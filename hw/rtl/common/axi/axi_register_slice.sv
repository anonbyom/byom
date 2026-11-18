module axi_register_slice #(parameter int WIDTH = 8) (
    input  logic             clk,
    input  logic             rst,
    input  logic             s_valid,
    output logic             s_ready,
    input  logic [WIDTH-1:0] s_data,
    output logic             m_valid,
    input  logic             m_ready,
    output logic [WIDTH-1:0] m_data
);
    logic             saved_valid;
    logic [WIDTH-1:0] saved_data;

    assign s_ready = !saved_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0;
            saved_valid <= 1'b0;
        end else if (m_ready || !m_valid) begin
            m_valid <= saved_valid || s_valid;
            saved_valid <= 1'b0;
        end else if (s_valid && s_ready) begin
            saved_valid <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (m_ready || !m_valid) m_data <= saved_valid ? saved_data : s_data;
        else if (s_valid && s_ready) saved_data <= s_data;
    end
endmodule
