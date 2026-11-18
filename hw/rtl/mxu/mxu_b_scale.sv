// One weight column's E8M0 scale: the bank's last push, taken at its preload, switched in on update.
module mxu_b_scale #(
    parameter int unsigned  DIM         = 32,
    localparam int unsigned SCALE_WIDTH = 8,
    localparam int unsigned COUNT_W     = $clog2(DIM + 1)
) (
    input  logic                   clk,
    input  logic                   rst,
    input  logic                   write,
    input  logic                   write_bank,
    input  logic [SCALE_WIDTH-1:0] write_scale,
    input  logic                   preload,
    input  logic                   preload_bank,
    input  logic                   read,
    input  logic                   read_bank,
    input  logic                   update,
    output logic [SCALE_WIDTH-1:0] scale
);
    logic [SCALE_WIDTH-1:0] active [2];
    logic [SCALE_WIDTH-1:0] loaded_q;
    logic [SCALE_WIDTH-1:0] compute_q;

    for (genvar bank = 0; bank < 2; bank++) begin : gen_bank
        logic                   push;
        logic                   last;
        logic                   preload_here;
        logic [COUNT_W-1:0]     count_q;
        logic                   ready_q;
        logic                   awaiting_q;
        logic [SCALE_WIDTH-1:0] pending_q;

        assign push         = write && write_bank == 1'(bank);
        assign last         = push && count_q == COUNT_W'(DIM - 1);
        assign preload_here = preload && preload_bank == 1'(bank);

        always_ff @(posedge clk) begin
            if (rst) begin
                count_q    <= '0;
                ready_q    <= 1'b0;
                awaiting_q <= 1'b0;
            end else begin
                if (push) count_q <= last ? '0 : count_q + 1'b1;
                if (last) ready_q <= 1'b1;
                if (preload_here) begin
                    ready_q    <= ready_q && last;
                    awaiting_q <= !ready_q && !last;
                end else if (awaiting_q && last) begin
                    ready_q    <= 1'b0;
                    awaiting_q <= 1'b0;
                end
            end
        end

        always_ff @(posedge clk) begin
            if (last) pending_q <= write_scale;
            if (preload_here && ready_q) active[bank] <= pending_q;
            else if (last && (preload_here || awaiting_q)) active[bank] <= write_scale;
        end
    end

    always_ff @(posedge clk) begin
        if (read) loaded_q <= active[read_bank];
        if (update) compute_q <= loaded_q;
    end
    assign scale = update ? loaded_q : compute_q;
endmodule : mxu_b_scale
