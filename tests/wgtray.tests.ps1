# ============================================================
#  wgtray.tests.ps1 - regression tests for wgtray.bat
#  (tray-only toolbox: no IME, tray menu + tools.txt toolbox +
#   plugins\*.txt + config.txt apps)
#
#  Run with Windows PowerShell 5.1:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray.tests.ps1
#
#  NOTE: ASCII-only file - Windows PS 5.1 reads scripts as ANSI;
#  do not add non-ASCII literals (use [char] codepoints if needed).
# ============================================================
$ErrorActionPreference = 'Stop'
$batPath = Join-Path $PSScriptRoot '..\wgtray.bat'
if (-not (Test-Path $batPath)) { throw "wgtray.bat not found - run build-wgtray.ps1 first: $batPath" }
$txt = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)
$script:passed = 0; $script:failed = 0
function T($name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:passed++; Write-Host "PASS  $name" -ForegroundColor Green }
    else     { $script:failed++; Write-Host "FAIL  $name  $detail" -ForegroundColor Red }
}

# ================= 1. file structure constraints =================
T 'starts with @echo off' ($txt.StartsWith('@echo off'))
T 'has cmd marker ###PWSHTRAY###' ($txt.Contains('###PWSHTRAY###'))
T 'has payload marker ###WGTRAY_DLL###' ($txt.Contains('###WGTRAY_DLL###'))
T 'has TrayApp launch call' ($txt.Contains('[TrayApp]::Run'))
$bytes = [IO.File]::ReadAllBytes($batPath)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
T 'no BOM' (-not $bom)
$loneLf = 0
for ($k = 0; $k -lt $bytes.Length; $k++) { if ($bytes[$k] -eq 0x0A -and ($k -eq 0 -or $bytes[$k-1] -ne 0x0D)) { $loneLf++ } }
T 'pure CRLF line endings (cmd.exe requirement)' ($loneLf -eq 0)
$lines = [regex]::Split($txt, "\r\n")
$mi = [Array]::IndexOf($lines, '###WGTRAY_DLL###')
T 'payload marker is 3rd from last' ($mi -eq ($lines.Count - 3))

# ================= 2. no-IME guarantee (code-level) =================
$ci = $txt.IndexOf("cs = @'")
if ($ci -lt 0) { throw "embedded C# marker 'cs = @''' not found" }
$csStart = $txt.IndexOf("`n", $ci) + 1
$csEnd = $txt.IndexOf("`n'@", $csStart)
$cs = $txt.Substring($csStart, $csEnd - $csStart)
T 'no KeyBordHook class (no keyboard hook)' (-not $cs.Contains('class KeyBordHook'))
T 'no WH_KEYBOARD_LL hook' (-not $cs.Contains('WH_KEYBOARD_LL'))
T 'no candidate-window WordBoard form' (-not $cs.Contains('class WordBoard'))
T 'no dictionary tables in bat (no IME data)' (-not $txt.Contains('pyData: 427 lines') -and -not $txt.Contains('$wbData = @'))
T 'no wgime DLL payload marker' (-not $txt.Contains('###WGIME_DLL###'))
T 'has TrayApp class' ($cs.Contains('public class TrayApp'))
T 'has tray Run entry point' ($cs.Contains('public static void Run(string dir, string batPath)'))
T 'has plugin loader' ($cs.Contains('static void LoadPlugins'))
T 'has toolbox loader (tools.txt)' ($cs.Contains('static void LoadTools'))

# ================= 3. embedded C# compiles =================
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms,System.Drawing -ErrorAction Stop
T 'embedded C# compiles (Add-Type)' $true

# ================= 4. toolbox parsing (tools.txt) =================
$td = Join-Path $env:TEMP ("wgtray-tools-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item $td -ItemType Directory -Force | Out-Null
$utf8n = New-Object System.Text.UTF8Encoding($false)
$toolsContent = "[tab TabA]`r`n[cols 3]`r`n[btn one]`r`nmsg hello`r`n[tab TabB]`r`n[btn two]`r`nwait 10`r`n[ps]`r`nWrite-Output 1`r`n[/ps]`r`n"
[IO.File]::WriteAllText((Join-Path $td 'tools.txt'), $toolsContent, $utf8n)
$lt = [TrayApp].GetMethod('LoadTools', [Reflection.BindingFlags]'Static,NonPublic')
$lt.Invoke($null, [object[]]@([string]$td)) | Out-Null
$tabs = [TrayApp].GetField('ToolTabs', [Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
T 'tools.txt: 2 tabs parsed' ($tabs.Count -eq 2)
$colsF = $tabs[0].GetType().GetField('Cols', [Reflection.BindingFlags]'Instance,NonPublic')
T 'tools.txt: [cols 3] honored' ($colsF.GetValue($tabs[0]) -eq 3)
$actsF = $tabs[0].GetType().GetField('Actions', [Reflection.BindingFlags]'Instance,NonPublic')
T 'tools.txt: tab has 1 action' ($actsF.GetValue($tabs[0]).Count -eq 1)
$tabB = $tabs[1].GetType().GetField('Actions', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($tabs[1])
$steps = $tabB[0].GetType().GetField('Steps', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($tabB[0])
T 'tools.txt: ps block parsed as a step' ($steps.Count -eq 2 -and $steps[1][0] -eq 'psblock')

# ================= 5. apps + plugins (config.txt + plugins\*.txt) =================
$pd = Join-Path $env:TEMP ("wgtray-apps-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$pdir = Join-Path $pd 'plugins'
New-Item $pdir -ItemType Directory -Force | Out-Null
$cfg = "fuzzy = zh-z`r`napp = np`tnotepad`tnotepad.exe`r`napp = bd`tbaidu`thttps://www.baidu.com`r`nstarton = 0`r`n"
[IO.File]::WriteAllText((Join-Path $pd 'config.txt'), $cfg, $utf8n)
[IO.File]::WriteAllText((Join-Path $pdir 'test-dsl.txt'), "code = testplug`r`nname = TestPlugin`r`nmsg hi`r`n", $utf8n)
[IO.File]::WriteAllText((Join-Path $pdir 'test-cs.txt'), "code = csplug`r`nname = CsPlugin`r`n[csharp]`r`nusing System;`r`npublic class P { public static void Run() { } }`r`n[/csharp]`r`n", $utf8n)
$dataDir = Join-Path $env:TEMP ("wgtray-data-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item $dataDir -ItemType Directory -Force | Out-Null
[TrayApp].GetField('DataDir', [Reflection.BindingFlags]'Static,Public').SetValue($null, $dataDir)
$lc = [TrayApp].GetMethod('LoadConfig', [Reflection.BindingFlags]'Static,NonPublic')
$lc.Invoke($null, [object[]]@([string]$pd)) | Out-Null
$apps = [TrayApp].GetField('Apps', [Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
T 'builtin apps registered (itools/net/clip/bj/ys/plugins)' (
    $apps.ContainsKey('itools') -and $apps.ContainsKey('net') -and $apps.ContainsKey('clip') -and
    $apps.ContainsKey('bj') -and $apps.ContainsKey('ys') -and $apps.ContainsKey('plugins'))
T 'config.txt app= entry registered' ($apps.ContainsKey('np') -and $apps['np'][1] -eq 'notepad.exe' -and $apps['np'][0] -eq 'notepad')
T 'config.txt space-separated app entry works' ($apps.ContainsKey('bd') -and $apps['bd'][1] -eq 'https://www.baidu.com')
T 'DSL plugin registered (plugins\*.txt)' ($apps.ContainsKey('testplug') -and $apps['testplug'][1].StartsWith('plugin:'))
T 'C# plugin registered ([csharp] block)' ($apps.ContainsKey('csplug') -and $apps['csplug'][1].StartsWith('codeplugin:'))
T 'IME-only config keys ignored without crash (fuzzy/starton)' $true

# ================= 6. tool step engine =================
$ex = [TrayApp].GetMethod('ExecToolStep', [Reflection.BindingFlags]'Static,NonPublic')
$sb = New-Object System.Text.StringBuilder
$mkd = Join-Path $env:TEMP ("wgtray-mk-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$r = $ex.Invoke($null, [object[]]@([string[]]@('mkdir', $mkd), [string]$mkd, [System.Text.StringBuilder]$sb, $null))
T 'exec mkdir creates the folder' ($r -eq $null -and (Test-Path $mkd))
if (Test-Path $mkd) { Remove-Item $mkd -Force -EA SilentlyContinue }
$r2 = $ex.Invoke($null, [object[]]@([string[]]@('wait', '5'), [string]'wait 5', [System.Text.StringBuilder]$sb, $null))
T 'exec wait returns null (ok)' ($r2 -eq $null)
$r3 = $ex.Invoke($null, [object[]]@([string[]]@('nosuchverb'), [string]'nosuchverb x', [System.Text.StringBuilder]$sb, $null))
T 'exec unknown verb reports an error' ($null -ne $r3)

# ================= 7. net tools statics (kept from wgime) =================
$sc = [TrayApp].GetMethod('SubnetCalc', [Reflection.BindingFlags]'Static,NonPublic')
$res = $sc.Invoke($null, [object[]]@([string]'192.168.1.10', [string]'24'))
$resTxt = [string]::Join(' ', [string[]]$res)
T 'SubnetCalc network address' ($resTxt.Contains('192.168.1.0'))
T 'SubnetCalc flags private RFC1918' ($resTxt.Contains('private'))
$ipType = [TrayApp].GetMethod('IpType', [Reflection.BindingFlags]'Static,NonPublic')
T 'IpType loopback' (([string]$ipType.Invoke($null, [object[]]@([uint32]2130706433))).Contains('loopback'))   # 127.0.0.1

# ================= 8. plugin CodeDom compile =================
$cp = [TrayApp].GetMethod('CompilePlugin', [Reflection.BindingFlags]'Static,NonPublic')
$pc = $cp.Invoke($null, [object[]]@([string]"using System;`r`npublic class T { public static void Run() { } }`r`n"))
$errF = $pc.GetType().GetField('Error', [Reflection.BindingFlags]'Instance,NonPublic')
$entryF = $pc.GetType().GetField('Entry', [Reflection.BindingFlags]'Instance,NonPublic')
T 'C# plugin compiles and finds Run()' ($errF.GetValue($pc) -eq $null -and $null -ne $entryF.GetValue($pc))
$pc2 = $cp.Invoke($null, [object[]]@([string]'broken syntax ###'))
T 'C# plugin compile error surfaces' ($null -ne $errF.GetValue($pc2))

# ================= 9. runtime smoke: launch the bat =================
$log = Join-Path $env:TEMP 'WgTray_error.log'
Remove-Item $log -Force -EA SilentlyContinue
try {
    Start-Process -FilePath $batPath | Out-Null
    Start-Sleep -Seconds 7
    $logOk = Test-Path $log
    T 'runtime: error log created' $logOk
    if ($logOk) {
        $logTxt = Get-Content $log -Raw -Encoding UTF8
        T 'runtime: TrayApp launched' ($logTxt.Contains('launching TrayApp'))
        T 'runtime: no FATAL error' (-not $logTxt.Contains('FATAL'))
        $dllLoaded = $logTxt.Contains('prebuilt DLL loaded') -or $logTxt.Contains('compiled OK')
        T 'runtime: code loaded (DLL payload or in-memory compile)' $dllLoaded
    }
    # clean up: kill the worker (powershell running the extracted PS section)
    try {
        $ps = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"
        $worker = $ps | Where-Object { $_.CommandLine -like '*WGTRAY_PATH*' }
        if ($worker) {
            $worker | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
            T 'runtime: worker process found and stopped' $true
        } else {
            T 'runtime: worker process found and stopped' $false
        }
    } catch {
        Write-Host "  (worker lookup skipped: $($_.Exception.Message))" -ForegroundColor DarkGray
    }
} catch {
    T 'runtime: launch' $false $_.Exception.Message
}

# ================= summary =================
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
