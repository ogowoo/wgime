# Trim wgime.bat seeds: keep only seedTools + seedCalc; remove plugin README/cleanBin/clock/chat seeds and their seeding calls
$ErrorActionPreference = 'Stop'
$batPath = 'C:\Tools\WgIme\wgime.bat'
$bat = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)

# 1) delete the here-strings for seedPluginReadme / seedCleanBin / seedClock / seedChat
foreach ($name in @('seedPluginReadme','seedCleanBin','seedClock','seedChat')) {
    $si = $bat.IndexOf("$" + $name + " = @'")
    if ($si -lt 0) { Write-Host "WARN: $name not found"; continue }
    $ei = $bat.IndexOf("`n'@", $si)
    if ($ei -lt 0) { throw "$name close not found" }
    $ei += 4  # include "\n'@" and the trailing newline
    $bat = $bat.Remove($si, $ei - $si)
    Write-Host "removed $name"
}

# 2) delete the seeding calls for plugins/README.txt, clean-bin.txt, clock.txt, chat.txt
#    (keep the calc.txt one)
$removeLines = @(
    "        `$rf = Join-Path `$pdir 'README.txt'",
    "        if (-not (Test-Path `$rf)) { [IO.File]::WriteAllText(`$rf, `$seedPluginReadme, `$utf8n) }",
    "        `$cf = Join-Path `$pdir 'clean-bin.txt'",
    "        if (-not (Test-Path `$cf)) { [IO.File]::WriteAllText(`$cf, `$seedCleanBin, `$utf8n) }",
    "        `$kf = Join-Path `$pdir 'clock.txt'",
    "        if (-not (Test-Path `$kf)) { [IO.File]::WriteAllText(`$kf, `$seedClock, `$utf8n) }",
    "        `$cf2 = Join-Path `$pdir 'chat.txt'",
    "        if (-not (Test-Path `$cf2)) { [IO.File]::WriteAllText(`$cf2, `$seedChat, `$utf8n) }"
)
foreach ($rl in $removeLines) {
    $i = $bat.IndexOf($rl)
    if ($i -ge 0) {
        $lineEnd = $bat.IndexOf("`n", $i)
        $bat = $bat.Remove($i, $lineEnd - $i + 1)
        Write-Host "removed seeding line"
    }
}
[IO.File]::WriteAllText($batPath, $bat, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "done"
