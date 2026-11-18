module valu_execute #(
    parameter int unsigned ELEMENT_WIDTH = isa_pkg::VECTOR_ELEMENT_WIDTH
) (
    input  isa_pkg::valu_opcode_t    op,
    input  logic [ELEMENT_WIDTH-1:0] operand [2],
    input  logic [ELEMENT_WIDTH-1:0] srot_in,
    output logic [ELEMENT_WIDTH-1:0] result
);
    import isa_pkg::*;

    logic [ELEMENT_WIDTH-1:0] minimum;
    logic [ELEMENT_WIDTH-1:0] maximum;
    logic                     gate_open;

    assign gate_open = !operand[0][15] && operand[0][14:0] != '0 && !(operand[0][14:7] == 8'hff && operand[0][6:0] != '0);

    bf16_compare u_compare (
        .a         (operand[0]),
        .b         (operand[1]),
        .less      (),
        .equal     (),
        .greater   (),
        .unordered (),
        .minimum,
        .maximum
    );

    always_comb begin
        case (op)
            VMIN:       result = minimum;
            VMAX:       result = maximum;
            VSROT:      result = srot_in;
            VRELU_GATE: result = gate_open ? operand[1] : '0;
            VOR:        result = operand[0] | operand[1];
            VAND:       result = operand[0] & operand[1];
            VXOR:       result = operand[0] ^ operand[1];
            default:    result = '0;
        endcase
    end


    initial begin
        if (ELEMENT_WIDTH != 16) $fatal(1, "The BF16 VALU requires 16-bit vector elements");
    end
endmodule : valu_execute
