module unbuffered_serializer #(
    parameter int unsigned SRC_WIDTH = 128,
    parameter int unsigned DST_WIDTH = 32,
    localparam int unsigned WORDS = SRC_WIDTH / DST_WIDTH,
    localparam int unsigned INDEX_W = WORDS > 1 ? $clog2(WORDS) : 1
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
    logic last;
    logic [INDEX_W-1:0] index_q;

    assign last = index_q == INDEX_W'(WORDS-1);
    assign src_ready = dst_ready && last;
    assign dst_valid = src_valid;
    assign dst_data = src_data[DST_WIDTH*index_q +: DST_WIDTH];

    always_ff @(posedge clk) begin
        if (rst) index_q <= '0;
        else if (dst_valid && dst_ready) begin
            if (last) index_q <= '0;
            else index_q <= index_q + 1'b1;
        end
    end

    initial begin
        if (SRC_WIDTH < DST_WIDTH || SRC_WIDTH % DST_WIDTH != 0) $fatal(1, "serializer requires an integer width ratio");
    end
endmodule
