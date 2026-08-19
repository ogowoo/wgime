@echo off
rem ============================================================
rem  WgIme - DLL edition (full IME, thin launcher)
rem  Loads the precompiled WgIme.dll next to this file. The base
rem  dictionaries are embedded in the assembly; py.txt / wb.txt /
rem  ec.txt next to this bat still extend them (optional).
rem  No base64 payload / no runtime compile / no self-extract.
rem  Errors are logged to %TEMP%\WgIme_error.log
rem ============================================================
set "WGIME_PATH=%~f0"
set "WGIME_DIR=%~dp0"
powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -Command "try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -Path (Join-Path $env:WGIME_DIR 'WgIme.dll'); [WgImeLauncher]::Run($env:WGIME_DIR, $env:WGIME_PATH) } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgIme_error.log'), ($_ | Out-String)); [System.Windows.Forms.MessageBox]::Show(($_ | Out-String),'WgIme Error') | Out-Null }"
exit /b
