module lane_vr #(
    parameter int unsigned SUBLANES        = 4,
    parameter int unsigned ELEMENT_WIDTH   = isa_pkg::VECTOR_ELEMENT_WIDTH,
    parameter int unsigned MXU_COUNT       = 4,
    parameter int unsigned POP_QUEUE_DEPTH = 18,
    parameter int unsigned FP_DEPTH        = 16,
    parameter bit FIRST_LANE               = 1'b1,
    parameter bit QUANTIZE                 = 1'b0,

    localparam int unsigned ENGINE_WIDTH    = $bits(isa_pkg::mxu_engine_id_t),
    localparam int unsigned POP_LEVEL_WIDTH = $clog2(POP_QUEUE_DEPTH+1),
    localparam int unsigned FP_LEVEL_WIDTH  = $clog2(FP_DEPTH+1)
) (
    input  logic                              clk,

    input  logic                              pop_fire,
    input  isa_pkg::vr_opcode_t               pop_op,
    input  isa_pkg::mxu_engine_id_t           pop_engine,
    output logic [ELEMENT_WIDTH-1:0]          pop_data              [SUBLANES],
    output logic                              pop_arrived           [MXU_COUNT],

    input  logic                              mxu_pop_valid         [SUBLANES][MXU_COUNT],
    input  logic [ELEMENT_WIDTH-1:0]          mxu_pop_data          [SUBLANES][MXU_COUNT],

    input  logic                              transpose_pop_valid,
    input  logic [ELEMENT_WIDTH-1:0]          transpose_pop_data    [SUBLANES],
    output logic                              transpose_pop_arrived,

    input  logic                              fp_valid              [SUBLANES],
    input  logic [ELEMENT_WIDTH-1:0]          fp_data               [SUBLANES],
    output logic                              fp_pop_arrived,

    input  logic                              eup_valid             [SUBLANES],
    input  logic [ELEMENT_WIDTH-1:0]          eup_data              [SUBLANES],
    output logic                              eup_pop_arrived,

    input  logic                              quant_valid,
    input  logic [SUBLANES*ELEMENT_WIDTH-1:0] quant_word,
    output logic                              quant_pop_arrived
);
    logic [POP_LEVEL_WIDTH-1:0] level_q        [MXU_COUNT];
    logic [ELEMENT_WIDTH-1:0]   pop_fifo_data  [SUBLANES][MXU_COUNT];
    logic [POP_LEVEL_WIDTH-1:0] pop_fifo_level [SUBLANES][MXU_COUNT];
    logic [POP_LEVEL_WIDTH-1:0] level_d        [MXU_COUNT];
    logic                       popped_q       [MXU_COUNT];
    logic [ELEMENT_WIDTH-1:0]   transpose_fifo_data [SUBLANES];
    logic [POP_LEVEL_WIDTH-1:0] transpose_fifo_level [SUBLANES];
    logic [POP_LEVEL_WIDTH-1:0] transpose_level_d;
    logic [POP_LEVEL_WIDTH-1:0] transpose_level_q;
    logic                       transpose_popped_q;
    logic                       mxu_pop;
    logic                       fp_pop;
    logic [ELEMENT_WIDTH-1:0]   fp_fifo_data  [SUBLANES];
    logic [FP_LEVEL_WIDTH-1:0]  fp_fifo_level [SUBLANES];
    logic [FP_LEVEL_WIDTH-1:0]  fp_level_d;
    logic [FP_LEVEL_WIDTH-1:0]  fp_level_q;
    logic                       fp_popped_q;
    logic                       eup_pop;
    logic [ELEMENT_WIDTH-1:0]   eup_fifo_data  [SUBLANES];
    logic [FP_LEVEL_WIDTH-1:0]  eup_fifo_level [SUBLANES];
    logic [FP_LEVEL_WIDTH-1:0]  eup_level_d;
    logic [FP_LEVEL_WIDTH-1:0]  eup_level_q;
    logic                       eup_popped_q;
    logic                       quant_pop;
    logic [SUBLANES*ELEMENT_WIDTH-1:0] quant_fifo_word;
    logic [FP_LEVEL_WIDTH-1:0]  quant_level_d;
    logic [FP_LEVEL_WIDTH-1:0]  quant_level_q;
    logic                       quant_popped_q;

    assign mxu_pop = pop_op == isa_pkg::POP_MXU;
    assign fp_pop  = pop_op == isa_pkg::POP_FP;
    assign eup_pop = pop_op == isa_pkg::POP_EUP;
    assign quant_pop = QUANTIZE && pop_op == isa_pkg::POP_QUANT;

    always_comb begin
        for (int sublane = 0; sublane < SUBLANES; sublane++) begin
            pop_data[sublane] = '0;
            if (eup_pop) begin
                pop_data[sublane] = eup_fifo_data[sublane];
            end else if (quant_pop) begin
                pop_data[sublane] = quant_fifo_word[sublane*ELEMENT_WIDTH +: ELEMENT_WIDTH];
            end else if (fp_pop) begin
                pop_data[sublane] = fp_fifo_data[sublane];
            end else if (pop_op == isa_pkg::POP_XLU) begin
                pop_data[sublane] = transpose_fifo_data[sublane];
            end else begin
                for (int engine = 0; engine < MXU_COUNT; engine++) begin
                    if (pop_engine == ENGINE_WIDTH'(engine)) begin
                        pop_data[sublane] = pop_fifo_data[sublane][engine];
                    end
                end
            end
        end

        for (int engine = 0; engine < MXU_COUNT; engine++) begin
            level_d[engine] = pop_fifo_level[0][engine];
            for (int sublane = 1; sublane < SUBLANES; sublane++) begin
                if (pop_fifo_level[sublane][engine] < level_d[engine])
                    level_d[engine] = pop_fifo_level[sublane][engine];
            end
        end

        // A result counts as arrived once its last sublane is in.
        fp_level_d = fp_fifo_level[0];
        for (int sublane = 1; sublane < SUBLANES; sublane++) begin
            if (fp_fifo_level[sublane] < fp_level_d)
                fp_level_d = fp_fifo_level[sublane];
        end

        eup_level_d = eup_fifo_level[0];
        for (int sublane = 1; sublane < SUBLANES; sublane++) begin
            if (eup_fifo_level[sublane] < eup_level_d)
                eup_level_d = eup_fifo_level[sublane];
        end

        transpose_level_d = transpose_fifo_level[0];
        for (int sublane = 1; sublane < SUBLANES; sublane++) begin
            if (transpose_fifo_level[sublane] < transpose_level_d)
                transpose_level_d = transpose_fifo_level[sublane];
        end
    end

    always_ff @(posedge clk) begin
        eup_level_q        <= eup_level_d;
        eup_popped_q       <= pop_fire && eup_pop;
        quant_level_q      <= quant_level_d;
        quant_popped_q     <= pop_fire && quant_pop;
        fp_level_q         <= fp_level_d;
        fp_popped_q        <= pop_fire && fp_pop;
        level_q            <= level_d;
        transpose_level_q  <= transpose_level_d;
        transpose_popped_q <= pop_fire && pop_op == isa_pkg::POP_XLU;

        for (int engine = 0; engine < MXU_COUNT; engine++)
            popped_q[engine] <= pop_fire && mxu_pop && pop_engine == ENGINE_WIDTH'(engine);
    end

    for (genvar engine = 0; engine < MXU_COUNT; engine++) begin : gen_pop_arrived
        assign pop_arrived[engine] = FIRST_LANE && level_d[engine] + POP_LEVEL_WIDTH'(popped_q[engine]) > level_q[engine];
    end

    assign transpose_pop_arrived = FIRST_LANE && transpose_level_d + POP_LEVEL_WIDTH'(transpose_popped_q) > transpose_level_q;
    assign fp_pop_arrived        = FIRST_LANE && fp_level_d + FP_LEVEL_WIDTH'(fp_popped_q) > fp_level_q;
    assign eup_pop_arrived       = FIRST_LANE && eup_level_d + FP_LEVEL_WIDTH'(eup_popped_q) > eup_level_q;
    assign quant_pop_arrived     = FIRST_LANE && quant_level_d + FP_LEVEL_WIDTH'(quant_popped_q) > quant_level_q;

    if (QUANTIZE) begin : gen_quant
        fifo #(
            .DATA_WIDTH(SUBLANES*ELEMENT_WIDTH),
            .DEPTH(FP_DEPTH),
            .READ_READY_BYPASS(FP_DEPTH == 1),
            .BRAM(1'b1)
        ) u_quant_fifo (
            .clk, .rst(1'b0),
            .w_en(quant_valid),
            .w_data(quant_word),
            .w_rdy(),
            .r_en(pop_fire && quant_pop),
            .r_data(quant_fifo_word),
            .r_valid(),
            .level(quant_level_d)
        );
    end else begin : gen_no_quant
        assign quant_fifo_word = '0;
        assign quant_level_d   = '0;
    end

    for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_pop_sublane

        for (genvar engine = 0; engine < MXU_COUNT; engine++) begin : gen_pop_engine
            fifo #(
                .DATA_WIDTH(ELEMENT_WIDTH),
                .DEPTH(POP_QUEUE_DEPTH),
                .READ_READY_BYPASS(POP_QUEUE_DEPTH == 1),
                .BRAM(1'b1)
            ) u_pop_fifo (
                .clk,
                .rst(1'b0),
                .w_en   (mxu_pop_valid[sublane][engine]),
                .w_data (mxu_pop_data[sublane][engine]),
                .w_rdy  (),
                .r_en   (pop_fire && mxu_pop && pop_engine == ENGINE_WIDTH'(engine)),
                .r_data (pop_fifo_data[sublane][engine]),
                .r_valid(),
                .level  (pop_fifo_level[sublane][engine])
            );
        end

        fifo #(
            .DATA_WIDTH(ELEMENT_WIDTH),
            .DEPTH(FP_DEPTH),
            .READ_READY_BYPASS(FP_DEPTH == 1),
            .BRAM(1'b1)
        ) u_fp_fifo (
            .clk, .rst(1'b0),
            .w_en(fp_valid[sublane]),
            .w_data(fp_data[sublane]),
            .w_rdy(),
            .r_en(pop_fire && fp_pop),
            .r_data(fp_fifo_data[sublane]),
            .r_valid(),
            .level(fp_fifo_level[sublane])
        );

        fifo #(
            .DATA_WIDTH(ELEMENT_WIDTH),
            .DEPTH(FP_DEPTH),
            .READ_READY_BYPASS(FP_DEPTH == 1),
            .BRAM(1'b1)
        ) u_eup_fifo (
            .clk, .rst(1'b0),
            .w_en(eup_valid[sublane]),
            .w_data(eup_data[sublane]),
            .w_rdy(),
            .r_en(pop_fire && eup_pop),
            .r_data(eup_fifo_data[sublane]),
            .r_valid(),
            .level(eup_fifo_level[sublane])
        );

        fifo #(
            .DATA_WIDTH(ELEMENT_WIDTH),
            .DEPTH(POP_QUEUE_DEPTH),
            .READ_READY_BYPASS(POP_QUEUE_DEPTH == 1),
            .BRAM(1'b1)
        ) u_transpose_fifo (
            .clk, .rst(1'b0),
            .w_en(transpose_pop_valid),
            .w_data(transpose_pop_data[sublane]),
            .w_rdy(),
            .r_en(pop_fire && pop_op == isa_pkg::POP_XLU),
            .r_data(transpose_fifo_data[sublane]),
            .r_valid(),
            .level(transpose_fifo_level[sublane])
        );
    end

endmodule : lane_vr
