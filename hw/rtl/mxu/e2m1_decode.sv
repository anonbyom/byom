// E2M1 code -> twice its value, as a signed integer (-12 .. 12).
module e2m1_decode (
    input  logic [3:0]        code,
    output logic signed [4:0] value
);
    localparam string ARITH_CODES = "e2m1";

    logic [3:0] magnitude;

    always_comb begin
        unique case (code[2:1])
            2'b00: magnitude = {3'b000, code[0]};
            2'b01: magnitude = {2'b00, 1'b1, code[0]};
            2'b10: magnitude = {1'b0, 1'b1, code[0], 1'b0};
            2'b11: magnitude = {1'b1, code[0], 2'b00};
        endcase
        value = code[3] && magnitude != 0 ? -$signed({1'b0, magnitude}) : $signed({1'b0, magnitude});
    end
endmodule : e2m1_decode
