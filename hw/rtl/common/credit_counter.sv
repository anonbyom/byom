// A slot count: INIT after reset, then count + add - sub every cycle.
module credit_counter #(
    parameter int unsigned WIDTH = 8,
    parameter int unsigned INIT  = 0
) (
    input  logic             clk,
    input  logic             rst,
    input  logic [WIDTH-1:0] add,
    input  logic [WIDTH-1:0] sub,
    output logic [WIDTH-1:0] count
);
    always_ff @(posedge clk) begin
        if (rst) count <= WIDTH'(INIT);
        else count <= count + add - sub;
    end
endmodule : credit_counter
