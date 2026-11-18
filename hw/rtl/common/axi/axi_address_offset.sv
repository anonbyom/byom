// base_addr + s_addr in four registered 16-bit adder stages.
module axi_address_offset #(parameter int WIDTH = 26) (
    input logic clk,
    input logic rst,
    input logic [63:0] base_addr,
    input logic s_valid,
    output logic s_ready,
    input logic [63:0] s_addr,
    input logic [WIDTH-1:0] s_data,
    output logic m_valid,
    input logic m_ready,
    output logic [63:0] m_addr,
    output logic [WIDTH-1:0] m_data
);
    typedef struct packed {
        logic [63:0] base;
        logic [63:0] address;
        logic [63:0] result;
        logic carry;
        logic [WIDTH-1:0] data;
    } payload_t;
    logic valid [5];
    logic ready [5];
    payload_t payload [5];
    assign valid[0] = s_valid;
    assign s_ready = ready[0];
    assign payload[0] = {base_addr, s_addr, 64'd0, 1'b0, s_data};
    assign m_valid = valid[4];
    assign ready[4] = m_ready;
    assign m_addr = payload[4].result;
    assign m_data = payload[4].data;
    for (genvar stage = 0; stage < 4; stage++) begin : gen_add
        wire [63:0] base = payload[stage].base;
        wire [63:0] address = payload[stage].address;
        wire carry = payload[stage].carry;
        wire [16:0] sum = {1'b0, base[16*stage +: 16]} +
                          {1'b0, address[16*stage +: 16]} + {16'd0, carry};
        logic [63:0] result;
        always_comb begin
            result = payload[stage].result;
            result[16*stage +: 16] = sum[15:0];
        end
        axi_register_slice #(
            .WIDTH($bits(payload_t))
        ) u_stage (
            .clk,
            .rst,
            .s_valid (valid[stage]),
            .s_ready (ready[stage]),
            .s_data  ({base, address, result, sum[16], payload[stage].data}),
            .m_valid (valid[stage+1]),
            .m_ready (ready[stage+1]),
            .m_data  (payload[stage+1])
        );
    end
endmodule
