module dma_scalar_write_control #(
    parameter int unsigned CHANNELS     = 32,
    parameter int unsigned PACKET_WORDS = 4,
    parameter int unsigned BEAT_PACKETS = 2,

    localparam int unsigned SMEM_SLOT   = PACKET_WORDS * BEAT_PACKETS,
    localparam int unsigned PHASE_W     = $clog2(SMEM_SLOT)
) (
    input  logic clk,
    input  logic rst,
    input  logic write_valid [CHANNELS],
    input  logic write_fast  [CHANNELS],
    output logic inject      [CHANNELS],
    input  logic beat_done   [CHANNELS]
);
    logic token [CHANNELS+1];
    logic returned;
    assign token[0] = returned;

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
        logic                 token_q;
        logic                 active_q;
        logic [PHASE_W-1:0]   phase_q;
        logic [PHASE_W-1:0]   phase;
        logic                 start;
        logic                 running;
        logic                 pass_token;

        assign start      = (token_q || token[c]) && write_valid[c];
        assign running    = start || active_q;
        assign phase      = start ? '0 : phase_q;
        assign inject[c]  = running && (write_fast[c] || phase % PHASE_W'(PACKET_WORDS) == 0);
        assign pass_token = running && phase == PHASE_W'((write_fast[c] ? BEAT_PACKETS : SMEM_SLOT) - 2);

        always_ff @(posedge clk) begin
            if (rst) begin
                token_q    <= c == 0;
                active_q   <= 1'b0;
                token[c+1] <= 1'b0;
                phase_q    <= '0;
            end else begin
                if (start) token_q <= 1'b0;
                else if (token[c]) token_q <= 1'b1;

                token[c+1] <= pass_token;
                if (start) begin
                    active_q <= 1'b1;
                    phase_q  <= PHASE_W'(1);
                end else if (active_q) begin
                    if (write_fast[c] ? beat_done[c] : pass_token) active_q <= 1'b0;
                    else phase_q <= phase_q + 1'b1;
                end

            end
        end
    end

    initial begin
        if (CHANNELS == 0 || (CHANNELS & (CHANNELS-1)) != 0) $fatal(1, "CHANNELS must be one or a power of two");
        if (BEAT_PACKETS < 2) $fatal(1, "write transport requires at least two packets per beat");
    end
endmodule
