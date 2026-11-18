// FTZ = 1: flush-to-zero. Subnormal inputs count as zero, results whose
// rounded value is below the normal range become a signed zero, and the data stages have no reset.
module bf16_adder #(
    parameter bit FTZ = 1'b0
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        in_valid,
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic        out_valid,
    output logic [15:0] sum
);
    typedef struct packed {
        logic [7:0] exponent;
        logic [7:0] exponent_gap;
        logic [7:0] large_significand;
        logic [7:0] small_significand;
        logic       large_sign;
        logic       small_sign;
        logic       nan;
        logic       infinity;
    } ordered_t;

    typedef struct packed {
        logic [7:0]  exponent;
        logic [10:0] large_significand;
        logic [10:0] small_significand;
        logic        sign;
        logic        subtract;
        logic        nan;
        logic        infinity;
    } aligned_t;

    typedef struct packed {
        logic [7:0]  exponent;
        logic [11:0] significand;
        logic        sign;
        logic        nan;
        logic        infinity;
    } added_t;

    typedef struct packed {
        logic [8:0]  exponent;
        logic [10:0] significand;
        logic        sign;
        logic        nan;
        logic        infinity;
    } normalized_t;

    ordered_t    ordered_d;
    ordered_t    ordered_q;
    aligned_t    aligned_d;
    aligned_t    aligned_q;
    added_t      added_d;
    added_t      added_q;
    normalized_t normalized_d;
    normalized_t normalized_q;
    logic [3:0] valid_q;

    logic [7:0] a_exponent;
    logic [7:0] b_exponent;
    logic [7:0] a_significand;
    logic [7:0] b_significand;
    logic       a_is_nan;
    logic       b_is_nan;
    logic       a_is_infinity;
    logic       b_is_infinity;
    logic       opposite_infinities;
    logic       a_is_larger;
    logic [7:0] a_minus_b;
    logic [7:0] b_minus_a;

    logic [10:0] extended_small_significand;
    logic [10:0] small_significand;
    logic [3:0]  alignment_shift;
    logic        alignment_sticky;

    logic [11:0] arithmetic_result;

    logic [3:0] normalization_shift;
    logic [3:0] leading_zero_count;

    logic        round_increment;
    logic [8:0]  rounded_significand;
    logic [8:0]  rounded_exponent;

    function automatic logic [3:0] count_leading_zeros(input logic [7:0] value);
        logic found;
        begin
            count_leading_zeros = 4'd8;
            found = 1'b0;
            for (int bit_index = 7; bit_index >= 0; bit_index--) begin
                if (!found && value[bit_index]) begin
                    count_leading_zeros = 4'(7 - bit_index);
                    found = 1'b1;
                end
            end
        end
    endfunction

    always_comb begin
        a_exponent          = a[14:7] == 0 ? 8'd1 : a[14:7];
        b_exponent          = b[14:7] == 0 ? 8'd1 : b[14:7];
        a_significand       = FTZ && a[14:7] == 0 ? 8'd0 : {a[14:7] != 0, a[6:0]};
        b_significand       = FTZ && b[14:7] == 0 ? 8'd0 : {b[14:7] != 0, b[6:0]};
        a_is_nan            = a[14:7] == 8'hff && a[6:0] != 0;
        b_is_nan            = b[14:7] == 8'hff && b[6:0] != 0;
        a_is_infinity       = a[14:7] == 8'hff && a[6:0] == 0;
        b_is_infinity       = b[14:7] == 8'hff && b[6:0] == 0;
        opposite_infinities = a_is_infinity && b_is_infinity && a[15] != b[15];
        // Magnitudes of non-NaN values order like their bit patterns; with FTZ a
        // flushed subnormal still compares above zero but both add as zero.
        // Both exponent differences are formed in parallel with the compare.
        a_is_larger         = FTZ ? a[14:0] > b[14:0]
                                  : a_exponent > b_exponent || (a_exponent == b_exponent && a_significand > b_significand);
        a_minus_b           = a_exponent - b_exponent;
        b_minus_a           = b_exponent - a_exponent;

        ordered_d          = '0;
        ordered_d.nan      = a_is_nan || b_is_nan || opposite_infinities;
        ordered_d.infinity = a_is_infinity || b_is_infinity;

        if (a_is_larger) begin
            ordered_d.exponent          = a_exponent;
            ordered_d.exponent_gap      = a_minus_b;
            ordered_d.large_significand = a_significand;
            ordered_d.small_significand = b_significand;
            ordered_d.large_sign        = a[15];
            ordered_d.small_sign        = b[15];
        end else begin
            ordered_d.exponent          = b_exponent;
            ordered_d.exponent_gap      = b_minus_a;
            ordered_d.large_significand = b_significand;
            ordered_d.small_significand = a_significand;
            ordered_d.large_sign        = b[15];
            ordered_d.small_sign        = a[15];
        end
    end

    always_comb begin
        alignment_shift            = ordered_q.exponent_gap > 8'd11 ? 4'd11 : ordered_q.exponent_gap[3:0];
        extended_small_significand = {ordered_q.small_significand, 3'b000};
        small_significand          = extended_small_significand >> alignment_shift;
        alignment_sticky           = 1'b0;

        for (int unsigned bit_index = 0; bit_index < 11; bit_index++) begin
            if (bit_index < alignment_shift)
                alignment_sticky |= extended_small_significand[bit_index];
        end

        small_significand[0] |= alignment_sticky;

        aligned_d                   = '0;
        aligned_d.exponent          = ordered_q.exponent;
        aligned_d.large_significand = {ordered_q.large_significand, 3'b000};
        aligned_d.small_significand = small_significand;
        aligned_d.sign              = ordered_q.large_sign;
        aligned_d.subtract          = ordered_q.large_sign ^ ordered_q.small_sign;
        aligned_d.nan               = ordered_q.nan;
        aligned_d.infinity          = ordered_q.infinity;
    end

    always_comb begin
        if (aligned_q.subtract)
            arithmetic_result = {1'b0, aligned_q.large_significand} - {1'b0, aligned_q.small_significand};
        else
            arithmetic_result = {1'b0, aligned_q.large_significand} + {1'b0, aligned_q.small_significand};

        added_d             = '0;
        added_d.exponent    = aligned_q.exponent;
        added_d.significand = arithmetic_result;
        added_d.sign        = aligned_q.subtract && arithmetic_result == 0 ? 1'b0 : aligned_q.sign;
        added_d.nan         = aligned_q.nan;
        added_d.infinity    = aligned_q.infinity;
    end

    always_comb begin
        leading_zero_count       = count_leading_zeros(added_q.significand[10:3]);
        normalization_shift      = '0;
        normalized_d             = '0;
        normalized_d.exponent    = {1'b0, added_q.exponent};
        normalized_d.significand = added_q.significand[10:0];
        normalized_d.sign        = added_q.sign;
        normalized_d.nan         = added_q.nan;
        normalized_d.infinity    = added_q.infinity;

        if (added_q.significand == 0) begin
            normalized_d.exponent = '0;
        end else if (added_q.significand[11]) begin
            normalized_d.exponent    = {1'b0, added_q.exponent} + 1'b1;
            normalized_d.significand = added_q.significand[11:1];
            normalized_d.significand[0] |= added_q.significand[0];
        end else if (!added_q.significand[10]) begin
            if (FTZ)
                // Shift fully; an exponent that would reach 0 is flushed below.
                normalization_shift = leading_zero_count;
            else if (added_q.exponent > 8'(leading_zero_count))
                normalization_shift = leading_zero_count;
            else
                normalization_shift = added_q.exponent[3:0] - 1'b1;

            normalized_d.exponent    = {1'b0, added_q.exponent} - 9'(normalization_shift);
            normalized_d.significand = added_q.significand[10:0] << normalization_shift;
        end
    end

    always_comb begin
        round_increment     = normalized_q.significand[2] && (normalized_q.significand[3] || normalized_q.significand[1:0] != 0);
        rounded_significand = {1'b0, normalized_q.significand[10:3]} + round_increment;
        rounded_exponent    = normalized_q.exponent + rounded_significand[8];

        if (normalized_q.nan)
            sum = 16'h7fc0;
        else if (FTZ && !normalized_q.infinity && (normalized_q.significand == 0 || $signed(rounded_exponent) <= 0))
            // Flushed after rounding, like bf16_mul_ftz.
            sum = {normalized_q.sign, 15'h0000};
        else if (normalized_q.infinity)
            sum = {normalized_q.sign, 8'hff, 7'h00};
        else if (normalized_q.significand == 0)
            sum = {normalized_q.sign, 15'h0000};
        else if (rounded_exponent >= 9'd255)
            sum = {normalized_q.sign, 8'hff, 7'h00};
        else if (rounded_significand[8:7] != 0)
            sum = {normalized_q.sign, rounded_exponent[7:0], rounded_significand[6:0]};
        else
            sum = {normalized_q.sign, 8'h00, rounded_significand[6:0]};
    end

    if (FTZ) begin : gen_data_no_reset
        always_ff @(posedge clk) begin
            ordered_q    <= ordered_d;
            aligned_q    <= aligned_d;
            added_q      <= added_d;
            normalized_q <= normalized_d;
            if (rst) valid_q <= '0;
            else valid_q <= {valid_q[2:0], in_valid};
        end
    end else begin : gen_data_reset
        always_ff @(posedge clk) begin
            if (rst) begin
                ordered_q    <= '0;
                aligned_q    <= '0;
                added_q      <= '0;
                normalized_q <= '0;
                valid_q      <= '0;
            end else begin
                ordered_q    <= ordered_d;
                aligned_q    <= aligned_d;
                added_q      <= added_d;
                normalized_q <= normalized_d;
                valid_q      <= {valid_q[2:0], in_valid};
            end
        end
    end

    assign out_valid = valid_q[3];
endmodule : bf16_adder
