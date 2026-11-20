// The matrix unit's socket: MATMUL commands and activation words in, N_A rows a beat to the unit, results to the sublanes.
// vector_issue counts the slots, so no input has a ready.
module vector_mxu #(
    parameter int unsigned LANES             = 32,
    parameter int unsigned SUBLANES          = 4,
    parameter int unsigned ELEMENT_WIDTH     = isa_pkg::VECTOR_ELEMENT_WIDTH,
    parameter int unsigned COMMAND_DEPTH     = 32,
    parameter int unsigned ROW_QUEUE_DEPTH   = 128,
    parameter int unsigned TAG_FIFO_DEPTH    = 48,
    parameter bit          ACC_ENABLE        = 1'b0,
    parameter int unsigned ACC_ROWS          = 1024,
    parameter bit          E2M1              = 1'b0,
    parameter bit          MX                = 1'b0,
    parameter bit          ACC_FP32          = 1'b0,
    parameter int unsigned N_W               = 3,
    parameter int unsigned N_A               = 3,
    parameter int unsigned W_BITS            = 4,
    parameter int unsigned A_BITS            = 4,
    parameter int unsigned PROD_W            = 8,
    parameter bit          W_TWOS            = 1'b0,
    parameter int unsigned PSUM_W            = 12,
    parameter int unsigned CODE_BITS         = ELEMENT_WIDTH,
    parameter int unsigned W_CODES           = 1,
    parameter bit          TILE_MODES        = 1'b0,
    parameter bit          BANK_FREE_AT_LOAD = 1'b0,
    parameter int unsigned A_WORD_ROWS       = SUBLANES * ELEMENT_WIDTH / CODE_BITS,
    parameter int unsigned DATAFLOW          = 1,

    localparam int unsigned WORD_WIDTH      = SUBLANES * ELEMENT_WIDTH,
    localparam int unsigned ROW_WIDTH       = CODE_BITS,
    localparam int unsigned ROWS            = WORD_WIDTH / ROW_WIDTH,
    localparam int unsigned PUSH_WIDTH      = CODE_BITS,
    localparam int unsigned SCALE_WIDTH     = 8,
    localparam int unsigned B_WIDTH         = MX ? SCALE_WIDTH + PUSH_WIDTH : PUSH_WIDTH,
    localparam int unsigned A_WORD_WIDTH    = A_WORD_ROWS * ROW_WIDTH,
    localparam int unsigned WORDS           = ROW_QUEUE_DEPTH / A_WORD_ROWS,
    localparam int unsigned BEAT_WIDTH      = N_A * ROW_WIDTH,
    localparam int unsigned SCALE_A_WIDTH   = N_A * SCALE_WIDTH,
    localparam int unsigned RESULT_WIDTH    = N_A * ELEMENT_WIDTH,
    localparam int unsigned POSITION_W      = $clog2(ROWS),
    localparam int unsigned WORD_POSITION_W = $clog2(A_WORD_ROWS),
    localparam int unsigned SUBLANE_W       = $clog2(SUBLANES),
    localparam int unsigned COMMAND_W       = $clog2(COMMAND_DEPTH + 1)
) (
    input  logic                     clk,
    input  logic                     rst,

    input  logic                     dataflow_os,
    input  logic [31:0]              mode_word,

    input  logic                     matmul_cmd_valid,
    input  logic                     matmul_cmd_preload,
    input  logic                     matmul_cmd_bank,
    input  logic [1:0]               matmul_cmd_mode,
    input  logic [1:0]               matmul_cmd_tile,

    input  logic                     push_valid       [LANES],
    input  logic [PUSH_WIDTH-1:0]    push_data        [LANES],
    input  logic [SCALE_WIDTH-1:0]   push_scale       [LANES],
    input  logic                     push_bank        [LANES],

    input  logic                     activation_valid [LANES],
    input  logic [A_WORD_WIDTH-1:0]  activation_data  [LANES],
    input  logic [SCALE_WIDTH-1:0]   activation_scale [LANES],

    output logic                     matmul_freed,
    output logic [1:0]               push_freed,
    output logic                     result_valid     [LANES][SUBLANES],
    output logic [ELEMENT_WIDTH-1:0] result_data      [LANES][SUBLANES]
);
    logic                     command_valid;
    logic                     command_preload;
    logic                     command_bank;
    logic [1:0]               command_mode;
    logic [1:0]               matmul_tile;
    logic [COMMAND_W-1:0]     command_level;
    logic                     scale_valid;
    logic [SCALE_A_WIDTH-1:0] matmul_scale_a;
    logic [POSITION_W-1:0]    offset_q;
    logic [POSITION_W:0]      next_offset;
    logic                     beat_ready;
    logic                     beat_fire;
    logic                     command_pop;
    logic                     matmul_ready;
    logic                     b_freed;
    logic                     b_freed_bank;
    logic [B_WIDTH-1:0]       b_data     [LANES];
    logic                     a_valid    [LANES];
    logic                     a_ready    [LANES];
    logic [BEAT_WIDTH-1:0]    a_data     [LANES];
    logic                     psum_valid [LANES];
    logic [RESULT_WIDTH-1:0]  psum_data  [LANES];

    fifo #(
        .DATA_WIDTH(6),
        .DEPTH(COMMAND_DEPTH)
    ) u_command (
        .clk,
        .rst,
        .w_en    (matmul_cmd_valid),
        .w_data  ({matmul_cmd_tile, matmul_cmd_mode, matmul_cmd_bank, matmul_cmd_preload}),
        .w_rdy   (),
        .r_en    (command_pop),
        .r_data  ({matmul_tile, command_mode, command_bank, command_preload}),
        .r_valid (command_valid),
        .level   (command_level)
    );

    assign next_offset  = (POSITION_W+1)'(offset_q) + (POSITION_W+1)'(N_A);
    assign beat_ready   = command_valid && scale_valid &&
                          (next_offset <= (POSITION_W+1)'(ROWS) || command_level >= COMMAND_W'(2));
    assign beat_fire    = beat_ready && matmul_ready;
    assign command_pop  = beat_fire && next_offset >= (POSITION_W+1)'(ROWS);
    assign matmul_freed = command_pop;
    assign push_freed   = {b_freed && b_freed_bank, b_freed && !b_freed_bank};

    always_ff @(posedge clk) begin
        if (rst) offset_q <= '0;
        else if (beat_fire) offset_q <= POSITION_W'(next_offset);
    end

    if (MX) begin : gen_scale
        logic [SCALE_WIDTH*ROWS-1:0] entry;
        logic [SCALE_WIDTH*ROWS-1:0] head;
        logic [POSITION_W-1:0]       arrived_q;
        for (genvar row = 0; row < ROWS; row++) begin : gen_align
            shifter #(
                .WIDTH(SCALE_WIDTH),
                .LENGTH(ROWS - 1 - row)
            ) u_scale_align (
                .clk,
                .rst (1'b0),
                .en  (1'b1),
                .d   (activation_scale[row]),
                .q   (entry[SCALE_WIDTH*row +: SCALE_WIDTH])
            );
        end
        always_ff @(posedge clk) begin
            if (rst) arrived_q <= '0;
            else if (activation_valid[ROWS-1]) arrived_q <= arrived_q + POSITION_W'(A_WORD_ROWS);
        end
        logic                        head_valid;
        logic                        head_pop;
        fifo #(
            .DATA_WIDTH(SCALE_WIDTH*ROWS),
            .DEPTH(ROW_QUEUE_DEPTH/ROWS > 2 ? ROW_QUEUE_DEPTH/ROWS : 2)
        ) u_scale (
            .clk,
            .rst,
            .w_en    (activation_valid[ROWS-1] && arrived_q == '0),
            .w_data  (entry),
            .w_rdy   (),
            .r_en    (head_pop),
            .r_data  (head),
            .r_valid (head_valid),
            .level   ()
        );
        if (ROWS % N_A == 0) begin : gen_aligned
            assign head_pop       = command_pop;
            assign scale_valid    = head_valid;
            assign matmul_scale_a = head[SCALE_WIDTH*offset_q +: SCALE_A_WIDTH];
        end else begin : gen_straddle
            logic [SCALE_WIDTH*ROWS-1:0] current_q;
            logic                        current_valid_q;
            logic                        take;
            assign take        = !current_valid_q || command_pop;
            assign head_pop    = head_valid && take;
            assign scale_valid = current_valid_q && (next_offset <= (POSITION_W+1)'(ROWS) || head_valid);
            always_ff @(posedge clk) begin
                if (rst) current_valid_q <= 1'b0;
                else if (take) current_valid_q <= head_valid;
            end
            always_ff @(posedge clk) if (head_pop) current_q <= head;
            for (genvar j = 0; j < N_A; j++) begin : gen_row
                logic [POSITION_W:0] index;
                assign index = (POSITION_W+1)'(offset_q) + (POSITION_W+1)'(j);
                assign matmul_scale_a[SCALE_WIDTH*j +: SCALE_WIDTH] = index < (POSITION_W+1)'(ROWS)
                    ? current_q[SCALE_WIDTH*POSITION_W'(index) +: SCALE_WIDTH]
                    : head[SCALE_WIDTH*POSITION_W'(index) +: SCALE_WIDTH];
            end
        end
    end else begin : gen_no_scale
        assign scale_valid    = 1'b1;
        assign matmul_scale_a = '0;
    end

    for (genvar lane = 0; lane < LANES; lane++) begin : gen_lane
        logic [A_WORD_WIDTH-1:0] head;
        logic                    head_valid;
        logic                    word_pop;
        logic                    fire;
        logic [SUBLANE_W-1:0]    sublane_q;

        assign b_data[lane] = B_WIDTH'({push_scale[lane], push_data[lane]});

        fifo #(
            .DATA_WIDTH(A_WORD_WIDTH),
            .DEPTH(WORDS)
        ) u_words (
            .clk,
            .rst,
            .w_en    (activation_valid[lane]),
            .w_data  (activation_data[lane]),
            .w_rdy   (),
            .r_en    (word_pop),
            .r_data  (head),
            .r_valid (head_valid),
            .level   ()
        );

        assign fire = a_valid[lane] && a_ready[lane];

        if (A_WORD_ROWS == N_A) begin : gen_beat
            assign a_valid[lane] = head_valid;
            assign a_data[lane]  = head;
            assign word_pop      = fire;
        end else begin : gen_unpack
            logic [A_WORD_WIDTH-1:0]    current_q;
            logic                       current_valid_q;
            logic [WORD_POSITION_W-1:0] position_q;
            logic [WORD_POSITION_W:0]   end_position;
            logic                       take;

            assign end_position  = (WORD_POSITION_W+1)'(position_q) + (WORD_POSITION_W+1)'(N_A);
            assign take          = !current_valid_q || fire && end_position >= (WORD_POSITION_W+1)'(A_WORD_ROWS);
            assign a_valid[lane] = current_valid_q && (end_position <= (WORD_POSITION_W+1)'(A_WORD_ROWS) || head_valid);
            assign word_pop      = head_valid && take;

            for (genvar j = 0; j < N_A; j++) begin : gen_row
                logic [WORD_POSITION_W:0] index;
                assign index = (WORD_POSITION_W+1)'(position_q) + (WORD_POSITION_W+1)'(j);
                assign a_data[lane][ROW_WIDTH*j +: ROW_WIDTH] = index < (WORD_POSITION_W+1)'(A_WORD_ROWS)
                    ? current_q[ROW_WIDTH*WORD_POSITION_W'(index) +: ROW_WIDTH]
                    : head[ROW_WIDTH*WORD_POSITION_W'(index) +: ROW_WIDTH];
            end

            always_ff @(posedge clk) begin
                if (rst) begin
                    current_valid_q <= 1'b0;
                    position_q      <= '0;
                end else if (take) begin
                    current_valid_q <= head_valid;
                    position_q      <= current_valid_q ? WORD_POSITION_W'(end_position) : '0;
                end else if (fire) begin
                    position_q      <= WORD_POSITION_W'(end_position);
                end
            end
            always_ff @(posedge clk) if (word_pop) current_q <= head;
        end

        always_ff @(posedge clk) begin
            if (rst) sublane_q <= '0;
            else if (psum_valid[lane]) sublane_q <= sublane_q + SUBLANE_W'(N_A);
        end

        for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_result
            logic [SUBLANE_W-1:0] row;
            logic                 used;
            assign row  = (dataflow_os ? SUBLANE_W'(SUBLANES - 1 - sublane) : SUBLANE_W'(sublane)) - sublane_q;
            assign used = (SUBLANE_W+1)'(row) < (SUBLANE_W+1)'(N_A);
            assign result_valid[lane][sublane] = psum_valid[lane] && used;
            assign result_data[lane][sublane]  = psum_data[lane][ELEMENT_WIDTH*(int'(row) % N_A) +: ELEMENT_WIDTH];
        end
    end

    mxu #(
        .LANES(LANES),
        .TAG_FIFO_DEPTH(TAG_FIFO_DEPTH),
        .ACC_ENABLE(ACC_ENABLE),
        .ACC_ROWS(ACC_ROWS),
        .E2M1(E2M1),
        .MX(MX),
        .ACC_FP32(ACC_FP32),
        .N_W(N_W),
        .N_A(N_A),
        .W_BITS(W_BITS),
        .A_BITS(A_BITS),
        .PROD_W(PROD_W),
        .W_TWOS(W_TWOS),
        .PSUM_W(PSUM_W),
        .CODE_BITS(CODE_BITS),
        .W_CODES(W_CODES),
        .TILE_MODES(TILE_MODES),
        .DATAFLOW(DATAFLOW),
        .BANK_FREE_AT_LOAD(BANK_FREE_AT_LOAD)
    ) u_mxu (
        .*,
        .b_valid        (push_valid),
        .b_bank         (push_bank),
        .matmul_valid   (beat_ready),
        .matmul_preload (command_preload && offset_q == '0),
        .matmul_bank    (command_bank),
        .matmul_mode    (command_mode)
    );
endmodule : vector_mxu
