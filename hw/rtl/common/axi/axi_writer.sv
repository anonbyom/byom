module axi_writer #(
    parameter int unsigned AXI_ADDR_W = 64,
    parameter int unsigned AXI_BYTES = 64,

    localparam int unsigned AXI_DATA_W = 8 * AXI_BYTES,
    localparam int unsigned AXI_SIZE = $clog2(AXI_BYTES)
) (
    input  logic                 clk,
    input  logic                 rst,

    input  logic                  req_valid,
    output logic                  req_ready,
    input  logic [AXI_ADDR_W-1:0] req_addr,
    input  logic [8:0]            req_beats,

    input  logic                  src_valid,
    output logic                  src_ready,
    input  logic [AXI_DATA_W-1:0] src_data,
    output logic                  done,

    output logic                  m_awvalid,
    input  logic                  m_awready,
    output logic [AXI_ADDR_W-1:0] m_awaddr,
    output logic [7:0]            m_awlen,
    output logic [2:0]            m_awsize,
    output axi_pkg::burst_t       m_awburst,
    output logic                  m_awid,
    output logic                  m_awlock,
    output logic [3:0]            m_awcache,
    output logic [2:0]            m_awprot,
    output logic [3:0]            m_awqos,

    output logic                  m_wvalid,
    input  logic                  m_wready,
    output logic [AXI_DATA_W-1:0] m_wdata,
    output logic [AXI_BYTES-1:0]  m_wstrb,
    output logic                  m_wlast,
    output logic                  m_wid,

    input  logic                  m_bvalid,
    output logic                  m_bready,
    input  axi_pkg::resp_t        m_bresp,
    input  logic                  m_bid
);
    initial begin
        if ((AXI_BYTES & (AXI_BYTES - 1)) != 0) $fatal(1, "AXI_BYTES is not a power of 2");
        if (AXI_BYTES > 128) $fatal(1, "AXI_BYTES must be no greater than 128");
    end

    logic can_issue;
    logic active;
    logic aw_fire;
    logic w_fire;
    logic b_fire;

    assign aw_fire = m_awvalid && m_awready;
    assign w_fire  = m_wvalid && m_wready;
    assign b_fire  = m_bvalid && m_bready;

    burst_tracker #(
        .COUNT_W($bits(req_beats))
    ) u_tracker (
        .clk,
        .rst,
        .req_fire(aw_fire),
        .req_beats,
        .beat_fire(w_fire),
        .resp_fire(b_fire),
        .can_issue,
        .active,
        .last(m_wlast),
        .resp_ready(m_bready),
        .done
    );

    assign req_ready = m_awready && can_issue;
    assign m_awvalid = req_valid && can_issue;
    assign m_awaddr  = req_addr;
    assign m_awlen   = 8'(req_beats - 1'b1);
    assign m_awsize  = 3'(AXI_SIZE);
    assign m_awburst = axi_pkg::INCR;
    assign m_awid    = 1'b0;
    assign m_awlock  = 1'b0;
    assign m_awcache = 4'b0000;
    assign m_awprot  = 3'b000;
    assign m_awqos   = 4'b0000;

    assign src_ready = active && m_wready;
    assign m_wvalid  = active && src_valid;
    assign m_wdata   = src_data;
    assign m_wstrb   = '1;
    assign m_wid     = 1'b0;
endmodule
