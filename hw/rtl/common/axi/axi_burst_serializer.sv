module axi_burst_serializer #(
    parameter int unsigned AXI_ADDR_W  = 64,
    parameter int unsigned AXI_BYTES   = 32,
    parameter int unsigned COUNT_W     = 32,

    localparam int unsigned PAGE_BYTES = 4096,
    localparam int unsigned MAX_BEATS  = 256,
    localparam int unsigned PAGE_W     = $clog2(PAGE_BYTES),
    localparam int unsigned BURST_W    = $clog2(MAX_BEATS + 1),
    localparam int unsigned AXI_SIZE   = $clog2(AXI_BYTES),
    localparam int unsigned PAGE_BEATS = PAGE_BYTES / AXI_BYTES,
    localparam int unsigned LIMIT_W    = $clog2(PAGE_BEATS + 1),
    localparam int unsigned COMPARE_W  = COUNT_W > LIMIT_W ? COUNT_W : LIMIT_W
) (
    input  logic                  clk,
    input  logic                  rst,

    input  logic                  req_valid,
    output logic                  req_ready,
    input  logic [AXI_ADDR_W-1:0] req_addr,
    input  logic [COUNT_W-1:0]    req_beats,

    output logic                  burst_valid,
    input  logic                  burst_ready,
    output logic [AXI_ADDR_W-1:0] burst_addr,
    output logic [BURST_W-1:0]    burst_beats,
    output logic                  burst_last
);
    initial begin
        if ((AXI_BYTES & (AXI_BYTES - 1)) != 0) $fatal(1, "AXI_BYTES is not a power of 2");
        if (AXI_BYTES < 16 || AXI_BYTES > 128) $fatal(1, "AXI_BYTES must be between 16 and 128");
    end

    typedef enum logic [1:0] {
        IDLE,
        PREPARE,
        EMIT
    } state_t;

    state_t                       state_q;
    logic [AXI_ADDR_W-1:0]        addr_q;
    logic [AXI_ADDR_W-PAGE_W-1:0] next_page_q;
    logic [COUNT_W-1:0]           beats_left_q;
    logic [LIMIT_W-1:0]           limit_q;
    logic                         last;

    assign last        = COMPARE_W'(beats_left_q) <= COMPARE_W'(limit_q);
    assign req_ready   = state_q == IDLE;
    assign burst_valid = state_q == EMIT;
    assign burst_addr  = addr_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
        end else begin
            case (state_q)
                IDLE: begin
                    if (req_valid) begin
                        addr_q       <= req_addr;
                        beats_left_q <= req_beats;
                        limit_q      <= LIMIT_W'(PAGE_BEATS) - LIMIT_W'(req_addr[PAGE_W-1:AXI_SIZE]);
                        state_q      <= PREPARE;
                    end
                end

                PREPARE: begin
                    burst_last   <= last;
                    burst_beats  <= last ? BURST_W'(beats_left_q) : BURST_W'(limit_q);
                    beats_left_q <= beats_left_q - COUNT_W'(limit_q);
                    next_page_q  <= addr_q[AXI_ADDR_W-1:PAGE_W] + 1'b1;
                    state_q      <= EMIT;
                end

                EMIT: begin
                    if (burst_ready) begin
                        if (burst_last) begin
                            state_q <= IDLE;
                        end else begin
                            addr_q  <= {next_page_q, {PAGE_W{1'b0}}};
                            limit_q <= LIMIT_W'(PAGE_BEATS);
                            state_q <= PREPARE;
                        end
                    end
                end

                default: begin
                    state_q <= IDLE;
                end
            endcase
        end
    end

endmodule
