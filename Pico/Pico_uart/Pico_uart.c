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

#define N_NOTES (sizeof(melody_notes) / sizeof(melody_notes[0]))

uint8_t queue[N_NOTES];
volatile int counter = 0;
volatile bool synced = false;
volatile bool header_echo_received = false;  // NOVA FLAG

// TX ativo, envia dados para o FPGA
void on_uart_tx(uint8_t sample[N_NOTES]);

// RX ativo, recebe dados do FPGA;
void on_uart_rx();

//configura tons das notas para serem reproduzidos no buzzer via PWM
void play_tone(uint pin, uint8_t frequency, uint duration_ms);

//função de chamada, coordena qual nota e duração vai ser tocada
void play_melody(uint pin, uint8_t melody[N_NOTES]);

//configura buzzer pin como saída pwm
void pwm_init_buzzer(uint pin);

//void compress_notes(uint8_t)

int main() {
    stdio_usb_init();

    uint8_t matrix[N_NOTES];
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

    // Configura os botões A e B
    gpio_init(BUTTON_A);
    gpio_set_dir(BUTTON_A, GPIO_IN);
    gpio_pull_up(BUTTON_A);
    gpio_init(BUTTON_B);
    gpio_set_dir(BUTTON_B, GPIO_IN);
    gpio_pull_up(BUTTON_B);
    
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

    //depois de enviar cabeçalho, envia dados da matrix
    on_uart_tx(matrix);
    
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
        printf("[%02d] ", i);
        printf("|0x%02X|", matrix[i]);
        printf("\n");
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

        printf("\nBytes corretos: %d/%d (%.1f%%)\n", correct, N_NOTES, 
               100.0*correct/(N_NOTES));
    }

    printf("Reproduzindo audio original\n");
    play_melody(BUZZER_PIN, matrix);

    printf("Reproduzindo áudio vindo do FPGA\n");
    play_melody(BUZZER_PIN, queue);

    while (1) tight_loop_contents();
}
    
void on_uart_tx(uint8_t sample[N_NOTES]) {
    for (int i = 0; i < N_NOTES; i++) {
        uint8_t b = sample[i];
        while (!uart_is_writable(UART_ID)) tight_loop_contents();
        uart_putc_raw(UART_ID, b);
        //sleep_ms(2);  // 2ms por byte
        
    }
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

void play_tone(uint pin, uint8_t frequency, uint duration_ms) {
    uint slice_num = pwm_gpio_to_slice_num(pin);
    uint32_t clock_freq = clock_get_hz(clk_sys);
    uint32_t top = clock_freq / (frequency * 2.5) - 1;  //multiplicando por 2.5 para saída ser audivel

    pwm_set_wrap(slice_num, top);
    pwm_set_gpio_level(pin, top / 2); 

    sleep_ms(duration_ms);
    pwm_set_gpio_level(pin, 0); 
    sleep_ms(50); // Pausa entre notas
}

void play_melody(uint pin, uint8_t melody[N_NOTES]) {
    for (int i = 0; i < N_NOTES; i++) {
        printf("Qual a nota está tocando: [%i] [%i]\n", i, melody[i]);
        play_tone(pin, melody[i], melody_durations[i]);
    }
}


void pwm_init_buzzer(uint pin) {
    gpio_set_function(pin, GPIO_FUNC_PWM);
    uint slice_num = pwm_gpio_to_slice_num(pin);
    pwm_config config = pwm_get_default_config();
    pwm_config_set_clkdiv(&config, 4.0f); 
    pwm_init(slice_num, &config, true);
    pwm_set_gpio_level(pin, 0); 
}




