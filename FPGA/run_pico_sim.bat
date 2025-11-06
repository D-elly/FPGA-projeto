@echo off
echo ========================================
echo Compilando Testbench: uart_echo_pico_sim_tb
echo ========================================

echo.
echo [1/2] Compilando modulos...
iverilog -g2012 -o uart_pico_sim ^
    uart_rx.sv ^
    uart_tx.sv ^
    uart_top.sv ^
    eff_1.sv ^
    uart_echo_colorlight_i9.sv ^
    uart_echo_pico_sim_tb.sv

if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERRO] Falha na compilacao!
    pause
    exit /b 1
)

echo.
echo [2/2] Executando simulacao...
vvp uart_pico_sim

if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERRO] Falha na execucao!
    pause
    exit /b 1
)

echo.
echo ========================================
echo Simulacao concluida!
echo Arquivo gerado: wave_pico_sim.vcd
echo ========================================
echo.
echo Para visualizar: gtkwave wave_pico_sim.vcd
echo.
pause
