module scalar_dma_control (
    input  logic                  clk,
    input  logic                  rst,

    input  logic                  enable,

    input  logic                  boot_req_valid,
    output logic                  boot_req_ready,
    input  isa_pkg::scalar_word_t boot_req_external_addr,
    input  isa_pkg::scalar_word_t boot_req_imem_addr,
    input  isa_pkg::scalar_word_t boot_req_length,
    output logic                  boot_done,

    input  logic                  req_valid,
    output logic                  req_ready,
    input  isa_pkg::direction_t   req_direction,
    input  isa_pkg::scalar_word_t req_src_addr,
    input  isa_pkg::scalar_word_t req_dst_addr,
    input  isa_pkg::scalar_word_t req_length,
    output logic                  done,

    output logic                  dma_read_req_valid,
    input  logic                  dma_read_req_ready,
    output logic                  dma_read_local_write_sel,
    output isa_pkg::scalar_word_t dma_read_external_addr,
    output isa_pkg::scalar_word_t dma_read_length,
    input  logic                  dma_read_done,

    output logic                  dma_write_req_valid,
    input  logic                  dma_write_req_ready,
    output logic                  dma_write_local_read_sel,
    output isa_pkg::scalar_word_t dma_write_external_addr,
    output isa_pkg::scalar_word_t dma_write_length,
    input  logic                  dma_write_done,

    output logic                  vector_dma_start,
    output logic                  vector_dma_write,
    output isa_pkg::scalar_word_t vector_dma_base,
    output isa_pkg::scalar_word_t vector_dma_length,

    output logic                  lmem_write_start,
    input  logic                  lmem_write_done,
    output logic                  lmem_write_imem,
    output isa_pkg::scalar_word_t lmem_write_base,

    output logic                  lmem_read_start,
    output isa_pkg::scalar_word_t lmem_read_base
);
    import isa_pkg::*;

    typedef struct packed {
        direction_t   direction;
        scalar_word_t source;
        scalar_word_t destination;
        scalar_word_t length;
    } command_t;

    command_t command_q;
    logic     pending_q;
    logic     boot_active_q;
    logic     boot_select;
    logic     read_command;
    logic     scalar_write_active_q;
    logic     channels_done_q;
    logic     memory_done_q;
    logic     scalar_write_complete;
    logic     read_complete;
    logic     read_fire;
    logic     write_fire;

    assign req_ready                = !pending_q && !boot_active_q && !scalar_write_active_q;
    assign boot_select              = !enable && boot_req_valid && req_ready;
    assign boot_req_ready           = !enable && req_ready && dma_read_req_ready;
    assign read_command             = command_q.direction inside {HBM_TO_IMEM, HBM_TO_SMEM, HBM_TO_VMEM};

    assign dma_read_req_valid       = boot_select || (pending_q && read_command);
    assign dma_read_local_write_sel = !boot_select && command_q.direction == HBM_TO_VMEM;
    assign dma_read_external_addr   = boot_select ? boot_req_external_addr : command_q.source;
    assign dma_read_length          = boot_select ? boot_req_length : command_q.length;

    assign dma_write_req_valid      = pending_q && !read_command;
    assign dma_write_local_read_sel = command_q.direction == VMEM_TO_HBM;
    assign dma_write_external_addr  = command_q.destination;
    assign dma_write_length         = command_q.length;

    assign read_fire                = dma_read_req_valid && dma_read_req_ready;
    assign write_fire               = dma_write_req_valid && dma_write_req_ready;

    assign vector_dma_start         = (read_fire && dma_read_local_write_sel) || (write_fire && dma_write_local_read_sel);
    assign vector_dma_write         = read_command;
    assign vector_dma_base          = read_command ? command_q.destination : command_q.source;
    assign vector_dma_length        = command_q.length;

    assign lmem_write_start         = read_fire && !dma_read_local_write_sel;
    assign lmem_write_imem          = boot_select || command_q.direction == HBM_TO_IMEM;
    assign lmem_write_base          = boot_select ? boot_req_imem_addr : command_q.destination;
    assign lmem_read_start          = write_fire && !dma_write_local_read_sel;
    assign lmem_read_base           = command_q.source;

    always_ff @(posedge clk) begin
        if (rst) pending_q <= 1'b0;
        else if (req_valid && req_ready) begin
            pending_q <= 1'b1;
            command_q <= '{direction: req_direction, source: req_src_addr, destination: req_dst_addr, length: req_length};
        end else if (read_fire || write_fire) pending_q <= 1'b0;
    end

    assign scalar_write_complete = (channels_done_q || dma_read_done) && (memory_done_q || lmem_write_done);
    assign read_complete         = scalar_write_active_q ? scalar_write_complete : dma_read_done;
    assign boot_done             = boot_active_q && read_complete;
    assign done                  = (read_complete && !boot_active_q) || dma_write_done;

    always_ff @(posedge clk) begin
        if (rst) begin
            boot_active_q         <= 1'b0;
            scalar_write_active_q <= 1'b0;
            channels_done_q       <= 1'b0;
            memory_done_q         <= 1'b0;
        end else begin
            if (boot_select && dma_read_req_ready) boot_active_q <= 1'b1;
            else if (read_complete)                boot_active_q <= 1'b0;

            if (lmem_write_start) begin
                scalar_write_active_q <= 1'b1;
                channels_done_q       <= 1'b0;
                memory_done_q         <= 1'b0;
            end else if (scalar_write_active_q) begin
                if (dma_read_done) channels_done_q       <= 1'b1;
                if (lmem_write_done) memory_done_q       <= 1'b1;
                if (read_complete) scalar_write_active_q <= 1'b0;
            end
        end
    end
endmodule
