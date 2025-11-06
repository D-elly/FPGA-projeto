`timescale 1ns/1ps

module eff_1_tb;
    // Parâmetros
    localparam CLK_FREQ = 50_000_000;
    localparam real CLK_PERIOD_NS = 20.0;  // 50 MHz
    localparam int CLIP_LEVEL = 200;
    
    // Sinais do DUT
    logic       i_clk;
    logic       i_rst_n;
    logic       data_valid;
    logic [7:0] receive_byte;
    logic [7:0] clipping_byte;
    
    // Instancia DUT
    eff_1 #(
        .CLK_FREQ(CLK_FREQ)
    ) dut (
        .i_clk(i_clk),
        .i_rst_n(i_rst_n),
        .data_valid(data_valid),
        .receive_byte(receive_byte),
        .clipping_byte(clipping_byte)
    );
    
    // Geração de clock
    initial i_clk = 0;
    always #(CLK_PERIOD_NS/2) i_clk = ~i_clk;
    
    // Task para enviar um byte e verificar resposta
    task automatic test_clipping(
        input logic [7:0] input_val,
        input logic [7:0] expected_val,
        input string description
    );
        begin
            $display("\n[%0t ns] Teste: %s", $time, description);
            $display("  Input: %0d (0x%02h)", input_val, input_val);
            $display("  Expected: %0d (0x%02h)", expected_val, expected_val);
            
            // Envia dado
            receive_byte = input_val;
            data_valid = 1'b1;
            @(posedge i_clk);
            data_valid = 1'b0;
            
            // Aguarda 1 ciclo para processamento
            @(posedge i_clk);
            
            // Verifica resultado
            $display("  Output: %0d (0x%02h)", clipping_byte, clipping_byte);
            
            if (clipping_byte == expected_val) begin
                $display("  ✓ PASSOU");
            end else begin
                $display("  ✗ FALHOU - Esperado %0d, obteve %0d", expected_val, clipping_byte);
            end
        end
    endtask
    
    // Bloco de estímulo
    initial begin
        $dumpfile("wave_eff_1.vcd");
        $dumpvars(0, eff_1_tb);
        
        $display("=== TESTBENCH PARA eff_1 (Hard Clipping) ===");
        $display("Clock: %0d MHz", CLK_FREQ/1_000_000);
        $display("Clip Level: %0d", CLIP_LEVEL);
        
        // Inicializa sinais
        i_rst_n = 1'b0;
        data_valid = 1'b0;
        receive_byte = 8'd0;
        
        // Reset
        repeat(5) @(posedge i_clk);
        i_rst_n = 1'b1;
        $display("\n[%0t ns] Reset liberado", $time);
        repeat(2) @(posedge i_clk);
        
        // TESTE 1: Valores abaixo do limite (passam sem alteração)
        $display("\n========== TESTE 1: Valores abaixo do limite ==========");
        test_clipping(8'd0,   8'd0,   "Valor mínimo");
        test_clipping(8'd50,  8'd50,  "Valor baixo");
        test_clipping(8'd100, 8'd100, "Valor médio-baixo");
        test_clipping(8'd150, 8'd150, "Valor médio");
        test_clipping(8'd199, 8'd199, "Valor no limite-1");
        test_clipping(8'd200, 8'd200, "Valor exatamente no limite");
        
        // TESTE 2: Valores acima do limite (clipping aplicado)
        $display("\n========== TESTE 2: Valores acima do limite (clipping) ==========");
        test_clipping(8'd201, 8'd200, "Limite + 1");
        test_clipping(8'd220, 8'd200, "Valor moderadamente alto");
        test_clipping(8'd240, 8'd200, "Valor alto");
        test_clipping(8'd250, 8'd200, "Valor muito alto (usado no Pico)");
        test_clipping(8'd255, 8'd200, "Valor máximo");
        
        // TESTE 3: Sequência rápida (sem data_valid entre eles)
        $display("\n========== TESTE 3: Sequência rápida sem data_valid ==========");
        receive_byte = 8'd180;
        data_valid = 1'b1;
        @(posedge i_clk);
        data_valid = 1'b0;
        @(posedge i_clk);
        $display("[%0t ns] Output para 180: %0d", $time, clipping_byte);
        
        receive_byte = 8'd250;
        @(posedge i_clk);
        $display("[%0t ns] Output para 250 (sem data_valid): %0d", $time, clipping_byte);
        
        // TESTE 4: Pulsos rápidos de data_valid
        $display("\n========== TESTE 4: Múltiplos valores com data_valid ==========");
        for (int i = 190; i <= 210; i += 5) begin
            receive_byte = i;
            data_valid = 1'b1;
            @(posedge i_clk);
            data_valid = 1'b0;
            @(posedge i_clk);
            $display("[%0t ns] Input: %0d -> Output: %0d %s", 
                    $time, i, clipping_byte,
                    (clipping_byte == CLIP_LEVEL) ? "(clipped)" : "");
        end
        
        // TESTE 5: Comportamento com reset durante operação
        $display("\n========== TESTE 5: Reset durante operação ==========");
        receive_byte = 8'd250;
        data_valid = 1'b1;
        @(posedge i_clk);
        $display("[%0t ns] Antes do reset: %0d", $time, clipping_byte);
        
        i_rst_n = 1'b0;
        @(posedge i_clk);
        $display("[%0t ns] Durante reset: %0d", $time, clipping_byte);
        
        i_rst_n = 1'b1;
        data_valid = 1'b0;
        @(posedge i_clk);
        $display("[%0t ns] Após reset: %0d", $time, clipping_byte);
        
        // TESTE 6: Simulação realista (como seria usado no sistema)
        $display("\n========== TESTE 6: Simulação realista (stream de áudio) ==========");
        $display("Simulando 20 amostras de áudio com clipping");
        
        logic [7:0] audio_samples [20] = '{
            128, 150, 180, 210, 230, 250, 255, 240, 220, 190,
            160, 140, 120, 100, 80, 100, 130, 170, 200, 225
        };
        
        foreach(audio_samples[i]) begin
            receive_byte = audio_samples[i];
            data_valid = 1'b1;
            @(posedge i_clk);
            data_valid = 1'b0;
            @(posedge i_clk);
            
            if (audio_samples[i] > CLIP_LEVEL) begin
                $display("  Sample[%02d]: %3d -> %3d (CLIPPED)", 
                        i, audio_samples[i], clipping_byte);
            end else begin
                $display("  Sample[%02d]: %3d -> %3d", 
                        i, audio_samples[i], clipping_byte);
            end
        end
        
        // Aguarda alguns ciclos finais
        repeat(10) @(posedge i_clk);
        
        $display("\n=== FIM DOS TESTES ===");
        $display("Todos os testes do módulo eff_1 foram executados!");
        
        $finish;
    end
    
    // Timeout de segurança
    initial begin
        #100us;
        $display("\n*** TIMEOUT: Simulação excedeu 100us ***");
        $finish;
    end

endmodule
