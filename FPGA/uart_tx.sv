// uart_tx.sv
// UART Transmitter Module - SystemVerilog
// Otimizado para comunicação FPGA <-> Raspberry Pi Pico
//
// Configuração padrão: 115200 baud, 8N1 (8 bits, No parity, 1 stop bit)
// Clock: 50 MHz
// CLKS_PER_BIT = 50_000_000 / 115200 = 434 (aproximadamente)

module uart_tx #(
    parameter int CLK_FREQ     = 50_000_000,
    parameter int BAUD_RATE    = 115200,
    parameter int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE
)(
    input  logic       i_clk,
    input  logic       i_rst_n,
    input  logic       i_tx_dv,      // Pulso de 1 ciclo para iniciar transmissão
    input  logic [7:0] i_tx_byte,    // Byte a ser transmitido

    output logic       o_tx_serial,  // Linha UART TX
    output logic       o_tx_active,  // '1' enquanto transmitindo
    output logic       o_tx_done     // Pulso de 1 ciclo ao final da transmissão
);

    typedef enum logic [2:0] {
        IDLE      = 3'b000,
        START_BIT = 3'b001,
        DATA_BITS = 3'b010,
        STOP_BIT  = 3'b011
    } state_t;

    state_t state, next_state;

    logic [$clog2(CLKS_PER_BIT)-1:0] clk_count;
    logic [2:0] bit_index;
    logic [7:0] tx_data;
    logic       tx_dv_latched;

    // Lógica sequencial
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state       <= IDLE;
            clk_count   <= 0;
            bit_index   <= 0;
            tx_data     <= 0;
            o_tx_serial <= 1;
            o_tx_active <= 0;
            o_tx_done   <= 0;
            tx_dv_latched <= 0;
        end else begin
            o_tx_done <= 0; // Pulso de 1 ciclo

            case (state)
                IDLE: begin
                    o_tx_serial <= 1;
                    o_tx_active <= 0;
                    clk_count   <= 0;
                    bit_index   <= 0;

                    if (i_tx_dv && !tx_dv_latched) begin
                        tx_data        <= i_tx_byte;
                        tx_dv_latched  <= 1;
                        o_tx_active    <= 1;
                        state          <= START_BIT;
                    end else begin
                        tx_dv_latched <= 0;
                    end
                end

                START_BIT: begin
                    o_tx_serial <= 0;
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                    end else begin
                        clk_count <= 0;
                        state     <= DATA_BITS;
                    end
                end

                DATA_BITS: begin
                    o_tx_serial <= tx_data[bit_index];
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                    end else begin
                        clk_count <= 0;
                        if (bit_index < 7) begin
                            bit_index <= bit_index + 1;
                        end else begin
                            bit_index <= 0;
                            state     <= STOP_BIT;
                        end
                    end
                end

                STOP_BIT: begin
                    o_tx_serial <= 1;
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                    end else begin
                        clk_count   <= 0;
                        o_tx_done   <= 1;
                        o_tx_active <= 0;
                        state       <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
