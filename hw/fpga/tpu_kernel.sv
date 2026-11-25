`include "axi_macros.svh"

module tpu_kernel #(
    parameter int unsigned C_S_AXI_CONTROL_ADDR_WIDTH = 9,
    parameter int unsigned C_S_AXI_CONTROL_DATA_WIDTH = 32,
    parameter int unsigned C_M_AXI_GMEM_ADDR_WIDTH    = 64,
    parameter int unsigned C_M_AXI_GMEM_DATA_WIDTH    = 256,
    parameter int unsigned C_M_AXI_GMEM_ID_WIDTH      = 1,

    parameter int unsigned IMEM_DEPTH                 = 4096,
    parameter int unsigned SMEM_DEPTH                 = 4096,
    parameter int unsigned SUBLANES                   = 4,
    parameter int unsigned LANES                      = 32,
    parameter int unsigned VREG_COUNT                 = 16,
    parameter int unsigned VMEM_DEPTH                 = 32768,
    parameter int unsigned POP_QUEUE_DEPTH            = 64,
    parameter bit          VMEM_URAM_OREG             = 1'b0,
    parameter int unsigned EUP_WIDTH                  = 1,
    parameter bit          XLU_QUANTIZE               = 1'b0,
    parameter int unsigned XLU_REDUCE_TREES           = 1,
    parameter bit          PERF_COUNTERS              = 1'b0,

    parameter int unsigned MXU_COUNT                  = 2,
    parameter bit          MXU_ENABLE                 = 1'b1,
    parameter int unsigned MXU_SLR_CROSSING           = 0,
    parameter int          MXU_ROW_QUEUE_DEPTH        = 128,
    parameter int          MXU_MATMUL_QUEUE_DEPTH     = 8,
    parameter int unsigned MXU_CODE_BITS              = 4,
    parameter bit          MXU_E2M1                   = 1'b0,
    parameter bit          MXU_MX                     = 1'b0,
    parameter int unsigned MXU_ACC_ROWS               = 1024,
    parameter bit          MXU_ACC_FP32               = 1'b0,
    parameter int unsigned MXU_N_W                    = 1,
    parameter int unsigned MXU_N_A                    = 1,
    parameter int unsigned MXU_W_BITS                 = 4,
    parameter int unsigned MXU_A_BITS                 = 4,
    parameter int unsigned MXU_PROD_W                 = 8,
    parameter bit          MXU_W_TWOS                 = 1'b0,
    parameter int unsigned MXU_PSUM_W                 = 12,
    parameter int unsigned MXU_TAG_FIFO_DEPTH         = 48,
    parameter bit          MXU_PUSH_NATURAL           = 1'b0,
    parameter bit          MXU_BANK_FREE_AT_LOAD      = 1'b0,
    parameter int unsigned MXU_DATAFLOW               = 1,
    parameter bit          MXU_MODE_WORD              = 1'b0,
    parameter int unsigned MXU_MODE_RESET             = 0,
    parameter bit          MXU_TILE_MODES             = 1'b0,
    parameter int unsigned MXU_W_CODES                = 1
) (
    input  logic                                    ap_clk,
    input  logic                                    ap_rst_n,

    input  logic [C_S_AXI_CONTROL_ADDR_WIDTH-1:0]   s_axi_control_AWADDR,
    input  logic                                    s_axi_control_AWVALID,
    output logic                                    s_axi_control_AWREADY,
    input  logic [C_S_AXI_CONTROL_DATA_WIDTH-1:0]   s_axi_control_WDATA,
    input  logic [C_S_AXI_CONTROL_DATA_WIDTH/8-1:0] s_axi_control_WSTRB,
    input  logic                                    s_axi_control_WVALID,
    output logic                                    s_axi_control_WREADY,
    output logic [1:0]                              s_axi_control_BRESP,
    output logic                                    s_axi_control_BVALID,
    input  logic                                    s_axi_control_BREADY,
    input  logic [C_S_AXI_CONTROL_ADDR_WIDTH-1:0]   s_axi_control_ARADDR,
    input  logic                                    s_axi_control_ARVALID,
    output logic                                    s_axi_control_ARREADY,
    output logic [C_S_AXI_CONTROL_DATA_WIDTH-1:0]   s_axi_control_RDATA,
    output logic [1:0]                              s_axi_control_RRESP,
    output logic                                    s_axi_control_RVALID,
    input  logic                                    s_axi_control_RREADY
    `TPU_AXI_PORT(0)
    `TPU_AXI_PORT(1)
    `TPU_AXI_PORT(2)
    `TPU_AXI_PORT(3)
    `TPU_AXI_PORT(4)
    `TPU_AXI_PORT(5)
    `TPU_AXI_PORT(6)
    `TPU_AXI_PORT(7)
    `TPU_AXI_PORT(8)
    `TPU_AXI_PORT(9)
    `TPU_AXI_PORT(10)
    `TPU_AXI_PORT(11)
    `TPU_AXI_PORT(12)
    `TPU_AXI_PORT(13)
    `TPU_AXI_PORT(14)
    `TPU_AXI_PORT(15)
    `TPU_AXI_PORT(16)
    `TPU_AXI_PORT(17)
    `TPU_AXI_PORT(18)
    `TPU_AXI_PORT(19)
    `TPU_AXI_PORT(20)
    `TPU_AXI_PORT(21)
    `TPU_AXI_PORT(22)
    `TPU_AXI_PORT(23)
    `TPU_AXI_PORT(24)
    `TPU_AXI_PORT(25)
    `TPU_AXI_PORT(26)
    `TPU_AXI_PORT(27)
    `TPU_AXI_PORT(28)
    `TPU_AXI_PORT(29)
    `TPU_AXI_PORT(30)
    `TPU_AXI_PORT(31)
);
    localparam int unsigned CHANNELS      = 32;
    localparam int unsigned AXI_BYTES     = C_M_AXI_GMEM_DATA_WIDTH / 8;
    logic                                          tpu_awvalid [CHANNELS];
    logic                                          tpu_awready [CHANNELS];
    logic            [C_M_AXI_GMEM_ADDR_WIDTH-1:0] tpu_awaddr  [CHANNELS];
    logic            [7:0]                         tpu_awlen   [CHANNELS];
    logic            [2:0]                         tpu_awsize  [CHANNELS];
    axi_pkg::burst_t                               tpu_awburst [CHANNELS];
    logic                                          tpu_awid    [CHANNELS];
    logic                                          tpu_awlock  [CHANNELS];
    logic            [3:0]                         tpu_awcache [CHANNELS];
    logic            [3:0]                         tpu_awqos   [CHANNELS];
    logic            [2:0]                         tpu_awprot  [CHANNELS];
    logic                                          tpu_wvalid  [CHANNELS];
    logic                                          tpu_wready  [CHANNELS];
    logic                                          tpu_wlast   [CHANNELS];
    logic                                          tpu_wid     [CHANNELS];
    logic            [C_M_AXI_GMEM_DATA_WIDTH-1:0] tpu_wdata   [CHANNELS];
    logic            [AXI_BYTES-1:0]               tpu_wstrb   [CHANNELS];
    logic                                          tpu_bvalid  [CHANNELS];
    logic                                          tpu_bready  [CHANNELS];
    logic                                          tpu_bid     [CHANNELS];
    axi_pkg::resp_t                                tpu_bresp   [CHANNELS];
    logic                                          tpu_arvalid [CHANNELS];
    logic                                          tpu_arready [CHANNELS];
    logic            [C_M_AXI_GMEM_ADDR_WIDTH-1:0] tpu_araddr  [CHANNELS];
    logic            [7:0]                         tpu_arlen   [CHANNELS];
    logic            [2:0]                         tpu_arsize  [CHANNELS];
    axi_pkg::burst_t                               tpu_arburst [CHANNELS];
    logic                                          tpu_arid    [CHANNELS];
    logic                                          tpu_arlock  [CHANNELS];
    logic            [3:0]                         tpu_arcache [CHANNELS];
    logic            [3:0]                         tpu_arqos   [CHANNELS];
    logic            [2:0]                         tpu_arprot  [CHANNELS];
    logic                                          tpu_rvalid  [CHANNELS];
    logic                                          tpu_rready  [CHANNELS];
    logic                                          tpu_rlast   [CHANNELS];
    logic                                          tpu_rid     [CHANNELS];
    logic            [C_M_AXI_GMEM_DATA_WIDTH-1:0] tpu_rdata   [CHANNELS];
    axi_pkg::resp_t                                tpu_rresp   [CHANNELS];

    `TPU_AXI_BIND(0)
    `TPU_AXI_BIND(1)
    `TPU_AXI_BIND(2)
    `TPU_AXI_BIND(3)
    `TPU_AXI_BIND(4)
    `TPU_AXI_BIND(5)
    `TPU_AXI_BIND(6)
    `TPU_AXI_BIND(7)
    `TPU_AXI_BIND(8)
    `TPU_AXI_BIND(9)
    `TPU_AXI_BIND(10)
    `TPU_AXI_BIND(11)
    `TPU_AXI_BIND(12)
    `TPU_AXI_BIND(13)
    `TPU_AXI_BIND(14)
    `TPU_AXI_BIND(15)
    `TPU_AXI_BIND(16)
    `TPU_AXI_BIND(17)
    `TPU_AXI_BIND(18)
    `TPU_AXI_BIND(19)
    `TPU_AXI_BIND(20)
    `TPU_AXI_BIND(21)
    `TPU_AXI_BIND(22)
    `TPU_AXI_BIND(23)
    `TPU_AXI_BIND(24)
    `TPU_AXI_BIND(25)
    `TPU_AXI_BIND(26)
    `TPU_AXI_BIND(27)
    `TPU_AXI_BIND(28)
    `TPU_AXI_BIND(29)
    `TPU_AXI_BIND(30)
    `TPU_AXI_BIND(31)

    tpu #(
        .AXI_ADDR_W(C_M_AXI_GMEM_ADDR_WIDTH),
        .CONTROL_ADDR_W(C_S_AXI_CONTROL_ADDR_WIDTH),
        .IMEM_DEPTH(IMEM_DEPTH),
        .SMEM_DEPTH(SMEM_DEPTH),
        .SUBLANES(SUBLANES),
        .LANES(LANES),
        .VREG_COUNT(VREG_COUNT),
        .VMEM_DEPTH(VMEM_DEPTH),
        .POP_QUEUE_DEPTH(POP_QUEUE_DEPTH),
        .VMEM_URAM_OREG(VMEM_URAM_OREG),
        .EUP_WIDTH(EUP_WIDTH),
        .XLU_QUANTIZE(XLU_QUANTIZE),
        .XLU_REDUCE_TREES(XLU_REDUCE_TREES),
        .PERF_COUNTERS(PERF_COUNTERS),
        .MXU_COUNT(MXU_COUNT),
        .MXU_ENABLE(MXU_ENABLE),
        .MXU_SLR_CROSSING(MXU_SLR_CROSSING),
        .MXU_ROW_QUEUE_DEPTH(MXU_ROW_QUEUE_DEPTH),
        .MXU_MATMUL_QUEUE_DEPTH(MXU_MATMUL_QUEUE_DEPTH),
        .MXU_CODE_BITS(MXU_CODE_BITS),
        .MXU_E2M1(MXU_E2M1),
        .MXU_MX(MXU_MX),
        .MXU_ACC_ROWS(MXU_ACC_ROWS),
        .MXU_ACC_FP32(MXU_ACC_FP32),
        .MXU_N_W(MXU_N_W),
        .MXU_N_A(MXU_N_A),
        .MXU_W_BITS(MXU_W_BITS),
        .MXU_A_BITS(MXU_A_BITS),
        .MXU_PROD_W(MXU_PROD_W),
        .MXU_W_TWOS(MXU_W_TWOS),
        .MXU_PSUM_W(MXU_PSUM_W),
        .MXU_TAG_FIFO_DEPTH(MXU_TAG_FIFO_DEPTH),
        .MXU_PUSH_NATURAL(MXU_PUSH_NATURAL),
        .MXU_BANK_FREE_AT_LOAD(MXU_BANK_FREE_AT_LOAD),
        .MXU_DATAFLOW(MXU_DATAFLOW),
        .MXU_MODE_WORD(MXU_MODE_WORD),
        .MXU_MODE_RESET(MXU_MODE_RESET),
        .MXU_TILE_MODES(MXU_TILE_MODES),
        .MXU_W_CODES(MXU_W_CODES)
    ) u_tpu (
        .clk       (ap_clk),
        .rst       (!ap_rst_n),
        .s_awaddr  (s_axi_control_AWADDR),
        .s_awvalid (s_axi_control_AWVALID),
        .s_awready (s_axi_control_AWREADY),
        .s_wdata   (s_axi_control_WDATA),
        .s_wstrb   (s_axi_control_WSTRB),
        .s_wvalid  (s_axi_control_WVALID),
        .s_wready  (s_axi_control_WREADY),
        .s_bresp   (s_axi_control_BRESP),
        .s_bvalid  (s_axi_control_BVALID),
        .s_bready  (s_axi_control_BREADY),
        .s_araddr  (s_axi_control_ARADDR),
        .s_arvalid (s_axi_control_ARVALID),
        .s_arready (s_axi_control_ARREADY),
        .s_rdata   (s_axi_control_RDATA),
        .s_rresp   (s_axi_control_RRESP),
        .s_rvalid  (s_axi_control_RVALID),
        .s_rready  (s_axi_control_RREADY),
        .m_awvalid (tpu_awvalid),
        .m_awready (tpu_awready),
        .m_awaddr  (tpu_awaddr),
        .m_awlen   (tpu_awlen),
        .m_awsize  (tpu_awsize),
        .m_awburst (tpu_awburst),
        .m_awid    (tpu_awid),
        .m_awlock  (tpu_awlock),
        .m_awcache (tpu_awcache),
        .m_awprot  (tpu_awprot),
        .m_awqos   (tpu_awqos),
        .m_wvalid  (tpu_wvalid),
        .m_wready  (tpu_wready),
        .m_wdata   (tpu_wdata),
        .m_wstrb   (tpu_wstrb),
        .m_wlast   (tpu_wlast),
        .m_wid     (tpu_wid),
        .m_bvalid  (tpu_bvalid),
        .m_bready  (tpu_bready),
        .m_bresp   (tpu_bresp),
        .m_bid     (tpu_bid),
        .m_arvalid (tpu_arvalid),
        .m_arready (tpu_arready),
        .m_araddr  (tpu_araddr),
        .m_arlen   (tpu_arlen),
        .m_arsize  (tpu_arsize),
        .m_arburst (tpu_arburst),
        .m_arid    (tpu_arid),
        .m_arlock  (tpu_arlock),
        .m_arcache (tpu_arcache),
        .m_arprot  (tpu_arprot),
        .m_arqos   (tpu_arqos),
        .m_rvalid  (tpu_rvalid),
        .m_rready  (tpu_rready),
        .m_rdata   (tpu_rdata),
        .m_rlast   (tpu_rlast),
        .m_rresp   (tpu_rresp),
        .m_rid     (tpu_rid)
    );

endmodule : tpu_kernel

`undef TPU_AXI_BIND
`undef TPU_AXI_PORT
