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
#define SAMPLE_RATE 4000           // Taxa de amostragem desejada (Hz)

//Saídas do processamento
#define DAC_OSC_PIN 20 // Pino conecctado ao osciloscópio

#define N_NOTES (sizeof(melody_notes) / sizeof(melody_notes[0]))

#define ADC_CENTER 128               // Centro da escala de 12 bits (2^11)
#define ADC_AMPLITUDE 127           // Amplitude maxima (2^11 - 1)

#define BUZZER_PIN 16   // Pino conectado ao buzzer
#define SINE_FREQ_HZ        250.0f    // Frequência alvo da senóide
#define SAMPLES_PER_CYCLE   100       // Amostras por ciclo (→ Fs = 25 kHz)
#define FS_HZ               (SINE_FREQ_HZ * SAMPLES_PER_CYCLE)  // 25 kHz


// ---------- PWM ----------
/*
 * f_pwm = clk_sys / (clkdiv * (wrap + 1))
 * wrap=255 (8 bits), clkdiv=1.0 → f_pwm ≈ 125e6 / 256 ≈ 488 kHz
 */
#define PWM_WRAP            255
#define PWM_CLKDIV          1.0f

//Tabela senoidal da nota dó(255 Hz)
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
    144,153,161,169,176,183,190,196
};

static volatile uint32_t s_index = 0;

volatile int counter = 0;
volatile bool synced = false;
volatile bool header_echo_received = false;  // NOVA FLAG
volatile uint32_t sample_counter = 0;                        // Contador global para o tempo dentro da onda senoidal
const uint32_t SAMPLE_INTERVAL_US = 1000000 / SAMPLE_RATE;   // Variável para controlar o tempo de intervalo entre samples (em microsegundos)

struct repeating_timer timer;

// TX ativo, envia dados para o FPGA
void on_uart_tx(uint8_t sample);

// RX ativo, recebe dados do FPGA;
void on_uart_rx();

//configura pwm para entrada do osciloscópio ser analógica
void pwm_init_dac_osc(uint pin);

//configura buzzer pin como saída pwm
void pwm_init_buzzer(uint pin);

static bool sample_timer_cb(repeating_timer_t *rt);

int main() {
    stdio_usb_init();

    uart_init(UART_ID, BAUD_RATE);
    gpio_set_function(UART_TX_PIN, GPIO_FUNC_UART);
    gpio_set_function(UART_RX_PIN, GPIO_FUNC_UART);
    uart_set_format(UART_ID, 8, 1, UART_PARITY_NONE);
    uart_set_fifo_enabled(UART_ID, true);
    
    // Configura o pino do buzzer e pino do osciloscópio como saída PWM
    pwm_init_buzzer(BUZZER_PIN);
    pwm_init_dac_osc(DAC_OSC_PIN);
    
    // Limpa buffer UART múltiplas vezes
    for (int clear = 0; clear < 5; clear++) {
        while (uart_is_readable(UART_ID)) uart_getc(UART_ID);
    }
    
    counter = 0;
    synced = false;
    header_echo_received = false;  // RESET DA FLAG

    int UART_IRQ = (UART_ID == uart0) ? UART0_IRQ : UART1_IRQ;
    irq_set_exclusive_handler(UART_IRQ, on_uart_rx);
    irq_set_enabled(UART_IRQ, true);
    uart_set_irq_enables(UART_ID, true, false);
    
    repeating_timer_t timer;
    double ts_us = 1e6 / FS_HZ;               // 40 us para 25 kHz
    int64_t interval_us = -(int64_t)(ts_us);  // negativo = periódico no SDK

    if (!add_repeating_timer_us(interval_us, sample_timer_cb, NULL, &timer)) {
        while (true) tight_loop_contents(); // fallback se falhar
    }
    while (1) tight_loop_contents();
}
    
void on_uart_tx(uint8_t sample) {
    while (!uart_is_writable(UART_ID)) tight_loop_contents();

    uart_putc_raw(UART_ID, HEADER_BYTE);
    uart_putc_raw(UART_ID, sample); 
}

void on_uart_rx() {
    pwm_set_gpio_level(DAC_OSC_PIN, 0);
    pwm_set_gpio_level(BUZZER_PIN, 0);

    while (uart_is_readable(UART_ID)) {
        int rv = uart_getc(UART_ID);
        if (rv < 0) break;
        uint8_t byte = (uint8_t)rv;

        // aguarda o primeiro header (sincroniza)
        if (!synced) {
            if (byte == HEADER_BYTE) {
                synced = true;
                header_echo_received = false;
                counter = 0;
            }
            continue; // descarta tudo até o primeiro header
        }

        // descartamos quaisquer 0xAA adicionais (echo repetido)
        if (!header_echo_received) {
            if (byte == HEADER_BYTE) {
                // pula headers repetidos
                continue;
            } else {
                // primeiro byte não-header após a sincronização é o primeiro dado
                header_echo_received = true;
                printf("|retorno do fpga: %i| \n", byte);
                pwm_set_gpio_level(DAC_OSC_PIN, byte);
                pwm_set_gpio_level(BUZZER_PIN, byte);
                synced = false;
                // cai para armazenar este byte abaixo
            }
        }
    }
}

void pwm_init_dac_osc(uint pin) {
    gpio_set_function(pin, GPIO_FUNC_PWM);
    uint slice_num = pwm_gpio_to_slice_num(pin);
    pwm_config config = pwm_get_default_config();

    pwm_set_wrap(slice_num, PWM_WRAP);
    pwm_config_set_clkdiv(&config, PWM_CLKDIV);
    pwm_init(slice_num, &config, true);

    pwm_set_gpio_level(pin, 0); 
    pwm_set_enabled(slice_num, true);
}

void pwm_init_buzzer(uint pin) {
    gpio_set_function(pin, GPIO_FUNC_PWM);
    uint slice_num = pwm_gpio_to_slice_num(pin);
    pwm_config config = pwm_get_default_config();
    pwm_config_set_clkdiv(&config, 1.0f); 
    pwm_init(slice_num, &config, true);
    pwm_set_gpio_level(pin, 0); 
}

static bool sample_timer_cb(repeating_timer_t *rt) {
    uint8_t level = sine_table[s_index];
    s_index++;
    if (s_index >= SAMPLES_PER_CYCLE) s_index = 0;
    on_uart_tx(level);

    return true; // continue recorrente
}



