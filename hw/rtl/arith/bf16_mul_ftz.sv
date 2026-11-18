// BF16 multiply, round-to-nearest-even, flush-to-zero: subnormal inputs count
// as zero and results below the normal range become a signed zero. The 8 x 8
// significand product runs in a DSP48E2 (A/B, M and P registers). Latency 4.
module bf16_mul_ftz (
    input  logic        clk,
    input  logic        rst,
    input  logic        in_valid,
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic        out_valid,
    output logic [15:0] product
);
    typedef struct packed {
        logic              sign;
        logic signed [9:0] exponent;   // ea + eb - 127, before normalization
        logic              zero;
        logic              infinity;
        logic              nan;
    } side_t;

    logic [3:0]  valid_q;
    logic [7:0]  a_sig_q, b_sig_q;
    (* use_dsp = "yes" *) logic [15:0] m_q;
    logic [15:0] p_q;
    side_t       side_d;
    side_t       side_q [3];

    logic        a_zero, b_zero, a_inf, b_inf, a_nan, b_nan;
    logic        high;
    logic [6:0]  mantissa;
    logic        guard, sticky, round_up;
    logic [7:0]  rounded;          // {carry, mantissa}
    logic signed [9:0] exponent;
    logic [15:0] result;

    always_comb begin
        a_zero = a[14:7] == 0;
        b_zero = b[14:7] == 0;
        a_inf  = a[14:7] == 8'hff && a[6:0] == 0;
        b_inf  = b[14:7] == 8'hff && b[6:0] == 0;
        a_nan  = a[14:7] == 8'hff && a[6:0] != 0;
        b_nan  = b[14:7] == 8'hff && b[6:0] != 0;
        side_d.sign     = a[15] ^ b[15];
        side_d.exponent = 10'($signed({2'b00, a[14:7]})) + 10'($signed({2'b00, b[14:7]})) - 10'sd127;
        side_d.nan      = a_nan || b_nan || (a_inf && b_zero) || (b_inf && a_zero);
        side_d.infinity = a_inf || b_inf;
        side_d.zero     = a_zero || b_zero;
    end

    always_ff @(posedge clk) begin
        a_sig_q   <= {1'b1, a[6:0]};
        b_sig_q   <= {1'b1, b[6:0]};
        m_q       <= a_sig_q * b_sig_q;
        p_q       <= m_q;
        side_q[0] <= side_d;
        side_q[1] <= side_q[0];
        side_q[2] <= side_q[1];
    end

    // p_q is in [2^14, 2^16): 1.xx or 1x.x with 14 fraction bits.
    always_comb begin
        high     = p_q[15];
        mantissa = high ? p_q[14:8] : p_q[13:7];
        guard    = high ? p_q[7] : p_q[6];
        sticky   = high ? |p_q[6:0] : |p_q[5:0];
        round_up = guard && (sticky || mantissa[0]);
        rounded  = {1'b0, mantissa} + 8'(round_up);
        exponent = side_q[2].exponent + 10'(high) + 10'(rounded[7]);

        if (side_q[2].nan)
            result = 16'h7fc0;
        else if (side_q[2].infinity)
            result = {side_q[2].sign, 8'hff, 7'h00};
        else if (side_q[2].zero || exponent <= 0)
            result = {side_q[2].sign, 15'h0000};
        else if (exponent >= 255)
            result = {side_q[2].sign, 8'hff, 7'h00};
        else
            result = {side_q[2].sign, exponent[7:0], rounded[6:0]};
    end

    always_ff @(posedge clk) begin
        if (rst) valid_q <= '0;
        else valid_q <= {valid_q[2:0], in_valid};

        product <= result;
    end
    assign out_valid = valid_q[3];
endmodule : bf16_mul_ftz
