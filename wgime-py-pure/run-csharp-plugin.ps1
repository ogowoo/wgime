# run-csharp-plugin.ps1 -- sidecar: compile + run a [csharp] plugin (plugins/*.txt) in a separate process.
# ASCII only (PS 5.1 reads scripts as ANSI). Called by wgime-py-pure when a [csharp] plugin is invoked.
param([string]$Path)
$ErrorActionPreference = 'Stop'
$text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
$m = [regex]::Match($text, '(?s)\[csharp\]\s*(.*?)\[/csharp\]')
if (-not $m.Success) { Write-Host 'no [csharp] block'; exit 1 }
$src = $m.Groups[1].Value

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$refs = @('System.dll', 'System.Core.dll', 'System.Data.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll')
foreach ($n in @('WindowsBase', 'PresentationCore', 'PresentationFramework')) {   # WPF (GAC)
    try { $a = [Reflection.Assembly]::Load("$n, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"); if ($a) { $refs += $a.Location } } catch {}
}
$cp = New-Object Microsoft.CSharp.CSharpCodeProvider
$par = New-Object System.CodeDom.Compiler.CompilerParameters
$par.GenerateInMemory = $true
$refs | ForEach-Object { [void]$par.ReferencedAssemblies.Add($_) }
$res = $cp.CompileAssemblyFromSource($par, $src)
if ($res.Errors.Count -gt 0) {
    Write-Host 'compile errors:'
    $res.Errors | ForEach-Object { Write-Host $_.ToString() }
    exit 1
}
$asm = $res.CompiledAssembly
$entry = $null
foreach ($t in $asm.GetTypes()) {
    $rm = $t.GetMethod('Run', [Reflection.BindingFlags]'Public, Static')
    if ($rm) { $entry = $rm; break }
}
if (-not $entry) { Write-Host 'no public static Run() entry'; exit 1 }

# 用 -STA 主线程跑 Run() + 消息泵, 插件窗体保持存活
[System.Windows.Forms.Application]::EnableVisualStyles()
$entry.Invoke($null, @())
[System.Windows.Forms.Application]::Run()
