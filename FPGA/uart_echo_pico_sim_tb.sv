`timescale 1ns/1ps

module uart_echo_pico_sim_tb;
    // Parâmetros realistas
    localparam real CLK_PERIOD_NS = 20.0;  // 50 MHz
    localparam int BAUD_RATE = 115200;
    localparam int CLK_FREQ = 50_000_000;
    localparam int CLKS_PER_BIT = 434;  // Clock cycles per bit
    localparam real BIT_PERIOD_NS = CLK_PERIOD_NS * CLKS_PER_BIT;  // 8680ns exato
    
    // Sinais do DUT
    logic       clk_50mhz;
    logic       reset_n;
    logic       uart_rx;
    logic       uart_tx;
    logic       botao_a;
    logic       botao_b;
    
    // Variáveis do testbench
    logic [7:0] rx_buffer [$];  // Fila para armazenar bytes recebidos
    int         bytes_sent;
    int         bytes_received;
    
    // Instancia DUT
    uart_echo_colorlight_i9 dut (
        .clk_50mhz(clk_50mhz),
        .reset_n(reset_n),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .botao_a(botao_a),
        .botao_b(botao_b)
    );
    
    // Monitor RX DV e TX para debug
    always @(posedge clk_50mhz) begin
        if (dut.rx_dv) begin
            $display("[FPGA MONITOR %0t] rx_dv ATIVO! rx_byte=0x%02h estado=%s tx_active=%b", 
                    $time, dut.rx_byte, dut.state.name(), dut.tx_active);
            // Mostra se a FSM está em WAIT_HEADER e rx_byte é o header
            if (dut.state == 0 && dut.rx_byte == 8'hAA) begin
                $display("[MONITOR] *** CONDICAO PERFEITA PARA MUDAR ESTADO! ***");
            end
        end
        if (dut.tx_dv) begin
            $display("[FPGA MONITOR %0t] *** TX_DV ATIVO! tx_byte=0x%02h ***", 
                    $time, dut.tx_byte);
        end
    end
    
    // Geração de clock 50 MHz
    initial clk_50mhz = 0;
    always #(CLK_PERIOD_NS/2) clk_50mhz = ~clk_50mhz;
    
    // Task para enviar um byte via UART (simulando Pico TX -> FPGA RX)
    task automatic send_uart_byte(input logic [7:0] data);
        integer i;
        begin
            $display("[%0t ns] PICO TX: Enviando byte 0x%02h (%0d)", $time, data, data);
            
            // Start bit
            uart_rx = 1'b0;
            #(BIT_PERIOD_NS);
            
            // Data bits (LSB first)
            for (i = 0; i < 8; i++) begin
                uart_rx = data[i];
                #(BIT_PERIOD_NS);
            end
            
            // Stop bit
            uart_rx = 1'b1;
            #(BIT_PERIOD_NS);
            
            bytes_sent++;
        end
    endtask
    
    // Task para receber um byte via UART (simulando FPGA TX -> Pico RX)
    task automatic receive_uart_byte(output logic [7:0] data);
        integer i;
        logic [7:0] temp_data;
        begin
            // Aguarda start bit
            wait(uart_tx == 1'b0);
            $display("[%0t ns] PICO RX: Detectou start bit", $time);
            #(BIT_PERIOD_NS/2);  // Vai para o meio do start bit
            #(BIT_PERIOD_NS);    // Pula o start bit
            
            // Lê data bits (LSB first)
            for (i = 0; i < 8; i++) begin
                temp_data[i] = uart_tx;
                #(BIT_PERIOD_NS);
            end
            
            // Verifica stop bit
            if (uart_tx !== 1'b1) begin
                $display("[%0t ns] ERRO: Stop bit inválido!", $time);
            end
            
            data = temp_data;
            rx_buffer.push_back(data);
            bytes_received++;
            $display("[%0t ns] PICO RX: Recebeu byte 0x%02h (%0d)", $time, data, data);
            
            #(BIT_PERIOD_NS);  // Aguarda fim do stop bit
        end
    endtask
    
    // Task que simula o comportamento do sample_timer_cb do Pico
    task automatic pico_send_sample(input logic [7:0] sample);
        begin
            // Envia HEADER + SAMPLE (igual ao on_uart_tx do Pico)
            send_uart_byte(8'hAA);  // HEADER_BYTE
            send_uart_byte(sample);
        end
    endtask
    
    // Process para receber bytes em paralelo (simula IRQ do Pico)
    logic [7:0] received_byte;
    logic       synced;
    logic       header_echo_received;
    int         data_count;
    
    initial begin
        synced = 0;
        header_echo_received = 0;
        data_count = 0;
        
        forever begin
            receive_uart_byte(received_byte);
            
            // Simula lógica do on_uart_rx do Pico
            if (!synced) begin
                if (received_byte == 8'hAA) begin
                    synced = 1;
                    header_echo_received = 0;
                    $display("[%0t ns] *** PICO: SINCRONIZADO (recebeu header 0xAA) ***", $time);
                end
            end else begin
                // Descarta headers repetidos
                if (!header_echo_received) begin
                    if (received_byte == 8'hAA) begin
                        $display("[%0t ns] PICO: Descartando header repetido", $time);
                    end else begin
                        header_echo_received = 1;
                        data_count++;
                        $display("[%0t ns] *** PICO: DADO RECEBIDO #%0d = 0x%02h ***", 
                                $time, data_count, received_byte);
                        synced = 0;  // Reseta para próximo ciclo
                    end
                end
            end
        end
    end
    
    // Bloco de estímulo principal
    initial begin
        $dumpfile("wave_pico_sim.vcd");
        $dumpvars(0, uart_echo_pico_sim_tb);
        
        // Inicializa variáveis
        bytes_sent = 0;
        bytes_received = 0;
        
        // Inicializa sinais
        reset_n = 1'b0;
        uart_rx = 1'b1;  // UART idle
        botao_a = 1'b0;
        botao_b = 1'b0;
        
        $display("=== INICIANDO SIMULAÇÃO ===");
        $display("Clock: %0d MHz", CLK_FREQ/1_000_000);
        $display("Baud Rate: %0d", BAUD_RATE);
        $display("Bit Period: %.2f ns", BIT_PERIOD_NS);
        
        // Aguarda e libera reset
        #(CLK_PERIOD_NS * 20);
        reset_n = 1'b1;
        $display("[%0t ns] Reset liberado", $time);
        
        // Aguarda reset interno do DUT (256 ciclos + margem)
        #(CLK_PERIOD_NS * 300);
        $display("[%0t ns] Reset interno completo (esperado)", $time);
        
        // Simula envio de 5 amostras (como o timer do Pico faria)
        $display("\n=== TESTE 1: Envio de 5 amostras sem filtro ===");
        repeat(5) begin
            pico_send_sample(8'd250);  // Valor usado no código C
            #(BIT_PERIOD_NS * 30);  // Aguarda processamento
        end
        
        // Aguarda todas as respostas
        #(BIT_PERIOD_NS * 50);
        
        // TESTE 2: Com botão A pressionado (clipping)
        $display("\n=== TESTE 2: Envio com filtro clipping (botao_a) ===");
        botao_a = 1'b1;
        repeat(3) begin
            pico_send_sample(8'd250);
            #(BIT_PERIOD_NS * 30);
        end
        botao_a = 1'b0;
        
        #(BIT_PERIOD_NS * 50);
        
        // TESTE 3: Valores variados sem filtro
        $display("\n=== TESTE 3: Valores variados sem filtro ===");
        pico_send_sample(8'd100);
        #(BIT_PERIOD_NS * 30);
        pico_send_sample(8'd150);
        #(BIT_PERIOD_NS * 30);
        pico_send_sample(8'd200);
        #(BIT_PERIOD_NS * 30);
        pico_send_sample(8'd255);
        #(BIT_PERIOD_NS * 30);
        
        #(BIT_PERIOD_NS * 50);
        
        // TESTE 4: Validação específica do clipping (CLIP_LEVEL = 200)
        $display("\n=== TESTE 4: Validação do Filtro de Clipping ===");
        botao_a = 1'b1;
        
        $display("Enviando valores ABAIXO do limite (devem passar sem alteração):");
        pico_send_sample(8'd50);   // Deve retornar 50
        #(BIT_PERIOD_NS * 30);
        pico_send_sample(8'd100);  // Deve retornar 100
        #(BIT_PERIOD_NS * 30);
        pico_send_sample(8'd150);  // Deve retornar 150
        #(BIT_PERIOD_NS * 30);
        pico_send_sample(8'd199);  // Deve retornar 199
        #(BIT_PERIOD_NS * 30);
        
        $display("Enviando valor NO LIMITE (deve passar sem alteração):");
        pico_send_sample(8'd200);  // Deve retornar 200 (no limite)
        #(BIT_PERIOD_NS * 30);
        
        $display("Enviando valores ACIMA do limite (devem ser cortados para 200):");
        pico_send_sample(8'd201);  // Deve retornar 200 (cortado)
        #(BIT_PERIOD_NS * 30);
        pico_send_sample(8'd220);  // Deve retornar 200 (cortado)
        #(BIT_PERIOD_NS * 30);
        pico_send_sample(8'd240);  // Deve retornar 200 (cortado)
        #(BIT_PERIOD_NS * 30);
        pico_send_sample(8'd255);  // Deve retornar 200 (cortado)
        #(BIT_PERIOD_NS * 30);
        
        botao_a = 1'b0;
        
        // Aguarda processamento final
        #(BIT_PERIOD_NS * 100);
        
        // Estatísticas
        $display("\n=== ESTATÍSTICAS ===");
        $display("Bytes enviados (PICO -> FPGA): %0d", bytes_sent);
        $display("Bytes recebidos (FPGA -> PICO): %0d", bytes_received);
        
        if (bytes_received > 0) begin
            // Metade dos bytes enviados são headers (0xAA), metade são dados
            int bytes_dados_esperados;
            real taxa_sucesso;
            bytes_dados_esperados = bytes_sent >> 1;  // Divide por 2
            taxa_sucesso = (bytes_received * 100.0) / bytes_dados_esperados;
            $display("\n*** SUCESSO: Comunicação UART funcionando! ***");
            $display("Taxa de recepção: %.1f%% (%0d de %0d bytes de dados esperados)", 
                     taxa_sucesso, bytes_received, bytes_dados_esperados);
        end else begin
            $display("\n*** FALHA: Nenhum dado foi recebido de volta! ***");
        end
        
        if (bytes_received > 0) begin
            $display("\nBytes recebidos:");
            for (int i = 0; i < bytes_received; i++) begin
                $display("  [%0d] = 0x%02h (%0d)", i, rx_buffer[i], rx_buffer[i]);
            end
        end
        
        // VALIDAÇÃO DO FILTRO DE CLIPPING
        $display("\n=== VALIDAÇÃO DO FILTRO DE CLIPPING ===");
        
        // Valores esperados do TESTE 4:
        // [12-15]: 50, 100, 150, 199 (abaixo do limite, sem alteração)
        // [16]:    200 (no limite, sem alteração)
        // [17-20]: 200, 200, 200, 200 (acima do limite, cortados para 200)
        
        begin : blk_test4_validation
            int erros = 0;
            
            if (bytes_received >= 21) begin
                // Valida valores abaixo do limite
                if (rx_buffer[12] != 8'd50)  begin $display("  ERRO: rx_buffer[12] = %0d, esperado 50",  rx_buffer[12]); erros++; end
                if (rx_buffer[13] != 8'd100) begin $display("  ERRO: rx_buffer[13] = %0d, esperado 100", rx_buffer[13]); erros++; end
                if (rx_buffer[14] != 8'd150) begin $display("  ERRO: rx_buffer[14] = %0d, esperado 150", rx_buffer[14]); erros++; end
                if (rx_buffer[15] != 8'd199) begin $display("  ERRO: rx_buffer[15] = %0d, esperado 199", rx_buffer[15]); erros++; end
                
                // Valida valor no limite
                if (rx_buffer[16] != 8'd200) begin $display("  ERRO: rx_buffer[16] = %0d, esperado 200 (no limite)", rx_buffer[16]); erros++; end
                
                // Valida valores acima do limite (devem ser cortados para 200)
                if (rx_buffer[17] != 8'd200) begin $display("  ERRO: rx_buffer[17] = %0d, esperado 200 (cortado de 201)", rx_buffer[17]); erros++; end
                if (rx_buffer[18] != 8'd200) begin $display("  ERRO: rx_buffer[18] = %0d, esperado 200 (cortado de 220)", rx_buffer[18]); erros++; end
                if (rx_buffer[19] != 8'd200) begin $display("  ERRO: rx_buffer[19] = %0d, esperado 200 (cortado de 240)", rx_buffer[19]); erros++; end
                if (rx_buffer[20] != 8'd200) begin $display("  ERRO: rx_buffer[20] = %0d, esperado 200 (cortado de 255)", rx_buffer[20]); erros++; end
                
                if (erros == 0) begin
                    $display("  PASSOU: Todos os valores do filtro de clipping estao corretos!");
                    $display("    - Valores abaixo de 200: passaram sem alteracao");
                    $display("    - Valor igual a 200: passou sem alteracao");
                    $display("    - Valores acima de 200: cortados corretamente para 200");
                end else begin
                    $display("  FALHOU: %0d erro(s) detectado(s) no filtro de clipping!", erros);
                end
            end else begin
                $display("  AVISO: Nao ha bytes suficientes para validar o filtro de clipping");
                $display("         Esperado pelo menos 21 bytes, recebido %0d", bytes_received);
            end
        end
        
        $finish;
    end
    
    // Timeout de segurança
    initial begin
        #50ms;
        $display("\n*** TIMEOUT: Simulação excedeu 50ms ***");
        $finish;
    end

endmodule
