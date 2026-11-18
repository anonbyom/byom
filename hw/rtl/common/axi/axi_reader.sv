module axi_reader #(
    parameter int unsigned AXI_ADDR_W = 64,
    parameter int unsigned AXI_BYTES = 64,

    localparam int unsigned AXI_DATA_W = 8 * AXI_BYTES,
    localparam int unsigned AXI_SIZE = $clog2(AXI_BYTES)
) (
    input  logic              clk,
    input  logic              rst,

    input  logic                  req_valid,
    output logic                  req_ready,
    input  logic [AXI_ADDR_W-1:0] req_addr,
    input  logic [8:0]            req_beats,

    output logic                  dst_valid,
    input  logic                  dst_ready,
    output logic [AXI_DATA_W-1:0] dst_data,

    output logic                  m_arvalid,
    input  logic                  m_arready,
    output logic [AXI_ADDR_W-1:0] m_araddr,
    output logic [7:0]            m_arlen,
    output logic [2:0]            m_arsize,
    output axi_pkg::burst_t       m_arburst,
    output logic                  m_arid,
    output logic                  m_arlock,
    output logic [3:0]            m_arcache,
    output logic [2:0]            m_arprot,
    output logic [3:0]            m_arqos,

    input  logic                  m_rvalid,
    output logic                  m_rready,
    input  logic [AXI_DATA_W-1:0] m_rdata,
    input  logic                  m_rlast,
    input  axi_pkg::resp_t        m_rresp,
    input  logic                  m_rid
);

    initial begin
        if (AXI_BYTES > 128) $fatal(1, "AXI_BYTES must be no greater than 128");
    end

    assign req_ready = m_arready;
    assign m_arvalid = req_valid;
    assign m_araddr  = req_addr;
    assign m_arlen   = 8'(req_beats - 1'b1);
    assign m_arsize  = 3'(AXI_SIZE);
    assign m_arburst = axi_pkg::INCR;
    assign m_arid    = 1'b0;
    assign m_arlock  = 1'b0;
    assign m_arcache = 4'b0000;
    assign m_arprot  = 3'b000;
    assign m_arqos   = 4'b0000;

    assign dst_valid = m_rvalid;
    assign dst_data  = m_rdata;
    assign m_rready  = dst_ready;

endmodule
