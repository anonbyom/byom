module vector_dma_response #(
    parameter int DEPTH = 32,
    parameter int LATENCY = 20,
    parameter int WORDS = 16,
    parameter int WORD_WIDTH = 16,
    localparam int COUNT_W = $clog2(DEPTH + 1),
    localparam int ENTRY_W = 2 * WORD_WIDTH    // each word returns as two halves on consecutive cycles
) (
    input  logic                        clk,
    input  logic                        rst,
    input  logic                        req_valid,
    output logic                        req_ready,
    input  logic                        word_valid     [WORDS],
    input  logic [WORD_WIDTH-1:0]       word_data      [WORDS],
    output logic                        response_valid,
    input  logic                        response_ready,
    output logic [WORDS*ENTRY_W-1:0]    response_data
);
    logic [COUNT_W-1:0] reserved_q;
    logic [COUNT_W-1:0] available_q;
    logic               response_valid_q;
    logic               mature;
    logic               read_fire;
    logic               response_fire;

    assign response_valid = response_valid_q;
    assign req_ready      = reserved_q < COUNT_W'(DEPTH);
    assign read_fire      = req_valid && req_ready;
    assign response_fire  = response_valid && response_ready;

    shifter #(
        .WIDTH(1),
        .LENGTH(LATENCY + 1)
    ) u_mature (
        .clk,
        .rst,
        .en (1'b1),
        .d  (read_fire),
        .q  (mature)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            reserved_q <= '0;
            available_q <= '0;
            response_valid_q <= 1'b0;
        end else begin
            case ({read_fire, response_fire})
                2'b10: reserved_q <= reserved_q + 1'b1;
                2'b01: reserved_q <= reserved_q - 1'b1;
                default: ;
            endcase
            case ({mature, response_fire})
                2'b10: begin
                    available_q <= available_q + 1'b1;
                    response_valid_q <= 1'b1;
                end
                2'b01: begin
                    available_q <= available_q - 1'b1;
                    response_valid_q <= available_q != 1;
                end
                default: ;
            endcase
        end
    end

    for (genvar word = 0; word < WORDS; word++) begin : gen_word
        logic                  rx_valid;
        logic [WORD_WIDTH-1:0] rx_data;

        // A receive register on this side of the SLR boundary.
        shifter #(
            .WIDTH(1),
            .LENGTH(1)
        ) u_rx_valid (
            .clk,
            .rst,
            .en (1'b1),
            .d  (word_valid[word]),
            .q  (rx_valid)
        );
        shifter #(
            .WIDTH(WORD_WIDTH),
            .LENGTH(1)
        ) u_rx_data (
            .clk,
            .rst (1'b0),
            .en  (1'b1),
            .d   (word_data[word]),
            .q   (rx_data)
        );

        logic               entry_valid;
        logic [ENTRY_W-1:0] entry_data;
        logic [ENTRY_W-1:0] r_data;

        logic                  upper_q;
        logic [WORD_WIDTH-1:0] lower_q;

        always_ff @(posedge clk) begin
            if (rst) upper_q <= 1'b0;
            else if (rx_valid) upper_q <= !upper_q;
            if (rx_valid && !upper_q) lower_q <= rx_data;
        end
        assign entry_valid = rx_valid && upper_q;
        assign entry_data  = {rx_data, lower_q};
        assign response_data[WORD_WIDTH*word +: WORD_WIDTH] = r_data[WORD_WIDTH-1:0];
        assign response_data[WORD_WIDTH*(WORDS + word) +: WORD_WIDTH] = r_data[ENTRY_W-1 -: WORD_WIDTH];

        fifo #(
            .DATA_WIDTH(ENTRY_W),
            .DEPTH(DEPTH),
            .RESERVED_WRITES(1'b1),
            .READ_READY_BYPASS(DEPTH == 1)
        ) u_response (
            .clk,
            .rst,
            .w_en    (entry_valid),
            .w_data  (entry_data),
            .w_rdy   (),
            .r_en    (response_fire),
            .r_valid (),
            .r_data  (r_data),
            .level   ()
        );
    end
endmodule
