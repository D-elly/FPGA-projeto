module uart_echo_colorlight_i9 (
    input  logic       clk_50mhz,
    input  logic       reset_n,
    input  logic       uart_rx,
    output logic       uart_tx,

    //interface escolha dos efeitos
    input logic     botao_a,  //representa hard clipping
    input logic     botao_b
);
logic [7:0] filter_select;
logic [7:0] clipping_byte;
logic [7:0] bitcrusher_out;
logic [7:0] data_byte;  // Armazena último byte de DADOS (não header)

// Inicializa bitcrusher_out para evitar valor X
assign bitcrusher_out = 8'd0;  // TODO: Implementar filtro bitcrusher

always_comb begin
    if(botao_a)begin
        filter_select = clipping_byte;

    end else if(botao_b) begin
        filter_select = bitcrusher_out;

    end else begin
        // Usa byte de dados (não o header)
        filter_select = data_byte;
    end 
end


    // Comentado para usar modo echo em vez de teste manual
    //`define TESTE_TX_MANUAL
    
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
        .CLK_FREQ_HZ(50_000_000),
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

    eff_1 #(
        .CLK_FREQ(50_000_000)
    ) eff_1_inst( 
        .i_clk(clk_50mhz),     
        .i_rst_n(reset_n_internal),
        .data_valid(rx_dv && rx_byte != HEADER_BYTE),  // Só valida dados, não header
        .receive_byte(rx_byte),   
        .clipping_byte(clipping_byte)   
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
                            // É um dado! Transmite imediatamente
                            if (!tx_active) begin
                                data_byte <= rx_byte;
                                tx_dv <= 1'b1;
                                
                                // Aplica filtro
                                if (botao_a) begin
                                    tx_byte <= (rx_byte > 8'd200) ? 8'd200 : rx_byte;
`ifdef SIMULATION
                                    $display("[FPGA %0t] TX com clipping: 0x%02h", $time, 
                                            (rx_byte > 8'd200) ? 8'd200 : rx_byte);
`endif
                                end else if (botao_b) begin
                                    tx_byte <= 8'd0;
                                end else begin
                                    tx_byte <= rx_byte;
`ifdef SIMULATION
                                    $display("[FPGA %0t] TX sem filtro: 0x%02h", $time, rx_byte);
`endif
                                end
                                
                                state <= WAIT_TX_DONE;
                            end
                        end
                    end
                end
                
                WAIT_TX_DONE: begin
                    // Aguarda transmissão completar
                    if (tx_done_rising) begin
`ifdef SIMULATION
                        $display("[FPGA %0t] TX completo! Voltando para WAIT_HEADER", $time);
`endif
                        state <= WAIT_HEADER;
                    end
                end
                
                default: state <= WAIT_HEADER;
            endcase
        end
    end

endmodule