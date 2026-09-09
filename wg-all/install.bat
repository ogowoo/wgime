@echo off
rem ============================================================
rem  install.bat - Wg single launcher (one file, two run modes)
rem  One program file runs both shapes - switch with config mode:
rem    WgIme.ps1   ime mode  = full IME (pinyin/wubi/mixed/EN-CN)
rem                tray mode = tray toolbox (tools.txt / plugins /
rem                            config apps) - no keyboard hook
rem  config.txt key:  mode = ime|tray   (default ime)
rem  tray menu "Run mode" switches and restarts, or pass an
rem  argument here to force a mode before launching.
rem
rem  Usage:
rem    install.bat          start per current config.txt mode
rem    install.bat ime      force mode=ime and start
rem    install.bat tray     force mode=tray and start
rem
rem  Errors are logged to %TEMP%\WgIme_error.log
rem ============================================================
setlocal
set "WG_DIR=%~dp0"
set "MODE=%~1"

rem ---- optional: force config.txt mode before launching ----
if /i "%MODE%"=="ime" goto :setime
if /i "%MODE%"=="tray" goto :settray
goto :launch

:setime
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=Join-Path $env:WG_DIR 'config.txt'; $s=[IO.File]::ReadAllText($p); if($s -match '(?m)^mode\s*=\s*\w+'){ $s=[regex]::Replace($s,'(?m)^mode\s*=\s*\w+','mode = ime') } else { $s=$s.TrimEnd()+[Environment]::NewLine+'mode = ime' }; [IO.File]::WriteAllText($p,$s,(New-Object System.Text.UTF8Encoding($false)))"
goto :launch

:settray
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=Join-Path $env:WG_DIR 'config.txt'; $s=[IO.File]::ReadAllText($p); if($s -match '(?m)^mode\s*=\s*\w+'){ $s=[regex]::Replace($s,'(?m)^mode\s*=\s*\w+','mode = tray') } else { $s=$s.TrimEnd()+[Environment]::NewLine+'mode = tray' }; [IO.File]::WriteAllText($p,$s,(New-Object System.Text.UTF8Encoding($false)))"
goto :launch

:launch
echo  [Wg] starting (mode from config.txt) ...
start "" powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%WG_DIR%WgIme.ps1"
echo.
echo  [Wg] done - tray icon per config mode (IME or toolbox)
echo  switch mode anytime from the tray menu: Run mode - IME / Tray
echo  autostart is not built in - use your own task scheduler if needed
pause >nul
endlocal
exit /b
