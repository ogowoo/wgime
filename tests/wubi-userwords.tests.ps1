# ============================================================
#  wubi-userwords.tests.ps1  -  dual-registration of user words
#  (pinyin + wubi):
#   1. BuildCharWb: longest full code wins, 1-letter short codes skipped
#   2. WubiCodeFor: 86 word rules (2/3/4+ chars), missing char -> null
#   3. MergeUserWordsWb: user words land in the wb dict at startup
#   4. AddUserWord: word injected into BOTH PyDict and WbDict,
#      userwords.txt keeps the pinyin code only
#
#  Pure ASCII source (PS 5.1 reads scripts as ANSI).
#  Prereq: rebuild.ps1 has run (%TEMP%\wgime_new.dll is current).
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wubi-userwords.tests.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

$dll = Join-Path $env:TEMP 'wgime_new.dll'
if (-not (Test-Path $dll)) { throw "rebuilt DLL not found: $dll (run rebuild.ps1 first)" }

$asm = [Reflection.Assembly]::LoadFile($dll)
$wbType = $asm.GetType('WordBoard')
$fl = [Reflection.BindingFlags] 'Static, Public, NonPublic'
$fln = [Reflection.BindingFlags] 'Instance, Public, NonPublic'

$pass = 0; $fail = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -ceq "$expected") { Write-Output "PASS  $name"; $script:pass++ }
    else { Write-Output "FAIL  $name (expected [$expected], got [$actual])"; $script:fail++ }
}

# chars via codepoints
$NI  = [string][char]0x4F60   # ni
$HAO = [string][char]0x597D   # hao
$MEN = [string][char]0x4EEC   # men
$ZI  = [string][char]0x5B50   # zi
$WO  = [string][char]0x6211   # wo
$YI  = [string][char]0x4E00   # yi
$YA  = [string][char]0x5440   # ya
$ZHONG = [string][char]0x4E2D # zhong

$buildM = $wbType.GetMethod('BuildCharWb', $fl)
$wcf2 = $wbType.GetMethods($fl) | Where-Object { $_.Name -eq 'WubiCodeFor' -and $_.GetParameters().Length -eq 2 } | Select-Object -First 1
$mergeM = $wbType.GetMethod('MergeUserWordsWb', $fl)
$addM   = $wbType.GetMethod('AddUserWord', $fl)

# ---- 1) BuildCharWb ----
[System.Collections.Generic.Dictionary[string,string]]$wbSyn = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$wbSyn['wqiy'] = $NI; $wbSyn['wq'] = $NI            # full + short code
$wbSyn['vbg']  = $HAO; $wbSyn['vb'] = $HAO
$wbSyn['bbbb'] = $ZI; $wbSyn['bb'] = $ZI
$wbSyn['trnt'] = $WO
$wbSyn['wun']  = $MEN; $wbSyn['wu'] = $MEN
$wbSyn['g']    = $YI                                 # 1-letter short code only
$wbSyn['ggll'] = $YI
$wbSyn['khk']  = $ZHONG
$wbSyn['kaht'] = $YA
$charWb = $buildM.Invoke($null, @($wbSyn))

function CW($ch) { return $charWb[[char]$ch] }
Check "ni -> wqiy (longest)"   (CW $NI)      "wqiy"
Check "hao -> vbg (3-letter)"  (CW $HAO)     "vbg"
Check "zi -> bbbb"             (CW $ZI)      "bbbb"
Check "yi: 1-letter skipped"   (CW $YI)      "ggll"
Check "zhong -> khk"           (CW $ZHONG)   "khk"

# ---- 2) WubiCodeFor 86 rules ----
function WCF([string]$w) { return $wcf2.Invoke($null, @($w, $charWb)) }
Check "2-char rule"    (WCF ($NI + $HAO))                "wqvb"
Check "2-char rule 2"  (WCF ($NI + $MEN))                "wqwu"
Check "3-char rule"    (WCF ($NI + $MEN + $HAO))         "wwvb"
Check "4-char rule"    (WCF ($WO + $MEN + $NI + $MEN))   "twww"
Check "missing char"   (WCF ($NI + 'X'))                 ""

# ---- 3) MergeUserWordsWb ----
$uwF = $wbType.GetField('UserWords', $fl)
[System.Collections.Generic.Dictionary[string,string]]$uw = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$uw[$NI + $HAO] = 'nihao'
$uwF.SetValue($null, $uw)
[System.Collections.Generic.Dictionary[string,string]]$wb2 = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$wb2['wqiy'] = $NI; $wb2['vbg'] = $HAO
$cw2 = $buildM.Invoke($null, @($wb2))
$mergeM.Invoke($null, @($wb2, $cw2))
Check "merge adds wqvb"        ($wb2.ContainsKey('wqvb'))                    "True"
Check "merge content"          ($wb2['wqvb'])                                ($NI + $HAO)

# merge again = idempotent (no duplicate)
$mergeM.Invoke($null, @($wb2, $cw2))
Check "merge idempotent"       ($wb2['wqvb'])                                ($NI + $HAO)

# ---- 4) AddUserWord dual registration ----
$tmp = [string](Join-Path $env:TEMP ('wgime-wbuw-' + [guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tmp | Out-Null
$setS = {
    param($name, $val)
    $wbType.GetField($name, $fl).SetValue($null, $val)
}
[System.Collections.Generic.Dictionary[string,string]]$pySyn = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$pySyn['ni'] = $NI; $pySyn['hao'] = $HAO; $pySyn['ya'] = $YA
& $setS 'PyDict' $pySyn
[System.Collections.Generic.Dictionary[string,string]]$wbSyn2 = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$wbSyn2['wqiy'] = $NI; $wbSyn2['vbg'] = $HAO; $wbSyn2['kaht'] = $YA
& $setS 'WbDict' $wbSyn2
[System.Collections.Generic.Dictionary[string,string]]$uw2 = New-Object 'System.Collections.Generic.Dictionary[string,string]'
& $setS 'UserWords' $uw2
[System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]]$acro = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]'
& $setS 'Acro' $acro
& $setS 'CharPy' $null
& $setS 'CharWb' $null
& $setS 'DataDir' $tmp
$wbType.GetField('DictsReady', $fl).SetValue($null, $true)

$word = $NI + $HAO + $YA
$added = $addM.Invoke($null, @($word, 'nihaoya'))
Check "AddUserWord ok"            ($added)                                   "True"
Check "py side injected"          ($pySyn['nihaoya'])                        $word
$expectedWb = 'wv' + 'ka'        # 3-char rule: ni->w?  ni=wqiy->w, hao=vbg->v, ya=kaht->ka => "wvka"
Check "wb side injected"          ($wbSyn2['wvka'])                          $word
$uwFile = Join-Path $tmp 'userwords.txt'
Check "userwords.txt written"     (Test-Path $uwFile)                        "True"
$uwContent = (Get-Content $uwFile -Raw).Trim()
Check "file keeps pinyin only"    ($uwContent)                               "nihaoya $word"
Remove-Item $tmp -Recurse -Force

Write-Output ""
Write-Output "== $pass passed, $fail failed =="
if ($fail -gt 0) { exit 1 }
