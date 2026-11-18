// A two's complement code saturated to BITS-bit two's complement or sign-magnitude.
module int4_int_code #(
    parameter int unsigned  BITS    = 4,
    parameter bit           TWOS    = 1'b1,
    parameter int unsigned  IN_BITS = 4,
    localparam int unsigned LIMIT   = (1 << (BITS - 1)) - 1
) (
    input  logic [IN_BITS-1:0] int4,
    output logic [BITS-1:0] code
);
    logic [IN_BITS-1:0] absolute;
    logic [BITS-1:0] magnitude;

    assign absolute  = int4[IN_BITS-1] ? -int4 : int4;
    assign magnitude = absolute > IN_BITS'(LIMIT) ? BITS'(LIMIT) : BITS'(absolute);

    if (TWOS) begin : gen_twos
        assign code = int4[IN_BITS-1] ? -magnitude : magnitude;
    end else begin : gen_sign_magnitude
        assign code = {int4[IN_BITS-1], magnitude[BITS-2:0]};
    end
endmodule : int4_int_code
