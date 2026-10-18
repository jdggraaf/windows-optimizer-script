@echo off
title clear_ram_loop.bat (retired)
color 0E
rem Retired. This file used to disable Windows Update, UsoSvc and BITS, then loop every 10 seconds
rem (temp purge, working-set trim, taskkill, RAMMap standby purge). None of that is done any more.
rem /noop = print the message and the launch command, start nothing (used by the tests).

echo ============================================================
echo  clear_ram_loop.bat has been retired
echo ============================================================
echo.
echo  It no longer disables Windows Update, UsoSvc or BITS, and it no longer
echo  loops. Those steps removed security updates, broke Intune, Defender
echo  signature updates and Delivery Optimization, and the 10 second standby
echo  purge only threw away useful cache.
echo.
echo  Use DebloatKit instead. Every change is previewed, reversible and safe by default:
echo    GUI:      DebloatKit\DebloatKit-GUI.ps1
echo    Preview:  DebloatKit\DebloatKit.ps1 -WhatIf
echo    Memory:   DebloatKit\Get-MemoryPressure.ps1   (read-only, tells you if you really need more RAM)
echo.
echo  Used the old script before? Run revert.bat as Administrator to restore
echo  Windows Update, UsoSvc and BITS.
echo.

if /i "%~1"=="/noop" (
    echo [noop] would run: powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0DebloatKit\DebloatKit-GUI.ps1"
    exit /b 0
)

if not exist "%~dp0DebloatKit\DebloatKit-GUI.ps1" (
    echo [!] DebloatKit\DebloatKit-GUI.ps1 was not found next to this file.
    echo     Open a PowerShell in the DebloatKit folder and run .\DebloatKit-GUI.ps1
    pause
    exit /b 1
)

echo [*] Opening the DebloatKit GUI...
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0DebloatKit\DebloatKit-GUI.ps1"
exit /b 0
