## Resumo
Este projeto visa desenvolver uma aplicação para Processamento Digital de Sinais (DSP) de áudio em tempo real utilizando-se de plataformas de hardware reconfigurável (FPGAs) e microcontroladores. A arquitetura utiliza o FPGA Lattice ECP5-LF45 como núcleo de processamento de efeitos e o microcontrolador raspberry pi pico como sintetizador de sinal.

## Arquitetura do Sistema
* **Raspberry (Sintetizador):** Gera uma onda senoidal de 8 bits para simular a nota DÓ, em uma taxa de amostragem (`SAMPLE_RATE`) de 5 kHz.
* **Comunicação (UART):** Envia os dados (pacote de 2 bytes: Header + Dado) a 115200 bps para o FPGA.
* **FPGA (Processador):** Recebe o áudio, aplica um efeito selecionado (Hard Clipping ou BitCrusher).
* **Comunicação (UART):** Retorna o áudio processado ao Pico.
* **Pico (Saída):** Recebe o áudio processado e o reproduz em um pino PWM (BUZZER_PIN).

## Tecnologias Utilizadas

* **Microcontrolador:** Raspberry Pi Pico W
* **FPGA:** Lattice ECP5 LF-45
* **Linguagem (Pico):** C/C++ (Pico SDK)
* **Linguagem (FPGA):** SystemVerilog
* **Comunicação:** UART (115200 bps, 8N1)
* **Simulação:** Icarus Verilog + GTKWave

## Como Compilar e Rodar

### Hardware (FPGA)

1.  Mapeie os pinos no arquivo `.lpf`.
2.  Use o script `flash_uart.bat` no terminal VS Code para sintetizar o design (`uart_echo_colorlight_i9.sv`).
3.  O bitstream gerado será carregado no FPGA.

### Software (Pico)

1.  Abra o diretório `Pico/Pico_uart` no VS Code.
2.  Configure o `CMakeLists.txt` (se necessário).
3.  Compile o projeto (Build).
4.  Arraste o arquivo `.uf2` para o Pico no modo BOOTSEL.

## Resultados

* **Forma de Onda (Senoide original):**
* **Forma de Onda (Hard Clipping):**
* **Forma de Onda (Bitcrusher):**
