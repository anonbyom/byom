module barrel_rotator #(
    parameter int unsigned INPUTS     = 2,
    parameter int unsigned DATA_WIDTH = 32,

    localparam int unsigned ROTATION_WIDTH = (INPUTS > 1) ? $clog2(INPUTS) : 1
) (
    input  logic [DATA_WIDTH-1:0]     data_in  [INPUTS],
    input  logic [ROTATION_WIDTH-1:0] rotation,
    output logic [DATA_WIDTH-1:0]     data_out [INPUTS]
);
    localparam int unsigned STAGES = $clog2(INPUTS);

    logic [STAGES:0][INPUTS-1:0][DATA_WIDTH-1:0] stage_data;

    for (genvar input_idx = 0; input_idx < INPUTS; input_idx++) begin : gen_input
        assign stage_data[0][input_idx] = data_in[input_idx];
    end

    for (genvar stage = 0; stage < STAGES; stage++) begin : gen_stage
        localparam int unsigned OFFSET = 1 << stage;

        for (genvar output_idx = 0; output_idx < INPUTS; output_idx++) begin : gen_output
            localparam int unsigned ROTATED_INDEX = (output_idx + OFFSET) % INPUTS;

            assign stage_data[stage + 1][output_idx] = rotation[stage] ? stage_data[stage][ROTATED_INDEX]
                : stage_data[stage][output_idx];
        end
    end

    for (genvar output_idx = 0; output_idx < INPUTS; output_idx++) begin : gen_output
        assign data_out[output_idx] = stage_data[STAGES][output_idx];
    end

endmodule : barrel_rotator
