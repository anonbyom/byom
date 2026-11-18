// BF16 ADD/MUL for one lane's four sublanes: one flush-to-zero adder and multiplier per sublane
module valu_bf16 #(
    parameter int unsigned SUBLANES = 4,
    parameter int unsigned VREG_COUNT = 16,
    localparam int unsigned VREG_ADDR_W = $clog2(VREG_COUNT)
) (
    input  logic                      clk,
    input  logic                      issue_valid,
    input  isa_pkg::valu_opcode_t    issue_op,
    input  logic [VREG_ADDR_W-1:0]  issue_dest,
    input  logic [15:0]             x [SUBLANES],
    input  logic [15:0]             y [SUBLANES],
    output logic                    result_valid [SUBLANES],
    output logic [VREG_ADDR_W-1:0]  result_dest,
    output logic [15:0]             result_data  [SUBLANES]
);
    import isa_pkg::*;

    // The VALU register reads complete one cycle after issue.
    logic                   start_q;
    valu_opcode_t           start_op_q;
    logic [VREG_ADDR_W-1:0] start_dest_q;

    always_ff @(posedge clk) begin
        start_q      <= issue_valid && issue_op inside {ADD_BF16, MUL_BF16};
        start_op_q   <= issue_op;
        start_dest_q <= issue_dest;
    end

    logic        add_valid [SUBLANES];
    logic        mul_valid [SUBLANES];
    logic [15:0] sum       [SUBLANES];
    logic [15:0] product   [SUBLANES];
    logic        result_add;

    for (genvar s = 0; s < SUBLANES; s++) begin : gen_sublane
        bf16_adder #(.FTZ(1'b1)) u_add (
            .clk, .rst(1'b0),
            .in_valid (start_q && start_op_q == ADD_BF16),
            .a        (x[s]),
            .b        (y[s]),
            .out_valid(add_valid[s]),
            .sum      (sum[s])
        );
        bf16_mul_ftz u_mul (
            .clk, .rst(1'b0),
            .in_valid (start_q && start_op_q == MUL_BF16),
            .a        (x[s]),
            .b        (y[s]),
            .out_valid(mul_valid[s]),
            .product  (product[s])
        );
        assign result_valid[s] = add_valid[s] || mul_valid[s];
        assign result_data[s]  = result_add ? sum[s] : product[s];
    end

    shifter #(
        .WIDTH(VREG_ADDR_W + 1),
        .LENGTH(4)
    ) u_tag (
        .clk,
        .rst (1'b0),
        .en  (1'b1),
        .d   ({start_dest_q, start_op_q == ADD_BF16}),
        .q   ({result_dest, result_add})
    );
endmodule : valu_bf16
