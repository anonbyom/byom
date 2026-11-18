// One lane's EUP: WIDTH BF16 function pipelines (eup_functions) shared by the four sublanes.
module lane_eup #(
    parameter int unsigned SUBLANES      = 4,
    parameter int unsigned ELEMENT_WIDTH = isa_pkg::VECTOR_ELEMENT_WIDTH,
    parameter int unsigned WIDTH         = 1,

    localparam int unsigned BEATS        = SUBLANES / WIDTH,
    localparam int unsigned BEAT_W       = BEATS > 1 ? $clog2(BEATS) : 1,
    localparam int unsigned FUNC_W       = $bits(isa_pkg::eup_function_t)
) (
    input  logic                     clk,
    input  logic                     fire,
    input  logic [FUNC_W-1:0]        func,
    input  logic [ELEMENT_WIDTH-1:0] x               [SUBLANES],
    output logic                     operand_valid,
    output logic [1:0]               operand_unit,     // 0 log2, 1 pow2, 2 reciprocal/rsqrt, 3 tanh/sigmoid
    output logic                     operand_variant,  // func[0]: rsqrt / shifted sigmoid
    output logic [BEAT_W-1:0]        operand_beat,
    output logic [ELEMENT_WIDTH-1:0] operand         [WIDTH],
    input  logic                     function_valid,
    input  logic [BEAT_W-1:0]        function_beat,
    input  logic [ELEMENT_WIDTH-1:0] function_result [WIDTH],
    output logic                     result_valid    [SUBLANES],
    output logic [ELEMENT_WIDTH-1:0] result_data     [SUBLANES]
);
    import isa_pkg::*;

    logic                     active_q;
    logic [BEAT_W-1:0]        beat_q;
    logic [FUNC_W-1:0]        func_q;
    logic [ELEMENT_WIDTH-1:0] x_q [SUBLANES];
    // Function unit of the command.
    logic [1:0]               unit_q;

    always_ff @(posedge clk) begin
        if (fire) begin
            active_q <= 1'b1;
            beat_q   <= '0;
        end else if (active_q) begin
            if (BEATS == 1 || beat_q == BEAT_W'(BEATS - 1)) active_q <= 1'b0;
            beat_q <= beat_q + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (fire) begin
            x_q    <= x;
            func_q <= func;
            unit_q <= func[2] ? 2'd3 : func[1] ? 2'd2 : {1'b0, func[0]};
        end
    end

    always_ff @(posedge clk) begin
        operand_valid <= active_q;
    end

    always_ff @(posedge clk) begin
        for (int p = 0; p < WIDTH; p++)
            operand[p] <= x_q[BEATS == 1 ? p : int'(beat_q) * WIDTH + p];
        operand_variant <= func_q[0];
        operand_unit    <= unit_q;
        operand_beat    <= beat_q;
    end

    for (genvar b = 0; b < BEATS; b++) begin : gen_result
        for (genvar p = 0; p < WIDTH; p++) begin : gen_pipe
            assign result_valid[b * WIDTH + p] = function_valid && (BEATS == 1 || int'(function_beat) == b);
            assign result_data[b * WIDTH + p]  = function_result[p];
        end
    end

    initial begin
        if (SUBLANES != 4) $fatal(1, "lane_eup assumes four sublanes");
        if (!(WIDTH inside {1, 2, 4})) $fatal(1, "lane_eup WIDTH must be 1, 2 or 4");
    end
endmodule : lane_eup
