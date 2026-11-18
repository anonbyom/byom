// instruction fetch. two-cycle IMEM reads into a 4-entry queue next to decode. fetch continues while an IMEM DMA.
module scalar_fetch #(
    parameter int unsigned IMEM_DEPTH = 1024,
    localparam int unsigned IMEM_ADDR_WIDTH = $clog2(IMEM_DEPTH)
) (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       enable,
    input  logic                       halt_q,
    input  logic                       decode_ready,
    input  logic                       refetch,
    input  logic [IMEM_ADDR_WIDTH-1:0] redirect_pc,
    input  logic                       imem_dma_write_valid,
    input  logic [IMEM_ADDR_WIDTH-1:0] imem_dma_write_addr,
    input  isa_pkg::bundle_t           imem_dma_write_data,
    input  logic                       loop_start,
    input  logic [IMEM_ADDR_WIDTH-1:0] loop_first,
    input  logic [IMEM_ADDR_WIDTH-1:0] loop_last,
    input  isa_pkg::scalar_word_t      loop_count,
    output logic                       fetched_valid_q,
    output logic [IMEM_ADDR_WIDTH-1:0] fetched_pc_q,
    output isa_pkg::bundle_t           imem_instr,
    output isa_pkg::bundle_t           fetched_instr_q
);
    import isa_pkg::*;

    logic                          imem_read;
    bundle_t                       imem_rdata;
    (* cascade_height = 1 *) logic [BUNDLE_WIDTH-1:0] imem [IMEM_DEPTH];
    logic                          imem_write_q;
    logic    [IMEM_ADDR_WIDTH-1:0] imem_write_addr_q;
    bundle_t                       imem_write_data_q;
    logic    [IMEM_ADDR_WIDTH-1:0] fetch_pc_q;
    logic                          loop_active_q;
    logic                          loop_more_q;
    logic    [IMEM_ADDR_WIDTH-1:0] loop_first_q;
    logic    [IMEM_ADDR_WIDTH-1:0] loop_last_q;
    scalar_word_t                  loop_left_q;
    logic                          loop_end;
    logic    [IMEM_ADDR_WIDTH-1:0] next_pc;

    always_ff @(posedge clk) begin
        if (rst) imem_write_q <= 1'b0;
        else imem_write_q <= imem_dma_write_valid;
        imem_write_addr_q <= imem_dma_write_addr;
        imem_write_data_q <= imem_dma_write_data;
    end

    always_ff @(posedge clk) begin
        if (imem_read) imem_rdata <= imem[fetch_pc_q];
        if (imem_write_q) imem[imem_write_addr_q] <= imem_write_data_q;
    end

    assign loop_end = loop_active_q && fetch_pc_q == loop_last_q;
    assign next_pc  = loop_end && loop_more_q ? loop_first_q : fetch_pc_q + 1'b1;

    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            loop_active_q <= 1'b0;
        end else if (loop_start) begin
            loop_active_q <= 1'b1;
        end else if (!refetch && imem_read && loop_end && !loop_more_q) begin
            loop_active_q <= 1'b0;
        end
        if (loop_start) begin
            loop_first_q <= loop_first;
            loop_last_q  <= loop_last;
            loop_left_q  <= loop_count == 0 ? '0 : loop_count - 1'b1;
            loop_more_q  <= loop_count > 1;
        end else if (!refetch && imem_read && loop_end && loop_more_q) begin
            loop_left_q <= loop_left_q - 1'b1;
            loop_more_q <= loop_left_q != 1;
        end
    end

    localparam int unsigned QUEUE   = 4;
    localparam int unsigned COUNT_W = $clog2(QUEUE + 1);

    logic                          read_q  [2];
    logic    [IMEM_ADDR_WIDTH-1:0] read_pc_q [2];
    bundle_t                       oreg_q;
    bundle_t                       q_instr [QUEUE];
    logic    [IMEM_ADDR_WIDTH-1:0] q_pc    [QUEUE];
    logic    [COUNT_W-1:0]         count_q;
    logic    [COUNT_W-1:0]         kept;
    logic                          pop;

    assign imem_read   = enable && !halt_q && 32'(count_q) + 32'(read_q[0]) + 32'(read_q[1]) < QUEUE;
    assign pop         = decode_ready && count_q != 0;
    assign kept        = count_q - COUNT_W'(pop);

    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            fetch_pc_q      <= '0;
            read_q          <= '{default: 1'b0};
            count_q         <= '0;
            fetched_valid_q <= 1'b0;
        end else if (refetch) begin
            read_q          <= '{default: 1'b0};
            count_q         <= '0;
            fetched_valid_q <= 1'b0;
            fetch_pc_q      <= redirect_pc;
        end else begin
            read_q[0] <= imem_read;
            read_q[1] <= read_q[0];
            if (imem_read) fetch_pc_q <= next_pc;
            count_q         <= kept + COUNT_W'(read_q[1]);
            fetched_valid_q <= kept != 0 || read_q[1];
        end
        if (imem_read) read_pc_q[0] <= fetch_pc_q;
        read_pc_q[1] <= read_pc_q[0];
        oreg_q <= imem_rdata;
    end

    for (genvar i = 0; i < QUEUE; i++) begin : gen_entry
        always_ff @(posedge clk) begin
            if (COUNT_W'(i) < kept) begin
                if (pop && i + 1 < QUEUE) begin
                    q_instr[i] <= q_instr[(i + 1) % QUEUE];
                    q_pc[i]    <= q_pc[(i + 1) % QUEUE];
                end
            end else if (COUNT_W'(i) == kept) begin
                q_instr[i] <= oreg_q;
                q_pc[i]    <= read_pc_q[1];
            end
        end
    end

    assign fetched_instr_q = q_instr[0];
    assign fetched_pc_q    = q_pc[0];
    assign imem_instr      = q_instr[0];

endmodule
