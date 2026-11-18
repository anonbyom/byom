module lane_vex #(
    parameter int unsigned SUBLANES           = 4,
    parameter int unsigned ELEMENT_WIDTH      = isa_pkg::VECTOR_ELEMENT_WIDTH,
    parameter int unsigned MXU_COUNT          = 4,
    parameter int unsigned PUSH_QUEUE_DEPTH   = 2
) (
    input  logic                              clk,

    input  isa_pkg::vex_opcode_t              vex_op,
    input  isa_pkg::mxu_engine_id_t           vex_engine,
    input  logic                              vex_fire,
    input  logic                              vex_bank,
    input  logic [2:0]                        vex_quantize,
    input  logic  [ELEMENT_WIDTH-1:0]         vex_data       [SUBLANES],
    input  logic                [7:0]         vex_scale,

    output logic                              mxu_valid,
    output logic                              mxu_matmul,
    output isa_pkg::mxu_engine_id_t           mxu_engine,
    output logic                              mxu_bank,
    output logic [SUBLANES*ELEMENT_WIDTH-1:0] mxu_data,
    output logic                [7:0]         mxu_scale,
    output logic                              transpose_valid,
    output logic [SUBLANES*ELEMENT_WIDTH-1:0] transpose_data,
    output logic [1:0]                        transpose_func,
    output logic [2:0]                        transpose_quantize
);
    import isa_pkg::*;

    vex_opcode_t    op_q;
    mxu_engine_id_t engine_q;
    logic [1:0]     func;
    logic [1:0]     func_q;
    logic           fire_q;
    logic           bank_q;
    logic [2:0]     quantize_q;
    logic           transpose_pending;
    logic [SUBLANES*ELEMENT_WIDTH-1:0] transpose_word;

    for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_transpose_pack
        assign transpose_word[sublane*ELEMENT_WIDTH +: ELEMENT_WIDTH] = vex_data[sublane];
    end

    always_comb begin
        case (vex_op)
            XLANE_ADD:           func = 2'd1;
            XLANE_MAX, XLANE_QUANTIZE: func = 2'd2;
            XLANE_MIN:           func = 2'd3;
            default:             func = 2'd0;
        endcase
    end

    assign transpose_pending = fire_q && op_q inside {TRANSPOSE_START, TRANSPOSE_CONTINUE, TRANSPOSE_END,
                                                      XLANE_ADD, XLANE_MAX, XLANE_MIN, XLANE_QUANTIZE};
    fifo #(
        .DATA_WIDTH(3 + 2 + SUBLANES*ELEMENT_WIDTH),
        .DEPTH(PUSH_QUEUE_DEPTH+1)
    ) u_transpose_fifo (
        .clk,
        .rst     (1'b0),
        .w_en    (transpose_pending),
        .w_data  ({quantize_q, func_q, transpose_word}),
        .w_rdy   (),
        .r_en    (1'b1),
        .r_data  ({transpose_quantize, transpose_func, transpose_data}),
        .r_valid (transpose_valid),
        .level   ()
    );

    always_ff @(posedge clk) begin
        op_q       <= vex_op;
        engine_q   <= vex_engine;
        func_q     <= func;
        bank_q     <= vex_bank;
        quantize_q <= vex_quantize;
        fire_q     <= vex_fire;

        mxu_valid  <= fire_q && (op_q == PUSH || vex_matmul(op_q));
        mxu_matmul <= op_q != PUSH;
        mxu_engine <= engine_q;
        mxu_bank   <= bank_q;
        mxu_data   <= transpose_word;
        mxu_scale  <= vex_scale;
    end
endmodule : lane_vex
