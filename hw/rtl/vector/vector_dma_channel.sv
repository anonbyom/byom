module vector_dma_channel #(
    parameter int unsigned ADDR_WIDTH    = 10,
    parameter int unsigned FIFO_DEPTH    = 32,
    parameter int unsigned RETURN_STAGES = 1,
    parameter int unsigned WORDS         = 16,
    parameter int unsigned WORD_WIDTH    = 16,
    parameter int unsigned MEM_OUTPUT_REG = 0,   // lane memory read registers beyond the first
    parameter int unsigned LANE_WORDS    = 1,    // consecutive words of a beat for one lane (one stagger tap)

    localparam int unsigned DATA_WIDTH = WORDS * WORD_WIDTH,
    localparam int unsigned LINK_WORDS = WORDS / 2,    // a beat crosses as two halves on consecutive cycles
    localparam int unsigned LINK_WIDTH = LINK_WORDS * WORD_WIDTH,
    localparam int unsigned TAPS = LINK_WORDS / LANE_WORDS,
    localparam int unsigned COUNT_WIDTH = ADDR_WIDTH + 1,
    localparam int unsigned INPUT_STAGES = 2,
    localparam int unsigned MEMORY_RESPONSE_STAGES = 3 + MEM_OUTPUT_REG,
    localparam int unsigned WRITE_LATENCY = INPUT_STAGES + 1 + WORDS,
    localparam int unsigned RESPONSE_LATENCY = INPUT_STAGES + 1 + WORDS + MEMORY_RESPONSE_STAGES + WORDS * RETURN_STAGES
) (
    input  logic                   clk,
    input  logic                   rst,
    input  logic                   start,
    input  logic                   write,
    input  logic [ADDR_WIDTH-1:0]  base,
    input  logic [COUNT_WIDTH-1:0] length,

    input  logic                   write_valid,
    output logic                   write_ready,
    input  logic [DATA_WIDTH-1:0]  write_data,
    output logic                   write_idle,
    output logic                   response_valid,
    input  logic                   response_ready,
    output logic [DATA_WIDTH-1:0]  response_data,

    output logic                   req_valid      [LINK_WORDS],
    output logic                   req_write      [LINK_WORDS],
    output logic                   req_upper      [LINK_WORDS],
    output logic [ADDR_WIDTH-1:0]  req_addr       [LINK_WORDS],
    output logic [WORD_WIDTH-1:0]  req_data       [LINK_WORDS],
    input  logic [WORD_WIDTH-1:0]  word_data      [LINK_WORDS]
);
    typedef struct packed {
        logic                  valid;
        logic                  write;
        logic                  upper;
        logic [ADDR_WIDTH-1:0] addr;
        logic [LINK_WIDTH-1:0] data;
    } request_t;

    request_t                     accepted_q;
    request_t                     request_q;
    request_t                     delayed         [TAPS];
    logic                         second_q;
    logic     [LINK_WIDTH-1:0]    upper_q;
    logic                         beat_accepted;
    logic                         write_q;
    logic     [ADDR_WIDTH-1:0]    address_q;
    logic     [COUNT_WIDTH-1:0]   remaining_q;
    logic                         pending_q;
    logic                         start_c;
    logic                         write_c;
    logic     [ADDR_WIDTH-1:0]    base_c;
    logic     [COUNT_WIDTH-1:0]   length_c;
    logic     [WRITE_LATENCY-1:0] write_pending_q;
    logic                         response_space;
    logic     [COUNT_WIDTH-1:0]   remaining;
    logic                         read_valid;
    logic                         read_fire;
    logic                         write_fire;
    logic                         arrived [LINK_WORDS];
    function automatic int unsigned arrival(int unsigned word, int unsigned half);
        return INPUT_STAGES + half + word / LANE_WORDS + MEMORY_RESPONSE_STAGES + (word / LANE_WORDS + 1) * RETURN_STAGES;
    endfunction
    localparam int unsigned LAST_ARRIVAL = arrival(LINK_WORDS - 1, 1);

    assign beat_accepted = accepted_q.valid && !accepted_q.upper;
    assign remaining   = remaining_q - COUNT_WIDTH'(beat_accepted);
    assign read_valid  = pending_q && !write_q && !second_q;
    assign read_fire   = read_valid && response_space;
    assign write_ready = pending_q && write_q && !second_q;
    assign write_fire  = write_valid && write_ready;
    assign write_idle  = write_pending_q == 0;

    logic                   held_q;
    logic                   held_write_q;
    logic [ADDR_WIDTH-1:0]  held_base_q;
    logic [COUNT_WIDTH-1:0] held_length_q;
    assign start_c  = !pending_q && (held_q || start);
    assign write_c  = held_q ? held_write_q : write;
    assign base_c   = held_q ? held_base_q : base;
    assign length_c = held_q ? held_length_q : length;
    always_ff @(posedge clk) begin
        if (start && (pending_q || held_q)) begin
            held_write_q  <= write;
            held_base_q   <= base;
            held_length_q <= length;
        end
    end
    always_ff @(posedge clk) begin
        if (rst) held_q <= 1'b0;
        else if (start && (pending_q || held_q)) held_q <= 1'b1;
        else if (start_c) held_q <= 1'b0;
    end

    vector_dma_response #(
        .DEPTH(FIFO_DEPTH),
        .LATENCY(RESPONSE_LATENCY),
        .WORDS(LINK_WORDS),
        .WORD_WIDTH(WORD_WIDTH)
    ) u_response (
        .clk,
        .rst,
        .req_valid (read_valid),
        .req_ready (response_space),
        .word_valid (arrived),
        .word_data,
        .response_valid,
        .response_ready,
        .response_data
    );

    logic [0:0] read_taps [LAST_ARRIVAL + 1];
    shifter_taps #(
        .WIDTH(1),
        .LENGTH(LAST_ARRIVAL)
    ) u_arrival (
        .clk,
        .rst,
        .en (1'b1),
        .d  (read_fire),
        .q  (read_taps)
    );
    for (genvar word = 0; word < LINK_WORDS; word++) begin : gen_arrived
        assign arrived[word] = read_taps[arrival(word, 0)][0] || read_taps[arrival(word, 1)][0];
    end

    shifter_taps #(
        .WIDTH($bits(request_t)),
        .LENGTH(TAPS - 1)
    ) u_request (
        .clk,
        .rst (1'b0),
        .en  (1'b1),
        .d   (request_q),
        .q   (delayed)
    );

    for (genvar word = 0; word < LINK_WORDS; word++) begin : gen_word
        assign req_valid[word] = delayed[word / LANE_WORDS].valid;
        assign req_write[word] = delayed[word / LANE_WORDS].write;
        assign req_upper[word] = delayed[word / LANE_WORDS].upper;
        assign req_addr[word] = delayed[word / LANE_WORDS].addr;
        assign req_data[word] = delayed[word / LANE_WORDS].data[WORD_WIDTH*word +: WORD_WIDTH];
    end

    always_ff @(posedge clk) begin
        if (second_q) begin
            accepted_q.data <= upper_q;
        end else begin
            accepted_q.write <= write_fire;
            accepted_q.data  <= write_data[LINK_WIDTH-1:0];
        end
        accepted_q.upper <= second_q;
        upper_q          <= write_data[DATA_WIDTH-1 -: LINK_WIDTH];
        request_q.write  <= accepted_q.write;
        request_q.upper  <= accepted_q.upper;
        if (!accepted_q.upper) request_q.addr <= address_q;
        request_q.data   <= accepted_q.data;
        if (start_c) begin
            write_q   <= write_c;
            address_q <= base_c;
        end else if (beat_accepted) begin
            address_q <= address_q + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            accepted_q.valid <= 1'b0;
            second_q         <= 1'b0;
            request_q.valid  <= 1'b0;
            write_pending_q  <= '0;
            remaining_q      <= '0;
            pending_q        <= 1'b0;
        end else begin
            accepted_q.valid <= write_fire || read_fire || second_q;
            second_q         <= write_fire || read_fire;
            request_q.valid  <= accepted_q.valid;
            write_pending_q  <= {write_pending_q[WRITE_LATENCY-2:0], write_fire};
            if (start_c) remaining_q <= length_c;
            else if (beat_accepted) remaining_q <= remaining_q - 1'b1;
            if (start_c) pending_q <= length_c != 0;
            else if (write_fire || read_fire) pending_q <= remaining != 1;
        end
    end

    initial begin
        if (DATA_WIDTH != 256) $fatal(1, "The vector DMA channel must preserve the 256-bit external beat");
        if (LINK_WORDS % LANE_WORDS != 0) $fatal(1, "A link half must hold whole lanes");
    end
endmodule
