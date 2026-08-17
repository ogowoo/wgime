# Smoke test for the improved C# code inside wgime.bat (compile in-memory, reflect private statics)
# Run with Windows PowerShell 5.1:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime.tests.ps1
# NOTE: no non-ASCII literals in this file - Windows PS 5.1 reads scripts as ANSI; use [char] codepoints.
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

# --- 1. InputMd5: streaming version must produce the same hash as the old MemoryStream version ---
function Old-InputMd5($pyText,$wbText,$ecText,$pyFile,$wbFile,$ecFile,$impPy,$impWb,$impEc,$uwFile) {
    $ms = New-Object System.IO.MemoryStream
    foreach ($b in @([Text.Encoding]::UTF8.GetBytes($pyText),[Text.Encoding]::UTF8.GetBytes($wbText),[Text.Encoding]::UTF8.GetBytes($ecText),
                     $pyFile,$wbFile,$ecFile,$impPy,$impWb,$impEc,$uwFile)) {
        $ms.Write($b,0,$b.Length); $ms.WriteByte(0)
    }
    return [Security.Cryptography.MD5]::Create().ComputeHash($ms.ToArray())
}
$method = [WordBoard].GetMethod('InputMd5', [Reflection.BindingFlags]'Static,NonPublic')
$p1 = [Text.Encoding]::UTF8.GetBytes("a a a`n")
$p2 = [Text.Encoding]::UTF8.GetBytes("a g`n")
$p3 = [Text.Encoding]::UTF8.GetBytes("apple pingguo`n")
$imp1 = [Text.Encoding]::UTF8.GetBytes("abacangzhu azhu`n")
$imp2 = [Text.Encoding]::UTF8.GetBytes("a g g`n")
$imp3 = [byte[]]@()
$uw = [Text.Encoding]::UTF8.GetBytes("zg zg`n")
$args = @("a a`n", "a g`n", "a y`n", $p1,$p2,$p3,$imp1,$imp2,$imp3,$uw)
$new = $method.Invoke($null, $args)
$old = Old-InputMd5 $args[0] $args[1] $args[2] $args[3] $args[4] $args[5] $args[6] $args[7] $args[8] $args[9]
T 'InputMd5 streaming == old MemoryStream hash' ([BitConverter]::ToString($new) -eq [BitConverter]::ToString($old)) ("new=$([BitConverter]::ToString($new)) old=$([BitConverter]::ToString($old))")

# --- 2. CharPy lazy: initially null, built on EnsureCharPy ---
$cChar = [string][char]0x4E2D   # 中
$cA    = [string][char]0x554A   # 啊
$cAi   = [string][char]0x7231   # 爱
[WordBoard]::CharPy = $null
[WordBoard]::PyDict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
[WordBoard]::PyDict['a'] = $cA; [WordBoard]::PyDict['ai'] = $cAi; [WordBoard]::PyDict['zhong'] = $cChar
T 'CharPy null before EnsureCharPy' ([WordBoard]::CharPy -eq $null)
$ecp = [WordBoard].GetMethod('EnsureCharPy', [Reflection.BindingFlags]'Static,NonPublic')
$ecp.Invoke($null, @())
T 'CharPy built by EnsureCharPy' ($null -ne [WordBoard]::CharPy -and [WordBoard]::CharPy[$cChar].Contains('zhong'))

# --- 3. BuildAcro + ApplySwap frequency sort ---
$cGuo  = [string][char]0x56FD   # 国
$cHua  = [string][char]0x534E   # 华
$cYao  = [string][char]0x836F   # 药
$cGang = [string][char]0x6E2F   # 港
$cZhu  = [string][char]0x732A   # 猪
$cGan  = [string][char]0x809D   # 肝
$zg  = $cChar + $cGuo            # 中国 (zg)
$zh  = $cChar + $cHua            # 中华 (zh)
$zy  = $cChar + $cYao            # 中药 (zy)
$zgang = $cChar + $cGang         # 中港 (zg)
$zgan  = $cZhu + $cGan           # 猪肝 (zg)
[WordBoard]::Freq = New-Object 'System.Collections.Generic.Dictionary[string,int]'
[WordBoard]::Freq[$zg] = 100; [WordBoard]::Freq[$zh] = 5; [WordBoard]::Freq[$zy] = 50
[WordBoard]::Freq[$zgang] = 10; [WordBoard]::Freq[$zgan] = 20
$py = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$py['zhong'] = $cChar; $py['guo'] = $cGuo; $py['hua'] = $cHua; $py['yao'] = $cYao
$py['gang'] = $cGang; $py['zhu'] = $cZhu; $py['gan'] = $cGan
$py['zhongguo'] = "$zg $zh $zy $zgang $zgan"
[WordBoard]::Acro = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]'
$ba = [WordBoard].GetMethod('BuildAcro', [Reflection.BindingFlags]'Static,NonPublic')
$ba.Invoke($null, @([System.Collections.Generic.Dictionary[string,string]]$py))
$acro = [WordBoard]::Acro['zg']
T 'Acro built: zg has 3 words' ($acro.Count -eq 3) ("count=$($acro.Count), words=$([string]::Join(',', $acro))")
$mbType = [WordBoard].GetNestedType('MbData', [Reflection.BindingFlags]'NonPublic')
$mb = [Activator]::CreateInstance($mbType, [object[]]@())
$mb.Py = $py; $mb.Wb = $py; $mb.Ec = $py; $mb.Ce = $py
$mb.Pk = [string[]]@('a'); $mb.Pv = [string[]]@($cA)
$mb.Wk = [string[]]@('a'); $mb.Wv = [string[]]@($cA)
$mb.Ek = [string[]]@('a'); $mb.Ev = [string[]]@($cA)
$mb.Acro = [WordBoard]::Acro
$as = [WordBoard].GetMethod('ApplySwap', [Reflection.BindingFlags]'Static,NonPublic')
$as.Invoke($null, @($mb))
T 'ApplySwap sorts Acro by Freq desc (China first)' ([WordBoard]::Acro['zg'][0] -eq $zg) ("order=$([string]::Join(',', [WordBoard]::Acro['zg']))")
T 'Acro order respects Freq (zhugan before zhonggang)' ([string]::Join(',', [WordBoard]::Acro['zg']) -eq "$zg,$zgan,$zgang") ("order=$([string]::Join(',', [WordBoard]::Acro['zg']))")

# --- 4. VerifyEmojiData: no log mismatch when data is consistent ---
$logPath = Join-Path $env:TEMP 'WgIme_error.log'
if (Test-Path $logPath) { $before = (Get-Item $logPath).Length } else { $before = 0 }
$ved = [WordBoard].GetMethod('VerifyEmojiData', [Reflection.BindingFlags]'Static,NonPublic')
$ved.Invoke($null, @())
$after = (Get-Item $logPath).Length
T 'VerifyEmojiData: no mismatch logged (consistent data)' ($after -eq $before) ("log grew: $before -> $after")

# --- 5. VerifyEmojiData catches mismatch: tamper one entry, must log ---
[WordBoard].GetField('emojiVerified', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $false)
$orig = [WordBoard].GetField('EmojiChars', [Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
$tampered = New-Object 'System.String[]' $orig.Length
$tampered[0] = 'X'
for ($ti = 1; $ti -lt $orig.Length; $ti++) { $tampered[$ti] = $orig[$ti] }
[WordBoard].GetField('EmojiChars', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $tampered)
$ved.Invoke($null, @())
[WordBoard].GetField('EmojiChars', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $orig)
$content = [IO.File]::ReadAllText($logPath, [Text.Encoding]::UTF8)
T 'VerifyEmojiData logs mismatch after tamper' ($content -match 'emoji mismatch') ("tail: " + $content.Substring([Math]::Max(0,$content.Length-200)))

# --- 6. Hook exception guard & other structural checks (read the bat source) ---
$src = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
T 'Hook try/catch present (catch LogC in KeyboardHookProc)' ($src -match 'catch \(Exception ex\) \{ LogC\("hook: " \+ ex\)' )
T 'WgLog rotation present (>1MB -> .old)' ($src -match '\$len -gt 1MB')
T 'ParseDict streaming (StringReader, no Split)' ($src -match 'new StringReader\(text\)')
T 'CharPy lazy: cache-hit path skips BuildCharPy' ($src -match 'if \(mb != null\) return mb;')

# --- 7. vf panel digit bug: stale v-mode DigitAsCode must be cleared inside the panel ---
# Real WordBoard instance: simulate typing 'v' (DigitAsCode=true) then 'f' -> ShowCharatar must reset it to false,
# so the NEXT digit key goes to OnSpaced (pick category) instead of extending the code buffer.
[WordBoard]::Shuangpin = 0
[WordBoard]::Hook = New-Object KeyBordHook
$wb = New-Object WordBoard
try {
    $keysF = [WordBoard].GetField('keys', [Reflection.BindingFlags]'Instance,NonPublic')
    $sc = [WordBoard].GetMethod('ShowCharatar', [Reflection.BindingFlags]'Instance,NonPublic')
    [KeyBordHook]::DigitAsCode = $true    # leftover from typing 'v'
    [KeyBordHook]::SemiAsCode = $true     # leftover from mspy shuangpin
    $keysF.SetValue($wb, 'vf')
    $sc.Invoke($wb, @())
    T 'vf panel resets DigitAsCode=false (vf5 bug)' ([KeyBordHook]::DigitAsCode -eq $false) ("DigitAsCode=" + [KeyBordHook]::DigitAsCode)
    T 'vf panel resets SemiAsCode=false' ([KeyBordHook]::SemiAsCode -eq $false) ("SemiAsCode=" + [KeyBordHook]::SemiAsCode)
    # picking a category then ShowCharatar keeps showing category contents (symCat stays, cands filled)
    $symF = [WordBoard].GetField('symCat', [Reflection.BindingFlags]'Instance,NonPublic')
    $candsF = [WordBoard].GetField('cands', [Reflection.BindingFlags]'Instance,NonPublic')
    $symF.SetValue($wb, 5)                # emoji category
    $sc.Invoke($wb, @())
    $cands = $candsF.GetValue($wb)
    T 'vf category 5 shows emoji candidates' ($cands.Count -gt 0) ("cands=" + $cands.Count)
} finally {
    $wb.Dispose()
}

# --- 7b. v-mode digit routing: multi-digit amounts + bare-v candidate selection ---
$cFa  = [string][char]0x53D1                 # 发
$pyV = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$pyV['a'] = $cA
$wbV = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$wbV['a'] = $cA; $wbV['v'] = $cFa
$mb2 = [Activator]::CreateInstance($mbType, [object[]]@())
$mb2.Py = $pyV; $mb2.Wb = $wbV; $mb2.Ec = $pyV; $mb2.Ce = $pyV
$mb2.Pk = [string[]]@('a'); $mb2.Pv = [string[]]@($cA)
$mb2.Wk = [string[]]@('a', 'v'); $mb2.Wv = [string[]]@($cA, $cFa)
$mb2.Ek = [string[]]@('a'); $mb2.Ev = [string[]]@($cA)
$mb2.Acro = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]'
$as.Invoke($null, @($mb2))
[WordBoard]::Shuangpin = 0
$wb2 = New-Object WordBoard
try {
    $keysF2 = [WordBoard].GetField('keys', [Reflection.BindingFlags]'Instance,NonPublic')
    $candsF2 = [WordBoard].GetField('cands', [Reflection.BindingFlags]'Instance,NonPublic')
    $modeF = [WordBoard].GetField('mode', [Reflection.BindingFlags]'Instance,NonPublic')
    $sc2 = [WordBoard].GetMethod('ShowCharatar', [Reflection.BindingFlags]'Instance,NonPublic')
    $spaced = [WordBoard].GetMethod('Hook_OnSpaced', [Reflection.BindingFlags]'Instance,NonPublic')
    $modeF.SetValue($wb2, 0)                                   # mixed mode

    $keysF2.SetValue($wb2, 'v'); $sc2.Invoke($wb2, @())
    $cv = $candsF2.GetValue($wb2)
    T 'bare v: wubi candidate fa present' ($cv.Count -gt 0 -and $cv[0] -eq $cFa) ("cands=" + [string]::Join(',', $cv))
    T 'bare v with candidates: digits select (DigitAsCode=false)' ([KeyBordHook]::DigitAsCode -eq $false) ("DigitAsCode=" + [KeyBordHook]::DigitAsCode)

    $spaced.Invoke($wb2, @(5))                                 # digit 5 > 1 candidate -> extend the code
    T 'digit beyond candidate count extends v-code (v5)' ($keysF2.GetValue($wb2) -eq 'v5') ("keys=" + $keysF2.GetValue($wb2))
    T 'v5: digits keep extending (DigitAsCode=true)' ([KeyBordHook]::DigitAsCode -eq $true) ("DigitAsCode=" + [KeyBordHook]::DigitAsCode)
    $c5 = $candsF2.GetValue($wb2)
    T 'v5 shows uppercase amount candidate' ($c5.Count -gt 0 -and $c5[0] -eq ([string][char]0x4F0D + [char]0x5143 + [char]0x6574)) ("cands=" + [string]::Join(',', $c5))

    $keysF2.SetValue($wb2, 'v12'); $sc2.Invoke($wb2, @())      # multi-digit amount stays in extend mode
    T 'v12: still extending (multi-digit v-mode fixed)' ([KeyBordHook]::DigitAsCode -eq $true) ("DigitAsCode=" + [KeyBordHook]::DigitAsCode)

    $modeF.SetValue($wb2, 1)                                   # pinyin mode: bare v has no candidates
    $keysF2.SetValue($wb2, 'v'); $sc2.Invoke($wb2, @())
    T 'bare v, no candidates (pinyin): digits extend (v-mode start)' ([KeyBordHook]::DigitAsCode -eq $true) ("DigitAsCode=" + [KeyBordHook]::DigitAsCode)

    $modeF.SetValue($wb2, 2)                                   # pure wubi mode: v-mode off
    $sc2.Invoke($wb2, @())
    T 'wubi mode: v-mode off (DigitAsCode=false)' ([KeyBordHook]::DigitAsCode -eq $false) ("DigitAsCode=" + [KeyBordHook]::DigitAsCode)
} finally {
    $wb2.Dispose()
}

# --- 8. tray 反查编码/简繁 toggle must persist keys into config.txt (keep comments/other keys) ---
$tmpCfg = Join-Path $env:TEMP 'wgime_cfg_test'
New-Item -ItemType Directory -Path $tmpCfg -Force | Out-Null
try {
    $cfg = Join-Path $tmpCfg 'config.txt'
    [IO.File]::WriteAllText($cfg, "; comment line`nfuzzy = zh-z,ch-c`npaste = key`nstarton = 0`n", (New-Object System.Text.UTF8Encoding($false)))
    [WordBoard]::BatDir = $tmpCfg
    $sck = [WordBoard].GetMethod('SaveConfigKey', [Reflection.BindingFlags]'Static,NonPublic')
    $sck.Invoke($null, @('showcode', '1'))
    $t = [IO.File]::ReadAllText($cfg, [Text.Encoding]::UTF8)
    T 'SaveConfigKey writes showcode = 1' ($t -match 'showcode = 1') ("cfg:`n$t")
    T 'SaveConfigKey keeps other keys/comments' ($t -match 'fuzzy = zh-z,ch-c' -and $t -match '; comment line' -and $t -match 'paste = key' -and $t -match 'starton = 0') ("cfg:`n$t")
    $sck.Invoke($null, @('showcode', '0'))
    $t2 = [IO.File]::ReadAllText($cfg, [Text.Encoding]::UTF8)
    T 'SaveConfigKey flips showcode to 0 (no duplicates)' (([regex]::Matches($t2, 'showcode = 0')).Count -eq 1 -and ([regex]::Matches($t2, 'showcode')).Count -eq 1) ("cfg:`n$t2")
    $sck.Invoke($null, @('trad', '1'))   # 简繁输出持久化: same helper, different key
    $t3 = [IO.File]::ReadAllText($cfg, [Text.Encoding]::UTF8)
    T 'SaveConfigKey writes trad = 1' ($t3 -match 'trad = 1') ("cfg:`n$t3")
    T 'SaveConfigKey showcode+trad coexist (no dupes)' (([regex]::Matches($t3, 'showcode')).Count -eq 1 -and ([regex]::Matches($t3, 'trad')).Count -eq 1) ("cfg:`n$t3")
    # Hook_OnToggleTrad persists too (the real toggle entry point)
    $htt = [WordBoard].GetMethod('Hook_OnToggleTrad', [Reflection.BindingFlags]'Instance,NonPublic')
    $wb2 = New-Object WordBoard
    try {
        [WordBoard]::Trad = $false
        $htt.Invoke($wb2, @())
        $t4 = [IO.File]::ReadAllText($cfg, [Text.Encoding]::UTF8)
        T 'Hook_OnToggleTrad writes trad = 1' ($t4 -match 'trad = 1') ("cfg:`n$t4")
        $htt.Invoke($wb2, @())
        $t5 = [IO.File]::ReadAllText($cfg, [Text.Encoding]::UTF8)
        T 'Hook_OnToggleTrad flips back to trad = 0' ($t5 -match 'trad = 0') ("cfg:`n$t5")
    } finally {
        $wb2.Dispose()
    }
} finally {
    Remove-Item $tmpCfg -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 8b. per-mode frequency buckets: isolation + legacy migration + per-mode persistence ---
$cFa2   = [string][char]0x53D1   # 发
$cJian2 = [string][char]0x89C1   # 见
$freqMF = [WordBoard].GetField('FreqM', [Reflection.BindingFlags]'Static, NonPublic')
$lpMF   = [WordBoard].GetField('LastPickM', [Reflection.BindingFlags]'Static, NonPublic')
$learnM = [WordBoard].GetMethod('Learn', [Reflection.BindingFlags]'Static, NonPublic')
$saveFM = [WordBoard].GetMethod('SaveFreq', [Reflection.BindingFlags]'Static, NonPublic')
$loadFM = [WordBoard].GetMethod('LoadFreq', [Reflection.BindingFlags]'Static, NonPublic')
$fArr = [Array]::CreateInstance([System.Collections.Generic.Dictionary[string,int]], 3)
$lArr = [Array]::CreateInstance([System.Collections.Generic.Dictionary[string,string]], 3)
for ($i = 0; $i -lt 3; $i++) { $fArr[$i] = New-Object 'System.Collections.Generic.Dictionary[string,int]'; $lArr[$i] = New-Object 'System.Collections.Generic.Dictionary[string,string]' }
$freqMF.SetValue($null, $fArr); $lpMF.SetValue($null, $lArr)
[WordBoard]::Freq = New-Object 'System.Collections.Generic.Dictionary[string,int]'
$tmpF = Join-Path $env:TEMP ('wgime-freq-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpF | Out-Null
$oldDataDir = [WordBoard]::DataDir
try {
    [WordBoard]::DataDir = $tmpF
    [IO.File]::WriteAllText((Join-Path $tmpF 'userdict.txt'), ($cJian2 + ' 7'), (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $tmpF 'lastpick.txt'), ('jian ' + $cJian2), (New-Object System.Text.UTF8Encoding($false)))
    $loadFM.Invoke($null, @())
    $fm = $freqMF.GetValue($null); $lm = $lpMF.GetValue($null)
    T 'legacy userdict migrates into all mode buckets' ($fm[0][$cJian2] -eq 7 -and $fm[1][$cJian2] -eq 7 -and $fm[2][$cJian2] -eq 7) ("mix=$($fm[0][$cJian2]) py=$($fm[1][$cJian2]) wb=$($fm[2][$cJian2])")
    T 'legacy lastpick migrates into all mode buckets' ($lm[0]['jian'] -eq $cJian2 -and $lm[2]['jian'] -eq $cJian2) ("py jian=$($lm[1]['jian'])")
    T 'combined Freq is the bucket sum' ([WordBoard]::Freq[$cJian2] -eq 21) ("Freq=$([WordBoard]::Freq[$cJian2])")

    $learnM.Invoke($null, @('fa', $cFa2, 1))        # pinyin-mode pick
    T 'pinyin pick lands in py bucket only' ($fm[1][$cFa2] -eq 1 -and -not $fm[0].ContainsKey($cFa2) -and -not $fm[2].ContainsKey($cFa2)) ("py=$($fm[1][$cFa2]) mix=$($fm[0].ContainsKey($cFa2)) wb=$($fm[2].ContainsKey($cFa2))")
    T 'pinyin lastpick lands in py bucket only' ($lm[1]['fa'] -eq $cFa2 -and -not $lm[0].ContainsKey('fa') -and -not $lm[2].ContainsKey('fa')) ("py fa=$($lm[1]['fa'])")
    T 'combined Freq still counts every mode' ([WordBoard]::Freq[$cFa2] -eq 1) ("Freq=$([WordBoard]::Freq[$cFa2])")

    $learnM.Invoke($null, @('xyz', 'ENG', 3))       # translate mode: combined only, no bucket pollution
    T 'translate pick skips mode buckets' (-not $fm[0].ContainsKey('ENG') -and -not $fm[1].ContainsKey('ENG') -and -not $fm[2].ContainsKey('ENG')) ""
    T 'translate pick counts in combined Freq' ([WordBoard]::Freq['ENG'] -eq 1) ("Freq=$([WordBoard]::Freq['ENG'])")

    $saveFM.Invoke($null, @())
    T 'per-mode files written' ((Test-Path (Join-Path $tmpF 'userdict_py.txt')) -and (Test-Path (Join-Path $tmpF 'userdict_wb.txt')) -and (Test-Path (Join-Path $tmpF 'lastpick_mix.txt'))) ""
    T 'py bucket file has the pinyin pick' (([IO.File]::ReadAllText((Join-Path $tmpF 'userdict_py.txt'), [Text.Encoding]::UTF8)) -match [regex]::Escape($cFa2)) ""
    T 'mix bucket file has no pinyin pick' (-not (([IO.File]::ReadAllText((Join-Path $tmpF 'userdict_mix.txt'), [Text.Encoding]::UTF8)) -match [regex]::Escape($cFa2))) ""
    T 'legacy userdict.txt not rewritten' (([IO.File]::ReadAllText((Join-Path $tmpF 'userdict.txt'), [Text.Encoding]::UTF8)).Trim() -eq ($cJian2 + ' 7')) ""
} finally {
    [WordBoard]::DataDir = $oldDataDir
    Remove-Item $tmpF -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "== $passed passed, $failed failed ==" -ForegroundColor Cyan
if ($failed -gt 0) { exit 1 }
