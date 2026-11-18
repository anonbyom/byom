module reset_register (
    input  logic clk,
    input  logic rst_in,
    output logic rst
);
    (* dont_touch = "true" *) logic root_q;
    (* max_fanout = 128 *) logic rst_q;

    always_ff @(posedge clk) begin
        root_q <= rst_in;
        rst_q <= root_q;
    end

    assign rst = rst_q;
endmodule : reset_register
