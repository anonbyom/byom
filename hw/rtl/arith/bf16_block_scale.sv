// E8M0 block scale of BLOCK_SIZE BF16 values: absmax tree, then the scale (latency log2(BLOCK_SIZE) + 2).
module bf16_block_scale #(
    parameter int unsigned BLOCK_SIZE = 32
) (
    input  logic                        clk,
    input  logic                        rst,
    input  logic                        in_valid,
    input  logic [BLOCK_SIZE-1:0][15:0] values,
    output logic                        out_valid,
    output logic [7:0]                  scale
);
    logic        reduction_valid;
    logic [15:0] maximum;

    bf16_absmax_reduction #(.SIZE(BLOCK_SIZE)) absmax (
        .clk,
        .rst,
        .in_valid,
        .values,
        .out_valid (reduction_valid),
        .maximum
    );

    bf16_scale_from_max u_scale (
        .clk,
        .rst,
        .in_valid (reduction_valid),
        .maximum,
        .out_valid,
        .scale
    );
endmodule : bf16_block_scale
