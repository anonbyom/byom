// One output column, a beat's products through the accumulator, or straight to BF16.
module mxu_output #(
    parameter int unsigned  ROWS       = 1,
    parameter int unsigned  IN_W       = 16,
    parameter bit           FLOAT      = 1'b0,
    parameter bit           SUM        = 1'b0,
    parameter int unsigned  SUM_STAGES = 1,
    parameter bit           ACC_ENABLE = 1'b0,
    parameter int unsigned  ACC_ROWS   = 1024,
    parameter bit           ACC_FP32   = 1'b0,
    localparam int unsigned BF16_WIDTH = 16
) (
    input  logic                         clk,
    input  logic                         rst,
    input  logic                         ctrl_valid,
    input  logic                         ctrl_first,
    input  logic [1:0]                   ctrl_mode,
    input  logic                         product_valid,
    input  logic [IN_W-1:0]              product   [ROWS],
    output logic                         psum_valid,
    output logic [ROWS*BF16_WIDTH-1:0]   psum_data
);
    logic                  out_valid;
    logic [BF16_WIDTH-1:0] bf16 [ROWS];
    logic [ROWS*BF16_WIDTH-1:0] out_data;

    for (genvar row = 0; row < ROWS; row++) begin : gen_pack
        assign out_data[BF16_WIDTH*row +: BF16_WIDTH] = bf16[row];
    end

    if (ACC_ENABLE) begin : gen_acc
        mxu_accumulator #(
            .DEPTH((ACC_ROWS + ROWS - 1) / ROWS),
            .FP32(ACC_FP32),
            .INT(!FLOAT && !SUM),
            .INT_WIDTH(IN_W),
            .SUM(SUM),
            .SUM_WIDTH(IN_W),
            .SUM_STAGES(SUM_STAGES),
            .ROWS(ROWS)
        ) u_acc (
            .clk,
            .rst,
            .ctrl_valid,
            .ctrl_first,
            .ctrl_mode,
            .product_valid,
            .product,
            .out_valid,
            .out_data (bf16),
            .out_int  ()
        );
    end else if (SUM) begin : gen_sum
        for (genvar row = 0; row < ROWS; row++) begin : gen_row
            sum_impl #(
                .P_BITS(IN_W)
            ) u_bf16 (
                .sum   (product[row]),
                .value (bf16[row])
            );
        end
        assign out_valid = product_valid;
    end else if (FLOAT) begin : gen_direct
        assign bf16      = product;
        assign out_valid = product_valid;
    end else begin : gen_convert
        for (genvar row = 0; row < ROWS; row++) begin : gen_row
            int_to_bf16 #(
                .WIDTH(IN_W)
            ) u_bf16 (
                .clk,
                .value (product[row]),
                .bf16  (bf16[row])
            );
        end
        shifter #(
            .WIDTH(1),
            .LENGTH(1)
        ) u_valid (
            .clk,
            .rst,
            .en (1'b1),
            .d  (product_valid),
            .q  (out_valid)
        );
    end

    always_ff @(posedge clk) begin
        if (rst) psum_valid <= 1'b0;
        else psum_valid <= out_valid;
        psum_data <= out_data;
    end
endmodule : mxu_output
