// One lane's PUSH/MATMUL words for the MXUs, per engine: PUSH as CODE_BITS weights, MATMUL as beats or whole words.
module mxu_feed #(
    parameter int unsigned SUBLANES           = 4,
    parameter int unsigned ELEMENT_WIDTH      = isa_pkg::VECTOR_ELEMENT_WIDTH,
    parameter int unsigned MXU_COUNT          = 1,
    parameter int unsigned PUSH_QUEUE_DEPTH   = 2,
    parameter int unsigned MATMUL_QUEUE_DEPTH = 4,
    parameter bit          MATMUL_WORD        = 1'b0,
    parameter int unsigned MATMUL_BEAT_BITS   = 8,
    parameter bit          PUSH_NATURAL       = 1'b0,
    parameter int unsigned CODE_BITS          = 4
) (
    input  logic                              clk,

    input  logic                              in_valid,
    input  logic                              in_matmul,
    input  isa_pkg::mxu_engine_id_t           in_engine,
    input  logic                              in_bank,
    input  logic [SUBLANES*ELEMENT_WIDTH-1:0] in_data,
    input  logic [7:0]                        in_scale,

    output logic                              push_valid     [MXU_COUNT],
    output logic                              push_bank      [MXU_COUNT],
    output logic [CODE_BITS-1:0]              push_code      [MXU_COUNT],
    output logic [7:0]                        push_scale     [MXU_COUNT],
    output logic                              matmul_valid   [MXU_COUNT],
    output logic [MATMUL_BEAT_BITS-1:0]       matmul_data    [MXU_COUNT],
    output logic [7:0]                        matmul_scale   [MXU_COUNT],
    output logic [SUBLANES*ELEMENT_WIDTH-1:0] matmul_word    [MXU_COUNT],
    output logic                              push_drained   [MXU_COUNT],
    output logic                              matmul_drained [MXU_COUNT]
);
    localparam int unsigned PER_ELEMENT = ELEMENT_WIDTH / CODE_BITS;
    localparam int unsigned SLOTS       = SUBLANES * PER_ELEMENT;

    logic [ELEMENT_WIDTH-1:0]          words      [SUBLANES];
    logic [ELEMENT_WIDTH-1:0]          push_words [SUBLANES];
    logic [SUBLANES*ELEMENT_WIDTH-1:0] reversed;

    function automatic int unsigned slot(int unsigned code);
        return code / PER_ELEMENT * ELEMENT_WIDTH + code % PER_ELEMENT * CODE_BITS;
    endfunction

    for (genvar code = 0; code < SLOTS; code++) begin : gen_reverse
        assign reversed[slot(code) +: CODE_BITS] = in_data[slot(SLOTS - 1 - code) +: CODE_BITS];
    end

    for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_unpack
        assign words[sublane]      = in_data[sublane*ELEMENT_WIDTH +: ELEMENT_WIDTH];
        assign push_words[sublane] = PUSH_NATURAL ? reversed[sublane*ELEMENT_WIDTH +: ELEMENT_WIDTH] : words[sublane];
    end

    for (genvar engine = 0; engine < MXU_COUNT; engine++) begin : gen_engine
        logic selected;

        assign selected = in_valid && in_engine == isa_pkg::mxu_engine_id_t'(engine);

        lane_serializer #(
            .SUBLANES(SUBLANES),
            .INPUT_WIDTH(ELEMENT_WIDTH),
            .OUTPUT_WIDTH(CODE_BITS),
            .TAG_WIDTH(9),
            .DEPTH(PUSH_QUEUE_DEPTH+1)
        ) u_push_serializer (
            .clk,
            .rst       (1'b0),
            .in_valid  (selected && !in_matmul),
            .in_ready  (),
            .in_data   (push_words),
            .in_tag    ({in_scale, in_bank}),
            .out_valid (push_valid[engine]),
            .out_ready (1'b1),
            .out_data  (push_code[engine]),
            .out_tag   ({push_scale[engine], push_bank[engine]}),
            .level     (),
            .drained   (push_drained[engine])
        );

        if (MATMUL_WORD) begin : gen_word
            assign matmul_valid[engine]   = selected && in_matmul;
            assign matmul_word[engine]    = in_data;
            assign matmul_data[engine]    = '0;
            assign matmul_scale[engine]   = in_scale;
            assign matmul_drained[engine] = matmul_valid[engine];
        end else begin : gen_beats
            assign matmul_word[engine] = '0;
            lane_serializer #(
                .SUBLANES(SUBLANES),
                .INPUT_WIDTH(ELEMENT_WIDTH),
                .OUTPUT_WIDTH(MATMUL_BEAT_BITS),
                .TAG_WIDTH(8),
                .DEPTH(MATMUL_QUEUE_DEPTH+1)
            ) u_matmul_serializer (
                .clk,
                .rst       (1'b0),
                .in_valid  (selected && in_matmul),
                .in_ready  (),
                .in_data   (words),
                .in_tag    (in_scale),
                .out_valid (matmul_valid[engine]),
                .out_ready (1'b1),
                .out_data  (matmul_data[engine]),
                .out_tag   (matmul_scale[engine]),
                .level     (),
                .drained   (matmul_drained[engine])
            );
        end
    end
endmodule : mxu_feed
