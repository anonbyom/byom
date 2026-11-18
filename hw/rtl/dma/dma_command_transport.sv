module dma_command_transport #(
    parameter int unsigned CHANNELS = 32,
    parameter int unsigned WIDTH    = 97,
    parameter int unsigned DEPTH    = 1
) (
    input  logic                clk,
    input  logic                rst,

    input  logic                req_valid,
    output logic                req_ready,
    input  logic [WIDTH-1:0]    req_data,
    output logic                done,

    output logic [CHANNELS-1:0] channel_valid,
    input  logic [CHANNELS-1:0] channel_ready,
    output logic [WIDTH-1:0]    channel_data  [CHANNELS],
    input  logic [CHANNELS-1:0] channel_done
);
    typedef struct packed {
        logic             valid;
        logic             tag;
        logic [WIDTH-1:0] data;
    } command_t;

    command_t delayed  [CHANNELS];
    logic     delayed_valid [CHANNELS];
    logic [WIDTH:0] delayed_payload [CHANNELS];
    logic     busy_q;
    logic     epoch_q;
    logic     done_q;
    logic     start;
    logic     finish;
    logic     done_tag_q [CHANNELS];
    logic     returned [CHANNELS];

    assign start     = req_valid && req_ready;

    // Only valid needs a reset; tag and data are qualified by it.
    shifter_taps #(
        .WIDTH(1),
        .LENGTH(CHANNELS-1)
    ) u_valid (
        .clk,
        .rst,
        .en (1'b1),
        .d  (start),
        .q  (delayed_valid)
    );

    shifter_taps #(
        .WIDTH(WIDTH+1),
        .LENGTH(CHANNELS-1)
    ) u_command (
        .clk,
        .rst (1'b0),
        .en  (1'b1),
        .d   ({~epoch_q, req_data}),
        .q   (delayed_payload)
    );

    for (genvar c = 0; c < CHANNELS; c++) begin : gen_delayed
        assign delayed[c] = '{valid: delayed_valid[c], tag: delayed_payload[c][WIDTH], data: delayed_payload[c][WIDTH-1:0]};
    end

    if (DEPTH == 1) begin : gen_single
        assign req_ready = !busy_q;
        assign done      = done_q;
        assign finish    = busy_q && returned[0] == epoch_q;

        always_ff @(posedge clk) begin
            if (rst) begin
                busy_q  <= 1'b0;
                epoch_q <= 1'b0;
                done_q  <= 1'b0;
            end else begin
                done_q <= finish;
                if (start) begin
                    busy_q  <= 1'b1;
                    epoch_q <= ~epoch_q;
                end else if (finish) begin
                    busy_q <= 1'b0;
                end
            end
        end
    end

    for (genvar c = 0; c < CHANNELS; c++) begin : gen_channel
        logic             valid_q;
        logic [WIDTH-1:0] data_q;
        logic             tag_q;

        assign channel_valid[c] = valid_q;
        assign channel_data[c] = data_q;

        always_ff @(posedge clk) begin
            if (delayed[c].valid) begin
                data_q <= delayed[c].data;
                tag_q  <= delayed[c].tag;
            end

            if (rst) begin
                valid_q    <= 1'b0;
                done_tag_q[c] <= 1'b0;
            end else begin
                if (delayed[c].valid) valid_q <= 1'b1;
                else if (channel_ready[c]) valid_q <= 1'b0;

                if (channel_done[c]) done_tag_q[c] <= tag_q;
            end
        end

    end

    if (DEPTH == 1) begin : gen_epoch_ring
        assign returned[CHANNELS-1] = done_tag_q[CHANNELS-1];

        for (genvar c = 0; c < CHANNELS-1; c++) begin : gen_return
            logic returned_q;

            assign returned[c] = returned_q;

            always_ff @(posedge clk) begin
                if (rst) returned_q <= 1'b0;
                else if (done_tag_q[c] == returned[c+1]) returned_q <= done_tag_q[c];
            end
        end
    end else begin : gen_count_ring
        logic [2:0] finished_q [CHANNELS];
        logic [2:0] minimum    [CHANNELS];
        logic [2:0] issued_q, completed_q;
        logic       done_pulse_q;

        for (genvar c = 0; c < CHANNELS; c++) begin : gen_count
            always_ff @(posedge clk) begin
                if (rst) finished_q[c] <= '0;
                else if (channel_done[c]) finished_q[c] <= finished_q[c] + 1'b1;
            end
        end
        assign minimum[CHANNELS-1] = finished_q[CHANNELS-1];
        for (genvar c = 0; c < CHANNELS-1; c++) begin : gen_min
            logic [2:0] minimum_q;
            logic [2:0] ahead;
            assign ahead = finished_q[c] - minimum[c+1];
            assign minimum[c] = minimum_q;
            always_ff @(posedge clk) begin
                if (rst) minimum_q <= '0;
                else minimum_q <= ahead[2] ? finished_q[c] : minimum[c+1];
            end
        end

        assign req_ready = 3'(issued_q - completed_q) < 3'(DEPTH);
        assign done      = done_pulse_q;
        assign finish    = minimum[0] != completed_q;
        always_ff @(posedge clk) begin
            if (rst) begin
                issued_q     <= '0;
                completed_q  <= '0;
                done_pulse_q <= 1'b0;
            end else begin
                if (start) issued_q <= issued_q + 1'b1;
                // One done per cycle; a second finished command is reported next cycle.
                if (finish) completed_q <= completed_q + 1'b1;
                done_pulse_q <= finish;
            end
        end
        assign busy_q  = 1'b0;
        assign epoch_q = 1'b0;
        assign done_q  = 1'b0;
        assign returned = '{default: 1'b0};
    end

    initial begin
        if (CHANNELS == 0) $fatal(1, "CHANNELS must be non-zero");
        if (!(DEPTH inside {1, 2})) $fatal(1, "dma_command_transport DEPTH must be 1 or 2");
    end
endmodule : dma_command_transport
