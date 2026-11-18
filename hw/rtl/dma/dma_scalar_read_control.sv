module dma_scalar_read_control #(
    parameter int unsigned CHANNELS   = 32,
    parameter int unsigned SCALAR_W   = 32,
    parameter int unsigned DEPTH      = 1024,
    parameter int unsigned BEAT_WORDS = 8,

    localparam int unsigned ADDR_W  = $clog2(DEPTH),
    localparam int unsigned COUNT_W = $clog2(BEAT_WORDS + 1),
    localparam int unsigned CHANNEL_W = CHANNELS > 1 ? $clog2(CHANNELS) : 1,
    localparam int unsigned WAVE_W  = $clog2(DEPTH / (CHANNELS * BEAT_WORDS) + 1)
) (
    input  logic                 clk,
    input  logic                 rst,
    input  logic                 read_start,
    input  logic [SCALAR_W-1:0]  read_base,
    input  logic [SCALAR_W-1:0]  read_length,
    input  logic                 response_taken [CHANNELS],
    output logic                 mem_valid,
    output logic [ADDR_W-1:0]    mem_addr,
    output logic [CHANNEL_W-1:0] mem_channel
);
    logic                 token     [CHANNELS+1];
    logic                 returned;
    logic [WAVE_W-1:0]    waves_q;
    logic                 start     [CHANNELS];
    logic                 req_valid [CHANNELS+1];
    logic [COUNT_W-1:0]   words_q;
    logic [ADDR_W-1:0]    address_q;
    logic [CHANNEL_W-1:0] channel_q;

    assign token[0]            = returned && waves_q != 0;
    assign req_valid[CHANNELS] = 1'b0;
    assign mem_valid           = words_q != 0;
    assign mem_addr            = address_q;
    assign mem_channel         = channel_q;

    shifter #(
        .WIDTH(1),
        .LENGTH(CHANNELS)
    ) return_token (
        .clk,
        .rst,
        .en (1'b1),
        .d  (token[CHANNELS]),
        .q  (returned)
    );

    for (genvar c = 0; c < CHANNELS; c++) begin : gen_channel
        logic token_q;
        logic busy_q;
        assign start[c] = (token_q || token[c]) && !busy_q;

        shifter #(
            .WIDTH(1),
            .LENGTH(BEAT_WORDS-1)
        ) next_channel (
            .clk,
            .rst,
            .en (1'b1),
            .d  (start[c]),
            .q  (token[c+1])
        );

        always_ff @(posedge clk) begin
            if (rst) begin
                token_q      <= 1'b0;
                busy_q       <= 1'b0;
                req_valid[c] <= 1'b0;
            end else begin
                if (start[c]) token_q <= 1'b0;
                else if (token[c] || (c == 0 && read_start)) token_q <= 1'b1;
                if (start[c]) busy_q <= 1'b1;
                else if (response_taken[c]) busy_q <= 1'b0;
                req_valid[c] <= start[c] || req_valid[c+1];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            words_q   <= '0;
            address_q <= '0;
            waves_q   <= '0;
            channel_q <= '0;
        end else begin
            if (req_valid[0]) words_q <= COUNT_W'(BEAT_WORDS);
            else if (mem_valid) words_q <= words_q - 1'b1;

            if (read_start) address_q <= ADDR_W'(read_base);
            else if (mem_valid) address_q <= address_q + 1'b1;

            if (read_start) channel_q <= '0;
            else if (words_q == COUNT_W'(1)) channel_q <= CHANNELS == 1 ? '0 : channel_q + 1'b1;

            if (read_start) waves_q <= WAVE_W'(read_length);
            else if (start[0]) waves_q <= waves_q - 1'b1;
        end
    end

    initial begin
        if (CHANNELS == 0 || (CHANNELS & (CHANNELS-1)) != 0) $fatal(1, "CHANNELS must be non zero power of two");
    end
endmodule
