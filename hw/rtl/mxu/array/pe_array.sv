// DIM x DIM weight-stationary array of PEs, each N_W columns by N_A rows
// a and b_update move right, the next tile's b moves down on b_load, sums move down.
module pe_array #(
    parameter int unsigned  DIM       = 32,
    parameter int unsigned  N_W       = 1,
    parameter int unsigned  N_A       = 1,
    parameter int unsigned  A_BITS    = 5,
    parameter int unsigned  B_BITS    = 5,
    parameter int unsigned  P_BITS    = 14,
    parameter int unsigned  PROD_BITS = 0,
    localparam int unsigned SHIFT     = pe_shape::PACK_SHIFT,
    localparam int unsigned LANES     = SHIFT != 0 ? 1 : N_A,
    localparam int unsigned PE_A      = SHIFT != 0 ? pe_shape::A_WORD : A_BITS,
    localparam int unsigned PE_BC     = pe_shape::BC_BITS != 0 ? pe_shape::BC_BITS : B_BITS,
    localparam int unsigned PE_P      = pe_shape::P_WORD != 0 ? pe_shape::P_WORD : P_BITS,
    localparam int unsigned GROUPS    = (DIM + N_W - 1) / N_W,
    localparam int unsigned SPAN      = GROUPS * N_W
) (
    input  logic                     clk,

    input  logic                     b_load       [DIM],
    input  logic                     b_update     [DIM],
    input  logic [B_BITS-1:0]        b_in         [DIM],
    input  logic [A_BITS-1:0]        a_in         [DIM][N_A],
    output logic signed [P_BITS-1:0] psum_out     [DIM][N_A]
);
    logic [LANES*PE_A-1:0]       a_path        [DIM][GROUPS+1];
    logic [N_W*B_BITS-1:0]       b_group       [GROUPS];
    logic [N_W*PE_BC-1:0]        b_cascade     [DIM+1][GROUPS];
    logic [N_W-1:0]              b_load_path   [DIM+1][GROUPS];
    logic                        b_update_path [DIM][GROUPS+1];
    logic [N_W*LANES*PE_P-1:0]   cascade       [DIM+1][GROUPS];
    logic [N_W*LANES*PE_P-1:0]   result        [DIM][GROUPS];

    for (genvar index = 0; index < DIM; index++) begin : gen_rows
        if (SHIFT != 0) begin : gen_pack
            always_comb begin
                a_path[index][0] = '0;
                for (int unsigned lane = 0; lane < N_A; lane++)
                    a_path[index][0] += PE_A'($signed(a_in[index][lane])) <<< (lane * SHIFT);
            end
        end else begin : gen_lanes
            for (genvar lane = 0; lane < N_A; lane++) begin : gen_lane
                assign a_path[index][0][lane*A_BITS +: A_BITS] = a_in[index][lane];
            end
        end
        assign b_update_path[index][0] = b_update[index];
    end

    for (genvar col = 0; col < SPAN; col++) begin : gen_cols
        if (col < DIM) begin : gen_used
            assign b_group[col/N_W][col%N_W*B_BITS +: B_BITS] = b_in[col];
            assign b_load_path[0][col/N_W][col%N_W]           = b_load[col];
            if (SHIFT != 0) begin : gen_unpack
                logic signed [PE_P-1:0] rest [N_A];
                assign rest[0] = result[DIM-1][col/N_W][col%N_W*PE_P +: PE_P];
                for (genvar lane = 0; lane < N_A; lane++) begin : gen_lane
                    logic signed [SHIFT-1:0] field;
                    assign field = rest[lane][SHIFT-1:0];
                    if (lane + 1 < N_A) begin : gen_low
                        assign psum_out[col][lane] = P_BITS'(field);
                        assign rest[lane+1] = (rest[lane] >>> SHIFT) + (field[SHIFT-1] ? PE_P'(1) : PE_P'(0));
                    end else begin : gen_high
                        assign psum_out[col][lane] = P_BITS'(rest[lane]);
                    end
                end
            end else begin : gen_lanes
                for (genvar lane = 0; lane < N_A; lane++) begin : gen_lane
                    assign psum_out[col][lane] = result[DIM-1][col/N_W][(col%N_W*N_A+lane)*P_BITS +: P_BITS];
                end
            end
        end else begin : gen_pad
            assign b_group[col/N_W][col%N_W*B_BITS +: B_BITS] = '0;
            assign b_load_path[0][col/N_W][col%N_W]           = 1'b0;
        end
    end

    for (genvar group = 0; group < GROUPS; group++) begin : gen_top
        assign b_cascade[0][group] = '0;
        assign cascade[0][group]   = '0;
    end

    for (genvar row = 0; row < DIM; row++) begin : gen_pe_row
        for (genvar group = 0; group < GROUPS; group++) begin : gen_pe_col
            pe #(
                .USE_BCIN(row != 0),
                .USE_PCIN(row != 0),
                .N_W(N_W),
                .N_A(LANES),
                .A_BITS(PE_A),
                .B_BITS(B_BITS),
                .BC_BITS(PE_BC),
                .P_BITS(PE_P),
                .PROD_BITS(PROD_BITS)
            ) pe (
                .clk,
                .a_in         (a_path[row][group]),
                .b_in         (b_group[group]),
                .b_load       (b_load_path[row][group]),
                .b_update     (b_update_path[row][group]),
                .bcin         (b_cascade[row][group]),
                .pcin         (cascade[row][group]),
                .a_out        (a_path[row][group+1]),
                .b_load_out   (b_load_path[row+1][group]),
                .b_update_out (b_update_path[row][group+1]),
                .bcout        (b_cascade[row+1][group]),
                .p            (result[row][group]),
                .pcout        (cascade[row+1][group])
            );
        end
    end
endmodule : pe_array
