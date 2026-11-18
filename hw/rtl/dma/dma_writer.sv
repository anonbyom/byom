module dma_writer #(
    parameter int unsigned AXI_ADDR_W                       = 64,
    parameter int unsigned AXI_BYTES                        = 64,
    parameter int unsigned LOCAL_DEPTH                      = 1024,
    parameter int unsigned LOCAL_READ_PORTS                 = 2,
    parameter logic [AXI_ADDR_W-1:0] BASE_ADDR              = '0,
    parameter logic [LOCAL_READ_PORTS-1:0] SERIALIZED_PORTS = '0,

    localparam int unsigned AXI_DATA_W = 8 * AXI_BYTES,
    localparam int unsigned COUNT_W = $clog2(LOCAL_DEPTH + 1),
    localparam int unsigned LOCAL_RD_SEL_W = LOCAL_READ_PORTS > 1 ? $clog2(LOCAL_READ_PORTS) : 1,
    localparam int unsigned AXI_SIZE       = $clog2(AXI_BYTES),
    localparam int unsigned PAGE_W         = 12
) (
    input  logic                      clk,
    input  logic                      rst,

    input  logic                      req_valid,
    output logic                      req_ready,
    input  logic [AXI_ADDR_W-1:0]     req_addr,
    input  logic [COUNT_W-1:0]        req_words,
    input  logic [LOCAL_RD_SEL_W-1:0] req_local_sel,
    output logic                      done,

    input  logic                      local_read_valid [LOCAL_READ_PORTS],
    output logic                      local_read_ready [LOCAL_READ_PORTS],
    input  logic [AXI_DATA_W-1:0]     local_read_data  [LOCAL_READ_PORTS],

    output logic                      m_awvalid,
    input  logic                      m_awready,
    output logic [AXI_ADDR_W-1:0]     m_awaddr,
    output logic [7:0]                m_awlen,
    output logic [2:0]                m_awsize,
    output axi_pkg::burst_t           m_awburst,
    output logic                      m_awid,
    output logic                      m_awlock,
    output logic [3:0]                m_awcache,
    output logic [2:0]                m_awprot,
    output logic [3:0]                m_awqos,

    output logic                      m_wvalid,
    input  logic                      m_wready,
    output logic [AXI_DATA_W-1:0]     m_wdata,
    output logic [AXI_BYTES-1:0]      m_wstrb,
    output logic                      m_wlast,
    output logic                      m_wid,

    input  logic                      m_bvalid,
    output logic                      m_bready,
    input  axi_pkg::resp_t            m_bresp,
    input  logic                      m_bid
);
    initial begin
        if (BASE_ADDR % 4096 != 0) $fatal(1, "BASE_ADDR must be 4 KiB aligned");
        if (LOCAL_READ_PORTS == 0) $fatal(1, "LOCAL_READ_PORTS must be non-zero");
    end

    logic                      burst_valid;
    logic                      burst_ready;
    logic [8:0]                burst_beats;
    logic [AXI_ADDR_W-1:0]     burst_addr;
    logic                      burst_last;

    logic                      pending;
    logic                      request_ready;
    logic                      request_last;
    logic                      active_last;

    logic [AXI_ADDR_W-1:0]     address;
    logic [8:0]                beats;
    logic                      serializer_ready;
    logic                      active;
    logic                      burst_done;
    logic                      request_fire;
    logic                      final_done;
    logic                      done_q;
    logic                      src_ready;
    logic [LOCAL_RD_SEL_W-1:0] local_read_sel_q;
    logic [8:0]                aw_beats;
    logic [8:0]                beats_left;
    logic                      serialized_q;
    logic                      owed_q;
    logic                      issue_ok;
    logic                      aw_fire;
    logic                      w_last_fire;

    assign request_fire        = req_valid && req_ready;
    assign final_done          = burst_done && active_last;
    assign req_ready           = !active && serializer_ready;
    assign burst_ready         = !pending;
    assign aw_beats            = serialized_q ? 9'd1 : beats;
    assign beats_left          = beats - aw_beats;
    assign issue_ok            = !serialized_q || (local_read_valid[local_read_sel_q] && !owed_q);
    assign aw_fire             = pending && issue_ok && request_ready;
    assign w_last_fire         = m_wvalid && m_wready && m_wlast;

    for (genvar p = 0; p < LOCAL_READ_PORTS; p++) begin : gen_local_read
        assign local_read_ready[p] = local_read_sel_q == LOCAL_RD_SEL_W'(p) && src_ready;
    end

    axi_burst_serializer #(
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_BYTES(AXI_BYTES),
        .COUNT_W(COUNT_W)
    ) u_burst_serializer (
        .clk,
        .rst,
        .req_valid(req_valid && !active),
        .req_ready(serializer_ready),
        .req_addr,
        .req_beats(req_words),
        .burst_valid,
        .burst_ready,
        .burst_addr,
        .burst_beats,
        .burst_last
    );

    always_ff @(posedge clk) begin
        if (burst_valid && burst_ready) begin
            address      <= BASE_ADDR + burst_addr;
            beats        <= burst_beats;
            request_last <= burst_last;
        end else if (aw_fire) begin
            address[PAGE_W-1:0] <= address[PAGE_W-1:0] + PAGE_W'({aw_beats, AXI_SIZE'(0)});
            beats               <= beats_left;
        end
        if (aw_fire) begin
            active_last <= request_last && beats_left == '0;
        end

        if (request_fire) begin
            local_read_sel_q <= req_local_sel;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            pending      <= 1'b0;
            active       <= 1'b0;
            done         <= 1'b0;
            done_q       <= 1'b0;
            serialized_q <= 1'b0;
            owed_q       <= 1'b0;
        end else begin
            done <= done_q;
            done_q <= !request_fire && final_done;
            if (request_fire) begin
                active <= 1'b1;
                serialized_q <= SERIALIZED_PORTS[req_local_sel];
            end else if (final_done) begin
                active <= 1'b0;
            end

            if (burst_valid && burst_ready) begin
                pending <= 1'b1;
            end else if (aw_fire && beats_left == '0) begin
                pending <= 1'b0;
            end

            if (aw_fire) begin
                owed_q <= 1'b1;
            end else if (w_last_fire) begin
                owed_q <= 1'b0;
            end
        end
    end

    axi_writer #(
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_BYTES(AXI_BYTES)
    ) u_writer (
        .clk,
        .rst,
        .req_valid(pending && issue_ok),
        .req_ready(request_ready),
        .req_addr(address),
        .req_beats(aw_beats),
        .src_valid(local_read_valid[local_read_sel_q]),
        .src_ready,
        .src_data(local_read_data[local_read_sel_q]),
        .done(burst_done),
        .m_awvalid,
        .m_awready,
        .m_awaddr,
        .m_awlen,
        .m_awsize,
        .m_awburst,
        .m_awid,
        .m_awlock,
        .m_awcache,
        .m_awprot,
        .m_awqos,
        .m_wvalid,
        .m_wready,
        .m_wdata,
        .m_wstrb,
        .m_wlast,
        .m_wid,
        .m_bvalid,
        .m_bready,
        .m_bresp,
        .m_bid
    );
endmodule
