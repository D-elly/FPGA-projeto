// uart_tx.sv
// UART Transmitter Module - SystemVerilog
// Otimizado para comunicação FPGA <-> Raspberry Pi Pico
//
// Configuração padrão: 115200 baud, 8N1 (8 bits, No parity, 1 stop bit)
// Clock: 50 MHz
// CLKS_PER_BIT = 50_000_000 / 115200 = 434 (aproximadamente)

module uart_tx #(
    // Parâmetros configuráveis para adaptar a diferentes frequências e baud rates
    parameter int CLK_FREQ     = 50_000_000,               // Frequência do clock do sistema (ex: 50 MHz)
    parameter int BAUD_RATE    = 115200,                   // Baud rate desejado
    parameter int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE      // Número de ciclos de clock por bit UART
)(
    // Entradas
    input  logic       i_clk,         // Clock principal do sistema
    input  logic       i_rst_n,       // Reset assíncrono ativo baixo
    input  logic       i_tx_dv,       // Pulso de 1 ciclo indicando que há dado para transmitir
    input  logic [7:0] i_tx_byte,     // Byte a ser transmitido

    // Saídas
    output logic       o_tx_serial,   // Linha de transmissão UART (conectar ao RX do outro dispositivo)
    output logic       o_tx_active,   // Indica que a transmissão está em andamento
    output logic       o_tx_done      // Pulso de 1 ciclo indicando que a transmissão foi concluída
);

    typedef enum logic [2:0] {
        IDLE      = 3'b000,           // Estado de espera
        START_BIT = 3'b001,           // Envia start bit (sempre 0)
        DATA_BITS = 3'b010,           // Envia os 8 bits de dados
        STOP_BIT  = 3'b011            // Envia stop bit (sempre 1)
    } state_t;

    state_t state, next_state;

    logic [$clog2(CLKS_PER_BIT)-1:0] clk_count;  // Contador para temporização de cada bit
    logic [2:0] bit_index;                       // Índice do bit atual sendo transmitido
    logic [7:0] tx_data;                         // Byte a ser transmitido (registrado internamente)
    logic       tx_dv_latched;                   // Latch para evitar múltiplos pulsos de i_tx_dv
    // Lógica sequencial
        always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            // Reset: inicializa todos os sinais
            state       <= IDLE;
            clk_count   <= 0;
            bit_index   <= 0;
            tx_data     <= 0;
            o_tx_serial <= 1;        // Linha UART idle é HIGH
            o_tx_active <= 0;
            o_tx_done   <= 0;
            tx_dv_latched <= 0;
        end else begin
            o_tx_done <= 0; // Garante que o pulso seja de 1 ciclo

            case (state)
                IDLE: begin
                    o_tx_serial <= 1;       // Linha em estado idle
                    o_tx_active <= 0;
                    clk_count   <= 0;
                    bit_index   <= 0;

                    // Proteção contra múltiplos pulsos: só aceita se não estiver latched
                    if (i_tx_dv && !tx_dv_latched) begin
                        tx_data        <= i_tx_byte;   // Captura o byte
                        tx_dv_latched  <= 1;           // Latch para evitar reentrada
                        o_tx_active    <= 1;           // Sinaliza transmissão ativa
                        state          <= START_BIT;   // Vai para start bit
                    end else begin
                        tx_dv_latched <= 0;            // Libera latch após 1 ciclo
                    end
                end

                               START_BIT: begin
                    o_tx_serial <= 0; // Start bit é sempre 0
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                    end else begin
                        clk_count <= 0;
                        state     <= DATA_BITS;
                    end
                end

                                DATA_BITS: begin
                    o_tx_serial <= tx_data[bit_index]; // Envia bit atual
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                    end else begin
                        clk_count <= 0;
                        if (bit_index < 7) begin
                            bit_index <= bit_index + 1; // Próximo bit
                        end else begin
                            bit_index <= 0;
                            state     <= STOP_BIT;      // Todos os bits enviados
                        end
                    end
                end

                              STOP_BIT: begin
                    o_tx_serial <= 1; // Stop bit é sempre 1
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                    end else begin
                        clk_count   <= 0;
                        o_tx_done   <= 1;   // Pulso de término
                        o_tx_active <= 0;   // Transmissão encerrada
                        state       <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
