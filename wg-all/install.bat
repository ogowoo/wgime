@echo off
rem ============================================================
rem  install.bat - Wg one-shot launcher (fake installer)
rem  Both editions are single-file ps1 payload editions (embedded
rem  base64 DLL, extracted at runtime; no separate dll files):
rem    WgIme.ps1   full IME (pinyin/wubi/mixed/EN-CN)
rem    WgTray.ps1  tray toolbox (tools.txt / plugins / config apps)
rem  This bat is the single entry point.
rem  Autostart is NOT built in (no -Install / no scheduled task / no
rem  tray item): if you want launch-at-logon, add one of these commands
rem  to your own task scheduler / startup folder:
rem    powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgIme.ps1
rem    powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgTray.ps1
rem
rem  Usage:
rem    install.bat          start ALL (IME + tray toolbox)
rem    install.bat ime      start only the IME
rem    install.bat tray     start only the tray toolbox
rem
rem  Errors are logged to %TEMP%\WgIme_error.log / WgTray_error.log
rem ============================================================
set "WG_DIR=%~dp0"
set "MODE=%~1"
if "%MODE%"=="" set "MODE=all"
if /i "%MODE%"=="ime" goto :ime
if /i "%MODE%"=="tray" goto :tray
:all
echo  [Wg] starting IME + tray toolbox ...
start "" powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File (Join-Path $env:WG_DIR 'WgIme.ps1')
start "" powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File (Join-Path $env:WG_DIR 'WgTray.ps1')
goto :done
:ime
echo  [Wg] starting IME ...
start "" powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File (Join-Path $env:WG_DIR 'WgIme.ps1')
goto :done
:tray
echo  [Wg] starting tray toolbox ...
start "" powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File (Join-Path $env:WG_DIR 'WgTray.ps1')
:done
echo.
echo  [Wg] done - tray icons: WgIme (IME) / WgTray (toolbox)
echo  autostart is not built in - use your own task scheduler if needed
echo  press any key to close this window ...
pause >nul
exit /b
