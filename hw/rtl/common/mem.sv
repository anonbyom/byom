module mem #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned DEPTH      = 4096,
    parameter int unsigned PORTS      = 1,
    parameter bit          OUTPUT_REG = 1'b0,

    localparam int unsigned ADDR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic                  clk,
    input  logic                  rst,

    input  logic                  req_valid [PORTS],
    input  logic                  req_write [PORTS],
    input  logic [ADDR_WIDTH-1:0] req_addr  [PORTS],
    input  logic [DATA_WIDTH-1:0] req_wdata [PORTS],

    output logic                  rsp_valid [PORTS],
    output logic [DATA_WIDTH-1:0] rsp_rdata [PORTS]
);
    initial begin
        if (PORTS > 2) $warning(1, "Memory with PORTS > 2");
    end

    logic [DATA_WIDTH-1:0] memory [DEPTH];

    for (genvar p = 0; p < PORTS; p++) begin : gen_port
        logic                  read_valid;
        logic [DATA_WIDTH-1:0] read_data;

        always_ff @(posedge clk) begin
            if (rst) read_valid <= 1'b0;
            else read_valid <= req_valid[p] && !req_write[p];
        end

        always @(posedge clk) begin
            if (req_valid[p]) begin
                if (req_write[p]) memory[req_addr[p]] <= req_wdata[p];
                else read_data <= memory[req_addr[p]];
            end
        end

        if (OUTPUT_REG) begin : gen_output_reg
            always_ff @(posedge clk) begin
                if (rst) rsp_valid[p] <= 1'b0;
                else rsp_valid[p] <= read_valid;
            end
            always_ff @(posedge clk) rsp_rdata[p] <= read_data;
        end else begin : gen_direct
            assign rsp_valid[p] = read_valid;
            assign rsp_rdata[p] = read_data;
        end
    end

endmodule : mem

// Two-port UltraRAM with byte write enables, two-cycle reads. OREG: three-cycle reads through the URAM output
// register (an XPM memory in synthesis).
module mem_bytewrite #(
    parameter int unsigned DATA_WIDTH = 64,
    parameter int unsigned DEPTH      = 4096,
    parameter int unsigned PORTS      = 2,
    parameter bit          OREG       = 1'b0,

    localparam int unsigned BYTES      = DATA_WIDTH / 8,
    localparam int unsigned ADDR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic                  clk,
    input  logic                  rst,

    input  logic                  req_valid [PORTS],
    input  logic [BYTES-1:0]      req_write [PORTS],
    input  logic [ADDR_WIDTH-1:0] req_addr  [PORTS],
    input  logic [DATA_WIDTH-1:0] req_wdata [PORTS],

    output logic                  rsp_valid [PORTS],
    output logic [DATA_WIDTH-1:0] rsp_rdata [PORTS]
);
    initial begin
        if (DATA_WIDTH % 8 != 0) $fatal(1, "mem_bytewrite needs whole bytes");
    end

`ifdef SYNTHESIS
    if (OREG) begin : gen_xpm
        logic       read_q [PORTS][3];
        logic [1:0] regce;

        for (genvar p = 0; p < PORTS; p++) begin : gen_valid
            always_ff @(posedge clk) begin
                if (rst) begin
                    read_q[p][0] <= 1'b0;
                    read_q[p][1] <= 1'b0;
                    read_q[p][2] <= 1'b0;
                end else begin
                    read_q[p][0] <= req_valid[p] && req_write[p] == '0;
                    read_q[p][1] <= read_q[p][0];
                    read_q[p][2] <= read_q[p][1];
                end
            end
            assign rsp_valid[p] = read_q[p][2];
            assign regce[p]     = read_q[p][1];   // the last (fabric) stage loads
        end

        xpm_memory_tdpram #(
            .ADDR_WIDTH_A(ADDR_WIDTH), .ADDR_WIDTH_B(ADDR_WIDTH), .AUTO_SLEEP_TIME(0),
            .BYTE_WRITE_WIDTH_A(8), .BYTE_WRITE_WIDTH_B(8), .CASCADE_HEIGHT(0),
            .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
            .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("ultra"),
            .MEMORY_SIZE(DEPTH * DATA_WIDTH), .MESSAGE_CONTROL(0),
            .READ_DATA_WIDTH_A(DATA_WIDTH), .READ_DATA_WIDTH_B(DATA_WIDTH),
            .READ_LATENCY_A(3), .READ_LATENCY_B(3), .READ_RESET_VALUE_A("0"), .READ_RESET_VALUE_B("0"),
            .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0),
            .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
            .WRITE_DATA_WIDTH_A(DATA_WIDTH), .WRITE_DATA_WIDTH_B(DATA_WIDTH),
            .WRITE_MODE_A("no_change"), .WRITE_MODE_B("no_change")
        ) u_xpm (
            .clka(clk), .clkb(clk), .rsta(1'b0), .rstb(1'b0), .sleep(1'b0),
            .ena(req_valid[0]), .enb(req_valid[1]), .wea(req_write[0]), .web(req_write[1]),
            .addra(req_addr[0]), .addrb(req_addr[1]), .dina(req_wdata[0]), .dinb(req_wdata[1]),
            .douta(rsp_rdata[0]), .doutb(rsp_rdata[1]), .regcea(regce[0]), .regceb(regce[1]),
            .injectdbiterra(1'b0), .injectdbiterrb(1'b0), .injectsbiterra(1'b0), .injectsbiterrb(1'b0),
            .dbiterra(), .dbiterrb(), .sbiterra(), .sbiterrb()
        );

        initial begin
            if (PORTS != 2) $fatal(1, "mem_bytewrite OREG needs two ports");
        end
    end else begin : gen_infer
`else
    if (1'b1) begin : gen_infer
`endif
    (* ram_style = "ultra" *) logic [DATA_WIDTH-1:0] memory [DEPTH];

    for (genvar p = 0; p < PORTS; p++) begin : gen_port
        logic                  read_valid;
        logic [DATA_WIDTH-1:0] read_data;

        always_ff @(posedge clk) begin
            if (rst) read_valid <= 1'b0;
            else read_valid <= req_valid[p] && req_write[p] == '0;
        end

        // Vivado's UltraRAM byte-write template: the write, a read only when no
        // byte is written (URAM is NO_CHANGE), and an enabled output register.
        always @(posedge clk) begin
            if (req_valid[p])
                for (int b = 0; b < BYTES; b++)
                    if (req_write[p][b]) memory[req_addr[p]][8*b +: 8] <= req_wdata[p][8*b +: 8];
        end

        always @(posedge clk) begin
            if (req_valid[p] && req_write[p] == '0) read_data <= memory[req_addr[p]];
        end

        if (OREG) begin : gen_oreg     // simulation model of the XPM's third read cycle
            logic                  oreg_valid;
            logic [DATA_WIDTH-1:0] oreg_data;
            always_ff @(posedge clk) begin
                if (rst) begin
                    oreg_valid   <= 1'b0;
                    rsp_valid[p] <= 1'b0;
                end else begin
                    oreg_valid   <= read_valid;
                    rsp_valid[p] <= oreg_valid;
                end
            end
            always_ff @(posedge clk) if (read_valid) oreg_data <= read_data;
            always_ff @(posedge clk) if (oreg_valid) rsp_rdata[p] <= oreg_data;
        end else begin : gen_reg
            always_ff @(posedge clk) begin
                if (rst) rsp_valid[p] <= 1'b0;
                else rsp_valid[p] <= read_valid;
            end
            always_ff @(posedge clk) if (read_valid) rsp_rdata[p] <= read_data;
        end
    end
    end

endmodule : mem_bytewrite
