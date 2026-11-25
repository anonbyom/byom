`define TPU_AXI_PORT(N) \
    , output logic [C_M_AXI_GMEM_ID_WIDTH-1:0]        m_axi_gmem``N``_AWID \
    , output logic [C_M_AXI_GMEM_ADDR_WIDTH-1:0]      m_axi_gmem``N``_AWADDR \
    , output logic [7:0]                              m_axi_gmem``N``_AWLEN \
    , output logic [2:0]                              m_axi_gmem``N``_AWSIZE \
    , output logic [1:0]                              m_axi_gmem``N``_AWBURST \
    , output logic                                    m_axi_gmem``N``_AWLOCK \
    , output logic [3:0]                              m_axi_gmem``N``_AWCACHE \
    , output logic [2:0]                              m_axi_gmem``N``_AWPROT \
    , output logic [3:0]                              m_axi_gmem``N``_AWQOS \
    , output logic                                    m_axi_gmem``N``_AWVALID \
    , input  logic                                    m_axi_gmem``N``_AWREADY \
    , output logic [C_M_AXI_GMEM_DATA_WIDTH-1:0]      m_axi_gmem``N``_WDATA \
    , output logic [C_M_AXI_GMEM_DATA_WIDTH/8-1:0]    m_axi_gmem``N``_WSTRB \
    , output logic                                    m_axi_gmem``N``_WLAST \
    , output logic                                    m_axi_gmem``N``_WVALID \
    , input  logic                                    m_axi_gmem``N``_WREADY \
    , input  logic [C_M_AXI_GMEM_ID_WIDTH-1:0]        m_axi_gmem``N``_BID \
    , input  logic [1:0]                              m_axi_gmem``N``_BRESP \
    , input  logic                                    m_axi_gmem``N``_BVALID \
    , output logic                                    m_axi_gmem``N``_BREADY \
    , output logic [C_M_AXI_GMEM_ID_WIDTH-1:0]        m_axi_gmem``N``_ARID \
    , output logic [C_M_AXI_GMEM_ADDR_WIDTH-1:0]      m_axi_gmem``N``_ARADDR \
    , output logic [7:0]                              m_axi_gmem``N``_ARLEN \
    , output logic [2:0]                              m_axi_gmem``N``_ARSIZE \
    , output logic [1:0]                              m_axi_gmem``N``_ARBURST \
    , output logic                                    m_axi_gmem``N``_ARLOCK \
    , output logic [3:0]                              m_axi_gmem``N``_ARCACHE \
    , output logic [2:0]                              m_axi_gmem``N``_ARPROT \
    , output logic [3:0]                              m_axi_gmem``N``_ARQOS \
    , output logic                                    m_axi_gmem``N``_ARVALID \
    , input  logic                                    m_axi_gmem``N``_ARREADY \
    , input  logic [C_M_AXI_GMEM_ID_WIDTH-1:0]        m_axi_gmem``N``_RID \
    , input  logic [C_M_AXI_GMEM_DATA_WIDTH-1:0]      m_axi_gmem``N``_RDATA \
    , input  logic [1:0]                              m_axi_gmem``N``_RRESP \
    , input  logic                                    m_axi_gmem``N``_RLAST \
    , input  logic                                    m_axi_gmem``N``_RVALID \
    , output logic                                    m_axi_gmem``N``_RREADY

// One HBM port through registered slices; the block name is matched by the floorplan scripts.
`define TPU_AXI_BIND(N) \
    if (1) begin : gen_axi_registered``N \
        logic rst_axi; \
        reset_register u_rst (.clk(ap_clk), .rst_in(!ap_rst_n), .rst(rst_axi)); \
        axi_address_offset u_aw``N ( \
            .clk       (ap_clk), \
            .rst       (rst_axi), \
            .base_addr (64'd0), \
            .s_valid   (tpu_awvalid[N]), \
            .s_ready   (tpu_awready[N]), \
            .s_addr    (tpu_awaddr[N]), \
            .s_data    ({tpu_awlen[N], tpu_awsize[N], tpu_awburst[N], tpu_awid[N], \
                         tpu_awlock[N], tpu_awcache[N], tpu_awprot[N], tpu_awqos[N]}), \
            .m_valid   (m_axi_gmem``N``_AWVALID), \
            .m_ready   (m_axi_gmem``N``_AWREADY), \
            .m_addr    (m_axi_gmem``N``_AWADDR), \
            .m_data    ({m_axi_gmem``N``_AWLEN, m_axi_gmem``N``_AWSIZE, m_axi_gmem``N``_AWBURST, \
                         m_axi_gmem``N``_AWID, m_axi_gmem``N``_AWLOCK, m_axi_gmem``N``_AWCACHE, \
                         m_axi_gmem``N``_AWPROT, m_axi_gmem``N``_AWQOS}) \
        ); \
        axi_register_slice #( \
            .WIDTH(C_M_AXI_GMEM_DATA_WIDTH + AXI_BYTES + 1) \
        ) u_w``N ( \
            .clk     (ap_clk), \
            .rst     (rst_axi), \
            .s_valid (tpu_wvalid[N]), \
            .s_ready (tpu_wready[N]), \
            .s_data  ({tpu_wdata[N], tpu_wstrb[N], tpu_wlast[N]}), \
            .m_valid (m_axi_gmem``N``_WVALID), \
            .m_ready (m_axi_gmem``N``_WREADY), \
            .m_data  ({m_axi_gmem``N``_WDATA, m_axi_gmem``N``_WSTRB, m_axi_gmem``N``_WLAST}) \
        ); \
        axi_register_slice #( \
            .WIDTH(3) \
        ) u_b``N ( \
            .clk     (ap_clk), \
            .rst     (rst_axi), \
            .s_valid (m_axi_gmem``N``_BVALID), \
            .s_ready (m_axi_gmem``N``_BREADY), \
            .s_data  ({m_axi_gmem``N``_BRESP, m_axi_gmem``N``_BID}), \
            .m_valid (tpu_bvalid[N]), \
            .m_ready (tpu_bready[N]), \
            .m_data  ({tpu_bresp[N], tpu_bid[N]}) \
        ); \
        axi_address_offset u_ar``N ( \
            .clk       (ap_clk), \
            .rst       (rst_axi), \
            .base_addr (64'd0), \
            .s_valid   (tpu_arvalid[N]), \
            .s_ready   (tpu_arready[N]), \
            .s_addr    (tpu_araddr[N]), \
            .s_data    ({tpu_arlen[N], tpu_arsize[N], tpu_arburst[N], tpu_arid[N], \
                         tpu_arlock[N], tpu_arcache[N], tpu_arprot[N], tpu_arqos[N]}), \
            .m_valid   (m_axi_gmem``N``_ARVALID), \
            .m_ready   (m_axi_gmem``N``_ARREADY), \
            .m_addr    (m_axi_gmem``N``_ARADDR), \
            .m_data    ({m_axi_gmem``N``_ARLEN, m_axi_gmem``N``_ARSIZE, m_axi_gmem``N``_ARBURST, \
                         m_axi_gmem``N``_ARID, m_axi_gmem``N``_ARLOCK, m_axi_gmem``N``_ARCACHE, \
                         m_axi_gmem``N``_ARPROT, m_axi_gmem``N``_ARQOS}) \
        ); \
        axi_register_slice #( \
            .WIDTH(C_M_AXI_GMEM_DATA_WIDTH + 4) \
        ) u_r``N ( \
            .clk     (ap_clk), \
            .rst     (rst_axi), \
            .s_valid (m_axi_gmem``N``_RVALID), \
            .s_ready (m_axi_gmem``N``_RREADY), \
            .s_data  ({m_axi_gmem``N``_RDATA, m_axi_gmem``N``_RLAST, m_axi_gmem``N``_RRESP, m_axi_gmem``N``_RID}), \
            .m_valid (tpu_rvalid[N]), \
            .m_ready (tpu_rready[N]), \
            .m_data  ({tpu_rdata[N], tpu_rlast[N], tpu_rresp[N], tpu_rid[N]}) \
        ); \
    end
