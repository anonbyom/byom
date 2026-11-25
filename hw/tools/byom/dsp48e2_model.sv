// slang lint_save
// slang lint_off unused-parameter
// slang lint_off unused-port

module DSP48E2 #(
    parameter int unsigned ACASCREG = 0,
    parameter bit    ADREG         = 0,
    parameter bit    ALUMODEREG    = 0,
    parameter string AMULTSEL      = "A",
    parameter int unsigned AREG     = 0,   // 0, 1 or 2 (A1, A2)
    parameter int unsigned BCASCREG = 0,
    parameter string BMULTSEL      = "B",
    parameter int unsigned BREG     = 0,
    parameter string B_INPUT       = "DIRECT",
    parameter bit    CARRYINREG    = 0,
    parameter bit    CARRYINSELREG = 0,
    parameter bit    CREG          = 0,
    parameter bit    DREG          = 0,
    parameter bit    INMODEREG     = 0,
    parameter bit    MREG          = 0,
    parameter bit    OPMODEREG     = 0,
    parameter string PREADDINSEL   = "A",
    parameter bit    PREG          = 0,
    parameter string USE_MULT      = "MULTIPLY",
    parameter string USE_SIMD      = "ONE48",
    parameter string A_INPUT       = "DIRECT",
    parameter logic [47:0] RND     = '0,
    parameter string USE_WIDEXOR   = "FALSE",
    parameter string XORSIMD       = "XOR24_48_96",
    parameter string AUTORESET_PATDET   = "NO_RESET",
    parameter string AUTORESET_PRIORITY = "RESET",
    parameter logic [47:0] MASK    = 48'h3fffffffffff,
    parameter logic [47:0] PATTERN = '0,
    parameter string SEL_MASK      = "MASK",
    parameter string SEL_PATTERN   = "PATTERN",
    parameter string USE_PATTERN_DETECT = "NO_PATDET",
    parameter logic [3:0] IS_ALUMODE_INVERTED = '0,
    parameter bit    IS_CARRYIN_INVERTED = 1'b0,
    parameter bit    IS_CLK_INVERTED = 1'b0,
    parameter logic [4:0] IS_INMODE_INVERTED = '0,
    parameter logic [8:0] IS_OPMODE_INVERTED = '0,
    parameter bit    IS_RSTALLCARRYIN_INVERTED = 1'b0,
    parameter bit    IS_RSTALUMODE_INVERTED = 1'b0,
    parameter bit    IS_RSTA_INVERTED = 1'b0,
    parameter bit    IS_RSTB_INVERTED = 1'b0,
    parameter bit    IS_RSTCTRL_INVERTED = 1'b0,
    parameter bit    IS_RSTC_INVERTED = 1'b0,
    parameter bit    IS_RSTD_INVERTED = 1'b0,
    parameter bit    IS_RSTINMODE_INVERTED = 1'b0,
    parameter bit    IS_RSTM_INVERTED = 1'b0,
    parameter bit    IS_RSTP_INVERTED = 1'b0
) (
    input  logic [29:0] A,
    input  logic [29:0] ACIN,
    input  logic [3:0]  ALUMODE,
    input  logic [17:0] B,
    input  logic [17:0] BCIN,
    input  logic [47:0] C,
    input  logic        CARRYCASCIN,
    input  logic        CARRYIN,
    input  logic [2:0]  CARRYINSEL,
    input  logic        CEA1,
    input  logic        CEA2,
    input  logic        CEAD,
    input  logic        CEALUMODE,
    input  logic        CEB1,
    input  logic        CEB2,
    input  logic        CEC,
    input  logic        CECARRYIN,
    input  logic        CECTRL,
    input  logic        CED,
    input  logic        CEINMODE,
    input  logic        CEM,
    input  logic        CEP,
    input  logic        CLK,
    input  logic [26:0] D,
    input  logic [4:0]  INMODE,
    input  logic        MULTSIGNIN,
    input  logic [8:0]  OPMODE,
    input  logic [47:0] PCIN,
    input  logic        RSTA,
    input  logic        RSTALLCARRYIN,
    input  logic        RSTALUMODE,
    input  logic        RSTB,
    input  logic        RSTC,
    input  logic        RSTCTRL,
    input  logic        RSTD,
    input  logic        RSTINMODE,
    input  logic        RSTM,
    input  logic        RSTP,
    output logic [47:0] P,
    output logic [47:0] PCOUT,
    output logic [17:0] BCOUT,
    output logic [29:0] ACOUT,
    output logic        CARRYCASCOUT,
    output logic        MULTSIGNOUT,
    output logic        OVERFLOW,
    output logic        PATTERNBDETECT,
    output logic        PATTERNDETECT,
    output logic        UNDERFLOW,
    output logic [3:0]  CARRYOUT,
    output logic [7:0]  XOROUT
);
    logic signed [26:0] a_q;           // A2 (the only A register with AREG 1)
    logic signed [26:0] a1_q;          // A1 (AREG 2)
    logic signed [17:0] b1_q;
    logic signed [17:0] b2_q;
    logic signed [26:0] ad_q;
    logic signed [44:0] product_q;
    logic signed [47:0] result_q;
    logic signed [47:0] c_q;
    logic [3:0]         alumode_q;
    logic [8:0]         opmode_q;
    logic [4:0]         inmode_q;
    logic               carryin_q;

    wire signed [17:0] b_in = B_INPUT == "CASCADE" ? $signed(BCIN) : $signed(B);

    // INMODE[4] picks B1 over B2 for both the multiplier and the pre-adder.
    wire [3:0] alumode = ALUMODEREG ? alumode_q : ALUMODE;
    wire [8:0] opmode = OPMODEREG ? opmode_q : OPMODE;
    wire [4:0] inmode = INMODEREG ? inmode_q : INMODE;

    // AREG 2: A1 then A2; the multiplier takes A2 (A1 with INMODE[0]).
    wire signed [26:0] a = AREG == 0 ? $signed(A[26:0]) : AREG == 2 && inmode[0] ? a1_q : a_q;
    wire carryin = CARRYINREG ? carryin_q : CARRYIN;
    wire signed [17:0] b = BREG == 0 ? b_in : BREG == 2 && inmode[4] ? b1_q : b2_q;
    wire signed [26:0] preadd_in = inmode[1] ? 27'sd0 : PREADDINSEL == "B" ? 27'(b) : a;
    wire signed [26:0] preadd_d = inmode[2] ? $signed(D) : 27'sd0;
    wire signed [26:0] ad = inmode[3] ? preadd_d - preadd_in : preadd_d + preadd_in;
    wire signed [26:0] ad_stage = ADREG ? ad_q : ad;
    wire signed [26:0] mult_a = AMULTSEL == "AD" ? ad_stage : a;
    wire signed [17:0] mult_b = BMULTSEL == "AD" ? ad_stage[17:0] : b;
    wire signed [44:0] product = mult_a * mult_b;
    wire signed [44:0] product_stage = MREG ? product_q : product;
    wire signed [47:0] c = CREG ? c_q : $signed(C);

    // Z: 000 zero, 001 PCIN, 010 P (accumulate: the P register), 011 C.
    wire signed [47:0] z = opmode[6:4] == 3'b001 ? $signed(PCIN) : opmode[6:4] == 3'b010 ? $signed(result_q) :
        opmode[6:4] == 3'b011 ? c : 48'sd0;
    wire signed [47:0] xy = opmode[3:0] == 4'b0101 ? {{3{product_stage[44]}}, product_stage} : 48'sd0;
    wire signed [47:0] sum = xy + 48'(carryin);
    wire signed [47:0] result = alumode == 4'b0000 ? z + sum : alumode == 4'b0011 ? z - sum :
        alumode == 4'b0001 ? ~z + sum : ~(z + sum);

    always_ff @(posedge CLK) begin
        if (RSTA) begin
            a1_q <= '0;
            a_q  <= '0;
        end else if (AREG == 1) begin
            if (CEA2) a_q <= A[26:0];
        end else if (AREG == 2) begin
            if (CEA1) a1_q <= A[26:0];
            if (CEA2) a_q <= a1_q;
        end

        if (RSTB) begin
            b1_q <= '0;
            b2_q <= '0;
        end else if (BREG == 1) begin
            if (CEB2)
                b2_q <= b_in;
        end else if (BREG == 2) begin
            if (CEB1)
                b1_q <= b_in;
            if (CEB2)
                b2_q <= b1_q;
        end

        if (RSTD)
            ad_q <= '0;
        else if (ADREG && CEAD)
            ad_q <= ad;

        if (RSTM)
            product_q <= '0;
        else if (MREG && CEM)
            product_q <= product;

        if (RSTP)
            result_q <= '0;
        else if (PREG && CEP)
            result_q <= result;

        if (RSTC)
            c_q <= '0;
        else if (CEC)
            c_q <= C;

        if (CECTRL) opmode_q <= OPMODE;
        if (CEALUMODE) alumode_q <= ALUMODE;
        if (CEINMODE) inmode_q <= INMODE;
        if (CECARRYIN) carryin_q <= CARRYIN;
    end

    assign P = PREG ? result_q : result;
    assign PCOUT = P;
    assign BCOUT = BCASCREG == 0 ? b_in : BCASCREG == 1 && BREG == 2 ? b1_q : b2_q;
    assign ACOUT = 30'(a);
    assign {CARRYCASCOUT, MULTSIGNOUT, OVERFLOW, PATTERNBDETECT, PATTERNDETECT, UNDERFLOW} = '0;
    assign CARRYOUT = '0;
    assign XOROUT = '0;

    initial begin
        if (USE_MULT != "MULTIPLY" || USE_SIMD != "ONE48")
            $fatal(1, "unsupported DSP48E2 mode");
        if (AREG > 2)
            $fatal(1, "unsupported A register configuration");
        if (!((BREG == 0 && BCASCREG == 0) || (BREG == 1 && BCASCREG == 1) || (BREG == 2 && BCASCREG inside {1, 2})))
            $fatal(1, "unsupported B register configuration");
        if (!(AMULTSEL inside {"A", "AD"}) || !(BMULTSEL inside {"B", "AD"}) || !(PREADDINSEL inside {"A", "B"}))
            $fatal(1, "unsupported DSP48E2 multiplier input selection");
        if (DREG)
            $fatal(1, "unsupported D register");
    end
endmodule : DSP48E2

// slang lint_restore
