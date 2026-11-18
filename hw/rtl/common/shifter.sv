module shifter #(
    parameter int unsigned WIDTH  = 8,
    parameter int unsigned LENGTH = 0
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              en,
    input  logic [WIDTH-1:0]  d,
    output logic [WIDTH-1:0]  q
);

    if (LENGTH == 0) begin : gen_passthru
        assign q = d;
    end else begin : gen_chain
        logic [WIDTH-1:0] regs [LENGTH];
        always_ff @(posedge clk) begin
            if (rst) regs <= '{default: '0};
            else if (en) begin
                regs[0] <= d;
                for (int i = 1; i < LENGTH; i++) regs[i] <= regs[i-1];
            end
        end
        assign q = regs[LENGTH-1];
    end

endmodule : shifter

