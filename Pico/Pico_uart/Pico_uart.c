
// Implementacao de um gerador de sinal de teste com controle de tempo através do hardware timer
// Estrutura de dados de 2 bytes por sample
// Envio via UART
//
// Objetivo: 
//      - Gerar samples de audio (amplitude em função do tempo) em forma de onda senoidal (por meio da frequencia e duracao) para o FPGA
//      - Garantir uma taxa de amostragem constante para streaming via UART
//      - Testar a comunicação com um sinal que se assemelha a um áudio real

#include <stdio.h>
#include <math.h>
#include "pico/stdlib.h"
#include "hardware/uart.h"
#include "hardware/timer.h"

// ----- DEFINICOES PARA VALIDACAO / DEBUG  -----
#define DEBUG_LED_PIN 13
#define TEST_FREQUENCY 2 // 2 Hz (Liga/Desliga duas vezes por segundo)
#define TEST_INTERVAL_US (1000000 / (2 * TEST_FREQUENCY)) // Meio ciclo em microssegundos
// ----------------------------------------------

// --- CONFIGURAÇÕES DO PROJETO ---
#define BAUD_RATE 460800  // Baud Rate de comunicacao UART (Pico -> FPGA)
#define UART_ID uart0     // Usando UART0 (GP0=TX, GP1=RX por padrao)
#define UART_TX_PIN 0     // TX da UART no Pico
#define UART_RX_PIN 1     // RX da UART no Pico

// --- CONFIGURACOES DE AUDIO/TESTE ---
#define SAMPLE_RATE 44100             // Taxa de amostragem desejada (Hz)
#define ADC_CENTER 2048               // Centro da escala de 12 bits (2^11)
#define ADC_AMPLITUDE 2047            // Amplitude maxima (2^11 - 1)
#define N_NOTES (sizeof(melody_notes) / sizeof(melody_notes[0]))

volatile uint32_t sample_counter = 0;                        // Contador global para o tempo dentro da onda senoidal
const uint32_t SAMPLE_INTERVAL_US = 1000000 / SAMPLE_RATE;   // Variável para controlar o tempo de intervalo entre samples (em microsegundos)
uint current_note_index = 0;
struct repeating_timer timer;

// --- ESTRUTURA DE DADOS UART (Sync Bytes + 12-bit Sample em 2 Bytes) ---
const uint8_t SYNC_BYTE_1 = 0xAA;
const uint8_t SYNC_BYTE_2 = 0x55;

// --- DADOS MUSICAIS ---
// Usado para tocar uma melodia em um buzzer (usando PWM para mudar a frequência de saída), não para simular o stream de samples de um sinal de áudio
const uint melody_notes[] = {  // Frequencias das notas em Hz
    392, 392, 440, 440, 392, 392, 330, 
    349, 349, 330, 330, 294,           
    392, 392, 349, 349, 330, 330, 294, 
    392, 392, 440, 440, 392, 392, 330, 
    349, 349, 330, 330, 294            
};

const uint melody_durations[] = { // Duracoes de cada nota em ms
    500, 500, 500, 500, 500, 500, 1000, 
    500, 500, 500, 500, 1000,           
    500, 500, 500, 500, 500, 500, 1000,
    500, 500, 500, 500, 500, 500, 1000,
    500, 500, 500, 500, 1000
};

// --- FUNCOES AUXILIARES --- 
void send_data_via_uart(uint16_t sample);
uint16_t calculate_sine_sample(uint freq, uint time_step);
bool timer_callback(struct repeating_timer *t);

int main() {
    stdio_init_all();
    while (!stdio_usb_connected()) {
        sleep_ms(100);
    }

    // 1. CONFIGURACAO DA UART (Pico -> FPGA)
    uart_init(UART_ID, BAUD_RATE);
    gpio_set_function(UART_TX_PIN, GPIO_FUNC_UART);
    gpio_set_function(UART_RX_PIN, GPIO_FUNC_UART);

    // --- INICIALIZACAO DO LED DE DEBUG ---
    gpio_init(DEBUG_LED_PIN);
    gpio_set_dir(DEBUG_LED_PIN, GPIO_OUT);
    // ------------------------------------

    // ----COMENTAR ESTA LINHA DE VALIDACAO----
    // add_repeating_timer_us(-TEST_INTERVAL_US, timer_callback, NULL, &timer);
    // 2. CONFIGURACAO DO TIMER (Para amostragem precisa) em intervalos fixos (44.1kHz)
    add_repeating_timer_us(-SAMPLE_INTERVAL_US, timer_callback, NULL, &timer);
    
    // 3. Gerenciamento da Melodia
    while (1) {
        if (current_note_index < N_NOTES) {
            uint freq = melody_notes[current_note_index];
            uint duration_ms = melody_durations[current_note_index];
            
            printf("Tocando nota %d (Freq: %d Hz) por %d ms...\n", current_note_index, freq, duration_ms);
            sleep_ms(duration_ms); 
            current_note_index++;
            sleep_ms(50);  // Pequeno 'gap' entre notas (silencio)
        } else {
            printf("Melodia terminou. Entrando em modo de espera...\n");
            cancel_repeating_timer(&timer); // Parar o timer de envio de dados
            
            while(1) {// Mantem o loop rodando em modo de espera
                tight_loop_contents(); 
            }
        }
    }
}


/**
 * @brief Envia um sample de 12 bits (uint16_t) empacotado em 4 bytes de transmissao UART.
 * Pacote: [SYNC1] [SYNC2] [MSB] [LSB]
 */
void send_data_via_uart(uint16_t sample) {
    // 1. Envia Sync Bytes
    uart_putc_raw(UART_ID, SYNC_BYTE_1);
    uart_putc_raw(UART_ID, SYNC_BYTE_2);

    // 2. Empacota o sample de 12 bits (usando 2 bytes)
    uint8_t msb = (uint8_t)((sample >> 8) & 0xFF);  // O MSB (Most Significant Byte) contem os bits 11 a 8
    uint8_t lsb = (uint8_t)(sample & 0xFF);         // O LSB (Least Significant Byte) contem os bits 7 a 0

    // 3. Envia os bytes do sample
    uart_putc_raw(UART_ID, msb);
    uart_putc_raw(UART_ID, lsb);
}

/**
 * @brief Calcula o valor de um sample senoidal de 12 bits.
 * @param freq Frequencia da nota (Hz).
 * @param time_step Contador de tempo (para rastrear a fase).
 * @param fs Taxa de amostragem.
 * @return Valor do sample (uint16_t) pronto para ser empacotado.
 */
uint16_t calculate_sine_sample(uint freq, uint time_step) {
    // Calcula a fase: 2 * PI * f * t
    double phase = 2.0 * M_PI * (double)freq * (double)time_step * ((double)SAMPLE_INTERVAL_US / 1000000.0);
    
    // Calcula o valor senoidal, escala para amplitude de 12 bits e centraliza em 2048
    double value = ADC_CENTER + (double)ADC_AMPLITUDE * sin(phase);
    
    // Garante que o valor nao ultrapasse o limite de 12 bits (0 a 4095)
    if (value > 4095.0) return 4095;
    if (value < 0.0) return 0;

    return (uint16_t)round(value);
}

/**
 * @brief calcular e enviar os samples da onda senoidal em intervalos regulares 
 * Esta funcao sera chamada em intervalos de SAMPLE_INTERVAL_US
 *
*/
bool timer_callback(struct repeating_timer *t) {
    // 1. CALCULA O SAMPLE DA ONDA SENOIDAL DA FREQUÊNCIA ATUAL
    uint16_t sample_value = calculate_sine_sample(melody_notes[current_note_index], sample_counter);
    
    // --- COMENTAR ESTE BLOCO DE VALIDAÇÃO (DEBUG) ---
    // printf("Sample N: %u | Freq: %u | Value: %u\n", sample_counter, melody_notes[current_note_index], sample_value);
    // gpio_put(DEBUG_LED_PIN, !gpio_get(DEBUG_LED_PIN));
    // ------------------------

    // 2. ENVIAR VIA UART
    send_data_via_uart(sample_value);
    
    // 3. ATUALIZA CONTADORES
    sample_counter++;

    return true; // Para que o timer continue repetindo o callback
}
