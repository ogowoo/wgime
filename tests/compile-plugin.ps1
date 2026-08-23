# compile check for any plugin file
param([string]$Path)
$ErrorActionPreference = 'Stop'
$t = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
$m = [regex]::Match($t, '(?s)\[csharp\]\s*(.*)')
if (-not $m.Success) { throw "no [csharp] block in $Path" }
$cs = $m.Groups[1].Value
$end = $cs.IndexOf("[/csharp]")
if ($end -gt 0) { $cs = $cs.Substring(0, $end) }
try {
    Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Net -ErrorAction Stop
    Write-Host "COMPILE OK: $Path ($($cs.Length) chars)"
} catch {
    Write-Host "COMPILE FAILED: $Path"
    $_.Exception.Message -split "`n" | Where-Object { $_ -match 'error CS|>>>' } | Select-Object -First 15 | ForEach-Object { $_.Trim() }
    exit 1
}
