// BF16 block -> E8M0 scale + MXFP4 codes, each value waits in a delay line for its block's scale.
module bf16_block_quantize #(
    parameter int unsigned BLOCK_SIZE = 32,
    localparam int unsigned SCALE_LATENCY = $clog2(BLOCK_SIZE) + 2
) (
    input  logic                        clk,
    input  logic                        rst,
    input  logic                        in_valid,
    input  logic [BLOCK_SIZE-1:0][15:0] values,
    output logic                        out_valid,
    output logic                        lane_valid [BLOCK_SIZE],
    output logic [7:0]                  scale,
    output logic [BLOCK_SIZE-1:0][3:0]  mxfp4
);
    logic                  scale_valid;
    logic [7:0]            block_scale;
    logic [BLOCK_SIZE-1:0] converted_valid;

    bf16_block_scale #(
        .BLOCK_SIZE(BLOCK_SIZE)
    ) u_block_scale (
        .clk,
        .rst,
        .in_valid,
        .values,
        .out_valid (scale_valid),
        .scale     (block_scale)
    );

    for (genvar lane = 0; lane < BLOCK_SIZE; lane++) begin : gen_convert
        logic [15:0] delayed_value;

        shifter #(
            .WIDTH(16),
            .LENGTH(SCALE_LATENCY)
        ) u_values_delay (
            .clk,
            .rst (1'b0),
            .en  (1'b1),
            .d   (values[lane]),
            .q   (delayed_value)
        );

        bf16_to_mxfp4 u_convert (
            .clk,
            .rst,
            .in_valid  (scale_valid),
            .bf16      (delayed_value),
            .scale     (block_scale),
            .out_valid (converted_valid[lane]),
            .mxfp4     (mxfp4[lane])
        );
        assign lane_valid[lane] = converted_valid[lane];
    end

    shifter #(
        .WIDTH(8),
        .LENGTH(4)
    ) u_scale_delay (
        .clk,
        .rst (1'b0),
        .en  (1'b1),
        .d   (block_scale),
        .q   (scale)
    );

    assign out_valid = converted_valid[0];
endmodule : bf16_block_quantize
