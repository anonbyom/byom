module scalar_unit #(
    parameter int unsigned CHANNELS              = 32,
    parameter int unsigned IMEM_DEPTH            = 1024,
    parameter int unsigned SMEM_DEPTH            = 1024,
    parameter int unsigned BEAT_W                = 256,
    parameter int unsigned VMEM_DEPTH            = 32768,

    localparam int unsigned DMA_QUEUE_DEPTH = 4,
    localparam int unsigned VMEM_ADDR_WIDTH = VMEM_DEPTH > 1 ? $clog2(VMEM_DEPTH) : 1,
    localparam int unsigned IMEM_ADDR_WIDTH = $clog2(IMEM_DEPTH),
    localparam int unsigned SMEM_ADDR_WIDTH = $clog2(SMEM_DEPTH)
) (
    input  logic                                                 clk,
    input  logic                                                 rst,
    input  logic                                                 enable,
    output logic                                                 halt,

    input  logic                                                 boot_req_valid,
    output logic                                                 boot_req_ready,
    input  isa_pkg::scalar_word_t                                boot_req_external_addr,
    input  isa_pkg::scalar_word_t                                boot_req_imem_addr,
    input  isa_pkg::scalar_word_t                                boot_req_length,
    output logic                                                 boot_done,

    output logic                                                 dma_read_req_valid,
    input  logic                                                 dma_read_req_ready,
    output logic                                                 dma_read_local_write_sel,
    output logic                                                 dma_read_scalar_fast,
    input  logic                                                 scalar_write_fast        [CHANNELS],
    output isa_pkg::scalar_word_t                                dma_read_external_addr,
    output isa_pkg::scalar_word_t                                dma_read_length,
    input  logic                                                 dma_read_done,

    output logic                                                 dma_write_req_valid,
    input  logic                                                 dma_write_req_ready,
    output logic                                                 dma_write_local_read_sel,
    output isa_pkg::scalar_word_t                                dma_write_external_addr,
    output isa_pkg::scalar_word_t                                dma_write_length,
    input  logic                                                 dma_write_done,

    output logic                                                 vector_dma_start,
    output logic                                                 vector_dma_write,
    output isa_pkg::scalar_word_t                                vector_dma_base,
    output isa_pkg::scalar_word_t                                vector_dma_length,

    input  logic                                                 dma_write_valid          [CHANNELS],
    output logic                                                 dma_write_ready          [CHANNELS],
    input  logic                       [BEAT_W-1:0]              dma_write_data           [CHANNELS],
    output logic                                                 dma_response_valid       [CHANNELS],
    input  logic                                                 dma_response_ready       [CHANNELS],
    output logic                       [BEAT_W-1:0]              dma_response_data        [CHANNELS],

    input  logic                                                 vector_ready,  // scalar_control
    output logic                                                 valu_valid,
    output isa_pkg::valu_opcode_t                                valu_op,
    output isa_pkg::vector_reg_id_t                              valu_dest,
    output isa_pkg::vector_reg_id_t                              valu_x,
    output isa_pkg::vector_reg_id_t                              valu_y,
    output logic                       [isa_pkg::SROT_WIDTH-1:0] valu_srot,
    output isa_pkg::valu_opcode_t                                valu2_op,
    output isa_pkg::vector_reg_id_t                              valu2_dest,
    output isa_pkg::vector_reg_id_t                              valu2_x,
    output isa_pkg::vector_reg_id_t                              valu2_y,
    output isa_pkg::valu_ctrl_t                                   valu_ctrl,

    output logic                                                 vmem_valid,
    output isa_pkg::vmem_opcode_t                                vmem_op,
    output isa_pkg::vector_reg_id_t                              vmem_reg,
    output logic                       [VMEM_ADDR_WIDTH-1:0]     vmem_addr,
    output isa_pkg::vmem_stride_t                                vmem_stride_m1,
    output isa_pkg::vmem_skip_t                                  vmem_skip,


    output logic                                                 vex_valid,
    output isa_pkg::vex_opcode_t                                 vex_op,
    output isa_pkg::vector_reg_id_t                              vex_x,
    output isa_pkg::mxu_engine_id_t                              vex_engine,
    output logic                                                 vex_bank,
    output logic [1:0]                                           vex_mode,
    output isa_pkg::scale_reg_id_t                               vex_sreg,

    output logic                                                 vr_valid,
    output isa_pkg::vr_opcode_t                                  vr_op,
    output isa_pkg::vector_reg_id_t                              vr_dest,
    output isa_pkg::mxu_engine_id_t                              vr_engine,
    output logic                       [8:0]                     perf_events
);
    import isa_pkg::*;

    logic                               imem_dma_write_valid;
    logic         [IMEM_ADDR_WIDTH-1:0] imem_dma_write_addr;
    bundle_t                            imem_dma_write_data;
    logic                               smem_dma_write_valid;
    logic         [SMEM_ADDR_WIDTH-1:0] smem_dma_write_addr;
    scalar_word_t                       smem_dma_write_data;
    logic                               smem_dma_read_req_valid;
    logic         [SMEM_ADDR_WIDTH-1:0] smem_dma_read_req_addr;
    logic                               smem_dma_read_rsp_valid;
    scalar_word_t                       smem_dma_read_rsp_data;
    logic                               dma_req_valid;
    logic                               dma_req_ready;
    direction_t                         dma_req_direction;
    scalar_word_t                       dma_req_src_addr;
    scalar_word_t                       dma_req_dst_addr;
    scalar_word_t                       dma_req_length;
    logic                               dma_done;
    logic                               ctrl_req_valid;
    logic                               ctrl_req_ready;
    direction_t                         ctrl_req_direction;
    scalar_word_t                       ctrl_req_src_addr;
    scalar_word_t                       ctrl_req_dst_addr;
    scalar_word_t                       ctrl_req_length;
    logic                               lmem_write_start;
    logic                               lmem_write_done;
    logic                               lmem_write_imem;
    scalar_word_t                       lmem_write_base;
    logic                               lmem_read_start;
    scalar_word_t                       lmem_read_base;

    // DMA commands wait here; two HBM_TO_VMEM DMAs may run at once, any other DMA runs alone.
    localparam int unsigned REQ_W = $bits(direction_t) + 3 * $bits(scalar_word_t);
    logic [REQ_W-1:0] queued;
    logic             queued_valid;
    logic             ctrl_fire;
    logic [1:0]       running;
    direction_t       running_direction_q;
    direction_t       queued_direction;

    fifo #(
        .DATA_WIDTH(REQ_W),
        .DEPTH(DMA_QUEUE_DEPTH),
        .READ_READY_BYPASS(1'b0)
    ) u_dma_queue (
        .clk,
        .rst,
        .w_en    (dma_req_valid),
        .w_data  ({dma_req_direction, dma_req_src_addr, dma_req_dst_addr, dma_req_length}),
        .w_rdy   (dma_req_ready),
        .r_en    (ctrl_fire),
        .r_data  (queued),
        .r_valid (queued_valid),
        .level   ()
    );

    credit_counter #(
        .WIDTH(2)
    ) u_running (
        .clk,
        .rst,
        .add   (2'(ctrl_fire)),
        .sub   (2'(dma_done)),
        .count (running)
    );

    always_ff @(posedge clk) if (ctrl_fire) running_direction_q <= queued_direction;

    assign ctrl_fire        = ctrl_req_valid && ctrl_req_ready;
    assign queued_direction = direction_t'(queued[REQ_W-1 -: $bits(direction_t)]);
    assign ctrl_req_valid   = queued_valid && (running == 0 ||
        running == 1 && queued_direction == HBM_TO_VMEM && running_direction_q == HBM_TO_VMEM);
    assign {ctrl_req_direction, ctrl_req_src_addr, ctrl_req_dst_addr, ctrl_req_length} = queued;

    scalar_pipeline #(
        .IMEM_DEPTH(IMEM_DEPTH),
        .SMEM_DEPTH(SMEM_DEPTH),
        .VMEM_DEPTH(VMEM_DEPTH)
    ) pipeline (
        .clk,
        .rst,
        .enable,
        .halt,
        .imem_dma_write_valid,
        .imem_dma_write_addr,
        .imem_dma_write_data,
        .smem_dma_write_valid,
        .smem_dma_write_addr,
        .smem_dma_write_data,
        .smem_dma_read_req_valid,
        .smem_dma_read_req_addr,
        .smem_dma_read_rsp_valid,
        .smem_dma_read_rsp_data,
        .dma_req_valid,
        .dma_req_ready,
        .dma_req_direction,
        .dma_req_src_addr,
        .dma_req_dst_addr,
        .dma_req_length,
        .dma_done,
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
        .vex_bank,
        .vex_mode,
        .vex_sreg,
        .vr_valid,
        .vr_op,
        .vr_dest,
        .vr_engine,
        .perf_events
    );

    scalar_dma_control dma_control (
        .clk,
        .rst,
        .enable,
        .boot_req_valid,
        .boot_req_ready,
        .boot_req_external_addr,
        .boot_req_imem_addr,
        .boot_req_length,
        .boot_done,
        .dma_read_req_valid,
        .dma_read_req_ready,
        .dma_read_local_write_sel,
        .dma_read_external_addr,
        .dma_read_length,
        .dma_read_done,
        .dma_write_req_valid,
        .dma_write_req_ready,
        .dma_write_local_read_sel,
        .dma_write_external_addr,
        .dma_write_length,
        .dma_write_done,
        .req_valid     (ctrl_req_valid),
        .req_ready     (ctrl_req_ready),
        .req_direction (ctrl_req_direction),
        .req_src_addr  (ctrl_req_src_addr),
        .req_dst_addr  (ctrl_req_dst_addr),
        .req_length    (ctrl_req_length),
        .done          (dma_done),
        .vector_dma_start,
        .vector_dma_write,
        .vector_dma_base,
        .vector_dma_length,
        .lmem_write_start,
        .lmem_write_imem,
        .lmem_write_base,
        .lmem_write_done,
        .lmem_read_start,
        .lmem_read_base
    );

    dma_scalar_adapter #(
        .CHANNELS(CHANNELS),
        .SCALAR_W(SCALAR_WORD_WIDTH),
        .IMEM_DEPTH(IMEM_DEPTH),
        .SMEM_DEPTH(SMEM_DEPTH),
        .BEAT_W(BEAT_W)
    ) dma_transport (
        .clk,
        .rst,
        .write_start      (lmem_write_start),
        .write_imem       (lmem_write_imem),
        .write_base       (lmem_write_base),
        .write_fast       (scalar_write_fast),
        .write_valid      (dma_write_valid),
        .write_ready      (dma_write_ready),
        .write_done       (lmem_write_done),
        .write_length     (dma_read_length),
        .write_data       (dma_write_data),
        .read_start       (lmem_read_start),
        .read_base        (lmem_read_base),
        .read_length      (dma_write_length),
        .response_valid   (dma_response_valid),
        .response_ready   (dma_response_ready),
        .response_data    (dma_response_data),
        .imem_valid       (imem_dma_write_valid),
        .imem_addr        (imem_dma_write_addr),
        .imem_data        (imem_dma_write_data),
        .smem_write_valid (smem_dma_write_valid),
        .smem_write_addr  (smem_dma_write_addr),
        .smem_write_data  (smem_dma_write_data),
        .smem_read_valid  (smem_dma_read_req_valid),
        .smem_read_addr   (smem_dma_read_req_addr),
        .smem_resp_valid  (smem_dma_read_rsp_valid),
        .smem_resp_data   (smem_dma_read_rsp_data)
    );
    assign dma_read_scalar_fast = lmem_write_imem;
endmodule
