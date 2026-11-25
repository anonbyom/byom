module vector_unit #(
    parameter int LANES              = 32,
    parameter int SUBLANES           = 4,
    parameter int VREG_COUNT         = 16,
    parameter int ELEMENT_WIDTH      = isa_pkg::VECTOR_ELEMENT_WIDTH,
    parameter int VMEM_DEPTH         = 32768,
    parameter int MXU_COUNT          = 2,
    parameter int PUSH_QUEUE_DEPTH   = 8,
    parameter int MATMUL_QUEUE_DEPTH = 4,
    parameter int POP_QUEUE_DEPTH    = 64,
    parameter int MXU_MATMUL_SLOTS   = 0,
    parameter int POPS_PER_MATMUL    = 1,
    parameter int POPS_PER_BLOCK     = 1,
    parameter int MXU_PUSH_SLOTS     = 0,
    parameter bit SCALE_REGS         = 1'b0,
    parameter bit MXU_TILE_MODES     = 1'b0,
    parameter int RETURN_STAGES      = 2,
    parameter int DMA_RETURN_STAGES  = 1,
    parameter int DMA_FIFO_DEPTH     = 32,
    parameter int DMA_WORD_W         = 256,
    parameter int BANKS              = DMA_WORD_W / ELEMENT_WIDTH,
    parameter bit VMEM_URAM_OREG     = 1'b0,
    parameter int FP_DEPTH           = 16,
    parameter int EUP_WIDTH          = 1,
    // DMA beats cross to the lanes as two halves (half the bandwidth and SLR0/SLR1 link).
    parameter bit XLU_QUANTIZE       = 1'b0,
    parameter int XLU_REDUCE_TREES   = 1,

    localparam int CHANNELS    = LANES,
    localparam int VMEM_READ_REGS = 1 + int'(VMEM_URAM_OREG),
    localparam int REG_W       = $clog2(VREG_COUNT),
    localparam int ADDR_W      = $clog2(VMEM_DEPTH),
    localparam int DMA_WORDS   = DMA_WORD_W / ELEMENT_WIDTH,
    localparam int LINK_WORDS  = DMA_WORDS / 2,    // DMA beats cross to the lanes as two halves
    localparam int DMA_ADDR_W  = $clog2(VMEM_DEPTH / BANKS),
    localparam int DMA_COUNT_W = $clog2(VMEM_DEPTH / BANKS + 1)
) (
    input  logic                           clk,
    input  logic                           rst,
    input  logic                           mxu_os,   // output-stationary MXU
    output logic                           idle,
    output logic [1:0]                     perf_mxu_full,
    output logic [1:0]                     perf_xlu_block,

    output logic                           vector_ready,

    input  logic                           valu_valid,
    input  isa_pkg::valu_opcode_t          valu_op,
    input  logic [REG_W-1:0]               valu_dest,
    input  logic [REG_W-1:0]               valu_x,
    input  logic [REG_W-1:0]               valu_y,
    input  logic [isa_pkg::SROT_WIDTH-1:0] valu_srot,
    input  isa_pkg::valu_opcode_t          valu2_op,
    input  logic [REG_W-1:0]               valu2_dest,
    input  logic [REG_W-1:0]               valu2_x,
    input  logic [REG_W-1:0]               valu2_y,
    input  isa_pkg::valu_ctrl_t            valu_ctrl,

    input  logic                           vmem_valid,
    input  isa_pkg::vmem_opcode_t          vmem_op,
    input  logic [REG_W-1:0]               vmem_reg,
    input  logic [ADDR_W-1:0]              vmem_addr,
    input  isa_pkg::vmem_stride_t          vmem_stride_m1,
    input  isa_pkg::vmem_skip_t            vmem_skip,

    input  logic                           vex_valid,
    input  isa_pkg::vex_opcode_t           vex_op,
    input  logic [REG_W-1:0]               vex_x,
    input  isa_pkg::mxu_engine_id_t        vex_engine,
    input  logic                           vex_bank,
    input  logic [1:0]                     vex_mode,
    input  isa_pkg::scale_reg_id_t         vex_sreg,

    input  logic                           vr_valid,
    input  isa_pkg::vr_opcode_t            vr_op,
    input  logic [REG_W-1:0]               vr_dest,
    input  isa_pkg::mxu_engine_id_t        vr_engine,

    output logic                           mxu_valid          [LANES],
    output logic                           mxu_matmul         [LANES],
    output isa_pkg::mxu_engine_id_t        mxu_engine         [LANES],
    output logic                           mxu_bank           [LANES],
    output logic [SUBLANES*ELEMENT_WIDTH-1:0] mxu_data        [LANES],
    output logic [7:0]                     mxu_scale          [LANES],

    output logic                           matmul_cmd_valid   [MXU_COUNT],
    output isa_pkg::mxu_command_t          matmul_cmd         [MXU_COUNT],
    input  logic                           mxu_matmul_freed   [MXU_COUNT],
    input  logic                           push_drained       [MXU_COUNT],
    input  logic                           matmul_drained     [MXU_COUNT],
    input  logic [1:0]                     mxu_push_freed     [MXU_COUNT],

    input  logic                           mxu_pop_valid      [LANES][SUBLANES][MXU_COUNT],
    input  logic [ELEMENT_WIDTH - 1:0]     mxu_pop_data       [LANES][SUBLANES][MXU_COUNT],

    output logic                           transpose_push_valid [LANES],
    output logic [SUBLANES*ELEMENT_WIDTH-1:0] transpose_push_data [LANES],
    output isa_pkg::mxu_engine_id_t        transpose_push_func [LANES],
    output logic [2:0]                     transpose_push_quantize [LANES],
    input  logic                           transpose_pop_valid [LANES],
    input  logic [ELEMENT_WIDTH-1:0]       transpose_pop_data [LANES][SUBLANES],

    input  logic                           dma_start,
    input  logic                           dma_write,
    input  isa_pkg::scalar_word_t          dma_base,
    input  isa_pkg::scalar_word_t          dma_length,
    input  logic                           dma_write_valid    [CHANNELS],
    output logic                           dma_write_ready    [CHANNELS],
    input  logic [DMA_WORD_W - 1:0]        dma_write_data     [CHANNELS],
    output logic                           dma_write_idle     [CHANNELS],
    output logic                           dma_response_valid [CHANNELS],
    input  logic                           dma_response_ready [CHANNELS],
    output logic [DMA_WORD_W - 1:0]        dma_response_data  [CHANNELS]
);
    import isa_pkg::*;

    localparam int unsigned READ_PORTS = VALU2 ? 6 : 4;

    localparam int unsigned SHELL_PUSH_QUEUE       = PUSH_QUEUE_DEPTH;
    localparam int unsigned SHELL_POP_QUEUE        = POP_QUEUE_DEPTH;
    localparam int unsigned SHELL_MATMUL_SLOTS     = MXU_MATMUL_SLOTS;
    localparam int unsigned SHELL_PUSH_SLOTS       = MXU_PUSH_SLOTS;
    localparam int unsigned SHELL_POPS_PER_MATMUL  = POPS_PER_MATMUL;
    localparam int unsigned SHELL_POPS_PER_BLOCK   = POPS_PER_BLOCK;
    localparam int unsigned TARGET_POP_QUEUE_DEPTH = POP_QUEUE_DEPTH;

    typedef struct packed {
        logic                   write;
        logic [DMA_ADDR_W-1:0]  address;
        logic [DMA_COUNT_W-1:0] words;
    } dma_command_t;

    typedef struct packed {
        logic alu_valid;
        logic mem_valid;
        logic vex_valid;
        logic pop_valid;
        logic dma_valid;
    } command_valid_t;

    typedef struct packed {
        valu_opcode_t                       op;
        logic              [REG_W-1:0]      dest;
        logic              [REG_W-1:0]      x;
        logic              [REG_W-1:0]      y;
        logic              [SROT_WIDTH-1:0] srot;
        valu_opcode_t                       valu2_op;
        logic              [REG_W-1:0]      valu2_dest;
        logic              [REG_W-1:0]      valu2_x;
        logic              [REG_W-1:0]      valu2_y;
        valu_ctrl_t                          ctrl;
        vmem_opcode_t                       mem_op;
        logic              [ADDR_W-1:0]     mem_addr;
        logic              [REG_W-1:0]      mem_reg;
        vmem_stride_t                       mem_stride_m1;
        vmem_skip_t                         mem_skip;
        vex_opcode_t                        vex_op;
        logic              [REG_W-1:0]      vex_x;
        mxu_engine_id_t                     vex_engine;
        logic                               vex_bank;
        logic [1:0]                         vex_mode;
        scale_reg_id_t                      vex_sreg;
        logic              [REG_W-1:0]      pop_dest;
        vr_opcode_t                         pop_op;
        mxu_engine_id_t                     pop_engine;
        dma_command_t                       dma;
    } command_t;

    command_t                   command                [LANES];
    // command_next[n] is the value command[n] loads, so lanes can keep local copies (lane 0 its read addresses).
    command_t                   command_next           [LANES];
    command_valid_t             command_valid          [LANES];
    logic                       issue_ready;
    logic                       pop_arrived            [LANES][MXU_COUNT];
    logic                       transpose_pop_arrived  [LANES];
    logic                       fp_pop_arrived         [LANES];
    logic                       eup_pop_arrived        [LANES];
    logic                       quant_pop_arrived      [LANES];
    // Lane n's VALU selects, taken by lane n + 1 (vlane FIRST_LANE).
    logic [5:0]                 lane_selects           [LANES+1][SUBLANES][4];
    logic [1:0]                 lane_owners            [LANES+1][SUBLANES][READ_PORTS];
    assign lane_selects[0] = '{default: '{default: '0}};
    assign lane_owners[0]  = '{default: '{default: '0}};
    logic [LANES+3+VMEM_READ_REGS:0] busy_q;
    logic                       rst_issue;
    logic [ELEMENT_WIDTH - 1:0] channel_response_data  [CHANNELS][LINK_WORDS];
    logic                       request_valid          [CHANNELS][LINK_WORDS];
    logic                       request_write          [CHANNELS][LINK_WORDS];
    logic                       request_upper          [CHANNELS][LINK_WORDS];
    logic [DMA_ADDR_W-1:0]      request_addr           [CHANNELS][LINK_WORDS];
    logic [ELEMENT_WIDTH - 1:0] request_data           [CHANNELS][LINK_WORDS];

    reset_register u_rst_issue (.clk, .rst_in(rst), .rst(rst_issue));

    vector_issue #(
        .LANES(LANES),
        .MXU_COUNT(MXU_COUNT),
        .PUSH_DEPTH(PUSH_QUEUE_DEPTH),
        .MATMUL_DEPTH(MATMUL_QUEUE_DEPTH),
        .POP_DEPTH(POP_QUEUE_DEPTH),
        .MXU_MATMUL_SLOTS(MXU_MATMUL_SLOTS),
        .POPS_PER_MATMUL(POPS_PER_MATMUL),
        .POPS_PER_BLOCK(POPS_PER_BLOCK),
        .MXU_PUSH_SLOTS(MXU_PUSH_SLOTS),
        .RETURN_STAGES(RETURN_STAGES),
        .FP_DEPTH(FP_DEPTH),
        .EUP_WIDTH(EUP_WIDTH),
        .XLU_QUANTIZE(XLU_QUANTIZE),
        .XLU_REDUCE_TREES(XLU_REDUCE_TREES)
    ) u_issue (
        .clk,
        .rst (rst_issue),
        .mxu_os,
        .valu_valid,
        .valu_op,
        .vex_valid,
        .vex_op,
        .vex_engine,
        .vex_bank,
        .vex_mode,
        .vex_sreg,
        .pop_valid      (vr_valid),
        .pop_op         (vr_op),
        .pop_engine     (vr_engine),
        .ready          (issue_ready),
        .push_drained,
        .matmul_drained,
        .pop_arrived    (pop_arrived[0]),
        .mxu_matmul_freed,
        .mxu_push_freed,
        .transpose_pop_arrived (transpose_pop_arrived[0]),
        .fp_pop_arrived (fp_pop_arrived[0]),
        .eup_pop_arrived (eup_pop_arrived[0]),
        .quant_pop_arrived (quant_pop_arrived[0]),
        .perf_mxu_full,
        .perf_xlu_block
    );

    assign vector_ready = issue_ready;
    assign idle = busy_q == 0;

    assign command_next[0] = '{op: valu_op, dest: valu_dest, x: valu_x, y: valu_y,
        srot: valu_srot, valu2_op: VALU2 ? valu2_op : VNOP, valu2_dest: VALU2 ? valu2_dest : '0,
        valu2_x: VALU2 ? valu2_x : '0, valu2_y: VALU2 ? valu2_y : '0, ctrl: VALU2 ? valu_ctrl : '0,
        mem_op: vmem_op, mem_addr: vmem_addr, mem_reg: vmem_reg,
        mem_stride_m1: vmem_stride_m1, mem_skip: vmem_skip,
        vex_op: vex_op, vex_x: vex_x, vex_engine: vex_engine, vex_bank: vex_bank, vex_mode: vex_mode, vex_sreg: vex_sreg,
        pop_dest: vr_dest, pop_op: vr_op, pop_engine: vr_engine,
        dma: '{write: dma_write, address: DMA_ADDR_W'(dma_base), words: DMA_COUNT_W'(dma_length)}};

    always_ff @(posedge clk) begin
        command[0] <= command_next[0];
        if (rst_issue) begin
            busy_q <= '1;
            command_valid[0] <= '0;
        end else begin
            busy_q <= {busy_q[LANES+2+VMEM_READ_REGS:0], issue_ready &&
                (valu_valid || vmem_valid || vex_valid || vr_valid)};
            command_valid[0] <= '{alu_valid: valu_valid && issue_ready,
                mem_valid: vmem_valid && issue_ready, vex_valid: vex_valid && issue_ready,
                pop_valid: vr_valid && issue_ready, dma_valid: dma_start};
        end
    end

    for (genvar n = 1; n < LANES; n++) begin : gen_command
        assign command_next[n] = command[n-1];
        always_ff @(posedge clk) begin
            command[n] <= command[n-1];
            command_valid[n] <= command_valid[n-1];
        end
    end

    for (genvar engine = 0; engine < MXU_COUNT; engine++) begin : gen_matmul_command
        logic      matmul_for_engine;
        logic      preload;
        acc_mode_t acc_mode;
        acc_mode_t acc_mode_q;
        logic [1:0] tile_mode;
        logic [1:0] tile_mode_q;
        assign matmul_for_engine = command_valid[0].vex_valid && vex_matmul(command[0].vex_op) &&
            command[0].vex_engine == mxu_engine_id_t'(engine);
        assign preload = vex_preload(command[0].vex_op);
        // A preload sets the engine's tile mode and accumulator mode.
        assign tile_mode = !MXU_TILE_MODES ? 2'd0 : preload ? command[0].vex_sreg[1:0] : tile_mode_q;
        assign acc_mode = preload ? acc_mode_t'(command[0].vex_mode) : acc_mode_q;
        always_ff @(posedge clk) begin
            if (rst_issue) begin
                matmul_cmd_valid[engine] <= 1'b0;
                acc_mode_q <= ACC_EMIT;
                tile_mode_q <= '0;
            end else begin
                matmul_cmd_valid[engine] <= matmul_for_engine;
                if (matmul_for_engine && preload) acc_mode_q <= acc_mode;
                if (matmul_for_engine && preload) tile_mode_q <= tile_mode;
            end
            matmul_cmd[engine] <= '{tile_mode: tile_mode, acc_mode: acc_mode, bank: command[0].vex_bank, preload: preload};
        end
    end

    // Each DMA channel serves CHANNEL_LANES lanes x one bank group (a URAM word: LANE_WORDS banks).
    localparam int LANE_WORDS    = SUBLANES;
    localparam int CHANNEL_LANES = LINK_WORDS / LANE_WORDS;
    localparam int GROUP_SETS    = BANKS / LANE_WORDS / 2;
    localparam int UPPER_BANK    = GROUP_SETS * LANE_WORDS;

    for (genvar c = 0; c < CHANNELS; c++) begin : gen_channel
        localparam int FIRST_LANE = (c / GROUP_SETS) * CHANNEL_LANES;
        logic rst_channel;

        reset_register u_rst (.clk, .rst_in(rst), .rst(rst_channel));

        vector_dma_channel #(
            .ADDR_WIDTH(DMA_ADDR_W),
            .FIFO_DEPTH(DMA_FIFO_DEPTH),
            .RETURN_STAGES(DMA_RETURN_STAGES),
            .WORDS(DMA_WORDS),
            .WORD_WIDTH(ELEMENT_WIDTH),
            .MEM_OUTPUT_REG(VMEM_READ_REGS),
            .LANE_WORDS(LANE_WORDS)
        ) u_dma (
            .clk,
            .rst            (rst_channel),
            .start          (command_valid[FIRST_LANE].dma_valid),
            .write          (command[FIRST_LANE].dma.write),
            .base           (command[FIRST_LANE].dma.address),
            .length         (command[FIRST_LANE].dma.words),
            .write_valid    (dma_write_valid[c]),
            .write_ready    (dma_write_ready[c]),
            .write_data     (dma_write_data[c]),
            .write_idle     (dma_write_idle[c]),
            .response_valid (dma_response_valid[c]),
            .response_ready (dma_response_ready[c]),
            .response_data  (dma_response_data[c]),
            .req_valid      (request_valid[c]),
            .req_write      (request_write[c]),
            .req_upper      (request_upper[c]),
            .req_addr       (request_addr[c]),
            .req_data       (request_data[c]),
            .word_data      (channel_response_data[c])
        );
    end

    for (genvar lane = 0; lane < LANES; lane++) begin : gen_lane
        wire command_t cmd = command[lane];
        logic [REG_W-1:0] read_addr_next [READ_PORTS];
        assign read_addr_next[0] = command_next[lane].x;
        assign read_addr_next[1] = command_next[lane].y;
        assign read_addr_next[2] = command_next[lane].mem_reg;
        assign read_addr_next[3] = command_next[lane].vex_x;
        if (VALU2) begin : gen_valu2_read
            assign read_addr_next[4] = command_next[lane].valu2_x;
            assign read_addr_next[5] = command_next[lane].valu2_y;
        end
        wire command_valid_t cmd_valid = command_valid[lane];

        logic                       mem_valid [BANKS];
        logic                       mem_write [BANKS];
        logic [DMA_ADDR_W-1:0]      mem_addr  [BANKS];
        logic [ELEMENT_WIDTH - 1:0] mem_wdata [BANKS];
        logic [ELEMENT_WIDTH - 1:0] mem_rdata [BANKS];
        logic                       bank_resp_valid [BANKS];
        logic [ELEMENT_WIDTH - 1:0] bank_resp_data  [BANKS];

        for (genvar bank = 0; bank < BANKS; bank++) begin : gen_dma
            localparam int GROUP_SET    = (bank / LANE_WORDS) % GROUP_SETS;
            localparam bit UPPER        = bank >= UPPER_BANK;
            localparam int CHANNEL      = (lane / CHANNEL_LANES) * GROUP_SETS + GROUP_SET;
            localparam int WORD         = (lane % CHANNEL_LANES) * LANE_WORDS + bank % LANE_WORDS;
            localparam int RETURN_DELAY = (WORD / LANE_WORDS + 1) * DMA_RETURN_STAGES;

            if (!UPPER) begin : gen_return
                logic [ELEMENT_WIDTH - 1:0] resp_data;
                assign resp_data = bank_resp_valid[bank + UPPER_BANK] ? bank_resp_data[bank + UPPER_BANK]
                                                                      : bank_resp_data[bank];

                shifter #(
                    .WIDTH(ELEMENT_WIDTH),
                    .LENGTH(RETURN_DELAY)
                ) u_return_data (
                    .clk,
                    .rst (1'b0),
                    .en  (1'b1),
                    .d   (resp_data),
                    .q   (channel_response_data[CHANNEL][WORD])
                );
            end

            lane_dma #(
                .ADDR_WIDTH(DMA_ADDR_W),
                .DATA_WIDTH(ELEMENT_WIDTH),
                .MEM_OUTPUT_REG(VMEM_READ_REGS)
            ) u_dma (
                .clk,
                .rst       (1'b0),
                .req_valid (request_valid[CHANNEL][WORD] && request_upper[CHANNEL][WORD] == UPPER),
                .req_write (request_write[CHANNEL][WORD]),
                .req_addr  (request_addr[CHANNEL][WORD]),
                .req_wdata (request_data[CHANNEL][WORD]),
                .resp_valid (bank_resp_valid[bank]),
                .resp_data  (bank_resp_data[bank]),
                .mem_valid (mem_valid[bank]),
                .mem_write (mem_write[bank]),
                .mem_addr  (mem_addr[bank]),
                .mem_wdata (mem_wdata[bank]),
                .mem_rdata (mem_rdata[bank])
            );
        end

        vlane #(
            .VREG_COUNT(VREG_COUNT),
            .ELEMENT_WIDTH(ELEMENT_WIDTH),
            .SUBLANES(SUBLANES),
            .VMEM_DEPTH(VMEM_DEPTH),
            .BANKS(BANKS),
            .MXU_COUNT(MXU_COUNT),
            .PUSH_QUEUE_DEPTH(PUSH_QUEUE_DEPTH),
            .POP_QUEUE_DEPTH(POP_QUEUE_DEPTH),
            .VMEM_URAM_OREG(VMEM_URAM_OREG),
            .SCALE_REGS(SCALE_REGS),
            .FP_DEPTH(FP_DEPTH),
            .EUP_WIDTH(EUP_WIDTH),
            .FIRST_LANE(lane == 0),
            .VALU2(VALU2)
        ) u_vlane (
            .clk,
            .valu_valid     (cmd_valid.alu_valid),
            .valu_op        (cmd.op),
            .valu_dest      (cmd.dest),
            .valu_srot      (cmd.srot),
            .valu2_valid    (cmd_valid.alu_valid),
            .valu2_op       (cmd.valu2_op),
            .valu2_dest     (cmd.valu2_dest),
            .valu_ctrl       (cmd.ctrl),
            .valu_y_imm_next(command_next[lane].ctrl.y_imm),
            .vmem_valid     (cmd_valid.mem_valid),
            .vmem_op        (cmd.mem_op),
            .vmem_reg       (cmd.mem_reg),
            .vmem_addr      (cmd.mem_addr),
            .vmem_stride_m1 (cmd.mem_stride_m1),
            .vmem_skip      (cmd.mem_skip),
            .vex_op         (cmd.vex_op),
            .read_addr_next (read_addr_next),
            .vex_engine     (cmd.vex_engine),
            .vex_bank       (cmd.vex_bank),
            .vex_fire       (cmd_valid.vex_valid),
            .pop_dest       (cmd.pop_dest),
            .pop_op         (cmd.pop_op),
            .pop_engine     (cmd.pop_engine),
            .pop_fire       (cmd_valid.pop_valid),
            .pop_arrived    (pop_arrived[lane]),
            .transpose_pop_arrived(transpose_pop_arrived[lane]),
            .fp_pop_arrived (fp_pop_arrived[lane]),
            .eup_pop_arrived (eup_pop_arrived[lane]),
            .quant_pop_arrived (quant_pop_arrived[lane]),
            .mxu_valid      (mxu_valid[lane]),
            .mxu_matmul     (mxu_matmul[lane]),
            .mxu_engine     (mxu_engine[lane]),
            .mxu_bank       (mxu_bank[lane]),
            .mxu_data       (mxu_data[lane]),
            .vex_sreg       (cmd.vex_sreg),
            .vex_quantize   ({cmd.vex_mode == QUANTIZE_WT,
                              cmd.vex_mode == QUANTIZE_W || cmd.vex_mode == QUANTIZE_WT,
                              cmd.vex_op == XLANE_QUANTIZE}),
            .mxu_scale      (mxu_scale[lane]),
            .transpose_push_valid(transpose_push_valid[lane]),
            .transpose_push_data(transpose_push_data[lane]),
            .transpose_push_func(transpose_push_func[lane]),
            .transpose_push_quantize(transpose_push_quantize[lane]),
            .mxu_pop_valid  (mxu_pop_valid[lane]),
            .mxu_pop_data   (mxu_pop_data[lane]),
            .transpose_pop_valid(transpose_pop_valid[lane]),
            .transpose_pop_data(transpose_pop_data[lane]),
            .selects_in     (lane_selects[lane]),
            .selects_out    (lane_selects[lane+1]),
            .owners_in      (lane_owners[lane]),
            .owners_out     (lane_owners[lane+1]),
            .dma_req_valid  (mem_valid),
            .dma_req_write  (mem_write),
            .dma_req_addr   (mem_addr),
            .dma_req_wdata  (mem_wdata),
            .dma_rsp_rdata  (mem_rdata)
        );
    end

    initial begin
        if (VREG_COUNT > (1 << $bits(vector_reg_id_t)))
            $fatal(1, "VREG_COUNT exceeds the ISA register ID width");
        if (LANES < DMA_WORDS || LANES % DMA_WORDS != 0 || SUBLANES != 4)
            $fatal(1, "This integration requires whole DMA beats of lanes and four sublanes");
        if (LANES % CHANNEL_LANES != 0 || LANES / CHANNEL_LANES * GROUP_SETS != CHANNELS)
            $fatal(1, "The DMA channels must cover whole lanes x bank groups");
        if (DMA_WORD_W % ELEMENT_WIDTH != 0 || DMA_WORDS != BANKS)
            $fatal(1, "One 256-bit DMA beat must contain exactly one word for every VMEM bank");
        if (VMEM_DEPTH % BANKS != 0 || LANES * BANKS != CHANNELS * DMA_WORDS)
            $fatal(1, "The lane/bank array must map exactly onto all DMA channel words");
    end
endmodule
