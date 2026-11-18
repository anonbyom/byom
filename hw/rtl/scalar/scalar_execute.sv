module scalar_execute #(
    parameter int unsigned INDEXES = 1
) (
    input logic                    clk,
    input logic                    rst,

    input logic                    flush,

    input logic                    valid,
    input isa_pkg::scalar_opcode_t op,
    input isa_pkg::scalar_reg_id_t dest,

    input logic                          read_valid,
    input isa_pkg::scalar_reg_id_t       x,
    input isa_pkg::scalar_source_t       y,
    input isa_pkg::scalar_source_t       dma_length,
    input logic [2:0]                    source_used,
    input isa_pkg::scalar_word_t         immediate,
    input isa_pkg::scalar_reg_id_t       index          [INDEXES],
    input logic                          index_used     [INDEXES],
    output isa_pkg::scalar_word_t        operand        [3],
    output logic                         operand_zero   [3],
    output isa_pkg::scalar_word_t        index_operand  [INDEXES],

    input isa_pkg::scalar_word_t         load_data,

    output logic                         result_valid_q,
    output logic                         commit_valid_q
);
    import isa_pkg::*;

    localparam int unsigned PORTS = 3 + INDEXES;

    typedef struct packed {
        scalar_word_t data;
        logic         zero;
    } operand_t;

    typedef struct packed {
        logic alu;
        logic load;
        logic saved;
    } forwarding_t;

    typedef struct packed {
        scalar_reg_id_t dest;
        scalar_word_t   data;
        logic           zero;
        logic           load;
    } result_t;

    typedef struct packed {
        scalar_reg_id_t                 dest;
        scalar_word_t                   data;
        logic                           load;
        logic [SCALAR_WORD_WIDTH/8-1:0] load_zero;
    } commit_t;

    operand_t     operand_d     [PORTS];
    operand_t     operand_q     [PORTS];
    forwarding_t  forwarding_d  [PORTS];
    forwarding_t  forwarding_q  [PORTS];
    scalar_word_t port_operand  [PORTS];
    logic         port_zero     [PORTS];
    logic [PORTS-1:0] port_used;
    result_t      result_d;
    result_t      result_q;
    commit_t      commit_d;
    commit_t      commit_q;

    scalar_word_t   register_data    [PORTS];
    scalar_reg_id_t register_addr    [PORTS];
    logic           source_immediate [PORTS];
    logic           read_forward     [PORTS];
    logic           read_load        [PORTS];
    logic           salu_write_enable;

    assign salu_write_enable = op inside {MOV, ADD, SHL};
    assign register_addr[0] = x;
    assign register_addr[1] = scalar_reg_id_t'(y);
    assign register_addr[2] = scalar_reg_id_t'(dma_length);
    assign source_immediate[0] = 1'b0;
    assign source_immediate[1] = y == SCALAR_IMM0;
    assign source_immediate[2] = dma_length == SCALAR_IMM0;
    assign port_used[2:0] = source_used;
    for (genvar i = 0; i < INDEXES; i++) begin : gen_index
        assign register_addr[3 + i]    = index[i];
        assign source_immediate[3 + i] = 1'b0;
        assign port_used[3 + i]        = index_used[i];
        assign index_operand[i]        = port_operand[3 + i];
    end

    for (genvar p = 0; p < PORTS; p++) begin : gen_operand
        assign port_operand[p] = ({SCALAR_WORD_WIDTH{forwarding_q[p].alu}} & result_q.data) |
                                 ({SCALAR_WORD_WIDTH{forwarding_q[p].load}} & commit_q.data) |
                                 ({SCALAR_WORD_WIDTH{forwarding_q[p].saved}} & operand_q[p].data);
        assign port_zero[p] = forwarding_q[p].alu ? result_q.zero :
            forwarding_q[p].load ? (&commit_q.load_zero) : operand_q[p].zero;
    end
    for (genvar p = 0; p < 3; p++) begin : gen_scalar_operand
        assign operand[p] = port_operand[p];
        assign operand_zero[p] = port_zero[p];
    end

    always_comb begin
        for (int p = 0; p < PORTS; p++) begin
            read_forward[p] = port_used[p] && valid && salu_write_enable && dest == register_addr[p];
            read_load[p] = !read_forward[p] && !source_immediate[p] &&
                result_valid_q && result_q.load && result_q.dest == register_addr[p];

            if (read_valid) begin
                forwarding_d[p].alu   = read_forward[p];
                forwarding_d[p].load  = read_load[p];
                forwarding_d[p].saved = !(read_forward[p] || read_load[p]);
            end else begin
                forwarding_d[p] = '{alu:1'b0, load:1'b0, saved:1'b1};
            end

            if (read_valid) begin
                if (source_immediate[p]) begin
                    operand_d[p].data = immediate;
                end else begin
                    operand_d[p].data = result_valid_q && !result_q.load && result_q.dest == register_addr[p] ?
                        result_q.data : commit_valid_q && commit_q.dest == register_addr[p] ?
                        commit_q.data : register_data[p];
                end
                operand_d[p].zero = operand_d[p].data == 0;
            end else if (forwarding_q[p].alu || forwarding_q[p].load) begin
                operand_d[p].data = port_operand[p];
                operand_d[p].zero = port_zero[p];
            end else begin
                operand_d[p] = operand_q[p];
            end
        end
    end

    always_comb begin
        result_d.dest = dest;
        result_d.load = op == LOAD;
        case (op)
            NOP: begin
                result_d.data = '0;
                result_d.zero = 1'b1;
            end
            MOV: begin
                result_d.data = operand[1];
                result_d.zero = operand[1] == 0;
            end
            ADD: begin
                result_d.data = operand[0] + operand[1];
                result_d.zero = (operand[0] ^ operand[1]) == ((operand[0] | operand[1]) << 1);
            end
            SHL: begin
                result_d.data = operand[0] << operand[1][$clog2(SCALAR_WORD_WIDTH)-1:0];
                result_d.zero = (operand[0] & ({SCALAR_WORD_WIDTH{1'b1}} >> operand[1][$clog2(SCALAR_WORD_WIDTH)-1:0])) == 0;
            end
            default: begin
                result_d.data = '0;
                result_d.zero = 1'b1;
            end
        endcase
    end

    always_comb begin
        commit_d.dest = result_q.dest;
        commit_d.data = result_q.load ? load_data : result_q.data;
        commit_d.load = result_q.load;
        for (int part = 0; part < SCALAR_WORD_WIDTH/8; part++) begin
            commit_d.load_zero[part] = load_data[8*part +: 8] == 0;
        end
    end

    register_file #(
        .DATA_WIDTH(SCALAR_WORD_WIDTH),
        .REGISTER_COUNT(SCALAR_REGISTER_COUNT),
        .READ_PORT_COUNT(PORTS),
        .WRITE_PORT_COUNT(1)
    ) rf (
        .clk,
        .rst(1'b0),
        .read_addr(register_addr),
        .read_data(register_data),
        .write_enable('{commit_valid_q}),
        .write_addr('{commit_q.dest}),
        .write_data('{commit_q.data})
    );

    always_ff @(posedge clk) begin
        operand_q <= operand_d;
        result_q  <= result_d;
        commit_q  <= commit_d;
        if (rst) begin
            for (int p = 0; p < PORTS; p++) begin
                forwarding_q[p] <= '{alu:1'b0, load:1'b0, saved:1'b1};
            end
            result_valid_q <= 1'b0;
            commit_valid_q    <= 1'b0;
        end else begin
            if (flush) begin
                for (int p = 0; p < PORTS; p++)
                    forwarding_q[p] <= '{alu:1'b0, load:1'b0, saved:1'b1};
                result_valid_q <= 1'b0;
                commit_valid_q <= 1'b0;
            end else begin
                forwarding_q <= forwarding_d;
                result_valid_q <= valid && (salu_write_enable || op == LOAD);
                commit_valid_q <= result_valid_q;
            end
        end
    end
endmodule
