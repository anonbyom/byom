// One output column's accumulator, entry e = beat e of the block: EMIT out = p, FIRST acc[e] = p,
// ACCUM acc[e] += p, LAST out = acc[e] + p. Sums in BF16, binary32 (FP32), integers (INT) or the PE's (SUM).
module mxu_accumulator #(
    parameter int unsigned  DEPTH         = 512,
    parameter bit           FP32          = 1'b0,
    parameter bit           INT           = 1'b0,
    parameter int unsigned  INT_WIDTH     = 12,
    parameter bit           SUM           = 1'b0,
    parameter int unsigned  SUM_WIDTH     = 17,
    parameter int unsigned  SUM_STAGES    = 1,
    parameter int unsigned  ROWS          = 2,
    localparam int unsigned PRODUCT_WIDTH = INT ? INT_WIDTH : SUM ? SUM_WIDTH : FP32 ? 32 : 16,
    localparam int unsigned ACC_WIDTH     = INT ? 32 : SUM ? SUM_WIDTH : FP32 ? 32 : 16,
    localparam int unsigned OUT_LATENCY   = INT ? 1 : 0,
    localparam int unsigned ADDR_W        = $clog2(DEPTH),
    localparam int unsigned READ_LEAD     = 2,
    localparam int unsigned ADD_LATENCY   = 4,
    localparam int unsigned LATENCY       = ADD_LATENCY + 1,
    localparam int unsigned READ_TO_WRITE = READ_LEAD + LATENCY + 1
) (
    input  logic              clk,
    input  logic              rst,

    input  logic              ctrl_valid,
    input  logic              ctrl_first,
    input  logic [1:0]        ctrl_mode,

    input  logic              product_valid,
    input  logic [PRODUCT_WIDTH-1:0] product [ROWS],

    output logic              out_valid,
    output logic [15:0]       out_data [ROWS],
    output logic [ACC_WIDTH-1:0] out_int [ROWS]
);
    localparam logic [1:0] EMIT = 2'd0, FIRST = 2'd1, ACCUM = 2'd2, LAST = 2'd3;

    typedef struct packed {
        logic              valid;
        logic [1:0]        mode;
        logic [ADDR_W-1:0] addr;
    } beat_t;

    logic [ADDR_W-1:0] pointer_q;
    logic [ADDR_W-1:0] read_addr;
    beat_t             lead_in;
    beat_t             lead [READ_LEAD + 1];
    beat_t             beat;
    beat_t             done;
    logic [ROWS*ACC_WIDTH-1:0] mem [DEPTH];
    logic [ROWS*ACC_WIDTH-1:0] read_q;
    logic [ROWS*ACC_WIDTH-1:0] read_data;
    logic [ACC_WIDTH-1:0]      sum [ROWS];
    logic [ACC_WIDTH-1:0]      sum_q [ROWS];
    logic [ACC_WIDTH-1:0]      bypass [ROWS];
    logic [ROWS*ACC_WIDTH-1:0] sum_word;
    logic              write_en;
    beat_t             done_d;

    assign read_addr = ctrl_first ? '0 : pointer_q + 1'b1;
    always_ff @(posedge clk) begin
        if (ctrl_valid) pointer_q <= read_addr;
    end

    assign lead_in = '{valid: ctrl_valid, mode: ctrl_mode, addr: read_addr};
    shifter_taps #(
        .WIDTH($bits(beat_t)),
        .LENGTH(READ_LEAD)
    ) u_lead (
        .clk,
        .rst,
        .en (1'b1),
        .d  (lead_in),
        .q  (lead)
    );
    assign beat = lead[READ_LEAD];

    always_ff @(posedge clk) begin
        if (write_en) mem[done.addr] <= sum_word;
        read_q    <= mem[read_addr];
        read_data <= read_q;
    end

    for (genvar row = 0; row < ROWS; row++) begin : gen_row
        logic [ACC_WIDTH-1:0] product_wide;
        if (INT) begin : gen_int_product
            assign product_wide = ACC_WIDTH'($signed(product[row]));
        end else begin : gen_float_product
            assign product_wide = product[row];
        end
        assign sum_word[ACC_WIDTH*row +: ACC_WIDTH] = sum_q[row];
        if (INT) begin : gen_int
            logic [ACC_WIDTH-1:0] exact_sum;
            assign exact_sum = read_data[ACC_WIDTH*row +: ACC_WIDTH] + product_wide;
            shifter #(
                .WIDTH(ACC_WIDTH),
                .LENGTH(ADD_LATENCY)
            ) u_pipe (
                .clk,
                .rst (1'b0),
                .en  (1'b1),
                .d   (exact_sum),
                .q   (sum[row])
            );
            int_to_bf16 #(
                .WIDTH(ACC_WIDTH)
            ) u_bf16 (
                .clk,
                .value (sum_q[row]),
                .bf16  (out_data[row])
            );
        end else if (SUM) begin : gen_sum
            logic [ACC_WIDTH-1:0] added;
            add_impl #(
                .P_BITS(ACC_WIDTH),
                .PROD_BITS(ACC_WIDTH)
            ) u_add (
                .clk,
                .psum_in (read_data[ACC_WIDTH*row +: ACC_WIDTH]),
                .ones    (product_wide),
                .carry   (1'b0),
                .psum    (added)
            );
            shifter #(
                .WIDTH(ACC_WIDTH),
                .LENGTH(ADD_LATENCY - SUM_STAGES)
            ) u_pipe (
                .clk,
                .rst (1'b0),
                .en  (1'b1),
                .d   (added),
                .q   (sum[row])
            );
            sum_impl #(
                .P_BITS(ACC_WIDTH)
            ) u_out (
                .sum   (sum_q[row]),
                .value (out_data[row])
            );
        end else if (FP32) begin : gen_fp32
            fp32_add u_add (
                .clk,
                .rst,
                .in_valid  (product_valid),
                .a         (read_data[ACC_WIDTH*row +: ACC_WIDTH]),
                .b         (product_wide),
                .out_valid (),
                .sum       (sum[row])
            );
            fp32_to_bf16 u_round (
                .value (sum_q[row]),
                .bf16  (out_data[row])
            );
        end else begin : gen_bf16
            bf16_adder u_add (
                .clk,
                .rst,
                .in_valid  (product_valid),
                .a         (read_data[ACC_WIDTH*row +: ACC_WIDTH]),
                .b         (product_wide),
                .out_valid (),
                .sum       (sum[row])
            );
            assign out_data[row] = sum_q[row];
        end
        shifter #(
            .WIDTH(ACC_WIDTH),
            .LENGTH(ADD_LATENCY)
        ) u_bypass (
            .clk,
            .rst (1'b0),
            .en  (1'b1),
            .d   (product_wide),
            .q   (bypass[row])
        );
        always_ff @(posedge clk)
            sum_q[row] <= (done_d.mode == EMIT || done_d.mode == FIRST) ? bypass[row] : sum[row];
        shifter #(
            .WIDTH(ACC_WIDTH),
            .LENGTH(OUT_LATENCY)
        ) u_out_int (
            .clk,
            .rst (1'b0),
            .en  (1'b1),
            .d   (sum_q[row]),
            .q   (out_int[row])
        );
    end

    shifter #(
        .WIDTH($bits(beat_t)),
        .LENGTH(ADD_LATENCY)
    ) u_track (
        .clk,
        .rst,
        .en (1'b1),
        .d  (beat),
        .q  (done_d)
    );
    always_ff @(posedge clk) done <= done_d;

    assign write_en  = done.valid && (done.mode == FIRST || done.mode == ACCUM);
    shifter #(
        .WIDTH(1),
        .LENGTH(OUT_LATENCY)
    ) u_out_valid (
        .clk,
        .rst,
        .en (1'b1),
        .d  (done.valid && (done.mode == EMIT || done.mode == LAST)),
        .q  (out_valid)
    );

endmodule : mxu_accumulator
