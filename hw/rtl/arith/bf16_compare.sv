module bf16_compare (
    input  logic [15:0] a,
    input  logic [15:0] b,

    output logic        less,
    output logic        equal,
    output logic        greater,
    output logic        unordered,
    output logic [15:0] minimum,
    output logic [15:0] maximum
);
    localparam logic [15:0] BF16_NAN = 16'h7fc0;

    logic a_is_nan;
    logic b_is_nan;
    logic a_is_zero;
    logic b_is_zero;

    assign a_is_nan  = a[14:7] == 8'hff && a[6:0] != '0;
    assign b_is_nan  = b[14:7] == 8'hff && b[6:0] != '0;
    assign a_is_zero = a[14:0] == '0;
    assign b_is_zero = b[14:0] == '0;

    always_comb begin
        less      = 1'b0;
        equal     = 1'b0;
        greater   = 1'b0;
        unordered = 1'b0;

        if (a_is_nan || b_is_nan) begin
            unordered = 1'b1;
        end else if (a_is_zero && b_is_zero) begin
            equal = 1'b1;
        end else if (a == b) begin
            equal = 1'b1;
        end else if (a[15] != b[15]) begin
            if (a[15])
                less = 1'b1;
            else
                greater = 1'b1;
        end else if (a[15]) begin
            if (a[14:0] > b[14:0])
                less = 1'b1;
            else
                greater = 1'b1;
        end else begin
            if (a[14:0] < b[14:0])
                less = 1'b1;
            else
                greater = 1'b1;
        end
    end

    always_comb begin
        minimum = BF16_NAN;
        maximum = BF16_NAN;

        if (!unordered) begin
            if (a_is_zero && b_is_zero) begin
                minimum = {a[15] | b[15], 15'b0};
                maximum = {a[15] & b[15], 15'b0};
            end else if (less) begin
                minimum = a;
                maximum = b;
            end else if (greater) begin
                minimum = b;
                maximum = a;
            end else begin
                minimum = a;
                maximum = a;
            end
        end
    end
endmodule : bf16_compare
