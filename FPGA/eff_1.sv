module eff_1 #(
    parameter int CLK_FREQ     = 50_000_000
)( 
    input  logic       i_clk,         // Clock principal do sistema
    input  logic       i_rst_n,       // Reset assíncrono ativo baixo
    input  logic [7:0] receive_byte,     // Byte a ser transmitido
    output  logic [7:0] modified_byte   // Byte a ser transmitido
);

    // Limite de clipping (ajustável)
    parameter signed [7:0] CLIP_LEVEL = 200;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (i_rst_n) begin
            // Aplicando hard clipping
            if (receive_byte > CLIP_LEVEL)
                modified_byte <= CLIP_LEVEL;
            else if (receive_byte < -CLIP_LEVEL)
                modified_byte <= -CLIP_LEVEL; //não vai ser usado, pois não manda valores negativos
            else
                modified_byte <= receive_byte;
        end 
    end

endmodule