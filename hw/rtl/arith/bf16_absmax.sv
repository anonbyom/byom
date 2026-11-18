// max(|a|, |b|), NaN if either is Inf or NaN.
module bf16_absmax (
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [15:0] maximum
);
    logic [15:0] a_abs;
    logic [15:0] b_abs;

    assign a_abs   = {1'b0, a[14:0]};
    assign b_abs   = {1'b0, b[14:0]};
    assign maximum = a_abs[14:7] == 8'hff || b_abs[14:7] == 8'hff ? 16'h7fc0 : a_abs >= b_abs ? a_abs : b_abs;
endmodule : bf16_absmax
