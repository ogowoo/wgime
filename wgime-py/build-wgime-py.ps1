# build-wgime-py.ps1 — 生成免安装单文件 wgime.py.bat
# 结构: cmd 引导 -> PowerShell 按 ###PYZIP###/###APP###/###DICTS### 标记 base64 解压到
#       %LOCALAPPDATA%\wgime-py\runtime (按版本标记缓存), 然后 python.exe 运行.
# 参数: -Py38 <embeddable zip 路径>  -DictDir <py.txt 所在目录>  -AppDir <应用脚本目录>
param(
    [string]$Py38 = 'C:\Tools\py38-embed.zip',
    [string]$PySite = 'C:\Tools\py38\Lib\site-packages',
    [string]$DictDir = 'C:\Tools\wgime',
    [string]$AppDir = 'C:\Tools\wgime-py',
    [string]$Out = 'C:\Tools\wgime-py\dist\wgime.py.bat',
    [int]$Ver = 1
)
$ErrorActionPreference = 'Stop'
# pythonnet 2.5.2 安装为扁平文件 (clr.pyd / Python.Runtime.dll 等), 不在包目录里
$PYNET_FILES = @('clr.pyd', 'Python.Runtime.dll')
function Add-Zip($items) { # items: @{Path=...; Name=<相对名>}
    $zipPath = Join-Path $env:TEMP ('wgpy-' + [guid]::NewGuid().ToString('N') + '.zip')
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
    foreach ($it in $items) {
        $entry = $zip.CreateEntry($it.Name, [System.IO.Compression.CompressionLevel]::Optimal)
        try {
            $bytes = [IO.File]::ReadAllBytes($it.Path)
            $s = $entry.Open(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        } catch {}
    }
    $zip.Dispose()
    return $zipPath
}

# ---- runtime.zip: embeddable python + pythonnet ----
$runtimeItems = @()
$emb = Join-Path $env:TEMP ('wgpy-emb-' + [guid]::NewGuid().ToString('N'))
Expand-Archive $Py38 -DestinationPath $emb -Force
$embFull = [IO.Path]::GetFullPath($emb)
# 让 embeddable 能 import site-packages (pythonnet 所在目录)
$pth = Join-Path $emb 'python38._pth'
$pc = Get-Content $pth
$pc = $pc -replace '#import site', 'import site'
Add-Content $pth 'Lib\site-packages'
Get-ChildItem -Recurse -File $emb | ForEach-Object {
    $rel = [IO.Path]::GetFullPath($_.FullName).Substring($embFull.Length).TrimStart('\', '/').Replace('\', '/')
    $runtimeItems += @{ Path = $_.FullName; Name = $rel }
}
foreach ($an in $PYNET_FILES) {
    $pkg = Join-Path $PySite $an
    if (Test-Path $pkg) {
        $runtimeItems += @{ Path = $pkg; Name = 'Lib/site-packages/' + $an }
    } else { Write-Warning "missing pkg file: $an" }
}
$runtimeZip = Add-Zip $runtimeItems
Remove-Item $emb -Recurse -Force -ErrorAction SilentlyContinue

# ---- app.zip: 应用脚本 + 小数据 (trad/pywfreq) ----
$appItems = @()
foreach ($name in @('wgime.py', 'engine.py', 'bridge.cs', 'plugins.py', 'trad.txt', 'pywfreq.txt')) {
    $p = Join-Path $AppDir $name
    if (Test-Path $p) { $appItems += @{ Path = $p; Name = $name }; Write-Host "app: $name" } else { Write-Warning "missing app file: $name" }
}
foreach ($name in @('config.txt', 'tools.txt')) {
    $p = Join-Path $DictDir $name
    if (Test-Path $p) { $appItems += @{ Path = $p; Name = 'data/' + $name } }
}
$plugDir = Join-Path $DictDir 'plugins'
if (Test-Path $plugDir) {
    Get-ChildItem $plugDir -File | ForEach-Object { $appItems += @{ Path = $_.FullName; Name = 'data/plugins/' + $_.Name } }
}
$appZip = Add-Zip $appItems

# ---- dicts.zip: 码表 (py/wb/ec/import) ----
$dictItems = @()
foreach ($name in @('py.txt', 'wb.txt', 'ec.txt', 'import_py.txt', 'import_wb.txt')) {
    $p = Join-Path $DictDir $name
    if (Test-Path $p) { $dictItems += @{ Path = $p; Name = $name } }
}
$dictZip = Add-Zip $dictItems

# ---- assemble bat ----
function B64([string]$path) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) }
$b64runtime = B64 $runtimeZip
$b64app = B64 $appZip
$b64dict = B64 $dictZip

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('@echo off & setlocal EnableExtensions')
[void]$sb.AppendLine('rem WgIme-Py: PowerShell/Python + pythonnet 免安装单文件输入法 (拼音/五笔/混合/词典)')
[void]$sb.AppendLine('set "RT=%LOCALAPPDATA%\wgime-py\runtime"')
[void]$sb.AppendLine('set "VER=' + $Ver + '"')
[void]$sb.AppendLine('if exist "%RT%\%VER%.ok" goto run')
[void]$sb.AppendLine('set "WGIME_PY_SRC=%~f0"')
[void]$sb.AppendLine('echo 正在首次解压运行环境, 请稍候...')
# 解压脚本 (单行; 单引号 here-string 保字面量, `$` 不被 cmd 展开)
$psBody = @'
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Add-Type -AssemblyName System.IO.Compression.FileSystem; $s=[IO.File]::ReadAllText($env:WGIME_PY_SRC,[Text.Encoding]::UTF8); function Ext($m,$n,$o){$x=$s.LastIndexOf($m)+$m.Length; $y=if($n){$s.IndexOf($n,$x)}else{$s.Length}; $b64=$s.Substring($x,$y-$x).Trim(); [IO.File]::WriteAllBytes($o,[Convert]::FromBase64String($b64))}; if(Test-Path $env:RT){Remove-Item $env:RT -Recurse -Force -ErrorAction SilentlyContinue}; New-Item -ItemType Directory -Force -Path $env:RT | Out-Null; Ext '###PYZIP###' '###APP###' (Join-Path $env:RT 'runtime.zip'); Ext '###APP###' '###DICTS###' (Join-Path $env:RT 'app.zip'); Ext '###DICTS###' $null (Join-Path $env:RT 'dicts.zip'); [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $env:RT 'runtime.zip'),$env:RT); [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $env:RT 'app.zip'),$env:RT); $dd=Join-Path $env:RT 'data'; New-Item -ItemType Directory -Force -Path $dd | Out-Null; [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $env:RT 'dicts.zip'),$dd); Remove-Item (Join-Path $env:RT 'runtime.zip'),(Join-Path $env:RT 'app.zip'),(Join-Path $env:RT 'dicts.zip') -Force -ErrorAction SilentlyContinue; New-Item -ItemType File -Path (Join-Path $env:RT ($env:VER + '.ok')) -Force | Out-Null; } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'wgpy-install.err'),($_ | Out-String)); pause; exit 1 }"
'@
$psLine = $psBody -replace "`r`n", ''
[void]$sb.AppendLine($psLine)
[void]$sb.AppendLine(':run')
[void]$sb.AppendLine('set "WGIME_DICT_DIR=%RT%\data"')
[void]$sb.AppendLine('if exist "%RT%\python.exe" ( "%RT%\python.exe" "%RT%\wgime.py" %* ) else ( echo 运行环境缺失 & exit /b 1 )')
[void]$sb.AppendLine('exit /b 0')
[void]$sb.AppendLine('###PYZIP###')
[void]$sb.AppendLine($b64runtime)
[void]$sb.AppendLine('###APP###')
[void]$sb.AppendLine($b64app)
[void]$sb.AppendLine('###DICTS###')
[void]$sb.AppendLine($b64dict)

$dir = Split-Path $Out -Parent
New-Item -ItemType Directory -Force -Path $dir | Out-Null
[IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
Write-Host ("built " + $Out + " (" + [math]::Round((Get-Item $Out).Length / 1MB, 1) + " MB)")
