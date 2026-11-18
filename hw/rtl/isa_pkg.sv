package isa_pkg;
    localparam int unsigned SCALAR_REGISTER_COUNT    = 32;
    localparam int unsigned SCALAR_WORD_WIDTH        = 32;
    localparam int unsigned VECTOR_REGISTER_COUNT    = 16;
    localparam int unsigned VECTOR_REGISTER_ID_WIDTH = 5;
    localparam int unsigned VECTOR_ELEMENT_WIDTH     = 16;
    localparam int unsigned SUBLANE_COUNT            = 4;
    localparam int unsigned MXU_MAX_COUNT            = 4;

    localparam int unsigned SCALAR_SLOT_WIDTH        = 29;
    localparam int unsigned VALU_SLOT_WIDTH          = 22;
    localparam int unsigned VMEM_SLOT_WIDTH          = 25;
    localparam int unsigned VEX_SLOT_WIDTH           = 16;
    localparam int unsigned VR_SLOT_WIDTH            = 10;
    localparam int unsigned IMM_SLOT_WIDTH           = 20;
    // VALU2: a second VALU (BF16 ADD/MUL) in a 32-bit bundle word after bit 128.
`ifdef VALU2
    localparam bit          VALU2                    = 1'b1;
`else
    localparam bit          VALU2                    = 1'b0;
`endif
    localparam int unsigned VALU2_SLOT_WIDTH         = 18;
    localparam int unsigned VALU2_SLOT_OFFSET        = 128;
    // After the VALU2 slot: each VALU's y source (1: the immediate's low 16 bits), then VALU1's opcode bit 5.
    localparam int unsigned VALU1_Y_IMM_BIT          = VALU2_SLOT_OFFSET + VALU2_SLOT_WIDTH;
    localparam int unsigned VALU2_Y_IMM_BIT          = VALU1_Y_IMM_BIT + 1;
    localparam int unsigned VALU1_OPCODE_HI_BIT      = VALU2_Y_IMM_BIT + 1;
    localparam int unsigned BUNDLE_WIDTH             = 128 + 32 * int'(VALU2);

    localparam int unsigned SCALAR_SLOT_OFFSET       = 0;
    localparam int unsigned VALU_SLOT_OFFSET         = SCALAR_SLOT_OFFSET + SCALAR_SLOT_WIDTH;
    localparam int unsigned VMEM_SLOT_OFFSET         = VALU_SLOT_OFFSET + VALU_SLOT_WIDTH;
    localparam int unsigned VEX_SLOT_OFFSET          = VMEM_SLOT_OFFSET + VMEM_SLOT_WIDTH;
    localparam int unsigned VR_SLOT_OFFSET           = VEX_SLOT_OFFSET + VEX_SLOT_WIDTH;
    localparam int unsigned IMM_SLOT_OFFSET          = VR_SLOT_OFFSET + VR_SLOT_WIDTH;

    localparam int unsigned SCALAR_OPCODE_WIDTH      = 4;
    localparam int unsigned SCALAR_OPCODE_COUNT      = 12;
    localparam int unsigned VALU_OPCODE_WIDTH        = 6;   // bit 5 in the VALU2 word (VALU1_OPCODE_HI_BIT)
    localparam int unsigned VMEM_OPCODE_WIDTH        = 2;
    localparam int unsigned VEX_OPCODE_WIDTH         = 4;
    localparam int unsigned VR_OPCODE_WIDTH          = 3;
    localparam int unsigned SROT_WIDTH               = $clog2(SUBLANE_COUNT);
    localparam int unsigned VMEM_INDEX_WIDTH         = 3;
    localparam int unsigned SCALE_REG_COUNT          = 8;

    typedef logic [$clog2(SCALAR_REGISTER_COUNT)-1:0]   scalar_reg_id_t;
    typedef logic [$clog2(SCALAR_REGISTER_COUNT+1)-1:0] scalar_source_t;
    typedef logic [VECTOR_REGISTER_ID_WIDTH-1:0]        vector_reg_id_t;
    typedef logic [14:0]                                vmem_imm_t;
    typedef logic [$clog2(MXU_MAX_COUNT)-1:0]           mxu_engine_id_t;
    typedef logic [SCALAR_WORD_WIDTH-1:0]               scalar_word_t;
    typedef logic [VMEM_INDEX_WIDTH-1:0]                vmem_index_t;
    typedef logic [1:0]                                 vmem_stride_t;
    typedef logic [SUBLANE_COUNT-1:0]                   vmem_skip_t;
    typedef logic [$clog2(SCALE_REG_COUNT)-1:0]         scale_reg_id_t;
    typedef logic [VECTOR_ELEMENT_WIDTH-1:0]            vector_element_t;

    typedef enum logic [SCALAR_OPCODE_WIDTH-1:0] {
        NOP      = 4'h0,
        MOV      = 4'h1,
        ADD      = 4'h2,
        SHL      = 4'h3,
        LOAD     = 4'h4,
        STORE    = 4'h5,
        BRZ      = 4'h6,
        BRNZ     = 4'h7,
        DMA      = 4'h8,
        DMA_WAIT = 4'h9,
        HALT     = 4'ha,
        LOOP     = 4'hb
    } scalar_opcode_t;

    typedef enum logic [VALU_OPCODE_WIDTH-1:0] {
        VNOP            = 6'h00,
        ADD_BF16        = 6'h01,
        MUL_BF16        = 6'h02,
        VMAX            = 6'h08,
        VMIN            = 6'h09,
        VSROT           = 6'h0a,
        VRELU_GATE      = 6'h0b,
        VSCALE          = 6'h0c,
        VEUP            = 6'h0d,
        VPACK_4_C       = 6'h0e,
        VPACK_4_I       = 6'h0f,
        VPACK_8_C       = 6'h10,
        VPACK_8_I       = 6'h11,
        VPACK_S8_C      = 6'h12,
        VPACK_S8_I      = 6'h13,
        VPACK_U8_C      = 6'h14,
        VPACK_U8_I      = 6'h15,
        VUNPACK_S8_LO   = 6'h16,
        VUNPACK_S8_HI   = 6'h17,
        VUNPACK_U8_LO   = 6'h18,
        VUNPACK_U8_HI   = 6'h19,
        VOR             = 6'h1a,
        VPACK_I_0       = 6'h1b,
        VPACK_I_1       = 6'h1c,
        VQUANT_START    = 6'h1d,
        VQUANT_CONTINUE = 6'h1e,
        VQUANT_END      = 6'h1f,
        // VALU2 bundles only (opcode bit 5); decoded to the base unit's op (bundle_decode).
        SUB_BF16        = 6'h20,
        VAND            = 6'h21,
        VXOR            = 6'h22
    } valu_opcode_t;


    function automatic logic valu_alu_op(valu_opcode_t op);
        return op inside {VMIN, VMAX, VSROT, VRELU_GATE, VOR, VAND, VXOR};
    endfunction

    function automatic logic valu_pack_op(valu_opcode_t op);
        return op inside {VPACK_4_C, VPACK_4_I, VPACK_8_C, VPACK_8_I, VPACK_S8_C, VPACK_S8_I, VPACK_U8_C, VPACK_U8_I,
                          VUNPACK_S8_LO, VUNPACK_S8_HI, VUNPACK_U8_LO, VUNPACK_U8_HI, VPACK_I_0, VPACK_I_1};
    endfunction

    typedef enum logic [VMEM_OPCODE_WIDTH-1:0] {
        VMEM_NOP = 2'h0,
        VLD      = 2'h1,
        VST      = 2'h2
    } vmem_opcode_t;

    typedef enum logic [VEX_OPCODE_WIDTH-1:0] {
        VEX_NOP            = 4'h0,
        PUSH               = 4'h1,
        MATMUL             = 4'h2,
        MATMUL_PRELOAD     = 4'h3,
        TRANSPOSE_START    = 4'h4,
        TRANSPOSE_CONTINUE = 4'h5,
        TRANSPOSE_END      = 4'h6,
        XLANE_ADD          = 4'h7,
        XLANE_MAX          = 4'h8,
        XLANE_MIN          = 4'h9,
        XLANE_QUANTIZE     = 4'ha
    } vex_opcode_t;

    function automatic logic vex_preload(vex_opcode_t op);
        return op == MATMUL_PRELOAD;
    endfunction
    function automatic logic vex_matmul(vex_opcode_t op);
        return op == MATMUL || op == MATMUL_PRELOAD;
    endfunction

    typedef enum logic [1:0] {
        QUANTIZE_A  = 2'd0,
        QUANTIZE_W  = 2'd1,
        QUANTIZE_WT = 2'd2   // W of the transposed tile
    } quantize_mode_t;

    typedef enum logic [1:0] {
        ACC_EMIT       = 2'd0,
        ACC_FIRST      = 2'd1,
        ACC_ACCUMULATE = 2'd2,
        ACC_LAST       = 2'd3
    } acc_mode_t;

    typedef struct packed {
        logic [1:0] tile_mode;  // the preload's sreg[1:0] (MXU_TILE_MODES), kept by the engine's MATMULs
        acc_mode_t  acc_mode;
        logic       bank;
        logic       preload;
    } mxu_command_t;

    typedef enum logic [2:0] {
        EUP_LOG2            = 3'd0,
        EUP_POW2            = 3'd1,
        EUP_RECIPROCAL      = 3'd2,
        EUP_RSQRT           = 3'd3,
        EUP_TANH            = 3'd4,
        EUP_SHIFTED_SIGMOID = 3'd5
    } eup_function_t;

    typedef enum logic [VR_OPCODE_WIDTH-1:0] {
        VR_NOP        = 3'h0,
        POP_MXU       = 3'h1,
        POP_FP        = 3'h2,
        POP_XLU       = 3'h3,
        POP_EUP       = 3'h4,
        POP_QUANT     = 3'h5
    } vr_opcode_t;

    typedef enum logic [2:0] {
        HBM_TO_IMEM = 3'h0,
        HBM_TO_SMEM = 3'h1,
        SMEM_TO_HBM = 3'h2,
        HBM_TO_VMEM = 3'h3,
        VMEM_TO_HBM = 3'h4
    } direction_t;

    localparam scalar_source_t SCALAR_IMM0 = scalar_source_t'(SCALAR_REGISTER_COUNT);

    typedef logic [SCALAR_SLOT_WIDTH-1:0] scalar_instr_t;
    typedef logic [VALU_SLOT_WIDTH-1:0]   valu_instr_t;
    typedef logic [VMEM_SLOT_WIDTH-1:0]   vmem_instr_t;
    typedef logic [VEX_SLOT_WIDTH-1:0]    vex_instr_t;
    typedef logic [VR_SLOT_WIDTH-1:0]     vr_instr_t;
    typedef logic [BUNDLE_WIDTH-1:0]      bundle_t;

    function automatic scalar_instr_t bundle_scalar(input bundle_t i);
        return i[SCALAR_SLOT_OFFSET +: SCALAR_SLOT_WIDTH];
    endfunction
    function automatic valu_instr_t bundle_valu(input bundle_t i);
        return i[VALU_SLOT_OFFSET +: VALU_SLOT_WIDTH];
    endfunction
    function automatic vmem_instr_t bundle_vmem(input bundle_t i);
        return i[VMEM_SLOT_OFFSET +: VMEM_SLOT_WIDTH];
    endfunction
    function automatic vex_instr_t bundle_vex(input bundle_t i);
        return i[VEX_SLOT_OFFSET +: VEX_SLOT_WIDTH];
    endfunction
    function automatic vr_instr_t bundle_vr(input bundle_t i);
        return i[VR_SLOT_OFFSET +: VR_SLOT_WIDTH];
    endfunction
    function automatic scalar_word_t bundle_imm(input bundle_t i);
        return scalar_word_t'(i[IMM_SLOT_OFFSET +: IMM_SLOT_WIDTH]);
    endfunction

    // Decoded VALU controls beside the op, y sources, SUB's sign flip.
    typedef struct packed {
        logic        y_imm;        // VALU1's y is imm
        logic        y_neg;        // VALU1 SUB_BF16
        logic        valu2_y_imm;  // VALU2's y is imm
        logic        valu2_y_neg;  // VALU2 SUB_BF16
        logic [15:0] imm;          // the bundle immediate's low 16 bits
    } valu_ctrl_t;

    function automatic logic bundle_bit(input bundle_t i, input int unsigned position);
        logic [VALU1_OPCODE_HI_BIT:0] wide;
        wide = (VALU1_OPCODE_HI_BIT+1)'(i);
        return VALU2 && wide[position];
    endfunction

    typedef logic [VALU2_SLOT_WIDTH-1:0]  valu2_instr_t;
    function automatic valu2_instr_t bundle_valu2(input bundle_t i);
        logic [VALU2_SLOT_OFFSET+VALU2_SLOT_WIDTH-1:0] wide;
        wide = (VALU2_SLOT_OFFSET+VALU2_SLOT_WIDTH)'(i);
        return VALU2 ? wide[VALU2_SLOT_OFFSET +: VALU2_SLOT_WIDTH] : '0;
    endfunction
    function automatic scalar_opcode_t scalar_opcode(input scalar_instr_t i);
        return scalar_opcode_t'(i[25 +: 4]);
    endfunction
    function automatic scalar_reg_id_t scalar_dest(input scalar_instr_t i);
        return i[20 +: 5];
    endfunction
    function automatic scalar_reg_id_t scalar_a(input scalar_instr_t i);
        return i[15 +: 5];
    endfunction
    function automatic scalar_source_t scalar_b(input scalar_instr_t i);
        return scalar_source_t'(i[9 +: 6]);
    endfunction
    function automatic scalar_source_t dma_length(input scalar_instr_t i);
        return scalar_source_t'(i[3 +: 6]);
    endfunction
    function automatic direction_t dma_direction(input scalar_instr_t i);
        return direction_t'(i[0 +: 3]);
    endfunction
    function automatic logic dma_async(input scalar_instr_t i);
        return i[20];
    endfunction

    function automatic logic [2:0] scalar_sources_used(input scalar_instr_t i);
        scalar_opcode_t op;
        op = scalar_opcode(i);
        return {dma_length(i) != SCALAR_IMM0 && op == DMA,
                scalar_b(i) != SCALAR_IMM0 && op inside {MOV, ADD, SHL, LOAD, STORE, BRZ, BRNZ, DMA, LOOP},
                op inside {ADD, SHL, STORE, BRZ, BRNZ, DMA, LOOP}};
    endfunction

    function automatic valu_opcode_t valu_opcode(input valu_instr_t i, input logic hi);
        return valu_opcode_t'({hi, i[17 +: 5]});
    endfunction
    function automatic vector_reg_id_t valu_dest(input valu_instr_t i);
        return i[12 +: 5];
    endfunction
    function automatic vector_reg_id_t valu_x(input valu_instr_t i);
        return i[7 +: 5];
    endfunction
    function automatic vector_reg_id_t valu_y(input valu_instr_t i);
        return i[2 +: 5];
    endfunction
    function automatic logic [SROT_WIDTH-1:0] valu_srot(input valu_instr_t i);
        return i[0 +: SROT_WIDTH];
    endfunction
    function automatic vmem_opcode_t vmem_opcode(input vmem_instr_t i);
        return vmem_opcode_t'(i[VMEM_SLOT_WIDTH - 2 +: 2]);
    endfunction
    function automatic vector_reg_id_t vmem_reg(input vmem_instr_t i);
        return i[VMEM_INDEX_WIDTH + 15 +: 5];
    endfunction
    function automatic vmem_imm_t vmem_addr(input vmem_instr_t i);
        return i[VMEM_INDEX_WIDTH +: 15];
    endfunction

    function automatic vmem_index_t vmem_index(input vmem_instr_t i);
        return i[0 +: VMEM_INDEX_WIDTH];
    endfunction

    function automatic vex_opcode_t vex_opcode(input vex_instr_t i);
        return vex_opcode_t'(i[12 +: 4]);
    endfunction
    function automatic logic [1:0] vex_mode(input vex_instr_t i);
        return i[1 +: 2];
    endfunction
    function automatic logic vex_bank(input vex_instr_t i);
        return i[0];
    endfunction
    function automatic vector_reg_id_t vex_x(input vex_instr_t i);
        return i[7 +: 5];
    endfunction
    function automatic scale_reg_id_t vex_sreg(input vex_instr_t i);
        return scale_reg_id_t'(i[3 +: 2]);
    endfunction
    function automatic mxu_engine_id_t vex_engine(input vex_instr_t i);
        return i[5 +: 2];
    endfunction

    function automatic vmem_stride_t bundle_vmem_stride_m1(input bundle_t i);
        return i[IMM_SLOT_OFFSET + IMM_SLOT_WIDTH +: 2];
    endfunction
    function automatic vmem_skip_t bundle_vmem_skip(input bundle_t i);
        return i[IMM_SLOT_OFFSET + IMM_SLOT_WIDTH + 2 +: SUBLANE_COUNT];
    endfunction

    // VALU2 field, from bit 17 down: opcode 3 | dest 5 | x 5 | y 5.
    function automatic valu_opcode_t valu2_opcode(input valu2_instr_t i);
        case (i[15 +: 3])
            3'd1:    return ADD_BF16;
            3'd2:    return MUL_BF16;
            3'd3:    return SUB_BF16;
            default: return VNOP;
        endcase
    endfunction
    function automatic vector_reg_id_t valu2_dest(input valu2_instr_t i);
        return i[10 +: 5];
    endfunction
    function automatic vector_reg_id_t valu2_x(input valu2_instr_t i);
        return i[5 +: 5];
    endfunction
    function automatic vector_reg_id_t valu2_y(input valu2_instr_t i);
        return i[0 +: 5];
    endfunction

    function automatic vr_opcode_t vr_opcode(input vr_instr_t i);
        return vr_opcode_t'(i[7 +: 3]);
    endfunction
    function automatic vector_reg_id_t vr_dest(input vr_instr_t i);
        return i[2 +: 5];
    endfunction
    function automatic mxu_engine_id_t vr_engine(input vr_instr_t i);
        return i[0 +: 2];
    endfunction
endpackage
