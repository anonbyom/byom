// One lane's EUP function pipelines: WIDTH copies of log2, pow2, reciprocal/rsqrt, tanh/sigmoid (latency 5).
module eup_functions #(
    parameter int unsigned ELEMENT_WIDTH = isa_pkg::VECTOR_ELEMENT_WIDTH,
    parameter int unsigned WIDTH         = 1,
    parameter int unsigned BEAT_W        = 2
) (
    input  logic                     clk,
    input  logic                     operand_valid,
    input  logic [1:0]               operand_unit,     // 0 log2, 1 pow2, 2 reciprocal/rsqrt, 3 tanh/sigmoid
    input  logic                     operand_variant,  // rsqrt / shifted sigmoid
    input  logic [BEAT_W-1:0]        operand_beat,
    input  logic [ELEMENT_WIDTH-1:0] operand        [WIDTH],
    output logic                     result_valid,
    output logic [BEAT_W-1:0]        result_beat,
    output logic [ELEMENT_WIDTH-1:0] result         [WIDTH]
);
    localparam int unsigned LATENCY = 5;

    logic [1:0] result_unit;

    shifter #(
        .WIDTH(2 + BEAT_W),
        .LENGTH(LATENCY)
    ) u_tag (
        .clk,
        .rst (1'b0),
        .en  (1'b1),
        .d   ({operand_unit, operand_beat}),
        .q   ({result_unit, result_beat})
    );

    for (genvar p = 0; p < WIDTH; p++) begin : gen_pipe
        logic                     valid;
        logic [ELEMENT_WIDTH-1:0] log2_result;
        logic [ELEMENT_WIDTH-1:0] pow2_result;
        logic [ELEMENT_WIDTH-1:0] reciprocal_result;
        logic [ELEMENT_WIDTH-1:0] tanh_result;

        bf16_log2 u_log2 (
            .clk,
            .rst(1'b0),
            .in_valid (operand_valid),
            .a        (operand[p]),
            .out_valid(valid),
            .result   (log2_result)
        );

        bf16_pow2 u_pow2 (
            .clk,
            .rst(1'b0),
            .in_valid (operand_valid),
            .a        (operand[p]),
            .out_valid(),
            .result   (pow2_result)
        );

        // 1/x (variant 0) or 1/sqrt(x).
        bf16_reciprocal u_reciprocal (
            .clk,
            .rst(1'b0),
            .in_valid (operand_valid),
            .rsqrt    (operand_variant),
            .a        (operand[p]),
            .out_valid(),
            .result   (reciprocal_result)
        );

        // tanh (variant 0) or sigmoid - 1/2.
        bf16_tanh u_tanh (
            .clk,
            .rst(1'b0),
            .in_valid (operand_valid),
            .sigmoid  (operand_variant),
            .a        (operand[p]),
            .out_valid(),
            .result   (tanh_result)
        );

        always_comb
            case (result_unit)
                2'd0:    result[p] = log2_result;
                2'd1:    result[p] = pow2_result;
                2'd2:    result[p] = reciprocal_result;
                default: result[p] = tanh_result;
            endcase

        if (p == 0) begin : gen_valid
            assign result_valid = valid;
        end
    end
endmodule : eup_functions
