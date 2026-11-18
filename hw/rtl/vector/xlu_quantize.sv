// XLANE_QUANTIZE: BF16 rows -> MXFP4 codes and E8M0 scales, one block per row across the lanes, four rows a cycle.
//   A  (4 inputs, 16 rows): result 0 lane l = the rows' codes for lane l, result 1 lane r = row r's scale.
//   W  (8 inputs, 32 rows): results 0 / 1 lane r = row r's codes for lanes 31..16 / 15..0, result 2 the scales.
//   WT (8 inputs): W of the transposed tile (xlu_quantize_t).
// A group's results leave on consecutive cycles after its last row; vector_issue spaces groups.
module xlu_quantize #(
    parameter int unsigned LANES    = 32,
    parameter int unsigned SUBLANES = 4,
    parameter int unsigned WIDTH    = 16,

    localparam int unsigned CODES   = SUBLANES * WIDTH / 4,   // codes per output word
    localparam int unsigned ROWS    = 2 * CODES,              // rows of a W group
    localparam int unsigned ROW_W   = $clog2(ROWS),
    localparam int unsigned LATENCY = $clog2(LANES) + 2 + 4   // bf16_block_quantize
) (
    input  logic                      clk,

    input  logic                      in_valid,
    input  logic                      in_weight,
    input  logic                      in_transposed,
    input  logic [SUBLANES*WIDTH-1:0] in_data [LANES],
    output logic                      out_valid,
    output logic [SUBLANES*WIDTH-1:0] out_data [LANES]
);
    typedef enum logic [1:0] {IDLE, FIRST, SECOND, SCALES} emit_t;

    logic                      row_weight;
    logic                      row_valid [SUBLANES];
    logic [LANES-1:0][15:0]    row_values [SUBLANES];
    logic [7:0]                row_scale [SUBLANES];
    logic [LANES-1:0][3:0]     row_codes [SUBLANES];
    logic                      row_last;
    logic [ROW_W-1:0]          row_q = '0;
    logic [4*ROWS-1:0]         codes_q [LANES];
    logic [7:0]                scale_q [ROWS];
    logic [7:0]                scale_out_q [ROWS];
    logic [4*CODES-1:0]        row0_low_q;
    logic                      weight_q;
    emit_t                     emit_q = IDLE;
    logic                      emit_valid_q = 1'b0;
    logic [SUBLANES*WIDTH-1:0] emit_data_q [LANES];
    logic                      t_valid;
    logic [SUBLANES*WIDTH-1:0] t_data [LANES];

    shifter #(
        .WIDTH(1),
        .LENGTH(LATENCY)
    ) u_row_weight (
        .clk,
        .rst (1'b0),
        .en  (1'b1),
        .d   (in_weight),
        .q   (row_weight)
    );

    for (genvar p = 0; p < SUBLANES; p++) begin : gen_quantizer
        for (genvar lane = 0; lane < LANES; lane++) begin : gen_row
            assign row_values[p][lane] = in_data[lane][p*WIDTH +: WIDTH];
        end
        bf16_block_quantize #(
            .BLOCK_SIZE(LANES)
        ) u_quantize (
            .clk,
            .rst       (1'b0),
            .in_valid  (in_valid && !in_transposed),
            .values    (row_values[p]),
            .out_valid (row_valid[p]),
            .lane_valid(),
            .scale     (row_scale[p]),
            .mxfp4     (row_codes[p])
        );
    end

    assign row_last = row_q == ROW_W'(row_weight ? ROWS - SUBLANES : CODES - SUBLANES);

    always_ff @(posedge clk) begin
        if (row_valid[0]) begin
            for (int p = 0; p < SUBLANES; p++) begin
                for (int lane = 0; lane < LANES; lane++) codes_q[lane][4*(int'(row_q)+p) +: 4] <= row_codes[p][lane];
                scale_q[int'(row_q)+p] <= row_scale[p];
            end
            row_q <= row_last ? '0 : row_q + ROW_W'(SUBLANES);
            if (row_last) weight_q <= row_weight;
        end
    end

    always_ff @(posedge clk) begin
        if (row_valid[0] && row_last) emit_q <= FIRST;
        else case (emit_q)
            FIRST:   emit_q <= weight_q ? SECOND : SCALES;
            SECOND:  emit_q <= SCALES;
            default: emit_q <= IDLE;
        endcase
        emit_valid_q <= emit_q != IDLE;
    end

    always_ff @(posedge clk) begin
        if (emit_q == FIRST) begin
            scale_out_q <= scale_q;
            for (int j = 0; j < CODES; j++) row0_low_q[4*j +: 4] <= codes_q[CODES-1-j][3:0];
        end
        for (int lane = 0; lane < LANES; lane++) begin
            case (emit_q)
                FIRST:
                    for (int j = 0; j < CODES; j++)
                        emit_data_q[lane][4*j +: 4] <= weight_q ? codes_q[LANES-1-j][4*lane +: 4] : codes_q[lane][4*j +: 4];
                SECOND:
                    for (int j = 0; j < CODES; j++)
                        emit_data_q[lane][4*j +: 4] <= lane == 0 ? row0_low_q[4*j +: 4] : codes_q[CODES-1-j][4*lane +: 4];
                SCALES:
                    emit_data_q[lane] <= (SUBLANES*WIDTH)'(lane < (weight_q ? ROWS : CODES) ? scale_out_q[lane] : 8'd0);
                default: ;
            endcase
        end
    end

    xlu_quantize_t #(
        .LANES(LANES),
        .SUBLANES(SUBLANES),
        .WIDTH(WIDTH)
    ) u_transposed (
        .clk,
        .in_valid  (in_valid && in_transposed),
        .in_data,
        .out_valid (t_valid),
        .out_data  (t_data)
    );

    assign out_valid = emit_valid_q || t_valid;
    for (genvar lane = 0; lane < LANES; lane++) begin : gen_out
        assign out_data[lane] = t_valid ? t_data[lane] : emit_data_q[lane];
    end
endmodule : xlu_quantize

module xlu_quantize_t #(
    parameter int unsigned LANES    = 32,
    parameter int unsigned SUBLANES = 4,
    parameter int unsigned WIDTH    = 16,
    localparam int unsigned INPUTS  = 32 / SUBLANES,
    localparam int unsigned IDX_W   = $clog2(INPUTS),
    localparam int unsigned CODES   = SUBLANES * WIDTH / 4
) (
    input  logic                      clk,
    input  logic                      in_valid,
    input  logic [SUBLANES*WIDTH-1:0] in_data [LANES],
    output logic                      out_valid,
    output logic [SUBLANES*WIDTH-1:0] out_data [LANES]
);
    typedef enum logic [1:0] {IDLE, HIGH, LOW, SCALES} emit_t;

    logic [IDX_W-1:0] in_idx_q  = '0;
    logic             in_bank_q = 1'b0;
    logic             abs_valid, abs_first, abs_last;
    logic             max_valid_q;
    logic             scale_valid;
    logic             read_q    = 1'b0;
    logic [IDX_W-1:0] read_idx_q;
    logic             read_bank_q = 1'b0;
    logic             read_valid_q;
    logic             code_valid;
    logic [IDX_W-1:0] code_idx;
    emit_t            emit_q    = IDLE;

    always_ff @(posedge clk) begin
        if (in_valid) begin
            in_idx_q <= in_idx_q + 1'b1;
            if (in_idx_q == IDX_W'(INPUTS - 1)) in_bank_q <= !in_bank_q;
        end
    end

    shifter #(
        .WIDTH(3),
        .LENGTH(2)
    ) u_abs_tag (
        .clk,
        .rst (1'b0),
        .en  (1'b1),
        .d   ({in_valid, in_idx_q == '0, in_idx_q == IDX_W'(INPUTS - 1)}),
        .q   ({abs_valid, abs_first, abs_last})
    );
    always_ff @(posedge clk) max_valid_q <= abs_valid && abs_last;

    always_ff @(posedge clk) begin
        if (scale_valid) begin
            read_q     <= 1'b1;
            read_idx_q <= '0;
        end else if (read_q) begin
            read_idx_q <= read_idx_q + 1'b1;
            if (read_idx_q == IDX_W'(INPUTS - 1)) begin
                read_q      <= 1'b0;
                read_bank_q <= !read_bank_q;
            end
        end
        read_valid_q <= read_q;
    end

    shifter #(
        .WIDTH(1 + IDX_W),
        .LENGTH(5)
    ) u_code_tag (
        .clk,
        .rst (1'b0),
        .en  (1'b1),
        .d   ({read_q, read_idx_q}),
        .q   ({code_valid, code_idx})
    );

    always_ff @(posedge clk) begin
        if (code_valid && code_idx == IDX_W'(INPUTS - 1)) emit_q <= HIGH;
        else emit_q <= emit_q == IDLE ? IDLE : emit_t'(emit_q + 1'b1);
        out_valid <= emit_q != IDLE;
    end

    logic lane_scale_valid [LANES];
    assign scale_valid = lane_scale_valid[0];

    for (genvar lane = 0; lane < LANES; lane++) begin : gen_lane
        logic [SUBLANES*WIDTH-1:0] rows_q [2*INPUTS];    // {bank, input} -> the input's rows
        logic [WIDTH-1:0]          pair [2];
        logic [WIDTH-1:0]          pair_q [2];
        logic [WIDTH-1:0]          abs;
        logic [WIDTH-1:0]          abs_q;
        logic [WIDTH-1:0]          running;
        logic [WIDTH-1:0]          max_q;
        logic [WIDTH-1:0]          group_max_q;
        logic [7:0]                scale;
        logic [7:0]                scale_q;              // the group being converted
        logic [7:0]                scale_out_q;          // the group whose results leave
        logic [SUBLANES*WIDTH-1:0] read_data_q;
        logic [3:0]                code [SUBLANES];
        logic [4*32-1:0]           codes_q;              // bits [4r +: 4] = row r's code

        always_ff @(posedge clk) if (in_valid) rows_q[{in_bank_q, in_idx_q}] <= in_data[lane];

        bf16_absmax u_pair0 (
            .a       (in_data[lane][0*WIDTH +: WIDTH]),
            .b       (in_data[lane][1*WIDTH +: WIDTH]),
            .maximum (pair[0])
        );
        bf16_absmax u_pair1 (
            .a       (in_data[lane][2*WIDTH +: WIDTH]),
            .b       (in_data[lane][3*WIDTH +: WIDTH]),
            .maximum (pair[1])
        );
        bf16_absmax u_abs (
            .a       (pair_q[0]),
            .b       (pair_q[1]),
            .maximum (abs)
        );
        bf16_absmax u_run (
            .a       (max_q),
            .b       (abs_q),
            .maximum (running)
        );

        always_ff @(posedge clk) begin
            pair_q <= pair;
            abs_q  <= abs;
            if (abs_valid) max_q <= abs_first ? abs_q : running;
            if (abs_valid && abs_last) group_max_q <= abs_first ? abs_q : running;
        end

        bf16_scale_from_max u_scale (
            .clk,
            .rst       (1'b0),
            .in_valid  (max_valid_q),
            .maximum   (group_max_q),
            .out_valid (lane_scale_valid[lane]),
            .scale
        );

        always_ff @(posedge clk) begin
            if (lane_scale_valid[lane]) scale_q <= scale;
            if (read_q && read_idx_q == IDX_W'(INPUTS - 1)) scale_out_q <= scale_q;
            read_data_q <= rows_q[{read_bank_q, read_idx_q}];
        end

        for (genvar s = 0; s < SUBLANES; s++) begin : gen_convert
            bf16_to_mxfp4 u_convert (
                .clk,
                .rst       (1'b0),
                .in_valid  (read_valid_q),
                .bf16      (read_data_q[s*WIDTH +: WIDTH]),
                .scale     (scale_q),
                .out_valid (),
                .mxfp4     (code[s])
            );
        end

        always_ff @(posedge clk) begin
            if (code_valid)
                for (int s = 0; s < SUBLANES; s++) codes_q[4*(SUBLANES*int'(code_idx)+s) +: 4] <= code[s];
            case (emit_q)
                HIGH:    for (int j = 0; j < CODES; j++) out_data[lane][4*j +: 4] <= codes_q[4*(31-j) +: 4];
                LOW:     for (int j = 0; j < CODES; j++) out_data[lane][4*j +: 4] <= codes_q[4*(15-j) +: 4];
                SCALES:  out_data[lane] <= (SUBLANES*WIDTH)'(scale_out_q);
                default: ;
            endcase
        end
    end
endmodule : xlu_quantize_t
