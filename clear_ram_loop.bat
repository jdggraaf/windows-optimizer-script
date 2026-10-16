@echo off
title Windows Optimizer Script
color 0A

:: === One-time: Disable Windows Updates ===
echo [*] Disabling Windows Updates...
sc stop wuauserv >nul 2>&1
sc config wuauserv start= disabled >nul 2>&1
sc stop UsoSvc >nul 2>&1
sc config UsoSvc start= disabled >nul 2>&1
sc stop bits >nul 2>&1
sc config bits start= disabled >nul 2>&1

reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /t REG_DWORD /d 1 /f >nul
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications" /v ToastEnabled /t REG_DWORD /d 0 /f >nul

schtasks /Change /TN "Microsoft\Windows\WindowsUpdate\Scheduled Start" /Disable >nul 2>&1
schtasks /Change /TN "Microsoft\Windows\WindowsUpdate\sih" /Disable >nul 2>&1
schtasks /Change /TN "Microsoft\Windows\WindowsUpdate\sihboot" /Disable >nul 2>&1

echo [✓] Windows Update Disabled.
echo.

:loop
echo ============================
echo [*] Starting Optimization Loop
echo ============================

:: === Clean temp folders ===
echo [*] Cleaning temp folders...
del /q /f /s %TEMP%\* >nul 2>&1
del /q /f /s C:\Windows\Temp\* >nul 2>&1

:: === Flush DNS ===
echo [*] Flushing DNS cache...
ipconfig /flushdns >nul

:: === Close bloat background tasks ===
echo [*] Killing background apps...
taskkill /f /im OneDrive.exe >nul 2>&1
taskkill /f /im Teams.exe >nul 2>&1
taskkill /f /im AdobeIPCBroker.exe >nul 2>&1
taskkill /f /im AdobeCollabSync.exe >nul 2>&1
taskkill /f /im ArmouryCrate.UserSessionHelper.exe
taskkill /f /im GameSDK.exe
taskkill /f /im NahimicService.exe
taskkill /f /im AuraService.exe

:: === Clean RAM (replaces RAMMap + per-process working-set trim) ===
:: Clean-Memory.ps1 uses built-in Windows APIs, so no RAMMap binary is needed.
:: -Auto only cleans when available RAM is below 15%% and at most once per 30 minutes,
:: because purging the standby cache every few seconds forces disk re-reads and causes stutter.
:: See CLEAN-MEMORY.md for areas, thresholds and the scheduled-task alternative.
echo [*] Checking memory (Clean-Memory.ps1 -Auto)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Clean-Memory.ps1" -Auto

echo [✓] Cleanup Done. Sleeping for 10 seconds...
timeout /t 10 >nul
goto loop
