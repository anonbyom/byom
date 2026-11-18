module vlane #(
    parameter int unsigned VREG_COUNT         = 16,
    parameter int unsigned ELEMENT_WIDTH      = isa_pkg::VECTOR_ELEMENT_WIDTH,
    parameter int unsigned SUBLANES           = 4,
    parameter int unsigned BANKS              = 16,
    parameter int unsigned VMEM_DEPTH         = 32768,
    parameter int unsigned MXU_COUNT          = 4,
    parameter int unsigned PUSH_QUEUE_DEPTH   = 2,
    parameter int unsigned POP_QUEUE_DEPTH    = 18,
    parameter bit VMEM_URAM_OREG              = 1'b0,
    parameter int unsigned FP_DEPTH           = 16,
    parameter int unsigned EUP_WIDTH          = 1,
    parameter bit SCALE_REGS                  = 1'b0,
    parameter bit FIRST_LANE                  = 1'b1,
    parameter bit VALU2                       = 1'b0,

    localparam int unsigned READ_PORTS       = VALU2 ? 6 : 4,
    localparam int unsigned VREG_ADDR_WIDTH  = $clog2(VREG_COUNT),
    localparam int unsigned VMEM_ADDR_WIDTH  = $clog2(VMEM_DEPTH),
    localparam int unsigned BANK_ADDR_WIDTH  = $clog2(VMEM_DEPTH / BANKS),
    localparam int unsigned LOAD_GROUPS      = BANKS / SUBLANES,
    localparam int unsigned LOAD_GROUP_WIDTH = LOAD_GROUPS > 1 ? $clog2(LOAD_GROUPS) : 1,
    localparam int unsigned EUP_BEAT_W       = SUBLANES / EUP_WIDTH > 1 ? $clog2(SUBLANES / EUP_WIDTH) : 1
) (
    input  logic                              clk,

    input  logic                              valu_valid,
    input  isa_pkg::valu_opcode_t             valu_op,
    input  logic [VREG_ADDR_WIDTH-1:0]        valu_dest,
    input  logic [isa_pkg::SROT_WIDTH-1:0]    valu_srot,

    input  logic                              valu2_valid,
    input  isa_pkg::valu_opcode_t             valu2_op,
    input  logic [VREG_ADDR_WIDTH-1:0]        valu2_dest,
    input  isa_pkg::valu_ctrl_t               valu_ctrl,
    input  logic                              valu_y_imm_next,

    input  logic                              vmem_valid,
    input  isa_pkg::vmem_opcode_t             vmem_op,
    input  logic [VREG_ADDR_WIDTH-1:0]        vmem_reg,
    input  logic [VMEM_ADDR_WIDTH-1:0]        vmem_addr,
    input  isa_pkg::vmem_stride_t             vmem_stride_m1,
    input  isa_pkg::vmem_skip_t               vmem_skip,

    input  isa_pkg::vex_opcode_t              vex_op,
    input  logic [VREG_ADDR_WIDTH-1:0]        read_addr_next [READ_PORTS],
    input  isa_pkg::mxu_engine_id_t           vex_engine,
    input  logic                              vex_bank,
    input  isa_pkg::scale_reg_id_t            vex_sreg,
    input  logic [2:0]                        vex_quantize,
    input  logic                              vex_fire,

    input  logic [VREG_ADDR_WIDTH-1:0]        pop_dest,
    input  isa_pkg::vr_opcode_t               pop_op,
    input  isa_pkg::mxu_engine_id_t           pop_engine,
    output logic                              pop_arrived    [MXU_COUNT],
    output logic                              transpose_pop_arrived,
    output logic                              fp_pop_arrived,
    output logic                              eup_pop_arrived,
    output logic                              quant_pop_arrived,
    input  logic                              pop_fire,

    output logic                              mxu_valid,
    output logic                              mxu_matmul,
    output isa_pkg::mxu_engine_id_t           mxu_engine,
    output logic                              mxu_bank,
    output logic [SUBLANES*ELEMENT_WIDTH-1:0] mxu_data,
    output logic [7:0]                        mxu_scale,
    output logic                              transpose_push_valid,
    output logic [SUBLANES*ELEMENT_WIDTH-1:0] transpose_push_data,
    output isa_pkg::mxu_engine_id_t           transpose_push_func,
    output logic [2:0]                        transpose_push_quantize,

    input  logic                              mxu_pop_valid       [SUBLANES][MXU_COUNT],
    input  logic [ELEMENT_WIDTH-1:0]          mxu_pop_data        [SUBLANES][MXU_COUNT],
    input  logic                              transpose_pop_valid,
    input  logic [ELEMENT_WIDTH-1:0]          transpose_pop_data  [SUBLANES],


    input  logic [5:0]                        selects_in     [SUBLANES][4],
    output logic [5:0]                        selects_out    [SUBLANES][4],
    input  logic [1:0]                        owners_in      [SUBLANES][READ_PORTS],
    output logic [1:0]                        owners_out     [SUBLANES][READ_PORTS],

    input  logic                              dma_req_valid  [BANKS],
    input  logic                              dma_req_write  [BANKS],
    input  logic [BANK_ADDR_WIDTH-1:0]        dma_req_addr   [BANKS],
    input  logic [ELEMENT_WIDTH-1:0]          dma_req_wdata  [BANKS],
    output logic [ELEMENT_WIDTH-1:0]          dma_rsp_rdata  [BANKS]
);
    import isa_pkg::*;

    logic              [SROT_WIDTH-1:0]      execute_srot;
    logic                                    execute_mem_valid;
    vmem_opcode_t                            execute_mem_op;
    logic              [VMEM_ADDR_WIDTH-1:0] execute_mem_addr;
    logic              [VREG_ADDR_WIDTH-1:0] execute_mem_reg;

    always_ff @(posedge clk) begin
        execute_srot      <= valu_srot;
        execute_mem_op    <= vmem_op;
        execute_mem_addr  <= vmem_addr;
        execute_mem_reg   <= vmem_reg;
        execute_mem_valid <= vmem_valid;
    end

    logic [ELEMENT_WIDTH-1:0]    x_data             [SUBLANES];
    logic [ELEMENT_WIDTH-1:0]    fp_x               [SUBLANES];
    logic [ELEMENT_WIDTH-1:0]    fp_y               [SUBLANES];
    logic                        fp_valid           [SUBLANES];
    logic [VREG_ADDR_WIDTH-1:0]  fp_dest;
    logic [ELEMENT_WIDTH-1:0]    fp_data            [SUBLANES];
    logic                        fp_writeback       [SUBLANES];
    logic                        pack_fire_q;
    valu_opcode_t                pack_op_q;
    logic [VREG_ADDR_WIDTH-1:0]  pack_dest_q        [4];
    logic                        pack_valid;
    logic [ELEMENT_WIDTH-1:0]    pack_data          [SUBLANES];
    logic                        eup_valid          [SUBLANES];
    logic [ELEMENT_WIDTH-1:0]    eup_data           [SUBLANES];
    logic                        eup_fire_q;
    eup_function_t               eup_func_q;
    logic                        quant_valid;
    logic [SUBLANES*ELEMENT_WIDTH-1:0] quant_word;
    logic [ELEMENT_WIDTH-1:0]    srot_data          [SUBLANES];
    logic [ELEMENT_WIDTH-1:0]    store_data         [SUBLANES];
    logic [ELEMENT_WIDTH-1:0]    vex_data           [SUBLANES];
    logic                        load_valid         [SUBLANES];
    logic [ELEMENT_WIDTH-1:0]    load_data          [SUBLANES][LOAD_GROUPS];
    logic [LOAD_GROUP_WIDTH-1:0] load_group         [SUBLANES];
    logic [VREG_ADDR_WIDTH-1:0]  load_dest_q;
    logic [ELEMENT_WIDTH-1:0]    pop_data           [SUBLANES];
    logic [ELEMENT_WIDTH-1:0]    valu2_x            [SUBLANES];
    logic [ELEMENT_WIDTH-1:0]    valu2_y            [SUBLANES];
    logic                        valu2_result_valid [SUBLANES];
    logic [VREG_ADDR_WIDTH-1:0]  valu2_result_dest;
    logic [ELEMENT_WIDTH-1:0]    valu2_result       [SUBLANES];

    barrel_rotator #(
        .INPUTS(SUBLANES),
        .DATA_WIDTH(ELEMENT_WIDTH)
    ) u_srot (
        .data_in  (x_data),
        .rotation (execute_srot),
        .data_out (srot_data)
    );

    valu_bf16 #(
        .SUBLANES(SUBLANES),
        .VREG_COUNT(VREG_COUNT)
    ) u_bf16 (
        .clk,
        .issue_valid (valu_valid),
        .issue_op    (valu_op),
        .issue_dest  (valu_dest),
        .x           (fp_x),
        .y           (fp_y),
        .result_valid(fp_valid),
        .result_dest (fp_dest),
        .result_data (fp_data)
    );

    if (VALU2) begin : gen_valu2
        logic                       fp2_valid [SUBLANES];
        logic [VREG_ADDR_WIDTH-1:0] fp2_dest;
        logic [ELEMENT_WIDTH-1:0]   fp2_data  [SUBLANES];

        valu_bf16 #(
            .SUBLANES(SUBLANES),
            .VREG_COUNT(VREG_COUNT)
        ) u_valu2_bf16 (
            .clk,
            .issue_valid (valu2_valid),
            .issue_op    (valu2_op),
            .issue_dest  (valu2_dest),
            .x           (valu2_x),
            .y           (valu2_y),
            .result_valid(fp2_valid),
            .result_dest (fp2_dest),
            .result_data (fp2_data)
        );

        assign valu2_result_valid = fp2_valid;
        assign valu2_result_dest  = fp2_dest;
        assign valu2_result       = fp2_data;
    end else begin : gen_no_valu2
        assign valu2_result_valid = '{default: 1'b0};
        assign valu2_result_dest  = '0;
        assign valu2_result  = '{default: '0};
    end

    always_ff @(posedge clk) begin
        pack_fire_q <= valu_valid && valu_pack_op(valu_op);
    end
    always_ff @(posedge clk) begin
        pack_op_q   <= valu_op;
        pack_dest_q <= '{valu_dest, pack_dest_q[0], pack_dest_q[1], pack_dest_q[2]};
    end
    lane_pack #(.SUBLANES(SUBLANES)) u_pack (
        .clk,
        .in_valid  (pack_fire_q),
        .op        (pack_op_q),
        .x         (fp_x),
        .y         (fp_y),
        .out_valid (pack_valid),
        .result    (pack_data)
    );

    for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_pack_writeback
        assign fp_writeback[sublane] = pack_valid;
    end

    // One forwarding table per lane; each sublane's VALU gets its own copy of the selects.
    logic fwd_read_rf         [SUBLANES][4];
    logic fwd_read_alu        [SUBLANES][4];
    logic fwd_read_load       [SUBLANES][4];
    logic fwd_read_pop_input  [SUBLANES][4];
    logic fwd_alu_forward_q   [SUBLANES][4];
    logic fwd_load_forward_q  [SUBLANES][4];

    // VALU2's reads (ports 4 and 5) are not forwarded.
    logic [VREG_ADDR_WIDTH-1:0] fwd_read_addr_next [4];
    assign fwd_read_addr_next = '{read_addr_next[0], read_addr_next[1], read_addr_next[2], read_addr_next[3]};

    valu_forwarding #(
        .VREG_COUNT(VREG_COUNT),
        .LOAD_STAGES(4 + VMEM_URAM_OREG),
        .SUBLANES(SUBLANES),
        .FIRST_LANE(FIRST_LANE)
    ) u_forwarding (
        .clk,
        .alu_issue       (valu_valid && valu_alu_op(valu_op)),
        .dest            (valu_dest),
        .load_issue      (vmem_valid && vmem_op == VLD),
        .load_issue_dest (vmem_reg),
        .pop_valid       (pop_fire),
        .pop_dest,
        .read_addr_next  (fwd_read_addr_next),
        .read_none_next  ('{1'b0, valu_y_imm_next, 1'b0, 1'b0}),
        .read_rf         (fwd_read_rf),
        .read_alu        (fwd_read_alu),
        .read_load       (fwd_read_load),
        .read_pop_input  (fwd_read_pop_input),
        .alu_forward_q   (fwd_alu_forward_q),
        .load_forward_q  (fwd_load_forward_q),
        .selects_in,
        .selects_out
    );

    logic [7:0] vex_scale;
    // No in-lane quantizer (VQUANT_*, POP_QUANT): compiled programs quantize in the XLU, and in the MX images its 32
    // copies and their pop FIFOs were 15k LUTs of SLR1, the SLR that sets their clock.
    assign quant_valid = 1'b0;
    assign quant_word  = '0;
    if (SCALE_REGS) begin : gen_scale_regs
        logic [7:0]    scale_regs [isa_pkg::SCALE_REG_COUNT];
        logic          scale_write_q;
        scale_reg_id_t scale_dest_q;
        scale_reg_id_t scale_read_q;
        always_ff @(posedge clk) begin
            scale_write_q <= valu_valid && valu_op == VSCALE;
            scale_dest_q  <= scale_reg_id_t'(valu_dest);
            scale_read_q  <= vex_sreg;
            // x_data is VREG x (forwarded) one cycle after issue, like vex_data.
            if (scale_write_q) scale_regs[scale_dest_q] <= x_data[0][7:0];
        end
        assign vex_scale = scale_regs[scale_read_q];
    end else begin : gen_no_scale_regs
        assign vex_scale = '0;
    end

    for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_valu
        valu #(
            .VREG_COUNT(VREG_COUNT),
            .ELEMENT_WIDTH(ELEMENT_WIDTH),
            .FIRST_LANE(FIRST_LANE),
            .VALU2(VALU2)
        ) u_valu (
            .clk,
            .valid            (valu_valid),
            .op               (valu_op),
            .dest             (valu_dest),
            .ctrl             (valu_ctrl),
            .read_addr_next,
            .srot_in          (srot_data[sublane]),
            .x_data           (x_data[sublane]),
            .fp_x             (fp_x[sublane]),
            .fp_y             (fp_y[sublane]),
            .fp_valid         (fp_writeback[sublane]),
            .fp_dest          (pack_dest_q[3]),
            .fp_data          (pack_data[sublane]),
            .valu2_x          (valu2_x[sublane]),
            .valu2_y          (valu2_y[sublane]),
            .valu2_valid      (valu2_result_valid[sublane]),
            .valu2_dest       (valu2_result_dest),
            .valu2_data       (valu2_result[sublane]),
            .load_valid       (load_valid[sublane]),
            .load_dest        (load_dest_q),
            .load_data        (load_data[sublane][load_group[sublane]]),
            .store_data       (store_data[sublane]),
            .vex_data         (vex_data[sublane]),
            .pop_valid        (pop_fire),
            .pop_dest,
            .pop_data         (pop_data[sublane]),
            .read_rf          (fwd_read_rf[sublane]),
            .read_alu         (fwd_read_alu[sublane]),
            .read_load        (fwd_read_load[sublane]),
            .read_pop_input   (fwd_read_pop_input[sublane]),
            .alu_forward_q    (fwd_alu_forward_q[sublane]),
            .load_forward_q   (fwd_load_forward_q[sublane]),
            .owner_in         (owners_in[sublane]),
            .owner_out        (owners_out[sublane])
        );
    end

    lane_memory #(
        .VREG_COUNT(VREG_COUNT),
        .ELEMENT_WIDTH(ELEMENT_WIDTH),
        .SUBLANES(SUBLANES),
        .BANKS(BANKS),
        .VMEM_DEPTH(VMEM_DEPTH),
        .URAM_OREG(VMEM_URAM_OREG)
    ) u_memory (
        .clk,
        .vmem_valid,
        .vmem_addr,
        .vmem_stride_m1,
        .vmem_skip,
        .execute_mem_valid,
        .execute_mem_op,
        .execute_mem_addr,
        .execute_mem_reg,
        .store_data,
        .load_valid,
        .load_data,
        .load_group,
        .load_dest_q,
        .dma_req_valid,
        .dma_req_write,
        .dma_req_addr,
        .dma_req_wdata,
        .dma_rsp_rdata
    );

    lane_vex #(
        .SUBLANES(SUBLANES),
        .ELEMENT_WIDTH(ELEMENT_WIDTH),
        .MXU_COUNT(MXU_COUNT),
        .PUSH_QUEUE_DEPTH(PUSH_QUEUE_DEPTH)
    ) u_vex (
        .clk,
        .vex_op,
        .vex_engine,
        .vex_bank,
        .vex_quantize,
        .vex_fire,
        .vex_data,
        .vex_scale      (vex_scale),
        .mxu_valid,
        .mxu_matmul,
        .mxu_engine,
        .mxu_bank,
        .mxu_data,
        .mxu_scale,
        .transpose_valid(transpose_push_valid),
        .transpose_data(transpose_push_data),
        .transpose_func(transpose_push_func),
        .transpose_quantize(transpose_push_quantize)
    );

    always_ff @(posedge clk) begin
        eup_func_q    <= eup_function_t'(valu_dest[2:0]);
        eup_fire_q    <= valu_valid && valu_op == VEUP;
    end

    logic                     eup_operand_valid;
    logic [1:0]               eup_operand_unit;
    logic                     eup_operand_variant;
    logic [EUP_BEAT_W-1:0]    eup_operand_beat;
    logic [ELEMENT_WIDTH-1:0] eup_operand [EUP_WIDTH];
    logic                     function_valid;
    logic [EUP_BEAT_W-1:0]    function_beat;
    logic [ELEMENT_WIDTH-1:0] function_result [EUP_WIDTH];

    lane_eup #(
        .SUBLANES(SUBLANES),
        .ELEMENT_WIDTH(ELEMENT_WIDTH),
        .WIDTH(EUP_WIDTH)
    ) u_eup (
        .clk,
        .fire           (eup_fire_q),
        .func           (eup_func_q),
        .x              (fp_x),
        .operand_valid  (eup_operand_valid),
        .operand_unit   (eup_operand_unit),
        .operand_variant(eup_operand_variant),
        .operand_beat   (eup_operand_beat),
        .operand        (eup_operand),
        .function_valid,
        .function_beat,
        .function_result,
        .result_valid   (eup_valid),
        .result_data    (eup_data)
    );

    eup_functions #(
        .ELEMENT_WIDTH(ELEMENT_WIDTH),
        .WIDTH(EUP_WIDTH),
        .BEAT_W(EUP_BEAT_W)
    ) u_functions (
        .clk,
        .operand_valid  (eup_operand_valid),
        .operand_unit   (eup_operand_unit),
        .operand_variant(eup_operand_variant),
        .operand_beat   (eup_operand_beat),
        .operand        (eup_operand),
        .result_valid   (function_valid),
        .result_beat    (function_beat),
        .result         (function_result)
    );

    lane_vr #(
        .SUBLANES(SUBLANES),
        .ELEMENT_WIDTH(ELEMENT_WIDTH),
        .MXU_COUNT(MXU_COUNT),
        .POP_QUEUE_DEPTH(POP_QUEUE_DEPTH),
        .FP_DEPTH(FP_DEPTH),
        .FIRST_LANE(FIRST_LANE)
    ) u_vr (
        .clk,
        .pop_fire,
        .pop_op,
        .pop_engine,
        .pop_data,
        .pop_arrived,
        .transpose_pop_arrived,
        .mxu_pop_valid,
        .mxu_pop_data,
        .transpose_pop_valid,
        .transpose_pop_data,
        .fp_valid,
        .fp_data,
        .fp_pop_arrived,
        .eup_valid,
        .eup_data,
        .eup_pop_arrived,
        .quant_valid,
        .quant_word,
        .quant_pop_arrived
    );

    initial begin
        if (VMEM_DEPTH % BANKS != 0 || (BANKS & (BANKS-1)) != 0)
            $fatal(1, "VMEM_DEPTH must be divisible by a power-of-two bank count");
        if (BANKS < SUBLANES || BANKS % SUBLANES != 0)
            $fatal(1, "BANKS must be a multiple of SUBLANES");
    end
endmodule
