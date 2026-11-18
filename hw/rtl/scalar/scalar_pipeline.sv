module scalar_pipeline #(
    parameter int unsigned IMEM_DEPTH = 1024,
    parameter int unsigned SMEM_DEPTH = 1024,
    parameter int unsigned VMEM_DEPTH = 32768,

    localparam int unsigned INDEXES = 1,
    localparam int unsigned VMEM_ADDR_WIDTH = VMEM_DEPTH > 1 ? $clog2(VMEM_DEPTH) : 1,
    localparam int unsigned IMEM_ADDR_WIDTH = $clog2(IMEM_DEPTH),
    localparam int unsigned SMEM_ADDR_WIDTH = $clog2(SMEM_DEPTH)
) (
    input  logic                           clk,
    input  logic                           rst,
    input  logic                           enable,
    output logic                           halt,

    input  logic                           imem_dma_write_valid,
    input  logic [IMEM_ADDR_WIDTH-1:0]     imem_dma_write_addr,
    input  isa_pkg::bundle_t               imem_dma_write_data,

    input  logic                           smem_dma_write_valid,
    input  logic [SMEM_ADDR_WIDTH-1:0]     smem_dma_write_addr,
    input  isa_pkg::scalar_word_t          smem_dma_write_data,

    input  logic                           smem_dma_read_req_valid,
    input  logic [SMEM_ADDR_WIDTH-1:0]     smem_dma_read_req_addr,
    output logic                           smem_dma_read_rsp_valid,
    output isa_pkg::scalar_word_t          smem_dma_read_rsp_data,

    output logic                           dma_req_valid,
    input  logic                           dma_req_ready,
    output isa_pkg::direction_t            dma_req_direction,
    output isa_pkg::scalar_word_t          dma_req_src_addr,
    output isa_pkg::scalar_word_t          dma_req_dst_addr,
    output isa_pkg::scalar_word_t          dma_req_length,
    input  logic                           dma_done,

    input  logic                           vector_ready,
    output logic                           valu_valid,
    output isa_pkg::valu_opcode_t          valu_op,
    output isa_pkg::vector_reg_id_t        valu_dest,
    output isa_pkg::vector_reg_id_t        valu_x,
    output isa_pkg::vector_reg_id_t        valu_y,
    output logic [isa_pkg::SROT_WIDTH-1:0] valu_srot,
    output isa_pkg::valu_opcode_t          valu2_op,
    output isa_pkg::vector_reg_id_t        valu2_dest,
    output isa_pkg::vector_reg_id_t        valu2_x,
    output isa_pkg::vector_reg_id_t        valu2_y,
    output isa_pkg::valu_ctrl_t            valu_ctrl,

    output logic                           vmem_valid,
    output isa_pkg::vmem_opcode_t          vmem_op,
    output isa_pkg::vector_reg_id_t        vmem_reg,
    output logic [VMEM_ADDR_WIDTH-1:0]     vmem_addr,
    output isa_pkg::vmem_stride_t          vmem_stride_m1,
    output isa_pkg::vmem_skip_t            vmem_skip,


    output logic                           vex_valid,
    output isa_pkg::vex_opcode_t           vex_op,
    output isa_pkg::vector_reg_id_t        vex_x,
    output isa_pkg::mxu_engine_id_t        vex_engine,
    output logic                           vex_bank,
    output logic [1:0]                     vex_mode,
    output isa_pkg::scale_reg_id_t         vex_sreg,

    output logic                           vr_valid,
    output isa_pkg::vr_opcode_t            vr_op,
    output isa_pkg::vector_reg_id_t        vr_dest,
    output isa_pkg::mxu_engine_id_t        vr_engine,

    output logic [8:0]                     perf_events
);
    import isa_pkg::*;

    typedef struct packed {
        scalar_opcode_t        scalar_op;
        scalar_reg_id_t        scalar_dest;
        scalar_reg_id_t        scalar_x;
        scalar_source_t        scalar_y;
        scalar_source_t        dma_length;
        logic           [2:0]  source_used;
        direction_t            dma_direction;
        scalar_word_t          immediate;

        valu_opcode_t          valu_op;
        vector_reg_id_t        valu_dest;
        vector_reg_id_t        valu_x;
        vector_reg_id_t        valu_y;
        logic [SROT_WIDTH-1:0] valu_srot;
        valu_opcode_t          valu2_op;
        vector_reg_id_t        valu2_dest;
        vector_reg_id_t        valu2_x;
        vector_reg_id_t        valu2_y;
        valu_ctrl_t             valu_ctrl;

        vmem_opcode_t          vmem_op;
        vector_reg_id_t        vmem_reg;
        vmem_imm_t             vmem_addr;
        vmem_index_t           vmem_index;
        vmem_stride_t          vmem_stride_m1;
        vmem_skip_t            vmem_skip;

        vex_opcode_t           vex_op;
        vector_reg_id_t        vex_x;
        mxu_engine_id_t        vex_engine;
        logic                  vex_bank;
        logic [1:0]            vex_mode;
        scale_reg_id_t         vex_sreg;

        vr_opcode_t            vr_op;
        vector_reg_id_t        vr_dest;
        mxu_engine_id_t        vr_engine;
    } decoded_bundle_t;

    logic                       halt_q;
    logic                       decode_ready;
    logic                       fetched_valid_q;
    logic [IMEM_ADDR_WIDTH-1:0] fetched_pc_q;
    logic                       issue_fire;
    logic                       refetch;
    logic [IMEM_ADDR_WIDTH-1:0] redirect_pc;
    logic                       loop_start;
    logic [7:0]                 control_events;
    logic [IMEM_ADDR_WIDTH-1:0] loop_first;
    logic [IMEM_ADDR_WIDTH-1:0] loop_last;
    scalar_word_t               loop_count;
    logic                       scalar_active;
    scalar_opcode_t             scalar_op;
    scalar_reg_id_t             scalar_dest;
    logic                       load_request;
    logic                       writeback_valid_q;
    logic                       commit_valid_q;
    scalar_word_t               operand [3];
    logic                       operand_zero [3];
    scalar_word_t               index_operand      [INDEXES];
    vmem_index_t                imem_vmem_index    [INDEXES];
    scalar_reg_id_t             imem_index         [INDEXES];
    logic                       imem_index_used    [INDEXES];
    scalar_reg_id_t             decoded_index      [INDEXES];
    logic                       decoded_index_used [INDEXES];

    bundle_t                    imem_instr;
    bundle_t                    fetched_instr_q;
    scalar_instr_t              imem_scalar;
    scalar_reg_id_t             imem_x;
    scalar_source_t             imem_y;
    scalar_source_t             imem_dma_length;
    logic [2:0]                 imem_source_used;
    decoded_bundle_t            decoded_d;
    decoded_bundle_t            issued_q;
    scalar_word_t               load_data;

    logic                       smem_req_valid [2];
    logic                       smem_req_write [2];
    logic [SMEM_ADDR_WIDTH-1:0] smem_req_addr  [2];
    scalar_word_t               smem_req_wdata [2];
    logic                       smem_rsp_valid [2];
    scalar_word_t               smem_rsp_data  [2];

    assign scalar_op         = issued_q.scalar_op;
    assign perf_events       = {control_events[7:6],
                                control_events[5] && issued_q.vex_op != PUSH,
                                control_events[5] && issued_q.vex_op == PUSH,
                                control_events[4:0]};
    assign imem_scalar       = bundle_scalar(imem_instr);
    assign imem_x            = scalar_a(imem_scalar);
    assign imem_y            = scalar_b(imem_scalar);
    assign imem_dma_length   = dma_length(imem_scalar);
    assign imem_source_used  = scalar_sources_used(imem_scalar);
    assign imem_vmem_index[0]    = vmem_index(bundle_vmem(imem_instr));
    assign imem_index_used[0]    = imem_vmem_index[0] != '0 && vmem_opcode(bundle_vmem(imem_instr)) inside {VLD, VST};
    assign decoded_index[0]      = scalar_reg_id_t'(decoded_d.vmem_index);
    assign decoded_index_used[0] = decoded_d.vmem_index != '0 && decoded_d.vmem_op inside {VLD, VST};
    for (genvar i = 0; i < INDEXES; i++) begin : gen_imem_index
        assign imem_index[i] = scalar_reg_id_t'(imem_vmem_index[i]);
    end
    assign scalar_dest       = issued_q.scalar_dest;
    assign dma_req_direction = issued_q.dma_direction;
    assign dma_req_src_addr  = operand[0];
    assign dma_req_dst_addr  = operand[1];
    assign dma_req_length    = operand[2];

    assign valu_op           = issued_q.valu_op;
    assign valu_dest         = issued_q.valu_dest;
    assign valu_x            = issued_q.valu_x;
    assign valu_y            = issued_q.valu_y;
    assign valu_srot         = issued_q.valu_srot;
    assign valu2_op          = issued_q.valu2_op;
    assign valu2_dest        = issued_q.valu2_dest;
    assign valu2_x           = issued_q.valu2_x;
    assign valu2_y           = issued_q.valu2_y;
    assign valu_ctrl          = issued_q.valu_ctrl;

    assign vmem_op           = issued_q.vmem_op;
    assign vmem_reg          = issued_q.vmem_reg;
    assign vmem_stride_m1    = issued_q.vmem_stride_m1;
    assign vmem_skip         = issued_q.vmem_skip;
    assign vmem_addr         = VMEM_ADDR_WIDTH'(issued_q.vmem_addr) + (issued_q.vmem_index != '0 ?
                               VMEM_ADDR_WIDTH'(index_operand[0]) : '0);

    assign vex_op            = issued_q.vex_op;
    assign vex_x             = issued_q.vex_x;
    assign vex_engine        = issued_q.vex_engine;
    assign vex_bank          = issued_q.vex_bank;
    assign vex_mode          = issued_q.vex_mode;
    assign vex_sreg          = issued_q.vex_sreg;

    assign vr_op             = issued_q.vr_op;
    assign vr_dest           = issued_q.vr_dest;
    assign vr_engine         = issued_q.vr_engine;

    assign load_data          = smem_rsp_data[0];
    assign smem_req_valid[0]  = load_request || (scalar_active && (scalar_op == STORE));
    assign smem_req_write[0]  = (scalar_op == STORE);
    assign smem_req_addr[0]   = operand[1][SMEM_ADDR_WIDTH-1:0];
    assign smem_req_wdata[0]  = operand[0];

    always_ff @(posedge clk) begin
        if (rst) begin
            smem_req_valid[1]       <= 1'b0;
            smem_req_write[1]       <= 1'b0;
            smem_dma_read_rsp_valid <= 1'b0;
        end else begin
            smem_req_valid[1]       <= smem_dma_write_valid || smem_dma_read_req_valid;
            smem_req_write[1]       <= smem_dma_write_valid;
            smem_dma_read_rsp_valid <= smem_rsp_valid[1];
        end
        smem_dma_read_rsp_data <= smem_rsp_data[1];
        smem_req_addr[1]       <= smem_dma_write_valid ? smem_dma_write_addr : smem_dma_read_req_addr;
        smem_req_wdata[1]      <= smem_dma_write_data;

        if (issue_fire) begin
            issued_q <= decoded_d;
        end
    end

    scalar_fetch #(
        .IMEM_DEPTH(IMEM_DEPTH)
    ) fetch (
        .clk,
        .rst,
        .enable,
        .halt_q,
        .decode_ready,
        .refetch,
        .redirect_pc,
        .imem_dma_write_valid,
        .imem_dma_write_addr,
        .imem_dma_write_data,
        .loop_start,
        .loop_first,
        .loop_last,
        .loop_count,
        .fetched_valid_q,
        .fetched_pc_q,
        .imem_instr,
        .fetched_instr_q
    );

    scalar_control #(
        .IMEM_DEPTH(IMEM_DEPTH)
    ) control (
        .clk,
        .rst,
        .enable,
        .fetched_valid_q,
        .fetched_pc_q,
        .decoded_scalar_op   (decoded_d.scalar_op),
        .decoded_valu_op     (decoded_d.valu_op),
        .decoded_valu2_op    (decoded_d.valu2_op),
        .decoded_vmem_op     (decoded_d.vmem_op),
        .decoded_vex_op      (decoded_d.vex_op),
        .decoded_vr_op       (decoded_d.vr_op),
        .imem_x,
        .imem_y,
        .imem_dma_length,
        .imem_source_used,
        .imem_index,
        .imem_index_used,
        .scalar_dest,
        .writeback_valid_q,
        .commit_valid_q,
        .operand_zero,
        .salu_a              (operand[0]),
        .salu_b              (operand[1]),
        .dma_req_ready,
        .dma_done,
        .dma_req_direction,
        .vector_ready,
        .halt,
        .halt_q,
        .decode_ready,
        .issue_fire,
        .refetch,
        .redirect_pc,
        .loop_start,
        .loop_first,
        .loop_last,
        .loop_count,
        .scalar_active,
        .load_request,
        .dma_req_valid,
        .valu_valid,
        .vmem_valid,
        .vex_valid,
        .vr_valid,
        .perf_events         (control_events)
    );

    scalar_execute #(.INDEXES(INDEXES)) execute (
        .clk,
        .rst,
        .flush          (!enable),
        .valid          (scalar_active),
        .op             (scalar_op),
        .dest           (scalar_dest),
        .read_valid     (issue_fire),
        .x              (decoded_d.scalar_x),
        .y              (decoded_d.scalar_y),
        .dma_length     (decoded_d.dma_length),
        .source_used    (decoded_d.source_used),
        .immediate      (decoded_d.immediate),
        .index          (decoded_index),
        .index_used     (decoded_index_used),
        .index_operand,
        .load_data,
        .operand,
        .operand_zero,
        .result_valid_q (writeback_valid_q),
        .commit_valid_q
    );

    mem #(
        .DATA_WIDTH(SCALAR_WORD_WIDTH),
        .DEPTH(SMEM_DEPTH),
        .PORTS(2)
    ) smem (
        .clk,
        .rst,
        .req_valid (smem_req_valid),
        .req_write (smem_req_write),
        .req_addr  (smem_req_addr),
        .req_wdata (smem_req_wdata),
        .rsp_valid (smem_rsp_valid),
        .rsp_rdata (smem_rsp_data)
    );

    bundle_decode decode (
        .instr            (fetched_instr_q),
        .scalar_op_d      (decoded_d.scalar_op),
        .scalar_dest_d    (decoded_d.scalar_dest),
        .scalar_x_d       (decoded_d.scalar_x),
        .scalar_y_d       (decoded_d.scalar_y),
        .dma_length_d     (decoded_d.dma_length),
        .source_used_d    (decoded_d.source_used),
        .dma_direction_d  (decoded_d.dma_direction),
        .immediate_d      (decoded_d.immediate),
        .valu_op_d        (decoded_d.valu_op),
        .valu_dest_d      (decoded_d.valu_dest),
        .valu_x_d         (decoded_d.valu_x),
        .valu_y_d         (decoded_d.valu_y),
        .valu_srot_d      (decoded_d.valu_srot),
        .valu2_op_d       (decoded_d.valu2_op),
        .valu2_dest_d     (decoded_d.valu2_dest),
        .valu2_x_d        (decoded_d.valu2_x),
        .valu2_y_d        (decoded_d.valu2_y),
        .valu_ctrl_d       (decoded_d.valu_ctrl),
        .vmem_op_d        (decoded_d.vmem_op),
        .vmem_reg_d       (decoded_d.vmem_reg),
        .vmem_addr_d      (decoded_d.vmem_addr),
        .vmem_index_d     (decoded_d.vmem_index),
        .vmem_stride_m1_d (decoded_d.vmem_stride_m1),
        .vmem_skip_d      (decoded_d.vmem_skip),
        .vex_op_d         (decoded_d.vex_op),
        .vex_x_d          (decoded_d.vex_x),
        .vex_engine_d     (decoded_d.vex_engine),
        .vex_bank_d       (decoded_d.vex_bank),
        .vex_mode_d       (decoded_d.vex_mode),
        .vex_sreg_d       (decoded_d.vex_sreg),
        .vr_op_d          (decoded_d.vr_op),
        .vr_dest_d        (decoded_d.vr_dest),
        .vr_engine_d      (decoded_d.vr_engine)
    );
endmodule
