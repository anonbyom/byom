import isa_pkg::*;

module bundle_decode (
    input bundle_t instr,

    output scalar_opcode_t        scalar_op_d,
    output scalar_reg_id_t        scalar_dest_d,
    output scalar_reg_id_t        scalar_x_d,
    output scalar_source_t        scalar_y_d,
    output scalar_source_t        dma_length_d,
    output logic [2:0]            source_used_d,
    output direction_t            dma_direction_d,
    output scalar_word_t          immediate_d,

    output valu_opcode_t          valu_op_d,
    output vector_reg_id_t        valu_dest_d,
    output vector_reg_id_t        valu_x_d,
    output vector_reg_id_t        valu_y_d,
    output logic [SROT_WIDTH-1:0] valu_srot_d,
    output valu_opcode_t          valu2_op_d,
    output vector_reg_id_t        valu2_dest_d,
    output vector_reg_id_t        valu2_x_d,
    output vector_reg_id_t        valu2_y_d,
    output valu_ctrl_t             valu_ctrl_d,

    output vmem_opcode_t          vmem_op_d,
    output vector_reg_id_t        vmem_reg_d,
    output vmem_imm_t             vmem_addr_d,
    output vmem_index_t           vmem_index_d,
    output vmem_stride_t          vmem_stride_m1_d,
    output vmem_skip_t            vmem_skip_d,


    output vex_opcode_t           vex_op_d,
    output vector_reg_id_t        vex_x_d,
    output mxu_engine_id_t        vex_engine_d,
    output logic                  vex_bank_d,
    output logic [1:0]            vex_mode_d,
    output scale_reg_id_t         vex_sreg_d,

    output vr_opcode_t            vr_op_d,
    output vector_reg_id_t        vr_dest_d,
    output mxu_engine_id_t        vr_engine_d
);
    scalar_instr_t scalar_instr;
    valu_instr_t   valu_instr;
    vmem_instr_t   vmem_instr;
    vex_instr_t    vex_instr;
    vr_instr_t     vr_instr;
    valu2_instr_t  valu2_instr;
    vmem_stride_t  vmem_field_stride;
    vmem_skip_t    vmem_field_skip;

    assign scalar_instr     = bundle_scalar(instr);
    assign valu_instr       = bundle_valu(instr);
    assign vmem_instr       = bundle_vmem(instr);
    assign vex_instr        = bundle_vex(instr);
    assign vr_instr         = bundle_vr(instr);
    assign valu2_instr      = bundle_valu2(instr);

    assign scalar_op_d      = scalar_opcode(scalar_instr);
    assign scalar_dest_d    = scalar_dest(scalar_instr);
    assign scalar_x_d       = scalar_a(scalar_instr);
    assign scalar_y_d       = scalar_b(scalar_instr);
    assign dma_length_d     = dma_length(scalar_instr);
    assign source_used_d    = scalar_sources_used(scalar_instr);
    assign dma_direction_d  = dma_direction(scalar_instr);
    assign immediate_d      = bundle_imm(instr);

    valu_opcode_t valu_isa_op, valu2_isa_op;
    assign valu_isa_op      = valu_opcode(valu_instr, bundle_bit(instr, VALU1_OPCODE_HI_BIT));
    assign valu2_isa_op     = valu2_opcode(valu2_instr);
    // SUB_BF16 runs on the adder with y's sign flipped (valu_ctrl_d.y_neg).
    assign valu_op_d        = valu_isa_op == SUB_BF16 ? ADD_BF16 : valu_isa_op;
    assign valu_dest_d      = valu_dest(valu_instr);
    assign valu_x_d         = valu_x(valu_instr);
    assign valu_y_d         = valu_y(valu_instr);
    assign valu_srot_d      = valu_srot(valu_instr);
    assign valu2_op_d       = valu2_isa_op == SUB_BF16 ? ADD_BF16 : valu2_isa_op;
    assign valu2_dest_d     = valu2_dest(valu2_instr);
    assign valu2_x_d        = valu2_x(valu2_instr);
    assign valu2_y_d        = valu2_y(valu2_instr);

    assign valu_ctrl_d = '{y_imm:        bundle_bit(instr, VALU1_Y_IMM_BIT),
                           y_neg:        valu_isa_op == SUB_BF16,
                           valu2_y_imm:  bundle_bit(instr, VALU2_Y_IMM_BIT),
                           valu2_y_neg:  valu2_isa_op == SUB_BF16,
                           imm:          VALU2 ? immediate_d[15:0] : 16'd0};

    assign vmem_op_d        = vmem_opcode(vmem_instr);
    assign vmem_reg_d       = vmem_reg(vmem_instr);
    assign vmem_addr_d      = vmem_addr(vmem_instr);
    assign vmem_index_d     = vmem_index(vmem_instr);
    assign vmem_field_stride = bundle_vmem_stride_m1(instr);
    assign vmem_field_skip   = bundle_vmem_skip(instr);
    assign vmem_stride_m1_d  = vmem_field_stride;
    assign vmem_skip_d       = vmem_field_skip;


    assign vex_op_d         = vex_opcode(vex_instr);
    assign vex_x_d          = vex_x(vex_instr);
    assign vex_engine_d     = vex_engine(vex_instr);
    assign vex_bank_d       = vex_bank(vex_instr);
    assign vex_mode_d       = vex_mode(vex_instr);
    assign vex_sreg_d       = vex_sreg(vex_instr);

    assign vr_op_d          = vr_opcode(vr_instr);
    assign vr_dest_d        = vr_dest(vr_instr);
    assign vr_engine_d      = vr_engine(vr_instr);
endmodule
