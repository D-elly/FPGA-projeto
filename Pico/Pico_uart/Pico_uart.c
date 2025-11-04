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

#define BUTTON_A 5
#define BUTTON_B 6

//Saídas do processamento
#define BUZZER_PIN 21  // Pino conectado ao buzzer
#define DAC_OSC_PIN 20 // Pino conecctado ao osciloscópio

#define N_NOTES (sizeof(melody_notes) / sizeof(melody_notes[0]))

#define ADC_CENTER 128               // Centro da escala de 12 bits (2^11)
#define ADC_AMPLITUDE 127           // Amplitude maxima (2^11 - 1)

const uint8_t melody_notes[] = {  // Frequencias das notas em Hz
    255, 255, 255, 255, 255, 255, 255, 
    255, 255, 255, 255, 255,           
    255, 255, 255, 255, 255, 255, 255, 
    255, 255, 255, 255, 255, 255, 255, 
    255, 255, 255, 255, 255            
};

const uint melody_durations[] = { // Duracoes de cada nota em ms
    500, 500, 500, 500, 500, 500, 1000, 
    500, 500, 500, 500, 1000,           
    500, 500, 500, 500, 500, 500, 1000,
    500, 500, 500, 500, 500, 500, 1000,
    500, 500, 500, 500, 1000
};

uint8_t queue[N_NOTES];
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

//configura tons das notas para serem reproduzidos no buzzer via PWM
void play_tone(uint pin, uint8_t frequency, uint duration_ms);

//função de chamada, coordena qual nota e duração vai ser tocada
void play_melody(uint pin, uint8_t melody);

//configura pwm para entrada do osciloscópio ser analógica
void pwm_init_dac_osc(uint pin);

//configura buzzer pin como saída pwm
void pwm_init_buzzer(uint pin);

//calcula amplitude da onda sonora da nota enviada, gerando amostra para FPGA  
uint8_t calculate_sine_sample(uint freq, uint time_step);

//função de chamada para ativar Uart TX
bool timer_callback(struct repeating_timer *t);

int main() {
    stdio_usb_init();
    sleep_ms(8000);

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

    printf("limpou buffer\n");
    
    counter = 0;
    synced = false;
    header_echo_received = false;  // RESET DA FLAG

    int UART_IRQ = (UART_ID == uart0) ? UART0_IRQ : UART1_IRQ;
    irq_set_exclusive_handler(UART_IRQ, on_uart_rx);
    irq_set_enabled(UART_IRQ, true);
    uart_set_irq_enables(UART_ID, true, false);
    printf("configurou interrupção de on_uart_rx\n");
    
    // 2. CONFIGURACAO DO TIMER (Para amostragem precisa) em intervalos fixos (44.1kHz)
    add_repeating_timer_us(SAMPLE_INTERVAL_US, timer_callback, NULL, &timer);
    printf("configurou interrupção de on_uart_tx\n");

    while (1) tight_loop_contents();
}
    
void on_uart_tx(uint8_t sample) {
    while (!uart_is_writable(UART_ID)) tight_loop_contents();

    uart_putc_raw(UART_ID, HEADER_BYTE);
    uart_putc_raw(UART_ID, sample);
    printf("está mandando o sample: %i \n", sample);
}

void on_uart_rx() {
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
                queue[0] = byte;
                printf("|retorno do fpga: %i| \n", queue[0]);
                printf("Reproduzindo áudio vindo do FPGA\n");
                pwm_set_gpio_level(DAC_OSC_PIN, byte);
                pwm_set_gpio_level(BUZZER_PIN, byte);
                synced = false;
                // cai para armazenar este byte abaixo
            }
        }
    }
}

void play_tone(uint pin, uint8_t frequency, uint duration_ms) {
    uint slice_num = pwm_gpio_to_slice_num(pin);
    uint32_t clock_freq = clock_get_hz(clk_sys);
    uint32_t top = clock_freq / (frequency * 2.5) - 1;  //multiplicando por 2.5 para saída ser audivel

    pwm_set_wrap(slice_num, 255);
    pwm_set_gpio_level(pin, top / 2); 

    pwm_set_gpio_level(pin, 0); 
}

void play_melody(uint pin, uint8_t melody) {
        printf("Qual a nota está tocando: [%i] [%i]\n", 0, melody);
        play_tone(pin, melody, melody_durations[0]);
}

void pwm_init_dac_osc(uint pin) {
    gpio_set_function(pin, GPIO_FUNC_PWM);
    uint slice_num = pwm_gpio_to_slice_num(pin);
    pwm_config config = pwm_get_default_config();
    pwm_config_set_clkdiv(&config, 125.0f); 
    pwm_init(slice_num, &config, true);
    pwm_set_wrap(slice_num, 255);
    pwm_set_gpio_level(pin, 0); 
}

void pwm_init_buzzer(uint pin) {
    gpio_set_function(pin, GPIO_FUNC_PWM);
    uint slice_num = pwm_gpio_to_slice_num(pin);
    pwm_config config = pwm_get_default_config();
    pwm_config_set_clkdiv(&config, 1.0f); 
    pwm_init(slice_num, &config, true);
    pwm_set_gpio_level(pin, 0); 
}

uint8_t calculate_sine_sample(uint freq, uint time_step) {
    // Calcula a fase: 2 * PI * f * t
    double phase = 2.0 * M_PI * (double)freq * (double)time_step * ((double)SAMPLE_INTERVAL_US / 1000000.0);
    printf("phase: %.2f\n", phase);
    
    // Calcula o valor senoidal, escala para amplitude de 12 bits e centraliza em 2048
    double value = ADC_CENTER + (double)ADC_AMPLITUDE * sin(phase);
    printf("value: %.2f\n", value);
    
    // Garante que o valor nao ultrapasse o limite de 12 bits (0 a 4095)
    if (value > 255.0) value = 255;
    if (value < 0.0) value = 0;

    return (uint8_t)round(value);
}

bool timer_callback(struct repeating_timer *t) {
    // 1. CALCULA O SAMPLE DA ONDA SENOIDAL DA FREQUÊNCIA ATUAL
    uint8_t sample_value = calculate_sine_sample(melody_notes[0], sample_counter);
    printf("sample_value: %i\n", sample_value);

    // 2. ENVIAR VIA UART
    on_uart_tx(sample_value);
    printf("Fez a chamada de on_uart_tx no callback\n");

    sample_counter++;

    return true; // Para que o timer continue repetindo o callback
}



