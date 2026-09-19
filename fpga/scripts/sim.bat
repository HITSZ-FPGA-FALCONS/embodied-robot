@echo off
REM ============================================================
REM  Simulation runner (Icarus Verilog)
REM ------------------------------------------------------------
REM  Usage:  sim.bat <testbench> <dut files...>
REM
REM  Example:
REM      sim.bat fpga\tb\tb_counter.v fpga\rtl\counter.v
REM
REM  Does three things:
REM      1. Compile testbench + DUT
REM      2. Run simulation, report PASS / FAIL
REM      3. Produce wave.vcd  (view with: gtkwave wave.vcd)
REM
REM  Requirement:
REM      winget install --id Icarus.Verilog
REM
REM  NOTE: This file is deliberately pure ASCII.
REM        A .bat with Chinese characters must be saved as GBK for
REM        cmd.exe to read it, but editors like VSCode default to
REM        UTF-8 and will silently break it on save. Keeping this
REM        ASCII avoids that trap entirely.
REM        Chinese documentation lives in fpga/README.md
REM
REM  STATUS (checked 2026-09-20): iverilog is NOT installed on this machine,
REM  so the earlier "verified PASS" record could not be reproduced.
REM  Do NOT treat any PASS from this script as evidence until a real run
REM  is shown. See the status doc under docs/test/  (item B-1)
REM ============================================================

setlocal enabledelayedexpansion

set IVERILOG=
set VVP=
set GTKWAVE=

where iverilog >nul 2>&1 && set IVERILOG=iverilog
if "!IVERILOG!"=="" if exist "C:\iverilog\bin\iverilog.exe" set IVERILOG=C:\iverilog\bin\iverilog.exe

where vvp >nul 2>&1 && set VVP=vvp
if "!VVP!"=="" if exist "C:\iverilog\bin\vvp.exe" set VVP=C:\iverilog\bin\vvp.exe

where gtkwave >nul 2>&1 && set GTKWAVE=gtkwave
if "!GTKWAVE!"=="" if exist "C:\iverilog\gtkwave\bin\gtkwave.exe" set GTKWAVE=C:\iverilog\gtkwave\bin\gtkwave.exe

if "!IVERILOG!"=="" (
    echo [ERROR] iverilog not found. Install it first:
    echo         winget install --id Icarus.Verilog
    exit /b 1
)

if "%~1"=="" (
    echo Usage: sim.bat ^<testbench^> ^<dut files...^>
    echo Example: sim.bat fpga\tb\tb_counter.v fpga\rtl\counter.v
    exit /b 1
)

set TB=%~1
shift
set DUTS=
:collect
if "%~1"=="" goto done_collect
set DUTS=!DUTS! %1
shift
goto collect
:done_collect

cd /d "%~dp0..\.."

echo ============================================================
echo  Testbench : %TB%
echo  DUT       : %DUTS%
echo ============================================================
echo.

echo [1/2] Compiling...
"!IVERILOG!" -o sim.out -g2012 "%TB%" %DUTS%
if errorlevel 1 (
    echo.
    echo [COMPILE FAILED] check syntax / port names / file paths
    exit /b 1
)
echo       compile OK
echo.

echo [2/2] Running...
"!VVP!" sim.out
set RUNRESULT=!errorlevel!
echo.

if exist wave.vcd (
    echo Waveform written: wave.vcd
    if not "!GTKWAVE!"=="" echo   view:  gtkwave wave.vcd
)
echo.

if !RUNRESULT! neq 0 (
    echo ============ SIMULATION ENDED ABNORMALLY ============
    exit /b !RUNRESULT!
)

echo ============ SIMULATION DONE ============
echo.
echo REMINDER: only a printed PASS counts as passing.
echo           A testbench with no checks can never FAIL --
echo           that is not verification.
exit /b 0
