// E8M0 block scale from a BF16 absmax's exponent field: floor(log2(maximum)) - 2 (E2M1 emax),
// biased and clamped at 0 (a subnormal maximum gives 0). NaN or infinity: 0xff.
module bf16_max_to_e8m0 (
    input  logic [7:0] exponent,
    output logic [7:0] scale
);
    always_comb begin
        if (exponent == 8'hff)    scale = 8'hff;
        else if (exponent < 8'd2) scale = 8'h00;
        else                      scale = exponent - 8'd2;
    end
endmodule : bf16_max_to_e8m0
