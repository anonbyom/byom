module scalar_control #(
    parameter int unsigned IMEM_DEPTH = 1024,

    localparam int unsigned INDEXES = 1,
    localparam int unsigned IMEM_ADDR_WIDTH = $clog2(IMEM_DEPTH)
) (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       enable,

    input  logic                       fetched_valid_q,
    input  logic [IMEM_ADDR_WIDTH-1:0] fetched_pc_q,
    input  isa_pkg::scalar_opcode_t    decoded_scalar_op,
    input  isa_pkg::valu_opcode_t      decoded_valu_op,
    input  isa_pkg::valu_opcode_t      decoded_valu2_op,
    input  isa_pkg::vmem_opcode_t      decoded_vmem_op,
    input  isa_pkg::vex_opcode_t       decoded_vex_op,
    input  isa_pkg::vr_opcode_t        decoded_vr_op,

    input  isa_pkg::scalar_reg_id_t    imem_x,
    input  isa_pkg::scalar_source_t    imem_y,
    input  isa_pkg::scalar_source_t    imem_dma_length,
    input  logic [2:0]                 imem_source_used,
    input  isa_pkg::scalar_reg_id_t    imem_index [INDEXES],
    input  logic                       imem_index_used [INDEXES],

    input  isa_pkg::scalar_reg_id_t    scalar_dest,
    input  logic                       writeback_valid_q,
    input  logic                       commit_valid_q,
    input  logic                       operand_zero [3],
    input  isa_pkg::scalar_word_t      salu_b,

    input  logic                       dma_req_ready,
    input  logic                       dma_done,
    input  isa_pkg::direction_t        dma_req_direction,
    input  logic                       vector_ready,

    output logic                       halt,
    output logic                       halt_q,
    output logic                       decode_ready,
    output logic                       issue_fire,
    output logic                       refetch,
    output logic [IMEM_ADDR_WIDTH-1:0] redirect_pc,
    input  isa_pkg::scalar_word_t      salu_a,

    output logic                       loop_start,
    output logic [IMEM_ADDR_WIDTH-1:0] loop_first,
    output logic [IMEM_ADDR_WIDTH-1:0] loop_last,
    output isa_pkg::scalar_word_t      loop_count,

    output logic                       scalar_active,
    output logic                       load_request,
    output logic                       dma_req_valid,
    output logic                       valu_valid,
    output logic                       vmem_valid,
    output logic                       vex_valid,
    output logic                       vr_valid,

    output logic [7:0]                 perf_events
);
    import isa_pkg::*;

    logic [IMEM_ADDR_WIDTH-1:0]     pc_q;
    logic [IMEM_ADDR_WIDTH-1:0]     pc_plusone_q;
    logic [SCALAR_OPCODE_COUNT-1:0] execute_op_q;
    logic scalar_done_q;
    logic bundle_valid_q;
    logic valu_done_q;
    logic vmem_done_q;
    logic vex_done_q;
    logic vr_done_q;
    logic [3:0] dma_pending;
    logic dma_outstanding;
    logic dma_fire;
    logic scalar_complete_now;
    logic scalar_complete;
    logic vex_complete;
    logic vr_complete;
    logic vector_done;
    logic bundle_complete;
    logic branch_taken;
    logic imem_loaded_q;

    logic load_hazard;
    logic [2+INDEXES:0] dependency;

    assign dependency[0]   = imem_source_used[0] && imem_x == scalar_dest;
    assign dependency[1]   = imem_source_used[1] && imem_y == scalar_source_t'(scalar_dest);
    assign dependency[2]   = imem_source_used[2] && imem_dma_length == scalar_source_t'(scalar_dest);
    for (genvar i = 0; i < INDEXES; i++) begin : gen_index_dependency
        assign dependency[3 + i] = imem_index_used[i] && imem_index[i] == scalar_dest;
    end

    assign load_hazard = fetched_valid_q && load_request && |dependency;
    assign redirect_pc = branch_taken ? pc_q + salu_b[IMEM_ADDR_WIDTH-1:0] : pc_plusone_q;
    assign loop_start  = bundle_complete && execute_op_q[LOOP];
    assign loop_first  = pc_plusone_q;
    assign loop_last   = pc_q + salu_b[IMEM_ADDR_WIDTH-1:0];
    assign loop_count  = salu_a;
    assign decode_ready = !fetched_valid_q || ((!bundle_valid_q || bundle_complete) && !load_hazard);
    assign issue_fire = enable && fetched_valid_q && !refetch && !halt_q && !load_hazard &&
        (!bundle_valid_q || bundle_complete) && !(bundle_valid_q && execute_op_q[HALT]);

    always_ff @(posedge clk) begin
        if (issue_fire) begin
            execute_op_q <= SCALAR_OPCODE_COUNT'(1) << decoded_scalar_op;
            pc_q         <= fetched_pc_q;
            pc_plusone_q <= fetched_pc_q + 1'b1;
        end
    end

    assign scalar_active       = enable && bundle_valid_q && !scalar_done_q;
    assign load_request        = scalar_active && execute_op_q[LOAD];
    assign dma_outstanding     = dma_pending != 0;
    // A DMA waits for the previous ones unless async (scalar_dest[0], bundle bit 20).
    assign dma_req_valid       = scalar_active && execute_op_q[DMA] && !operand_zero[2] &&
                                 (scalar_dest[0] || !dma_outstanding);
    assign dma_fire            = dma_req_valid && dma_req_ready;

    assign scalar_complete_now = scalar_active && (execute_op_q[DMA] ? operand_zero[2] || dma_fire :
         execute_op_q[DMA_WAIT] ? !dma_outstanding : 1'b1);

    assign valu_valid      = enable && bundle_valid_q && !valu_done_q;
    assign vmem_valid      = enable && bundle_valid_q && !vmem_done_q;
    assign vex_valid       = enable && bundle_valid_q && !vex_done_q;
    assign vr_valid        = enable && bundle_valid_q && !vr_done_q;

    assign scalar_complete = scalar_done_q || scalar_complete_now;
    assign vex_complete    = vex_done_q || vector_ready;
    assign vr_complete     = vr_done_q || vector_ready;
    assign vector_done     = valu_done_q && vmem_done_q && vex_done_q && vr_done_q;
    assign bundle_complete = enable && bundle_valid_q && scalar_complete && (vector_done || vector_ready);
    assign branch_taken    = (execute_op_q[BRZ] && operand_zero[0]) || (execute_op_q[BRNZ] && !operand_zero[0]);
    assign refetch         = bundle_complete && (branch_taken || execute_op_q[DMA_WAIT] && imem_loaded_q);
    assign halt            = enable && halt_q && !writeback_valid_q && !commit_valid_q && !dma_outstanding;

    logic stalled;
    assign stalled = bundle_valid_q && !bundle_complete;
    assign perf_events = {
        refetch,
        stalled && scalar_complete && vr_complete && vex_complete,
        stalled && scalar_complete && vr_complete && !vex_complete,
        stalled && scalar_complete && !vr_complete,
        stalled && !scalar_complete && execute_op_q[DMA_WAIT],
        stalled && !scalar_complete,
        !stalled && !issue_fire,
        issue_fire
    };

    credit_counter #(
        .WIDTH(4)
    ) u_dma_pending (
        .clk,
        .rst   (rst || !enable),
        .add   (4'(dma_fire)),
        .sub   (4'(dma_done)),
        .count (dma_pending)
    );

    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            halt_q            <= 1'b0;
            bundle_valid_q    <= 1'b0;
            scalar_done_q     <= 1'b0;
            valu_done_q       <= 1'b0;
            vmem_done_q       <= 1'b0;
            vex_done_q        <= 1'b0;
            vr_done_q         <= 1'b0;
            imem_loaded_q     <= 1'b0;
        end else begin
            if (dma_fire && dma_req_direction == HBM_TO_IMEM) imem_loaded_q <= 1'b1;
            else if (bundle_complete && execute_op_q[DMA_WAIT]) imem_loaded_q <= 1'b0;
            if (bundle_complete && execute_op_q[HALT]) halt_q <= 1'b1;

            if (issue_fire || bundle_complete) begin
                bundle_valid_q <= issue_fire;
                scalar_done_q  <= 1'b0;
                valu_done_q    <= decoded_valu_op == VNOP && decoded_valu2_op == VNOP;
                vmem_done_q    <= decoded_vmem_op == VMEM_NOP;
                vex_done_q     <= decoded_vex_op == VEX_NOP;
                vr_done_q      <= decoded_vr_op == VR_NOP;
            end else begin
                if (scalar_complete_now)      scalar_done_q <= 1'b1;
                if (valu_valid && vector_ready) valu_done_q <= 1'b1;
                if (vmem_valid && vector_ready) vmem_done_q <= 1'b1;
                if (vex_valid && vector_ready)  vex_done_q  <= 1'b1;
                if (vr_valid && vector_ready)   vr_done_q   <= 1'b1;
            end
        end
    end
endmodule
