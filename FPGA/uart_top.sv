module uart_top #(
    parameter CLK_FREQ_HZ = 50_000_000,  // Clock do sistema
    parameter BAUD_RATE   = 115200        // Taxa de transmissão
) (
    // Sinais do sistema
    input  logic       i_clk,          // Clock 50 MHz
    input  logic       i_rst_n,        // Reset assíncrono ativo baixo
    
    // Interface UART física (conectar ao Raspberry Pi Pico)
    input  logic       i_uart_rx,      // Recebe do Pico TX
    output logic       o_uart_tx,      // Envia para Pico RX

    //seletores de efeito
    input logic botao_a, 
    input logic botao_b
);

    // Calcula CLKS_PER_BIT
    localparam int CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;

    logic [7:0] reset_counter = 8'd0;
    logic reset_n_internal = 1'b0; // Começa em reset
    
    always_ff @(posedge i_clk or negedge i_rst_n) begin 
        if (!i_rst_n) begin // Reset físico
            reset_counter <= 8'd0;
            reset_n_internal <= 1'b0;
        end else if (reset_counter < 8'd255) begin
            reset_counter <= reset_counter + 1'b1;
            reset_n_internal <= 1'b0; // Mantém em reset
        end else begin
            reset_n_internal <= 1'b1; // Libera o reset
        end
    end

    //conexões com módulos filhos
    logic       rx_dv;       // data_ready
    logic [7:0] rx_byte;     // byte de dado recebido
    
    logic       tx_dv;       // data ready para iniciar tx function
    logic [7:0] tx_byte;     // byte para enviar no tx
    logic       tx_active;   // flag para tx funcionando

    //Fios Internos p/ Efeitos
    logic [7:0] clipping_out;   
    logic [7:0] bitcrusher_out; 
    logic [7:0] filter_select; 
    
    // Instancia transmissor UART
    uart_tx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) uart_tx_inst (
        .i_clk       (i_clk),
        .i_rst_n     (reset_n_internal),
        .i_tx_dv     (tx_dv),
        .i_tx_byte   (tx_byte),
        .o_tx_serial (o_uart_tx),
        .o_tx_active (tx_active)
       // .o_tx_done   (o_tx_done) não está sendo usado
    );
    
    // Instancia receptor UART
    uart_rx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) uart_rx_inst (
        .i_clk       (i_clk),
        .i_rst_n     (reset_n_internal),
        .i_rx_serial (i_uart_rx),
        .o_rx_dv     (rx_dv),
        .o_rx_byte   (rx_byte)
    );

    eff_1 #(
    .CLK_FREQ(CLK_FREQ_HZ)
    ) eff_1_inst ( 
        .i_clk(i_clk),         
        .i_rst_n(reset_n_internal),  
        .data_valid(rx_dv),    
        .receive_byte(rx_byte),     
        .clipping_byte(clipping_out)   
    );

    //efeito de bitcrusher pode ser feito no mesmo módulo caso 
    //não inclua mudanças na taxa de amostragem, apenas em depth
    assign bitcrusher_out = {rx_byte[7:4], 4'b0000};

    //multiplexador de efeitos
    always_comb begin
        if(botao_a)begin
            filter_select = clipping_out;

        end else if(botao_b) begin
            filter_select = bitcrusher_out;

        end else begin
            filter_select = rx_byte;
        end 
    end

    //Máquina de estados para controle de UART
    typedef enum logic [1:0]{
        S_IDLE, 
        S_SEND 
    } state_t;

    state_t echo_state;

    always_ff @(posedge i_clk or negedge reset_n_internal) begin
        if (!reset_n_internal) begin
            echo_state <= S_IDLE;
            tx_dv <= 1'b0;
            tx_byte <= 8'h00;
        end else begin
            tx_dv <= 1'b0; // O pulso 'tx_dv' dura apenas 1 ciclo
            
            case (echo_state)
                S_IDLE: begin
                    // Se um byte chegou (rx_dv=1) E o TX está livre (!tx_active)
                    if (rx_dv && !tx_active) begin
                        tx_byte <= filter_select; // Carrega o byte do MUX
                        tx_dv <= 1'b1;            // Inicia o envio
                        echo_state <= S_SEND;
                    end
                end 
                
                S_SEND: begin
                    // Volta para IDLE no próximo ciclo
                    echo_state <= S_IDLE;
                end
                
                default: echo_state <= S_IDLE;
            endcase
        end
    end


endmodule