#include <stdio.h>
#include "pico/stdlib.h"
#include "hardware/uart.h"
#include "hardware/pwm.h"
#include "hardware/clocks.h"

#define UART_ID uart0
#define BAUD_RATE 9600
#define UART_TX_PIN 0
#define UART_RX_PIN 1
#define BUTTON_A 5
#define BUTTON_B 6
#define BUZZER_PIN 21  // Pino conectado ao buzzer
#define HEADER_BYTE 0xAA  // Byte de sincronização

//clock_handle_t clk_sys = 125000000;

const uint melody_notes[] = {  // Frequencias das notas em Hz
    180, 392, 440, 440, 392, 392, 330, 
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

#define N_NOTES (sizeof(melody_notes) / sizeof(melody_notes[0]))

uint queue[N_NOTES];
volatile int counter = 0;
volatile bool synced = false;
volatile bool header_echo_received = false;  // NOVA FLAG

// Prototipos
void send_image_16x16(uint8_t img[N_NOTES]);
// void configure_pwm_for_buzzer(uint freq);
void on_uart_rx();
void play_tone(uint pin, uint frequency, uint duration_ms);
void play_melody(uint pin, uint melody[N_NOTES]);
void pwm_init_buzzer(uint pin);

int main() {
    stdio_usb_init();
    sleep_ms(8000);

    uint matrix[N_NOTES];
    for (int i = 0; i < N_NOTES; i++) {
        matrix[i] = melody_notes[i];
    }
    

    uart_init(UART_ID, BAUD_RATE);
    gpio_set_function(UART_TX_PIN, GPIO_FUNC_UART);
    gpio_set_function(UART_RX_PIN, GPIO_FUNC_UART);
    uart_set_format(UART_ID, 8, 1, UART_PARITY_NONE);
    uart_set_fifo_enabled(UART_ID, true);
    
    // Configura o pino do buzzer como saída PWM
    pwm_init_buzzer(BUZZER_PIN);
    pwm_set_enabled(pwm_gpio_to_slice_num(BUZZER_PIN), false);  // desliga inicialmente

    // Configura os botões A e B
    gpio_init(BUTTON_A);
    gpio_set_dir(BUTTON_A, GPIO_IN);
    gpio_pull_up(BUTTON_A);
    gpio_init(BUTTON_B);
    gpio_set_dir(BUTTON_B, GPIO_IN);
    gpio_pull_up(BUTTON_B);
    
    printf("\nPressione A para áudio original, B para áudio com efeito.\n");
    
    printf("\n=== TESTE UART 16x16 COM SINCRONIZACAO ===\n");
    printf("Header: 0x%02X\n", HEADER_BYTE);
    printf("Enviando matriz com delay de 2ms/byte...\n\n");
    
    // Limpa buffer UART múltiplas vezes
    for (int clear = 0; clear < 5; clear++) {
        while (uart_is_readable(UART_ID)) uart_getc(UART_ID);
        sleep_ms(20);
    }
    
    counter = 0;
    synced = false;
    header_echo_received = false;  // RESET DA FLAG

    int UART_IRQ = (UART_ID == uart0) ? UART0_IRQ : UART1_IRQ;
    irq_set_exclusive_handler(UART_IRQ, on_uart_rx);
    irq_set_enabled(UART_IRQ, true);
    uart_set_irq_enables(UART_ID, true, false);
    
    // ENVIA HEADER PRIMEIRO
    uart_putc_raw(UART_ID, HEADER_BYTE);
    sleep_ms(10);  // Espera header ser processado
    
    uint32_t start_ms = to_ms_since_boot(get_absolute_time());
    const uint32_t timeout_ms = 10000;
    while ((counter < (N_NOTES)) && 
           ((to_ms_since_boot(get_absolute_time()) - start_ms) < timeout_ms)) {
        sleep_ms(1);
    }

    sleep_ms(100);
    uart_set_irq_enables(UART_ID, false, false);
    irq_set_enabled(UART_IRQ, false);

    printf("Matriz Original:\n");
    for (int i = 0; i < N_NOTES; i++) {
        printf("|0x%02X| \n", matrix[i]);
    }

    printf("\nRecebidos %d byte(s) (synced=%d, header_echo=%d):\n", counter, synced, header_echo_received);
    if (counter == 0) {
        printf("Nenhuma resposta do FPGA.\n");
    } else {
        int correct = 0;
        for (int i = 0; i < N_NOTES; i++) {
            printf("[%02d] ", i);
            uint8_t v = (i < counter) ? queue[i] : 0x00;
            printf("|0x%02X| ", v);
            if (v == matrix[i]) correct++;
            printf("\n");
        }

        //pwm_set_enabled(pwm_gpio_to_slice_num(BUZZER_PIN), false);  // Desliga PWM após reprodução

        printf("\nBytes corretos: %d/%d (%.1f%%)\n", correct, N_NOTES, 
               100.0*correct/(N_NOTES));
    }

    while (1) {
        if (!gpio_get(BUTTON_A)) {
            printf("\nReproduzindo áudio original...\n");
            for (int i = 0; i < N_NOTES; i++) {
                if (matrix[i] > 0) {
                    play_melody(BUZZER_PIN, matrix);
                }
            }
            pwm_set_enabled(pwm_gpio_to_slice_num(BUZZER_PIN), false);
            sleep_ms(200);  // debounce
        }

        if (!gpio_get(BUTTON_B)) {
            printf("\nReproduzindo áudio com efeito...\n");
            for (int i = 0; i < N_NOTES; i++) {
                if (queue[i] > 0) {
                    play_melody(BUZZER_PIN, queue);
                }
            }
            pwm_set_enabled(pwm_gpio_to_slice_num(BUZZER_PIN), false);
            sleep_ms(200);  // debounce
        }

        sleep_ms(10);  // loop leve
    }
    while (1) tight_loop_contents();
}
    
void send_image_16x16(uint8_t img[N_NOTES]) {
    for (int i = 0; i < N_NOTES; i++) {
        uint8_t b = img[i];
        while (!uart_is_writable(UART_ID)) tight_loop_contents();
        uart_putc_raw(UART_ID, b);
        sleep_ms(2);  // 2ms por byte
        
    }
}

// void configure_pwm_for_buzzer(uint freq) {
//     uint slice_num = pwm_gpio_to_slice_num(BUZZER_PIN);
//     uint channel = pwm_gpio_to_channel(BUZZER_PIN);

//     uint32_t clock_freq = 125000000; // Clock padrão do Pico
//     uint32_t wrap = clock_freq / freq;

//     pwm_set_wrap(slice_num, wrap);
//     pwm_set_chan_level(slice_num, channel, wrap / 2);  // 50% duty cycle
//     pwm_set_enabled(slice_num, true);
// }

// Inicialização do PWM para o buzzer
void pwm_init_buzzer(uint pin) {
    gpio_set_function(pin, GPIO_FUNC_PWM);
    uint slice_num = pwm_gpio_to_slice_num(pin);
    pwm_config config = pwm_get_default_config();
    pwm_config_set_clkdiv(&config, 4.0f); 
    pwm_init(slice_num, &config, true);
    pwm_set_gpio_level(pin, 0); 
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
                // cai para armazenar este byte abaixo
            }
        }

        // armazena bytes de dados (apenas dados reais; headers iniciais já removidos)
        if (counter < (N_NOTES)) {
            queue[counter++] = byte;
        }
    }
}

// Tocar uma nota com frequência e duração específicas
void play_tone(uint pin, uint frequency, uint duration_ms) {
    uint slice_num = pwm_gpio_to_slice_num(pin);
    uint32_t clock_freq = clock_get_hz(clk_sys);
    uint32_t top = clock_freq / frequency - 1;

    pwm_set_wrap(slice_num, top);
    pwm_set_gpio_level(pin, top / 2); 

    sleep_ms(duration_ms);
    pwm_set_gpio_level(pin, 0); 
    sleep_ms(50); // Pausa entre notas
}

// Função para reproduzir "Brilha, Brilha Estrelinha"
void play_melody(uint pin, uint melody[N_NOTES]) {
    for (int i = 0; i < sizeof(melody[N_NOTES]); i++) {
        play_tone(pin, melody[i], melody_durations[i]);
    }
}
