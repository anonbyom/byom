// BF16(significand * 2^exponent), round to nearest even. 4 cycles.
module scaled_int_to_bf16 #(
    parameter int unsigned N_WIDTH = 14,
    parameter int unsigned E_WIDTH = 9
) (
    input  logic                      clk,
    input  logic signed [N_WIDTH-1:0] significand,
    input  logic signed [E_WIDTH-1:0] exponent,
    input  logic                      is_zero,
    input  logic                      is_nan,
    output logic [15:0]               bf16
);
    localparam logic [15:0] BF16_NAN      = 16'h7fc0;
    localparam int unsigned LEADING_WIDTH = $clog2(N_WIDTH);
    localparam int unsigned CALC_WIDTH    = E_WIDTH + 1;
    localparam int unsigned SHIFT_WIDTH   = $clog2(N_WIDTH + 1);
    localparam logic signed [CALC_WIDTH-1:0] NORMAL_MIN = -126;
    localparam logic signed [CALC_WIDTH-1:0] FRACTION_BITS = 7;
    localparam logic signed [CALC_WIDTH-1:0] SUBNORMAL_SHIFT = 133;
    localparam logic signed [CALC_WIDTH-1:0] MAX_EXPONENT = 127;
    localparam logic signed [CALC_WIDTH-1:0] EXPONENT_BIAS = 127;
    localparam logic signed [CALC_WIDTH-1:0] MAX_RIGHT_SHIFT = CALC_WIDTH'(N_WIDTH);
    localparam logic signed [CALC_WIDTH-1:0] MAX_LEFT_SHIFT = -CALC_WIDTH'(N_WIDTH);

    typedef struct packed {
        logic [LEADING_WIDTH-1:0] leading_one;
        logic signed [E_WIDTH-1:0] exponent;
        logic [N_WIDTH-1:0] magnitude;
        logic sign;
        logic zero;
        logic nan;
    } decoded_t;

    typedef struct packed {
        logic signed [CALC_WIDTH-1:0] exponent;
        logic [N_WIDTH-1:0] magnitude;
        logic [SHIFT_WIDTH-1:0] shift_amount;
        logic sign;
        logic normal;
        logic shift_right;
        logic shift_too_large;
        logic zero;
        logic nan;
    } normalized_t;

    typedef struct packed {
        logic signed [CALC_WIDTH-1:0] exponent;
        logic [N_WIDTH:0] aligned;
        logic sign;
        logic guard_bit;
        logic sticky_bit;
        logic normal;
        logic zero;
        logic nan;
    } aligned_t;

    decoded_t    decoded_d;
    decoded_t    decoded_q;
    normalized_t normalized_d;
    normalized_t normalized_q;
    aligned_t    aligned_d;
    aligned_t    aligned_q;
    logic signed [CALC_WIDTH-1:0] shift;
    logic signed [CALC_WIDTH-1:0] rounded_exponent;
    logic [N_WIDTH:0]             rounded;
    logic                         round_increment;
    logic [15:0]                  bf16_d;

    always_comb begin
        decoded_d             = '0;
        decoded_d.sign        = significand[N_WIDTH-1];
        decoded_d.magnitude   = significand[N_WIDTH-1] ? -significand : significand;
        decoded_d.exponent    = exponent;
        decoded_d.zero        = is_zero || significand == 0;
        decoded_d.nan         = is_nan;

        for (int i = 0; i < N_WIDTH; i++) begin
            if (decoded_d.magnitude[i])
                decoded_d.leading_one = LEADING_WIDTH'(i);
        end
    end

    always_comb begin
        normalized_d           = '0;
        shift                  = '0;
        normalized_d.exponent  = CALC_WIDTH'($signed(decoded_q.exponent))
            + CALC_WIDTH'($signed({1'b0, decoded_q.leading_one}));
        normalized_d.magnitude = decoded_q.magnitude;
        normalized_d.sign      = decoded_q.sign;
        normalized_d.normal    = normalized_d.exponent >= NORMAL_MIN;
        normalized_d.zero      = decoded_q.zero;
        normalized_d.nan       = decoded_q.nan;

        if (normalized_d.normal)
            shift = CALC_WIDTH'($signed({1'b0, decoded_q.leading_one})) - FRACTION_BITS;
        else
            shift = -CALC_WIDTH'($signed(decoded_q.exponent)) - SUBNORMAL_SHIFT;

        normalized_d.shift_right = shift > 0;
        normalized_d.shift_too_large = shift > MAX_RIGHT_SHIFT || shift < MAX_LEFT_SHIFT;
        if (!normalized_d.shift_too_large) begin
            if (normalized_d.shift_right)
                normalized_d.shift_amount = SHIFT_WIDTH'($unsigned(shift));
            else
                normalized_d.shift_amount = SHIFT_WIDTH'($unsigned(-shift));
        end
    end

    always_comb begin
        aligned_d            = '0;
        aligned_d.exponent   = normalized_q.exponent;
        aligned_d.sign       = normalized_q.sign;
        aligned_d.normal     = normalized_q.normal;
        aligned_d.zero       = normalized_q.zero;
        aligned_d.nan        = normalized_q.nan;

        if (normalized_q.shift_too_large) begin
            if (normalized_q.shift_right)
                aligned_d.sticky_bit = |normalized_q.magnitude;
        end else if (normalized_q.shift_right) begin
            aligned_d.aligned = {1'b0, normalized_q.magnitude} >> normalized_q.shift_amount;
            if (normalized_q.shift_amount != 0)
                aligned_d.guard_bit = normalized_q.magnitude[normalized_q.shift_amount-1'b1];
            for (int i = 0; i < N_WIDTH; i++) begin
                if (SHIFT_WIDTH'(i + 1) < normalized_q.shift_amount)
                    aligned_d.sticky_bit |= normalized_q.magnitude[i];
            end
        end else begin
            aligned_d.aligned = {1'b0, normalized_q.magnitude} << normalized_q.shift_amount;
        end
    end

    always_comb begin
        round_increment = aligned_q.guard_bit && (aligned_q.sticky_bit || aligned_q.aligned[0]);
        rounded = aligned_q.aligned + round_increment;
        rounded_exponent = aligned_q.exponent;
        bf16_d = '0;

        if (aligned_q.nan) begin
            bf16_d = BF16_NAN;
        end else if (!aligned_q.zero) begin
            if (aligned_q.normal) begin
                if (rounded[8]) begin
                    rounded = rounded >> 1;
                    rounded_exponent = rounded_exponent + 1'b1;
                end

                if (rounded_exponent > MAX_EXPONENT)
                    bf16_d = {aligned_q.sign, 8'hff, 7'h00};
                else
                    bf16_d = {aligned_q.sign, 8'(rounded_exponent + EXPONENT_BIAS), rounded[6:0]};
            end else begin
                if (rounded[7])
                    bf16_d = {aligned_q.sign, 8'h01, 7'h00};
                else
                    bf16_d = {aligned_q.sign, 8'h00, rounded[6:0]};
            end
        end
    end

    always_ff @(posedge clk) begin
        decoded_q    <= decoded_d;
        normalized_q <= normalized_d;
        aligned_q    <= aligned_d;
        bf16         <= bf16_d;
    end
endmodule : scaled_int_to_bf16
