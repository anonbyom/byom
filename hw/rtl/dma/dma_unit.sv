module dma_unit #(
    parameter int unsigned CHANNELS            = 32,
    parameter int unsigned AXI_ADDR_W          = 64,
    parameter int unsigned AXI_BYTES           = 64,
    parameter int unsigned SCALAR_W            = 32,
    parameter int unsigned LOCAL_DEPTH         = 1024,
    parameter logic [AXI_ADDR_W-1:0] BASE_ADDR = '0,
    parameter int unsigned CHANNEL_BYTES       = 512 * 1024 * 1024,
    parameter int unsigned LOCAL_WRITE_PORTS   = 3,
    parameter int unsigned LOCAL_READ_PORTS    = 2,
    parameter int unsigned FIFO_DEPTH          = 4,
    parameter logic [LOCAL_WRITE_PORTS-1:0] SERIALIZED_WRITE_PORTS = '0,
    parameter logic [LOCAL_READ_PORTS-1:0]  SERIALIZED_READ_PORTS  = '0,

    localparam int unsigned AXI_DATA_W     = 8 * AXI_BYTES,
    localparam int unsigned COUNT_W        = $clog2(LOCAL_DEPTH + 1),
    localparam int unsigned LOCAL_WR_SEL_W = (LOCAL_WRITE_PORTS > 1) ? $clog2(LOCAL_WRITE_PORTS) : 1,
    localparam int unsigned LOCAL_RD_SEL_W = (LOCAL_READ_PORTS > 1) ? $clog2(LOCAL_READ_PORTS) : 1
) (
    input  logic                      clk,
    input  logic                      rst,

    input  logic                      dma_read_req_valid,
    output logic                      dma_read_req_ready,
    input  logic [LOCAL_WR_SEL_W-1:0] dma_read_local_write_sel,
    input  logic                      dma_read_scalar_fast,
    output logic                      scalar_write_fast        [CHANNELS],
    input  logic [SCALAR_W-1:0]       dma_read_external_addr,
    input  logic [SCALAR_W-1:0]       dma_read_length,
    output logic                      dma_read_done,

    input  logic                      dma_write_req_valid,
    output logic                      dma_write_req_ready,
    input  logic [LOCAL_RD_SEL_W-1:0] dma_write_local_read_sel,
    input  logic [SCALAR_W-1:0]       dma_write_external_addr,
    input  logic [SCALAR_W-1:0]       dma_write_length,
    output logic                      dma_write_done,

    output logic                      local_write_valid        [CHANNELS][LOCAL_WRITE_PORTS],
    input  logic                      local_write_ready        [CHANNELS][LOCAL_WRITE_PORTS],
    output logic [AXI_DATA_W-1:0]     local_write_data         [CHANNELS][LOCAL_WRITE_PORTS],
    input  logic                      local_write_idle         [CHANNELS],

    input  logic                      local_read_valid         [CHANNELS][LOCAL_READ_PORTS],
    output logic                      local_read_ready         [CHANNELS][LOCAL_READ_PORTS],
    input  logic [AXI_DATA_W-1:0]     local_read_data          [CHANNELS][LOCAL_READ_PORTS],

    output logic                      m_awvalid                [CHANNELS],
    input  logic                      m_awready                [CHANNELS],
    output logic [AXI_ADDR_W-1:0]     m_awaddr                 [CHANNELS],
    output logic [7:0]                m_awlen                  [CHANNELS],
    output logic [2:0]                m_awsize                 [CHANNELS],
    output axi_pkg::burst_t           m_awburst                [CHANNELS],
    output logic                      m_awid                   [CHANNELS],
    output logic                      m_awlock                 [CHANNELS],
    output logic [3:0]                m_awcache                [CHANNELS],
    output logic [2:0]                m_awprot                 [CHANNELS],
    output logic [3:0]                m_awqos                  [CHANNELS],

    output logic                      m_wvalid                 [CHANNELS],
    input  logic                      m_wready                 [CHANNELS],
    output logic [AXI_DATA_W-1:0]     m_wdata                  [CHANNELS],
    output logic [AXI_BYTES-1:0]      m_wstrb                  [CHANNELS],
    output logic                      m_wlast                  [CHANNELS],
    output logic                      m_wid                    [CHANNELS],

    input  logic                      m_bvalid                 [CHANNELS],
    output logic                      m_bready                 [CHANNELS],
    input  axi_pkg::resp_t            m_bresp                  [CHANNELS],
    input  logic                      m_bid                    [CHANNELS],

    output logic                      m_arvalid                [CHANNELS],
    input  logic                      m_arready                [CHANNELS],
    output logic [AXI_ADDR_W-1:0]     m_araddr                 [CHANNELS],
    output logic [7:0]                m_arlen                  [CHANNELS],
    output logic [2:0]                m_arsize                 [CHANNELS],
    output axi_pkg::burst_t           m_arburst                [CHANNELS],
    output logic                      m_arid                   [CHANNELS],
    output logic                      m_arlock                 [CHANNELS],
    output logic [3:0]                m_arcache                [CHANNELS],
    output logic [2:0]                m_arprot                 [CHANNELS],
    output logic [3:0]                m_arqos                  [CHANNELS],

    input  logic                      m_rvalid                 [CHANNELS],
    output logic                      m_rready                 [CHANNELS],
    input  logic [AXI_DATA_W-1:0]     m_rdata                  [CHANNELS],
    input  logic                      m_rlast                  [CHANNELS],
    input  axi_pkg::resp_t            m_rresp                  [CHANNELS],
    input  logic                      m_rid                    [CHANNELS]
);

    typedef struct packed {
        logic [LOCAL_WR_SEL_W-1:0] local_sel;
        logic                      scalar_fast;
        logic [SCALAR_W-1:0]       external_addr;
        logic [COUNT_W-1:0]        length;
    } read_command_t;

    typedef struct packed {
        logic [LOCAL_RD_SEL_W-1:0] local_sel;
        logic [SCALAR_W-1:0]       external_addr;
        logic [COUNT_W-1:0]        length;
    } write_command_t;

    read_command_t                 read_command  [CHANNELS];
    write_command_t                write_command [CHANNELS];
    read_command_t                 read_input;
    write_command_t                write_input;
    logic           [CHANNELS-1:0] read_valid;
    logic           [CHANNELS-1:0] write_valid;
    logic           [CHANNELS-1:0] read_ready;
    logic           [CHANNELS-1:0] write_ready;
    logic           [CHANNELS-1:0] read_done;
    logic           [CHANNELS-1:0] write_done;

    // Registered reset copies (reset_register): one per transport and channel.
    logic rst_read;
    logic rst_write;
    reset_register u_rst_read (.clk, .rst_in(rst), .rst(rst_read));
    reset_register u_rst_write (.clk, .rst_in(rst), .rst(rst_write));

    assign read_input = {dma_read_local_write_sel, dma_read_scalar_fast, dma_read_external_addr, COUNT_W'(dma_read_length)};
    assign write_input = {dma_write_local_read_sel, dma_write_external_addr, COUNT_W'(dma_write_length)};

    dma_command_transport #(
        .CHANNELS(CHANNELS),
        .WIDTH($bits(read_command_t)),
        .DEPTH(2)    // two HBM -> local reads in flight
    ) u_read (
        .clk,
        .rst           (rst_read),
        .req_valid     (dma_read_req_valid),
        .req_ready     (dma_read_req_ready),
        .req_data      (read_input),
        .done          (dma_read_done),
        .channel_valid (read_valid),
        .channel_ready (read_ready),
        .channel_data  (read_command),
        .channel_done  (read_done)
    );

    dma_command_transport #(
        .CHANNELS(CHANNELS),
        .WIDTH($bits(write_command_t))
    ) u_write (
        .clk,
        .rst           (rst_write),
        .req_valid     (dma_write_req_valid),
        .req_ready     (dma_write_req_ready),
        .req_data      (write_input),
        .done          (dma_write_done),
        .channel_valid (write_valid),
        .channel_ready (write_ready),
        .channel_data  (write_command),
        .channel_done  (write_done)
    );

    for (genvar c = 0; c < CHANNELS; c++) begin : gen_channel
        logic read_engine_done;
        logic read_draining;
        logic rst_channel;

        reset_register u_rst (.clk, .rst_in(rst), .rst(rst_channel));

        assign scalar_write_fast[c] = read_command[c].scalar_fast;

        // Both reads' data may finish before the local writes go idle: one done each.
        logic [1:0] draining;
        assign read_draining = draining != 0;

        credit_counter #(
            .WIDTH(2)
        ) u_draining (
            .clk,
            .rst   (rst_channel),
            .add   (2'(read_engine_done)),
            .sub   (2'(read_draining && local_write_idle[c])),
            .count (draining)
        );

        always_ff @(posedge clk) begin
            if (rst_channel) read_done[c] <= 1'b0;
            else read_done[c] <= read_draining && local_write_idle[c];
        end

        dma_channel #(
            .AXI_ADDR_W        (AXI_ADDR_W),
            .AXI_BYTES         (AXI_BYTES),
            .SCALAR_W          (SCALAR_W),
            .LOCAL_DEPTH       (LOCAL_DEPTH),
            .BASE_ADDR         (BASE_ADDR + AXI_ADDR_W'(c) * AXI_ADDR_W'(CHANNEL_BYTES)),
            .LOCAL_WRITE_PORTS (LOCAL_WRITE_PORTS),
            .LOCAL_READ_PORTS  (LOCAL_READ_PORTS),
            .FIFO_DEPTH        (FIFO_DEPTH),
            .SERIALIZED_WRITE_PORTS (SERIALIZED_WRITE_PORTS),
            .SERIALIZED_READ_PORTS  (SERIALIZED_READ_PORTS)
        ) u_dma (
            .clk,
            .rst                      (rst_channel),

            .dma_read_req_valid       (read_valid[c]),
            .dma_read_req_ready       (read_ready[c]),
            .dma_read_done            (read_engine_done),
            .dma_write_req_valid      (write_valid[c]),
            .dma_write_req_ready      (write_ready[c]),
            .dma_write_done           (write_done[c]),
            .dma_read_local_write_sel (read_command[c].local_sel),
            .dma_read_external_addr   (read_command[c].external_addr),
            .dma_read_length          (SCALAR_W'(read_command[c].length)),
            .dma_write_local_read_sel (write_command[c].local_sel),
            .dma_write_external_addr  (write_command[c].external_addr),
            .dma_write_length         (SCALAR_W'(write_command[c].length)),

            .local_write_valid        (local_write_valid[c]),
            .local_write_ready        (local_write_ready[c]),
            .local_write_data         (local_write_data[c]),
            .local_read_valid         (local_read_valid[c]),
            .local_read_ready         (local_read_ready[c]),
            .local_read_data          (local_read_data[c]),

            .m_awvalid                (m_awvalid[c]),
            .m_awready                (m_awready[c]),
            .m_awaddr                 (m_awaddr[c]),
            .m_awlen                  (m_awlen[c]),
            .m_awsize                 (m_awsize[c]),
            .m_awburst                (m_awburst[c]),
            .m_awid                   (m_awid[c]),
            .m_awlock                 (m_awlock[c]),
            .m_awcache                (m_awcache[c]),
            .m_awprot                 (m_awprot[c]),
            .m_awqos                  (m_awqos[c]),
            .m_wvalid                 (m_wvalid[c]),
            .m_wready                 (m_wready[c]),
            .m_wdata                  (m_wdata[c]),
            .m_wstrb                  (m_wstrb[c]),
            .m_wlast                  (m_wlast[c]),
            .m_wid                    (m_wid[c]),
            .m_bvalid                 (m_bvalid[c]),
            .m_bready                 (m_bready[c]),
            .m_bresp                  (m_bresp[c]),
            .m_bid                    (m_bid[c]),
            .m_arvalid                (m_arvalid[c]),
            .m_arready                (m_arready[c]),
            .m_araddr                 (m_araddr[c]),
            .m_arlen                  (m_arlen[c]),
            .m_arsize                 (m_arsize[c]),
            .m_arburst                (m_arburst[c]),
            .m_arid                   (m_arid[c]),
            .m_arlock                 (m_arlock[c]),
            .m_arcache                (m_arcache[c]),
            .m_arprot                 (m_arprot[c]),
            .m_arqos                  (m_arqos[c]),
            .m_rvalid                 (m_rvalid[c]),
            .m_rready                 (m_rready[c]),
            .m_rdata                  (m_rdata[c]),
            .m_rlast                  (m_rlast[c]),
            .m_rresp                  (m_rresp[c]),
            .m_rid                    (m_rid[c])
        );
    end

    initial begin
        if (CHANNELS == 0) $fatal(1, "CHANNELS must be non-zero");
        if (CHANNEL_BYTES % 4096 != 0) $fatal(1, "CHANNEL_BYTES must be a multiple of 4 KiB");
    end
endmodule : dma_unit
