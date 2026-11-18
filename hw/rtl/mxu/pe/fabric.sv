package pe_shape;
    localparam int unsigned A_WORD         = 0;
    localparam int unsigned PACK_SHIFT     = 0;
    localparam int unsigned BC_BITS        = 0;
    localparam int unsigned P_WORD         = 0;
    localparam int unsigned LATENCY        = 1 + mul_shape::LATENCY + add_shape::STAGES;
    localparam int unsigned ROW_SKEW       = add_shape::STAGES;
    localparam int unsigned ACC_STAGES     = add_shape::STAGES;
    localparam bit          SUM_FLOAT      = add_shape::FLOAT;
    localparam bit          ACC_OWN        = add_shape::ACC_OWN;
    localparam int unsigned ENCODE_BITS    = 0;     // no input encoder
    localparam int unsigned ENCODE_LATENCY = 0;
endpackage : pe_shape

module pe #(
    parameter bit          USE_BCIN  = 1'b0,
    parameter bit          USE_PCIN  = 1'b1,
    parameter int unsigned N_W       = 3,
    parameter int unsigned N_A       = 3,
    parameter int unsigned A_BITS    = 4,
    parameter int unsigned B_BITS    = 4,
    parameter int unsigned BC_BITS   = B_BITS,
    parameter int unsigned P_BITS    = 12,
    parameter int unsigned PROD_BITS = 8
) (
    input  logic                         clk,

    input  logic [N_A*A_BITS-1:0]        a_in,
    input  logic [N_W*B_BITS-1:0]        b_in,
    input  logic [N_W-1:0]               b_load,
    input  logic                         b_update,
    input  logic [N_W*BC_BITS-1:0]       bcin,
    input  logic [N_W*N_A*P_BITS-1:0]    pcin,

    output logic [N_A*A_BITS-1:0]        a_out,
    output logic [N_W-1:0]               b_load_out,
    output logic                         b_update_out,
    output logic [N_W*BC_BITS-1:0]       bcout,
    output logic [N_W*N_A*P_BITS-1:0]    p,
    output logic [N_W*N_A*P_BITS-1:0]    pcout
);
    logic [N_A*A_BITS-1:0]       a_q        [N_W+1];
    logic                        b_update_q [N_W+1];
    logic [B_BITS-1:0]           weight     [N_W];
    logic [A_BITS-1:0]           a          [N_A];
    logic signed [PROD_BITS-1:0] ones       [N_W][N_A];
    logic                        carry      [N_W][N_A];

    assign a_q[0]        = a_in;
    assign b_update_q[0] = b_update;

    always_ff @(posedge clk) begin
        for (int unsigned col = 1; col <= N_W; col++) begin
            a_q[col]        <= a_q[col-1];
            b_update_q[col] <= b_update_q[col-1];
        end
    end

    assign a_out        = a_q[N_W];
    assign b_update_out = b_update_q[N_W];

    for (genvar row = 0; row < N_A; row++) begin : gen_a
        assign a[row] = a_q[N_W][row*A_BITS +: A_BITS];
    end


    for (genvar col = 0; col < N_W; col++) begin : gen_col
        logic [B_BITS-1:0] load_in;
        logic [B_BITS-1:0] b1;
        logic [B_BITS-1:0] b2;

        assign load_in = USE_BCIN ? bcin[col*BC_BITS +: B_BITS] : b_in[col*B_BITS +: B_BITS];

        always_ff @(posedge clk) begin
            b_load_out[col] <= b_load[col];
            if (b_load[col]) begin
                b1 <= load_in;
                b2 <= b1;
            end
            if (b_update_q[N_W-1]) weight[col] <= b1;
        end

        assign bcout[col*BC_BITS +: BC_BITS] = BC_BITS'(b2);
    end

    logic [P_BITS-1:0] psum_in [N_W][N_A];
    logic [P_BITS-1:0] psum    [N_W][N_A];
    for (genvar col = 0; col < N_W; col++) begin : gen_chain
        for (genvar row = 0; row < N_A; row++) begin : gen_row
            assign psum_in[col][row] = USE_PCIN ? pcin[(col*N_A+row)*P_BITS +: P_BITS] : P_BITS'(add_shape::ZERO);
            assign pcout[(col*N_A+row)*P_BITS +: P_BITS] = psum[col][row];
        end
    end

    mul_impl u_mul (
        .clk,
        .w (weight),
        .a,
        .ones,
        .carry
    );
    for (genvar col = 0; col < N_W; col++) begin : gen_add
        for (genvar row = 0; row < N_A; row++) begin : gen_sum
            add_impl #(
                .P_BITS(P_BITS),
                .PROD_BITS(PROD_BITS)
            ) u_add (
                .clk,
                .psum_in (psum_in[col][row]),
                .ones    (ones[col][row]),
                .carry   (carry[col][row]),
                .psum    (psum[col][row])
            );
        end
    end

    assign p = pcout;
endmodule : pe
