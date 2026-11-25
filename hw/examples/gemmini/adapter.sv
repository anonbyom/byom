// BYOM's adapter for a Gemmini mesh (meshes/, from Gemmini's generator)

package gemmini_timing;
    localparam int unsigned DIM = gemmini_mesh_cfg::DIM;

    function automatic int unsigned mesh_delay(int unsigned i);
        return (i / gemmini_mesh_cfg::TILE) * (gemmini_mesh_cfg::TILE_LATENCY + 1);
    endfunction
    function automatic int unsigned a_lag();
        int unsigned lag = 0;
        for (int unsigned i = 0; i < DIM; i++)
            if (i > mesh_delay(i) + lag) lag = i - mesh_delay(i);
        return lag;
    endfunction
    function automatic int unsigned out_lag();
        int unsigned lag = 0;
        for (int unsigned i = 0; i < DIM; i++)
            if (mesh_delay(i) > i + lag) lag = mesh_delay(i) - i;
        return lag;
    endfunction

    localparam int unsigned A_LAG        = a_lag();
    localparam int unsigned OUT_LAG      = out_lag();
    localparam int unsigned MESH_LATENCY = A_LAG + (DIM / gemmini_mesh_cfg::TILE) * (gemmini_mesh_cfg::TILE_LATENCY + 1) +
                                           gemmini_mesh_cfg::OUTPUT_DELAY + OUT_LAG;

    localparam int unsigned IN_W    = gemmini_mesh_cfg::INPUT_WIDTH;
    localparam int unsigned OUT_W   = gemmini_mesh_cfg::OUTPUT_WIDTH;
    localparam int unsigned MATMULS = gemmini_mesh_cfg::MATMULS;
    localparam int unsigned ID_W    = $clog2(MATMULS);

    typedef struct packed {
        logic [IN_W-1:0] a;
        logic [IN_W-1:0] b;
        logic [IN_W-1:0] d;
        logic            dataflow;
        logic            valid;
        logic            prop;
        logic            last;
        logic [ID_W-1:0] id;
    } fire_t;
    typedef struct packed {
        logic             valid;
        logic [ID_W-1:0]  id;
        logic [OUT_W-1:0] b;
        logic [OUT_W-1:0] c;
    } result_t;

    function automatic logic [ID_W-1:0] id_add(logic [ID_W-1:0] id, int unsigned n);
        return ID_W'((int'(id) + n) % MATMULS);
    endfunction
endpackage : gemmini_timing

module mxu
    import gemmini_timing::*;
#(
    parameter int unsigned  LANES             = 32,
    parameter int unsigned  A_FIFO_DEPTH      = 128,
    parameter int unsigned  TAG_FIFO_DEPTH    = 48,
    parameter int unsigned  PRELOAD_DEPTH     = 16,
    parameter bit           ACC_ENABLE        = 1'b0,
    parameter int unsigned  ACC_ROWS          = 1024,
    parameter bit           MX                = 1'b0,
    parameter bit           ACC_FP32          = 1'b0,
    parameter bit           E2M1              = 1'b0,
    parameter int unsigned  N_W               = 1,
    parameter int unsigned  N_A               = 1,
    parameter int unsigned  W_BITS            = 8,
    parameter int unsigned  A_BITS            = 8,
    parameter int unsigned  PROD_W            = 16,
    parameter bit           W_TWOS            = 1'b1,
    parameter int unsigned  PSUM_W            = gemmini_mesh_cfg::OUTPUT_WIDTH,
    parameter int unsigned  CODE_BITS         = 8,
    parameter int unsigned  W_CODES           = 1,
    parameter bit           TILE_MODES        = 1'b0,
    parameter bit           BANK_FREE_AT_LOAD = 1'b0,
    parameter int unsigned  A_WORD_ROWS       = N_A,     // a MATMUL word's rows (vector_mxu's); unused
    parameter int unsigned  DATAFLOW          = 1,
    parameter int unsigned  B_QUEUE_DEPTH     = 64,
    parameter int unsigned  FLUSH_WAIT        = 4,
    localparam bit          WS                = DATAFLOW[0],
    localparam bit          OS                = DATAFLOW[1],
    localparam int unsigned BF16_WIDTH        = 16
) (
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  dataflow_os,

    input  logic                  b_valid       [DIM],
    input  logic [IN_W-1:0]       b_data        [DIM],
    input  logic                  b_bank        [DIM],
    output logic                  b_freed,
    output logic                  b_freed_bank,

    input  logic                  matmul_valid,
    output logic                  matmul_ready,
    input  logic                  matmul_preload,
    input  logic                  matmul_bank,
    input  logic [1:0]            matmul_mode,
    input  logic                  a_valid       [DIM],
    output logic                  a_ready       [DIM],
    input  logic [IN_W-1:0]       a_data        [DIM],

    output logic                  psum_valid    [DIM],
    output logic [BF16_WIDTH-1:0] psum_data     [DIM]
);
    if (gemmini_mesh_cfg::DIM != DIM || LANES != DIM) begin : gen_bad_dim
        $fatal(1, "mxu_gemmini: the installed Gemmini mesh is not %0dx%0d", DIM, DIM);
    end
    if (IN_W != 8) begin : gen_bad_input
        $fatal(1, "mxu_gemmini: packed INT8 operands need an 8-bit inputType, the mesh's is %0d bits", IN_W);
    end
    if (E2M1 || N_A != 1 || CODE_BITS != IN_W) begin : gen_bad_shape
        $fatal(1, "mxu_gemmini: the mesh takes one %0d-bit integer row per beat", IN_W);
    end
    if (!WS && !OS) begin : gen_bad_dataflow
        $fatal(1, "mxu_gemmini: no dataflow");
    end
    if (MX || ACC_FP32) begin : gen_bad_mx
        $fatal(1, "mxu_gemmini: the mesh's integer sums take no E8M0 scales (MX) and no FP32 accumulation (ACC_FP32)");
    end
    if (W_BITS != IN_W || A_BITS != IN_W || PROD_W != 2 * IN_W || PSUM_W != gemmini_mesh_cfg::OUTPUT_WIDTH)
    begin : gen_bad_widths
        $fatal(1, "mxu_gemmini: the socket's operands (%0d / %0d bits, %0d-bit products, %0d-bit sums) are not the mesh's (%0d, %0d)",
               W_BITS, A_BITS, PROD_W, PSUM_W, IN_W, gemmini_mesh_cfg::OUTPUT_WIDTH);
    end

    // This unit's socket terms where they differ from vector_mxu.sv's defaults
    localparam string       SOCKET_LEVEL     = "unit";
    localparam string       SOCKET_FAMILY    = "gemmini";
    localparam int unsigned SOCKET_TILE      = gemmini_mesh_cfg::TILE;
    localparam int unsigned SOCKET_IN_FLIGHT = MATMULS;
    localparam string       TARGET_MXU_OPERANDS = "int8";
    localparam string       ARITH_KIND          = "int";
    localparam int unsigned ARITH_W_BITS        = IN_W;
    localparam int unsigned ARITH_A_BITS        = IN_W;
    localparam int unsigned ARITH_N_W           = 1;
    localparam int unsigned ARITH_N_A           = 1;
    localparam bit          ARITH_FULL_NEG      = 1'b1;
    localparam int unsigned ARITH_SUM_BITS      = OUT_W;

    fire_t           fire   [DIM];
    result_t         result [DIM];
    logic            tag_push;
    logic [ID_W-1:0] tag_id;
    logic            room;

    logic            os;
    logic            sel_b_valid   [2][DIM];
    logic            sel_a_valid   [2][DIM];
    logic            sel_matmul    [2];
    logic            sel_ready     [2];
    logic            sel_a_ready   [2][DIM];
    logic            sel_freed     [2];
    logic            sel_freed_bank [2];
    logic            sel_psum_valid [2][DIM];
    logic [BF16_WIDTH-1:0] sel_psum_data [2][DIM];
    fire_t           sel_fire      [2][DIM];
    logic            sel_tag_push  [2];
    logic [ID_W-1:0] sel_tag_id    [2];

    logic [1:0] os_q;
    always_ff @(posedge clk) os_q <= {os_q[0], dataflow_os};
    assign os = OS && (!WS || os_q[1]);
    for (genvar s = 0; s < 2; s++) begin : gen_select
        assign sel_matmul[s] = matmul_valid && os == 1'(s);
        for (genvar lane = 0; lane < DIM; lane++) begin : gen_lane
            assign sel_b_valid[s][lane] = b_valid[lane] && os == 1'(s);
            assign sel_a_valid[s][lane] = a_valid[lane] && os == 1'(s);
        end
    end
    assign matmul_ready = sel_ready[os];
    assign b_freed      = sel_freed[os];
    assign b_freed_bank = sel_freed_bank[os];
    assign a_ready      = sel_a_ready[os];
    assign psum_valid   = sel_psum_valid[os];
    assign psum_data    = sel_psum_data[os];
    assign fire         = sel_fire[os];
    assign tag_push     = sel_tag_push[os];
    assign tag_id       = sel_tag_id[os];

    if (WS) begin : gen_ws
        gemmini_ws #(
            .A_FIFO_DEPTH(A_FIFO_DEPTH),
            .TAG_FIFO_DEPTH(TAG_FIFO_DEPTH),
            .PRELOAD_DEPTH(PRELOAD_DEPTH),
            .ACC_ENABLE(ACC_ENABLE),
            .ACC_ROWS(ACC_ROWS)
        ) u_dataflow (
            .clk,
            .rst          (rst || os),
            .b_valid      (sel_b_valid[0]),
            .b_data,
            .b_bank,
            .b_freed      (sel_freed[0]),
            .b_freed_bank (sel_freed_bank[0]),
            .matmul_valid (sel_matmul[0]),
            .matmul_ready (sel_ready[0]),
            .matmul_preload,
            .matmul_bank,
            .matmul_mode,
            .a_valid      (sel_a_valid[0]),
            .a_ready      (sel_a_ready[0]),
            .a_data,
            .psum_valid   (sel_psum_valid[0]),
            .psum_data    (sel_psum_data[0]),
            .fire         (sel_fire[0]),
            .tag_push     (sel_tag_push[0]),
            .tag_id       (sel_tag_id[0]),
            .room,
            .result
        );
    end else begin : gen_no_ws
        assign sel_ready[0] = 1'b0;
        assign sel_freed[0] = 1'b0;
        assign sel_freed_bank[0] = 1'b0;
        assign sel_a_ready[0] = '{default: 1'b0};
        assign sel_psum_valid[0] = '{default: 1'b0};
        assign sel_psum_data[0] = '{default: '0};
        assign sel_fire[0] = '{default: '0};
        assign sel_tag_push[0] = 1'b0;
        assign sel_tag_id[0] = '0;
    end

    if (OS) begin : gen_os
        gemmini_os #(
            .B_QUEUE_DEPTH(B_QUEUE_DEPTH),
            .FLUSH_WAIT(FLUSH_WAIT),
            .OUTPUT_REG(WS)
        ) u_dataflow (
            .clk,
            .rst          (rst || !os),
            .b_valid      (sel_b_valid[1]),
            .b_data,
            .b_freed      (sel_freed[1]),
            .b_freed_bank (sel_freed_bank[1]),
            .matmul_valid (sel_matmul[1]),
            .matmul_ready (sel_ready[1]),
            .matmul_mode,
            .a_valid      (sel_a_valid[1]),
            .a_ready      (sel_a_ready[1]),
            .a_data,
            .psum_valid   (sel_psum_valid[1]),
            .psum_data    (sel_psum_data[1]),
            .fire         (sel_fire[1]),
            .tag_push     (sel_tag_push[1]),
            .tag_id       (sel_tag_id[1]),
            .room,
            .result
        );
    end else begin : gen_no_os
        assign sel_ready[1] = 1'b0;
        assign sel_freed[1] = 1'b0;
        assign sel_freed_bank[1] = 1'b0;
        assign sel_a_ready[1] = '{default: 1'b0};
        assign sel_psum_valid[1] = '{default: 1'b0};
        assign sel_psum_data[1] = '{default: '0};
        assign sel_fire[1] = '{default: '0};
        assign sel_tag_push[1] = 1'b0;
        assign sel_tag_id[1] = '0;
    end

    gemmini_mesh u_mesh (
        .clk,
        .rst,
        .fire,
        .tag_push,
        .tag_id,
        .room,
        .result
    );
endmodule : mxu

module gemmini_mesh
    import gemmini_timing::*;
#(
    localparam int unsigned TAGS = MATMULS + 1
) (
    input  logic            clk,
    input  logic            rst,
    input  fire_t           fire   [DIM],
    input  logic            tag_push,
    input  logic [ID_W-1:0] tag_id,
    output logic            room,
    output result_t         result [DIM]
);

    logic [DIM*IN_W-1:0]  flat_a, flat_b, flat_d;
    logic [DIM-1:0]       flat_dataflow, flat_valid, flat_prop, flat_last, flat_out_valid, flat_out_last;
    logic [DIM*ID_W-1:0]  flat_id, flat_out_id;
    logic [DIM*OUT_W-1:0] flat_out_b, flat_out_c;

    for (genvar i = 0; i < DIM; i++) begin : gen_in
        fire_t skewed;
        shifter #(
            .WIDTH($bits(fire_t)),
            .LENGTH(A_LAG + mesh_delay(i) - i)
        ) u_skew (
            .clk,
            .rst,
            .en (1'b1),
            .d  (fire[i]),
            .q  (skewed)
        );
        assign flat_a[IN_W*i +: IN_W] = skewed.a;
        assign flat_b[IN_W*i +: IN_W] = skewed.b;
        assign flat_d[IN_W*i +: IN_W] = skewed.d;
        assign flat_dataflow[i]       = skewed.dataflow;
        assign flat_valid[i]          = skewed.valid;
        assign flat_prop[i]           = skewed.prop;
        assign flat_last[i]           = skewed.last;
        assign flat_id[ID_W*i +: ID_W] = skewed.id;
    end

    gemmini_FlatMesh u_mesh (
        .clock            (clk),
        .reset            (rst),
        .io_in_a          (flat_a),
        .io_in_b          (flat_b),
        .io_in_d          (flat_d),
        .io_in_dataflow   (flat_dataflow),
        .io_in_propagate  (flat_prop),
        .io_in_shift      ('0),
        .io_in_id         (flat_id),
        .io_in_last       (flat_last),
        .io_in_valid      (flat_valid),
        .io_out_b         (flat_out_b),
        .io_out_c         (flat_out_c),
        .io_out_dataflow  (),
        .io_out_propagate (),
        .io_out_shift     (),
        .io_out_id        (flat_out_id),
        .io_out_last      (flat_out_last),
        .io_out_valid     (flat_out_valid)
    );

    for (genvar c = 0; c < DIM; c++) begin : gen_out
        shifter #(
            .WIDTH($bits(result_t)),
            .LENGTH(OUT_LAG + c - mesh_delay(c))
        ) u_skew (
            .clk,
            .rst,
            .en (1'b1),
            .d  (result_t'{flat_out_valid[c], flat_out_id[ID_W*c +: ID_W], flat_out_b[OUT_W*c +: OUT_W],
                flat_out_c[OUT_W*c +: OUT_W]}),
            .q  (result[c])
        );
    end

    logic [ID_W-1:0]           tagq_id [TAGS];
    logic [$clog2(TAGS)-1:0]   tagq_raddr_q;
    logic [$clog2(TAGS)-1:0]   tagq_waddr_q;
    logic [$clog2(TAGS+1)-1:0] tagq_len_q;
    logic                      tagq_deq;
    logic                      done;
    logic [ID_W-1:0]           done_id;

    assign done     = flat_out_valid[DIM-1] && flat_out_last[DIM-1];
    assign done_id  = flat_out_id[ID_W*(DIM-1) +: ID_W];
    assign room     = tagq_len_q != ($bits(tagq_len_q))'(TAGS);
    assign tagq_deq = done && tagq_len_q != '0 && done_id == tagq_id[tagq_raddr_q];

    always_ff @(posedge clk) begin
        if (rst) begin
            tagq_raddr_q <= '0;
            tagq_waddr_q <= '0;
            tagq_len_q   <= '0;
        end else begin
            if (tag_push) tagq_waddr_q <= tagq_waddr_q == ($bits(tagq_waddr_q))'(TAGS - 1) ? '0 : tagq_waddr_q + 1'b1;
            if (tagq_deq) tagq_raddr_q <= tagq_raddr_q == ($bits(tagq_raddr_q))'(TAGS - 1) ? '0 : tagq_raddr_q + 1'b1;
            tagq_len_q <= tagq_len_q + ($bits(tagq_len_q))'(tag_push) - ($bits(tagq_len_q))'(tagq_deq);
        end
        if (tag_push) tagq_id[tagq_waddr_q] <= tag_id;
    end
endmodule : gemmini_mesh

module gemmini_ws
    import gemmini_timing::*;
#(
    parameter int unsigned  A_FIFO_DEPTH   = 128,
    parameter int unsigned  TAG_FIFO_DEPTH = 48,
    parameter int unsigned  PRELOAD_DEPTH  = 16,
    parameter bit           ACC_ENABLE     = 1'b0,
    parameter int unsigned  ACC_ROWS       = 1024,
    localparam int unsigned BF16_WIDTH     = 16,
    localparam int unsigned IDX_W          = 8,
    localparam int unsigned LEN_W          = $clog2(DIM + 1),
    localparam int unsigned TAG_W          = 3
) (
    input  logic                  clk,
    input  logic                  rst,

    input  logic                  b_valid       [DIM],
    input  logic [IN_W-1:0]       b_data        [DIM],
    input  logic                  b_bank        [DIM],
    output logic                  b_freed,
    output logic                  b_freed_bank,

    input  logic                  matmul_valid,
    output logic                  matmul_ready,
    input  logic                  matmul_preload,
    input  logic                  matmul_bank,
    input  logic [1:0]            matmul_mode,
    input  logic                  a_valid       [DIM],
    output logic                  a_ready       [DIM],
    input  logic [IN_W-1:0]       a_data        [DIM],

    output logic                  psum_valid    [DIM],
    output logic [BF16_WIDTH-1:0] psum_data     [DIM],

    output fire_t                 fire          [DIM],
    output logic                  tag_push,
    output logic [ID_W-1:0]       tag_id,
    input  logic                  room,
    input  result_t               result        [DIM]
);
    localparam int unsigned REQUEST_ROWS          = 4;
    localparam int unsigned OUTPUT_DELAY          = ACC_ENABLE ? 7 : 2;     // mxu_output's: accumulating, or straight to BF16
    localparam int unsigned SOCKET_SCHEDULE       = REQUEST_ROWS - 1;
    localparam int unsigned SOCKET_RESULT_DELAY   = SOCKET_SCHEDULE + MESH_LATENCY + OUTPUT_DELAY;
    localparam int unsigned SOCKET_FEED_START     = 2;
    localparam int unsigned SOCKET_PRELOAD_LAUNCH = SOCKET_FEED_START + DIM;
    localparam bit          SOCKET_WEIGHT_STREAM  = 1'b0;
    localparam int unsigned SOCKET_WEIGHT_READY   = DIM - 1 + 3;

    logic                matmul_accept;
    logic [TAG_W-1:0]    tag_data;
    logic                tag_valid;
    logic                tag_wrdy;
    logic                tag_pop;
    logic                pre_wrdy;
    logic                pre_valid;
    logic                pre_bank;
    logic [IDX_W-1:0]    pre_idx;
    logic                pre_pop;
    logic [IDX_W-1:0]    in_idx_q;
    logic [IDX_W-1:0]    stage_idx_q;

    assign matmul_ready  = tag_wrdy && (!matmul_preload || pre_wrdy);
    assign matmul_accept = matmul_valid && matmul_ready;

    fifo #(
        .DATA_WIDTH(TAG_W),
        .DEPTH(TAG_FIFO_DEPTH),
        .READ_READY_BYPASS(1'b0)
    ) u_tag (
        .clk,
        .rst,
        .w_en    (matmul_accept),
        .w_data  ({matmul_mode, matmul_preload}),
        .w_rdy   (tag_wrdy),
        .r_en    (tag_pop),
        .r_data  (tag_data),
        .r_valid (tag_valid),
        .level   ()
    );
    fifo #(
        .DATA_WIDTH(1 + IDX_W),
        .DEPTH(PRELOAD_DEPTH),
        .READ_READY_BYPASS(1'b0)
    ) u_preload (
        .clk,
        .rst,
        .w_en    (matmul_accept && matmul_preload),
        .w_data  ({matmul_bank, in_idx_q}),
        .w_rdy   (pre_wrdy),
        .r_en    (pre_pop),
        .r_data  ({pre_bank, pre_idx}),
        .r_valid (pre_valid),
        .level   ()
    );

    always_ff @(posedge clk) begin
        if (rst) in_idx_q <= '0;
        else if (matmul_accept) in_idx_q <= in_idx_q + 1'b1;
    end

    logic                a_wave  [DIM];
    logic [IN_W-1:0]     a_head  [DIM];
    logic                a_head_valid [DIM];
    logic [IN_W-1:0]     b_head  [2][DIM];
    logic                b_head_valid [2][DIM];
    logic                b_full  [2][DIM];
    logic                bank_full_q [2];
    logic                feed_wave [DIM];
    logic                bank_wave [DIM];

    for (genvar lane = 0; lane < DIM; lane++) begin : gen_lane
        logic                  a_code_valid_q;
        logic [IN_W-1:0]       a_code_q;
        logic                  a_fifo_rdy;
        logic                  b_valid_q;
        logic                  b_bank_q;
        logic [IN_W-1:0]       b_code_q;

        assign a_ready[lane] = !a_code_valid_q || a_fifo_rdy;
        always_ff @(posedge clk) begin
            if (rst) begin
                a_code_valid_q <= 1'b0;
                b_valid_q      <= 1'b0;
            end else begin
                if (a_ready[lane]) a_code_valid_q <= a_valid[lane];
                b_valid_q <= b_valid[lane];
            end
            if (a_ready[lane] && a_valid[lane]) a_code_q <= a_data[lane];
            b_bank_q <= b_bank[lane];
            b_code_q <= b_data[lane];
        end

        fifo #(
            .DATA_WIDTH(IN_W),
            .DEPTH(A_FIFO_DEPTH),
            .READ_READY_BYPASS(1'b0)
        ) u_a (
            .clk,
            .rst,
            .w_en    (a_code_valid_q && a_fifo_rdy),
            .w_data  (a_code_q),
            .w_rdy   (a_fifo_rdy),
            .r_en    (a_wave[lane]),
            .r_data  (a_head[lane]),
            .r_valid (a_head_valid[lane]),
            .level   ()
        );

        for (genvar bank = 0; bank < 2; bank++) begin : gen_bank
            logic [LEN_W-1:0] level;
            fifo #(
                .DATA_WIDTH(IN_W),
                .DEPTH(DIM)
            ) u_b (
                .clk,
                .rst,
                .w_en    (b_valid_q && b_bank_q == 1'(bank)),
                .w_data  (b_code_q),
                .w_rdy   (),
                .r_en    (feed_wave[lane] && bank_wave[lane] == 1'(bank)),
                .r_data  (b_head[bank][lane]),
                .r_valid (b_head_valid[bank][lane]),
                .level   (level)
            );
            assign b_full[bank][lane] = level == LEN_W'(DIM);
        end
    end

    for (genvar bank = 0; bank < 2; bank++) begin : gen_bank_full
        always_ff @(posedge clk) begin
            if (rst) bank_full_q[bank] <= 1'b0;
            else begin
                bank_full_q[bank] <= 1'b1;
                for (int unsigned lane = 0; lane < DIM; lane++)
                    if (!b_full[bank][lane]) bank_full_q[bank] <= 1'b0;
            end
        end
    end

    logic                in_prop_q;
    logic [ID_W-1:0]     matmul_id_q;
    logic                tagq_enq;
    logic                req_room;

    logic [IDX_W-1:0]    until_pre;
    logic [IDX_W-1:0]    avail;
    logic                at_preload;
    logic                feed_active_q;
    logic                feed_bank_q;
    logic [LEN_W-1:0]    feed_count_q;
    logic                shadow_full_q;
    logic                feed_start;
    logic                feeding;
    logic                feed_bank;
    logic [LEN_W-1:0]    feed_count;
    logic                feed_last;
    logic [LEN_W-1:0]    rows_left_q;
    logic                req_pad_q;
    logic                start_flip;
    logic                start_pad;
    logic                start_compute;
    logic                starting;
    logic [LEN_W-1:0]    req_len;
    logic                row_pad;
    logic                row_go;
    logic                row_prop;
    logic [ID_W-1:0]     row_id;
    logic                row_last;

    assign until_pre  = pre_idx - stage_idx_q;
    assign avail      = (pre_valid ? pre_idx : in_idx_q) - stage_idx_q;
    assign at_preload = pre_valid && until_pre == '0;

    assign feed_start = !feed_active_q && !shadow_full_q && pre_valid && bank_full_q[pre_bank] &&
                        until_pre <= IDX_W'(DIM) && until_pre[1:0] == 2'b00;
    assign feeding    = feed_active_q || feed_start;
    assign feed_bank  = feed_active_q ? feed_bank_q : pre_bank;
    assign feed_count = feed_active_q ? feed_count_q : '0;
    assign feed_last  = row_go && feeding && feed_count == LEN_W'(DIM - 1);

    assign start_flip    = rows_left_q == '0 && at_preload && shadow_full_q;
    assign start_pad     = rows_left_q == '0 && at_preload && !shadow_full_q && feeding;
    assign start_compute = rows_left_q == '0 && !at_preload && avail >= IDX_W'(4);
    assign starting      = (start_flip || start_pad || start_compute) && req_room;
    assign req_len       = start_flip ? LEN_W'(4) : start_pad ? LEN_W'(DIM) - feed_count :
                           avail >= IDX_W'(DIM) ? LEN_W'(DIM) : LEN_W'({avail[IDX_W-1:2], 2'b00});

    assign row_pad  = rows_left_q == '0 ? start_pad : req_pad_q;
    assign row_go   = (rows_left_q != '0 || starting) && (row_pad || (tag_valid && a_head_valid[0]));
    assign tag_pop  = row_go && !row_pad;
    assign pre_pop  = row_go && start_flip;
    assign tagq_enq = row_go && rows_left_q == '0;

    assign row_prop = rows_left_q == '0 ? in_prop_q ^ start_flip : in_prop_q;
    assign row_id   = rows_left_q == '0 ? id_add(matmul_id_q, 1) : matmul_id_q;
    assign row_last = rows_left_q == '0 ? req_len == LEN_W'(1) : rows_left_q == LEN_W'(1);

    always_ff @(posedge clk) begin
        if (rst) begin
            stage_idx_q   <= '0;
            feed_active_q <= 1'b0;
            feed_bank_q   <= 1'b0;
            feed_count_q  <= '0;
            shadow_full_q <= 1'b0;
            rows_left_q   <= '0;
            req_pad_q     <= 1'b0;
            in_prop_q     <= 1'b0;
            matmul_id_q   <= '0;
        end else if (row_go) begin
            if (!row_pad) stage_idx_q <= stage_idx_q + 1'b1;
            if (rows_left_q == '0) begin
                rows_left_q <= req_len - 1'b1;
                req_pad_q   <= start_pad;
                in_prop_q   <= row_prop;
                matmul_id_q <= row_id;
            end else begin
                rows_left_q <= rows_left_q - 1'b1;
            end
            if (start_flip) shadow_full_q <= 1'b0;
            if (feeding) begin
                feed_bank_q <= feed_bank;
                if (feed_last) begin
                    feed_active_q <= 1'b0;
                    feed_count_q  <= '0;
                    shadow_full_q <= 1'b1;
                end else begin
                    feed_active_q <= 1'b1;
                    feed_count_q  <= feed_count + 1'b1;
                end
            end
        end
    end

    shifter #(
        .WIDTH(2),
        .LENGTH(DIM)
    ) u_freed (
        .clk,
        .rst,
        .en (1'b1),
        .d  ({feed_last, feed_bank}),
        .q  ({b_freed, b_freed_bank})
    );

    localparam int unsigned COL_W = 5 + ID_W;
    logic [COL_W-1:0] col_wave [DIM];
    logic             prop_wave [DIM];
    logic [ID_W-1:0]  id_wave [DIM];
    logic             last_wave [DIM];
    logic             valid_wave [DIM];

    shifter_taps #(
        .WIDTH(1),
        .LENGTH(DIM - 1)
    ) u_a_wave (
        .clk,
        .rst,
        .en (1'b1),
        .d  (row_go && !row_pad),
        .q  (a_wave)
    );
    shifter_taps #(
        .WIDTH(COL_W),
        .LENGTH(DIM - 1)
    ) u_col_wave (
        .clk,
        .rst,
        .en (1'b1),
        .d  ({row_go, row_go && feeding, feed_bank, row_prop, row_id, row_last}),
        .q  (col_wave)
    );

    logic [OUT_W-1:0]     mesh_out_b     [DIM];
    logic                 mesh_out_valid [DIM];

    for (genvar i = 0; i < DIM; i++) begin : gen_mesh
        assign {valid_wave[i], feed_wave[i], bank_wave[i], prop_wave[i], id_wave[i], last_wave[i]} = col_wave[i];
        assign fire[i] = '{a: a_wave[i] ? a_head[i] : '0, b: '0, d: feed_wave[i] ? b_head[bank_wave[i]][i] : '0,
                           dataflow: 1'b1, valid: valid_wave[i], prop: prop_wave[i], last: last_wave[i], id: id_wave[i]};
        assign mesh_out_valid[i] = result[i].valid;
        assign mesh_out_b[i]     = result[i].b;
    end
    assign tag_push = tagq_enq;
    assign tag_id   = id_add(matmul_id_q, 2);
    assign req_room = room;

    localparam int unsigned ACC_READ_LEAD = 2;
    logic [4:0] ctrl_first_col;
    logic [4:0] ctrl [DIM];

    shifter #(
        .WIDTH(5),
        .LENGTH(MESH_LATENCY - ACC_READ_LEAD)
    ) u_ctrl_delay (
        .clk,
        .rst,
        .en (1'b1),
        .d  ({row_go, row_go && !row_pad, start_flip, tag_data[2:1]}),
        .q  (ctrl_first_col)
    );
    shifter_taps #(
        .WIDTH(5),
        .LENGTH(DIM - 1)
    ) u_ctrl_stagger (
        .clk,
        .rst,
        .en (1'b1),
        .d  (ctrl_first_col),
        .q  (ctrl)
    );

    for (genvar col = 0; col < DIM; col++) begin : gen_output
        logic             fired;
        logic             product_valid;
        logic [OUT_W-1:0] product [1];

        shifter #(
            .WIDTH(2),
            .LENGTH(ACC_READ_LEAD)
        ) u_product_valid (
            .clk,
            .rst,
            .en (1'b1),
            .d  (ctrl[col][4:3]),
            .q  ({fired, product_valid})
        );

        assign product[0] = mesh_out_b[col];

        mxu_output #(
            .ROWS(1),
            .IN_W(OUT_W),
            .ACC_ENABLE(ACC_ENABLE),
            .ACC_ROWS(ACC_ROWS)
        ) u_output (
            .clk,
            .rst,
            .ctrl_valid (ctrl[col][3]),
            .ctrl_first (ctrl[col][2]),
            .ctrl_mode  (ctrl[col][1:0]),
            .product_valid,
            .product,
            .psum_valid (psum_valid[col]),
            .psum_data  (psum_data[col])
        );
    end
endmodule : gemmini_ws

module gemmini_os
    import gemmini_timing::*;
#(
    parameter int unsigned  B_QUEUE_DEPTH = 64,
    parameter int unsigned  FLUSH_WAIT    = 4,
    parameter bit           OUTPUT_REG    = 1'b0,
    localparam int unsigned BF16_WIDTH    = 16,
    localparam int unsigned WORD_ROWS     = 8,
    localparam int unsigned BEAT_W        = $clog2(WORD_ROWS),
    localparam int unsigned FIRE_W        = $clog2(DIM)
) (
    input  logic                  clk,
    input  logic                  rst,

    input  logic                  b_valid       [DIM],
    input  logic [IN_W-1:0]       b_data        [DIM],
    output logic                  b_freed,
    output logic                  b_freed_bank,

    input  logic                  matmul_valid,
    output logic                  matmul_ready,
    input  logic [1:0]            matmul_mode,
    input  logic                  a_valid       [DIM],
    output logic                  a_ready       [DIM],
    input  logic [IN_W-1:0]       a_data        [DIM],

    output logic                  psum_valid    [DIM],
    output logic [BF16_WIDTH-1:0] psum_data     [DIM],

    output fire_t                 fire          [DIM],
    output logic                  tag_push,
    output logic [ID_W-1:0]       tag_id,
    input  logic                  room,
    input  result_t               result        [DIM]
);
    localparam logic [1:0] FIRST = 2'd1, LAST = 2'd3;

    localparam int unsigned SOCKET_OS_DRAIN_FLUSH = 1 + FLUSH_WAIT;
    localparam int unsigned SOCKET_OS_DRAIN       = MESH_LATENCY + 1 + OUTPUT_REG;

    logic [IN_W-1:0] b_head [DIM];
    logic            b_head_valid [DIM];
    logic            data_wave [DIM];

    for (genvar lane = 0; lane < DIM; lane++) begin : gen_queue
        logic [$clog2(B_QUEUE_DEPTH+1)-1:0] b_level;
        fifo #(
            .DATA_WIDTH(IN_W),
            .DEPTH(B_QUEUE_DEPTH)
        ) u_b (
            .clk,
            .rst,
            .w_en    (b_valid[lane]),
            .w_data  (b_data[lane]),
            .w_rdy   (),
            .r_en    (data_wave[lane]),
            .r_data  (b_head[lane]),
            .r_valid (b_head_valid[lane]),
            .level   (b_level)
        );
        assign a_ready[lane] = data_wave[lane];
    end

    logic [BEAT_W-1:0] beat_q;
    logic [FIRE_W-1:0] fires_q;
    logic              in_block_q;
    logic              flushing_q;
    logic              init_q;
    logic              pending_q;
    logic              tile_real_q;
    logic [$clog2(FLUSH_WAIT+1)-1:0] idle_q;
    logic              in_prop_q;
    logic [ID_W-1:0]   matmul_id_q;
    logic              drains_q [MATMULS];

    logic       req_start, heads, data_ready, data_go, flush_start, flush_go, go;
    logic       block_start, block_end, flip;
    logic       row_prop, row_last;
    logic [ID_W-1:0] row_id;

    assign req_start   = fires_q == '0;
    assign heads       = a_valid[0] && b_head_valid[0] && matmul_valid;
    assign data_ready  = !rst && heads && !flushing_q && !init_q && (!req_start || room);
    assign flush_start = !rst && !flushing_q && req_start && !in_block_q && !data_ready &&
                         (init_q || pending_q && idle_q == ($bits(idle_q))'(FLUSH_WAIT));
    assign data_go     = data_ready;
    assign flush_go    = flushing_q || flush_start;
    assign go          = data_go || flush_go;
    assign block_start = data_go && beat_q == '0 && matmul_mode == FIRST;
    assign block_end   = data_go && beat_q == BEAT_W'(WORD_ROWS - 1) && matmul_mode == LAST;
    assign flip        = block_start || flush_start;

    assign row_prop = flip ? !in_prop_q : in_prop_q;
    assign row_id   = req_start ? id_add(matmul_id_q, 1) : matmul_id_q;
    assign row_last = fires_q == FIRE_W'(DIM - 1);
    assign tag_push = data_go && req_start;
    assign tag_id   = row_id;

    assign matmul_ready = data_go;
    assign b_freed      = data_go && beat_q == BEAT_W'(WORD_ROWS - 1);
    assign b_freed_bank = 1'b0;

    always_ff @(posedge clk) begin
        if (rst) begin
            beat_q      <= '0;
            fires_q     <= '0;
            in_block_q  <= 1'b0;
            flushing_q  <= 1'b0;
            init_q      <= 1'b1;
            pending_q   <= 1'b0;
            tile_real_q <= 1'b0;
            idle_q      <= '0;
            in_prop_q   <= 1'b0;
            matmul_id_q <= '0;
        end else begin
            if (data_go) beat_q <= beat_q + 1'b1;
            if (go) begin
                fires_q <= row_last ? '0 : fires_q + 1'b1;
                in_prop_q <= row_prop;
                matmul_id_q <= row_id;
            end
            if (flush_start) begin
                init_q     <= 1'b0;
                flushing_q <= 1'b1;
            end else if (flushing_q && row_last) begin
                flushing_q <= 1'b0;
            end
            if (block_start) in_block_q <= 1'b1;
            if (block_end) in_block_q <= 1'b0;
            if (flip) tile_real_q <= block_start;
            if (flip) pending_q <= 1'b0;
            else if (block_end) pending_q <= 1'b1;
            if (go || !pending_q) idle_q <= '0;
            else if (idle_q != ($bits(idle_q))'(FLUSH_WAIT)) idle_q <= idle_q + 1'b1;
        end
        if (go && req_start) drains_q[row_id] <= flip && tile_real_q;
    end

    localparam int unsigned COL_W = 4 + ID_W;
    logic [COL_W-1:0] col_wave [DIM];
    shifter_taps #(
        .WIDTH(COL_W),
        .LENGTH(DIM - 1)
    ) u_col_wave (
        .clk,
        .rst,
        .en (1'b1),
        .d  ({go, data_go, row_prop, row_last, row_id}),
        .q  (col_wave)
    );

    for (genvar i = 0; i < DIM; i++) begin : gen_mesh_in
        logic            valid_w, prop_w, last_w;
        logic [ID_W-1:0] id_w;
        assign {valid_w, data_wave[i], prop_w, last_w, id_w} = col_wave[i];
        assign fire[i] = '{a: data_wave[i] ? a_data[i] : '0, b: data_wave[i] ? b_head[i] : '0, d: '0,
                           dataflow: 1'b0, valid: valid_w, prop: prop_w, last: last_w, id: id_w};
    end

    for (genvar c = 0; c < DIM; c++) begin : gen_result
        logic result_q;
        always_ff @(posedge clk) begin
            if (rst) result_q <= 1'b0;
            else result_q <= result[c].valid && drains_q[result[c].id];
        end
        logic [BF16_WIDTH-1:0] bf16;
        int_to_bf16 #(
            .WIDTH(OUT_W)
        ) u_bf16 (
            .clk,
            .value (result[c].c),
            .bf16
        );
        if (OUTPUT_REG) begin : gen_output_reg
            logic                  valid_q;
            logic [BF16_WIDTH-1:0] data_q;
            always_ff @(posedge clk) begin
                if (rst) valid_q <= 1'b0;
                else valid_q <= result_q;
                data_q <= bf16;
            end
            assign psum_valid[c] = valid_q;
            assign psum_data[c]  = data_q;
        end else begin : gen_output
            assign psum_valid[c] = result_q;
            assign psum_data[c]  = bf16;
        end
    end

    initial begin
        if (IN_W != 8) $fatal(1, "gemmini_os: packed INT8 words of %0d K rows", WORD_ROWS);
        if (DIM % WORD_ROWS != 0) $fatal(1, "gemmini_os: DIM must be a multiple of %0d", WORD_ROWS);
    end
endmodule : gemmini_os
