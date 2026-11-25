module dma_scalar_write #(
    parameter int unsigned CHANNELS      = 32,
    parameter int unsigned SCALAR_W      = 32,
    parameter int unsigned IMEM_DEPTH    = 1024,
    parameter int unsigned SMEM_DEPTH    = 1024,
    parameter int unsigned BEAT_W        = 256,

    localparam int unsigned PACKET_W     = 128,
    localparam int unsigned BUNDLE_W     = isa_pkg::BUNDLE_WIDTH,
    localparam int unsigned BEAT_PACKETS = BEAT_W / PACKET_W,
    localparam int unsigned IMEM_WORDS   = CHANNELS * BEAT_W / PACKET_W,
    localparam int unsigned SMEM_WORDS   = CHANNELS * BEAT_W / SCALAR_W,
    localparam int unsigned IMEM_ADDR_W  = $clog2(IMEM_DEPTH),
    localparam int unsigned SMEM_ADDR_W  = $clog2(SMEM_DEPTH),
    localparam int unsigned ADDR_W       = IMEM_ADDR_W > SMEM_ADDR_W ? IMEM_ADDR_W : SMEM_ADDR_W,
    localparam int unsigned COUNT_W      = ADDR_W + 1
) (
    input logic                    clk,
    input logic                    rst,

    input  logic                   write_valid [CHANNELS],
    output logic                   write_ready [CHANNELS],
    input  logic [BEAT_W-1:0]      write_data  [CHANNELS],
    input  logic                   write_start,
    input  logic                   write_imem,
    input  logic                   write_fast  [CHANNELS],
    input  logic [SCALAR_W-1:0]    write_base,
    input  logic [SCALAR_W-1:0]    write_length,
    output logic                   write_done,

    output logic                   imem_valid,
    output logic [IMEM_ADDR_W-1:0] imem_addr,
    output logic [BUNDLE_W-1:0]    imem_data,

    output logic                   smem_valid,
    output logic [SMEM_ADDR_W-1:0] smem_addr,
    output logic [SCALAR_W-1:0]    smem_data
);
    localparam int unsigned DMA_TIMING_IMEM_WORD_CYCLES = IMEM_WORDS;   // a DMA word into IMEM, a packet a cycle

    logic                inject           [CHANNELS];
    logic                beat_done        [CHANNELS];
    logic [PACKET_W-1:0] data             [CHANNELS];
    logic                sink_valid;
    logic [PACKET_W-1:0] packet;
    logic                packet_fire;
    logic                count_fire;
    logic                imem_q;
    logic                sink_ready;
    logic                serializer_ready;
    logic [ADDR_W-1:0]   address_q;
    logic [COUNT_W-1:0]  remaining_q;
    logic                write_fire;
    logic                last_write;

    dma_scalar_write_control #(
        .CHANNELS(CHANNELS),
        .PACKET_WORDS(PACKET_W / SCALAR_W),
        .BEAT_PACKETS(BEAT_PACKETS)
    ) control (
        .clk,
        .rst,
        .write_valid,
        .write_fast,
        .inject,
        .beat_done
    );

    assign imem_addr  = IMEM_ADDR_W'(address_q);
    assign smem_addr  = SMEM_ADDR_W'(address_q);
    assign write_fire  = imem_valid || smem_valid;
    assign packet_fire = sink_valid && imem_q;
    assign count_fire  = packet_fire || smem_valid;
    assign last_write  = count_fire && remaining_q == COUNT_W'(1);

    injection_chain #(
        .STAGES(CHANNELS),
        .WIDTH(PACKET_W)
    ) transport (
        .clk,
        .rst,
        .inject,
        .data,
        .out_valid(sink_valid),
        .out_consume(sink_ready),
        .out_data(packet)
    );

    shifter #(
        .WIDTH(1),
        .LENGTH(3)
    ) write_completion (
        .clk,
        .rst,
        .en (1'b1),
        .d  (last_write),
        .q  (write_done)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            address_q   <= '0;
            imem_q      <= 1'b0;
            remaining_q <= '0;
        end else begin
            if (write_start) begin
                address_q   <= ADDR_W'(write_base);
                imem_q      <= write_imem;
                remaining_q <= COUNT_W'(write_length) * COUNT_W'(write_imem ? IMEM_WORDS : SMEM_WORDS);
            end else begin
                if (write_fire) address_q <= address_q + 1'b1;
                if (count_fire) remaining_q <= remaining_q - 1'b1;
            end
        end
    end

    for (genvar c = 0; c < CHANNELS; c++) begin : gen_channel
        assign beat_done[c] = write_valid[c] && write_ready[c];

        unbuffered_serializer #(
            .SRC_WIDTH(BEAT_W),
            .DST_WIDTH(PACKET_W)
        ) beat_serializer (
            .clk,
            .rst,
            .src_data  (write_data[c]),
            .src_valid (write_valid[c]),
            .src_ready (write_ready[c]),
            .dst_data  (data[c]),
            .dst_valid (),
            .dst_ready (inject[c])
        );
    end

    // 128-bit packets in, BUNDLE_W-bit bundles out, packed back to back.
    begin : gen_gearbox
        localparam int unsigned GEAR_W  = BUNDLE_W + PACKET_W;
        localparam int unsigned LEVEL_W = $clog2(GEAR_W + 1);
        logic [GEAR_W-1:0]  gear_q;
        logic [LEVEL_W-1:0] level_q;
        logic               emit;
        logic [GEAR_W-1:0]  kept;
        logic [LEVEL_W-1:0] kept_level;

        assign emit       = level_q >= LEVEL_W'(BUNDLE_W);
        assign kept       = emit ? gear_q >> BUNDLE_W : gear_q;
        assign kept_level = emit ? level_q - LEVEL_W'(BUNDLE_W) : level_q;
        assign imem_valid = emit;
        assign imem_data  = gear_q[BUNDLE_W-1:0];

        always_ff @(posedge clk) gear_q <= write_start ? '0 : packet_fire ? kept | (GEAR_W'(packet) << kept_level) : kept;

        always_ff @(posedge clk) begin
            if (rst) level_q <= '0;
            else if (write_start) level_q <= '0;
            else level_q <= kept_level + (packet_fire ? LEVEL_W'(PACKET_W) : '0);
        end
    end
    assign sink_ready = imem_q || serializer_ready;

    unbuffered_serializer #(
        .SRC_WIDTH(PACKET_W),
        .DST_WIDTH(SCALAR_W)
    ) smem_serializer (
        .clk,
        .rst,
        .src_data  (packet),
        .src_valid (sink_valid && !imem_q),
        .src_ready (serializer_ready),
        .dst_data  (smem_data),
        .dst_valid (smem_valid),
        .dst_ready (1'b1)
    );

    initial begin
        if (SCALAR_W != 32) $fatal(1, "scalar transport requires 32-bit words");
    end
endmodule
