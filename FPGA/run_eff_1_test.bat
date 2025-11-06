@echo off
echo ========================================
echo Compilando Testbench: eff_1_tb
echo ========================================

echo.
echo [1/2] Compilando modulo eff_1...
iverilog -g2012 -o eff_1_test ^
    eff_1.sv ^
    eff_1_tb.sv

if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERRO] Falha na compilacao!
    pause
    exit /b 1
)

echo.
echo [2/2] Executando simulacao...
vvp eff_1_test

if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERRO] Falha na execucao!
    pause
    exit /b 1
)

echo.
echo ========================================
echo Simulacao concluida!
echo Arquivo gerado: wave_eff_1.vcd
echo ========================================
echo.
echo Para visualizar: gtkwave wave_eff_1.vcd
echo.
pause
