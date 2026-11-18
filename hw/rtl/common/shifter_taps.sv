module shifter_taps #(
    parameter int unsigned WIDTH  = 8,
    parameter int unsigned LENGTH = 0
) (
    input  logic              clk,
    input  logic              rst,

    input  logic              en,
    input  logic [WIDTH-1:0]  d,
    output logic [WIDTH-1:0]  q [LENGTH + 1]
);
    assign q[0] = d;

    if (LENGTH > 0) begin : gen_chain
        always_ff @(posedge clk) begin
            if (rst) q[1:LENGTH] <= '{default: '0};
            else if (en) begin
                q[1] <= d;
                for (int i = 2; i <= LENGTH; i++) q[i] <= q[i-1];
            end
        end
    end

endmodule : shifter_taps
