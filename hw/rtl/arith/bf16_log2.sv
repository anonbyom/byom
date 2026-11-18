module bf16_log2 (
    input  logic        clk,
    input  logic        rst,
    input  logic        in_valid,
    input  logic [15:0] a,
    output logic        out_valid,
    output logic [15:0] result
);
    localparam int LATENCY = 5;

    (* rom_style = "distributed" *) logic [23:0] log2_fraction_table [0:127];
    initial begin
        log2_fraction_table[0] = 24'h000000;
        log2_fraction_table[1] = 24'h02dfca;
        log2_fraction_table[2] = 24'h05b9e6;
        log2_fraction_table[3] = 24'h088e69;
        log2_fraction_table[4] = 24'h0b5d6a;
        log2_fraction_table[5] = 24'h0e26fd;
        log2_fraction_table[6] = 24'h10eb39;
        log2_fraction_table[7] = 24'h13aa30;
        log2_fraction_table[8] = 24'h1663f7;
        log2_fraction_table[9] = 24'h1918a1;
        log2_fraction_table[10] = 24'h1bc842;
        log2_fraction_table[11] = 24'h1e72ec;
        log2_fraction_table[12] = 24'h2118b1;
        log2_fraction_table[13] = 24'h23b9a3;
        log2_fraction_table[14] = 24'h2655d4;
        log2_fraction_table[15] = 24'h28ed54;
        log2_fraction_table[16] = 24'h2b8034;
        log2_fraction_table[17] = 24'h2e0e86;
        log2_fraction_table[18] = 24'h309858;
        log2_fraction_table[19] = 24'h331dba;
        log2_fraction_table[20] = 24'h359ebc;
        log2_fraction_table[21] = 24'h381b6e;
        log2_fraction_table[22] = 24'h3a93dd;
        log2_fraction_table[23] = 24'h3d0818;
        log2_fraction_table[24] = 24'h3f782d;
        log2_fraction_table[25] = 24'h41e42b;
        log2_fraction_table[26] = 24'h444c1f;
        log2_fraction_table[27] = 24'h46b017;
        log2_fraction_table[28] = 24'h49101f;
        log2_fraction_table[29] = 24'h4b6c44;
        log2_fraction_table[30] = 24'h4dc493;
        log2_fraction_table[31] = 24'h501919;
        log2_fraction_table[32] = 24'h5269e1;
        log2_fraction_table[33] = 24'h54b6f8;
        log2_fraction_table[34] = 24'h570069;
        log2_fraction_table[35] = 24'h594640;
        log2_fraction_table[36] = 24'h5b8887;
        log2_fraction_table[37] = 24'h5dc74b;
        log2_fraction_table[38] = 24'h600296;
        log2_fraction_table[39] = 24'h623a72;
        log2_fraction_table[40] = 24'h646eea;
        log2_fraction_table[41] = 24'h66a009;
        log2_fraction_table[42] = 24'h68cdd8;
        log2_fraction_table[43] = 24'h6af862;
        log2_fraction_table[44] = 24'h6d1fb0;
        log2_fraction_table[45] = 24'h6f43cc;
        log2_fraction_table[46] = 24'h7164bf;
        log2_fraction_table[47] = 24'h738292;
        log2_fraction_table[48] = 24'h759d50;
        log2_fraction_table[49] = 24'h77b4ff;
        log2_fraction_table[50] = 24'h79c9ab;
        log2_fraction_table[51] = 24'h7bdb5a;
        log2_fraction_table[52] = 24'h7dea16;
        log2_fraction_table[53] = 24'h7ff5e6;
        log2_fraction_table[54] = 24'h81fed4;
        log2_fraction_table[55] = 24'h8404e8;
        log2_fraction_table[56] = 24'h860828;
        log2_fraction_table[57] = 24'h88089e;
        log2_fraction_table[58] = 24'h8a0650;
        log2_fraction_table[59] = 24'h8c0146;
        log2_fraction_table[60] = 24'h8df989;
        log2_fraction_table[61] = 24'h8fef1f;
        log2_fraction_table[62] = 24'h91e20f;
        log2_fraction_table[63] = 24'h93d260;
        log2_fraction_table[64] = 24'h95c01a;
        log2_fraction_table[65] = 24'h97ab44;
        log2_fraction_table[66] = 24'h9993e3;
        log2_fraction_table[67] = 24'h9b7a00;
        log2_fraction_table[68] = 24'h9d5da0;
        log2_fraction_table[69] = 24'h9f3eca;
        log2_fraction_table[70] = 24'ha11d84;
        log2_fraction_table[71] = 24'ha2f9d5;
        log2_fraction_table[72] = 24'ha4d3c2;
        log2_fraction_table[73] = 24'ha6ab53;
        log2_fraction_table[74] = 24'ha8808c;
        log2_fraction_table[75] = 24'haa5374;
        log2_fraction_table[76] = 24'hac2411;
        log2_fraction_table[77] = 24'hadf268;
        log2_fraction_table[78] = 24'hafbe80;
        log2_fraction_table[79] = 24'hb1885c;
        log2_fraction_table[80] = 24'hb35004;
        log2_fraction_table[81] = 24'hb5157d;
        log2_fraction_table[82] = 24'hb6d8cb;
        log2_fraction_table[83] = 24'hb899f5;
        log2_fraction_table[84] = 24'hba58ff;
        log2_fraction_table[85] = 24'hbc15ee;
        log2_fraction_table[86] = 24'hbdd0c8;
        log2_fraction_table[87] = 24'hbf8991;
        log2_fraction_table[88] = 24'hc1404f;
        log2_fraction_table[89] = 24'hc2f506;
        log2_fraction_table[90] = 24'hc4a7ba;
        log2_fraction_table[91] = 24'hc65872;
        log2_fraction_table[92] = 24'hc80731;
        log2_fraction_table[93] = 24'hc9b3fb;
        log2_fraction_table[94] = 24'hcb5ed7;
        log2_fraction_table[95] = 24'hcd07c7;
        log2_fraction_table[96] = 24'hceaed0;
        log2_fraction_table[97] = 24'hd053f7;
        log2_fraction_table[98] = 24'hd1f740;
        log2_fraction_table[99] = 24'hd398af;
        log2_fraction_table[100] = 24'hd53848;
        log2_fraction_table[101] = 24'hd6d60f;
        log2_fraction_table[102] = 24'hd87209;
        log2_fraction_table[103] = 24'hda0c3a;
        log2_fraction_table[104] = 24'hdba4a4;
        log2_fraction_table[105] = 24'hdd3b4e;
        log2_fraction_table[106] = 24'hded039;
        log2_fraction_table[107] = 24'he0636a;
        log2_fraction_table[108] = 24'he1f4e5;
        log2_fraction_table[109] = 24'he384ad;
        log2_fraction_table[110] = 24'he512c7;
        log2_fraction_table[111] = 24'he69f35;
        log2_fraction_table[112] = 24'he829fb;
        log2_fraction_table[113] = 24'he9b31e;
        log2_fraction_table[114] = 24'heb3a9f;
        log2_fraction_table[115] = 24'hecc083;
        log2_fraction_table[116] = 24'hee44cd;
        log2_fraction_table[117] = 24'hefc781;
        log2_fraction_table[118] = 24'hf148a1;
        log2_fraction_table[119] = 24'hf2c832;
        log2_fraction_table[120] = 24'hf44636;
        log2_fraction_table[121] = 24'hf5c2b0;
        log2_fraction_table[122] = 24'hf73da4;
        log2_fraction_table[123] = 24'hf8b714;
        log2_fraction_table[124] = 24'hfa2f04;
        log2_fraction_table[125] = 24'hfba578;
        log2_fraction_table[126] = 24'hfd1a71;
        log2_fraction_table[127] = 24'hfe8df2;
    end
    function automatic logic [23:0] log2_fraction(input logic [6:0] index);
        log2_fraction = log2_fraction_table[index];
    endfunction

    typedef struct packed {
        logic signed [9:0] exponent;
        logic [6:0] fraction;
        logic [15:0] special_value;
        logic special;
    } decoded_t;
    typedef struct packed {
        logic signed [9:0] exponent;
        logic [23:0] logarithm;
        logic [15:0] special_value;
        logic special;
    } table_t;
    typedef struct packed {
        logic [31:0] magnitude;
        logic sign;
        logic [15:0] special_value;
        logic special;
    } magnitude_t;
    typedef struct packed {
        logic [31:0] magnitude;
        logic [4:0] leading_bit;
        logic sign;
        logic [15:0] special_value;
        logic special;
    } located_t;
    typedef struct packed {
        logic [15:0] value;
    } output_t;

    decoded_t decoded_d, decoded_q;
    table_t table_d, table_q;
    magnitude_t magnitude_d, magnitude_q;
    located_t located_d, located_q;
    output_t output_d, output_q;
    logic [LATENCY-1:0] valid_q;
    logic signed [32:0] fixed_logarithm;
    logic [31:0] shifted;
    logic [8:0] rounded;
    logic [8:0] biased_exponent;
    logic guard_bit, sticky_bit;

    always_comb begin
        decoded_d = '0;
        if (a[14:7] == 8'hff) begin
            decoded_d.special = 1'b1;
            decoded_d.special_value = a[6:0] != 0 || a[15] ? 16'h7fc0 : 16'h7f80;
        end else if (a[14:7] == 0) begin
            decoded_d.special = 1'b1;
            decoded_d.special_value = 16'hff80;
        end else if (a[15]) begin
            decoded_d.special = 1'b1;
            decoded_d.special_value = 16'h7fc0;
        end else begin
            decoded_d.exponent = $signed({2'b00, a[14:7]}) - 10'sd127;
            decoded_d.fraction = a[6:0];
        end
    end

    always_comb begin
        table_d = '0;
        table_d.exponent = decoded_q.exponent;
        table_d.logarithm = log2_fraction(decoded_q.fraction);
        table_d.special_value = decoded_q.special_value;
        table_d.special = decoded_q.special;
    end

    always_comb begin
        magnitude_d = '0;
        fixed_logarithm = ($signed(table_q.exponent) <<< 24) + $signed({9'b0, table_q.logarithm});
        magnitude_d.sign = fixed_logarithm < 0;
        magnitude_d.magnitude = fixed_logarithm < 0 ? 32'(-fixed_logarithm) : 32'(fixed_logarithm);
        magnitude_d.special_value = table_q.special_value;
        magnitude_d.special = table_q.special;
    end

    always_comb begin
        located_d = '0;
        located_d.magnitude = magnitude_q.magnitude;
        located_d.sign = magnitude_q.sign;
        located_d.special_value = magnitude_q.special_value;
        located_d.special = magnitude_q.special;
        for (int bit_index = 16; bit_index < 32; bit_index++)
            if (magnitude_q.magnitude[bit_index]) located_d.leading_bit = 5'(bit_index);
    end

    always_comb begin
        output_d = '0;
        shifted = '0;
        rounded = '0;
        biased_exponent = '0;
        guard_bit = 1'b0;
        sticky_bit = 1'b0;
        if (located_q.special) begin
            output_d.value = located_q.special_value;
        end else if (located_q.magnitude == 0) begin
            output_d.value = 16'h0000;
        end else begin
            case (located_q.leading_bit)
                5'd16: begin
                    shifted[7:0] = located_q.magnitude[16:9];
                    guard_bit = located_q.magnitude[8];
                    sticky_bit = |located_q.magnitude[7:0];
                end
                5'd17: begin
                    shifted[7:0] = located_q.magnitude[17:10];
                    guard_bit = located_q.magnitude[9];
                    sticky_bit = |located_q.magnitude[8:0];
                end
                5'd18: begin
                    shifted[7:0] = located_q.magnitude[18:11];
                    guard_bit = located_q.magnitude[10];
                    sticky_bit = |located_q.magnitude[9:0];
                end
                5'd19: begin
                    shifted[7:0] = located_q.magnitude[19:12];
                    guard_bit = located_q.magnitude[11];
                    sticky_bit = |located_q.magnitude[10:0];
                end
                5'd20: begin
                    shifted[7:0] = located_q.magnitude[20:13];
                    guard_bit = located_q.magnitude[12];
                    sticky_bit = |located_q.magnitude[11:0];
                end
                5'd21: begin
                    shifted[7:0] = located_q.magnitude[21:14];
                    guard_bit = located_q.magnitude[13];
                    sticky_bit = |located_q.magnitude[12:0];
                end
                5'd22: begin
                    shifted[7:0] = located_q.magnitude[22:15];
                    guard_bit = located_q.magnitude[14];
                    sticky_bit = |located_q.magnitude[13:0];
                end
                5'd23: begin
                    shifted[7:0] = located_q.magnitude[23:16];
                    guard_bit = located_q.magnitude[15];
                    sticky_bit = |located_q.magnitude[14:0];
                end
                5'd24: begin
                    shifted[7:0] = located_q.magnitude[24:17];
                    guard_bit = located_q.magnitude[16];
                    sticky_bit = |located_q.magnitude[15:0];
                end
                5'd25: begin
                    shifted[7:0] = located_q.magnitude[25:18];
                    guard_bit = located_q.magnitude[17];
                    sticky_bit = |located_q.magnitude[16:0];
                end
                5'd26: begin
                    shifted[7:0] = located_q.magnitude[26:19];
                    guard_bit = located_q.magnitude[18];
                    sticky_bit = |located_q.magnitude[17:0];
                end
                5'd27: begin
                    shifted[7:0] = located_q.magnitude[27:20];
                    guard_bit = located_q.magnitude[19];
                    sticky_bit = |located_q.magnitude[18:0];
                end
                5'd28: begin
                    shifted[7:0] = located_q.magnitude[28:21];
                    guard_bit = located_q.magnitude[20];
                    sticky_bit = |located_q.magnitude[19:0];
                end
                5'd29: begin
                    shifted[7:0] = located_q.magnitude[29:22];
                    guard_bit = located_q.magnitude[21];
                    sticky_bit = |located_q.magnitude[20:0];
                end
                5'd30: begin
                    shifted[7:0] = located_q.magnitude[30:23];
                    guard_bit = located_q.magnitude[22];
                    sticky_bit = |located_q.magnitude[21:0];
                end
                5'd31: begin
                    shifted[7:0] = located_q.magnitude[31:24];
                    guard_bit = located_q.magnitude[23];
                    sticky_bit = |located_q.magnitude[22:0];
                end
                default: begin
                    shifted = '0;
                    guard_bit = 1'b0;
                    sticky_bit = 1'b0;
                end
            endcase
            rounded = {1'b0, shifted[7:0]} + (guard_bit && (sticky_bit || shifted[0]));
            biased_exponent = {4'b0, located_q.leading_bit} + 9'd103 + rounded[8];
            output_d.value = {located_q.sign, biased_exponent[7:0], rounded[6:0]};
        end
    end

    always_ff @(posedge clk) begin
        decoded_q   <= decoded_d;
        table_q     <= table_d;
        magnitude_q <= magnitude_d;
        located_q   <= located_d;
        output_q    <= output_d;
        valid_q     <= {valid_q[LATENCY-2:0], in_valid};
    end
    assign out_valid = valid_q[LATENCY-1];
    assign result = output_q.value;
endmodule
