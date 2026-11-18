module lane_memory #(
    parameter int unsigned VREG_COUNT    = 16,
    parameter int unsigned ELEMENT_WIDTH = isa_pkg::VECTOR_ELEMENT_WIDTH,
    parameter int unsigned SUBLANES      = 4,
    parameter int unsigned BANKS         = 16,
    parameter int unsigned VMEM_DEPTH    = 32768,
    parameter bit          URAM_OREG     = 1'b0,

    localparam int unsigned VREG_ADDR_WIDTH     = $clog2(VREG_COUNT),
    localparam int unsigned VMEM_ADDR_WIDTH     = $clog2(VMEM_DEPTH),
    localparam int unsigned BANK_WIDTH          = BANKS > 1 ? $clog2(BANKS) : 1,
    localparam int unsigned BANK_DEPTH          = VMEM_DEPTH / BANKS,
    localparam int unsigned BANK_ADDR_WIDTH     = $clog2(BANK_DEPTH),
    localparam int unsigned LOAD_GROUPS         = BANKS / SUBLANES,
    localparam int unsigned LOAD_GROUP_WIDTH    = LOAD_GROUPS > 1 ? $clog2(LOAD_GROUPS) : 1,
    localparam int unsigned LOAD_ROTATION_WIDTH = SUBLANES > 1 ? $clog2(SUBLANES) : 1
) (
    input  logic                        clk,

    input  logic                        vmem_valid,
    input  logic [VMEM_ADDR_WIDTH-1:0]  vmem_addr,
    input  isa_pkg::vmem_stride_t       vmem_stride_m1,
    input  logic [SUBLANES-1:0]         vmem_skip,


    input  logic                        execute_mem_valid,
    input  isa_pkg::vmem_opcode_t       execute_mem_op,
    input  logic [VMEM_ADDR_WIDTH-1:0]  execute_mem_addr,
    input  logic [VREG_ADDR_WIDTH-1:0]  execute_mem_reg,

    input  logic [ELEMENT_WIDTH-1:0]    store_data        [SUBLANES],
    output logic                        load_valid        [SUBLANES],
    output logic [ELEMENT_WIDTH-1:0]    load_data         [SUBLANES][LOAD_GROUPS],
    output logic [LOAD_GROUP_WIDTH-1:0] load_group        [SUBLANES],
    output logic [VREG_ADDR_WIDTH-1:0]  load_dest_q,

    input  logic                        dma_req_valid     [BANKS],
    input  logic                        dma_req_write     [BANKS],
    input  logic [BANK_ADDR_WIDTH-1:0]  dma_req_addr      [BANKS],
    input  logic [ELEMENT_WIDTH-1:0]    dma_req_wdata     [BANKS],
    output logic [ELEMENT_WIDTH-1:0]    dma_rsp_rdata     [BANKS]
);
    import isa_pkg::*;


    logic [ELEMENT_WIDTH-1:0]   bank_rsp_data       [BANKS];
    logic [BANK_WIDTH-1:0]      load_bank_d         [SUBLANES];
    logic [BANK_WIDTH-1:0]      load_bank_q         [SUBLANES];
    logic [SUBLANES-1:0]        load_skip_q;
    logic                       load_response_valid;
    vmem_stride_t               execute_stride_m1_q;
    logic [SUBLANES-1:0]        execute_skip_q;

    always_ff @(posedge clk) begin
        execute_stride_m1_q <= vmem_stride_m1;
        execute_skip_q      <= vmem_skip;
    end

    function automatic logic [SUBLANES-1:0] window_hits(input logic [BANK_WIDTH-1:0] offset, input vmem_stride_t stride_m1);
        for (int unsigned k = 0; k < SUBLANES; k++)
            window_hits[k] = offset == BANK_WIDTH'(k * (unsigned'(int'(stride_m1)) + 1));
    endfunction

    function automatic logic [LOAD_ROTATION_WIDTH-1:0] window_sublane(input logic [SUBLANES-1:0] hits);
        window_sublane = '0;
        for (int unsigned k = 0; k < SUBLANES; k++)
            if (hits[k]) window_sublane |= LOAD_ROTATION_WIDTH'(k);
    endfunction

    for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_load
        assign load_bank_d[sublane] = BANK_WIDTH'(execute_mem_addr) +
            BANK_WIDTH'(unsigned'(sublane) * (unsigned'(int'(execute_stride_m1_q)) + 1));
        assign load_group[sublane] = LOAD_GROUP_WIDTH'(int'(load_bank_q[sublane]) / SUBLANES);
        assign load_valid[sublane] = load_response_valid && !load_skip_q[sublane];

        for (genvar group = 0; group < LOAD_GROUPS; group++) begin : gen_group
            logic [ELEMENT_WIDTH-1:0] inputs [SUBLANES];
            for (genvar element = 0; element < SUBLANES; element++) begin : gen_element
                assign inputs[element] = bank_rsp_data[group * SUBLANES + element];
            end
            assign load_data[sublane][group] = inputs[LOAD_ROTATION_WIDTH'(load_bank_q[sublane])];
        end
    end

    shifter #(
        .WIDTH(1),
        .LENGTH(2 + URAM_OREG)
    ) u_load_valid (
        .clk,
        .rst(1'b0),
        .en (1'b1),
        .d  (execute_mem_valid && execute_mem_op == VLD),
        .q  (load_response_valid)
    );

    for (genvar sublane = 0; sublane < SUBLANES; sublane++) begin : gen_load_meta
        shifter #(
            .WIDTH(BANK_WIDTH + 1),
            .LENGTH(2 + URAM_OREG)
        ) u_load_meta (
            .clk,
            .rst (1'b0),
            .en  (1'b1),
            .d   ({load_bank_d[sublane], execute_skip_q[sublane]}),
            .q   ({load_bank_q[sublane], load_skip_q[sublane]})
        );
    end

    shifter #(
        .WIDTH(VREG_ADDR_WIDTH),
        .LENGTH(2 + URAM_OREG)
    ) u_load_dest (
        .clk,
        .rst (1'b0),
        .en  (1'b1),
        .d   (execute_mem_reg),
        .q   (load_dest_q)
    );

    localparam int unsigned GROUP_WIDTH   = SUBLANES * ELEMENT_WIDTH;
    localparam int unsigned ELEMENT_BYTES = ELEMENT_WIDTH / 8;

    // Bank group g (banks g*SUBLANES ..) is one URAM word, its active elements share one row (row + 1 when the
    // group lies below the window start).
    for (genvar group = 0; group < LOAD_GROUPS; group++) begin : gen_uram
        logic                       active_q     [SUBLANES];
        logic [LOAD_ROTATION_WIDTH-1:0] store_source [SUBLANES];
        logic [SUBLANES-1:0]        slot_hit;
        logic [VMEM_ADDR_WIDTH-1:0] addr;
        logic                       req_valid    [2];
        logic [GROUP_WIDTH/8-1:0]   req_write    [2];
        logic [BANK_ADDR_WIDTH-1:0] req_addr     [2];
        logic [GROUP_WIDTH-1:0]     req_wdata    [2];
        logic                       rsp_valid    [2];
        logic [GROUP_WIDTH-1:0]     rsp_data     [2];
        logic [SUBLANES-1:0]        active;

        for (genvar k = 0; k < SUBLANES; k++) begin : gen_element
            localparam int BANK = group * SUBLANES + k;
            wire [SUBLANES-1:0] hits = window_hits(BANK_WIDTH'(BANK) - BANK_WIDTH'(vmem_addr), vmem_stride_m1);
            assign slot_hit[k] = vmem_valid && |(hits & ~vmem_skip);

            always_ff @(posedge clk) begin
                active_q[k] <= slot_hit[k];
                store_source[k] <= window_sublane(hits);
            end

            assign active[k] = active_q[k];
            assign req_write[0][k*ELEMENT_BYTES +: ELEMENT_BYTES] = {ELEMENT_BYTES{execute_mem_op == VST &&
                active_q[k]}};
            assign req_wdata[0][k*ELEMENT_WIDTH +: ELEMENT_WIDTH] = store_data[store_source[k]];
            assign bank_rsp_data[BANK] = rsp_data[0][k*ELEMENT_WIDTH +: ELEMENT_WIDTH];

            assign req_wdata[1][k*ELEMENT_WIDTH +: ELEMENT_WIDTH] = dma_req_wdata[BANK];
            assign dma_rsp_rdata[BANK] = rsp_data[1][k*ELEMENT_WIDTH +: ELEMENT_WIDTH];
        end

        assign addr      = vmem_addr;
        always_ff @(posedge clk) begin
            req_addr[0] <= BANK_ADDR_WIDTH'(addr >> BANK_WIDTH) +
                BANK_ADDR_WIDTH'((group + 1) * SUBLANES - 1 < int'(BANK_WIDTH'(addr)));
        end
        assign req_valid[0] = |active;

        assign req_valid[1] = dma_req_valid[group * SUBLANES];
        assign req_write[1] = {(GROUP_WIDTH/8){dma_req_write[group * SUBLANES]}};
        assign req_addr[1]  = dma_req_addr[group * SUBLANES];

        mem_bytewrite #(
            .DATA_WIDTH(GROUP_WIDTH),
            .DEPTH(BANK_DEPTH),
            .PORTS(2),
            .OREG(URAM_OREG)
        ) u_uram (
            .clk,
            .rst(1'b0),
            .req_valid (req_valid),
            .req_write (req_write),
            .req_addr  (req_addr),
            .req_wdata (req_wdata),
            .rsp_valid (rsp_valid),
            .rsp_rdata (rsp_data)
        );
    end

    initial begin
        if (ELEMENT_WIDTH % 8 != 0) $fatal(1, "URAM VMEM needs byte-aligned elements");
    end
endmodule : lane_memory
