module dma_scalar_read #(
    parameter int unsigned CHANNELS   = 32,
    parameter int unsigned SCALAR_W   = 32,
    parameter int unsigned DEPTH      = 1024,
    parameter int unsigned BEAT_W     = 256,

    localparam int unsigned BEAT_WORDS  = BEAT_W / SCALAR_W,
    localparam int unsigned MEM_LATENCY = 3,
    localparam int unsigned ADDR_W      = $clog2(DEPTH),
    localparam int unsigned CHANNEL_W   = CHANNELS > 1 ? $clog2(CHANNELS) : 1
) (
    input  logic                clk,
    input  logic                rst,
    input  logic                read_start,
    input  logic [SCALAR_W-1:0] read_base,
    input  logic [SCALAR_W-1:0] read_length,
    output logic                response_valid [CHANNELS],
    input  logic                response_ready [CHANNELS],
    output logic [BEAT_W-1:0]   response_data  [CHANNELS],

    output logic                mem_valid,
    output logic [ADDR_W-1:0]   mem_addr,
    input  logic                mem_resp_valid,
    input  logic [SCALAR_W-1:0] mem_resp_data
);
    typedef struct packed {
        logic                 valid;
        logic [CHANNEL_W-1:0] channel;
        logic [SCALAR_W-1:0]  data;
    } packet_t;
    packet_t              delayed [CHANNELS+1];
    logic                 delayed_valid [CHANNELS+1];
    logic [CHANNEL_W+SCALAR_W-1:0] delayed_payload [CHANNELS+1];

    logic                 response_taken [CHANNELS];
    logic [CHANNEL_W-1:0] mem_channel;
    logic [CHANNEL_W-1:0] response_channel;

    dma_scalar_read_control #(
        .CHANNELS(CHANNELS),
        .SCALAR_W(SCALAR_W),
        .DEPTH(DEPTH),
        .BEAT_WORDS(BEAT_WORDS)
    ) control (
        .clk,
        .rst,
        .read_start,
        .read_base,
        .read_length,
        .response_taken,
        .mem_valid,
        .mem_addr,
        .mem_channel
    );

    shifter #(
        .WIDTH(CHANNEL_W),
        .LENGTH(MEM_LATENCY)
    ) response_tag (
        .clk,
        .rst (1'b0),
        .en (1'b1),
        .d  (mem_channel),
        .q  (response_channel)
    );

    // Only valid needs a reset; channel and data are qualified by it.
    shifter_taps #(
        .WIDTH(1),
        .LENGTH(CHANNELS)
    ) transport_valid (
        .clk,
        .rst,
        .en (1'b1),
        .d  (mem_resp_valid),
        .q  (delayed_valid)
    );

    shifter_taps #(
        .WIDTH(CHANNEL_W + SCALAR_W),
        .LENGTH(CHANNELS)
    ) transport (
        .clk,
        .rst (1'b0),
        .en  (1'b1),
        .d   ({response_channel, mem_resp_data}),
        .q   (delayed_payload)
    );

    for (genvar c = 0; c <= CHANNELS; c++) begin : gen_delayed
        assign delayed[c] = '{valid: delayed_valid[c], channel: delayed_payload[c][SCALAR_W +: CHANNEL_W],
                              data: delayed_payload[c][SCALAR_W-1:0]};
    end

    for (genvar c = 0; c < CHANNELS; c++) begin : gen_channel
        logic received_valid;
        assign received_valid = delayed[c+1].valid && delayed[c+1].channel == CHANNEL_W'(c);
        assign response_taken[c] = response_valid[c] && response_ready[c];

        deserializer #(
            .SRC_WIDTH(SCALAR_W),
            .DST_WIDTH(BEAT_W)
        ) pack_channel (
            .clk,
            .rst,
            .src_data  (delayed[c+1].data),
            .src_valid (received_valid),
            .src_ready (),
            .dst_data  (response_data[c]),
            .dst_valid (response_valid[c]),
            .dst_ready (response_ready[c])
        );
    end

endmodule
