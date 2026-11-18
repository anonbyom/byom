// synchronous buffered fifo
module fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH      = 16,
    parameter bit RESERVED_WRITES = 1'b0,
    parameter bit READ_READY_BYPASS = 1'b1,
    // Storage in BRAM (else the tool's choice); needs !READ_READY_BYPASS.
    parameter bit BRAM = 1'b0
)(
    input  logic                  clk,
    input  logic                  rst,

    input  logic                  w_en,
    input  logic [DATA_WIDTH-1:0] w_data,
    output logic                  w_rdy,

    input  logic                  r_en,
    output logic [DATA_WIDTH-1:0] r_data,
    output logic                  r_valid,

    output logic [(DEPTH > 0 ? $clog2(DEPTH+1)-1 : 0):0] level
);

    if (DEPTH == 0) begin : g_zero
        assign w_rdy  = 1'b0;
        assign r_valid = 1'b0;
        assign r_data = '0;
        assign level  = '0;
    end else if (DEPTH == 1) begin : g_one
        logic do_write;
        logic do_read;

        assign do_write = w_en && (RESERVED_WRITES || w_rdy);
        assign do_read  = r_en && r_valid;

        assign r_valid = level;
        assign w_rdy = ~level | (READ_READY_BYPASS && do_read);

        always_ff @(posedge clk) begin
            if (rst) level <= 1'b0;
            else if (do_write) level <= 1'b1;
            else if (do_read) level <= 1'b0;

            if (do_write) r_data <= w_data;
        end
    end else begin : g_main
        localparam int INNER_DEPTH = DEPTH - 1;
        localparam int PTR_W       = (INNER_DEPTH > 1) ? $clog2(INNER_DEPTH) : 1;
        localparam int COUNT_W     = $clog2(INNER_DEPTH + 1);

        logic [PTR_W-1:0]      w_ptr;
        logic [PTR_W-1:0]      r_ptr;
        logic [COUNT_W-1:0]    inner_level;
        logic                  inner_valid;
        logic                  out_valid;
        logic                  do_write;
        logic                  do_inner_read;

        assign inner_valid = (inner_level != 0);
        assign r_valid     = out_valid;
        assign level       = inner_level + out_valid;

        assign do_inner_read = inner_valid && (~out_valid | r_en);
        assign w_rdy = (inner_level != COUNT_W'(INNER_DEPTH)) | (READ_READY_BYPASS && do_inner_read);
        assign do_write = w_en && (RESERVED_WRITES || w_rdy);

        if (BRAM) begin : g_block
            (* ram_style = "block" *) logic [DATA_WIDTH-1:0] mem [INNER_DEPTH];
            always_ff @(posedge clk) begin
                if (do_write)      mem[w_ptr] <= w_data;
                if (do_inner_read) r_data     <= mem[r_ptr];
            end
        end else begin : g_memory
            logic [DATA_WIDTH-1:0] mem [INNER_DEPTH];
            always_ff @(posedge clk) begin
                if (do_write)      mem[w_ptr] <= w_data;
                if (do_inner_read) r_data     <= mem[r_ptr];
            end
        end
        initial if (BRAM && READ_READY_BYPASS)
            $fatal(1, "fifo: a block FIFO cannot bypass (it would read the entry being written)");

        always_ff @(posedge clk) begin
            if (rst) begin
                w_ptr       <= '0;
                r_ptr       <= '0;
                inner_level <= '0;
                out_valid   <= 1'b0;
            end else begin
                if (do_write)
                    w_ptr <= (w_ptr == PTR_W'(INNER_DEPTH - 1)) ? '0 : w_ptr + 1;
                if (do_inner_read)
                    r_ptr <= (r_ptr == PTR_W'(INNER_DEPTH - 1)) ? '0 : r_ptr + 1;
                if (do_write && ~do_inner_read)  inner_level <= inner_level + 1;
                if (do_inner_read && ~do_write)  inner_level <= inner_level - 1;

                if (do_inner_read)              out_valid <= 1'b1;
                else if (r_en)                  out_valid <= 1'b0;
            end
        end
    end
endmodule
