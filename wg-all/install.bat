@echo off
rem ============================================================
rem  install.bat - Wg one-shot launcher (fake installer)
rem  Both DLL editions (WgIme.dll IME + WgTray.dll toolbox) live
rem  in this folder; this bat is the single entry point:
rem  first run starts BOTH apps and auto-creates both launcher
rem  shortcuts (WgIme.lnk / WgTray.lnk) next to this folder.
rem  Later runs start both again; shortcuts, once created, are
rem  kept as-is (delete them to have them regenerated).
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
start "" powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -Command "try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -Path (Join-Path $env:WG_DIR 'WgTray.dll'); [TrayApp]::Run($env:WG_DIR, (Join-Path $env:WG_DIR 'WgTray.bat')) } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgTray_error.log'), ($_ | Out-String)) }"
goto :done
:ime
echo  [Wg] starting IME ...
start "" powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -Command "try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -Path (Join-Path $env:WG_DIR 'WgIme.dll'); [WgImeLauncher]::Run($env:WG_DIR, (Join-Path $env:WG_DIR 'WgIme.bat')) } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgIme_error.log'), ($_ | Out-String)) }"
goto :done
:tray
echo  [Wg] starting tray toolbox ...
start "" powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -Command "try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -Path (Join-Path $env:WG_DIR 'WgTray.dll'); [TrayApp]::Run($env:WG_DIR, (Join-Path $env:WG_DIR 'WgTray.bat')) } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgTray_error.log'), ($_ | Out-String)) }"
:done
echo.
echo  [Wg] done - tray icons: WgIme (IME) / WgTray (toolbox)
echo  launcher shortcuts: WgIme.lnk / WgTray.lnk (auto-created on first run)
echo  press any key to close this window ...
pause >nul
exit /b
