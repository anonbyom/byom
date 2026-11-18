// Forwarding control for one lane's VALUs
module valu_forwarding #(
    parameter int unsigned VREG_COUNT        = 16,
    parameter int unsigned LOAD_STAGES       = 4,   // cycles from a VLD's issue to its VRF write
    parameter int unsigned SUBLANES          = 4,
    parameter bit FIRST_LANE                 = 1'b1,

    localparam int unsigned VREG_ADDR_WIDTH  = $clog2(VREG_COUNT)
) (
    input  logic                        clk,

    input  logic                        alu_issue,
    input  logic [VREG_ADDR_WIDTH-1:0]  dest,

    input  logic                        load_issue,
    input  logic [VREG_ADDR_WIDTH-1:0]  load_issue_dest,

    input  logic                        pop_valid,
    input  logic [VREG_ADDR_WIDTH-1:0]  pop_dest,

    input  logic [VREG_ADDR_WIDTH-1:0]  read_addr_next  [4],
    input  logic                        read_none_next  [4],

    output logic                        read_rf         [SUBLANES][4],
    output logic                        read_alu        [SUBLANES][4],
    output logic                        read_load       [SUBLANES][4],
    output logic                        read_pop_input  [SUBLANES][4],
    output logic                        alu_forward_q   [SUBLANES][4],
    output logic                        load_forward_q  [SUBLANES][4],

    // {rf, alu, load, pop_input, alu_exec, load_result}
    input  logic [5:0]                  selects_in      [SUBLANES][4],
    output logic [5:0]                  selects_out     [SUBLANES][4]
);
    typedef enum logic [3:0] {
        RF, ALU_EXEC, ALU_RESULT, LOAD_RESULT, LOAD_WRITE, POP_INPUT, LOAD_PENDING, LOAD_WAIT, LOAD_WAIT2
    } producer_t;

    localparam int unsigned ALU_STAGES  = 2;

    typedef struct packed {
        logic                       valid;
        logic [VREG_ADDR_WIDTH-1:0] dest;
    } stage_t;
    stage_t alu_q  [ALU_STAGES];
    stage_t load_q [LOAD_STAGES];

    producer_t producer_d [4];      // next state of register read_addr_next[r]

    function automatic producer_t load_stage(input int unsigned s);
        if (s == LOAD_STAGES - 1) return LOAD_WRITE;
        if (s == LOAD_STAGES - 2) return LOAD_RESULT;
        return LOAD_STAGES > 4 && s == 1 ? LOAD_WAIT2 : LOAD_WAIT;
    endfunction

    function automatic logic issued(input logic [VREG_ADDR_WIDTH-1:0] register);
        return pop_valid && pop_dest == register || load_issue && load_issue_dest == register ||
               alu_issue && dest == register;
    endfunction

    always_ff @(posedge clk) begin
        alu_q[0].dest  <= dest;
        load_q[0].dest <= load_issue_dest;

        for (int s = 1; s < ALU_STAGES; s++)
            alu_q[s].dest <= alu_q[s-1].dest;
        for (int s = 1; s < LOAD_STAGES; s++)
            load_q[s].dest <= load_q[s-1].dest;

        load_q[0].valid <= load_issue && !(pop_valid && pop_dest == load_issue_dest);
        alu_q[0].valid  <= alu_issue && !(pop_valid && pop_dest == dest) && !(load_issue && load_issue_dest == dest);

        for (int s = 1; s < ALU_STAGES; s++)
            alu_q[s].valid <= alu_q[s-1].valid && !issued(alu_q[s-1].dest);
        for (int s = 1; s < LOAD_STAGES; s++)
            load_q[s].valid <= load_q[s-1].valid && !issued(load_q[s-1].dest);
    end

    always_comb begin
        for (int r = 0; r < 4; r++) begin
            producer_d[r] = RF;
            if (pop_valid && pop_dest == read_addr_next[r]) begin
                producer_d[r] = POP_INPUT;
            end else if (load_issue && load_issue_dest == read_addr_next[r]) begin
                producer_d[r] = LOAD_PENDING;
            end else if (alu_issue && dest == read_addr_next[r]) begin
                producer_d[r] = ALU_EXEC;
            end else begin
                for (int s = 0; s + 1 < ALU_STAGES; s++)
                    if (alu_q[s].valid && alu_q[s].dest == read_addr_next[r]) producer_d[r] = ALU_RESULT;
                for (int s = 0; s + 1 < LOAD_STAGES; s++)
                    if (load_q[s].valid && load_q[s].dest == read_addr_next[r]) producer_d[r] = load_stage(s + 1);
            end
        end
    end

    for (genvar c = 0; c < SUBLANES; c++) begin : gen_sublane
        // dont_touch: each sublane keeps its own copy (not merged by synthesis).
        (* dont_touch = "true" *) logic sel_rf_q        [4];
        (* dont_touch = "true" *) logic sel_alu_q       [4];
        (* dont_touch = "true" *) logic sel_load_q      [4];
        (* dont_touch = "true" *) logic sel_pop_input_q [4];
        (* dont_touch = "true" *) logic alu_exec_q      [4];
        (* dont_touch = "true" *) logic load_result_q   [4];
        logic [5:0] select_d  [4];

        always_comb begin
            for (int r = 0; r < 4; r++)
                select_d[r] = read_none_next[r] ? 6'b0 : !FIRST_LANE ? selects_in[c][r] :
                    {producer_d[r] inside {RF, LOAD_PENDING, LOAD_WAIT, LOAD_WAIT2}, producer_d[r] == ALU_RESULT,
                     producer_d[r] == LOAD_WRITE, producer_d[r] == POP_INPUT, producer_d[r] == ALU_EXEC,
                     producer_d[r] == LOAD_RESULT};
        end

        always_ff @(posedge clk) begin
            for (int r = 0; r < 4; r++) begin
                sel_rf_q[r]         <= select_d[r][5];
                sel_alu_q[r]        <= select_d[r][4];
                sel_load_q[r]       <= select_d[r][3];
                sel_pop_input_q[r]  <= select_d[r][2];
                alu_exec_q[r]       <= select_d[r][1];
                load_result_q[r]    <= select_d[r][0];
                alu_forward_q[c][r]  <= alu_exec_q[r];
                load_forward_q[c][r] <= load_result_q[r];
            end
        end

        assign read_rf[c]         = sel_rf_q;
        assign read_alu[c]        = sel_alu_q;
        assign read_load[c]       = sel_load_q;
        assign read_pop_input[c]  = sel_pop_input_q;
        for (genvar r = 0; r < 4; r++) begin : gen_out
            assign selects_out[c][r] = {sel_rf_q[r], sel_alu_q[r], sel_load_q[r], sel_pop_input_q[r],
                                        alu_exec_q[r], load_result_q[r]};
        end
    end
endmodule : valu_forwarding
