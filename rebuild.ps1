# ============================================================
#  rebuild.ps1  -  wgime.bat C# 载荷重建工具
#
#  用途: 修改 wgime.bat 内嵌的 C# 源码 ($cs here-string) 之后,
#        必须运行本脚本重新编译并替换 base64 预编译 DLL 载荷,
#        否则运行时加载的还是旧代码。
#
#  要求: 必须用 Windows PowerShell 5.1 (powershell.exe) 运行!
#        pwsh 7 (.NET Core) 编出的程序集无法被 5.1 加载。
#        运行:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File rebuild.ps1
#
#  校验: 编译失败 -> bat 不被改动; 载荷行格式/位置不对 -> 中止
# ============================================================
$ErrorActionPreference = 'Stop'

$path = Join-Path $PSScriptRoot 'wgime.bat'
if (-not (Test-Path $path)) { throw "wgime.bat not found next to this script: $path" }
$txt = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
# 内部统一按 LF 处理 (输入可能是 CRLF 或烘焙产生的混合换行), 写回时再转 CRLF
$txt = $txt -replace "`r`n", "`n"

# ---- 1) 提取 $cs here-string 源码 ("cs = @'" 之后到首个行首 '@) ----
$i     = $txt.IndexOf("cs = @'")
if ($i -lt 0) { throw "marker 'cs = @''' not found" }
$start = $txt.IndexOf("`n", $i) + 1
$end   = $txt.IndexOf("`n'@", $start)
if ($end -lt 0) { throw "cs here-string terminator not found" }
$cs    = $txt.Substring($start, $end - $start)
Write-Output ("cs source: {0} chars" -f $cs.Length)

# ---- 2) 编译 (失败则 bat 未被改动, 安全) ----
$outDll = Join-Path $env:TEMP 'wgime_new.dll'
if (Test-Path $outDll) { Remove-Item $outDll -Force }
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms,System.Drawing,UIAutomationClient,UIAutomationTypes,WindowsBase `
         -OutputAssembly $outDll -OutputType Library -ErrorAction Stop
Write-Output "compiled OK -> $outDll"

# ---- 3) base64 替换载荷行 (文件必须保持 CRLF 换行、无 BOM、UTF-8;
#         cmd.exe 依赖 CRLF 解析批处理头, LF 会导致 'xxx is not recognized' 报错) ----
$b64   = [Convert]::ToBase64String([IO.File]::ReadAllBytes($outDll))
$lines = $txt -split "`n"
$mi    = [Array]::IndexOf($lines, '###WGIME_DLL###')      # 应为倒数第 3 个元素
if ($mi -lt 0) { throw 'marker ###WGIME_DLL### not found - aborting' }
if ($mi -ne ($lines.Count - 3)) {
    Write-Warning ("marker at index {0}, expected {1} - still replacing by marker position" -f $mi, ($lines.Count - 3))
}
# 载荷行必须单引号包裹 (PS 无害语句); 校验上一行确实是 marker
$lines[$mi + 1] = "'" + $b64 + "'"
$outText = [string]::Join("`r`n", $lines)
[IO.File]::WriteAllText($path, $outText, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("payload replaced: {0} chars base64 -> {1}" -f $b64.Length, $path)

# ---- 4) 自我校验: 无 BOM / 纯 CRLF (不允许裸 LF, cmd 无法正确解析) ----
$bytes = [IO.File]::ReadAllBytes($path)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
if ($bom) { throw 'FAIL: file now has a BOM - encoding constraint violated' }
$loneLf = 0
for ($k = 0; $k -lt $bytes.Length; $k++) { if ($bytes[$k] -eq 0x0A -and ($k -eq 0 -or $bytes[$k-1] -ne 0x0D)) { $loneLf++ } }
if ($loneLf -gt 0) { throw ("FAIL: {0} lone LF line endings detected (must be pure CRLF, cmd.exe requires it)" -f $loneLf) }
Write-Output "file constraints OK (no BOM, pure CRLF)"
Write-Output "DONE - restart wgime.bat to load the new code (new DLL hash name auto-created, old cleaned)"
