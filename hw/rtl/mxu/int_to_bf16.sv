// Signed integer -> BF16, round to nearest even. 1 cycle.
module int_to_bf16 #(
    parameter int unsigned  WIDTH = 32,
    localparam int unsigned POS_W = $clog2(WIDTH)
) (
    input  logic                    clk,
    input  logic signed [WIDTH-1:0] value,
    output logic [15:0]             bf16
);
    logic [WIDTH-1:0] magnitude;
    logic [POS_W-1:0] leading;
    logic             sign_q;
    logic             zero_q;
    logic [WIDTH-1:0] magnitude_q;
    logic [POS_W-1:0] leading_q;

    assign magnitude = $unsigned(value[WIDTH-1] ? -value : value);

    always_comb begin
        leading = '0;
        for (int unsigned index = 0; index < WIDTH; index++)
            if (magnitude[index]) leading = POS_W'(index);
    end

    always_ff @(posedge clk) begin
        sign_q      <= value[WIDTH-1];
        zero_q      <= magnitude == '0;
        magnitude_q <= magnitude;
        leading_q   <= leading;
    end

    logic [WIDTH+7:0] normalized;
    logic [6:0]       fraction;
    logic             round_bit;
    logic             sticky;
    logic [14:0]      rounded;

    assign normalized = {magnitude_q, 8'b0} << (POS_W'(WIDTH - 1) - leading_q);
    assign fraction   = normalized[WIDTH+6 -: 7];
    assign round_bit  = normalized[WIDTH-1];
    assign sticky     = |normalized[WIDTH-2:0];
    assign rounded    = {8'(127 + 32'(leading_q)), fraction} + 15'(round_bit && (sticky || fraction[0]));
    assign bf16       = zero_q ? 16'h0000 : {sign_q, rounded};
endmodule : int_to_bf16
