module dma_scalar_adapter #(
    parameter int unsigned CHANNELS = 32,
    parameter int unsigned SCALAR_W = 32,
    parameter int unsigned IMEM_DEPTH = 1024,
    parameter int unsigned SMEM_DEPTH = 1024,
    parameter int unsigned BEAT_W = 256,

    localparam int unsigned BUS_LANES = 4,
    localparam int unsigned PACKET_W = BUS_LANES * SCALAR_W,
    localparam int unsigned IMEM_ADDR_W = $clog2(IMEM_DEPTH),
    localparam int unsigned SMEM_ADDR_W = $clog2(SMEM_DEPTH)
) (
    input  logic                   clk,
    input  logic                   rst,

    input  logic                   write_valid    [CHANNELS],
    output logic                   write_ready    [CHANNELS],
    output logic                   write_done,
    input  logic                   write_start,
    input  logic                   write_imem,
    input  logic                   write_fast     [CHANNELS],
    input  logic [SCALAR_W-1:0]    write_base,
    input  logic [SCALAR_W-1:0]    write_length,
    input  logic [BEAT_W-1:0]      write_data     [CHANNELS],

    input  logic                   read_start,
    input  logic [SCALAR_W-1:0]    read_base,
    input  logic [SCALAR_W-1:0]    read_length,

    output logic                   response_valid [CHANNELS],
    input  logic                   response_ready [CHANNELS],
    output logic [BEAT_W-1:0]      response_data  [CHANNELS],

    output logic                   imem_valid,
    output logic [IMEM_ADDR_W-1:0] imem_addr,
    output isa_pkg::bundle_t       imem_data,

    output logic                   smem_write_valid,
    output logic [SMEM_ADDR_W-1:0] smem_write_addr,
    output logic [SCALAR_W-1:0]    smem_write_data,
    output logic                   smem_read_valid,
    output logic [SMEM_ADDR_W-1:0] smem_read_addr,
    input  logic                   smem_resp_valid,
    input  logic [SCALAR_W-1:0]    smem_resp_data
);
    dma_scalar_write #(
        .CHANNELS(CHANNELS),
        .SCALAR_W(SCALAR_W),
        .IMEM_DEPTH(IMEM_DEPTH),
        .SMEM_DEPTH(SMEM_DEPTH),
        .BEAT_W(BEAT_W)
    ) write_transport (
        .clk,
        .rst,
        .write_valid,
        .write_ready,
        .write_done,
        .write_length,
        .write_imem,
        .write_fast,
        .write_start,
        .write_base,
        .write_data,

        .imem_valid,
        .imem_addr,
        .imem_data,

        .smem_valid (smem_write_valid),
        .smem_addr  (smem_write_addr),
        .smem_data  (smem_write_data)
    );

    dma_scalar_read #(
        .CHANNELS(CHANNELS),
        .SCALAR_W(SCALAR_W),
        .DEPTH(SMEM_DEPTH),
        .BEAT_W(BEAT_W)
    ) read_transport (
        .clk,
        .rst,

        .read_start,
        .read_base,
        .read_length,

        .response_valid,
        .response_ready,
        .response_data,

        .mem_valid      (smem_read_valid),
        .mem_addr       (smem_read_addr),
        .mem_resp_valid (smem_resp_valid),
        .mem_resp_data  (smem_resp_data)
    );
endmodule
