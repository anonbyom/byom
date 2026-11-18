module dma_channel #(
    parameter int unsigned AXI_ADDR_W        = 64,
    parameter int unsigned AXI_BYTES         = 64,
    parameter int unsigned SCALAR_W          = 32,
    parameter int unsigned LOCAL_DEPTH       = 1024,
    parameter logic [AXI_ADDR_W-1:0] BASE_ADDR = '0,
    parameter int unsigned LOCAL_WRITE_PORTS = 3,
    parameter int unsigned LOCAL_READ_PORTS  = 2,
    parameter int unsigned FIFO_DEPTH        = 4,
    parameter logic [LOCAL_WRITE_PORTS-1:0] SERIALIZED_WRITE_PORTS = '0,
    parameter logic [LOCAL_READ_PORTS-1:0]  SERIALIZED_READ_PORTS  = '0,

    localparam int unsigned AXI_DATA_W = 8 * AXI_BYTES,
    localparam int unsigned COUNT_W = $clog2(LOCAL_DEPTH + 1),
    localparam int unsigned LOCAL_WRITE_SEL_W = (LOCAL_WRITE_PORTS > 1) ? $clog2(LOCAL_WRITE_PORTS) : 1,
    localparam int unsigned LOCAL_READ_SEL_W  = (LOCAL_READ_PORTS > 1) ? $clog2(LOCAL_READ_PORTS) : 1
) (
    input  logic clk,
    input  logic rst,

    input  logic                         dma_read_req_valid,
    output logic                         dma_read_req_ready,
    input  logic [LOCAL_WRITE_SEL_W-1:0] dma_read_local_write_sel,
    input  logic [SCALAR_W-1:0]          dma_read_external_addr,
    input  logic [SCALAR_W-1:0]          dma_read_length,
    output logic                         dma_read_done,

    input  logic                         dma_write_req_valid,
    output logic                         dma_write_req_ready,
    input  logic [LOCAL_READ_SEL_W-1:0]  dma_write_local_read_sel,
    input  logic [SCALAR_W-1:0]          dma_write_external_addr,
    input  logic [SCALAR_W-1:0]          dma_write_length,
    output logic                         dma_write_done,

    output logic                         local_write_valid [LOCAL_WRITE_PORTS],
    input  logic                         local_write_ready [LOCAL_WRITE_PORTS],
    output logic [AXI_DATA_W-1:0]        local_write_data  [LOCAL_WRITE_PORTS],

    input  logic                         local_read_valid [LOCAL_READ_PORTS],
    output logic                         local_read_ready [LOCAL_READ_PORTS],
    input  logic [AXI_DATA_W-1:0]        local_read_data  [LOCAL_READ_PORTS],

    output logic                         m_awvalid,
    input  logic                         m_awready,
    output logic [AXI_ADDR_W-1:0]        m_awaddr,
    output logic [7:0]                   m_awlen,
    output logic [2:0]                   m_awsize,
    output axi_pkg::burst_t              m_awburst,
    output logic                         m_awid,
    output logic                         m_awlock,
    output logic [3:0]                   m_awcache,
    output logic [2:0]                   m_awprot,
    output logic [3:0]                   m_awqos,

    output logic                         m_wvalid,
    input  logic                         m_wready,
    output logic [AXI_DATA_W-1:0]        m_wdata,
    output logic [AXI_BYTES-1:0]         m_wstrb,
    output logic                         m_wlast,
    output logic                         m_wid,

    input  logic                         m_bvalid,
    output logic                         m_bready,
    input  axi_pkg::resp_t               m_bresp,
    input  logic                         m_bid,

    output logic                         m_arvalid,
    input  logic                         m_arready,
    output logic [AXI_ADDR_W-1:0]        m_araddr,
    output logic [7:0]                   m_arlen,
    output logic [2:0]                   m_arsize,
    output axi_pkg::burst_t              m_arburst,
    output logic                         m_arid,
    output logic                         m_arlock,
    output logic [3:0]                   m_arcache,
    output logic [2:0]                   m_arprot,
    output logic [3:0]                   m_arqos,

    input  logic                         m_rvalid,
    output logic                         m_rready,
    input  logic [AXI_DATA_W-1:0]        m_rdata,
    input  logic                         m_rlast,
    input  axi_pkg::resp_t               m_rresp,
    input  logic                         m_rid
);
    dma_reader #(
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_BYTES(AXI_BYTES),
        .LOCAL_DEPTH(LOCAL_DEPTH),
        .LOCAL_WR_PORTS(LOCAL_WRITE_PORTS),
        .BASE_ADDR(BASE_ADDR),
        .FIFO_DEPTH(FIFO_DEPTH),
        .SERIALIZED_PORTS(SERIALIZED_WRITE_PORTS)
    ) u_dma_reader (
        .clk,
        .rst,

        .req_valid(dma_read_req_valid),
        .req_ready(dma_read_req_ready),
        .req_addr(AXI_ADDR_W'(dma_read_external_addr) * AXI_ADDR_W'(AXI_BYTES)),
        .req_words(COUNT_W'(dma_read_length)),
        .req_local_sel(dma_read_local_write_sel),
        .done(dma_read_done),

        .local_write_valid,
        .local_write_ready,
        .local_write_data,

        .m_arvalid,
        .m_arready,
        .m_araddr,
        .m_arlen,
        .m_arsize,
        .m_arburst,
        .m_arid,
        .m_arlock,
        .m_arcache,
        .m_arprot,
        .m_arqos,
        .m_rvalid,
        .m_rready,
        .m_rdata,
        .m_rlast,
        .m_rresp,
        .m_rid
    );

    dma_writer #(
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_BYTES(AXI_BYTES),
        .LOCAL_DEPTH(LOCAL_DEPTH),
        .LOCAL_READ_PORTS(LOCAL_READ_PORTS),
        .BASE_ADDR(BASE_ADDR),
        .SERIALIZED_PORTS(SERIALIZED_READ_PORTS)
    ) u_dma_writer (
        .clk,
        .rst,

        .req_valid(dma_write_req_valid),
        .req_ready(dma_write_req_ready),
        .req_addr(AXI_ADDR_W'(dma_write_external_addr) * AXI_ADDR_W'(AXI_BYTES)),
        .req_words(COUNT_W'(dma_write_length)),
        .req_local_sel(dma_write_local_read_sel),
        .done(dma_write_done),

        .local_read_valid,
        .local_read_ready,
        .local_read_data,

        .m_awvalid,
        .m_awready,
        .m_awaddr,
        .m_awlen,
        .m_awsize,
        .m_awburst,
        .m_awid,
        .m_awlock,
        .m_awcache,
        .m_awprot,
        .m_awqos,
        .m_wvalid,
        .m_wready,
        .m_wdata,
        .m_wstrb,
        .m_wlast,
        .m_wid,
        .m_bvalid,
        .m_bready,
        .m_bresp,
        .m_bid
    );

endmodule : dma_channel
