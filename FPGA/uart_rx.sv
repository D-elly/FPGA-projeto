// uart_rx.sv
// UART Receiver Module - SystemVerilog
// Otimizado para comunicação FPGA <-> Raspberry Pi Pico
//
// Configuração padrão: 115200 baud, 8N1 (8 bits, No parity, 1 stop bit)
// Clock: 50 MHz
// CLKS_PER_BIT = 50_000_000 / 115200 = 434 (aproximadamente)

module uart_rx #(
    parameter CLKS_PER_BIT = 434,  // Para 115200 baud @ 50MHz
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter BAUD_RATE = 115200
) (
    input  logic       i_clk,        // Clock do sistema
    input  logic       i_rst_n,      // Reset assíncrono ativo baixo
    input  logic       i_rx_serial,  // Sinal UART RX (conectar ao Pico TX)
    
    output logic       o_rx_dv,      // Data Valid: pulso de 1 ciclo quando dado pronto
    output logic [7:0] o_rx_byte     // Byte recebido
);

    // Estados da máquina de estados (simplificado)
    typedef enum logic [1:0] {
        IDLE      = 2'b00,
        START_BIT = 2'b01,
        DATA_BITS = 2'b10,
        STOP_BIT  = 2'b11
    } state_t;
    
    state_t state;
    
    // Double-flop para sincronização e proteção contra metastabilidade
    logic rx_sync1, rx_sync2;
    
    // Registradores internos
    logic [$clog2(CLKS_PER_BIT)-1:0] clk_count;
    logic [2:0] bit_index;
    logic [7:0] rx_byte_reg;
    
    // Pipeline de sincronização (2 estágios)
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= i_rx_serial;
            rx_sync2 <= rx_sync1;
        end
    end
    
    // FSM de recepção UART
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state       <= IDLE;
            o_rx_dv     <= 1'b0;
            o_rx_byte   <= 8'h00;
            clk_count   <= 0;
            bit_index   <= 0;
            rx_byte_reg <= 8'h00;
        end else begin
            // Limpa data valid por padrão (pulso de 1 ciclo)
            o_rx_dv <= 1'b0;
            
            case (state)
                IDLE: begin
                    clk_count <= 0;
                    bit_index <= 0;
                    
                    // Detecta start bit (transição para LOW)
                    if (rx_sync2 == 1'b0) begin
                        state <= START_BIT;
                    end
                end
                
                START_BIT: begin
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                    end else begin
                        // Terminou período do start bit
                        clk_count <= 0;
                        state <= DATA_BITS;
                    end
                end
                
                DATA_BITS: begin
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                        
                        // Amostra no MEIO do bit (ciclo 217)
                        if (clk_count == (CLKS_PER_BIT / 2)) begin
                            rx_byte_reg[bit_index] <= rx_sync2;
                        end
                    end else begin
                        // Terminou período do bit atual
                        clk_count <= 0;
                        
                        if (bit_index < 7) begin
                            // Próximo bit de dados
                            bit_index <= bit_index + 1;
                        end else begin
                            // Todos os 8 bits recebidos
                            state <= STOP_BIT;
                        end
                    end
                end
                
                STOP_BIT: begin
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                        
                        // No meio do stop bit, valida e envia dados
                        if (clk_count == (CLKS_PER_BIT / 2)) begin
                            // Gera pulso de data valid
                            o_rx_dv   <= 1'b1;
                            o_rx_byte <= rx_byte_reg;
                        end
                    end else begin
                        // Terminou stop bit, volta para IDLE
                        clk_count <= 0;
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
