module vector_issue #(
    parameter int unsigned LANES            = 32,
    parameter int unsigned MXU_COUNT        = 2,
    parameter int unsigned PUSH_DEPTH       = 2,
    parameter int unsigned MATMUL_DEPTH     = 4,
    parameter int unsigned POP_DEPTH        = 18,
    parameter int unsigned POPS_PER_MATMUL  = 1,
    parameter int unsigned POPS_PER_BLOCK   = 1,
    parameter int unsigned MXU_MATMUL_SLOTS = 0,
    parameter int unsigned MXU_PUSH_SLOTS   = 0,
    parameter int unsigned RETURN_STAGES    = 2,
    parameter int unsigned FP_DEPTH         = 16,
    parameter int unsigned EUP_WIDTH        = 1,
    parameter bit XLU_QUANTIZE              = 1'b0,
    parameter int unsigned XLU_REDUCE_TREES = 1,

    localparam int unsigned PUSH_W   = $clog2(PUSH_DEPTH + 1),
    localparam int unsigned MATMUL_W = $clog2(MATMUL_DEPTH + 1),
    localparam int unsigned POP_W    = $clog2(POP_DEPTH + 1),
    localparam int unsigned FP_W     = $clog2(FP_DEPTH + 1),
    localparam int unsigned MXU_MATMUL_W = MXU_MATMUL_SLOTS > 0 ? $clog2(MXU_MATMUL_SLOTS + 1) : 1,
    localparam int unsigned MXU_PUSH_W   = MXU_PUSH_SLOTS > 0 ? $clog2(MXU_PUSH_SLOTS + 1) : 1
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    mxu_os,
    input  logic                    valu_valid,
    input  isa_pkg::valu_opcode_t   valu_op,
    input  logic                    vex_valid,
    input  isa_pkg::vex_opcode_t    vex_op,
    input  isa_pkg::mxu_engine_id_t vex_engine,
    input  logic                    vex_bank,
    input  logic [1:0]              vex_mode,
    input  isa_pkg::scale_reg_id_t  vex_sreg,
    input  logic                    pop_valid,
    input  isa_pkg::vr_opcode_t     pop_op,
    input  isa_pkg::mxu_engine_id_t pop_engine,
    output logic                    ready,
    input  logic                    push_drained          [MXU_COUNT],
    input  logic                    matmul_drained        [MXU_COUNT],
    input  logic                    pop_arrived           [MXU_COUNT],
    input  logic                    mxu_matmul_freed      [MXU_COUNT],
    input  logic [1:0]              mxu_push_freed        [MXU_COUNT],
    input  logic                    transpose_pop_arrived,
    input  logic                    fp_pop_arrived,
    input  logic                    eup_pop_arrived,
    input  logic                    quant_pop_arrived,

    output logic [1:0]              perf_mxu_full,
    output logic [1:0]              perf_xlu_block
);
    import isa_pkg::*;

    typedef struct packed {
        logic quant_pop;
        logic eup_pop;
        logic fp_pop;
        logic transpose_pop;
        logic [MXU_COUNT-1:0] push;
        logic [MXU_COUNT-1:0] matmul;
        logic [MXU_COUNT-1:0] pop;
        logic [MXU_COUNT-1:0] mxu_matmul;
        logic [MXU_COUNT-1:0][1:0] mxu_push;
    } return_t;

    return_t                returned;
    return_t                completed;
    logic    [PUSH_W-1:0]   push_free_q   [MXU_COUNT];
    logic    [MATMUL_W-1:0] matmul_free_q [MXU_COUNT];
    logic    [POP_W-1:0]    output_free_q [MXU_COUNT];
    logic    [POP_W-1:0]    pop_ready_q   [MXU_COUNT];
    logic    [MXU_MATMUL_W-1:0] mxu_matmul_free_q [MXU_COUNT];
    logic    [MXU_PUSH_W-1:0]   mxu_bank_free_q   [MXU_COUNT][2];
    logic                   mxu_matmul_space;
    logic                   mxu_push_space;
    logic    [POP_W-1:0]    transpose_pop_ready_q;
    logic                   vex_ready;
    logic                   pop_ready;
    logic                   push_fire;
    logic                   matmul_fire;
    logic                   pop_fire;
    logic                   transpose_fire;
    logic                   transpose_active_q;
    logic [3:0]             transpose_fill_q;
    logic                   xlu_issue;
    logic                   xlu_fire;
    logic                   quant_issue;
    logic [2:0]             quant_index_q;
    logic                   quant_weight;
    logic                   quant_last;
    logic                   quant_result;
    localparam int unsigned TILE_VREGS      = LANES / 4;
    localparam int unsigned XLU_EXIT_REDUCE = $clog2(LANES) * 5 + 8;
    localparam int unsigned XLU_EXIT_QUANT  = 15;
    localparam int unsigned XLU_EXIT_QUANT_T = 22;
    localparam int unsigned XLU_EXIT_TILE   = 3;
    localparam int unsigned XLU_POOL        = 15 + 8;    // XLU results in flight + the tile's 8
    localparam int unsigned TARGET_XLU_DEPTH = XLU_POOL - 8;   // the description's xlu_depth
    logic [5:0]             xlu_free_from_q;
    localparam int unsigned TREE_W = XLU_REDUCE_TREES > 1 ? $clog2(XLU_REDUCE_TREES) : 1;
    logic [1:0]             reduce_busy_q [XLU_REDUCE_TREES];
    logic [TREE_W-1:0]      reduce_tree_q;
    logic [1:0]             quant_busy_q;
    logic                   quant_weight_q;
    logic                   quant_transposed;
    logic                   quant_transposed_q;
    logic [3:0]             tile_wait_q;
    logic [4:0]             xlu_pending_q;
    logic                   xlu_reserve;
    logic [5:0]             xlu_exit;
    logic [3:0]             xlu_exit_count;
    logic [3:0]             xlu_slots;
    logic                   mix_order_ok;
    logic                   mix_slots_ok;
    logic                   mix_xlu_ready;
    logic                   fp_issue;
    logic                   fp_ready;
    logic                   fp_fire;
    logic                   fp_pop;
    logic                   fp_pop_fire;
    logic                   mxu_pop;
    logic    [FP_W-1:0]     fp_free_q;
    logic    [FP_W-1:0]     fp_pop_ready_q;
    logic                   eup_issue;
    logic                   eup_ready;
    logic                   eup_fire;
    logic                   eup_pop;
    logic                   eup_pop_fire;
    logic    [FP_W-1:0]     eup_free_q;
    logic    [FP_W-1:0]     eup_pop_ready_q;
    logic    [1:0]          eup_busy_q;
    logic                   vquant_end;
    logic                   vquant_pop;
    logic                   vquant_pop_fire;
    logic    [FP_W-1:0]     vquant_free_q;
    logic    [FP_W-1:0]     vquant_pop_ready_q;

    for (genvar e = 0; e < MXU_COUNT; e++) begin : gen_return
        assign completed.push[e]   = push_drained[e];
        assign completed.matmul[e] = matmul_drained[e];
        assign completed.pop[e]    = pop_arrived[e];
        assign completed.mxu_matmul[e] = mxu_matmul_freed[e];
        assign completed.mxu_push[e]   = mxu_push_freed[e];
    end

    assign completed.transpose_pop = transpose_pop_arrived;
    assign completed.fp_pop        = fp_pop_arrived;
    assign completed.eup_pop       = eup_pop_arrived;
    assign completed.quant_pop     = quant_pop_arrived;

    shifter #(
        .WIDTH($bits(return_t)),
        .LENGTH(RETURN_STAGES)
    ) u_return (
        .clk,
        .rst,
        .en (1'b1),
        .d  (completed),
        .q  (returned)
    );

    acc_mode_t issue_acc_mode_q [MXU_COUNT];
    acc_mode_t matmul_acc_mode;
    logic      matmul_produces;
    assign matmul_acc_mode = int'(vex_engine) >= MXU_COUNT ? ACC_EMIT :
        vex_preload(vex_op) ? acc_mode_t'(vex_mode) : issue_acc_mode_q[int'(vex_engine)];
    assign matmul_produces = matmul_acc_mode inside {ACC_EMIT, ACC_LAST};
    logic [POP_W-1:0] matmul_pops;
    assign matmul_pops = POP_W'(mxu_os ? POPS_PER_BLOCK : POPS_PER_MATMUL);
    for (genvar e = 0; e < MXU_COUNT; e++) begin : gen_issue_mode
        always_ff @(posedge clk) begin
            if (rst) issue_acc_mode_q[e] <= ACC_EMIT;
            else if (matmul_fire && vex_preload(vex_op) && vex_engine == mxu_engine_id_t'(e))
                issue_acc_mode_q[e] <= acc_mode_t'(vex_mode);
        end
    end

    assign mxu_matmul_space = MXU_MATMUL_SLOTS == 0 || int'(vex_engine) >= MXU_COUNT || mxu_matmul_free_q[int'(vex_engine)] != 0;
    logic [MXU_PUSH_W-1:0] push_slots;
    assign push_slots = MXU_PUSH_W'(1);
    assign mxu_push_space = MXU_PUSH_SLOTS == 0 || int'(vex_engine) >= MXU_COUNT ||
        mxu_bank_free_q[int'(vex_engine)][mxu_os ? 1'b0 : vex_bank] >= push_slots;

    always_comb begin
        case (vex_op)
            VEX_NOP: vex_ready = 1'b1;
            PUSH: vex_ready = int'(vex_engine) < MXU_COUNT && push_free_q[int'(vex_engine)] != 0 && mxu_push_space;
            MATMUL,
            MATMUL_PRELOAD:
                vex_ready = !(mxu_os && vex_op == MATMUL) &&
                    int'(vex_engine) < MXU_COUNT && matmul_free_q[int'(vex_engine)] != 0 && mxu_matmul_space &&
                    (!matmul_produces || output_free_q[int'(vex_engine)] >= matmul_pops);
            TRANSPOSE_START: vex_ready = !transpose_active_q && tile_wait_q == 0;
            XLANE_ADD, XLANE_MAX, XLANE_MIN, XLANE_QUANTIZE: vex_ready = xlu_issue && mix_xlu_ready;
            TRANSPOSE_CONTINUE: vex_ready = transpose_active_q && transpose_fill_q < 4'(TILE_VREGS - 1);
            TRANSPOSE_END: vex_ready = transpose_active_q && transpose_fill_q == 4'(TILE_VREGS - 1) &&
                mix_order_ok && mix_slots_ok;
            default: vex_ready = 1'b0;
        endcase
    end

    assign quant_issue      = XLU_QUANTIZE && vex_op == XLANE_QUANTIZE;
    assign xlu_issue        = vex_op inside {XLANE_ADD, XLANE_MAX, XLANE_MIN} || quant_issue;
    assign xlu_fire         = ready && vex_valid && xlu_issue;
    assign quant_weight     = quant_issue && vex_mode != QUANTIZE_A;
    assign quant_transposed = quant_issue && vex_mode == QUANTIZE_WT;
    assign quant_last       = quant_index_q == (quant_weight ? 3'd7 : 3'd3);
    assign quant_result     = quant_weight ? quant_index_q inside {3'd1, 3'd4, 3'd7} : quant_index_q[0];

    always_comb begin
        xlu_reserve    = 1'b0;
        xlu_exit       = '0;
        xlu_exit_count = '0;
        xlu_slots      = '0;
        if (vex_op == TRANSPOSE_END) begin
            xlu_reserve    = 1'b1;
            xlu_exit       = 6'(XLU_EXIT_TILE);
            xlu_exit_count = 4'(TILE_VREGS);
            xlu_slots      = 4'(TILE_VREGS);
        end else if (xlu_issue && !quant_issue) begin
            xlu_reserve    = 1'b1;
            xlu_exit       = 6'(XLU_EXIT_REDUCE);
            xlu_exit_count = 4'd1;
            xlu_slots      = 4'd1;
        end else if (quant_issue) begin
            xlu_reserve    = quant_last;
            xlu_exit       = 6'(quant_transposed ? XLU_EXIT_QUANT_T : XLU_EXIT_QUANT);
            xlu_exit_count = quant_weight ? 4'd3 : 4'd2;
            xlu_slots      = 4'(quant_result);
        end
    end
    assign mix_order_ok  = !xlu_reserve || xlu_exit >= xlu_free_from_q;
    assign mix_slots_ok = 6'(xlu_pending_q) + 6'(xlu_slots) <= 6'(XLU_POOL);
    assign mix_xlu_ready = mix_order_ok && mix_slots_ok && (quant_issue ? quant_busy_q == 0 &&
        (quant_index_q == 0 || quant_weight == quant_weight_q && quant_transposed == quant_transposed_q)
        : reduce_busy_q[XLU_REDUCE_TREES > 1 ? int'(reduce_tree_q) : 0] == 0);

    assign fp_issue    = valu_valid && valu_op inside {ADD_BF16, MUL_BF16};
    assign fp_ready    = fp_free_q != 0;
    assign eup_issue   = valu_valid && valu_op == VEUP;
    assign eup_ready   = eup_busy_q == 0 && eup_free_q != 0;
    assign fp_pop      = pop_op == POP_FP;
    assign eup_pop     = pop_op == POP_EUP;
    assign vquant_end  = valu_valid && valu_op == VQUANT_END;
    assign vquant_pop  = pop_op == POP_QUANT;
    assign mxu_pop     = pop_op == POP_MXU;
    assign pop_ready   = vquant_pop ? vquant_pop_ready_q != 0 : eup_pop ? eup_pop_ready_q != 0 : fp_pop ? fp_pop_ready_q != 0 :
        pop_op == POP_XLU ? transpose_pop_ready_q != 0 : int'(pop_engine) < MXU_COUNT && pop_ready_q[int'(pop_engine)] != 0;
    assign ready       = (!vex_valid || vex_ready) && (!pop_valid || pop_ready) && (!fp_issue || fp_ready) &&
                         (!eup_issue || eup_ready) && (!vquant_end || vquant_free_q >= FP_W'(2));

    assign fp_fire         = ready && fp_issue;
    assign fp_pop_fire     = ready && pop_valid && fp_pop;
    assign eup_fire        = ready && eup_issue;
    assign eup_pop_fire    = ready && pop_valid && eup_pop;
    assign vquant_pop_fire = ready && pop_valid && vquant_pop;
    assign push_fire       = ready && vex_valid && vex_op == PUSH;
    assign matmul_fire     = ready && vex_valid && vex_matmul(vex_op);
    assign transpose_fire  = ready && vex_valid &&
        (vex_op inside {TRANSPOSE_START, TRANSPOSE_CONTINUE, TRANSPOSE_END} || xlu_issue);
    assign pop_fire        = ready && pop_valid;

    credit_counter #(
        .WIDTH(FP_W),
        .INIT(FP_DEPTH)
    ) u_fp_free (
        .clk,
        .rst,
        .add   (FP_W'(fp_pop_fire)),
        .sub   (FP_W'(fp_fire)),
        .count (fp_free_q)
    );
    credit_counter #(
        .WIDTH(FP_W),
        .INIT(0)
    ) u_fp_pop_ready (
        .clk,
        .rst,
        .add   (FP_W'(returned.fp_pop)),
        .sub   (FP_W'(fp_pop_fire)),
        .count (fp_pop_ready_q)
    );
    credit_counter #(
        .WIDTH(FP_W),
        .INIT(FP_DEPTH)
    ) u_eup_free (
        .clk,
        .rst,
        .add   (FP_W'(eup_pop_fire)),
        .sub   (FP_W'(eup_fire)),
        .count (eup_free_q)
    );
    credit_counter #(
        .WIDTH(FP_W),
        .INIT(0)
    ) u_eup_pop_ready (
        .clk,
        .rst,
        .add   (FP_W'(returned.eup_pop)),
        .sub   (FP_W'(eup_pop_fire)),
        .count (eup_pop_ready_q)
    );
    credit_counter #(
        .WIDTH(FP_W),
        .INIT(FP_DEPTH)
    ) u_vquant_free (
        .clk,
        .rst,
        .add   (FP_W'(vquant_pop_fire)),
        .sub   (ready && vquant_end ? FP_W'(2) : FP_W'(0)),
        .count (vquant_free_q)
    );
    credit_counter #(
        .WIDTH(FP_W),
        .INIT(0)
    ) u_vquant_pop_ready (
        .clk,
        .rst,
        .add   (FP_W'(returned.quant_pop)),
        .sub   (FP_W'(vquant_pop_fire)),
        .count (vquant_pop_ready_q)
    );

    always_ff @(posedge clk) begin
        if (rst) eup_busy_q <= '0;
        else if (eup_fire) eup_busy_q <= 2'(4 / EUP_WIDTH - 1);
        else if (eup_busy_q != 0) eup_busy_q <= eup_busy_q - 1'b1;
    end

    logic reduce_fire;
    logic quant_fire;
    assign reduce_fire = xlu_fire && !quant_issue;
    assign quant_fire  = xlu_fire && quant_issue;

    always_ff @(posedge clk) begin
        if (rst) begin
            transpose_active_q <= 1'b0;
            transpose_fill_q   <= '0;
            tile_wait_q        <= '0;
            xlu_free_from_q    <= '0;
            reduce_tree_q      <= '0;
            reduce_busy_q      <= '{default: '0};
            quant_index_q      <= '0;
            quant_weight_q     <= 1'b0;
            quant_transposed_q <= 1'b0;
            quant_busy_q       <= '0;
        end else begin
            // tile fill and drain
            if (transpose_fire && !xlu_fire) begin
                case (vex_op)
                    TRANSPOSE_START: begin
                        transpose_active_q <= 1'b1;
                        transpose_fill_q   <= 4'd1;
                    end
                    TRANSPOSE_CONTINUE: transpose_fill_q <= transpose_fill_q + 1'b1;
                    TRANSPOSE_END: begin
                        transpose_active_q <= 1'b0;
                        transpose_fill_q   <= '0;
                    end
                    default: ;
                endcase
            end
            if (transpose_fire && vex_op == TRANSPOSE_END) tile_wait_q <= 4'(TILE_VREGS);
            else if (tile_wait_q != 0) tile_wait_q <= tile_wait_q - 1'b1;

            // result exit order
            if (transpose_fire && xlu_reserve) xlu_free_from_q <= xlu_exit + 6'(xlu_exit_count) - 1'b1;
            else if (xlu_free_from_q != 0) xlu_free_from_q <= xlu_free_from_q - 1'b1;

            // reduce trees, used in turn
            if (XLU_REDUCE_TREES > 1 && reduce_fire) reduce_tree_q <= reduce_tree_q + 1'b1;
            for (int t = 0; t < XLU_REDUCE_TREES; t++) begin
                if (reduce_fire && (XLU_REDUCE_TREES == 1 || int'(reduce_tree_q) == t)) reduce_busy_q[t] <= 2'd3;
                else if (reduce_busy_q[t] != 0) reduce_busy_q[t] <= reduce_busy_q[t] - 1'b1;
            end

            // quantize groups
            if (quant_fire) begin
                quant_index_q      <= quant_last ? 3'd0 : quant_index_q + 1'b1;
                quant_weight_q     <= quant_weight;
                quant_transposed_q <= quant_transposed;
                quant_busy_q       <= quant_last ? 2'd1 : 2'd0;
            end else if (quant_busy_q != 0) begin
                quant_busy_q <= quant_busy_q - 1'b1;
            end
        end
    end

    credit_counter #(
        .WIDTH(5),
        .INIT(0)
    ) u_xlu_pending (
        .clk,
        .rst,
        .add   (transpose_fire ? 5'(xlu_slots) : 5'd0),
        .sub   (5'(pop_fire && pop_op == POP_XLU)),
        .count (xlu_pending_q)
    );
    credit_counter #(
        .WIDTH(POP_W),
        .INIT(0)
    ) u_transpose_pop_ready (
        .clk,
        .rst,
        .add   (POP_W'(returned.transpose_pop)),
        .sub   (POP_W'(pop_fire && pop_op == POP_XLU)),
        .count (transpose_pop_ready_q)
    );

    // MXU engines: queue, result and bank slots.
    for (genvar e = 0; e < MXU_COUNT; e++) begin : gen_engine_slots
        logic push_to_engine, matmul_to_engine, pop_from_engine;
        assign push_to_engine   = push_fire && vex_engine == mxu_engine_id_t'(e);
        assign matmul_to_engine = matmul_fire && vex_engine == mxu_engine_id_t'(e);
        assign pop_from_engine    = pop_fire && mxu_pop && pop_engine == mxu_engine_id_t'(e);

        credit_counter #(
            .WIDTH(PUSH_W),
            .INIT(PUSH_DEPTH)
        ) u_push_free (
            .clk,
            .rst,
            .add   (PUSH_W'(returned.push[e])),
            .sub   (PUSH_W'(push_to_engine)),
            .count (push_free_q[e])
        );
        credit_counter #(
            .WIDTH(MATMUL_W),
            .INIT(MATMUL_DEPTH)
        ) u_matmul_free (
            .clk,
            .rst,
            .add   (MATMUL_W'(returned.matmul[e])),
            .sub   (MATMUL_W'(matmul_to_engine)),
            .count (matmul_free_q[e])
        );
        credit_counter #(
            .WIDTH(POP_W),
            .INIT(POP_DEPTH)
        ) u_output_free (
            .clk,
            .rst,
            .add   (POP_W'(pop_from_engine)),
            .sub   (matmul_to_engine && matmul_produces ? matmul_pops : POP_W'(0)),
            .count (output_free_q[e])
        );
        credit_counter #(
            .WIDTH(POP_W),
            .INIT(0)
        ) u_pop_ready (
            .clk,
            .rst,
            .add   (POP_W'(returned.pop[e])),
            .sub   (POP_W'(pop_from_engine)),
            .count (pop_ready_q[e])
        );
        credit_counter #(
            .WIDTH(MXU_MATMUL_W),
            .INIT(MXU_MATMUL_SLOTS)
        ) u_mxu_matmul_free (
            .clk,
            .rst,
            .add   (MXU_MATMUL_W'(returned.mxu_matmul[e])),
            .sub   (MXU_MATMUL_W'(matmul_to_engine)),
            .count (mxu_matmul_free_q[e])
        );
        for (genvar b = 0; b < 2; b++) begin : gen_bank
            credit_counter #(
                .WIDTH(MXU_PUSH_W),
                .INIT(MXU_PUSH_SLOTS)
            ) u_bank_free (
                .clk,
                .rst,
                .add   (returned.mxu_push[e][b] ? (mxu_os ? MXU_PUSH_W'(1) : MXU_PUSH_W'(MXU_PUSH_SLOTS)) : '0),
                .sub   (push_to_engine && (mxu_os ? b == 0 : vex_bank == 1'(b)) ? push_slots : '0),
                .count (mxu_bank_free_q[e][b])
            );
        end
    end

    assign perf_xlu_block = {vex_valid && !vex_ready && vex_op == TRANSPOSE_START, vex_valid && !vex_ready &&
        (vex_op == TRANSPOSE_END || xlu_issue)};

    assign perf_mxu_full = {output_free_q[0] == 0, matmul_free_q[0] == 0};
endmodule
