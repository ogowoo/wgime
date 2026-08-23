# Rebuild wgime.bat's embedded THIN DLL: pure WordBoard (no WgImeLauncher, no dict consts).
# The bat edition calls [WordBoard]::RunApp($pyData,$wbData,$ecData,...) with the dict
# here-strings, so the DLL only needs the compiled WordBoard code (~550KB), NOT the
# launcher+embedded-dicts full build (which would balloon the bat to ~10MB).
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot | Split-Path -Parent
$batPath = Join-Path $root 'wgime.bat'

$bat = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)
$i = $bat.IndexOf("cs = @'")
if ($i -lt 0) { throw "cs = @' not found" }
$start = $bat.IndexOf("`n", $i) + 1
$end = $bat.IndexOf("`n'@", $start)
if ($end -lt 0) { throw "cs close not found" }
$cs = $bat.Substring($start, $end - $start)

# compile pure WordBoard
$outDll = Join-Path $env:TEMP ("wgime-thin-" + [guid]::NewGuid().ToString('N').Substring(0,6) + ".dll")
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms,System.Drawing,UIAutomationClient,UIAutomationTypes,WindowsBase -OutputAssembly $outDll -OutputType Library -ErrorAction Stop
Write-Host ("thin DLL compiled: {0:N0} KB" -f ((Get-Item $outDll).Length / 1KB))

# embed into wgime.bat
$tag = '###WGIME_DLL###'
$ti = $bat.LastIndexOf($tag)
if ($ti -lt 0) { throw 'marker not found' }
$head = $bat.Substring(0, $ti + $tag.Length)
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($outDll))
$newBat = $head + "`n'" + $b64 + "'"
[IO.File]::WriteAllText($batPath, $newBat, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("wgime.bat rebuilt: {0:N1} MB (was {1:N1} MB)" -f ((Get-Item $batPath).Length/1MB), ($bat.Length/1MB))
Remove-Item $outDll -Force -EA SilentlyContinue
