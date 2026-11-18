// A pipelined FP32 add tree (rounded once to BF16) or a BF16 min/max tree.
module xlu_reduce #(
    parameter int unsigned LANES    = 32,
    parameter int unsigned SUBLANES = 4,
    parameter int unsigned WIDTH    = 16,
    localparam int unsigned LEVELS  = $clog2(LANES),
    localparam int unsigned LATENCY = LEVELS * 5 + 1   // fp32_add 4 stages + register a level, then the rounding
) (
    input  logic                         clk,
    input  logic                         rst,
    input  logic                         in_valid,
    input  logic [1:0]                   in_func,          // 1 add, 2 max, 3 min
    input  logic [SUBLANES*WIDTH-1:0]    in_data [LANES],
    output logic                         out_valid,
    output logic [SUBLANES*WIDTH-1:0]    out_data
);
    localparam logic [1:0] FUNC_ADD = 2'd1, FUNC_MIN = 2'd3;
    localparam int unsigned COUNT_W = $clog2(SUBLANES + 1);

    logic [SUBLANES*WIDTH-1:0] hold_q [LANES];
    logic [1:0]                func_q;
    logic [COUNT_W-1:0]        feed_q;             // sublanes left to feed
    logic                      feed_valid;

    assign feed_valid = feed_q != 0;

    always_ff @(posedge clk) begin
        if (in_valid) func_q <= in_func;
        for (int lane = 0; lane < LANES; lane++)
            hold_q[lane] <= in_valid ? in_data[lane] : hold_q[lane] >> WIDTH;
        if (rst) feed_q <= '0;
        else if (in_valid) feed_q <= COUNT_W'(SUBLANES);
        else if (feed_valid) feed_q <= feed_q - 1'b1;
    end

    logic [31:0]      add_level [LEVELS+1][LANES];
    logic [WIDTH-1:0] cmp_level [LEVELS+1][LANES];
    logic             min_level [LEVELS+1];

    for (genvar lane = 0; lane < LANES; lane++) begin : gen_leaf
        assign add_level[0][lane] = {hold_q[lane][WIDTH-1:0], 16'h0000};
        assign cmp_level[0][lane] = hold_q[lane][WIDTH-1:0];
    end
    assign min_level[0] = func_q == FUNC_MIN;

    for (genvar level = 0; level < LEVELS; level++) begin : gen_level
        localparam int unsigned NODES = LANES >> (level + 1);
        always_ff @(posedge clk) min_level[level+1] <= min_level[level];
        for (genvar node = 0; node < NODES; node++) begin : gen_node
            logic [31:0] sum;
            logic [WIDTH-1:0] minimum, maximum;
            fp32_add u_add (
                .clk,
                .rst       (1'b0),
                .in_valid  (1'b0),
                .a         (add_level[level][2*node]),
                .b         (add_level[level][2*node+1]),
                .out_valid (),
                .sum
            );
            bf16_compare u_compare (
                .a         (cmp_level[level][2*node]),
                .b         (cmp_level[level][2*node+1]),
                .less      (),
                .equal     (),
                .greater   (),
                .unordered (),
                .minimum,
                .maximum
            );
            always_ff @(posedge clk) begin
                add_level[level+1][node] <= sum;
                cmp_level[level+1][node] <= min_level[level] ? minimum : maximum;
            end
        end
        for (genvar node = NODES; node < LANES; node++) begin : gen_unused
            assign add_level[level+1][node] = '0;
            assign cmp_level[level+1][node] = '0;
        end
    end

    logic [WIDTH-1:0] rounded, add_result;
    fp32_to_bf16 u_round (.value(add_level[LEVELS][0]), .bf16(rounded));
    always_ff @(posedge clk) add_result <= rounded;

    logic [WIDTH-1:0] cmp_result;
    logic [1:0]       result_func;
    logic             result_valid;

    shifter #(
        .WIDTH(WIDTH),
        .LENGTH(LATENCY - LEVELS)
    ) u_cmp_delay (
        .clk,
        .rst (1'b0),
        .en  (1'b1),
        .d   (cmp_level[LEVELS][0]),
        .q   (cmp_result)
    );
    shifter #(
        .WIDTH(3),
        .LENGTH(LATENCY)
    ) u_tag_delay (
        .clk,
        .rst (1'b0),
        .en  (1'b1),
        .d   ({feed_valid, func_q}),
        .q   ({result_valid, result_func})
    );

    // The sublane results arrive on consecutive cycles: shift them in every cycle, valid after the last.
    logic [$clog2(SUBLANES)-1:0] collected_q;
    (* max_fanout = 128 *) logic valid_q;
    assign out_valid = valid_q;
    always_ff @(posedge clk) begin
        out_data <= {result_func == FUNC_ADD ? add_result : cmp_result, out_data[SUBLANES*WIDTH-1:WIDTH]};
        valid_q <= result_valid && collected_q == $clog2(SUBLANES)'(SUBLANES - 1);
        if (result_valid) collected_q <= collected_q + 1'b1;
    end
endmodule : xlu_reduce
