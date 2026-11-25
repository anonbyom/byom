// Two rows packed 16 bits apart into the DSP's 27-bit A, their sums sharing its 48-bit P.
package pe_shape;
    localparam int unsigned A_WORD         = 27;
    localparam int unsigned PACK_SHIFT     = 16;
    localparam int unsigned BC_BITS        = 18;
    localparam int unsigned P_WORD         = 48;
    localparam int unsigned LATENCY        = 3;
    localparam int unsigned ROW_SKEW       = 1;     // sums move one row per cycle (PCIN)
    localparam int unsigned ACC_STAGES     = 1;     // unused (integer sums)
    localparam bit          ACC_OWN        = 1'b0;
    localparam bit          SUM_FLOAT      = 1'b0;
    localparam int unsigned ENCODE_BITS    = 0;     // no input encoder
    localparam int unsigned ENCODE_LATENCY = 0;
endpackage : pe_shape

// One DSP48E2: P = A * AD (+ PCIN). b_load shifts the next tile's b through B1/B2 (BCIN/BCOUT)
// b_update copies B1 into AD, the b in use.
module pe #(
    parameter bit          USE_BCIN  = 1'b0,
    parameter bit          USE_PCIN  = 1'b1,
    parameter int unsigned N_W       = 1,
    parameter int unsigned N_A       = 1,
    parameter int unsigned A_BITS    = 27,
    parameter int unsigned B_BITS    = 5,
    parameter int unsigned BC_BITS   = 18,
    parameter int unsigned P_BITS    = 48,
    parameter int unsigned PROD_BITS = 0
) (
    input  logic                    clk,

    input  logic [26:0]             a_in,
    input  logic [B_BITS-1:0]       b_in,
    input  logic                    b_load,
    input  logic                    b_update,
    input  logic [17:0]             bcin,
    input  logic [47:0]             pcin,

    output logic [26:0]             a_out,
    output logic                    b_load_out,
    output logic                    b_update_out,
    output logic [17:0]             bcout,
    output logic [47:0]             p,
    output logic [47:0]             pcout
);
    logic [26:0] a_q;
    logic        b_load_q;
    logic        b_update_q;
    logic [17:0] dsp_b;

    always_ff @(posedge clk) begin
        b_load_q   <= b_load;
        b_update_q <= b_update;
        a_q        <= a_in;
    end

    assign a_out        = a_q;
    assign b_load_out   = b_load_q;
    assign b_update_out = b_update_q;
    assign dsp_b        = {{(18-B_BITS){b_in[B_BITS-1]}}, b_in};

    DSP48E2 #(
        .ACASCREG      (1),
        .ADREG         (1),
        .ALUMODEREG    (0),
        .AMULTSEL      ("A"),
        .AREG          (1),
        .BCASCREG      (2),
        .BMULTSEL      ("AD"),
        .BREG          (2),
        .B_INPUT       (USE_BCIN ? "CASCADE" : "DIRECT"),
        .CARRYINREG    (0),
        .CARRYINSELREG (0),
        .CREG          (0),
        .DREG          (0),
        .INMODEREG     (0),
        .MREG          (1),
        .OPMODEREG     (0),
        .PREADDINSEL   ("B"),
        .PREG          (1),
        .USE_MULT      ("MULTIPLY"),
        .USE_SIMD      ("ONE48")
    ) dsp (
        .A             ({3'b000, a_in}),
        .ACIN          ('0),
        .ALUMODE       ('0),
        .B             (dsp_b),
        .BCIN          (bcin),
        .BCOUT         (bcout),
        .C             ('0),
        .CARRYCASCIN   (1'b0),
        .CARRYIN       (1'b0),
        .CARRYINSEL    ('0),
        .CEA1          (1'b0),
        .CEA2          (1'b1),
        .CEAD          (b_update),
        .CEALUMODE     (1'b1),
        .CEB1          (b_load),
        .CEB2          (b_load),
        .CEC           (1'b0),
        .CECARRYIN     (1'b1),
        .CECTRL        (1'b1),
        .CED           (1'b0),
        .CEINMODE      (1'b1),
        .CEM           (1'b1),
        .CEP           (1'b1),
        .CLK           (clk),
        .D             ('0),
        .INMODE        (5'b10000), // pre-adder takes B1 + 0, AD feeds multiplier B
        .MULTSIGNIN    (1'b0),
        .OPMODE        (USE_PCIN ? 9'b000010101 : 9'b000110101),
        .P             (p),
        .PCIN          (pcin),
        .PCOUT         (pcout),
        .RSTA          (1'b0),
        .RSTALLCARRYIN (1'b0),
        .RSTALUMODE    (1'b0),
        .RSTB          (1'b0),
        .RSTC          (1'b0),
        .RSTCTRL       (1'b0),
        .RSTD          (1'b0),
        .RSTINMODE     (1'b0),
        .RSTM          (1'b0),
        .RSTP          (1'b0)
    );
endmodule : pe
