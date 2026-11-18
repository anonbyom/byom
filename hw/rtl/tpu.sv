module tpu #(
    parameter int AXI_ADDR_W                    = 64,
    parameter int CONTROL_ADDR_W                = 9,
    parameter int CHANNEL_BYTES                 = 512 * 1024 * 1024,
    parameter int FIFO_DEPTH                    = 4,
    parameter int IMEM_DEPTH                    = 1024,
    parameter int SMEM_DEPTH                    = 1024,
    parameter int SUBLANES                      = 4,
    parameter int LANES                         = 32,
    parameter int VREG_COUNT                    = isa_pkg::VECTOR_REGISTER_COUNT,
    parameter int VMEM_DEPTH                    = 32768,
    parameter int POP_QUEUE_DEPTH               = 64,
    parameter bit VMEM_URAM_OREG                = 1'b0,
    parameter int EUP_WIDTH                     = 1,
    parameter bit XLU_QUANTIZE                  = 1'b0,
    parameter int XLU_REDUCE_TREES              = 1,
    parameter bit PERF_COUNTERS                 = 1'b0,

    parameter int MXU_COUNT                     = 2,
    parameter bit MXU_ENABLE                    = 1'b1,
    parameter int unsigned MXU_SLR_CROSSING     = 0,
    parameter int MXU_ROW_QUEUE_DEPTH           = 128,
    parameter int MXU_PUSH_QUEUE_DEPTH          = 8,
    parameter int MXU_MATMUL_QUEUE_DEPTH        = 8,
    parameter int unsigned MXU_CODE_BITS        = 4,
    parameter bit MXU_E2M1                      = 1'b1,
    parameter bit MXU_MX                        = 1'b1,
    parameter int unsigned MXU_ACC_ROWS         = 1024,
    parameter bit MXU_ACC_FP32                  = 1'b0,
    parameter int unsigned MXU_N_W              = 3,
    parameter int unsigned MXU_N_A              = 3,
    parameter int unsigned MXU_W_BITS           = 4,
    parameter int unsigned MXU_A_BITS           = 4,
    parameter int unsigned MXU_PROD_W           = 8,
    parameter bit MXU_W_TWOS                    = 1'b0,
    parameter int unsigned MXU_PSUM_W           = 12,
    parameter int unsigned MXU_TAG_FIFO_DEPTH   = 48,
    parameter bit MXU_PUSH_NATURAL              = 1'b0,
    parameter bit MXU_BANK_FREE_AT_LOAD         = 1'b0,
    parameter int unsigned MXU_DATAFLOW         = 1,
    parameter bit MXU_MODE_WORD                 = 1'b0,
    parameter int unsigned MXU_MODE_RESET       = 0,
    parameter bit MXU_TILE_MODES                = 1'b0,
    parameter int unsigned MXU_W_CODES          = 1,

    localparam int CHANNELS  = 32,
    localparam int AXI_BYTES = 32,
    localparam int AXI_DATA_W = 8 * AXI_BYTES,
    localparam int IMEM_DMA_WORDS = IMEM_DEPTH * isa_pkg::BUNDLE_WIDTH / (CHANNELS * AXI_DATA_W),
    localparam int SMEM_DMA_WORDS = SMEM_DEPTH * isa_pkg::SCALAR_WORD_WIDTH / (CHANNELS * AXI_DATA_W),
    localparam int VMEM_DMA_WORDS = VMEM_DEPTH * LANES * isa_pkg::VECTOR_ELEMENT_WIDTH / (CHANNELS * AXI_DATA_W),
    localparam int SCALAR_DMA_WORDS = IMEM_DMA_WORDS > SMEM_DMA_WORDS ? IMEM_DMA_WORDS : SMEM_DMA_WORDS,
    localparam int MAX_DMA_WORDS = SCALAR_DMA_WORDS > VMEM_DMA_WORDS ? SCALAR_DMA_WORDS : VMEM_DMA_WORDS,
    localparam int VMEM_ADDR_W = (VMEM_DEPTH > 1) ? $clog2(VMEM_DEPTH) : 1,
    localparam int LOCAL_WRITE_PORTS = 2,
    localparam int LOCAL_READ_PORTS = 2,
    localparam int MXU_WORD_ROWS = SUBLANES * isa_pkg::VECTOR_ELEMENT_WIDTH / MXU_CODE_BITS,
    localparam bit MXU_OS = MXU_DATAFLOW == 2,
    localparam int SHELL_RETURN_STAGES = 2,
    localparam bit MXU_BEATS = MXU_E2M1 || MXU_DATAFLOW[1],
    localparam int MXU_BEAT_BITS = MXU_CODE_BITS > 8 ? MXU_CODE_BITS : 8
) (
    input  logic                      clk,
    input  logic                      rst,

    input  logic [CONTROL_ADDR_W-1:0] s_awaddr,
    input  logic                      s_awvalid,
    output logic                      s_awready,
    input  logic [31:0]               s_wdata,
    input  logic [3:0]                s_wstrb,
    input  logic                      s_wvalid,
    output logic                      s_wready,
    output logic [1:0]                s_bresp,
    output logic                      s_bvalid,
    input  logic                      s_bready,
    input  logic [CONTROL_ADDR_W-1:0] s_araddr,
    input  logic                      s_arvalid,
    output logic                      s_arready,
    output logic [31:0]               s_rdata,
    output logic [1:0]                s_rresp,
    output logic                      s_rvalid,
    input  logic                      s_rready,

    output logic                      m_awvalid [CHANNELS],
    input  logic                      m_awready [CHANNELS],
    output logic [AXI_ADDR_W-1:0]     m_awaddr  [CHANNELS],
    output logic [7:0]                m_awlen   [CHANNELS],
    output logic [2:0]                m_awsize  [CHANNELS],
    output axi_pkg::burst_t           m_awburst [CHANNELS],
    output logic                      m_awid    [CHANNELS],
    output logic                      m_awlock  [CHANNELS],
    output logic [3:0]                m_awcache [CHANNELS],
    output logic [2:0]                m_awprot  [CHANNELS],
    output logic [3:0]                m_awqos   [CHANNELS],

    output logic                      m_wvalid  [CHANNELS],
    input  logic                      m_wready  [CHANNELS],
    output logic [AXI_DATA_W-1:0]     m_wdata   [CHANNELS],
    output logic [AXI_BYTES-1:0]      m_wstrb   [CHANNELS],
    output logic                      m_wlast   [CHANNELS],
    output logic                      m_wid     [CHANNELS],

    input  logic                      m_bvalid  [CHANNELS],
    output logic                      m_bready  [CHANNELS],
    input  axi_pkg::resp_t            m_bresp   [CHANNELS],
    input  logic                      m_bid     [CHANNELS],

    output logic                      m_arvalid [CHANNELS],
    input  logic                      m_arready [CHANNELS],
    output logic [AXI_ADDR_W-1:0]     m_araddr  [CHANNELS],
    output logic [7:0]                m_arlen   [CHANNELS],
    output logic [2:0]                m_arsize  [CHANNELS],
    output axi_pkg::burst_t           m_arburst [CHANNELS],
    output logic                      m_arid    [CHANNELS],
    output logic                      m_arlock  [CHANNELS],
    output logic [3:0]                m_arcache [CHANNELS],
    output logic [2:0]                m_arprot  [CHANNELS],
    output logic [3:0]                m_arqos   [CHANNELS],

    input  logic                      m_rvalid  [CHANNELS],
    output logic                      m_rready  [CHANNELS],
    input  logic [AXI_DATA_W-1:0]     m_rdata   [CHANNELS],
    input  logic                      m_rlast   [CHANNELS],
    input  axi_pkg::resp_t            m_rresp   [CHANNELS],
    input  logic                      m_rid     [CHANNELS]
);
    import isa_pkg::*;

    typedef enum logic [1:0] {IDLE, BOOT_REQ, BOOT_WAIT, RUN} state_t;
    state_t       state_q;
    logic         enable;
    logic         halt;
    logic         ap_start;
    logic         boot_req_valid;
    logic         boot_req_ready;
    scalar_word_t boot_req_external_addr;
    scalar_word_t boot_req_imem_addr;
    scalar_word_t boot_req_length;
    logic         boot_done;
    logic         dma_write_done;
    logic         boot_accepted_q;
    logic         boot_done_q;
    logic         halt_q;

    logic         rst_control;
    logic         rst_scalar;
    reset_register u_rst_control (.clk, .rst_in(rst), .rst(rst_control));
    reset_register u_rst_scalar (.clk, .rst_in(rst), .rst(rst_scalar));

    // The mxu_mode kernel argument (latched at start), registered on its way to the MXUs.
    localparam bit MXU_MODE_ARG = MXU_MODE_WORD;
    logic [31:0] mxu_mode_arg;
    logic [31:0] mxu_mode_word;
    logic        mxu_os;
    assign mxu_os = MXU_DATAFLOW == 2 || MXU_DATAFLOW == 3 && mxu_mode_word[0];
    if (MXU_DATAFLOW == 3 && !MXU_MODE_ARG) begin : gen_bad_dataflow
        $fatal(1, "tpu: a unit with both dataflows takes its dataflow from mxu_mode: set MXU_MODE_WORD");
    end
    if (MXU_MODE_ARG) begin : gen_mode_arg
        shifter #(
            .WIDTH(32),
            .LENGTH(2)
        ) u_mxu_mode (
            .clk,
            .rst (1'b0),
            .en  (1'b1),
            .d   (mxu_mode_arg),
            .q   (mxu_mode_word)
        );
    end else begin : gen_mode_fixed
        assign mxu_mode_word = '0;
    end

    assign enable = state_q == RUN;
    assign boot_req_valid = state_q == BOOT_REQ;

    logic vector_idle, scalar_halt, halt_pending;
    logic [8:0] scalar_perf_events;
    logic [1:0] vector_perf_mxu_full;
    logic [1:0] vector_perf_xlu_block;
    logic [63:0] perf_counters [tpu_perf_pkg::COUNT];
    always_ff @(posedge clk) begin
        if (rst_control || !enable) halt_pending <= 1'b0;
        else if (scalar_halt) halt_pending <= 1'b1;
    end
    assign halt = halt_pending && vector_idle;

    logic                            valu_valid;
    logic                            vector_ready;
    valu_opcode_t                    valu_op;
    vector_reg_id_t                  valu_dest;
    vector_reg_id_t                  valu_x;
    vector_reg_id_t                  valu_y;
    logic [SROT_WIDTH-1:0]           valu_srot;
    valu_opcode_t                    valu2_op;
    vector_reg_id_t                  valu2_dest;
    vector_reg_id_t                  valu2_x;
    vector_reg_id_t                  valu2_y;
    valu_ctrl_t                      valu_ctrl;
    logic                            vmem_valid;
    vmem_opcode_t                    vmem_op;
    vector_reg_id_t                  vmem_reg;
    logic [VMEM_ADDR_W-1:0]          vmem_addr;
    vmem_stride_t                    vmem_stride_m1;
    vmem_skip_t                      vmem_skip;
    logic                            vex_valid;
    vex_opcode_t                     vex_op;
    vector_reg_id_t                  vex_x;
    mxu_engine_id_t                  vex_engine;
    logic                            vex_bank;
    logic [1:0]                      vex_mode;
    scale_reg_id_t                   vex_sreg;
    logic                            vr_valid;
    vr_opcode_t                      vr_op;
    vector_reg_id_t                  vr_dest;
    mxu_engine_id_t                  vr_engine;

    logic                            lane_mxu_valid  [LANES];
    logic                            lane_mxu_matmul [LANES];
    mxu_engine_id_t                  lane_mxu_engine [LANES];
    logic                            lane_mxu_bank   [LANES];
    logic [SUBLANES*VECTOR_ELEMENT_WIDTH-1:0] lane_mxu_data [LANES];
    logic [7:0]                      lane_mxu_scale [LANES];
    logic                            feed_push_drained   [LANES][MXU_COUNT];
    logic                            feed_matmul_drained [LANES][MXU_COUNT];
    logic                            push_drained   [MXU_COUNT];
    logic                            matmul_drained [MXU_COUNT];
    logic                            push_valid   [LANES][MXU_COUNT];
    logic                            push_bank    [LANES][MXU_COUNT];
    logic [MXU_CODE_BITS-1:0]        push_code  [LANES][MXU_COUNT];
    logic [7:0]                      push_scale [LANES][MXU_COUNT];
    logic                            matmul_valid [LANES][MXU_COUNT];
    logic [MXU_BEAT_BITS-1:0]        matmul_data [LANES][MXU_COUNT];
    logic [7:0]                      matmul_scale [LANES][MXU_COUNT];
    logic [SUBLANES*VECTOR_ELEMENT_WIDTH-1:0] matmul_word [LANES][MXU_COUNT];
    logic                            matmul_cmd_valid [MXU_COUNT];
    mxu_command_t                    matmul_cmd       [MXU_COUNT];
    logic                            mxu_matmul_freed [MXU_COUNT];
    logic [1:0]                      mxu_push_freed   [MXU_COUNT];
    logic                            result_valid [LANES][SUBLANES][MXU_COUNT];
    logic [VECTOR_ELEMENT_WIDTH-1:0] result_data  [LANES][SUBLANES][MXU_COUNT];
    logic                            transpose_push_valid [LANES];
    logic [SUBLANES*VECTOR_ELEMENT_WIDTH-1:0] transpose_push_data [LANES];
    isa_pkg::mxu_engine_id_t         transpose_push_func [LANES];
    logic [2:0]                      transpose_push_quantize [LANES];
    logic                            transpose_pop_valid [LANES];
    logic [VECTOR_ELEMENT_WIDTH-1:0] transpose_pop_data [LANES][SUBLANES];

    logic                            vector_dma_start;
    logic                            vector_dma_write;
    scalar_word_t                    vector_dma_base;
    scalar_word_t                    vector_dma_length;

    logic                            dma_read_req_valid;
    logic                            dma_read_req_ready;
    logic                            dma_read_local_write_sel;
    logic                            dma_read_scalar_fast;
    logic                            scalar_write_fast        [CHANNELS];
    scalar_word_t                    dma_read_external_addr;
    scalar_word_t                    dma_read_length;
    logic                            dma_read_done;
    logic                            dma_write_req_valid;
    logic                            dma_write_req_ready;
    logic                            dma_write_local_read_sel;
    scalar_word_t                    dma_write_external_addr;
    scalar_word_t                    dma_write_length;

    logic                            local_write_valid [LOCAL_WRITE_PORTS][CHANNELS];
    logic                            local_write_ready [LOCAL_WRITE_PORTS][CHANNELS];
    logic [AXI_DATA_W-1:0]           local_write_data  [LOCAL_WRITE_PORTS][CHANNELS];

    logic                            local_read_valid [LOCAL_READ_PORTS][CHANNELS];
    logic                            local_read_ready [LOCAL_READ_PORTS][CHANNELS];
    logic [AXI_DATA_W-1:0]           local_read_data  [LOCAL_READ_PORTS][CHANNELS];

    logic                            channel_local_write_valid [CHANNELS][LOCAL_WRITE_PORTS];
    logic                            channel_local_write_ready [CHANNELS][LOCAL_WRITE_PORTS];
    logic [AXI_DATA_W-1:0]           channel_local_write_data  [CHANNELS][LOCAL_WRITE_PORTS];

    logic                            channel_local_read_valid [CHANNELS][LOCAL_READ_PORTS];
    logic                            channel_local_read_ready [CHANNELS][LOCAL_READ_PORTS];
    logic [AXI_DATA_W-1:0]           channel_local_read_data  [CHANNELS][LOCAL_READ_PORTS];

    logic                            vmem_write_idle [CHANNELS];
    logic                            channel_write_idle [CHANNELS];

    logic                            vector_write_valid [LANES];
    logic                            vector_write_ready [LANES];
    logic [AXI_DATA_W-1:0]           vector_write_data  [LANES];
    logic                            vector_write_idle  [LANES];
    logic                            vector_read_valid  [LANES];
    logic                            vector_read_ready  [LANES];
    logic [AXI_DATA_W-1:0]           vector_read_data   [LANES];

    scalar_unit #(
        .CHANNELS(CHANNELS),
        .IMEM_DEPTH(IMEM_DEPTH),
        .SMEM_DEPTH(SMEM_DEPTH),
        .BEAT_W(AXI_DATA_W),
        .VMEM_DEPTH(VMEM_DEPTH)
    ) u_scalar (
        .clk,
        .rst                (rst_scalar),
        .enable             (enable && !halt_pending),
        .halt               (scalar_halt),
        .vector_dma_start,
        .vector_dma_write,
        .vector_dma_base,
        .vector_dma_length,
        .boot_req_valid,
        .boot_req_ready,
        .boot_req_external_addr,
        .boot_req_imem_addr,
        .boot_req_length,
        .boot_done,
        .dma_read_req_valid,
        .dma_read_req_ready,
        .dma_read_local_write_sel,
        .dma_read_scalar_fast,
        .scalar_write_fast,
        .dma_read_external_addr,
        .dma_read_length,
        .dma_read_done,
        .dma_write_req_valid,
        .dma_write_req_ready,
        .dma_write_local_read_sel,
        .dma_write_external_addr,
        .dma_write_length,
        .dma_write_done,
        .dma_write_valid    (local_write_valid[0]),
        .dma_write_ready    (local_write_ready[0]),
        .dma_write_data     (local_write_data[0]),
        .dma_response_valid (local_read_valid[0]),
        .dma_response_ready (local_read_ready[0]),
        .dma_response_data  (local_read_data[0]),
        .valu_valid,
        .vector_ready,
        .valu_op,
        .valu_dest,
        .valu_x,
        .valu_y,
        .valu_srot,
        .valu2_op,
        .valu2_dest,
        .valu2_x,
        .valu2_y,
        .valu_ctrl,
        .vmem_valid,
        .vmem_op,
        .vmem_reg,
        .vmem_addr,
        .vmem_stride_m1,
        .vmem_skip,
        .vex_valid,
        .vex_op,
        .vex_x,
        .vex_engine,
        .vex_bank (vex_bank),
        .vex_mode (vex_mode),
        .vex_sreg (vex_sreg),
        .vr_valid,
        .vr_op,
        .vr_dest,
        .vr_engine,
        .perf_events        (scalar_perf_events)
    );

    // DMA -> local writes through a register slice. SMEM/IMEM (port 0) through a one-entry buffer.
    for (genvar c = 0; c < CHANNELS; c++) begin : gen_ports
        logic [LOCAL_WRITE_PORTS-1:0] input_mask, output_mask, output_ready;
        logic input_ready, output_valid;
        logic [AXI_DATA_W-1:0] output_data;
        logic [3:0] outstanding;
        logic scalar_full_q;
        logic rst_port;
        wire accept = (|input_mask) && input_ready;
        wire retire = output_valid && (|output_ready);

        reset_register u_rst (.clk, .rst_in(rst), .rst(rst_port));

        axi_register_slice #(
            .WIDTH(LOCAL_WRITE_PORTS + AXI_DATA_W)
        ) u_write_handoff (
            .clk,
            .rst     (rst_port),
            .s_valid (|input_mask),
            .s_ready (input_ready),
            .s_data  ({input_mask, channel_local_write_data[c][0]}),
            .m_valid (output_valid),
            .m_ready (|output_ready),
            .m_data  ({output_mask, output_data})
        );
        credit_counter #(
            .WIDTH(4)
        ) u_outstanding (
            .clk,
            .rst   (rst_port),
            .add   (4'(accept)),
            .sub   (4'(retire)),
            .count (outstanding)
        );

        always_ff @(posedge clk) begin
            if (rst_port) channel_write_idle[c] <= 1'b0;
            else channel_write_idle[c] <= outstanding == 0 && !accept && !scalar_full_q && vmem_write_idle[c];
        end
        for (genvar p = 0; p < LOCAL_WRITE_PORTS; p++) begin : gen_write
            assign input_mask[p] = channel_local_write_valid[c][p];
            assign channel_local_write_ready[c][p] = input_ready;
            if (p == 0) begin : gen_scalar_buffer
                // A one-entry buffer with a registered ready (half rate is enough for SMEM/IMEM loads).
                logic [AXI_DATA_W-1:0] scalar_data_q;
                assign output_ready[p] = output_mask[p] && !scalar_full_q;
                assign local_write_valid[p][c] = scalar_full_q;
                assign local_write_data[p][c] = scalar_data_q;
                always_ff @(posedge clk) begin
                    if (rst_port) scalar_full_q <= 1'b0;
                    else if (scalar_full_q) scalar_full_q <= !local_write_ready[p][c];
                    else scalar_full_q <= output_valid && output_mask[p];
                end
                always_ff @(posedge clk) if (!scalar_full_q) scalar_data_q <= output_data;
            end else begin : gen_direct_port
                assign output_ready[p] = output_mask[p] && local_write_ready[p][c];
                assign local_write_valid[p][c] = output_valid && output_mask[p];
                assign local_write_data[p][c] = output_data;
            end
        end
        for (genvar p = 0; p < LOCAL_READ_PORTS; p++) begin : gen_read
            assign channel_local_read_valid[c][p] = local_read_valid[p][c];
            assign local_read_ready[p][c] = channel_local_read_ready[c][p];
            assign channel_local_read_data[c][p] = local_read_data[p][c];
        end
    end

    dma_unit #(
        .CHANNELS(CHANNELS),
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_BYTES(AXI_BYTES),
        .CHANNEL_BYTES(CHANNEL_BYTES),
        .LOCAL_WRITE_PORTS(LOCAL_WRITE_PORTS),
        .LOCAL_READ_PORTS(LOCAL_READ_PORTS),
        .FIFO_DEPTH(FIFO_DEPTH),
        // Port 0 (SMEM/IMEM) visits the channels in a fixed order.
        .SERIALIZED_WRITE_PORTS(LOCAL_WRITE_PORTS'(1)),
        .SERIALIZED_READ_PORTS(LOCAL_READ_PORTS'(1)),
        .LOCAL_DEPTH(MAX_DMA_WORDS)
    ) u_dma (
        .clk,
        .rst,

        .dma_read_req_valid,
        .dma_read_req_ready,
        .dma_read_local_write_sel,
        .dma_read_scalar_fast,
        .scalar_write_fast,
        .dma_read_external_addr,
        .dma_read_length,
        .dma_read_done,

        .dma_write_req_valid,
        .dma_write_req_ready,
        .dma_write_local_read_sel,
        .dma_write_external_addr,
        .dma_write_length,
        .dma_write_done,

        .local_write_valid (channel_local_write_valid),
        .local_write_ready (channel_local_write_ready),
        .local_write_data  (channel_local_write_data),
        .local_write_idle  (channel_write_idle),
        .local_read_valid  (channel_local_read_valid),
        .local_read_ready  (channel_local_read_ready),
        .local_read_data   (channel_local_read_data),

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
        .m_bid,
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

    vector_unit #(
        .LANES(LANES),
        .SUBLANES(SUBLANES),
        .VREG_COUNT(VREG_COUNT),
        .VMEM_DEPTH(VMEM_DEPTH),
        .MXU_COUNT(MXU_COUNT),
        .RETURN_STAGES(SHELL_RETURN_STAGES),
        .VMEM_URAM_OREG(VMEM_URAM_OREG),
        .EUP_WIDTH(EUP_WIDTH),
        .PUSH_QUEUE_DEPTH(MXU_PUSH_QUEUE_DEPTH),
        .MATMUL_QUEUE_DEPTH(MXU_MATMUL_QUEUE_DEPTH),
        .MXU_MATMUL_SLOTS(MXU_ENABLE ? (MXU_ROW_QUEUE_DEPTH / MXU_WORD_ROWS < 32 ?
            MXU_ROW_QUEUE_DEPTH / MXU_WORD_ROWS : 32) : 0),
        .POPS_PER_MATMUL(MXU_WORD_ROWS / 4),
        .POPS_PER_BLOCK(LANES / 4),
        .MXU_PUSH_SLOTS(!MXU_ENABLE ? 0 : MXU_OS ? MXU_ROW_QUEUE_DEPTH / MXU_WORD_ROWS :
            (LANES * MXU_W_CODES + MXU_WORD_ROWS - 1) / MXU_WORD_ROWS),
        .SCALE_REGS(MXU_MX),
        .MXU_TILE_MODES(MXU_TILE_MODES),
        .POP_QUEUE_DEPTH(POP_QUEUE_DEPTH),
        .XLU_QUANTIZE(XLU_QUANTIZE),
        .XLU_REDUCE_TREES(XLU_REDUCE_TREES)
    ) u_vector (
        .clk,
        .rst,
        .mxu_os,
        .idle               (vector_idle),
        .perf_mxu_full      (vector_perf_mxu_full),
        .perf_xlu_block     (vector_perf_xlu_block),

        .valu_valid,
        .vector_ready,
        .valu_op,
        .valu_dest,
        .valu_x,
        .valu_y,
        .valu_srot,
        .valu2_op,
        .valu2_dest,
        .valu2_x,
        .valu2_y,
        .valu_ctrl,

        .vmem_valid,
        .vmem_op,
        .vmem_reg,
        .vmem_addr,
        .vmem_stride_m1,
        .vmem_skip,

        .vex_valid,
        .vex_op,
        .vex_x,
        .vex_engine,
        .vex_bank (vex_bank),
        .vex_mode (vex_mode),
        .vex_sreg (vex_sreg),

        .vr_valid,
        .vr_op,
        .vr_dest,
        .vr_engine,

        .mxu_valid          (lane_mxu_valid),
        .mxu_matmul         (lane_mxu_matmul),
        .mxu_engine         (lane_mxu_engine),
        .mxu_bank           (lane_mxu_bank),
        .mxu_data           (lane_mxu_data),
        .mxu_scale          (lane_mxu_scale),
        .push_drained,
        .matmul_drained,
        .matmul_cmd_valid,
        .matmul_cmd,
        .mxu_matmul_freed,
        .mxu_push_freed,

        .mxu_pop_valid      (result_valid),
        .mxu_pop_data       (result_data),
        .transpose_push_valid,
        .transpose_push_data,
        .transpose_push_func,
        .transpose_push_quantize,
        .transpose_pop_valid,
        .transpose_pop_data,

        .dma_start          (vector_dma_start),
        .dma_write          (vector_dma_write),
        .dma_base           (vector_dma_base),
        .dma_length         (vector_dma_length),
        .dma_write_valid    (vector_write_valid),
        .dma_write_ready    (vector_write_ready),
        .dma_write_data     (vector_write_data),
        .dma_write_idle     (vector_write_idle),

        .dma_response_valid (vector_read_valid),
        .dma_response_ready (vector_read_ready),
        .dma_response_data  (vector_read_data)
    );

    for (genvar c = 0; c < CHANNELS; c++) begin : gen_vector_channel
        if (c < LANES) begin : gen_lane
            assign vector_write_valid[c]   = local_write_valid[1][c];
            assign local_write_ready[1][c] = vector_write_ready[c];
            assign vector_write_data[c]    = local_write_data[1][c];
            assign vmem_write_idle[c]      = vector_write_idle[c];
            assign local_read_valid[1][c]  = vector_read_valid[c];
            assign vector_read_ready[c]    = local_read_ready[1][c];
            assign local_read_data[1][c]   = vector_read_data[c];
        end else begin : gen_unused
            assign local_write_ready[1][c] = 1'b1;
            assign vmem_write_idle[c]      = 1'b1;
            assign local_read_valid[1][c]  = 1'b1;
            assign local_read_data[1][c]   = '0;
        end
    end

    // XLU in SLR2: the floorplan scripts match gen_transpose's blocks.
    if (1) begin : gen_transpose
        logic input_valid [LANES];
        logic [SUBLANES*VECTOR_ELEMENT_WIDTH-1:0] input_data [LANES];
        logic output_valid;
        logic [SUBLANES*VECTOR_ELEMENT_WIDTH-1:0] output_data [LANES];
        logic [1:0] input_func;
        logic [2:0] input_quantize;
        // The function travels with the last lane's beat.
        if (1) begin : gen_func
            logic [4:0] tx_func;
            shifter #(
                .WIDTH(5),
                .LENGTH(1)
            ) u_tx_func (
                .clk,
                .rst (1'b0),
                .en  (1'b1),
                .d   ({XLU_QUANTIZE ? transpose_push_quantize[LANES-1] : 3'b000, 2'(transpose_push_func[LANES-1])}),
                .q   (tx_func)
            );
            logic [4:0] rx_func;
            shifter #(
                .WIDTH(5),
                .LENGTH(1)
            ) u_rx_func (
                .clk,
                .rst (1'b0),
                .en  (1'b1),
                .d   (tx_func),
                .q   (rx_func)
            );
            assign {input_quantize, input_func} = rx_func;
        end

        for (genvar lane = 0; lane < LANES; lane++) begin : gen_input
            logic tx_valid, rx_valid;
            logic [SUBLANES*VECTOR_ELEMENT_WIDTH-1:0] tx_data, rx_data;
            // tx / rx: the SLR1 side of the crossing.
            shifter #(
                .WIDTH(1),
                .LENGTH(1)
            ) u_tx_valid (
                .clk,
                .rst (1'b0),
                .en  (1'b1),
                .d   (transpose_push_valid[lane]),
                .q   (tx_valid)
            );
            shifter #(
                .WIDTH(SUBLANES*VECTOR_ELEMENT_WIDTH),
                .LENGTH(1)
            ) u_tx_data (
                .clk,
                .rst (1'b0),
                .en  (1'b1),
                .d   (transpose_push_data[lane]),
                .q   (tx_data)
            );
            shifter #(
                .WIDTH(1),
                .LENGTH(1)
            ) u_rx_valid (
                .clk,
                .rst (1'b0),
                .en  (1'b1),
                .d   (tx_valid),
                .q   (rx_valid)
            );
            shifter #(
                .WIDTH(SUBLANES*VECTOR_ELEMENT_WIDTH),
                .LENGTH(1)
            ) u_rx_data (
                .clk,
                .rst (1'b0),
                .en  (1'b1),
                .d   (tx_data),
                .q   (rx_data)
            );
            assign input_valid[lane] = rx_valid;
            assign input_data[lane]  = rx_data;
        end

        xlu #(
            .LANES(LANES),
            .SUBLANES(SUBLANES),
            .WIDTH(VECTOR_ELEMENT_WIDTH),
            .XLU_QUANTIZE(XLU_QUANTIZE),
            .XLU_REDUCE_TREES(XLU_REDUCE_TREES)
        ) u_transpose (
            .clk,
            .rst         (1'b0),
            .in_valid    (input_valid),
            .in_data     (input_data),
            .in_func     (input_func),
            .in_quantize (input_quantize),
            .out_valid   (output_valid),
            .out_data    (output_data)
        );

        for (genvar lane = 0; lane < LANES; lane++) begin : gen_return
            logic valid;
            logic [SUBLANES*VECTOR_ELEMENT_WIDTH-1:0] data;
            // The lane skew, in SLR1.
            shifter #(
                .WIDTH(1),
                .LENGTH(lane+2)
            ) u_valid (
                .clk,
                .rst (1'b0),
                .en  (1'b1),
                .d   (output_valid),
                .q   (valid)
            );
            shifter #(
                .WIDTH(SUBLANES*VECTOR_ELEMENT_WIDTH),
                .LENGTH(lane+2)
            ) u_data (
                .clk,
                .rst (1'b0),
                .en  (1'b1),
                .d   (output_data[lane]),
                .q   (data)
            );
            assign transpose_pop_valid[lane] = valid;
            for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_sublane
                assign transpose_pop_data[lane][sublane] =
                    data[sublane*VECTOR_ELEMENT_WIDTH +: VECTOR_ELEMENT_WIDTH];
            end
        end
    end

    // Each lane's PUSH/MATMUL words cross to the MXUs' SLR, mxu_feed serializes them there.
    for (genvar lane = 0; lane < LANES; lane++) begin : gen_feed
        localparam int unsigned FEED_W = 8 + 3 + $bits(mxu_engine_id_t) + SUBLANES*VECTOR_ELEMENT_WIDTH;
        logic [FEED_W-1:0] word [3];
        logic                  in_valid, in_matmul, in_bank;
        mxu_engine_id_t        in_engine;
        logic [SUBLANES*VECTOR_ELEMENT_WIDTH-1:0] in_data;
        logic [7:0]            in_scale;

        assign word[0] = {lane_mxu_scale[lane], lane_mxu_valid[lane], lane_mxu_matmul[lane], lane_mxu_engine[lane],
                          lane_mxu_bank[lane], lane_mxu_data[lane]};
        assign {in_scale, in_valid, in_matmul, in_engine, in_bank, in_data} = word[2];
        if (MXU_SLR_CROSSING != 0) begin : gen_crossing
            for (genvar stage = 0; stage < 2; stage++) begin : gen_stage
                shifter #(
                    .WIDTH(FEED_W),
                    .LENGTH(1)
                ) u_stage (
                    .clk,
                    .rst (1'b0),
                    .en  (1'b1),
                    .d   (word[stage]),
                    .q   (word[stage+1])
                );
            end
        end else begin : gen_direct
            assign word[2] = word[0];
        end

        mxu_feed #(
            .SUBLANES(SUBLANES),
            .ELEMENT_WIDTH(VECTOR_ELEMENT_WIDTH),
            .MXU_COUNT(MXU_COUNT),
            .PUSH_QUEUE_DEPTH(MXU_PUSH_QUEUE_DEPTH),
            .MATMUL_QUEUE_DEPTH(MXU_MATMUL_QUEUE_DEPTH),
            .MATMUL_WORD(!MXU_BEATS),
            .MATMUL_BEAT_BITS(MXU_BEAT_BITS),
            .PUSH_NATURAL(MXU_PUSH_NATURAL),
            .CODE_BITS(MXU_CODE_BITS)
        ) u_feed (
            .clk,
            .in_valid,
            .in_matmul,
            .in_engine,
            .in_bank,
            .in_data,
            .in_scale,
            .push_valid     (push_valid[lane]),
            .push_bank      (push_bank[lane]),
            .push_code      (push_code[lane]),
            .push_scale     (push_scale[lane]),
            .matmul_valid   (matmul_valid[lane]),
            .matmul_data    (matmul_data[lane]),
            .matmul_scale   (matmul_scale[lane]),
            .matmul_word    (matmul_word[lane]),
            .push_drained   (feed_push_drained[lane]),
            .matmul_drained (feed_matmul_drained[lane])
        );
    end

    // shell timing for engine 0, lane 0, in cycles (read by tools/byom/integrate.py).
    localparam int unsigned SHELL_VEX_OUT         = 3;
    localparam int unsigned SHELL_FEED_CROSSING   = MXU_SLR_CROSSING != 0 ? 2 : 0;
    localparam int unsigned SHELL_ENGINE_CROSSING = MXU_SLR_CROSSING[0] ? 2 : 0;
    localparam int unsigned SHELL_PUSH_FEED       = SHELL_VEX_OUT + SHELL_FEED_CROSSING + 2;
    localparam int unsigned SHELL_PUSH_ROW_CYCLES = 1;
    localparam int unsigned SHELL_A_WORD_ROWS     = MXU_BEATS ? MXU_BEAT_BITS / MXU_CODE_BITS : MXU_WORD_ROWS;
    localparam int unsigned SHELL_MATMUL_WORD     = SHELL_VEX_OUT + SHELL_FEED_CROSSING + (MXU_BEATS ? 2 : 0) + 2 +
                                                    (SHELL_A_WORD_ROWS != MXU_N_A ? 1 : 0);
    // MX: vector_mxu releases a MATMUL / PRELOAD command once the row scales of its word are in (gen_scale). Row r's
    // scale comes on lane r with the word, a cycle a lane after lane 0's, so the last one is there MXU_WORD_ROWS - 1
    // cycles after lane 0's word.
    localparam int unsigned MX_SCALES_IN          = MXU_MX ? SHELL_MATMUL_WORD + MXU_WORD_ROWS - 1 : 0;
    localparam int unsigned SHELL_MATMUL_COMMAND  = MX_SCALES_IN > 4 + SHELL_ENGINE_CROSSING ? MX_SCALES_IN
                                                                                             : 4 + SHELL_ENGINE_CROSSING;
    // The unit starts a MATMUL's feed with its word, or, when the command comes after the word (MX), the cycle after it
    // takes the command (mxu.sv; Verilator, 4d11: command 24, first row scheduled from 25).
    localparam int unsigned SHELL_MATMUL_FEED     = SHELL_MATMUL_WORD > SHELL_MATMUL_COMMAND ? SHELL_MATMUL_WORD
                                                                                             : SHELL_MATMUL_COMMAND + 1;
    localparam int unsigned SHELL_RESULT_IN       = SHELL_ENGINE_CROSSING;
    localparam int unsigned SHELL_RESULT_COUNT    = 1 + SHELL_RETURN_STAGES;
    localparam int unsigned SHELL_CREDIT_RETURN   = SHELL_ENGINE_CROSSING + SHELL_RETURN_STAGES;
    localparam int unsigned SHELL_VLD_READY       = 3 + int'(VMEM_URAM_OREG);

    for (genvar engine = 0; engine < MXU_COUNT; engine++) begin : gen_mxu
        if (MXU_ENABLE) begin : gen_enabled
            logic                            b_valid [LANES];
            logic [MXU_CODE_BITS-1:0]        b_code  [LANES];
            logic [7:0]                      b_scale [LANES];
            logic                            b_bank  [LANES];
            logic                            a_valid [LANES];
            logic [MXU_BEAT_BITS-1:0]        a_data  [LANES];
            logic [7:0]                      a_scale [LANES];
            logic                            c_valid [LANES][SUBLANES];
            logic [VECTOR_ELEMENT_WIDTH-1:0] c_data  [LANES][SUBLANES];
            logic         command_valid;
            mxu_command_t command;
            logic matmul_freed;
            logic [1:0] push_freed;

            if ((MXU_SLR_CROSSING >> engine) & 1) begin : gen_command_crossing
                localparam int unsigned COMMAND_W = 1 + $bits(mxu_command_t);
                logic [COMMAND_W-1:0] command_tx;
                shifter #(
                    .WIDTH(COMMAND_W),
                    .LENGTH(1)
                ) u_tx (
                    .clk,
                    .rst (1'b0),
                    .en  (1'b1),
                    .d   ({matmul_cmd_valid[engine], matmul_cmd[engine]}),
                    .q   (command_tx)
                );
                shifter #(
                    .WIDTH(COMMAND_W),
                    .LENGTH(1)
                ) u_rx (
                    .clk,
                    .rst (1'b0),
                    .en  (1'b1),
                    .d   (command_tx),
                    .q   ({command_valid, command})
                );
                // Freed slots back to vector_issue.
                logic [4:0] freed_tx;
                shifter #(
                    .WIDTH(5),
                    .LENGTH(1)
                ) u_freed_tx (
                    .clk,
                    .rst (1'b0),
                    .en  (1'b1),
                    .d   ({matmul_freed, push_freed, feed_push_drained[0][engine], feed_matmul_drained[0][engine]}),
                    .q   (freed_tx)
                );
                shifter #(
                    .WIDTH(5),
                    .LENGTH(1)
                ) u_freed_rx (
                    .clk,
                    .rst (1'b0),
                    .en  (1'b1),
                    .d   (freed_tx),
                    .q   ({mxu_matmul_freed[engine], mxu_push_freed[engine], push_drained[engine], matmul_drained[engine]})
                );
            end else begin : gen_direct_command
                assign command_valid = matmul_cmd_valid[engine];
                assign command = matmul_cmd[engine];
                assign mxu_matmul_freed[engine] = matmul_freed;
                assign mxu_push_freed[engine] = push_freed;
                assign push_drained[engine] = feed_push_drained[0][engine];
                assign matmul_drained[engine] = feed_matmul_drained[0][engine];
            end

            localparam int unsigned A_WORD_ROWS = MXU_BEATS ? MXU_BEAT_BITS / MXU_CODE_BITS : MXU_WORD_ROWS;
            logic [MXU_CODE_BITS*A_WORD_ROWS-1:0] a_word [LANES];
            // Only an output-stationary unit uses its reset (it flushes its PEs).
            logic rst_mxu;
            if (MXU_DATAFLOW[1]) begin : gen_rst
                reset_register u_rst_mxu (.clk, .rst_in(rst), .rst(rst_mxu));
            end else begin : gen_no_rst
                assign rst_mxu = 1'b0;
            end
            for (genvar lane = 0; lane < LANES; lane++) begin : gen_word
                if (MXU_BEATS) begin : gen_beat
                    assign a_word[lane] = a_data[lane];
                end else begin : gen_whole
                    assign a_word[lane] = matmul_word[lane][engine];
                end
            end
            vector_mxu #(
                .LANES(LANES),
                .SUBLANES(SUBLANES),
                .ELEMENT_WIDTH(VECTOR_ELEMENT_WIDTH),
                .ROW_QUEUE_DEPTH(MXU_ROW_QUEUE_DEPTH),
                .TAG_FIFO_DEPTH(MXU_TAG_FIFO_DEPTH),
                .ACC_ENABLE(1'b1),
                .ACC_ROWS(MXU_ACC_ROWS),
                .E2M1(MXU_E2M1),
                .MX(MXU_MX),
                .ACC_FP32(MXU_ACC_FP32),
                .N_W(MXU_N_W),
                .N_A(MXU_N_A),
                .W_BITS(MXU_W_BITS),
                .A_BITS(MXU_A_BITS),
                .PROD_W(MXU_PROD_W),
                .W_TWOS(MXU_W_TWOS),
                .PSUM_W(MXU_PSUM_W),
                .CODE_BITS(MXU_CODE_BITS),
                .W_CODES(MXU_W_CODES),
                .TILE_MODES(MXU_TILE_MODES),
                .BANK_FREE_AT_LOAD(MXU_BANK_FREE_AT_LOAD),
                .A_WORD_ROWS(A_WORD_ROWS),
                .DATAFLOW(MXU_DATAFLOW)
            ) u_adapter (
                .clk,
                .rst                (rst_mxu),
                .dataflow_os        (mxu_os),
                .mode_word          (mxu_mode_word),
                .matmul_cmd_valid   (command_valid),
                .matmul_cmd_preload (command.preload),
                .matmul_cmd_bank    (command.bank),
                .matmul_cmd_mode    (2'(command.acc_mode)),
                .matmul_cmd_tile    (command.tile_mode),
                .push_valid         (b_valid),
                .push_data          (b_code),
                .push_scale         (b_scale),
                .push_bank          (b_bank),
                .activation_valid   (a_valid),
                .activation_data    (a_word),
                .activation_scale   (a_scale),
                .matmul_freed,
                .push_freed,
                .result_valid       (c_valid),
                .result_data        (c_data)
            );

            for (genvar lane = 0; lane < LANES; lane++) begin : gen_lane
                assign b_valid[lane] = push_valid[lane][engine];
                assign b_code[lane]  = push_code[lane][engine];
                assign b_scale[lane] = push_scale[lane][engine];
                assign b_bank[lane]  = push_bank[lane][engine];
                assign a_valid[lane] = matmul_valid[lane][engine];
                assign a_data[lane]  = matmul_data[lane][engine];
                assign a_scale[lane] = matmul_scale[lane][engine];
                if ((MXU_SLR_CROSSING >> engine) & 1) begin : gen_crossing
                    // Sublanes s and s + N_A carry the same row: it crosses once.
                    localparam int unsigned CROSS_ROWS = SUBLANES % MXU_N_A == 0 ? MXU_N_A : SUBLANES;
                    localparam int unsigned RESULT_W   = SUBLANES + CROSS_ROWS*VECTOR_ELEMENT_WIDTH;
                    logic [RESULT_W-1:0] result_in, result_tx, result_rx;

                    shifter #(
                        .WIDTH(RESULT_W),
                        .LENGTH(1)
                    ) u_result_tx (
                        .clk,
                        .rst (1'b0),
                        .en  (1'b1),
                        .d   (result_in),
                        .q   (result_tx)
                    );
                    shifter #(
                        .WIDTH(RESULT_W),
                        .LENGTH(1)
                    ) u_result_rx (
                        .clk,
                        .rst (1'b0),
                        .en  (1'b1),
                        .d   (result_tx),
                        .q   (result_rx)
                    );
                    for (genvar half = 0; half < CROSS_ROWS; half++) begin : gen_half
                        assign result_in[SUBLANES + half*VECTOR_ELEMENT_WIDTH +: VECTOR_ELEMENT_WIDTH] = c_data[lane][half];
                    end
                    for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_result
                        assign result_in[sublane] = c_valid[lane][sublane];
                        assign result_valid[lane][sublane][engine] = result_rx[sublane];
                        assign result_data[lane][sublane][engine] =
                            result_rx[SUBLANES + (sublane % CROSS_ROWS)*VECTOR_ELEMENT_WIDTH +: VECTOR_ELEMENT_WIDTH];
                    end
                end else begin : gen_direct
                    for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_sublane
                        assign result_valid[lane][sublane][engine] = c_valid[lane][sublane];
                        assign result_data[lane][sublane][engine]  = c_data[lane][sublane];
                    end
                end
            end
        end else begin : gen_disabled
            assign mxu_matmul_freed[engine] = 1'b0;
            assign mxu_push_freed[engine] = 2'b00;
            assign push_drained[engine] = feed_push_drained[0][engine];
            assign matmul_drained[engine] = feed_matmul_drained[0][engine];
            for (genvar lane = 0; lane < LANES; lane++) begin : gen_lane
                for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_sublane
                    assign result_valid[lane][sublane][engine] = 1'b0;
                    assign result_data[lane][sublane][engine]  = '0;
                end
            end
        end
    end

    if (PERF_COUNTERS) begin : gen_perf
        import tpu_perf_pkg::*;
        logic [COUNT-1:0] perf_event;
        logic [8:0]       e;
        assign e = scalar_perf_events;   // {refetch, other, vex, push, pop, dma_wait, scalar, bubble, issue}
        always_comb begin
            perf_event                  = '0;
            perf_event[TOTAL]           = 1'b1;
            perf_event[CYCLES]          = 1'b1;
            perf_event[ISSUES]          = e[0];
            perf_event[BUBBLE]          = e[1];
            perf_event[STALL_SCALAR]    = e[2];
            perf_event[STALL_DMA_WAIT]  = e[3];
            perf_event[STALL_POP]       = e[4];
            perf_event[STALL_PUSH]      = e[5];
            perf_event[STALL_VEX]       = e[6];
            perf_event[STALL_MM_QUEUE]  = e[6] && vector_perf_mxu_full[0];
            perf_event[STALL_MM_OUTPUT] = e[6] && vector_perf_mxu_full[1];
            perf_event[STALL_OTHER]     = e[7];
            perf_event[REFETCH]         = e[8];
            perf_event[STALL_XLU_ORDER] = e[6] && vector_perf_xlu_block[0];
            perf_event[STALL_XLU_TILE]  = e[6] && vector_perf_xlu_block[1];
        end
        tpu_perf u_perf (
            .clk,
            .rst      (rst_control),
            .start    (state_q == IDLE && ap_start),
            .done     (state_q == RUN && halt_q),
            .event_in (perf_event),
            .counters (perf_counters)
        );
    end else begin : gen_no_perf
        assign perf_counters = '{default: '0};
    end

    tpu_control #(
        .ADDR_W(CONTROL_ADDR_W),
        .PERF(PERF_COUNTERS),
        .MXU_MODE_ARG(MXU_MODE_ARG),
        .MXU_MODE_RESET(MXU_MODE_RESET)
    ) u_control (
        .clk,
        .rst                (rst_control),
        .s_awaddr,
        .s_awvalid,
        .s_awready,
        .s_wdata,
        .s_wstrb,
        .s_wvalid,
        .s_wready,
        .s_bresp,
        .s_bvalid,
        .s_bready,
        .s_araddr,
        .s_arvalid,
        .s_arready,
        .s_rdata,
        .s_rresp,
        .s_rvalid,
        .s_rready,
        .start              (ap_start),
        .idle               (state_q == IDLE),
        .done               (state_q == RUN && halt_q),
        .boot_external_addr (boot_req_external_addr),
        .boot_imem_addr     (boot_req_imem_addr),
        .boot_length        (boot_req_length),
        .mxu_mode           (mxu_mode_arg),
        .perf_counters
    );

    always_ff @(posedge clk) begin
        if (rst_control) begin
            boot_accepted_q <= 1'b0;
            boot_done_q <= 1'b0;
            halt_q <= 1'b0;
            state_q <= IDLE;
        end else begin
            boot_accepted_q <= state_q == BOOT_REQ && boot_req_ready;
            boot_done_q <= boot_done;
            halt_q <= halt;
            case (state_q)
                IDLE: if (ap_start) state_q <= BOOT_REQ;
                BOOT_REQ: if (boot_accepted_q) state_q <= BOOT_WAIT;
                BOOT_WAIT: if (boot_done_q) state_q <= RUN;
                RUN: if (halt_q) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end

endmodule
