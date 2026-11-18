module valu #(
    parameter int unsigned VREG_COUNT    = 16,
    parameter int unsigned ELEMENT_WIDTH = isa_pkg::VECTOR_ELEMENT_WIDTH,
    parameter bit FIRST_LANE             = 1'b1,
    parameter bit VALU2                  = 1'b0,

    localparam int unsigned READ_PORTS       = VALU2 ? 6 : 4,
    localparam int unsigned WRITE_PORTS      = VALU2 ? 4 : 3,
    localparam int unsigned VREG_ADDR_WIDTH  = $clog2(VREG_COUNT)
) (
    input  logic                        clk,

    input  logic                        valid,
    input  isa_pkg::valu_opcode_t       op,
    input  logic [VREG_ADDR_WIDTH-1:0]  dest,
    input  isa_pkg::valu_ctrl_t         ctrl,
    input  logic [VREG_ADDR_WIDTH-1:0]  read_addr_next [READ_PORTS],
    input  logic [ELEMENT_WIDTH-1:0]    srot_in,
    output logic [ELEMENT_WIDTH-1:0]    x_data,
    output logic [ELEMENT_WIDTH-1:0]    fp_x,
    output logic [ELEMENT_WIDTH-1:0]    fp_y,
    input  logic                        fp_valid,
    input  logic [VREG_ADDR_WIDTH-1:0]  fp_dest,
    input  logic [ELEMENT_WIDTH-1:0]    fp_data,

    output logic [ELEMENT_WIDTH-1:0]    valu2_x,
    output logic [ELEMENT_WIDTH-1:0]    valu2_y,
    input  logic                        valu2_valid,
    input  logic [VREG_ADDR_WIDTH-1:0]  valu2_dest,
    input  logic [ELEMENT_WIDTH-1:0]    valu2_data,

    input  logic                        load_valid,
    input  logic [VREG_ADDR_WIDTH-1:0]  load_dest,
    input  logic [ELEMENT_WIDTH-1:0]    load_data,

    output logic [ELEMENT_WIDTH-1:0]    store_data,
    output logic [ELEMENT_WIDTH-1:0]    vex_data,

    input  logic                        pop_valid,
    input  logic [VREG_ADDR_WIDTH-1:0]  pop_dest,
    input  logic [ELEMENT_WIDTH-1:0]    pop_data,

    input  logic                        read_rf         [4],
    input  logic                        read_alu        [4],
    input  logic                        read_load       [4],
    input  logic                        read_pop_input  [4],
    input  logic                        alu_forward_q   [4],
    input  logic                        load_forward_q  [4],

    input  logic [1:0]                  owner_in        [READ_PORTS],
    output logic [1:0]                  owner_out       [READ_PORTS]
);
    import isa_pkg::*;

    logic [ELEMENT_WIDTH-1:0]    read_data          [READ_PORTS];
    logic [ELEMENT_WIDTH-1:0]    operand            [2];
    logic [ELEMENT_WIDTH-1:0]    load_result_q;
    logic                        write_enable       [WRITE_PORTS];
    logic [VREG_ADDR_WIDTH-1:0]  write_addr         [WRITE_PORTS];
    logic [ELEMENT_WIDTH-1:0]    write_data         [WRITE_PORTS];
    logic [ELEMENT_WIDTH-1:0]    result;
    logic                        execute_valid_q;
    valu_opcode_t                execute_op_q;
    logic [VREG_ADDR_WIDTH-1:0]  execute_dest_q;

    typedef struct packed {
        logic                       valid;
        logic [VREG_ADDR_WIDTH-1:0] dest;
        logic [ELEMENT_WIDTH-1:0]   data;
    } writeback_t;
    writeback_t alu_result_q;
    writeback_t pop_input_q;
    writeback_t writeback    [WRITE_PORTS];
    assign x_data = operand[0];
    logic y_neg_q;
    assign fp_x = operand[0];
    assign fp_y = {operand[1][ELEMENT_WIDTH-1] ^ y_neg_q, operand[1][ELEMENT_WIDTH-2:0]};
    assign writeback[0].valid = alu_result_q.valid || fp_valid;
    assign writeback[0].dest = fp_valid ? fp_dest : alu_result_q.dest;
    assign writeback[0].data = fp_valid ? fp_data : alu_result_q.data;
    assign writeback[1].data = load_result_q;
    assign writeback[2] = pop_input_q;

    if (VALU2) begin : gen_valu2
        logic [ELEMENT_WIDTH-1:0] valu2_read_q [2];
        always_ff @(posedge clk)
            valu2_read_q <= '{read_data[4], (ctrl.valu2_y_imm ? ELEMENT_WIDTH'(ctrl.imm) : read_data[5]) ^
                                            {ctrl.valu2_y_neg, {(ELEMENT_WIDTH-1){1'b0}}}};
        assign valu2_x = valu2_read_q[0];
        assign valu2_y = valu2_read_q[1];
        assign writeback[3] = '{valid: valu2_valid, dest: valu2_dest, data: valu2_data};
    end else begin : gen_no_valu2
        assign valu2_x = '0;
        assign valu2_y = '0;
    end

    logic [ELEMENT_WIDTH-1:0] read_forwarded [4];
    logic [ELEMENT_WIDTH-1:0] read_q         [4];
    logic [ELEMENT_WIDTH-1:0] forwarded      [4];

    always_comb begin
        for (int r = 0; r < 4; r++) begin
            read_forwarded[r] = (read_data[r] & {ELEMENT_WIDTH{read_rf[r]}})
                | (alu_result_q.data & {ELEMENT_WIDTH{read_alu[r]}})
                | (writeback[1].data & {ELEMENT_WIDTH{read_load[r]}})
                | (pop_input_q.data & {ELEMENT_WIDTH{read_pop_input[r]}})
                | (r == 1 ? ELEMENT_WIDTH'(ctrl.imm) & {ELEMENT_WIDTH{ctrl.y_imm}} : '0);
            forwarded[r] = read_q[r]
                | (alu_result_q.data & {ELEMENT_WIDTH{alu_forward_q[r]}})
                | (writeback[1].data & {ELEMENT_WIDTH{load_forward_q[r]}});
        end
    end

    assign operand    = '{forwarded[0], forwarded[1]};
    assign store_data = forwarded[2];
    assign vex_data   = forwarded[3];

    always_ff @(posedge clk) read_q <= read_forwarded;

    valu_execute #(
        .ELEMENT_WIDTH(ELEMENT_WIDTH)
    ) u_execute (
        .op       (execute_op_q),
        .operand,
        .srot_in,
        .result
    );

    for (genvar w = 0; w < WRITE_PORTS; w++) begin : gen_writeback
        assign write_enable[w] = writeback[w].valid &&
            (w == 0 || !writeback[0].valid || writeback[w].dest != writeback[0].dest);
        assign write_addr[w] = writeback[w].dest;
        assign write_data[w] = writeback[w].data;
    end

    multiport_register_file #(
        .DATA_WIDTH(ELEMENT_WIDTH),
        .REGISTER_COUNT(VREG_COUNT),
        .READ_PORT_COUNT(READ_PORTS),
        .WRITE_PORT_COUNT(WRITE_PORTS),
        .OWNER_LOOKUP(FIRST_LANE)
    ) u_vreg (
        .clk,
        .read_addr_next,
        .read_data,
        .write_enable,
        .write_addr,
        .write_data,
        .owner_in,
        .owner_out
    );

    always_ff @(posedge clk) begin
        execute_op_q       <= op;
        y_neg_q            <= ctrl.y_neg;
        execute_dest_q     <= dest;
        load_result_q      <= load_data;
        alu_result_q.dest  <= execute_dest_q;
        alu_result_q.data  <= result;
        writeback[1].dest  <= load_dest;
        pop_input_q.dest   <= pop_dest;
        pop_input_q.data   <= pop_data;

        execute_valid_q    <= valid && valu_alu_op(op);
        alu_result_q.valid <= execute_valid_q;
        writeback[1].valid <= load_valid;
        pop_input_q.valid  <= pop_valid;
    end
endmodule : valu
