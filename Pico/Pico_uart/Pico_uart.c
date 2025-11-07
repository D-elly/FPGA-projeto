#include <stdio.h>
#include <math.h>
#include "pico/stdlib.h"
#include "hardware/uart.h"
#include "hardware/pwm.h"
#include "hardware/clocks.h"
#include "hardware/timer.h"

//para funcionamento do UART
#define UART_ID uart0
#define BAUD_RATE 115200
#define UART_TX_PIN 0
#define UART_RX_PIN 1
#define HEADER_BYTE 0xAA  // Byte de sincronização

//Saídas do processamento
#define DAC_OSC_PIN 20 // Pino conecctado ao osciloscópio
#define BUZZER_PIN 21   // Pino conectado ao buzzer

#define SINE_FREQ_HZ        250.0f    // Frequência alvo da senóide
#define SAMPLES_PER_CYCLE   100       // Amostras por ciclo (→ Fs = 25 kHz)
#define FS_HZ               5000.0f     // 5 kHz = 1 amostra a cada 100ms (LENTO para debug)
//#define FS_HZ               (SINE_FREQ_HZ * SAMPLES_PER_CYCLE)  // 25 kHz

#define BUTTON_A 5
#define BUTTON_B 6
#define PIN_16 16  //botão A
#define PIN_18 18 //botao
#define led_v 13

// ---------- PWM ----------
/*
 * f_pwm = clk_sys / (clkdiv * (wrap + 1)
 * wrap=255 (8 bits), clkdiv=1.0 → f_pwm ≈ 125e6 / 256 ≈ 488 kHz
 */
#define PWM_WRAP            255
#define PWM_CLKDIV          1.0f
#define N_SINES (sizeof(sine_table) / sizeof(sine_table[0]))

//Tabela senoidal da nota dó(255 Hz) - 100 amostras
static const uint8_t sine_table[SAMPLES_PER_CYCLE] = {
    128,136,144,153,161,169,176,183,190,196,
    202,208,213,218,222,226,229,232,234,236,
    237,238,238,238,237,236,234,232,229,226,
    222,218,213,208,202,196,190,183,176,169,
    161,153,144,136,128,119,111,102,94, 86,
    79, 72, 65, 59, 53, 47, 42, 37, 33, 29,
    26, 23, 21, 19, 18, 17, 17, 17, 18, 19,
    21, 23, 26, 29, 33, 37, 42, 47, 53, 59,
    65, 72, 79, 86, 94,102,111,119,128,136,
    144,153,161,169,176,183,190,196,202,208  // CORRIGIDO: Completados 100 elementos
};

static volatile uint32_t s_index = 0;

volatile int counter = 0;
volatile bool synced = false;
volatile bool header_echo_received = false;  // NOVA FLAG

struct repeating_timer timer;

// TX ativo, envia dados para o FPGA
void on_uart_tx(uint8_t sample);

// RX ativo, recebe dados do FPGA;
void on_uart_rx();

//configura pwm para entrada do osciloscópio ser analógica
void pwm_init_dac_osc(uint pin);

//configura buzzer pin como saída pwm
void pwm_init_buzzer(uint pin);

void select_filter();

static bool sample_timer_cb(repeating_timer_t *rt);

int main() {
    stdio_usb_init();
    
    // CRÍTICO: Aguarda USB serial inicializar
    sleep_ms(2000);
    printf("\n=== SISTEMA INICIANDO ===\n");

    uart_init(UART_ID, BAUD_RATE);
    gpio_set_function(UART_TX_PIN, GPIO_FUNC_UART);
    gpio_set_function(UART_RX_PIN, GPIO_FUNC_UART);
    uart_set_format(UART_ID, 8, 1, UART_PARITY_NONE);
    uart_set_fifo_enabled(UART_ID, true);
    
    printf("UART configurado: %d baud\n", BAUD_RATE);
    
    // Configura o pino do buzzer e pino do osciloscópio como saída PWM
    pwm_init_buzzer(BUZZER_PIN);
    pwm_init_dac_osc(DAC_OSC_PIN);

    //inicializando botões
    gpio_init(BUTTON_A);
    gpio_set_dir(BUTTON_A, GPIO_IN);
    gpio_pull_up(BUTTON_A);

    gpio_init(BUTTON_B);
    gpio_set_dir(BUTTON_B, GPIO_IN);
    gpio_pull_up(BUTTON_B);

    //inicializando pinos de saída para o FPGA
    gpio_init(PIN_16);
    gpio_set_dir(PIN_16, GPIO_OUT);
    gpio_put(PIN_16, 0);

    gpio_init(PIN_18);
    gpio_set_dir(PIN_18, GPIO_OUT);
    gpio_put(PIN_18, 0);

    gpio_init(led_v);
    gpio_set_dir(led_v, GPIO_OUT);
    gpio_put(led_v, 0);
    
    printf("Pinos configurados\n");
    
    // Limpa buffer UART múltiplas vezes
    for (int clear = 0; clear < 5; clear++) {
        while (uart_is_readable(UART_ID)) uart_getc(UART_ID);
    }
    
    printf("Buffer UART limpo\n");
    
    counter = 0;
    synced = false;
    header_echo_received = false;

    int UART_IRQ = (UART_ID == uart0) ? UART0_IRQ : UART1_IRQ;
    irq_set_exclusive_handler(UART_IRQ, on_uart_rx);
    irq_set_enabled(UART_IRQ, true);
    uart_set_irq_enables(UART_ID, true, false);
    
    printf("IRQ UART configurada\n");
    
    // Configura timer para envio periódico
    repeating_timer_t timer;
    double ts_us = 1e6 / FS_HZ;               // 40 us para 25 kHz
    int64_t interval_us = -(int64_t)(ts_us);  // NEGATIVO para timer repetitivo!

    add_repeating_timer_us(interval_us, sample_timer_cb, NULL, &timer);
    
    printf("Timer TX configurado: %lld us (%.1f kHz)\n", -interval_us, FS_HZ/1000.0f);
    printf("\n=== SISTEMA BIDIRECIONAL ATIVO ===\n");
    printf("TX: Enviando senoide 250 Hz @ 25 kHz\n");
    printf("RX: Aguardando echo do FPGA\n\n"); 

    while (1) {
        tight_loop_contents();
    }
}
    
void on_uart_tx(uint8_t sample) {
    while (!uart_is_writable(UART_ID)) tight_loop_contents();

    uart_putc_raw(UART_ID, HEADER_BYTE);
    uart_putc_raw(UART_ID, sample); 
}

void on_uart_rx() {
    static uint32_t rx_count = 0;
    
    while (uart_is_readable(UART_ID)) {
        int rv = uart_getc(UART_ID);
        if (rv < 0) break;
        uint8_t byte = (uint8_t)rv;
        
        rx_count++;
        
        // **MODO DEBUG SIMPLIFICADO: Imprime TUDO que recebe**
        printf("[RX#%lu] 0x%02X (%3d) ", rx_count, byte, byte);
        
        if (byte == HEADER_BYTE) {
            printf("<-- HEADER\n");
        } else {
            printf("<-- DADO\n");
            // Atualiza PWM com qualquer dado recebido
            pwm_set_gpio_level(DAC_OSC_PIN, byte);
            pwm_set_gpio_level(BUZZER_PIN, byte * 8);
        }
    }
}

void pwm_init_dac_osc(uint pin) {
    gpio_set_function(pin, GPIO_FUNC_PWM);
    uint slice_num = pwm_gpio_to_slice_num(pin);
    pwm_config config = pwm_get_default_config();

    pwm_set_wrap(slice_num, PWM_WRAP);
    pwm_config_set_clkdiv(&config, PWM_CLKDIV);
    pwm_init(slice_num, &config, false);

    pwm_set_gpio_level(pin, PWM_WRAP / 2); 
    pwm_set_enabled(slice_num, true);
}

void pwm_init_buzzer(uint pin) {
    gpio_set_function(pin, GPIO_FUNC_PWM);
    uint slice = pwm_gpio_to_slice_num(pin);

    pwm_config cfg = pwm_get_default_config();
    pwm_config_set_wrap(&cfg, PWM_WRAP);
    pwm_config_set_clkdiv(&cfg, PWM_CLKDIV);
    pwm_init(slice, &cfg, false);

    pwm_set_gpio_level(pin, PWM_WRAP / 2);
    pwm_set_enabled(slice, true);

}

static bool sample_timer_cb(repeating_timer_t *rt) {
    static uint32_t tx_count = 0;
    
    // Pega valor da tabela senoidal
    uint8_t level = sine_table[s_index];
    
    // Incrementa índice (com wrap)
    s_index++;
    if (s_index >= SAMPLES_PER_CYCLE) {
        s_index = 0;
    }
    
    // Envia header + dado via UART
    on_uart_tx(level);
    
    // Debug: Mostra TODA transmissão (não só a cada 100)
    tx_count++;
    printf("[TX#%lu] HEADER(0xAA) + DATA(0x%02X=%d) | s_index=%lu/%d\n", 
           tx_count, level, level, (unsigned long)s_index, SAMPLES_PER_CYCLE);
    
    select_filter();
    
    return true; // Continua repetindo
}

void select_filter(){
    if(!gpio_get(BUTTON_A)){
        gpio_put(PIN_18, 0);
        gpio_put(PIN_16, 1);
        gpio_put(led_v, 1);
    }
    if(!gpio_get(BUTTON_B)){
        gpio_put(PIN_16, 0);
        gpio_put(PIN_18, 1);
        gpio_put(led_v, 0);
    }
    return;
}



