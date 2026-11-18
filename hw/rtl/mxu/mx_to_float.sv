// dot * 2^(scale_a + scale_b - BIAS), rounded once to binary32 or BF16; a scale of 0xff is NaN. 4 cycles.
module mx_to_float #(
    parameter int unsigned  DOT_WIDTH   = 14,
    parameter int unsigned  BIAS        = 256,
    parameter bit           FP32        = 1'b0,
    localparam int unsigned SCALE_WIDTH = 8,
    localparam int unsigned E_WIDTH     = SCALE_WIDTH + 1,
    localparam int unsigned OUT_WIDTH   = FP32 ? 32 : 16
) (
    input  logic                         clk,
    input  logic signed [DOT_WIDTH-1:0]  raw_dot,
    input  logic [SCALE_WIDTH-1:0]       scale_a,
    input  logic [SCALE_WIDTH-1:0]       scale_b,
    output logic [OUT_WIDTH-1:0]         value
);
    logic signed [E_WIDTH-1:0] exponent;
    logic                      is_zero;
    logic                      is_nan;

    always_comb begin
        is_nan   = scale_a == 8'hff || scale_b == 8'hff;
        is_zero  = raw_dot == '0 && !is_nan;
        exponent = is_nan ? 9'sd0 : 9'($signed({2'b00, scale_a}) + $signed({2'b00, scale_b}) - $signed(10'(BIAS)));
    end

    if (FP32) begin : gen_fp32
        scaled_int_to_fp32 #(
            .N_WIDTH(DOT_WIDTH),
            .E_WIDTH(E_WIDTH)
        ) converter (
            .clk,
            .significand (raw_dot),
            .exponent,
            .is_nan,
            .fp32        (value)
        );
    end else begin : gen_bf16
        scaled_int_to_bf16 #(
            .N_WIDTH(DOT_WIDTH),
            .E_WIDTH(E_WIDTH)
        ) converter (
            .clk,
            .significand (raw_dot),
            .exponent,
            .is_zero,
            .is_nan,
            .bf16        (value)
        );
    end
endmodule : mx_to_float
