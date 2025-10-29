#include <stdio.h>
#include "pico/stdlib.h"

uart_rx #(
    .CLK_FREQ(50000000),
    .BAUD_RATE(115200)
) uart_rx_inst (
    .clk(clk),
    .rst(rst),
    .rx(uart_rx_pin),
    .data_out(received_byte),
    .data_ready(received_flag)
);


module uart_system (
    input wire clk,           // Clock principal do sistema
    input wire rst,           // Reset síncrono
    input wire rx,            // Entrada UART RX (recebe dados da BitDogLab)
    output wire tx,           // Saída UART TX (envia XON/XOFF para BitDogLab)
    output wire [7:0] fifo_out, // Saída de dados do FIFO (para processamento posterior)
    output wire fifo_valid    // Indica se há dados válidos no FIFO
);
    // Sinais internos para recepção UART
    wire [7:0] rx_data;       // Byte recebido via UART
    wire rx_ready;            // Pulso indicando que rx_data está válido

    // Instancia o módulo UART RX com clock de 50 MHz e baud rate de 115200
    uart_rx #(
        .CLK_FREQ(50000000),
        .BAUD_RATE(115200)
    ) uart_rx_inst (
        .clk(clk),
        .rst(rst),
        .rx(rx),
        .data_out(rx_data),
        .data_ready(rx_ready)
    );

    // FIFO
       // Sinais internos do FIFO
    wire fifo_full, fifo_empty;   // Flags de estado do FIFO
    wire [5:0] fifo_count;        // Quantidade de dados armazenados
    reg wr_en;                    // Habilita escrita no FIFO

    // Instancia o FIFO com profundidade de 64 bytes
    fifo_buffer #(.DEPTH(64)) fifo_inst (
        .clk(clk),
        .rst(rst),
        .wr_en(wr_en),            // Escreve quando rx_ready e FIFO não está cheio
        .wr_data(rx_data),        // Dados recebidos via UART
        .rd_en(0),                // Leitura externa desativada neste módulo
        .rd_data(fifo_out),       // Saída dos dados armazenados
        .full(fifo_full),
        .empty(fifo_empty),
        .count(fifo_count)
    );
    // UART TX para XON/XOFF
       // Sinais de controle para transmissão UART
    reg tx_start = 0;             // Pulso para iniciar transmissão
    reg [7:0] tx_data = 8'h00;    // Byte a ser transmitido (XON ou XOFF)
    wire tx_busy;                 // Indica se o transmissor está ocupado

    // Instancia o módulo UART TX com os mesmos parâmetros
    uart_tx #(
        .CLK_FREQ(50000000),
        .BAUD_RATE(115200)
    ) uart_tx_inst (
        .clk(clk),
        .rst(rst),
        .start(tx_start),
        .data_in(tx_data),
        .tx(tx),
        .busy(tx_busy)
    );

    // Controle de fluxo
       // Constantes para controle de fluxo
    localparam XOFF = 8'h13;      // Comando para pausar envio (Ctrl-S)
    localparam XON  = 8'h11;      // Comando para retomar envio (Ctrl-Q)

    reg [1:0] flow_state = 0;     // Estado do controle de fluxo: 0 = normal, 1 = XOFF enviado

    // Lógica de controle de fluxo
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            // Reset: limpa sinais
            wr_en <= 0;
            tx_start <= 0;
            flow_state <= 0;
        end else begin
            // Habilita escrita no FIFO se houver dado e espaço disponível
            wr_en <= rx_ready && !fifo_full;

            // Garante que tx_start seja um pulso de 1 ciclo
            tx_start <= 0;

            // FSM de controle de fluxo
            case (flow_state)
                0: begin // Estado normal: pronto para enviar XOFF se FIFO estiver quase cheio
                    if (fifo_count >= 60 && !tx_busy) begin
                        tx_data <= XOFF;
                        tx_start <= 1;
                        flow_state <= 1;
                    end
                end
                1: begin // Estado de espera: aguarda FIFO esvaziar para enviar XON
                    if (fifo_count <= 32 && !tx_busy) begin
                        tx_data <= XON;
                        tx_start <= 1;
                        flow_state <= 0;
                    end
                end
            endcase
        end
    end
        // Indica se há dados disponíveis no FIFO para leitura externa
    assign fifo_valid = !fifo_empty;

endmodule
