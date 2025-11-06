`timescale 1ns/1ps

module uart_echo_pico_sim_tb;
    // Parâmetros realistas
    localparam real CLK_PERIOD_NS = 20.0;  // 50 MHz
    localparam int BAUD_RATE = 115200;
    localparam int CLK_FREQ = 50_000_000;
    localparam real BIT_PERIOD_NS = 1_000_000_000.0 / BAUD_RATE;  // ~8680 ns
    
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
        
        // Aguarda reset interno do DUT (255 ciclos)
        #(CLK_PERIOD_NS * 260);
        
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
        
        // TESTE 3: Valores variados
        $display("\n=== TESTE 3: Valores variados ===");
        pico_send_sample(8'd100);
        #(BIT_PERIOD_NS * 30);
        pico_send_sample(8'd150);
        #(BIT_PERIOD_NS * 30);
        pico_send_sample(8'd200);
        #(BIT_PERIOD_NS * 30);
        pico_send_sample(8'd255);
        #(BIT_PERIOD_NS * 30);
        
        // Aguarda processamento final
        #(BIT_PERIOD_NS * 100);
        
        // Estatísticas
        $display("\n=== ESTATÍSTICAS ===");
        $display("Bytes enviados (PICO -> FPGA): %0d", bytes_sent);
        $display("Bytes recebidos (FPGA -> PICO): %0d", bytes_received);
        $display("Dados processados: %0d", data_count);
        
        if (data_count > 0) begin
            $display("\n*** SUCESSO: Comunicação UART funcionando! ***");
        end else begin
            $display("\n*** FALHA: Nenhum dado foi recebido de volta! ***");
        end
        
        $display("\nBytes recebidos:");
        foreach(rx_buffer[i]) begin
            $display("  [%0d] = 0x%02h (%0d)", i, rx_buffer[i], rx_buffer[i]);
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
