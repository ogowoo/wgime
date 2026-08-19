# ============================================================
#  wgtray-dll.tests.ps1 - regression tests for the DLL edition
#  (wgtray-dll\WgTray.bat + WgTray.dll: thin launcher + precompiled
#   assembly; no payload, no runtime compile, no self-extract)
#
#  Run with Windows PowerShell 5.1:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray-dll.tests.ps1
#
#  NOTE: ASCII-only file - Windows PS 5.1 reads scripts as ANSI.
# ============================================================
$ErrorActionPreference = 'Stop'
$dllDir = Join-Path $PSScriptRoot '..\wgtray-dll'
$batPath = Join-Path $dllDir 'WgTray.bat'
$dllPath = Join-Path $dllDir 'WgTray.dll'
$script:passed = 0; $script:failed = 0
function T($name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:passed++; Write-Host "PASS  $name" -ForegroundColor Green }
    else     { $script:failed++; Write-Host "FAIL  $name  $detail" -ForegroundColor Red }
}

# ================= 1. thin launcher (no suspicious patterns) =================
if (-not (Test-Path $batPath)) { throw "wgtray-dll\WgTray.bat not found - run build-wgtray-dll.ps1 first" }
$batTxt = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)
T 'launcher starts with @echo off' ($batTxt.StartsWith('@echo off'))
T 'launcher loads the DLL via Add-Type -Path' ($batTxt.Contains('Add-Type -Path'))
T 'launcher has no Invoke-Expression' (-not $batTxt.Contains('Invoke-Expression'))
T 'launcher has no FromBase64String' (-not $batTxt.Contains('FromBase64String'))
T 'launcher has no runtime compile (Add-Type -TypeDefinition)' (-not $batTxt.Contains('Add-Type -TypeDefinition'))
T 'launcher has no -ExecutionPolicy Bypass' (-not $batTxt.Contains('ExecutionPolicy'))
T 'launcher has no PS self-extract marker' (-not $batTxt.Contains('###PWSHTRAY###'))
$bytes = [IO.File]::ReadAllBytes($batPath)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
T 'launcher has no BOM' (-not $bom)
$loneLf = 0
for ($k = 0; $k -lt $bytes.Length; $k++) { if ($bytes[$k] -eq 0x0A -and ($k -eq 0 -or $bytes[$k-1] -ne 0x0D)) { $loneLf++ } }
T 'launcher is pure CRLF (cmd.exe requirement)' ($loneLf -eq 0)

# ================= 2. precompiled DLL =================
if (-not (Test-Path $dllPath)) { throw "wgtray-dll\WgTray.dll not found - run build-wgtray-dll.ps1 first" }
$dllBytes = [IO.File]::ReadAllBytes($dllPath)
T 'DLL is a valid PE (MZ header)' ($dllBytes.Length -ge 2 -and $dllBytes[0] -eq 0x4D -and $dllBytes[1] -eq 0x5A)
Add-Type -Path $dllPath -ErrorAction Stop
T 'DLL loads and exposes TrayApp' ($null -ne [TrayApp])
T 'DLL has the tray Run entry' ($null -ne [TrayApp].GetMethod('Run', [Reflection.BindingFlags]'Static,Public'))
T 'DLL has the plugin manager RunSel (launcher extension)' ($null -ne [TrayApp].GetNestedType('PluginMgrForm', [Reflection.BindingFlags]'NonPublic'))
T 'DLL has no keyboard hook (no IME)' ($null -eq [TrayApp].GetNestedType('KeyBordHook', [Reflection.BindingFlags]'NonPublic'))

# ================= 3. first-run seeding inside the C# (SeedSamples) =================
$tmp = Join-Path $env:TEMP ("wgtray-dll-seed-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$data = Join-Path $env:TEMP ("wgtray-dll-data-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item $tmp -ItemType Directory -Force | Out-Null
New-Item $data -ItemType Directory -Force | Out-Null
$utf8n = New-Object System.Text.UTF8Encoding($false)
[TrayApp].GetField('BatDir', [Reflection.BindingFlags]'Static,Public').SetValue($null, $tmp)
[TrayApp].GetField('DataDir', [Reflection.BindingFlags]'Static,Public').SetValue($null, $data)
$ss = [TrayApp].GetMethod('SeedSamples', [Reflection.BindingFlags]'Static,NonPublic')
$ss.Invoke($null, [object[]]@()) | Out-Null
T 'seed: tools.txt created' (Test-Path (Join-Path $tmp 'tools.txt'))
T 'seed: plugins\README.txt created' (Test-Path (Join-Path $tmp 'plugins\README.txt'))
T 'seed: plugins\clock.txt created' (Test-Path (Join-Path $tmp 'plugins\clock.txt'))
T 'seed: plugins\calc.txt created' (Test-Path (Join-Path $tmp 'plugins\calc.txt'))
T 'seed: marker written' (Test-Path (Join-Path $data 'provisioned-tray-dll.done'))
$toolsHead = Get-Content (Join-Path $tmp 'tools.txt') -TotalCount 2 -Encoding UTF8
T 'seed: tools.txt is the tray-flavored template (WgTray wording)' (($toolsHead -join ' ') -match 'WgTray')
[IO.File]::WriteAllText((Join-Path $tmp 'tools.txt'), 'CUSTOM CONTENT', $utf8n)
$ss.Invoke($null, [object[]]@()) | Out-Null
T 'seed: never overwrites existing files (idempotent)' ([IO.File]::ReadAllText((Join-Path $tmp 'tools.txt')) -eq 'CUSTOM CONTENT')
Remove-Item $tmp, $data -Recurse -Force -EA SilentlyContinue

# ================= 4. runtime smoke: launch the DLL edition =================
$log = Join-Path $env:TEMP 'WgTray_error.log'
Remove-Item $log -Force -EA SilentlyContinue
try {
    Start-Process -FilePath $batPath | Out-Null
    Start-Sleep -Seconds 6
    $me = $PID
    $ps = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"
    $worker = $ps | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*WgTray.dll*' }
    T 'runtime: DLL-edition worker is running' ($null -ne $worker)
    if (Test-Path $log) {
        $logTxt = Get-Content $log -Raw -Encoding UTF8
        T 'runtime: no FATAL error' (-not $logTxt.Contains('FATAL'))
    } else {
        T 'runtime: no FATAL error' $true
    }
    if ($worker) { $worker | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } }
} catch {
    T 'runtime: DLL-edition worker is running' $false $_.Exception.Message
    T 'runtime: no FATAL error' $false $_.Exception.Message
}

# ================= 4. first-launch launcher shortcut + DLL-embedded icon =================
# deterministic: call EnsureShortcut in a temp folder with a dummy bat
$tmpLnk = Join-Path $env:TEMP ("wgtray-lnk-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item $tmpLnk -ItemType Directory -Force | Out-Null
$lnkFile = Join-Path $tmpLnk 'WgTray.lnk'
$dummyBat = Join-Path $tmpLnk 'WgTray.bat'
[IO.File]::WriteAllText($dummyBat, "@echo off`r`n", (New-Object System.Text.UTF8Encoding($false)))
$es = [TrayApp].GetMethod('EnsureShortcut', [Reflection.BindingFlags]'Static,NonPublic')
$ws = New-Object -ComObject WScript.Shell

# old-format shortcut (targets the .bat) must be upgraded in place
$oldLnk = $ws.CreateShortcut($lnkFile)
$oldLnk.TargetPath = $dummyBat
$oldLnk.Save()
$es.Invoke($null, [object[]]@([string]$tmpLnk, [string]$dummyBat)) | Out-Null
$sc = $ws.CreateShortcut($lnkFile)
T 'first-launch: shortcut targets powershell directly (no bat/cmd)' ($sc.TargetPath -match 'powershell\.exe')
T 'first-launch: old bat-targeted shortcut upgraded in place' ($sc.TargetPath -notlike '*WgTray.bat')
$argsStr = [string]$sc.Arguments
T 'first-launch: arguments load the DLL and run TrayApp' ($argsStr.Contains('Add-Type -Path') -and $argsStr.Contains('[TrayApp]::Run') -and $argsStr.Contains($dummyBat))
T 'first-launch: hidden window (no console flash)' ($argsStr.Contains('-WindowStyle Hidden'))
T 'first-launch: working dir is the bat folder' ($sc.WorkingDirectory -eq $tmpLnk)
T 'first-launch: runs minimized' ($sc.WindowStyle -eq 7)
# icon comes from the DLL itself (build-time injected resource) - no .ico file
T 'first-launch: icon points at the DLL (no .ico file)' ($sc.IconLocation -match 'WgTray\.dll,0$' -and $sc.IconLocation -notmatch '\.ico')
# the DLL carries the embedded icon: blue rounded tile + knocked-out glyph
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
$dllIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($dllPath)
if ($null -ne $dllIcon) {
    $ib = $dllIcon.ToBitmap()
    $tilePx = $ib.GetPixel([int]($ib.Width * 0.12), [int]($ib.Height * 0.5))
    $glyphPx = $ib.GetPixel([int]($ib.Width * 0.5), [int]($ib.Height * 0.5))
    T 'first-launch: DLL has an embedded icon (blue tile)' ($tilePx.B -gt 100)
    T 'first-launch: DLL icon glyph is knocked out' ($glyphPx.A -lt 128)
    $ib.Dispose(); $dllIcon.Dispose()
} else {
    T 'first-launch: DLL has an embedded icon (blue tile)' $false
    T 'first-launch: DLL icon glyph is knocked out' $false
}
# idempotency: second call must not overwrite (target is powershell now -> skip)
$stamp1 = (Get-Item $lnkFile).LastWriteTime
Start-Sleep -Milliseconds 1100
$es.Invoke($null, [object[]]@([string]$tmpLnk, [string]$dummyBat)) | Out-Null
T 'first-launch: second call does not overwrite' ((Get-Item $lnkFile).LastWriteTime -eq $stamp1)
Remove-Item $tmpLnk -Recurse -Force -EA SilentlyContinue

# ================= summary =================
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
