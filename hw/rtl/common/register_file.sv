module register_file #(
    parameter int unsigned DATA_WIDTH       = 32,
    parameter int unsigned REGISTER_COUNT   = 32,
    parameter int unsigned READ_PORT_COUNT  = 2,
    parameter int unsigned WRITE_PORT_COUNT = 1,

    localparam int unsigned ADDR_WIDTH = (REGISTER_COUNT > 1) ? $clog2(REGISTER_COUNT) : 1
) (
    input  logic                    clk,
    input  logic                    rst,

    input  logic [ADDR_WIDTH - 1:0] read_addr    [READ_PORT_COUNT],
    output logic [DATA_WIDTH - 1:0] read_data    [READ_PORT_COUNT],

    input  logic                    write_enable [WRITE_PORT_COUNT],
    input  logic [ADDR_WIDTH - 1:0] write_addr   [WRITE_PORT_COUNT],
    input  logic [DATA_WIDTH - 1:0] write_data   [WRITE_PORT_COUNT]
);
    logic [DATA_WIDTH - 1:0] regs [REGISTER_COUNT];

    always_comb begin
        for (int port = 0; port < READ_PORT_COUNT; port++)
            read_data[port] = regs[read_addr[port]];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < REGISTER_COUNT; i++)
                regs[i] <= '0;
        end else begin
            for (int port = 0; port < WRITE_PORT_COUNT; port++)
                if (write_enable[port]) regs[write_addr[port]] <= write_data[port];
        end
    end
endmodule : register_file
