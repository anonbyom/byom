// binary32 adder, round to nearest even, NaN = 0x7fc00000. Latency 4.
module fp32_add (
    input  logic        clk,
    input  logic        rst,

    input  logic        in_valid,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic        out_valid,
    output logic [31:0] sum
);
    localparam int unsigned SIG_WIDTH = 24;
    localparam int unsigned EXT_WIDTH = SIG_WIDTH + 3;

    typedef struct packed {
        logic [7:0]            exponent;
        logic [7:0]            exponent_gap;
        logic [SIG_WIDTH-1:0]  large_significand;
        logic [SIG_WIDTH-1:0]  small_significand;
        logic                  large_sign;
        logic                  small_sign;
        logic                  nan;
        logic                  infinity;
    } ordered_t;

    typedef struct packed {
        logic [7:0]            exponent;
        logic [EXT_WIDTH-1:0]  large_significand;
        logic [EXT_WIDTH-1:0]  small_significand;
        logic                  sign;
        logic                  subtract;
        logic                  nan;
        logic                  infinity;
    } aligned_t;

    typedef struct packed {
        logic [7:0]            exponent;
        logic [EXT_WIDTH:0]    significand;
        logic [4:0]            leading_zero_count;
        logic                  sign;
        logic                  nan;
        logic                  infinity;
    } added_t;

    typedef struct packed {
        logic [8:0]            exponent;
        logic [EXT_WIDTH-1:0]  significand;
        logic                  sign;
        logic                  nan;
        logic                  infinity;
    } normalized_t;

    ordered_t    ordered_d;
    ordered_t    ordered_q;
    aligned_t    aligned_d;
    aligned_t    aligned_q;
    added_t      added_d;
    added_t      added_q;
    normalized_t normalized_d;
    normalized_t normalized_q;
    logic [3:0]  valid_q;

    logic [7:0]           a_exponent;
    logic [7:0]           b_exponent;
    logic [SIG_WIDTH-1:0] a_significand;
    logic [SIG_WIDTH-1:0] b_significand;
    logic                 a_is_nan;
    logic                 b_is_nan;
    logic                 a_is_infinity;
    logic                 b_is_infinity;
    logic                 opposite_infinities;
    logic                 a_is_larger;

    logic [EXT_WIDTH-1:0] extended_small_significand;
    logic [EXT_WIDTH-1:0] small_significand;
    logic [4:0]           alignment_shift;
    logic                 alignment_sticky;

    logic [EXT_WIDTH:0]   arithmetic_result;

    logic [4:0]           normalization_shift;

    logic                 round_increment;
    logic [SIG_WIDTH:0]   rounded_significand;
    logic [8:0]           rounded_exponent;

    function automatic logic [4:0] count_leading_zeros(input logic [SIG_WIDTH-1:0] value);
        logic found;
        begin
            count_leading_zeros = 5'(SIG_WIDTH);
            found = 1'b0;
            for (int bit_index = SIG_WIDTH - 1; bit_index >= 0; bit_index--) begin
                if (!found && value[bit_index]) begin
                    count_leading_zeros = 5'(SIG_WIDTH - 1 - bit_index);
                    found = 1'b1;
                end
            end
        end
    endfunction

    always_comb begin
        a_exponent          = a[30:23] == 0 ? 8'd1 : a[30:23];
        b_exponent          = b[30:23] == 0 ? 8'd1 : b[30:23];
        a_significand       = {a[30:23] != 0, a[22:0]};
        b_significand       = {b[30:23] != 0, b[22:0]};
        a_is_nan            = a[30:23] == 8'hff && a[22:0] != 0;
        b_is_nan            = b[30:23] == 8'hff && b[22:0] != 0;
        a_is_infinity       = a[30:23] == 8'hff && a[22:0] == 0;
        b_is_infinity       = b[30:23] == 8'hff && b[22:0] == 0;
        opposite_infinities = a_is_infinity && b_is_infinity && a[31] != b[31];
        // Magnitudes of non-NaN binary32 values order like their bit patterns.
        a_is_larger         = a[30:0] > b[30:0];

        ordered_d          = '0;
        ordered_d.nan      = a_is_nan || b_is_nan || opposite_infinities;
        ordered_d.infinity = a_is_infinity || b_is_infinity;

        if (a_is_larger) begin
            ordered_d.exponent          = a_exponent;
            ordered_d.exponent_gap      = a_exponent - b_exponent;
            ordered_d.large_significand = a_significand;
            ordered_d.small_significand = b_significand;
            ordered_d.large_sign        = a[31];
            ordered_d.small_sign        = b[31];
        end else begin
            ordered_d.exponent          = b_exponent;
            ordered_d.exponent_gap      = b_exponent - a_exponent;
            ordered_d.large_significand = b_significand;
            ordered_d.small_significand = a_significand;
            ordered_d.large_sign        = b[31];
            ordered_d.small_sign        = a[31];
        end
    end

    always_comb begin
        alignment_shift            = ordered_q.exponent_gap > 8'(EXT_WIDTH) ? 5'(EXT_WIDTH) : ordered_q.exponent_gap[4:0];
        extended_small_significand = {ordered_q.small_significand, 3'b000};
        small_significand          = extended_small_significand >> alignment_shift;
        alignment_sticky           = 1'b0;

        for (int unsigned bit_index = 0; bit_index < EXT_WIDTH; bit_index++) begin
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

        added_d                    = '0;
        added_d.exponent           = aligned_q.exponent;
        added_d.significand        = arithmetic_result;
        added_d.leading_zero_count = count_leading_zeros(arithmetic_result[EXT_WIDTH-1:3]);
        added_d.sign               = aligned_q.subtract && arithmetic_result == 0 ? 1'b0 : aligned_q.sign;
        added_d.nan                = aligned_q.nan;
        added_d.infinity           = aligned_q.infinity;
    end

    always_comb begin
        normalization_shift      = '0;
        normalized_d             = '0;
        normalized_d.exponent    = {1'b0, added_q.exponent};
        normalized_d.significand = added_q.significand[EXT_WIDTH-1:0];
        normalized_d.sign        = added_q.sign;
        normalized_d.nan         = added_q.nan;
        normalized_d.infinity    = added_q.infinity;

        if (added_q.significand == 0) begin
            normalized_d.exponent = '0;
        end else if (added_q.significand[EXT_WIDTH]) begin
            normalized_d.exponent    = {1'b0, added_q.exponent} + 1'b1;
            normalized_d.significand = added_q.significand[EXT_WIDTH:1];
            normalized_d.significand[0] |= added_q.significand[0];
        end else if (!added_q.significand[EXT_WIDTH-1]) begin
            // Stop at exponent 1 (subnormal result) when the full shift would go below it.
            if (added_q.exponent > 8'(added_q.leading_zero_count))
                normalization_shift = added_q.leading_zero_count;
            else
                normalization_shift = added_q.exponent[4:0] - 1'b1;

            normalized_d.exponent    = {1'b0, added_q.exponent} - 9'(normalization_shift);
            normalized_d.significand = added_q.significand[EXT_WIDTH-1:0] << normalization_shift;
        end
    end

    always_comb begin
        round_increment     = normalized_q.significand[2] && (normalized_q.significand[3] || normalized_q.significand[1:0] != 0);
        rounded_significand = {1'b0, normalized_q.significand[EXT_WIDTH-1:3]} + round_increment;
        rounded_exponent    = normalized_q.exponent + rounded_significand[SIG_WIDTH];

        if (normalized_q.nan)
            sum = 32'h7fc00000;
        else if (normalized_q.infinity)
            sum = {normalized_q.sign, 8'hff, 23'h0};
        else if (normalized_q.significand == 0)
            sum = {normalized_q.sign, 31'h0};
        else if (rounded_exponent >= 9'd255)
            sum = {normalized_q.sign, 8'hff, 23'h0};
        else if (rounded_significand[SIG_WIDTH:SIG_WIDTH-1] != 0)
            sum = {normalized_q.sign, rounded_exponent[7:0], rounded_significand[22:0]};
        else
            sum = {normalized_q.sign, 8'h00, rounded_significand[22:0]};
    end

    always_ff @(posedge clk) begin
        ordered_q    <= ordered_d;
        aligned_q    <= aligned_d;
        added_q      <= added_d;
        normalized_q <= normalized_d;
        if (rst) valid_q <= '0;
        else valid_q <= {valid_q[2:0], in_valid};
    end

    assign out_valid = valid_q[3];
endmodule : fp32_add
