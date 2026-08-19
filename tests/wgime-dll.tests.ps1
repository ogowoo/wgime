# ============================================================
#  wgime-dll.tests.ps1 - regression tests for the wgime DLL
#  edition (wgime-dll\WgIme.bat + WgIme.dll: thin launcher +
#  full IME assembly with the base dictionaries embedded)
#
#  Run with Windows PowerShell 5.1:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime-dll.tests.ps1
#
#  NOTE: ASCII-only file - Windows PS 5.1 reads scripts as ANSI.
# ============================================================
$ErrorActionPreference = 'Stop'
$dllDir = Join-Path $PSScriptRoot '..\wg-all'
$batPath = Join-Path $dllDir 'WgIme.bat'
$dllPath = Join-Path $dllDir 'WgIme.dll'
$script:passed = 0; $script:failed = 0
function T($name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:passed++; Write-Host "PASS  $name" -ForegroundColor Green }
    else     { $script:failed++; Write-Host "FAIL  $name  $detail" -ForegroundColor Red }
}

# ================= 1. thin launcher (no suspicious patterns) =================
if (-not (Test-Path $batPath)) { throw "wgime-dll\WgIme.bat not found - run build-wgime-dll.ps1 first" }
$batTxt = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)
T 'launcher starts with @echo off' ($batTxt.StartsWith('@echo off'))
T 'launcher loads the DLL via Add-Type -Path' ($batTxt.Contains('Add-Type -Path'))
T 'launcher runs WgImeLauncher' ($batTxt.Contains('[WgImeLauncher]::Run'))
T 'launcher has no Invoke-Expression' (-not $batTxt.Contains('Invoke-Expression'))
T 'launcher has no FromBase64String' (-not $batTxt.Contains('FromBase64String'))
T 'launcher has no runtime compile' (-not $batTxt.Contains('Add-Type -TypeDefinition'))
T 'launcher has no -ExecutionPolicy Bypass' (-not $batTxt.Contains('ExecutionPolicy'))
T 'launcher has no PS self-extract marker' (-not $batTxt.Contains('###PWSHTRAY###'))
$bytes = [IO.File]::ReadAllBytes($batPath)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
T 'launcher has no BOM' (-not $bom)
$loneLf = 0
for ($k = 0; $k -lt $bytes.Length; $k++) { if ($bytes[$k] -eq 0x0A -and ($k -eq 0 -or $bytes[$k-1] -ne 0x0D)) { $loneLf++ } }
T 'launcher is pure CRLF (cmd.exe requirement)' ($loneLf -eq 0)

# ================= 2. precompiled DLL =================
if (-not (Test-Path $dllPath)) { throw "wgime-dll\WgIme.dll not found - run build-wgime-dll.ps1 first" }
$dllBytes = [IO.File]::ReadAllBytes($dllPath)
T 'DLL is a valid PE (MZ header)' ($dllBytes.Length -ge 2 -and $dllBytes[0] -eq 0x4D -and $dllBytes[1] -eq 0x5A)
Add-Type -Path $dllPath -ErrorAction Stop
$runAppCount = @([WordBoard].GetMethods([Reflection.BindingFlags]'Static,Public') | Where-Object { $_.Name -eq 'RunApp' }).Count
T 'DLL exposes the full IME (WordBoard + RunApp)' ($null -ne [WordBoard] -and $runAppCount -ge 2)
T 'DLL exposes the launcher (WgImeLauncher)' ($null -ne [WgImeLauncher])
# this IS the IME: the keyboard hook must be present (opposite of the tray editions)
T 'DLL contains the IME keyboard hook (KeyBordHook)' ($null -ne [KeyBordHook])
# embedded base dictionaries: const fields (need the NonPublic flag combo - PS binding quirk)
$asm = [KeyBordHook].Assembly
$lt = $asm.GetType('WgImeLauncher')
$bf = [Reflection.BindingFlags]'Public,NonPublic,Static,Instance,DeclaredOnly'
$exp = @{ PyData = 30000; WbData = 100000; EcData = 500; PyWords = 400000; PyWf = 300000 }
$allOk = $true
foreach ($k in $exp.Keys) {
    $fi = $lt.GetField($k, $bf)
    if ($fi -and $fi.GetRawConstantValue().Length -ge $exp[$k]) {
        T ("embedded dict {0} present ({1} chars)" -f $k, $fi.GetRawConstantValue().Length) $true
    } else {
        T ("embedded dict {0} present" -f $k) $false "missing or too small"
        $allOk = $false
    }
}
# launcher calls the ORIGINAL RunApp with the embedded dicts
$runBody = $null
$rm = $lt.GetMethod('Run', $bf)
if ($rm) { $runBody = [System.IO.File]::ReadAllText($dllPath, [Text.Encoding]::UTF8) }
T 'launcher entry present' ($null -ne $rm)

# ================= 2b. full extension tables in the trailer (no txt files needed) =================
$dllText = [System.IO.File]::ReadAllText($dllPath, [Text.Encoding]::ASCII)
T 'trailer: full tables appended to the DLL' ($dllText.Contains('###WGIME_DICT###') -and $dllText.Contains('###WGIME_DICT_END###'))
$ex = [WgImeLauncher].GetMethod('ExtractDicts', [Reflection.BindingFlags]'Static,NonPublic')
$ea = [object[]]@([string]'', [string]'', [string]'', [string]'', [string]'')
$ex.Invoke($null, $ea) | Out-Null
T 'trailer: merged pinyin table loaded' ($ea[0].Length -gt 1000000) ("py=$($ea[0].Length)")
T 'trailer: merged wubi table loaded' ($ea[1].Length -gt 1000000) ("wb=$($ea[1].Length)")
T 'trailer: merged EN-CN table loaded' ($ea[2].Length -gt 1000000) ("ec=$($ea[2].Length)")
T 'trailer: pyWords merged into py (pw empty)' ($ea[3].Length -eq 0)
T 'trailer: pack-safe flag set (single words not split)' ([WordBoard]::EmbeddedMerged)

# ================= 3. runtime smoke: launch the DLL edition (full IME) =================
$log = Join-Path $env:TEMP 'WgIme_error.log'
$mbErr = Join-Path $env:LOCALAPPDATA 'wgime\mb_error.log'
$mbCache = Join-Path $env:LOCALAPPDATA 'wgime\wgime.mb'
Remove-Item $log, $mbErr, $mbCache -Force -EA SilentlyContinue   # force a genuine rebuild from the trailer
try {
    Start-Process -FilePath $batPath | Out-Null
    Start-Sleep -Seconds 35
    $me = $PID
    $ps = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"
    $worker = $ps | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*WgIme.dll*' }
    T 'runtime: IME worker is running' ($null -ne $worker)
    T 'runtime: no startup error log' (-not (Test-Path $log))
    T 'runtime: dictionary build OK (no mb_error.log)' (-not (Test-Path $mbErr))
    $mb = Get-Item (Join-Path $env:LOCALAPPDATA 'wgime\wgime.mb') -ErrorAction SilentlyContinue
    T 'runtime: dict cache present (embedded dicts parsed)' ($null -ne $mb -and $mb.Length -gt 100000)
    # the full merged cache (~39MB, not the 1.4MB base-only) proves the trailer tables
    # loaded AND the pack-safe flag worked (single words intact)
    T 'runtime: FULL merged cache built (trailer tables, not base-only)' ($null -ne $mb -and $mb.Length -gt 30MB)
    if ($worker) { $worker | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } }
} catch {
    T 'runtime: IME worker is running' $false $_.Exception.Message
    T 'runtime: no startup error log' $false $_.Exception.Message
    T 'runtime: dictionary build OK (no mb_error.log)' $false $_.Exception.Message
    T 'runtime: dict cache present (embedded dicts parsed)' $false $_.Exception.Message
    T 'runtime: FULL merged cache built (trailer tables, not base-only)' $false $_.Exception.Message
}

# ================= 4. first-launch launcher shortcut =================
# deterministic: call EnsureShortcut in a temp folder with a dummy bat
$tmpLnk = Join-Path $env:TEMP ("wgime-lnk-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item $tmpLnk -ItemType Directory -Force | Out-Null
$lnkFile = Join-Path $tmpLnk 'WgIme.lnk'
$dummyBat = Join-Path $tmpLnk 'WgIme.bat'
[IO.File]::WriteAllText($dummyBat, "@echo off`r`n", (New-Object System.Text.UTF8Encoding($false)))
$es = [WgImeLauncher].GetMethod('EnsureShortcut', [Reflection.BindingFlags]'Static,NonPublic')
$ws = New-Object -ComObject WScript.Shell

# old-format shortcut (targets the .bat) must be upgraded in place
$oldLnk = $ws.CreateShortcut($lnkFile)
$oldLnk.TargetPath = $dummyBat
$oldLnk.Save()
$es.Invoke($null, [object[]]@([string]$tmpLnk, [string]$dummyBat)) | Out-Null
$sc = $ws.CreateShortcut($lnkFile)
T 'first-launch: shortcut targets powershell directly (no bat/cmd)' ($sc.TargetPath -match 'powershell\.exe')
T 'first-launch: old bat-targeted shortcut upgraded in place' ($sc.TargetPath -notlike '*WgIme.bat')
$argsStr = [string]$sc.Arguments
T 'first-launch: arguments load the DLL and run the launcher' ($argsStr.Contains('Add-Type -Path') -and $argsStr.Contains('[WgImeLauncher]::Run') -and $argsStr.Contains($dummyBat))
T 'first-launch: hidden window (no console flash)' ($argsStr.Contains('-WindowStyle Hidden'))
T 'first-launch: working dir is the bat folder' ($sc.WorkingDirectory -eq $tmpLnk)
T 'first-launch: runs minimized' ($sc.WindowStyle -eq 7)
# icon comes from the DLL itself (build-time injected resource) - no .ico file
T 'first-launch: icon points at the DLL (no .ico file)' ($sc.IconLocation -match 'WgIme\.dll,0$' -and $sc.IconLocation -notmatch '\.ico')
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
