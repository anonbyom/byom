// A TILES x TILES grid of TILE_DIM x TILE_DIM blocks: fill shifts rows in from the left, drain shifts columns out the top.
module transpose #(
    parameter int unsigned TILE_DIM = 1,
    parameter int unsigned TILES = 32,
    parameter int unsigned WIDTH = 16,

    localparam int unsigned TILE_SIZE = TILE_DIM * TILE_DIM,
    localparam int unsigned DIM = TILE_DIM * TILES
) (
    input logic              clk,

    input logic              fill,
    input logic              drain,
    input logic [WIDTH-1:0]  a [TILES][TILE_SIZE],

    output logic [WIDTH-1:0] at [TILE_DIM][DIM]
);
    logic [WIDTH-1:0] a_h [TILES][TILES + 1][TILE_SIZE];
    logic [WIDTH-1:0] a_v [TILES + 1][TILES][TILE_SIZE];

    for (genvar k = 0; k < TILES; k++) begin : gen_boundary
        assign a_h[k][0] = a[k];
        assign a_v[TILES][k] = '{default: '0};

        for (genvar i = 0; i < TILE_DIM; i++) begin : gen_row
            for (genvar j = 0; j < TILE_DIM; j++) begin : gen_col
                assign at[i][k * TILE_DIM + j] = a_v[0][TILES - 1 - k][j * TILE_DIM + i];
            end
        end
    end

    for (genvar r = 0; r < TILES; r++) begin : gen_tile_row
        for (genvar c = 0; c < TILES; c++) begin : gen_tile_col
            logic [WIDTH-1:0] data_q [TILE_SIZE];

            always_ff @(posedge clk) begin
                if (fill || drain)
                    data_q <= drain && r != TILES - 1 ? a_v[r + 1][c] : a_h[r][c];
            end

            assign a_h[r][c + 1] = data_q;
            assign a_v[r][c] = data_q;
        end
    end

endmodule : transpose
