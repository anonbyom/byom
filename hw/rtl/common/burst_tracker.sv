module burst_tracker #(
    parameter int unsigned COUNT_W = 9
) (
    input  logic               clk,
    input  logic               rst,

    input  logic               req_fire,
    input  logic [COUNT_W-1:0] req_beats,
    input  logic               beat_fire,
    input  logic               resp_fire,

    output logic               can_issue,
    output logic               active,
    output logic               last,
    output logic               resp_ready,
    output logic               done
);
    logic               burst_valid_q;
    logic               current_valid_q;
    logic               next_valid_q;
    logic [COUNT_W-1:0] burst_beats_q;
    logic [COUNT_W-1:0] current_beats_q;
    logic [COUNT_W-1:0] next_beats_q;
    logic [1:0]         pending_responses_q;
    logic               last_fire;
    logic               current_ready;

    assign can_issue     = pending_responses_q != 2'd2 || resp_fire;
    assign active        = current_valid_q;
    assign last          = current_beats_q == COUNT_W'(1);
    assign resp_ready    = pending_responses_q != '0;
    assign done          = resp_fire && (pending_responses_q == 2'd1) && !req_fire;
    assign last_fire     = beat_fire && last;
    assign current_ready = !current_valid_q || (last_fire && !next_valid_q);

    always_ff @(posedge clk) begin
        burst_beats_q <= req_beats;

        if (rst) begin
            burst_valid_q       <= 1'b0;
            current_valid_q     <= 1'b0;
            next_valid_q        <= 1'b0;
            pending_responses_q <= '0;
        end else begin
            burst_valid_q <= req_fire;

            if (req_fire && !resp_fire) begin
                pending_responses_q <= pending_responses_q + 1'b1;
            end else if (resp_fire && !req_fire) begin
                pending_responses_q <= pending_responses_q - 1'b1;
            end

            if (burst_valid_q && current_ready) begin
                current_beats_q <= burst_beats_q;
                current_valid_q <= 1'b1;
            end else if (last_fire) begin
                current_valid_q <= next_valid_q;
                if (next_valid_q) begin
                    current_beats_q <= next_beats_q;
                end
            end else if (beat_fire) begin
                current_beats_q <= current_beats_q - 1'b1;
            end

            if (burst_valid_q && !current_ready) begin
                next_beats_q <= burst_beats_q;
                next_valid_q <= 1'b1;
            end else if (last_fire) begin
                next_valid_q <= 1'b0;
            end
        end
    end
endmodule
