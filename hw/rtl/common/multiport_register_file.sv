module multiport_register_file #(
    parameter int unsigned DATA_WIDTH       = 32,
    parameter int unsigned REGISTER_COUNT   = 16,
    parameter int unsigned READ_PORT_COUNT  = 4,
    parameter int unsigned WRITE_PORT_COUNT = 3,
    parameter bit OWNER_LOOKUP              = 1'b1,

    localparam int unsigned ADDR_WIDTH      = REGISTER_COUNT > 1 ? $clog2(REGISTER_COUNT) : 1,
    localparam int unsigned TAG_WIDTH       = WRITE_PORT_COUNT > 1 ? $clog2(WRITE_PORT_COUNT) : 1
) (
    input  logic                  clk,
    input  logic [ADDR_WIDTH-1:0] read_addr_next [READ_PORT_COUNT],
    output logic [DATA_WIDTH-1:0] read_data    [READ_PORT_COUNT],
    input  logic                  write_enable [WRITE_PORT_COUNT],
    input  logic [ADDR_WIDTH-1:0] write_addr   [WRITE_PORT_COUNT],
    input  logic [DATA_WIDTH-1:0] write_data   [WRITE_PORT_COUNT],
    input  logic [TAG_WIDTH-1:0]  owner_in     [READ_PORT_COUNT],
    output logic [TAG_WIDTH-1:0]  owner_out    [READ_PORT_COUNT]
);
    logic [TAG_WIDTH-1:0]  owner      [REGISTER_COUNT];
    logic [TAG_WIDTH-1:0]  next_owner [REGISTER_COUNT];
    logic [DATA_WIDTH-1:0] bank_data  [WRITE_PORT_COUNT][READ_PORT_COUNT];
    logic [ADDR_WIDTH-1:0] read_addr_q  [READ_PORT_COUNT];
    logic [TAG_WIDTH-1:0]  read_owner_q [READ_PORT_COUNT];

    for (genvar port = 0; port < WRITE_PORT_COUNT; port++) begin : gen_writer
        (* ram_style = "distributed" *) logic [DATA_WIDTH-1:0] regs [REGISTER_COUNT];

        always_ff @(posedge clk) begin
            if (write_enable[port]) regs[write_addr[port]] <= write_data[port];
        end

        for (genvar read_port = 0; read_port < READ_PORT_COUNT; read_port++) begin : gen_read
            assign bank_data[port][read_port] = regs[read_addr_q[read_port]];
        end
    end

    always_comb begin
        next_owner = owner;
        for (int reg_id = 0; reg_id < REGISTER_COUNT; reg_id++) begin
            for (int port = WRITE_PORT_COUNT-1; port >= 0; port--) begin
                if (write_enable[port] && write_addr[port] == ADDR_WIDTH'(reg_id)) begin
                    next_owner[reg_id] = TAG_WIDTH'(port);
                    break;
                end
            end
        end

        for (int read_port = 0; read_port < READ_PORT_COUNT; read_port++) begin
            read_data[read_port] = '0;
            for (int write_port = 0; write_port < WRITE_PORT_COUNT; write_port++) begin
                if (read_owner_q[read_port] == TAG_WIDTH'(write_port))
                    read_data[read_port] = bank_data[write_port][read_port];
            end
        end
    end

    assign owner_out = read_owner_q;

    always_ff @(posedge clk) begin
        owner <= next_owner;
        for (int read_port = 0; read_port < READ_PORT_COUNT; read_port++) begin
            read_addr_q[read_port]  <= read_addr_next[read_port];
            read_owner_q[read_port] <= OWNER_LOOKUP ? next_owner[read_addr_next[read_port]] : owner_in[read_port];
        end
    end
endmodule
