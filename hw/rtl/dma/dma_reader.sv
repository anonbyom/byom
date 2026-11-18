module dma_reader #(
    parameter int unsigned           AXI_ADDR_W           = 64,
    parameter int unsigned           AXI_BYTES            = 64,
    parameter int unsigned           LOCAL_DEPTH          = 1024,
    parameter int unsigned           LOCAL_WR_PORTS       = 3,
    parameter int unsigned           FIFO_DEPTH           = 4,
    parameter logic [AXI_ADDR_W-1:0] BASE_ADDR            = '0,
    parameter logic [LOCAL_WR_PORTS-1:0] SERIALIZED_PORTS = '0,

    localparam int unsigned AXI_DATA_W     = 8 * AXI_BYTES,
    localparam int unsigned COUNT_W        = $clog2(LOCAL_DEPTH + 1),
    localparam int unsigned LOCAL_WR_SEL_W = LOCAL_WR_PORTS > 1 ? $clog2(LOCAL_WR_PORTS) : 1,
    // Half the FIFO, so the next burst is in flight while the previous one drains.
    localparam int unsigned PIECE_BEATS    = FIFO_DEPTH > 1 ? FIFO_DEPTH / 2 : 1,
    localparam int unsigned AXI_SIZE       = $clog2(AXI_BYTES),
    localparam int unsigned PAGE_W         = 12
) (
    input  logic                      clk,
    input  logic                      rst,

    input  logic                      req_valid,
    output logic                      req_ready,
    input  logic [AXI_ADDR_W-1:0]     req_addr,
    input  logic [COUNT_W-1:0]        req_words,
    input  logic [LOCAL_WR_SEL_W-1:0] req_local_sel,
    output logic                      done,

    output logic                      local_write_valid [LOCAL_WR_PORTS],
    input  logic                      local_write_ready [LOCAL_WR_PORTS],
    output logic [AXI_DATA_W-1:0]     local_write_data  [LOCAL_WR_PORTS],

    output logic                      m_arvalid,
    input  logic                      m_arready,
    output logic [AXI_ADDR_W-1:0]     m_araddr,
    output logic [7:0]                m_arlen,
    output logic [2:0]                m_arsize,
    output axi_pkg::burst_t           m_arburst,
    output logic                      m_arid,
    output logic                      m_arlock,
    output logic [3:0]                m_arcache,
    output logic [2:0]                m_arprot,
    output logic [3:0]                m_arqos,

    input  logic                      m_rvalid,
    output logic                      m_rready,
    input  logic [AXI_DATA_W-1:0]     m_rdata,
    input  logic                      m_rlast,
    input  axi_pkg::resp_t            m_rresp,
    input  logic                      m_rid
);
    initial begin
        if (FIFO_DEPTH == 0) $fatal(1, "FIFO_DEPTH must be non-zero");
        if (BASE_ADDR % 4096 != 0) $fatal(1, "BASE_ADDR must be 4 KiB aligned");
        if (LOCAL_WR_PORTS == 0) $fatal(1, "LOCAL_WRITE_PORTS must be non-zero");
        if (FIFO_DEPTH > 256) $fatal(1, "FIFO_DEPTH must be at most 256");
    end

    logic                      burst_valid;
    logic                      burst_ready;
    logic [AXI_ADDR_W-1:0]     burst_addr;
    logic [8:0]                burst_beats;
    logic                      request_ready;
    logic                      pending_q;
    logic [AXI_ADDR_W-1:0]     address_q;
    logic [8:0]                beats_q;
    logic [8:0]                ar_beats_q;
    logic                      serialized_q;
    logic                      space_q;
    logic [COUNT_W-1:0]        reserved_q;
    logic                      burst_fire;
    logic                      ar_fire;
    logic [8:0]                beats_left;
    logic                      pending_next;
    logic [8:0]                ar_beats_next;
    logic [COUNT_W-1:0]        reserved_next;

    logic                      data_valid;
    logic                      data_ready;
    logic [AXI_DATA_W-1:0]     data;
    logic                      fifo_valid;
    logic                      dst_ready;
    logic [AXI_DATA_W-1:0]     dst_data;

    logic                      read_busy_q;
    logic                      serializer_ready;
    logic                      read_req_fire;
    logic                      read_word_fire;
    logic                      read_done;
    logic [LOCAL_WR_SEL_W-1:0] local_write_sel_q;
    logic [COUNT_W-1:0]        read_words_left_q;
    logic                      next_valid_q;
    logic [LOCAL_WR_SEL_W-1:0] next_sel_q;
    logic [COUNT_W-1:0]        next_words_q;
    logic                      take_next;

    assign burst_ready    = !pending_q;
    assign burst_fire     = burst_valid && burst_ready;
    assign ar_fire        = pending_q && space_q && request_ready;
    assign beats_left     = beats_q - ar_beats_q;
    assign req_ready      = serializer_ready && (!read_busy_q ||
        !next_valid_q && !serialized_q && !SERIALIZED_PORTS[req_local_sel]);
    assign read_req_fire  = req_valid && req_ready;
    assign read_word_fire = fifo_valid && dst_ready;
    assign read_done      = read_word_fire && read_words_left_q == COUNT_W'(1);
    assign dst_ready      = local_write_ready[local_write_sel_q];

    for (genvar p = 0; p < LOCAL_WR_PORTS; p++) begin : gen_local_write
        assign local_write_valid[p] = local_write_sel_q == LOCAL_WR_SEL_W'(p) && fifo_valid;
        assign local_write_data[p] = dst_data;
    end

    axi_burst_serializer #(
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_BYTES(AXI_BYTES),
        .COUNT_W(COUNT_W)
    ) u_burst_serializer (
        .clk, .rst,
        .req_valid(req_valid && req_ready),
        .req_ready(serializer_ready),
        .req_addr,
        .req_beats(req_words),
        .burst_valid,
        .burst_ready,
        .burst_addr,
        .burst_beats,
        .burst_last()
    );

    always_comb begin
        pending_next  = pending_q;
        ar_beats_next = ar_beats_q;
        if (burst_fire) begin
            pending_next  = 1'b1;
            ar_beats_next = serialized_q && burst_beats > 9'(PIECE_BEATS) ? 9'(PIECE_BEATS) : burst_beats;
        end else if (ar_fire) begin
            pending_next  = beats_left != '0;
            ar_beats_next = beats_left > 9'(PIECE_BEATS) ? 9'(PIECE_BEATS) : beats_left;
        end
        reserved_next = reserved_q + (ar_fire ? COUNT_W'(ar_beats_q) : '0) - COUNT_W'(read_word_fire);
    end

    always_ff @(posedge clk) begin
        if (burst_fire) begin
            address_q <= BASE_ADDR + burst_addr;
            beats_q   <= burst_beats;
        end else if (ar_fire) begin
            address_q[PAGE_W-1:0] <= address_q[PAGE_W-1:0] + PAGE_W'({ar_beats_q, AXI_SIZE'(0)});
            beats_q               <= beats_left;
        end
        ar_beats_q <= ar_beats_next;

        if (take_next) begin
            local_write_sel_q <= next_sel_q;
        end else if (read_req_fire && (!read_busy_q || read_done && !next_valid_q)) begin
            local_write_sel_q <= req_local_sel;
        end
        if (read_req_fire && read_busy_q && !(read_done && !next_valid_q)) begin
            next_sel_q   <= req_local_sel;
            next_words_q <= req_words;
        end
    end
    assign take_next = read_done && next_valid_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= 1'b0;
            serialized_q <= 1'b0;
            space_q <= 1'b0;
            reserved_q <= '0;
            read_busy_q <= 1'b0;
            next_valid_q <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= read_done;
            pending_q <= pending_next;
            reserved_q <= reserved_next;
            space_q <= !serialized_q || (COUNT_W+1)'(reserved_next) + (COUNT_W+1)'(ar_beats_next) <= (COUNT_W+1)'(FIFO_DEPTH);

            if (read_req_fire) begin
                serialized_q <= SERIALIZED_PORTS[req_local_sel];
            end

            if (take_next) begin
                read_words_left_q  <= next_words_q;
            end else if (read_req_fire && (!read_busy_q || read_done && !next_valid_q)) begin
                read_words_left_q  <= req_words;
            end else if (read_word_fire) begin
                read_words_left_q  <= read_words_left_q - 1'b1;
            end

            if (take_next) next_valid_q <= read_req_fire;
            else if (read_req_fire && read_busy_q && !read_done) next_valid_q <= 1'b1;
            if (read_req_fire || take_next) begin
                read_busy_q <= 1'b1;
            end else if (read_done) begin
                read_busy_q <= 1'b0;
            end
        end
    end

    axi_reader #(
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_BYTES(AXI_BYTES)
    ) u_reader (
        .clk,
        .rst,
        .req_valid(pending_q && space_q),
        .req_ready(request_ready),
        .req_addr(address_q),
        .req_beats(ar_beats_q),
        .dst_valid(data_valid),
        .dst_ready(data_ready),
        .dst_data(data),
        .m_arvalid,
        .m_arready,
        .m_araddr,
        .m_arlen,
        .m_arsize,
        .m_arburst,
        .m_arid,
        .m_arlock,
        .m_arcache,
        .m_arprot,
        .m_arqos,
        .m_rvalid,
        .m_rready,
        .m_rdata,
        .m_rlast,
        .m_rresp,
        .m_rid
    );

    fifo #(
        .DATA_WIDTH(AXI_DATA_W),
        .DEPTH(FIFO_DEPTH)
    ) u_fifo (
        .clk,
        .rst,
        .w_en(data_valid),
        .w_data(data),
        .w_rdy(data_ready),
        .r_en(read_word_fire),
        .r_data(dst_data),
        .r_valid(fifo_valid),
        .level()
    );
endmodule
