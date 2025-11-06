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

always_comb begin
    if(botao_a)begin
        filter_select = clipping_byte;

    end else if(botao_b) begin
        filter_select = bitcrusher_out;

    end else begin
        // Usa byte filtrado para reduzir ruído
        filter_select = rx_byte;
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
        .data_valid(rx_dv),
        .receive_byte(rx_byte),   
        .clipping_byte(clipping_byte)   
    );
    
`ifdef TESTE_TX_MANUAL
    logic [31:0] timer_counter;
    logic [7:0]  test_char;
    // 50 MHz clock -> 0.5s = 50_000_000 / 2 cycles
    localparam TIMER_500MS = 50_000_000 / 2;
    
    always_ff @(posedge clk_50mhz or negedge reset_n_internal) begin
        if (!reset_n_internal) begin
            timer_counter <= 32'd0;
            test_char <= 8'd65;
            tx_dv <= 1'b0;
            tx_byte <= 8'h00;
        end else begin
            tx_dv <= 1'b0;
            if (timer_counter < TIMER_500MS) begin
                timer_counter <= timer_counter + 1'b1;
            end else begin
                timer_counter <= 32'd0;
                if (!tx_active) begin
                    tx_dv <= 1'b1;
                    tx_byte <= test_char;
                    if (test_char < 8'd90) begin
                        test_char <= test_char + 1'b1;
                    end else begin
                        test_char <= 8'd65;
                    end
                end
            end
        end
    end
    
`else
    // ECHO COM HEADER DE SINCRONIZAÇÃO (baseado no código Hough funcionando)
    localparam HEADER_BYTE = 8'hAA;
    
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

    always_ff @(posedge clk_50mhz or negedge reset_n_internal) begin
        if (!reset_n_internal) begin
            state <= WAIT_HEADER;
            tx_dv <= 1'b0;
            tx_byte <= 8'h00;
        end else begin
            // Default: limpa tx_dv (igual ao código Hough)
            tx_dv <= 1'b0;

            case (state)
                WAIT_HEADER: begin
                    // Aguarda header de sincronização (0xAA)
                    if (rx_dv && rx_byte == HEADER_BYTE) begin
                        state <= ECHO_DATA;
                    end
                end
                
                ECHO_DATA: begin
                    // Quando receber um byte de dados (não o header)
                    if (rx_dv) begin
                        // Envia imediatamente se TX não estiver ativo
                        if (!tx_active) begin
                            tx_dv <= 1'b1;
                            tx_byte <= filter_select;
                            state <= WAIT_TX_DONE;
                        end
                        // Se tx_active, aguarda na mesma posição (não descarta)
                    end
                end
                
                WAIT_TX_DONE: begin
                    // Aguarda transmissão completar (usando borda ascendente)
                    if (tx_done_rising) begin
                        tx_dv <= 1'b0;
                        state <= ECHO_DATA;  // Volta para aguardar próximo dado
                    end
                end
                
                default: state <= WAIT_HEADER;
            endcase
        end
    end
`endif

endmodule