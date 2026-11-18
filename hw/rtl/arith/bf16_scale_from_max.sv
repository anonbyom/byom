// E8M0 scale for a block whose max |value| is maximum: floor(log2(max)) - 2, saturated; NaN/Inf -> 0xff. Latency 2.
module bf16_scale_from_max (
    input  logic        clk,
    input  logic        rst,
    input  logic        in_valid,
    input  logic [15:0] maximum,
    output logic        out_valid,
    output logic [7:0]  scale
);
    typedef struct packed {
        logic signed [9:0] exponent;
        logic              zero;
        logic              invalid;
    } normalized_t;

    normalized_t normalized_d;
    normalized_t normalized_q;
    logic [2:0] leading_one;
    logic signed [10:0] scale_exponent;
    logic signed [10:0] biased_exponent;
    logic [7:0] scale_d;
    logic [1:0] valid_q;

    function automatic logic [2:0] leading_one_fraction(input logic [6:0] value);
        logic found;
        begin
            leading_one_fraction = '0;
            found = 1'b0;
            for (int bit_index = 6; bit_index >= 0; bit_index--) begin
                if (!found && value[bit_index]) begin
                    leading_one_fraction = 3'(bit_index);
                    found = 1'b1;
                end
            end
        end
    endfunction

    always_comb begin
        leading_one = leading_one_fraction(maximum[6:0]);
        normalized_d         = '0;
        normalized_d.zero    = maximum == '0;
        normalized_d.invalid = maximum[14:7] == 8'hff;
        if (maximum[14:7] == '0)
            normalized_d.exponent = $signed({7'b0000000, leading_one}) - 10'sd133;
        else
            normalized_d.exponent = $signed({2'b00, maximum[14:7]}) - 10'sd127;
    end

    always_comb begin
        scale_exponent  = $signed({normalized_q.exponent[9], normalized_q.exponent}) - 11'sd2;
        biased_exponent = scale_exponent + 11'sd127;
        scale_d         = '0;
        if (normalized_q.invalid)
            scale_d = 8'hff;
        else if (normalized_q.zero || biased_exponent < 0)
            scale_d = 8'h00;
        else if (biased_exponent > 11'sd254)
            scale_d = 8'hfe;
        else
            scale_d = biased_exponent[7:0];
    end

    always_ff @(posedge clk) begin
        if (rst) valid_q <= '0;
        else valid_q <= {valid_q[0], in_valid};
    end

    always_ff @(posedge clk) begin
        normalized_q <= normalized_d;
        scale        <= scale_d;
    end

    assign out_valid = valid_q[1];
endmodule : bf16_scale_from_max
