// max |value| of SIZE BF16 values: a registered tree, one level a cycle.
module bf16_absmax_reduction #(
    parameter int unsigned SIZE = 32,
    localparam int unsigned LEVELS = $clog2(SIZE)
) (
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  in_valid,
    input  logic [SIZE-1:0][15:0] values,
    output logic                  out_valid,
    output logic [15:0]           maximum
);
    logic [LEVELS:0][SIZE-1:0][15:0] stage_q;

    assign stage_q[0] = values;

    for (genvar level = 0; level < LEVELS; level++) begin : gen_level
        localparam int unsigned NODES = SIZE >> (level + 1);
        logic [NODES-1:0][15:0] stage_d;

        for (genvar node = 0; node < NODES; node++) begin : gen_node
            bf16_absmax compare (
                .a       (stage_q[level][2 * node]),
                .b       (stage_q[level][2 * node + 1]),
                .maximum (stage_d[node])
            );
        end
        always_ff @(posedge clk) stage_q[level + 1] <= {{(SIZE - NODES){16'b0}}, stage_d};
    end

    shifter #(
        .WIDTH(1),
        .LENGTH(LEVELS)
    ) u_valid (
        .clk,
        .rst,
        .en (1'b1),
        .d  (in_valid),
        .q  (out_valid)
    );

    assign maximum = stage_q[LEVELS][0];
endmodule : bf16_absmax_reduction
