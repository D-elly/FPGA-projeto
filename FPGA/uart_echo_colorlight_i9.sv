module uart_echo_colorlight_i9 (
    input  logic       clk_50mhz,
    input  logic       reset_n,
    input  logic       uart_rx,
    output logic       uart_tx,

    //interface escolha dos efeitos
    input logic     botao_a,  //representa hard clipping
    input logic     botao_b
);
    logic [7:0] data_byte;        // Armazena último byte recebido
    logic [7:0] filtered_byte;    // Byte após aplicar filtro

    // Lógica combinacional para aplicar filtros
    always_comb begin
        if (botao_a) begin
            // Filtro de clipping (limita em 200)
            if (data_byte > 8'd200) begin
                filtered_byte = 8'd200;
            end else begin
                filtered_byte = data_byte;
            end
        end else if (botao_b) begin
            // Filtro bitcrusher (reduz resolução - mantém 4 MSBs)
            filtered_byte = {data_byte[7:4], 4'b0000};
        end else begin
            // Sem filtro: passa dados originais
            filtered_byte = data_byte;
        end
    end


    // MODO ECHO ATIVADO (comentar para modo teste)
    // `define TESTE_TX_MANUAL
    
    logic [7:0] reset_counter = 8'd0;
    logic reset_n_internal = 1'b0;
    
    always_ff @(posedge clk_50mhz) begin
        if (reset_counter < 8'd255) begin
            reset_counter <= reset_counter + 1'b1;
            reset_n_internal <= 1'b0;
        end else begin
            reset_n_internal <= 1'b1;
        end
    end

    logic       rx_dv;
    logic [7:0] rx_byte;
    logic       tx_dv;
    logic [7:0] tx_byte;
    logic       tx_active, tx_done;
    
    // Captura rx_dv e rx_byte para evitar problemas de delta-cycle
    logic rx_dv_reg, rx_dv_reg2;
    logic [7:0] rx_byte_reg, rx_byte_reg2;
    
    // ECHO COM HEADER DE SINCRONIZAÇÃO (baseado no código Hough funcionando)
    localparam HEADER_BYTE = 8'hAA;
    
    uart_top #(
        .CLK_FREQ_HZ(25_000_000),  // CORRIGIDO: Clock real é 25 MHz!
        .BAUD_RATE(115200)
    ) uart_inst (
        .i_clk(clk_50mhz),
        .i_rst_n(reset_n_internal),
        .i_uart_rx(uart_rx),
        .o_uart_tx(uart_tx),
        .i_tx_dv(tx_dv),
        .i_tx_byte(tx_byte),
        .o_tx_active(tx_active),
        .o_tx_done(tx_done),
        .o_rx_dv(rx_dv),
        .o_rx_byte(rx_byte)
    );
    
    typedef enum logic [1:0] {
        WAIT_HEADER,
        ECHO_DATA,
        WAIT_TX_DONE
    } state_t;
    
    state_t state;
    logic       prev_tx_done;
    logic       tx_done_rising;
    
    // Detecção de borda ascendente de tx_done (igual ao código Hough)
    always_ff @(posedge clk_50mhz or negedge reset_n_internal) begin
        if (!reset_n_internal) begin
            prev_tx_done <= 1'b0;
        end else begin
            prev_tx_done <= tx_done;
        end
    end
    assign tx_done_rising = tx_done && !prev_tx_done;

    // Duplo registrador para capturar rx_dv/rx_byte (evita race conditions)
    always_ff @(posedge clk_50mhz or negedge reset_n_internal) begin
        if (!reset_n_internal) begin
            rx_dv_reg <= 1'b0;
            rx_byte_reg <= 8'h00;
            rx_dv_reg2 <= 1'b0;
            rx_byte_reg2 <= 8'h00;
        end else begin
            // Stage 1
            rx_dv_reg <= rx_dv;
            rx_byte_reg <= rx_byte;
            // Stage 2 (FSM vai ler este)
            rx_dv_reg2 <= rx_dv_reg;
            rx_byte_reg2 <= rx_byte_reg;
        end
    end
    
`ifndef TESTE_TX_MANUAL
    // ========================================
    // FSM Principal de Echo (desabilitada no modo teste)
    // ========================================
    always_ff @(posedge clk_50mhz or negedge reset_n_internal) begin
        if (!reset_n_internal) begin
            state <= WAIT_HEADER;
            tx_dv <= 1'b0;
            tx_byte <= 8'h00;
            data_byte <= 8'h00;
        end else begin
            // Default: limpa tx_dv (igual ao código Hough)
            tx_dv <= 1'b0;

            case (state)
                WAIT_HEADER: begin
                    // Aguarda header de sincronização (0xAA)
                    if (rx_dv && (rx_byte == HEADER_BYTE)) begin
                        state <= ECHO_DATA;
                    end
                end
                
                ECHO_DATA: begin
                    // Aguarda próximo byte (o dado após o header) - USA SINAIS DIRETOS!
                    if (rx_dv) begin
`ifdef SIMULATION
                        $display("[FPGA %0t] ECHO_DATA: Recebeu byte 0x%02h", $realtime, rx_byte);
`endif
                        if (rx_byte == HEADER_BYTE) begin
                            // Recebeu outro header, volta para WAIT_HEADER
`ifdef SIMULATION
                            $display("[FPGA %0t] Novo header detectado, voltando para WAIT_HEADER", $realtime);
`endif
                            state <= WAIT_HEADER;
                        end else begin
                            // É um dado! Salva e inicia transmissão do HEADER
                            if (!tx_active) begin
                                data_byte <= rx_byte;  // Salva para próxima vez
                                tx_dv <= 1'b1;
                                tx_byte <= HEADER_BYTE;  // Envia HEADER primeiro
                                
`ifdef SIMULATION
                                $display("[FPGA %0t] RX dados: 0x%02h, enviando HEADER", $time, rx_byte);
`endif
                                state <= WAIT_TX_DONE;
                            end
                        end
                    end
                end
                
                WAIT_TX_DONE: begin
                    // Aguarda transmissão do HEADER completar, depois envia DADOS
                    if (tx_done_rising) begin
                        if (tx_byte == HEADER_BYTE) begin
                            // Acabou de enviar HEADER, agora envia DADOS com filtro
                            tx_dv <= 1'b1;
                            tx_byte <= filtered_byte;
                            
`ifdef SIMULATION
                            if (botao_a) begin
                                $display("[FPGA %0t] TX com clipping: 0x%02h", $time, filtered_byte);
                            end else if (botao_b) begin
                                $display("[FPGA %0t] TX com bitcrusher: 0x%02h", $time, filtered_byte);
                            end else begin
                                $display("[FPGA %0t] TX sem filtro: 0x%02h", $time, filtered_byte);
                            end
`endif
                        end else begin
                            // Acabou de enviar DADOS, volta para WAIT_HEADER
`ifdef SIMULATION
                            $display("[FPGA %0t] TX completo! Voltando para WAIT_HEADER", $time);
`endif
                            state <= WAIT_HEADER;
                        end
                    end
                end
                
                default: state <= WAIT_HEADER;
            endcase
        end
    end
`else
    // ========================================
    // MODO DE TESTE: TX Manual Periódico
    // ========================================
    // Envia pacotes periodicamente para testar comunicação
    
    localparam CLKS_PER_50MS = 25_000_000 / 20;  // 50ms @ 25 MHz = 1.25M ciclos
    
    logic [31:0] test_counter;
    logic [7:0]  test_value;
    
    typedef enum logic [2:0] {
        TEST_IDLE,
        TEST_SEND_HEADER,
        TEST_WAIT_HEADER,
        TEST_SEND_DATA,
        TEST_WAIT_DATA
    } test_state_t;
    
    test_state_t test_state;
    
    // Combinação de lógica de teste com FSM principal
    always_ff @(posedge clk_50mhz or negedge reset_n_internal) begin
        if (!reset_n_internal) begin
            test_counter <= 0;
            test_value <= 8'h80;  // Começa em 128
            test_state <= TEST_IDLE;
            tx_dv <= 1'b0;
            tx_byte <= 8'h00;
        end else begin
            // Default: limpa tx_dv
            tx_dv <= 1'b0;
            
            case (test_state)
                TEST_IDLE: begin
                    test_counter <= test_counter + 1;
                    
                    // A cada 50ms, envia um novo pacote
                    if (test_counter >= CLKS_PER_50MS) begin
                        test_counter <= 0;
                        test_state <= TEST_SEND_HEADER;
                    end
                end
                
                TEST_SEND_HEADER: begin
                    if (!tx_active) begin
                        tx_dv <= 1'b1;
                        tx_byte <= HEADER_BYTE;  // 0xAA
                        test_state <= TEST_WAIT_HEADER;
                    end
                end
                
                TEST_WAIT_HEADER: begin
                    if (tx_done_rising) begin
                        test_state <= TEST_SEND_DATA;
                    end
                end
                
                TEST_SEND_DATA: begin
                    if (!tx_active) begin
                        tx_dv <= 1'b1;
                        tx_byte <= test_value;
                        test_state <= TEST_WAIT_DATA;
                    end
                end
                
                TEST_WAIT_DATA: begin
                    if (tx_done_rising) begin
                        // Incrementa valor de teste
                        test_value <= test_value + 8'd10;
                        test_state <= TEST_IDLE;
                    end
                end
                
                default: test_state <= TEST_IDLE;
            endcase
        end
    end
`endif

endmodule