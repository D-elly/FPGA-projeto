#include <stdio.h>
#include "pico/stdlib.h"

uart_rx #(
    .CLK_FREQ(50000000),
    .BAUD_RATE(115200)
) uart_rx_inst (
    .clk(clk),
    .rst(rst),
    .rx(uart_rx_pin),
    .data_out(received_byte),
    .data_ready(received_flag)
);

int main()
{
    stdio_init_all();

    while (true) {
        printf("Hello, world!\n");
        sleep_ms(1000);
    }
}
