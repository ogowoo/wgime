# Headless harness: drives the real plugins\chat.txt code (no UI) against a live broker.
# usage: powershell.exe -File plugin-harness.ps1 -BrokerUrl <url> -Room <r> -Nick <n> -Key <k> -WaitMs <ms> -SendText <t>
param(
    [string]$PluginPath = "$PSScriptRoot\..\..\plugins\chat.txt",
    [string]$DriverPath = "$PSScriptRoot\driver.cs.txt",
    [string]$BrokerUrl = 'wss://chat.seee.uno',
    [string]$Room = 'wgtest',
    [string]$Nick = 'WgPlugin',
    [string]$Key = '',
    [int]$WaitMs = 20000,
    [string]$SendText = 'plugin-hello',
    [string]$SendFile = '',
    [switch]$Lan
)
$ErrorActionPreference = 'Stop'
if ($Key -eq 'nokey') { $Key = '' }

$t = [IO.File]::ReadAllText($PluginPath, [Text.Encoding]::UTF8)
$m = [regex]::Match($t, '(?s)\[csharp\]\s*(.*)')
$cs = $m.Groups[1].Value
$end = $cs.IndexOf('[/csharp]')
if ($end -gt 0) { $cs = $cs.Substring(0, $end) }
$driver = [IO.File]::ReadAllText($DriverPath, [Text.Encoding]::UTF8)
Add-Type -TypeDefinition ($cs + "`n" + $driver) -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Net

$lines = [ChatPluginDriver]::Run($BrokerUrl, $Room, $Nick, $Key, $WaitMs, $SendText, $SendFile, $Lan.IsPresent)
$lines | ForEach-Object { $_ }
