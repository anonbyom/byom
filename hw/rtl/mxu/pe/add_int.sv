package add_shape;
    localparam int unsigned STAGES  = 1;
    localparam bit          FLOAT   = 1'b0;
    localparam logic        ZERO    = 1'b0;
    localparam bit          ACC_OWN = 1'b0;
endpackage : add_shape

module add_impl #(
    parameter int unsigned P_BITS    = 12,
    parameter int unsigned PROD_BITS = 8
) (
    input  logic                        clk,
    input  logic signed [P_BITS-1:0]    psum_in,
    input  logic signed [PROD_BITS-1:0] ones,
    input  logic                        carry,
    output logic signed [P_BITS-1:0]    psum
);
    always_ff @(posedge clk) psum <= psum_in + P_BITS'(ones) + P_BITS'(carry);
endmodule : add_impl
