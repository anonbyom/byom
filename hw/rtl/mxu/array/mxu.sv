module mxu #(
    parameter int unsigned  LANES             = 32,
    parameter int unsigned  A_FIFO_DEPTH      = 128,
    parameter int unsigned  TAG_FIFO_DEPTH    = 48,
    parameter bit           ACC_ENABLE        = 1'b0,
    parameter int unsigned  ACC_ROWS          = 1024,
    parameter bit           E2M1              = 1'b0,
    parameter bit           MX                = 1'b0,
    parameter bit           ACC_FP32          = 1'b0,
    parameter int unsigned  N_W               = 3,
    parameter int unsigned  N_A               = 3,
    parameter int unsigned  W_BITS            = 4,
    parameter int unsigned  A_BITS            = 4,
    parameter int unsigned  PROD_W            = 8,
    parameter bit           W_TWOS            = 1'b0,
    parameter int unsigned  PSUM_W            = 12,
    parameter int unsigned  CODE_BITS         = 16,
    parameter int unsigned  W_CODES           = 1,
    parameter bit           TILE_MODES        = 1'b0,
    parameter int unsigned  DATAFLOW          = 1,
    parameter bit           BANK_FREE_AT_LOAD = 1'b0,
    parameter int unsigned  A_WORD_ROWS       = N_A,     // a MATMUL word's rows (vector_mxu's)
    localparam int unsigned DIM               = LANES,
    localparam int unsigned GROUPS            = (DIM + N_W - 1) / N_W,
    localparam int unsigned SPAN              = GROUPS * N_W,
    localparam int unsigned BF16_WIDTH        = 16,
    localparam int unsigned SCALE_WIDTH       = 8,
    localparam bit          SUM_FLOAT         = pe_shape::SUM_FLOAT,
    localparam int unsigned ROW_SKEW          = pe_shape::ROW_SKEW,
    localparam bit          FLOAT             = E2M1 || MX,
    localparam bit          SUM_OWN           = SUM_FLOAT && pe_shape::ACC_OWN,
    localparam bit          FLOAT_OUT         = FLOAT || SUM_FLOAT && !SUM_OWN,
    localparam int unsigned B_WIDTH           = MX ? SCALE_WIDTH + CODE_BITS : CODE_BITS,
    localparam int unsigned A_WIDTH           = N_A * CODE_BITS,
    localparam int unsigned A_CODES           = N_A * A_BITS,
    localparam int unsigned MODE_BITS         = TILE_MODES ? 2 : 0,
    localparam bit          ENCODE            = pe_shape::ENCODE_BITS != 0,
    localparam int unsigned W_OPERAND         = (E2M1 ? 5 : W_BITS) + MODE_BITS,
    localparam int unsigned A_OPERAND         = ENCODE ? pe_shape::ENCODE_BITS : E2M1 ? 5 : A_BITS,
    localparam int unsigned SCALE_A_WIDTH     = N_A * SCALE_WIDTH,
    localparam int unsigned TAG_WIDTH         = 3 + (MX ? SCALE_A_WIDTH : 0) + MODE_BITS,
    localparam int unsigned OUTPUT_WIDTH      = N_A * BF16_WIDTH,
    localparam bit          PRODUCT_FP32      = FLOAT_OUT && ACC_ENABLE && ACC_FP32,
    localparam int unsigned CONVERT_DELAY     = FLOAT ? 4 : 0,
    localparam int unsigned PRODUCT_DELAY     = 1 + pe_shape::ENCODE_LATENCY + (DIM - 1) * ROW_SKEW +
                                                pe_shape::LATENCY,
    localparam int unsigned RESULT_DELAY      = PRODUCT_DELAY + CONVERT_DELAY,
    localparam int unsigned COUNT_W           = $clog2(DIM + 1)
) (
    input  logic                     clk,
    input  logic                     rst,
    input  logic                     dataflow_os,

    input  logic                     b_valid       [DIM],
    input  logic [B_WIDTH-1:0]       b_data        [DIM],
    input  logic                     b_bank        [DIM],
    output logic                     b_freed,
    output logic                     b_freed_bank,

    input  logic                     matmul_valid,
    output logic                     matmul_ready,
    input  logic                     matmul_preload,
    input  logic                     matmul_bank,
    input  logic [1:0]               matmul_mode,
    input  logic [1:0]               matmul_tile,
    input  logic [SCALE_A_WIDTH-1:0] matmul_scale_a,
    input  logic                     a_valid       [DIM],
    output logic                     a_ready       [DIM],
    input  logic [A_WIDTH-1:0]       a_data        [DIM],

    output logic                     psum_valid    [DIM],
    output logic [OUTPUT_WIDTH-1:0]  psum_data     [DIM]
);

    logic [W_BITS-1:0]   b_fifo_bank_data  [2][DIM];
    logic                b_fifo_bank_valid [2][DIM];
    logic                b_load_bank_q;
    logic                b_load_bank;
    logic                b_load_bank_wave  [DIM];
    logic                b_load_wave       [DIM];
    logic                load_hold;
    logic                b_load            [DIM];
    logic [W_BITS-1:0]   b_in              [DIM];

    logic [A_CODES-1:0]  a_fifo_data       [DIM];
    logic                a_fifo_valid      [DIM];
    logic                a_pop_wave        [DIM + 1];
    logic [$clog2(A_FIFO_DEPTH+1)-1:0] a_level;
    logic [A_BITS-1:0]   a_in              [DIM][N_A];
    logic                a_launch;

    logic [COUNT_W-1:0]  b_load_remaining_q;
    logic                b_load_done;
    logic                b_load_beat;

    logic [TAG_WIDTH-1:0] tag_in;
    logic [TAG_WIDTH-1:0] tag_fifo_data;
    logic                tag_is_preload;
    logic [1:0]          tag_mode;
    logic                tag_fifo_rvalid;
    logic                tag_fifo_wrdy;
    logic                matmul_accept;
    logic                preload_accept;
    logic                preload_pending_q;

    logic                b_update_fire;
    logic                b_update_aligned;
    logic                b_update          [DIM];
    logic                result_wave       [SPAN];
    logic                psum_valid_first;
    logic [W_OPERAND-1:0] b_operand        [DIM];
    logic [A_OPERAND-1:0] a_operand        [DIM][N_A];
    logic signed [PSUM_W-1:0] psum_out     [DIM][N_A];

    localparam int unsigned ACC_GAP = 8;
    logic [3:0]          acc_beats_q;
    logic [3:0]          acc_since_q;
    logic                acc_ready;

    assign tag_is_preload = tag_fifo_data[0];
    assign tag_mode       = ACC_ENABLE ? tag_fifo_data[TAG_WIDTH-MODE_BITS-2 +: 2] : 2'd0;
    assign acc_ready      = !ACC_ENABLE || !tag_mode[1] || 5'(acc_beats_q) + 5'(acc_since_q) >= 5'(ACC_GAP + 1);
    assign a_launch       = a_level > $bits(a_level)'(a_pop_wave[1]) && tag_fifo_rvalid &&
                            (~tag_is_preload || (b_load_done && acc_ready));
    assign b_update_fire  = a_launch && tag_is_preload;
    assign matmul_ready   = tag_fifo_wrdy && (~matmul_preload || ~preload_pending_q || b_update_fire);
    assign matmul_accept  = matmul_valid && matmul_ready;
    assign preload_accept = matmul_accept && matmul_preload;
    assign b_load_done    = preload_pending_q && b_load_remaining_q == 0;
    assign b_load_bank    = preload_accept ? matmul_bank : b_load_bank_q;
    assign b_load_beat    = (b_load_remaining_q != 0 || preload_accept) && b_fifo_bank_valid[b_load_bank][0] &&
                            !load_hold;

    always_ff @(posedge clk) begin
        if (rst) begin
            preload_pending_q  <= 1'b0;
            b_load_remaining_q <= '0;
            b_load_bank_q      <= 1'b0;
        end else begin
            preload_pending_q <= preload_accept || (preload_pending_q && !b_update_fire);
            if (preload_accept) b_load_bank_q <= matmul_bank;
            if (preload_accept)
                b_load_remaining_q <= COUNT_W'(DIM) - COUNT_W'(b_load_beat);
            else if (b_load_beat)
                b_load_remaining_q <= b_load_remaining_q - 1'b1;
        end
    end

    if (ACC_ENABLE) begin : gen_acc_gap
        always_ff @(posedge clk) begin
            if (a_launch) begin
                acc_beats_q <= tag_is_preload ? 4'd1 : (acc_beats_q == 4'hf ? 4'hf : acc_beats_q + 1'b1);
                acc_since_q <= 4'd1;
            end else if (acc_since_q != 4'hf) begin
                acc_since_q <= acc_since_q + 1'b1;
            end
        end
    end else begin : gen_no_acc_gap
        assign acc_beats_q = '0;
        assign acc_since_q = '0;
    end

    logic b_load_last;
    logic b_load_freed;
    assign b_load_last  = b_load_beat && (preload_accept ? COUNT_W'(DIM) : b_load_remaining_q) == COUNT_W'(1);
    assign b_load_freed = BANK_FREE_AT_LOAD ? b_load_beat && (preload_accept || b_load_remaining_q == COUNT_W'(DIM))
                                            : b_load_last;
    shifter #(
        .WIDTH(2),
        .LENGTH(DIM)
    ) u_freed (
        .clk,
        .rst,
        .en (1'b1),
        .d  ({b_load_freed, b_load_bank}),
        .q  ({b_freed, b_freed_bank})
    );
    shifter_taps #(
        .WIDTH(1),
        .LENGTH(DIM - 1)
    ) u_load_wave (
        .clk,
        .rst,
        .en (1'b1),
        .d  (b_load_beat),
        .q  (b_load_wave)
    );
    shifter_taps #(
        .WIDTH(1),
        .LENGTH(DIM - 1)
    ) u_bank_wave (
        .clk,
        .rst,
        .en (1'b1),
        .d  (b_load_bank),
        .q  (b_load_bank_wave)
    );
    logic [1:0] b_load_tile_wave [DIM];
    if (TILE_MODES) begin : gen_load_tile
        logic [1:0] load_tile;
        logic [1:0] load_tile_q;
        assign load_tile = preload_accept ? matmul_tile : load_tile_q;
        always_ff @(posedge clk) if (preload_accept) load_tile_q <= matmul_tile;
        shifter_taps #(
            .WIDTH(2),
            .LENGTH(DIM - 1)
        ) u_tile_wave (
            .clk,
            .rst,
            .en (1'b1),
            .d  (load_tile),
            .q  (b_load_tile_wave)
        );
    end else begin : gen_no_load_tile
        assign b_load_tile_wave = '{default: '0};
    end
    localparam int unsigned LOAD_HOLD = N_W - 1 + (DIM - 1) * (ROW_SKEW - 1);
    if (LOAD_HOLD > 0) begin : gen_load_hold
        logic recent [LOAD_HOLD];
        shifter_taps #(
            .WIDTH(1),
            .LENGTH(LOAD_HOLD - 1)
        ) u_recent (
            .clk,
            .rst,
            .en (1'b1),
            .d  (b_update_fire),
            .q  (recent)
        );
        always_comb begin
            load_hold = 1'b0;
            for (int unsigned i = 0; i < LOAD_HOLD; i++) load_hold |= recent[i];
        end
    end else begin : gen_no_load_hold
        assign load_hold = 1'b0;
    end

    localparam bit          INT_SUMS            = !FLOAT_OUT && !SUM_OWN;
    localparam int unsigned OUTPUT_DELAY        = N_W - 1 + (ACC_ENABLE ? 4 + 1 + (INT_SUMS ? 1 : 0) + 1 : INT_SUMS ? 2 : 1);
    localparam int unsigned SOCKET_RESULT_DELAY = 1 + RESULT_DELAY + OUTPUT_DELAY;    // a cycle to schedule the row
    localparam bit          SOCKET_FREE_AT_LOAD = BANK_FREE_AT_LOAD;
    localparam int unsigned SOCKET_TILE_SPACING = DIM + LOAD_HOLD;
    localparam int unsigned SOCKET_IN_FLIGHT    = (A_FIFO_DEPTH < TAG_FIFO_DEPTH ? A_FIFO_DEPTH : TAG_FIFO_DEPTH) /
                                                  ((A_WORD_ROWS + N_A - 1) / N_A);
    localparam int unsigned SOCKET_ADD_STAGES   = pe_shape::ACC_STAGES;
    localparam string       TARGET_MXU_OPERANDS = "bf16";
    localparam string       ARITH_KIND          = SUM_FLOAT ? "float" : "int";
    localparam int unsigned ARITH_N_W           = N_W;
    localparam int unsigned ARITH_N_A           = N_A;
    if (SUM_FLOAT) begin : gen_float_arith
        localparam string ARITH_K_TILES = ACC_FP32 ? "fp32_accumulator" : "add_impl";
    end else begin : gen_int_arith
        localparam int unsigned ARITH_W_BITS     = W_BITS < CODE_BITS ? W_BITS : CODE_BITS;
        localparam int unsigned ARITH_A_BITS     = A_BITS;
        localparam bit          ARITH_W_FULL_NEG = W_CODES > 1 && W_TWOS || W_BITS > CODE_BITS;
        localparam bit          ARITH_PACKED     = CODE_BITS == 4;
    end

    for (genvar col = 0; col < DIM; col++) begin : gen_b
        logic read;
        logic bank;
        assign read = b_load_wave[col];
        assign bank = b_load_bank_wave[col];

        logic [W_BITS-1:0] weight_code;
        logic              weight_valid;
        if (W_CODES > 1) begin : gen_gather
            // W_CODES consecutive codes make one weight, the first in the low bits.
            logic [W_BITS-1:0]          gather_q;
            logic [$clog2(W_CODES)-1:0] count_q;
            assign weight_code  = {b_data[col][CODE_BITS-1:0], gather_q[W_BITS-1:CODE_BITS]};
            assign weight_valid = b_valid[col] && count_q == $bits(count_q)'(W_CODES - 1);
            always_ff @(posedge clk) begin
                if (rst) count_q <= '0;
                else if (b_valid[col]) count_q <= weight_valid ? '0 : count_q + 1'b1;
                if (b_valid[col]) gather_q <= weight_code;
            end
        end else if (E2M1 || SUM_FLOAT) begin : gen_raw
            assign weight_code  = b_data[col][W_BITS-1:0];
            assign weight_valid = b_valid[col];
        end else begin : gen_int
            int_code #(
                .BITS(W_BITS),
                .TWOS(W_TWOS),
                .IN_BITS(CODE_BITS)
            ) u_code (
                .int4 (b_data[col][CODE_BITS-1:0]),
                .code (weight_code)
            );
            assign weight_valid = b_valid[col];
        end

        for (genvar index = 0; index < 2; index++) begin : gen_bank
            fifo #(
                .DATA_WIDTH(W_BITS),
                .DEPTH(DIM)
            ) u_fifo (
                .clk,
                .rst,
                .w_en    (weight_valid && b_bank[col] == 1'(index)),
                .w_data  (weight_code),
                .w_rdy   (),
                .r_en    (read && bank == 1'(index)),
                .r_data  (b_fifo_bank_data[index][col]),
                .r_valid (b_fifo_bank_valid[index][col]),
                .level   ()
            );
        end

        always_ff @(posedge clk) begin
            if (rst) b_load[col] <= 1'b0;
            else b_load[col] <= read && b_fifo_bank_valid[bank][col];
            b_in[col] <= b_fifo_bank_data[bank][col];
        end

        logic [W_OPERAND-MODE_BITS-1:0] b_value;
        if (E2M1) begin : gen_decode
            e2m1_decode b_decoder (
                .code  (b_in[col]),
                .value (b_value)
            );
        end else begin : gen_operand
            assign b_value = b_in[col];
        end
        if (TILE_MODES) begin : gen_tile
            logic [1:0] tile_q;
            always_ff @(posedge clk) tile_q <= b_load_tile_wave[col];
            assign b_operand[col] = {tile_q, b_value};
        end else begin : gen_no_tile
            assign b_operand[col] = b_value;
        end
    end

    logic [TAG_WIDTH-MODE_BITS-1:0] tag_base;
    if (MX) begin : gen_tag_scale
        assign tag_base = {ACC_ENABLE ? matmul_mode : 2'd0, matmul_scale_a, matmul_preload};
    end else begin : gen_tag
        assign tag_base = {ACC_ENABLE ? matmul_mode : 2'd0, matmul_preload};
    end
    if (TILE_MODES) begin : gen_tag_tile
        assign tag_in = {matmul_tile, tag_base};
    end else begin : gen_tag_no_tile
        assign tag_in = tag_base;
    end
    fifo #(
        .DATA_WIDTH(TAG_WIDTH),
        .DEPTH(TAG_FIFO_DEPTH)
    ) u_tag (
        .clk,
        .rst,
        .w_en    (matmul_accept),
        .w_data  (tag_in),
        .w_rdy   (tag_fifo_wrdy),
        .r_en    (a_launch),
        .r_data  (tag_fifo_data),
        .r_valid (tag_fifo_rvalid),
        .level   ()
    );

    shifter #(
        .WIDTH(1),
        .LENGTH(1 + pe_shape::ENCODE_LATENCY)
    ) u_update_align (
        .clk,
        .rst,
        .en (1'b1),
        .d  (b_update_fire),
        .q  (b_update_aligned)
    );
    logic update_line [(DIM - 1) * ROW_SKEW + 1];
    logic pop_line    [DIM * ROW_SKEW + 1];
    shifter_taps #(
        .WIDTH(1),
        .LENGTH((DIM - 1) * ROW_SKEW)
    ) u_update_stagger (
        .clk,
        .rst,
        .en (1'b1),
        .d  (b_update_aligned),
        .q  (update_line)
    );
    shifter_taps #(
        .WIDTH(1),
        .LENGTH(DIM * ROW_SKEW)
    ) u_pop_stagger (
        .clk,
        .rst,
        .en (1'b1),
        .d  (a_launch),
        .q  (pop_line)
    );
    assign a_pop_wave[0] = pop_line[0];
    for (genvar row = 0; row < DIM; row++) begin : gen_waves
        assign b_update[row]       = update_line[row * ROW_SKEW];
        assign a_pop_wave[row + 1] = pop_line[1 + row * ROW_SKEW];
    end

    logic [1:0] tile_line [DIM * ROW_SKEW + 1];
    if (TILE_MODES && ENCODE) begin : gen_tile_line
        shifter_taps #(
            .WIDTH(2),
            .LENGTH(DIM * ROW_SKEW)
        ) u_tile_stagger (
            .clk,
            .rst,
            .en (1'b1),
            .d  (tag_fifo_data[TAG_WIDTH-1 -: 2]),
            .q  (tile_line)
        );
    end else begin : gen_no_tile_line
        assign tile_line = '{default: '0};
    end

    for (genvar row = 0; row < DIM; row++) begin : gen_a
        logic [A_CODES-1:0] codes;
        logic [$clog2(A_FIFO_DEPTH+1)-1:0] level;
        for (genvar j = 0; j < N_A; j++) begin : gen_code
            if (E2M1) begin : gen_e2m1
                assign codes[A_BITS*j +: A_BITS] = a_data[row][CODE_BITS*j +: CODE_BITS];
                e2m1_decode a_decoder (
                    .code  (a_in[row][j]),
                    .value (a_operand[row][j])
                );
            end else if (SUM_FLOAT || ENCODE) begin : gen_raw
                assign codes[A_BITS*j +: A_BITS] = a_data[row][CODE_BITS*j +: CODE_BITS];
            end else begin : gen_int
                int_code #(
                    .BITS(A_BITS),
                    .TWOS(1'b1),
                    .IN_BITS(CODE_BITS)
                ) u_code (
                    .int4 (a_data[row][CODE_BITS*j +: CODE_BITS]),
                    .code (codes[A_BITS*j +: A_BITS])
                );
            end
            if (ENCODE) begin : gen_encode
                a_encode #(
                    .A_BITS(A_BITS)
                ) u_encode (
                    .clk,
                    .code  (a_in[row][j]),
                    .mode  (tile_line[1 + row * ROW_SKEW]),
                    .value (a_operand[row][j])
                );
            end else if (!E2M1) begin : gen_operand
                assign a_operand[row][j] = a_in[row][j];
            end
            assign a_in[row][j] = a_fifo_data[row][A_BITS*j +: A_BITS];
        end
        fifo #(
            .DATA_WIDTH(A_CODES),
            .DEPTH(A_FIFO_DEPTH)
        ) u_fifo (
            .clk,
            .rst,
            .w_en    (a_valid[row] && a_ready[row]),
            .w_data  (codes),
            .w_rdy   (a_ready[row]),
            .r_en    (a_pop_wave[row + 1]),
            .r_data  (a_fifo_data[row]),
            .r_valid (a_fifo_valid[row]),
            .level   (level)
        );
        if (row == 0) begin : gen_level
            assign a_level = level;
        end
    end

    shifter #(
        .WIDTH(1),
        .LENGTH(RESULT_DELAY)
    ) u_result_delay (
        .clk,
        .rst,
        .en (1'b1),
        .d  (a_launch),
        .q  (psum_valid_first)
    );
    shifter_taps #(
        .WIDTH(1),
        .LENGTH(SPAN - 1)
    ) u_result_stagger (
        .clk,
        .rst,
        .en (1'b1),
        .d  (psum_valid_first),
        .q  (result_wave)
    );

    localparam int unsigned ACC_READ_LEAD = 2;
    logic [3:0] acc_ctrl_first;
    logic [3:0] acc_ctrl [SPAN];
    if (ACC_ENABLE) begin : gen_acc_ctrl
        shifter #(
            .WIDTH(4),
            .LENGTH(RESULT_DELAY - ACC_READ_LEAD)
        ) u_delay (
            .clk,
            .rst,
            .en (1'b1),
            .d  ({a_launch, tag_is_preload, tag_mode}),
            .q  (acc_ctrl_first)
        );
        shifter_taps #(
            .WIDTH(4),
            .LENGTH(SPAN - 1)
        ) u_stagger (
            .clk,
            .rst,
            .en (1'b1),
            .d  (acc_ctrl_first),
            .q  (acc_ctrl)
        );
    end else begin : gen_no_acc_ctrl
        assign acc_ctrl = '{default: '0};
    end

    pe_array #(
        .DIM(DIM),
        .N_W(N_W),
        .N_A(N_A),
        .A_BITS(A_OPERAND),
        .B_BITS(W_OPERAND),
        .P_BITS(PSUM_W),
        .PROD_BITS(PROD_W)
    ) u_array (
        .clk,
        .b_load,
        .b_update,
        .b_in (b_operand),
        .a_in (a_operand),
        .psum_out
    );

    logic [SCALE_WIDTH-1:0] scale_b [DIM];
    logic [SCALE_WIDTH-1:0] scale_a [SPAN][N_A];
    if (MX) begin : gen_mx
        logic                     b_scale_update [SPAN];
        logic [SCALE_A_WIDTH-1:0] scale_a_first;
        logic [SCALE_A_WIDTH-1:0] scale_a_wave [SPAN];

        for (genvar col = 0; col < DIM; col++) begin : gen_b_scale
            localparam int unsigned TAP = (col / N_W + 1) * N_W - 1;
            logic [SCALE_WIDTH-1:0] scale_now;
            mxu_b_scale #(
                .DIM(DIM)
            ) u_scale (
                .clk,
                .rst,
                .write        (b_valid[col]),
                .write_bank   (b_bank[col]),
                .write_scale  (b_data[col][CODE_BITS +: SCALE_WIDTH]),
                .preload      (preload_accept),
                .preload_bank (matmul_bank),
                .read         (b_load_wave[col] && b_fifo_bank_valid[b_load_bank_wave[col]][col]),
                .read_bank    (b_load_bank_wave[col]),
                .update       (b_scale_update[TAP]),
                .scale        (scale_now)
            );
            shifter #(
                .WIDTH(SCALE_WIDTH),
                .LENGTH(PRODUCT_DELAY)
            ) u_scale_b (
                .clk,
                .rst (1'b0),
                .en  (1'b1),
                .d   (scale_now),
                .q   (scale_b[col])
            );
        end

        shifter_taps #(
            .WIDTH(1),
            .LENGTH(SPAN - 1)
        ) u_scale_update (
            .clk,
            .rst,
            .en (1'b1),
            .d  (b_update_fire),
            .q  (b_scale_update)
        );
        shifter #(
            .WIDTH(SCALE_A_WIDTH),
            .LENGTH(PRODUCT_DELAY)
        ) u_scale_a (
            .clk,
            .rst,
            .en (1'b1),
            .d  (tag_fifo_data[1 +: SCALE_A_WIDTH]),
            .q  (scale_a_first)
        );
        shifter_taps #(
            .WIDTH(SCALE_A_WIDTH),
            .LENGTH(SPAN - 1)
        ) u_scale_a_wave (
            .clk,
            .rst,
            .en (1'b1),
            .d  (scale_a_first),
            .q  (scale_a_wave)
        );
        for (genvar col = 0; col < SPAN; col++) begin : gen_scale_a
            for (genvar j = 0; j < N_A; j++) begin : gen_row
                assign scale_a[col][j] = scale_a_wave[col][SCALE_WIDTH*j +: SCALE_WIDTH];
            end
        end

    end else begin : gen_unit_scales
        assign scale_b = '{default: SCALE_WIDTH'(127)};
        assign scale_a = '{default: '{default: SCALE_WIDTH'(127)}};
    end

    for (genvar col = 0; col < DIM; col++) begin : gen_output
        localparam int unsigned TAP  = (col / N_W + 1) * N_W - 1;
        localparam int unsigned IN_W = !FLOAT_OUT ? PSUM_W : PRODUCT_FP32 ? 32 : BF16_WIDTH;
        logic [IN_W-1:0] product [N_A];

        for (genvar j = 0; j < N_A; j++) begin : gen_product
            if (SUM_FLOAT && !SUM_OWN) begin : gen_sum_float
                logic [BF16_WIDTH-1:0] bf16;
                sum_impl #(
                    .P_BITS(PSUM_W)
                ) u_sum (
                    .sum   (psum_out[col][j]),
                    .value (bf16)
                );
                assign product[j] = PRODUCT_FP32 ? IN_W'({bf16, 16'h0000}) : IN_W'(bf16);
            end else if (FLOAT) begin : gen_scale
                mx_to_float #(
                    .DOT_WIDTH(PSUM_W),
                    .BIAS(E2M1 ? 256 : 254),
                    .FP32(PRODUCT_FP32)
                ) u_scale (
                    .clk,
                    .raw_dot (psum_out[col][j]),
                    .scale_a (scale_a[TAP][j]),
                    .scale_b (scale_b[col]),
                    .value   (product[j])
                );
            end else begin : gen_int
                assign product[j] = psum_out[col][j];
            end
        end

        mxu_output #(
            .ROWS(N_A),
            .IN_W(IN_W),
            .FLOAT(FLOAT_OUT),
            .SUM(SUM_OWN),
            .SUM_STAGES(pe_shape::ACC_STAGES),
            .ACC_ENABLE(ACC_ENABLE),
            .ACC_ROWS(ACC_ROWS),
            .ACC_FP32(ACC_FP32)
        ) u_output (
            .clk,
            .rst,
            .ctrl_valid    (acc_ctrl[TAP][3]),
            .ctrl_first    (acc_ctrl[TAP][2]),
            .ctrl_mode     (acc_ctrl[TAP][1:0]),
            .product_valid (result_wave[TAP]),
            .product,
            .psum_valid    (psum_valid[col]),
            .psum_data     (psum_data[col])
        );
    end
endmodule : mxu
