@echo off
rem ============================================================
rem  install.bat - Wg one-shot launcher (fake installer)
rem  WgTray is the single-file ps1 payload edition (embedded DLL,
rem  no separate dll file); WgIme is the DLL edition. This bat is
rem  the single entry point; first run auto-creates the launcher
rem  shortcuts (WgIme.lnk / WgTray.lnk) next to this folder.
rem  For autostart at logon, run:  WgTray.ps1 -Install
rem  (registers a scheduled task; remove with WgTray.ps1 -RemoveTask)
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
start "" powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -Command "try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -Path (Join-Path $env:WG_DIR 'WgIme.dll'); [WgImeLauncher]::Run($env:WG_DIR, (Join-Path $env:WG_DIR 'WgIme.bat')) } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgIme_error.log'), ($_ | Out-String)) }"
start "" powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File (Join-Path $env:WG_DIR 'WgTray.ps1')
goto :done
:ime
echo  [Wg] starting IME ...
start "" powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -Command "try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -Path (Join-Path $env:WG_DIR 'WgIme.dll'); [WgImeLauncher]::Run($env:WG_DIR, (Join-Path $env:WG_DIR 'WgIme.bat')) } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgIme_error.log'), ($_ | Out-String)) }"
goto :done
:tray
echo  [Wg] starting tray toolbox ...
start "" powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File (Join-Path $env:WG_DIR 'WgTray.ps1')
:done
echo.
echo  [Wg] done - tray icons: WgIme (IME) / WgTray (toolbox)
echo  WgTray autostart at logon: run "WgTray.ps1 -Install" once
echo  (scheduled task; remove with WgTray.ps1 -RemoveTask)
echo  press any key to close this window ...
pause >nul
exit /b
