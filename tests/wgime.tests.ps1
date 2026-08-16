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

Write-Host ""
Write-Host "== $passed passed, $failed failed ==" -ForegroundColor Cyan
if ($failed -gt 0) { exit 1 }
