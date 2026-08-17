# ============================================================
#  tools.tests.ps1  -  tests for the config-driven toolbox (tools.txt):
#   1. ToolToks tokenizer (quotes/whitespace)
#   2. LoadTools parsing (tabs/buttons/steps structure)
#   3. ExecToolStep: mkdir / file-del (+root guard, +locked-file skip) /
#      reg-set / reg-del / unknown verb / shell exit codes; [shellx]/[psx] block parsing
#   4. Apps registry has builtin:tools
#   5. ToolsForm renders (tests\tools-form.png)
#
#  Prereq: rebuild.ps1 has run (%TEMP%\wgime_new.dll is current).
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\tools.tests.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

$dll = Join-Path $env:TEMP 'wgime_new.dll'
if (-not (Test-Path $dll)) { throw "rebuilt DLL not found: $dll (run rebuild.ps1 first)" }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$asm = [Reflection.Assembly]::LoadFile($dll)
$wbType = $asm.GetType('WordBoard')
$fl = [Reflection.BindingFlags] 'Static, Public, NonPublic'

$pass = 0; $fail = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -ceq "$expected") { Write-Output "PASS  $name"; $script:pass++ }
    else { Write-Output "FAIL  $name (expected [$expected], got [$actual])"; $script:fail++ }
}

$toksM  = $wbType.GetMethod('ToolToks', $fl)
$loadT  = $wbType.GetMethod('LoadTools', $fl)
$execM  = $wbType.GetMethod('ExecToolStep', $fl)
$tabsF  = $wbType.GetField('ToolTabs', $fl)
$appsF  = $wbType.GetField('Apps', $fl)
$loadC  = $wbType.GetMethod('LoadConfig', $fl)

function Toks([string]$s) { $r = $toksM.Invoke($null, @($s)); return (, [string[]] $r) }
function Exec([string]$line) {
    $tk = Toks $line
    [string]$rest = ''
    $sp = $line.IndexOf(' '); if ($sp -ge 0) { $rest = $line.Substring($sp + 1).Trim() }
    [System.Text.StringBuilder]$sbb = New-Object System.Text.StringBuilder
    return $execM.Invoke($null, @($tk, $rest, $sbb, $null))
}
function ExecFull([string]$verb, [string]$body) {     # returns @(result, logText)
    [System.Text.StringBuilder]$sbb = New-Object System.Text.StringBuilder
    $r = $execM.Invoke($null, @([string[]]@($verb), $body, $sbb, $null))
    return @($r, $sbb.ToString())
}

# ---- 1) tokenizer ----
Check "toks plain"    ((Toks 'kill Teams') -join '|')            "kill|Teams"
Check "toks quoted"   ((Toks 'run "C:\a b\c.exe" /x') -join '|') "run|C:\a b\c.exe|/x"
Check "toks extra ws" ((Toks '  wait   100 ') -join '|')         "wait|100"

# ---- 2) LoadTools parsing ----
$BANGONG  = [string]([char]0x529E) + [char]0x516C     # 办公
$CHONGZHI = [string]([char]0x91CD) + [char]0x7F6E     # 重置
$XIUFU    = [string]([char]0x4FEE) + [char]0x590D     # 修复
$XITONG   = [string]([char]0x7CFB) + [char]0x7EDF     # 系统
$DAKAI    = [string]([char]0x6253) + [char]0x5F00     # 打开
$MULU     = [string]([char]0x76EE) + [char]0x5F55     # 目录
$tmp = [string](Join-Path $env:TEMP ('wgime-tools-test-' + [guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tmp | Out-Null
$sample = @"
; comment
[tab $BANGONG]
[$CHONGZHI Teams]
confirm sure?
kill Teams
file-del %LOCALAPPDATA%\X
[$XIUFU Outlook]
shell outlook.exe /resetnavpane
[tab $XITONG]
[$DAKAI$MULU]
open %WINDIR%
"@
[IO.File]::WriteAllText((Join-Path $tmp 'tools.txt'), $sample, (New-Object System.Text.UTF8Encoding($false)))
$loadT.Invoke($null, @($tmp))
$tabs = $tabsF.GetValue($null)
function TabName($t)  { return $t.GetType().GetField('Name', 'Instance, Public, NonPublic').GetValue($t) }
function TabActs($t)  { $v = $t.GetType().GetField('Actions', 'Instance, Public, NonPublic').GetValue($t); return (, $v) }   # (, ) stops PS unrolling
function ActSteps($a) { $v = $a.GetType().GetField('Steps', 'Instance, Public, NonPublic').GetValue($a); return (, $v) }
Check "tab count"        ($tabs.Count)                         "2"
Check "tab1 name"        (TabName $tabs[0])                    $BANGONG
$acts1 = TabActs $tabs[0]
$acts2 = TabActs $tabs[1]
$b1 = $acts1[0]
$b2 = $acts1[1]
Check "tab1 buttons"     ($acts1.Count)            "2"
Check "btn1 name"        (TabName $b1)             "$CHONGZHI Teams"
Check "btn1 steps"       ((ActSteps $b1).Count)    "3"
Check "btn2 steps"       ((ActSteps $b2).Count)    "1"
Check "tab2 buttons"     ($acts2.Count)            "1"
Remove-Item (Join-Path $tmp 'tools.txt') -Force

# ---- 2b) multi-line script blocks ----
$sample2 = @"
[tab T]
[B1]
[shell]
echo a
echo b
[/shell]
[powershell]
Write-Output 1
[/powershell]
"@
[IO.File]::WriteAllText((Join-Path $tmp 'tools.txt'), $sample2, (New-Object System.Text.UTF8Encoding($false)))
$loadT.Invoke($null, @($tmp))
$tabsB = $tabsF.GetValue($null)
$bb = (TabActs $tabsB[0])[0]
$bs = ActSteps $bb
$rawF2 = $bb.GetType().GetField('Raw', 'Instance, Public, NonPublic')
$braw = $rawF2.GetValue($bb)
Check "block: step count"    ($bs.Count)                 "2"
Check "block: verb 1"        ($bs[0][0])                 "shellblock"
Check "block: verb 2"        ($bs[1][0])                 "psblock"
Check "block: raw content"   ($braw[0] -replace "`r", "") "echo a`necho b"
Remove-Item (Join-Path $tmp 'tools.txt') -Force

# ---- 2c) interactive console blocks ([shellx]/[psx] parse, never auto-run) ----
$sample3 = @"
[tab T]
[B1]
[shellx]
echo hi
[/shellx]
[psx]
Read-Host x
[/psx]
"@
[IO.File]::WriteAllText((Join-Path $tmp 'tools.txt'), $sample3, (New-Object System.Text.UTF8Encoding($false)))
$loadT.Invoke($null, @($tmp))
$tabsX = $tabsF.GetValue($null)
$bx = ActSteps ((TabActs $tabsX[0])[0])
Check "blockx: step count"  ($bx.Count)       "2"
Check "blockx: verb 1"      ($bx[0][0])       "shellblockx"
Check "blockx: verb 2"      ($bx[1][0])       "psblockx"
Check "RunVisible exists"   ($wbType.GetMethod('RunVisible', $fl) -ne $null)  "True"
Remove-Item (Join-Path $tmp 'tools.txt') -Force

# ---- 3) ExecToolStep ----
$dir = Join-Path $tmp 'sub dir'
Check "mkdir"          (Exec ('mkdir "' + $dir + '"'))                ""        # null -> $null -> ""
Check "mkdir exists"   (Test-Path $dir)                               "True"
Check "file-del dir"   (Exec ('file-del "' + $dir + '"'))             ""
Check "dir gone"       (Test-Path $dir)                               "False"
Check "root guard"     ((Exec 'file-del C:\') -ne $null)              "True"
Check "unknown verb"   ((Exec 'frobnicate x') -match 'unknown verb')  "True"
Check "wait ok"        (Exec 'wait 1')                                ""
Check "shell ok"       (Exec 'shell echo wgimetest')                  ""
Check "shell exit 3"   ((Exec 'shell exit 3') -match 'exit code 3')   "True"

# file-del wildcard: a locked/in-use file must be skipped, not abort the rest
$delDir = Join-Path $tmp 'deltest'
New-Item -ItemType Directory -Path $delDir | Out-Null
$fA = Join-Path $delDir 'a.txt'; $fB = Join-Path $delDir 'b.txt'; $fC = Join-Path $delDir 'c.txt'
[IO.File]::WriteAllText($fA, 'a'); [IO.File]::WriteAllText($fB, 'b'); [IO.File]::WriteAllText($fC, 'c')
$lock = [IO.File]::Open($fB, 'Open', 'ReadWrite', 'None')
$tkDel = Toks ('file-del "' + $delDir + '\*"')
$restDel = '"' + $delDir + '\*"'                              # must be pre-computed: inline "a"+$x+"b" inside @() binds looser than ','
[System.Text.StringBuilder]$sbDel = New-Object System.Text.StringBuilder
$rDel = $execM.Invoke($null, @($tkDel, $restDel, $sbDel, $null))
$lock.Close(); $lock.Dispose()
Check "file-del locked: step ok"  ("$rDel")                                ""
Check "file-del locked: a gone"   (Test-Path $fA)                          "False"
Check "file-del locked: c gone"   (Test-Path $fC)                          "False"
Check "file-del locked: b kept"   (Test-Path $fB)                          "True"
Check "file-del locked: log"      ($sbDel.ToString() -match 'skipped 1')   "True"
Remove-Item $delDir -Recurse -Force

# multi-line script blocks execute
$ZW = [string]([char]0x4E2D) + [char]0x6587     # 中文
$rp = ExecFull 'psblock' "Write-Output 'wgime-ps-ok'"
Check "psblock runs"        ($rp[0])                                  ""
Check "psblock output"      ($rp[1] -match 'wgime-ps-ok')             "True"
$rp2 = ExecFull 'psblock' ("Write-Output '" + $ZW + "-ok'")
Check "psblock CJK output"  ($rp2[1] -match ($ZW + '-ok'))            "True"
$rp3 = ExecFull 'shellblock' "@echo off`necho wgime-cmd-ok"
Check "shellblock runs"     ($rp3[0])                                 ""
Check "shellblock output"   ($rp3[1] -match 'wgime-cmd-ok')           "True"

$rk = 'HKCU\Software\WgImeToolTest'
Check "reg-set dword"  (Exec "reg-set $rk TestVal dword 42")          ""
$got = [Microsoft.Win32.Registry]::GetValue("HKEY_CURRENT_USER\Software\WgImeToolTest", "TestVal", $null)
Check "reg readback"   ($got)                                         "42"
Check "reg-set string" (Exec "reg-set $rk Note string hello world")   ""
Check "reg-del value"  (Exec "reg-del $rk TestVal")                   ""
$got2 = [Microsoft.Win32.Registry]::GetValue("HKEY_CURRENT_USER\Software\WgImeToolTest", "TestVal", "missing")
Check "value gone"     ($got2)                                        "missing"
Check "reg-del key"    (Exec "reg-del $rk")                           ""
$gone = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\WgImeToolTest') -eq $null
Check "key gone"       ($gone)                                        "True"
Remove-Item $tmp -Recurse -Force

# ---- 4) builtin:tools registered ----
$tmp2 = [string](Join-Path $env:TEMP ('wgime-tools-test2-' + [guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tmp2 | Out-Null
$loadC.Invoke($null, @($tmp2))     # no config.txt -> defaults incl. builtins
$apps = $appsF.GetValue($null)
Check "itools registered" ($apps.ContainsKey('itools') -and $apps['itools'][1] -eq 'builtin:tools') "True"
Check "tools registered"  ($apps.ContainsKey('tools')  -and $apps['tools'][1]  -eq 'builtin:tools') "True"
Remove-Item $tmp2 -Recurse -Force

# ---- 5) ToolsForm renders with the real repo tools.txt ----
$loadT.Invoke($null, @('C:\Tools\WgIme'))
$tabsReal = $tabsF.GetValue($null)
$toolsType = $wbType.GetNestedType('ToolsForm', 'NonPublic')
$ctor = $toolsType.GetConstructors([Reflection.BindingFlags]'Instance, Public, NonPublic')[0]
[System.Collections.IList]$tabsI = $tabsReal            # typed scalar assignment: no pipeline enumeration, PSObject auto-unwrapped
$argsArr = New-Object 'object[]' 1
$argsArr[0] = $tabsI
$form = $ctor.Invoke($argsArr)
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
$bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
$form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
$png = Join-Path $PSScriptRoot 'tools-form.png'
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$form.Close()
Check "tools form rendered" (Test-Path $png) "True"
Write-Output "tools form screenshot: $png"

Write-Output ""
Write-Output "== $pass passed, $fail failed =="
if ($fail -gt 0) { exit 1 }
