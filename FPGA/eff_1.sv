module eff_1 #(
    parameter int CLK_FREQ     = 50_000_000
)( 
    input  logic       i_clk,         // Clock principal do sistema
    input  logic       i_rst_n,       // Reset assíncrono ativo baixo
    input  logic       data_valid,    
    input  logic [7:0] receive_byte,     // Byte recebido
    output logic [7:0] clipping_byte   // Byte a ser transmitido
);

    // Limite de clipping (ajustável)
    logic [7:0] CLIP_LEVEL = 8'd200;
    logic [7:0] clipping_get;

    always_ff @(posedge i_clk) begin
        if (receive_byte > CLIP_LEVEL) begin
            clipping_get <= CLIP_LEVEL;
        end else if (receive_byte < -CLIP_LEVEL) begin
            clipping_get <= -CLIP_LEVEL; //não vai ser usado, pois não manda valores negativos
        end else begin
            clipping_get <= receive_byte;
        end 
    end 
    assign clipping_byte = clipping_get;

endmodule