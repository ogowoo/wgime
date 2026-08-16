# End-to-end check against the REAL dictionary files (py.txt/wb.txt/ec.txt + import_*.txt)
# Verifies: streaming ParseDict handles the big tables, InputMd5 matches old cache key,
#           BuildDicts + ApplySwap + lazy CharPy work on real data.
# Run with Windows PowerShell 5.1:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\e2e-real-dict.ps1
# NOTE: no non-ASCII literals in this file (PS 5.1 ANSI script reading).
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\wgime.bat'
if (-not (Test-Path $path)) { throw "wgime.bat not found: $path" }
$txt  = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
$i     = $txt.IndexOf("cs = @'")
$start = $txt.IndexOf("`n", $i) + 1
$end   = $txt.IndexOf("`n'@", $start)
$cs    = $txt.Substring($start, $end - $start)

Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms,System.Drawing,UIAutomationClient,UIAutomationTypes,WindowsBase -ErrorAction Stop
$passed = 0; $failed = 0
function T($name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:passed++; Write-Host "PASS  $name" -ForegroundColor Green }
    else     { $script:failed++; Write-Host "FAIL  $name  $detail" -ForegroundColor Red }
}

# embedded base tables (small) + real dir files
$dir = [string](Split-Path $path -Parent)
$cA  = [string][char]0x554A   # 啊
$cAi = [string][char]0x7231   # 爱
$cZhong = [string][char]0x4E2D # 中
$cGuo   = [string][char]0x56FD # 国
$cPing  = [string][char]0x82F9 # 苹
$cGuo2  = [string][char]0x679C # 果
$cXiang = [string][char]0x9999 # 香
$cJiao  = [string][char]0x8549 # 蕉
$pyText = "a $cA$cAi`nai $cAi`nzhongguo $cZhong$cGuo`n"
$wbText = "a g`naaaa g`n"
$ecText = "apple $cPing$cGuo2`nbanana $cXiang$cJiao`n"
[WordBoard]::SrcPy = $pyText; [WordBoard]::SrcWb = $wbText; [WordBoard]::SrcEc = $ecText

# userwords dir
$DataDir = Join-Path $env:TEMP 'wgime_e2e_test'
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
[WordBoard]::DataDir = $DataDir
$mbPath = Join-Path $DataDir 'wgime.mb'
if (Test-Path $mbPath) { Remove-Item $mbPath -Force }

# BuildDicts with real files (uses SafeRead on the actual py.txt/wb.txt/ec.txt/import_*.txt)
$bd = [WordBoard].GetMethod('BuildDicts', [Reflection.BindingFlags]'Static,NonPublic')
$mb = $bd.Invoke($null, @($dir))
T 'BuildDicts on real dir OK (cache miss build)' ($null -ne $mb)
T 'py dict has zhongguo -> China' ($mb.Py['zhongguo'].Contains($cZhong + $cGuo))
T 'import_py overlaid (abacangzhu present)' ($mb.Py.ContainsKey('abacangzhu'))
T 'import_wb overlaid (aaaa present)' ($mb.Wb.ContainsKey('aaaa'))

# cache hit path: second call should load from .mb (and CharPy stays null = lazy)
[WordBoard]::CharPy = $null
$mb2 = $bd.Invoke($null, @($dir))
T 'BuildDicts cache hit OK' ($null -ne $mb2)
T 'CharPy still null after cache hit (lazy)' ([WordBoard]::CharPy -eq $null)

# ApplySwap -> CharPy lazily built on first word creation
$as = [WordBoard].GetMethod('ApplySwap', [Reflection.BindingFlags]'Static,NonPublic')
$as.Invoke($null, @($mb2))
T 'ApplySwap OK' ([WordBoard]::DictsReady -eq $true)
$cf = [WordBoard].GetMethod('CodeFor', [Reflection.BindingFlags]'Static,NonPublic')
$code = $cf.Invoke($null, @($cZhong + $cGuo))
T 'CodeFor lazy-builds CharPy and returns pinyin' ($code -eq 'zhongguo') ("code=$code")

# InputMd5 must equal the old cache-key algorithm (cache compat)
function SRB($p) {
    if (Test-Path $p) { return ,([byte[]][IO.File]::ReadAllBytes($p)) }
    return ,([byte[]]::new(0))
}
$md5m = [WordBoard].GetMethod('InputMd5', [Reflection.BindingFlags]'Static,NonPublic')
$b_py = SRB (Join-Path $dir 'py.txt'); $b_wb = SRB (Join-Path $dir 'wb.txt'); $b_ec = SRB (Join-Path $dir 'ec.txt')
$b_ip = SRB (Join-Path $dir 'import_py.txt'); $b_iw = SRB (Join-Path $dir 'import_wb.txt'); $b_ie = SRB (Join-Path $dir 'import_ec.txt')
$b_uw = [byte[]]::new(0)
$md5New = $md5m.Invoke($null, @($pyText, $wbText, $ecText, $b_py, $b_wb, $b_ec, $b_ip, $b_iw, $b_ie, $b_uw))
$ms = New-Object System.IO.MemoryStream
foreach ($b in @([Text.Encoding]::UTF8.GetBytes($pyText),[Text.Encoding]::UTF8.GetBytes($wbText),[Text.Encoding]::UTF8.GetBytes($ecText),
    $b_py, $b_wb, $b_ec, $b_ip, $b_iw, $b_ie, $b_uw)) { $ms.Write($b,0,$b.Length); $ms.WriteByte(0) }
$md5Old = [Security.Cryptography.MD5]::Create().ComputeHash($ms.ToArray())
T 'InputMd5 real-data == old algorithm (cache compatible)' ([BitConverter]::ToString($md5New) -eq [BitConverter]::ToString($md5Old))

# cleanup
Remove-Item $DataDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "== $passed passed, $failed failed ==" -ForegroundColor Cyan
if ($failed -gt 0) { exit 1 }
