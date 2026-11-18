module lane_pack #(
    parameter int unsigned SUBLANES = 4
) (
    input  logic                  clk,
    input  logic                  in_valid,
    input  isa_pkg::valu_opcode_t op,
    input  logic [15:0]           x [SUBLANES],
    input  logic [15:0]           y [SUBLANES],
    output logic                  out_valid,
    output logic [15:0]           result [SUBLANES]
);
    import isa_pkg::*;

    typedef struct packed {
        logic       sign;
        logic       under;
        logic       over;
        logic [7:0] whole;
        logic       half;
        logic       sticky;
    } aligned_t;

    function automatic aligned_t align(logic [15:0] bf16);
        logic [7:0]  exponent;
        logic [15:0] shifted;
        exponent = bf16[14:7];
        shifted  = {1'b1, bf16[6:0], 8'b0} >> (8'd134 - exponent);
        return '{sign: bf16[15], under: exponent < 8'd126, over: exponent > 8'd134, whole: shifted[15:8],
                 half: shifted[7], sticky: |shifted[6:0]};
    endfunction

    function automatic logic [7:0] round_code(aligned_t a, logic unsigned_code, logic four_bits);
        logic [8:0] rounded;
        logic [8:0] limit;
        logic [8:0] magnitude;
        rounded = 9'(a.whole) + 9'(a.half && (a.sticky || a.whole[0]));
        if (unsigned_code) limit = 9'd255;
        else if (four_bits) limit = a.sign ? 9'd8 : 9'd7;
        else limit = a.sign ? 9'd128 : 9'd127;
        if (a.under) magnitude = '0;
        else if (a.over || rounded > limit) magnitude = limit;
        else magnitude = rounded;
        if (unsigned_code) return a.sign ? 8'h00 : magnitude[7:0];
        return a.sign ? 8'(-magnitude) : magnitude[7:0];
    endfunction

    function automatic logic [15:0] to_bf16(logic negative, logic [7:0] magnitude);
        logic [2:0] lead;
        lead = '0;
        for (int i = 0; i < 8; i++) if (magnitude[i]) lead = 3'(i);
        if (magnitude == 0) return 16'h0000;
        return {negative, 8'(127 + lead), 7'((16'(magnitude) << (7 - lead)) & 16'h7f)};
    endfunction

    logic [2:0]   valid_q;
    valu_opcode_t op_q [2];
    logic [15:0]  x_q [SUBLANES];
    logic [15:0]  y_q [SUBLANES];
    aligned_t     aligned_d [2][SUBLANES];
    aligned_t     aligned_q [2][SUBLANES];
    logic         negative_d [SUBLANES];
    logic         negative_q [SUBLANES];
    logic [7:0]   magnitude_d [SUBLANES];
    logic [7:0]   magnitude_q [SUBLANES];
    logic [7:0]   piece [2][SUBLANES];
    logic [15:0]  bits_d [SUBLANES];
    logic [15:0]  bits_q [SUBLANES];
    logic [15:0]  result_d [SUBLANES];
    logic [15:0]  result_q [SUBLANES];

    always_comb begin
        for (int s = 0; s < SUBLANES; s++) begin
            logic [7:0] byte_in;
            int unsigned src, pair, half_index;
            src        = s < SUBLANES / 2 ? 0 : 1;
            pair       = 2 * (s % (SUBLANES / 2));
            half_index = s / 2;

            aligned_d[0][s] = align(x_q[s]);
            aligned_d[1][s] = align(y_q[s]);
            byte_in         = op_q[0] inside {VUNPACK_S8_HI, VUNPACK_U8_HI} ? x_q[s][15:8] : x_q[s][7:0];
            negative_d[s]   = op_q[0] inside {VUNPACK_S8_LO, VUNPACK_S8_HI} && byte_in[7];
            magnitude_d[s]  = negative_d[s] ? 8'(-byte_in) : byte_in;
            case (op_q[0])
                VPACK_8_C: bits_d[s] = src == 0 ? {x_q[pair + 1][7:0], x_q[pair][7:0]}
                                                : {y_q[pair + 1][7:0], y_q[pair][7:0]};
                VPACK_8_I: bits_d[s] = {y_q[s][7:0], x_q[s][7:0]};
                VPACK_I_0: bits_d[s] = s % 2 == 0 ? x_q[half_index] : y_q[half_index];
                VPACK_I_1: bits_d[s] = s % 2 == 0 ? x_q[half_index + SUBLANES / 2] : y_q[half_index + SUBLANES / 2];
                default:   bits_d[s] = '0;
            endcase
        end
        for (int i = 0; i < 2; i++)
            for (int s = 0; s < SUBLANES; s++)
                piece[i][s] = round_code(aligned_q[i][s], op_q[1] inside {VPACK_U8_C, VPACK_U8_I},
                                         op_q[1] inside {VPACK_4_C, VPACK_4_I});
        for (int s = 0; s < SUBLANES; s++) begin
            int unsigned src, pair;
            src  = s < SUBLANES / 2 ? 0 : 1;
            pair = 2 * (s % (SUBLANES / 2));
            case (op_q[1])
                VUNPACK_S8_LO, VUNPACK_S8_HI, VUNPACK_U8_LO, VUNPACK_U8_HI: result_d[s] = to_bf16(negative_q[s], magnitude_q[s]);
                VPACK_8_C, VPACK_8_I, VPACK_I_0, VPACK_I_1: result_d[s] = bits_q[s];
                VPACK_S8_I, VPACK_U8_I: result_d[s] = {piece[1][s], piece[0][s]};
                VPACK_4_I:              result_d[s] = {8'b0, piece[1][s][3:0], piece[0][s][3:0]};
                VPACK_4_C:              result_d[s] = {8'b0, piece[src][pair + 1][3:0], piece[src][pair][3:0]};
                default:                result_d[s] = {piece[src][pair + 1], piece[src][pair]};
            endcase
        end
    end

    always_ff @(posedge clk) begin
        valid_q <= {valid_q[1:0], in_valid};
    end

    always_ff @(posedge clk) begin
        op_q        <= '{op, op_q[0]};
        x_q         <= x;
        y_q         <= y;
        aligned_q   <= aligned_d;
        negative_q  <= negative_d;
        magnitude_q <= magnitude_d;
        bits_q      <= bits_d;
        result_q    <= result_d;
    end

    assign out_valid = valid_q[2];
    assign result    = result_q;
endmodule : lane_pack
