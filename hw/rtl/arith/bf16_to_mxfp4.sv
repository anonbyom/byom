module bf16_to_mxfp4 (
    input  logic        clk,
    input  logic        rst,

    input  logic        in_valid,
    input  logic [15:0] bf16,
    input  logic [7:0]  scale,
    output logic        out_valid,
    output logic [3:0]  mxfp4
);
    typedef struct packed {
        logic [7:0] exponent;
        logic [6:0] fraction;
        logic [7:0] scale;
        logic [2:0] leading_one;
        logic       sign;
        logic       zero;
        logic       infinity;
        logic       nan;
    } decoded_t;

    typedef struct packed {
        logic signed [9:0] exponent;
        logic        [7:0] significand;
        logic        [7:0] scale;
        logic              sign;
        logic              zero;
        logic              infinity;
        logic              nan;
    } normalized_t;

    typedef struct packed {
        logic signed [9:0] exponent;
        logic        [7:0] significand;
        logic              sign;
        logic              zero;
        logic              infinity;
        logic              nan;
    } scaled_t;

    decoded_t    decoded_d;
    decoded_t    decoded_q;
    normalized_t normalized_d;
    normalized_t normalized_q;
    scaled_t     scaled_d;
    scaled_t     scaled_q;
    logic [3:0]  mxfp4_d;
    logic [3:0]  valid_q;
    logic [2:0]  magnitude;

    function automatic logic [2:0] leading_one(input logic [6:0] value);
        logic found;
        begin
            leading_one = '0;
            found = 1'b0;
            for (int bit_index = 6; bit_index >= 0; bit_index--) begin
                if (!found && value[bit_index]) begin
                    leading_one = 3'(bit_index);
                    found = 1'b1;
                end
            end
        end
    endfunction

    always_comb begin
        decoded_d             = '0;
        decoded_d.exponent    = bf16[14:7];
        decoded_d.fraction    = bf16[6:0];
        decoded_d.scale       = scale;
        decoded_d.leading_one = leading_one(bf16[6:0]);
        decoded_d.sign        = bf16[15];
        decoded_d.zero        = bf16[14:0] == '0;
        decoded_d.infinity    = bf16[14:7] == 8'hff && bf16[6:0] == '0;
        decoded_d.nan         = scale == 8'hff
                              || (bf16[14:7] == 8'hff && bf16[6:0] != '0);
    end

    always_comb begin
        normalized_d          = '0;
        normalized_d.scale    = decoded_q.scale;
        normalized_d.sign     = decoded_q.sign;
        normalized_d.zero     = decoded_q.zero;
        normalized_d.infinity = decoded_q.infinity;
        normalized_d.nan      = decoded_q.nan;

        if (decoded_q.exponent == '0) begin
            normalized_d.exponent    = $signed({7'b0000000, decoded_q.leading_one}) - 10'sd133;
            normalized_d.significand = {1'b0, decoded_q.fraction} << (7 - decoded_q.leading_one);
        end else begin
            normalized_d.exponent    = $signed({2'b00, decoded_q.exponent}) - 10'sd127;
            normalized_d.significand = {1'b1, decoded_q.fraction};
        end
    end

    always_comb begin
        scaled_d             = '0;
        scaled_d.exponent    = normalized_q.exponent
                             - $signed({2'b00, normalized_q.scale})
                             + 10'sd127;
        scaled_d.significand = normalized_q.significand;
        scaled_d.sign        = normalized_q.sign;
        scaled_d.zero        = normalized_q.zero;
        scaled_d.infinity    = normalized_q.infinity;
        scaled_d.nan         = normalized_q.nan;
    end

    always_comb begin
        magnitude = 3'b000;

        if (scaled_q.exponent < -10'sd2) begin
            magnitude = 3'b000;
        end else begin
            unique case (scaled_q.exponent)
                -10'sd2: magnitude = scaled_q.significand > 8'd128 ? 3'b001 : 3'b000;
                -10'sd1: magnitude = scaled_q.significand >= 8'd192 ? 3'b010 : 3'b001;
                 10'sd0: magnitude = scaled_q.significand >= 8'd224 ? 3'b100
                                        : scaled_q.significand > 8'd160 ? 3'b011 : 3'b010;
                 10'sd1: magnitude = scaled_q.significand >= 8'd224 ? 3'b110
                                        : scaled_q.significand > 8'd160 ? 3'b101 : 3'b100;
                 10'sd2: magnitude = scaled_q.significand > 8'd160 ? 3'b111 : 3'b110;
                default: magnitude = 3'b111;
            endcase
        end

        if (scaled_q.nan)
            mxfp4_d = 4'b0000;
        else if (scaled_q.infinity)
            mxfp4_d = {scaled_q.sign, 3'b111};
        else if (scaled_q.zero)
            mxfp4_d = {scaled_q.sign, 3'b000};
        else
            mxfp4_d = {scaled_q.sign, magnitude};
    end

    always_ff @(posedge clk) begin
        if (rst) valid_q <= '0;
        else valid_q <= {valid_q[2:0], in_valid};
    end

    always_ff @(posedge clk) begin
        decoded_q    <= decoded_d;
        normalized_q <= normalized_d;
        scaled_q     <= scaled_d;
        mxfp4        <= mxfp4_d;
    end

    assign out_valid = valid_q[3];
endmodule : bf16_to_mxfp4
