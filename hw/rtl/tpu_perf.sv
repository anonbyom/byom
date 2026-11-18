// Counters of one kernel run, cleared at start: TOTAL from start, the others from the first issued bundle.
module tpu_perf #(
    localparam int unsigned COUNT = tpu_perf_pkg::COUNT
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic        done,
    input  logic [COUNT-1:0] event_in,
    output logic [63:0] counters [COUNT]
);
    import tpu_perf_pkg::*;

    logic             active_q;
    logic             running_q;
    logic [COUNT-1:0] event_q;

    always_ff @(posedge clk) event_q <= event_in;

    always_ff @(posedge clk) begin
        if (rst) begin
            active_q  <= 1'b0;
            running_q <= 1'b0;
        end else begin
            if (start) active_q <= 1'b1;
            else if (done) active_q <= 1'b0;
            if (start || done) running_q <= 1'b0;
            else if (active_q && event_q[ISSUES]) running_q <= 1'b1;
        end
    end

    for (genvar i = 0; i < COUNT; i++) begin : gen_counter
        always_ff @(posedge clk) begin
            if (start) counters[i] <= '0;
            else if (i == TOTAL ? active_q : (running_q || event_q[ISSUES] && active_q) && event_q[i])
                counters[i] <= counters[i] + 1'b1;
        end
    end
endmodule
