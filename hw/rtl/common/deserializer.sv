module deserializer #(
    parameter int unsigned SRC_WIDTH = 32,
    parameter int unsigned DST_WIDTH = 128,

    localparam int unsigned WORDS    = DST_WIDTH / SRC_WIDTH,
    localparam int unsigned COUNT_W  = $clog2(WORDS + 1),
    localparam int unsigned INDEX_W  = WORDS > 1 ? $clog2(WORDS) : 1
) (
    input  logic                 clk,
    input  logic                 rst,
    input  logic [SRC_WIDTH-1:0] src_data,
    input  logic                 src_valid,
    output logic                 src_ready,
    output logic [DST_WIDTH-1:0] dst_data,
    output logic                 dst_valid,
    input  logic                 dst_ready
);
    logic [SRC_WIDTH-1:0] data_q  [WORDS];
    logic [COUNT_W-1:0]   count_q;

    assign dst_valid = count_q == COUNT_W'(WORDS);
    assign src_ready = !dst_valid || dst_ready;

    for (genvar word = 0; word < WORDS; word++) begin : gen_word
        assign dst_data[SRC_WIDTH*word +: SRC_WIDTH] = data_q[word];
    end

    always_ff @(posedge clk) begin
        if (rst) count_q <= '0;
        else if (src_valid && src_ready) begin
            count_q <= dst_valid ? COUNT_W'(1) : count_q + 1'b1;
            data_q[dst_valid ? INDEX_W'(0) : INDEX_W'(count_q)] <= src_data;
        end else if (dst_valid && dst_ready) count_q <= '0;
    end

    initial begin
        if (DST_WIDTH < SRC_WIDTH || DST_WIDTH % SRC_WIDTH != 0) $fatal(1, "deserializer requires an integer width ratio");
    end
endmodule
