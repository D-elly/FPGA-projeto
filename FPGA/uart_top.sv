// uart_top.sv
// UART Top-Level Module - SystemVerilog
// Integração completa para comunicação FPGA <-> Raspberry Pi Pico
//
// Este módulo integra transmissor e receptor UART para comunicação bidirecional
// Configuração: 115200 baud, 8N1, 50 MHz clock
//
// Conexões com Raspberry Pi Pico:
//   FPGA TX -> Pico RX (GP1 ou outro pino UART)
//   FPGA RX <- Pico TX (GP0 ou outro pino UART)
//   GND     -> GND (compartilhado)
// Inclui lpf digital para suavizar bytes recebidos

module uart_top #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter BAUD_RATE   = 115200
) (
    input  logic       i_clk,
    input  logic       i_rst_n,

    // Interface UART física
    input  logic       i_uart_rx,
    output logic       o_uart_tx,

    // Interface de transmissão
    input  logic       i_tx_dv,
    input  logic [7:0] i_tx_byte,
    output logic       o_tx_active,
    output logic       o_tx_done,

    // Interface de recepção original
    output logic       o_rx_dv,
    output logic [7:0] o_rx_byte,

    // Interface de recepção filtrada (nova)
    output logic       o_rx_filtered_dv,
    output logic [7:0] o_rx_filtered_byte
);

    localparam int CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;

    // Transmissor UART
    uart_tx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) uart_tx_inst (
        .i_clk       (i_clk),
        .i_rst_n     (i_rst_n),
        .i_tx_dv     (i_tx_dv),
        .i_tx_byte   (i_tx_byte),
        .o_tx_serial (o_uart_tx),
        .o_tx_active (o_tx_active),
        .o_tx_done   (o_tx_done)
    );

    // Receptor UART
    uart_rx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) uart_rx_inst (
        .i_clk       (i_clk),
        .i_rst_n     (i_rst_n),
        .i_rx_serial (i_uart_rx),
        .o_rx_dv     (o_rx_dv),
        .o_rx_byte   (o_rx_byte)
    );

    // Filtro passa-baixa digital
    lpf_byte #(
        .ALPHA_SHIFT(3)  // α = 1/8
    ) lpf_inst (
        .i_clk      (i_clk),
        .i_rst_n    (i_rst_n),
        .i_valid    (o_rx_dv),
        .i_data     (o_rx_byte),
        .o_filtered (o_rx_filtered_byte),
        .o_valid    (o_rx_filtered_dv)
    );

endmodule

// Módulo LPF simples para bytes UART
module lpf_byte #(
    parameter ALPHA_SHIFT = 3
)(
    input  logic        i_clk,
    input  logic        i_rst_n,
    input  logic        i_valid,
    input  logic [7:0]  i_data,
    output logic [7:0]  o_filtered,
    output logic        o_valid
);

    logic [10:0] acc;
    logic        valid_d;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            acc      <= 0;
            valid_d  <= 0;
        end else if (i_valid) begin
            acc     <= acc + (i_data - acc[10:3]);
            valid_d <= 1;
        end else begin
            valid_d <= 0;
        end
    end

    assign o_filtered = acc[10:3];
    assign o_valid    = valid_d;

endmodule
