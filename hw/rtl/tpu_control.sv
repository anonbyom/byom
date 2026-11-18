// The kernel's AXI-Lite registers: control, boot arguments, mxu_mode and the performance counters.
module tpu_control #(
    parameter int ADDR_W = 9,
    parameter bit PERF   = 1'b0,
    parameter bit MXU_MODE_ARG = 1'b0,
    parameter logic [31:0] MXU_MODE_RESET = '0
) (
    input  logic              clk,
    input  logic              rst,

    input  logic [ADDR_W-1:0] s_awaddr,
    input  logic              s_awvalid,
    output logic              s_awready,

    input  logic [31:0]       s_wdata,
    input  logic [3:0]        s_wstrb,
    input  logic              s_wvalid,
    output logic              s_wready,

    output logic [1:0]        s_bresp,
    output logic              s_bvalid,
    input  logic              s_bready,

    input  logic [ADDR_W-1:0] s_araddr,
    input  logic              s_arvalid,
    output logic              s_arready,

    output logic [31:0]       s_rdata,
    output logic [1:0]        s_rresp,
    output logic              s_rvalid,
    input  logic              s_rready,

    output logic              start,
    input  logic              idle,
    input  logic              done,
    output logic [31:0]       boot_external_addr,
    output logic [31:0]       boot_imem_addr,
    output logic [31:0]       boot_length,
    output logic [31:0]       mxu_mode,

    input  logic [63:0]       perf_counters [tpu_perf_pkg::COUNT]
);
    localparam logic [ADDR_W-1:0] CONTROL_ADDR       = 'h00;
    localparam logic [ADDR_W-1:0] BOOT_EXTERNAL_ADDR = 'h10;
    localparam logic [ADDR_W-1:0] BOOT_IMEM_ADDR     = 'h14;
    localparam logic [ADDR_W-1:0] BOOT_LENGTH_ADDR   = 'h18;
    localparam logic [ADDR_W-1:0] MXU_MODE_ADDR      = 'h1c;

    logic              waddr_valid_q;
    logic [ADDR_W-1:0] waddr_q;
    logic              wdata_valid_q;
    logic [31:0]       wdata_q;
    logic [3:0]        wstrb_q;
    logic              wresp_valid_q;
    logic              rresp_valid_q;
    logic [31:0]       rdata_q;
    logic              start_q;
    logic              done_q;
    logic [31:0]       boot_external_addr_q;
    logic [31:0]       boot_imem_addr_q;
    logic [31:0]       boot_length_q;
    logic [31:0]       mxu_mode_arg_q;
    logic [31:0]       mxu_mode_q;
    logic              write_commit;
    logic              read_accept;
    logic              write_start;
    logic              read_control;
    logic [31:0]       perf_high_q;     // high word of the last counter read
    logic              perf_read;
    int unsigned       perf_index;

    assign s_awready = !waddr_valid_q && !wresp_valid_q;
    assign s_wready  = !wdata_valid_q && !wresp_valid_q;
    assign s_bvalid  = wresp_valid_q;
    assign s_bresp   = axi_pkg::OKAY;
    assign s_arready = !rresp_valid_q;
    assign s_rvalid  = rresp_valid_q;
    assign s_rdata   = rdata_q;
    assign s_rresp   = axi_pkg::OKAY;

    assign write_commit = waddr_valid_q && wdata_valid_q && !wresp_valid_q;
    assign read_accept  = s_arvalid && s_arready;
    assign write_start  = write_commit && waddr_q == CONTROL_ADDR && wstrb_q[0];
    assign read_control = read_accept && s_araddr == CONTROL_ADDR;
    assign perf_index   = (int'(s_araddr) - tpu_perf_pkg::PERF_BASE) / 8;
    assign perf_read    = PERF && int'(s_araddr) >= tpu_perf_pkg::PERF_BASE &&
                          perf_index < tpu_perf_pkg::COUNT;

    assign start              = start_q;
    assign boot_external_addr = boot_external_addr_q;
    assign boot_imem_addr     = boot_imem_addr_q;
    assign boot_length        = boot_length_q;
    assign mxu_mode           = MXU_MODE_ARG ? mxu_mode_q : MXU_MODE_RESET;

    // Write channel: address and data in any order, then one response.
    always_ff @(posedge clk) begin
        if (rst) begin
            waddr_valid_q <= 1'b0;
            wdata_valid_q <= 1'b0;
            wresp_valid_q <= 1'b0;
        end else if (write_commit) begin
            waddr_valid_q <= 1'b0;
            wdata_valid_q <= 1'b0;
            wresp_valid_q <= 1'b1;
        end else begin
            if (s_awvalid && s_awready) waddr_valid_q <= 1'b1;
            if (s_wvalid && s_wready) wdata_valid_q <= 1'b1;
            if (s_bready) wresp_valid_q <= 1'b0;
        end
    end
    always_ff @(posedge clk) begin
        if (s_awvalid && s_awready) waddr_q <= s_awaddr;
        if (s_wvalid && s_wready) begin
            wdata_q <= s_wdata;
            wstrb_q <= s_wstrb;
        end
    end

    // Control and arguments.
    always_ff @(posedge clk) begin
        if (rst) begin
            start_q              <= 1'b0;
            done_q               <= 1'b0;
            boot_external_addr_q <= '0;
            boot_imem_addr_q     <= '0;
            boot_length_q        <= '0;
            mxu_mode_arg_q       <= MXU_MODE_RESET;
            mxu_mode_q           <= MXU_MODE_RESET;
        end else begin
            if (write_start) start_q <= wdata_q[0];
            else if (start_q && idle) start_q <= 1'b0;
            if (write_start && wdata_q[0]) mxu_mode_q <= mxu_mode_arg_q;

            if (done) done_q <= 1'b1;
            else if (read_control) done_q <= 1'b0;

            if (write_commit) begin
                for (int byte_index = 0; byte_index < 4; byte_index++) begin
                    if (wstrb_q[byte_index]) begin
                        case (waddr_q)
                            BOOT_EXTERNAL_ADDR:
                                boot_external_addr_q[8*byte_index +: 8] <= wdata_q[8*byte_index +: 8];
                            BOOT_IMEM_ADDR:
                                boot_imem_addr_q[8*byte_index +: 8]     <= wdata_q[8*byte_index +: 8];
                            BOOT_LENGTH_ADDR:
                                boot_length_q[8*byte_index +: 8]        <= wdata_q[8*byte_index +: 8];
                            MXU_MODE_ADDR:
                                if (MXU_MODE_ARG) mxu_mode_arg_q[8*byte_index +: 8] <= wdata_q[8*byte_index +: 8];
                            default: ;
                        endcase
                    end
                end
            end
        end
    end

    // Read channel.
    always_ff @(posedge clk) begin
        if (rst) rresp_valid_q <= 1'b0;
        else if (read_accept) rresp_valid_q <= 1'b1;
        else if (s_rready) rresp_valid_q <= 1'b0;
    end
    always_ff @(posedge clk) begin
        if (read_accept) begin
            if (perf_read) begin
                // Low word first: it latches the high word, so a 64-bit read is coherent.
                if (!s_araddr[2]) begin
                    rdata_q     <= perf_counters[perf_index][31:0];
                    perf_high_q <= perf_counters[perf_index][63:32];
                end else begin
                    rdata_q <= perf_high_q;
                end
            end else begin
                case (int'(s_araddr))
                    int'(CONTROL_ADDR):            rdata_q <= {28'd0, idle, idle, done_q, start_q};
                    int'(BOOT_EXTERNAL_ADDR):      rdata_q <= boot_external_addr_q;
                    int'(BOOT_IMEM_ADDR):          rdata_q <= boot_imem_addr_q;
                    int'(BOOT_LENGTH_ADDR):        rdata_q <= boot_length_q;
                    int'(MXU_MODE_ADDR):           rdata_q <= mxu_mode_arg_q;
                    tpu_perf_pkg::PERF_ID_ADDR:    rdata_q <= PERF ? tpu_perf_pkg::PERF_ID : '0;
                    tpu_perf_pkg::PERF_COUNT_ADDR: rdata_q <= PERF ? tpu_perf_pkg::COUNT : '0;
                    default:                       rdata_q <= '0;
                endcase
            end
        end
    end
endmodule : tpu_control
