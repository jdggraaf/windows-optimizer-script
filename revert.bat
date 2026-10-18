@echo off
title Revert Windows Optimizer Changes
color 0C
rem Undoes what the old clear_ram_loop.bat did. Run as Administrator.
rem /noop = print every command instead of running it (used by the tests; no admin needed).

set "DO="
if /i "%~1"=="/noop" (
    set "DO=echo [noop]"
) else (
    net session >nul 2>&1
    if errorlevel 1 (
        echo [!] Run this file as Administrator ^(right-click, Run as administrator^).
        pause
        exit /b 1
    )
)

echo [*] Restoring Windows Update service start types to the Windows defaults...
%DO% sc config wuauserv start= demand
%DO% sc config UsoSvc start= delayed-auto
%DO% sc config bits start= demand

echo [*] Starting the services...
%DO% sc start wuauserv
%DO% sc start UsoSvc
%DO% sc start bits

echo [*] Removing the policy values the old script wrote...
%DO% reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /f
%DO% reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /f
%DO% reg delete "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications" /v ToastEnabled /f

echo [*] Re-enabling the Windows Update scheduled tasks...
%DO% schtasks /Change /TN "Microsoft\Windows\WindowsUpdate\Scheduled Start" /Enable
%DO% schtasks /Change /TN "Microsoft\Windows\WindowsUpdate\sih" /Enable
%DO% schtasks /Change /TN "Microsoft\Windows\WindowsUpdate\sihboot" /Enable

echo.
echo [OK] Done. A "value not found" message above only means the old script never wrote it.
echo      Check Settings ^> Windows Update and press "Check for updates".
echo      To undo a DebloatKit run instead, use DebloatKit\DebloatKit.ps1 -Undo latest.
if not defined DO pause
exit /b 0
