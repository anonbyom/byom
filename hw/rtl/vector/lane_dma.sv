module lane_dma #(
    parameter int ADDR_WIDTH     = 10,
    parameter int DATA_WIDTH     = 32,
    parameter int MEM_OUTPUT_REG = 0,
    localparam int READ_LATENCY  = 3 + MEM_OUTPUT_REG
) (
    input  logic                  clk,
    input  logic                  rst,

    input  logic                  req_valid,
    input  logic                  req_write,
    input  logic [ADDR_WIDTH-1:0] req_addr,
    input  logic [DATA_WIDTH-1:0] req_wdata,

    output logic                  resp_valid,
    output logic [DATA_WIDTH-1:0] resp_data,

    output logic                  mem_valid,
    output logic                  mem_write,
    output logic [ADDR_WIDTH-1:0] mem_addr,
    output logic [DATA_WIDTH-1:0] mem_wdata,
    input  logic [DATA_WIDTH-1:0] mem_rdata
);
    typedef struct packed {
        logic                  valid;
        logic                  write;
        logic [ADDR_WIDTH-1:0] addr;
        logic [DATA_WIDTH-1:0] data;
    } request_t;

    request_t              req_q;
    logic [DATA_WIDTH-1:0] resp_data_q;
    logic                  read_valid;

    assign read_valid = req_valid && !req_write;
    assign mem_valid  = req_q.valid;
    assign mem_write  = req_q.write;
    assign mem_addr   = req_q.addr;
    assign mem_wdata  = req_q.data;
    assign resp_data  = resp_data_q;

    shifter #(
        .WIDTH(1),
        .LENGTH(READ_LATENCY)
    ) u_read_valid (
        .clk,
        .rst,
        .en (1'b1),
        .d  (read_valid),
        .q  (resp_valid)
    );

    always_ff @(posedge clk) begin
        req_q.write <= req_write;
        req_q.addr  <= req_addr;
        req_q.data  <= req_wdata;
        resp_data_q <= mem_rdata;
        if (rst) req_q.valid <= 1'b0;
        else req_q.valid <= req_valid;
    end
endmodule
