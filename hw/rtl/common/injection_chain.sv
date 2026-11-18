module injection_chain #(
    parameter int unsigned STAGES    = 32,
    parameter int unsigned WIDTH     = 128
) (
    input  logic                 clk,
    input  logic                 rst,
    input  logic                 inject    [STAGES],
    input  logic [WIDTH-1:0]     data      [STAGES],
    output logic                 out_valid,
    input  logic                 out_consume,
    output logic [WIDTH-1:0]     out_data
);
    logic                 valid_q [STAGES+1];
    logic [WIDTH-1:0]     data_q  [STAGES+1];

    assign valid_q[STAGES] = 1'b0;
    assign out_valid       = valid_q[0];
    assign out_data        = data_q[0];
    assign data_q[STAGES]  = '0;

    for (genvar s = 0; s < STAGES; s++) begin : gen_stage
        logic capture;
        assign capture = inject[s] || valid_q[s+1];

        always_ff @(posedge clk) begin
            if (rst) valid_q[s] <= 1'b0;
            else if (capture) valid_q[s] <= 1'b1;
            else if (s != 0 || out_consume) valid_q[s] <= 1'b0;
        end

        always_ff @(posedge clk) begin
            if (capture) data_q[s] <= inject[s] ? data[s] : data_q[s+1];
        end
    end
endmodule
