@echo off
rem ============================================================
rem  WgTray - DLL edition (tray-only toolbox, no IME)
rem  Loads the precompiled WgTray.dll next to this file and runs.
rem  No embedded payload / no runtime compile / no self-extract.
rem  Add-Type -Path works on ConstrainedLanguage machines too.
rem  Errors are logged to %TEMP%\WgTray_error.log
rem ============================================================
set "WGTRAY_PATH=%~f0"
set "WGTRAY_DIR=%~dp0"
powershell.exe -NoProfile -NoLogo -WindowStyle Hidden -Command "try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -Path (Join-Path $env:WGTRAY_DIR 'WgTray.dll'); [TrayApp]::Run($env:WGTRAY_DIR, $env:WGTRAY_PATH) } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgTray_error.log'), ($_ | Out-String)); [System.Windows.Forms.MessageBox]::Show(($_ | Out-String),'WgTray Error') | Out-Null }"
exit /b
