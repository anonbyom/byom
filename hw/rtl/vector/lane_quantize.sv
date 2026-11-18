// One lane's MXFP4 quantizer: VQUANT_START, six VQUANT_CONTINUEs and VQUANT_END push a 32-element block (8 VREGs).
module lane_quantize #(
    parameter int unsigned SUBLANES      = 4,
    parameter int unsigned ELEMENT_WIDTH = isa_pkg::VECTOR_ELEMENT_WIDTH,

    localparam int unsigned WORD_WIDTH   = SUBLANES * ELEMENT_WIDTH
) (
    input  logic                     clk,
    input  logic                     fire,
    input  logic                     start,
    input  logic                     last,
    input  isa_pkg::scale_reg_id_t   sreg,
    input  logic [ELEMENT_WIDTH-1:0] x [SUBLANES],
    output logic                     scale_valid,
    output isa_pkg::scale_reg_id_t   scale_reg,
    output logic [7:0]               scale,
    output logic                     word_valid,
    output logic [WORD_WIDTH-1:0]    word
);
    logic [WORD_WIDTH-1:0]  pushed;
    logic [WORD_WIDTH-1:0]  row;
    logic [7:0]             exponent_q [SUBLANES];
    logic [7:0]             pair_q     [2];
    logic [7:0]             row_max_q;
    logic [7:0]             block_max_q;
    logic [7:0]             block_scale;
    logic [2:0]             push_q;
    logic [2:0]             start_q;
    logic [3:0]             last_q;
    isa_pkg::scale_reg_id_t sreg_q;
    logic                   convert_q;
    logic [2:0]             convert_count_q;
    logic [3:0]             code [SUBLANES];
    logic [SUBLANES-1:0]    converted;
    logic                   code_valid;
    logic [1:0]             code_count_q;

    for (genvar s = 0; s < SUBLANES; s++) begin : gen_pushed
        assign pushed[s * ELEMENT_WIDTH +: ELEMENT_WIDTH] = x[s];
    end

    fifo #(
        .DATA_WIDTH(WORD_WIDTH),
        .DEPTH(16)
    ) u_rows (
        .clk,
        .rst     (1'b0),
        .w_en    (fire),
        .w_data  (pushed),
        .w_rdy   (),
        .r_en    (convert_q),
        .r_data  (row),
        .r_valid (),
        .level   ()
    );

    bf16_max_to_e8m0 u_scale (
        .exponent (block_max_q),
        .scale    (block_scale)
    );

    always_ff @(posedge clk) begin
        for (int s = 0; s < SUBLANES; s++) exponent_q[s] <= x[s][14:7];
        pair_q[0] <= exponent_q[0] > exponent_q[1] ? exponent_q[0] : exponent_q[1];
        pair_q[1] <= exponent_q[2] > exponent_q[3] ? exponent_q[2] : exponent_q[3];
        row_max_q <= pair_q[0] > pair_q[1] ? pair_q[0] : pair_q[1];
        if (push_q[2]) block_max_q <= start_q[2] || row_max_q > block_max_q ? row_max_q : block_max_q;
        if (fire && last) sreg_q <= sreg;
        if (last_q[3]) begin
            scale           <= block_scale;
            scale_reg       <= sreg_q;
            convert_count_q <= '0;
        end else if (convert_q) begin
            convert_count_q <= convert_count_q + 1'b1;
        end
        if (code_valid)
            for (int s = 0; s < SUBLANES; s++)
                word[int'(code_count_q) * ELEMENT_WIDTH + 4 * (SUBLANES - 1 - s) +: 4] <= code[s];
        push_q       <= {push_q[1:0], fire};
        start_q      <= {start_q[1:0], fire && start};
        last_q       <= {last_q[2:0], fire && last};
        scale_valid  <= last_q[3];
        if (last_q[3]) convert_q <= 1'b1;
        else if (convert_count_q == 3'd7) convert_q <= 1'b0;
        if (code_valid) code_count_q <= code_count_q + 1'b1;
        word_valid   <= code_valid && code_count_q == 2'd3;
    end

    for (genvar s = 0; s < SUBLANES; s++) begin : gen_convert
        bf16_to_mxfp4 u_convert (
            .clk,
            .rst(1'b0),
            .in_valid (convert_q),
            .bf16     (row[s * ELEMENT_WIDTH +: ELEMENT_WIDTH]),
            .scale,
            .out_valid(converted[s]),
            .mxfp4    (code[s])
        );
    end
    assign code_valid = &converted;
endmodule : lane_quantize
