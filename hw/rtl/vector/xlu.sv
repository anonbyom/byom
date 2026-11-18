// XLU: transpose (TRANSPOSE_*), cross-lane add/max/min (XLANE_*) and, with XLU_QUANTIZE, XLANE_QUANTIZE.
module xlu #(
    parameter int unsigned LANES            = 32,
    parameter int unsigned SUBLANES         = 4,
    parameter int unsigned WIDTH            = 16,
    parameter bit XLU_QUANTIZE              = 1'b0,
    parameter int unsigned XLU_REDUCE_TREES = 1,

    localparam int unsigned TILES = LANES / SUBLANES,
    localparam int unsigned TILE_W = $clog2(TILES),
    localparam int unsigned TREE_W = XLU_REDUCE_TREES > 1 ? $clog2(XLU_REDUCE_TREES) : 1
) (
    input  logic clk,
    input  logic rst,
    input  logic in_valid [LANES],
    input  logic [SUBLANES*WIDTH-1:0] in_data [LANES],
    input  logic [1:0] in_func,             // lane LANES-1: 0 tile row, 1 add, 2 max, 3 min
    input  logic [2:0] in_quantize,         // lane LANES-1: {WT, W orientation, quantize}
    output logic out_valid,
    output logic [SUBLANES*WIDTH-1:0] out_data [LANES]
);
    logic aligned_valid [LANES];
    logic [SUBLANES*WIDTH-1:0] aligned_data [LANES];
    logic [WIDTH-1:0] a [TILES][SUBLANES*SUBLANES];
    logic [WIDTH-1:0] at [SUBLANES][LANES];
    logic [TILE_W-1:0] fill_q, drain_q;
    logic draining_q;
    logic fill;
    (* max_fanout = 256 *) logic tile_fill_q, tile_drain_q;

    // remove the issue skew between lanes.
    for (genvar lane = 0; lane < LANES; lane++) begin : gen_align
        shifter #(
            .WIDTH(1 + SUBLANES*WIDTH),
            .LENGTH(LANES-lane)
        ) u_data (
            .clk,
            .rst (1'b0),
            .en  (1'b1),
            .d   ({in_valid[lane], in_data[lane]}),
            .q   ({aligned_valid[lane], aligned_data[lane]})
        );
        for (genvar row = 0; row < SUBLANES; row++) begin : gen_pack
            assign a[lane/SUBLANES][row*SUBLANES+lane%SUBLANES] = aligned_data[lane][row*WIDTH +: WIDTH];
        end
    end

    logic [1:0] aligned_func;
    logic [2:0] aligned_quantize;
    logic reduce_in;
    logic [TREE_W-1:0] tree_q;
    logic tree_valid [XLU_REDUCE_TREES];
    logic [SUBLANES*WIDTH-1:0] tree_data [XLU_REDUCE_TREES];
    logic reduce_valid;
    logic [SUBLANES*WIDTH-1:0] reduce_data;

    assign reduce_in = aligned_valid[LANES-1] && aligned_func != 0 && !aligned_quantize[0];

    always_ff @(posedge clk) begin
        {aligned_quantize, aligned_func} <= {XLU_QUANTIZE ? in_quantize : 3'b000, in_func};
        if (XLU_REDUCE_TREES > 1 && reduce_in) tree_q <= tree_q + 1'b1;
    end

    for (genvar t = 0; t < XLU_REDUCE_TREES; t++) begin : gen_tree
        xlu_reduce #(
            .LANES(LANES),
            .SUBLANES(SUBLANES),
            .WIDTH(WIDTH)
        ) u_reduce (
            .clk,
            .rst,
            .in_valid  (reduce_in && (XLU_REDUCE_TREES == 1 || int'(tree_q) == t)),
            .in_func   (aligned_func),
            .in_data   (aligned_data),
            .out_valid (tree_valid[t]),
            .out_data  (tree_data[t])
        );
    end

    // at most one tree finishes per cycle (vector_issue reserves distinct exits).
    always_comb begin
        reduce_valid = 1'b0;
        reduce_data = tree_data[0];
        for (int t = 0; t < XLU_REDUCE_TREES; t++)
            if (tree_valid[t]) begin
                reduce_valid = 1'b1;
                reduce_data = tree_data[t];
            end
    end

    logic quant_valid;
    logic [SUBLANES*WIDTH-1:0] quant_data [LANES];
    if (XLU_QUANTIZE) begin : gen_quantize
        xlu_quantize #(
            .LANES(LANES),
            .SUBLANES(SUBLANES),
            .WIDTH(WIDTH)
        ) u_quantize (
            .clk,
            .in_valid      (aligned_valid[LANES-1] && aligned_quantize[0]),
            .in_weight     (aligned_quantize[1]),
            .in_transposed (aligned_quantize[1] && aligned_quantize[2]),
            .in_data       (aligned_data),
            .out_valid     (quant_valid),
            .out_data      (quant_data)
        );
    end else begin : gen_no_quantize
        assign quant_valid = 1'b0;
        assign quant_data = '{default: '0};
    end

    assign fill = aligned_valid[LANES-1] && aligned_func == 0;

    transpose #(
        .TILE_DIM(SUBLANES),
        .TILES(TILES),
        .WIDTH(WIDTH)
    ) u_tile (
        .clk,
        .fill  (tile_fill_q),
        .drain (tile_drain_q),
        .a,
        .at
    );

    // Registered in SLR2 before crossing back to the lanes; reductions go to every lane.
    for (genvar lane = 0; lane < LANES; lane++) begin : gen_output
        for (genvar row = 0; row < SUBLANES; row++) begin : gen_row
            always_ff @(posedge clk)
                out_data[lane][row*WIDTH +: WIDTH] <= quant_valid  ? quant_data[lane][row*WIDTH +: WIDTH] :
                                                      reduce_valid ? reduce_data[row*WIDTH +: WIDTH] : at[row][lane];
        end
    end

    // A tile fills over TILES beats, then drains over the next TILES cycles.
    logic fill_last, drain_last, draining_d;
    assign fill_last  = fill && fill_q == TILE_W'(TILES-1);
    assign drain_last = draining_q && drain_q == TILE_W'(TILES-1);
    assign draining_d = !drain_last && (fill_last || draining_q);

    always_ff @(posedge clk) begin
        if (fill) fill_q <= fill_q + 1'b1;
        if (draining_q) drain_q <= drain_q + 1'b1;
        draining_q   <= draining_d;
        out_valid    <= draining_q || reduce_valid || quant_valid;
        tile_fill_q  <= in_valid[LANES-1] && in_func == 0;
        tile_drain_q <= draining_d;
    end
endmodule : xlu
