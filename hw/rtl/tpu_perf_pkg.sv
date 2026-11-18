package tpu_perf_pkg;
    typedef enum int unsigned {
        TOTAL,
        CYCLES,
        ISSUES,
        BUBBLE,
        STALL_SCALAR,
        STALL_DMA_WAIT,
        STALL_POP,
        STALL_PUSH,
        STALL_VEX,
        STALL_MM_QUEUE,
        STALL_MM_OUTPUT,
        STALL_OTHER,
        REFETCH,
        STALL_XLU_ORDER,
        STALL_XLU_TILE,
        COUNT_
    } counter_t;
    localparam int unsigned COUNT = COUNT_;
    localparam int unsigned PERF_BASE = 'h180;
    localparam int unsigned PERF_ID_ADDR = 'h170;
    localparam int unsigned PERF_COUNT_ADDR = 'h174;
    localparam logic [31:0] PERF_ID = 32'h50455246;
endpackage
