// One entry of SUBLANES elements in, OUTPUT_WIDTH bits out per cycle (low bits first, leftover element bits unused).
module lane_serializer #(
    parameter int unsigned SUBLANES       = 4,
    parameter int unsigned INPUT_WIDTH    = 32,
    parameter int unsigned OUTPUT_WIDTH   = 8,
    parameter int unsigned TAG_WIDTH      = 2,
    parameter int unsigned DEPTH          = 4,

    localparam int unsigned ELEMENTS      = INPUT_WIDTH >= OUTPUT_WIDTH ? INPUT_WIDTH / OUTPUT_WIDTH : 1,
    localparam int unsigned SUBLANE_STEP  = OUTPUT_WIDTH > INPUT_WIDTH ? OUTPUT_WIDTH / INPUT_WIDTH : 1,
    localparam int unsigned DATA_WIDTH    = SUBLANES * INPUT_WIDTH,
    localparam int unsigned ENTRY_WIDTH   = DATA_WIDTH + TAG_WIDTH,
    localparam int unsigned SUBLANE_WIDTH = SUBLANES > 1 ? $clog2(SUBLANES) : 1,
    localparam int unsigned ELEM_WIDTH    = ELEMENTS > 1 ? $clog2(ELEMENTS) : 1
) (
    input  logic                       clk,
    input  logic                       rst,

    input  logic                       in_valid,
    output logic                       in_ready,
    input  logic [INPUT_WIDTH-1:0]     in_data   [SUBLANES],
    input  logic [TAG_WIDTH-1:0]       in_tag,

    output logic                       out_valid,
    input  logic                       out_ready,
    output logic [OUTPUT_WIDTH-1:0]    out_data,
    output logic [TAG_WIDTH-1:0]       out_tag,

    output logic [$clog2(DEPTH+1)-1:0] level,
    output logic                       drained
);
    logic [ENTRY_WIDTH-1:0]   fifo_wdata;
    logic [ENTRY_WIDTH-1:0]   fifo_rdata;
    logic                     fifo_valid;
    logic                     fifo_pop;
    logic [SUBLANE_WIDTH-1:0] sublane_q;
    logic [ELEM_WIDTH-1:0]    element_q;

    for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_pack
        assign fifo_wdata[sublane*INPUT_WIDTH +: INPUT_WIDTH] = in_data[sublane];
    end
    assign fifo_wdata[DATA_WIDTH +: TAG_WIDTH] = in_tag;
    assign out_valid = fifo_valid;
    assign out_data  = fifo_rdata[sublane_q*INPUT_WIDTH + element_q*OUTPUT_WIDTH +: OUTPUT_WIDTH];
    assign out_tag   = fifo_rdata[DATA_WIDTH +: TAG_WIDTH];
    assign fifo_pop  = out_valid && out_ready &&
                       sublane_q == SUBLANE_WIDTH'(SUBLANES-SUBLANE_STEP) && element_q == ELEM_WIDTH'(ELEMENTS-1);
    assign drained = fifo_pop;

    fifo #(
        .DATA_WIDTH(ENTRY_WIDTH),
        .DEPTH(DEPTH),
        .READ_READY_BYPASS(DEPTH == 1)
    ) u_fifo (
        .clk,
        .rst,
        .w_en   (in_valid),
        .w_data (fifo_wdata),
        .w_rdy  (in_ready),
        .r_en   (fifo_pop),
        .r_data (fifo_rdata),
        .r_valid(fifo_valid),
        .level
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            sublane_q <= '0;
            element_q <= '0;
        end else if (out_valid && out_ready) begin
            if (fifo_pop) begin
                sublane_q <= '0;
                element_q <= '0;
            end else if (element_q == ELEM_WIDTH'(ELEMENTS-1)) begin
                element_q <= '0;
                if (sublane_q == SUBLANE_WIDTH'(SUBLANES-SUBLANE_STEP)) sublane_q <= '0;
                else sublane_q <= sublane_q + SUBLANE_WIDTH'(SUBLANE_STEP);
            end else begin
                element_q <= element_q + 1'b1;
            end
        end
    end
endmodule
