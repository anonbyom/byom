// binary32 -> BF16, round to nearest even; NaN = 0x7fc0.
module fp32_to_bf16 (
    input  logic [31:0] value,
    output logic [15:0] bf16
);
    logic [31:0] rounded;

    assign rounded = value + 32'h7fff + 32'(value[16]);
    assign bf16    = value[30:23] == 8'hff && value[22:0] != 0 ? 16'h7fc0 : rounded[31:16];
endmodule : fp32_to_bf16
