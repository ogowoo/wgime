# ============================================================
#  nettools.tests.ps1  -  tests for the embedded network tools
#  (builtin:nettools):
#   1. SubnetCalc: prefix & dotted-mask forms, /24 /25 /30 /32,
#      bad input throws, non-contiguous mask throws
#   2. PingOnce 127.0.0.1 -> reply
#   3. HopOnce 127.0.0.1 ttl=1 -> done in one hop
#   4. TestPort: open (live listener) vs closed (unused port)
#   5. LocalNetInfo contains the host name
#   6. Apps registry has net/wlgj -> builtin:nettools
#   7. NetToolsForm renders (tests\nettools-form.png)
#
#  Prereq: rebuild.ps1 has run (%TEMP%\wgime_new.dll is current).
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\nettools.tests.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

$dll = Join-Path $env:TEMP 'wgime_new.dll'
if (-not (Test-Path $dll)) { throw "rebuilt DLL not found: $dll (run rebuild.ps1 first)" }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$asm = [Reflection.Assembly]::LoadFile($dll)
$wbType = $asm.GetType('WordBoard')
$fl = [Reflection.BindingFlags] 'Static, Public, NonPublic'

$pass = 0; $fail = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -ceq "$expected") { Write-Output "PASS  $name"; $script:pass++ }
    else { Write-Output "FAIL  $name (expected [$expected], got [$actual])"; $script:fail++ }
}

$subnetM = $wbType.GetMethod('SubnetCalc', $fl)
$pingM   = $wbType.GetMethod('PingOnce', $fl)
$hopM    = $wbType.GetMethod('HopOnce', $fl)
$portM   = $wbType.GetMethod('TestPort', $fl)
$localM  = $wbType.GetMethod('LocalNetInfo', $fl)
$appsF   = $wbType.GetField('Apps', $fl)
$loadC   = $wbType.GetMethod('LoadConfig', $fl)

# ---- 1) SubnetCalc ----
$lines = $subnetM.Invoke($null, @('192.168.1.10', '24'))
$text = ($lines -join "`n")
Check "subnet /24 mask"      ($text -match '255\.255\.255\.0')                    "True"
Check "subnet /24 network"   ($text -match '192\.168\.1\.0')                      "True"
Check "subnet /24 bcast"     ($text -match '192\.168\.1\.255')                    "True"
Check "subnet /24 hosts"     ($text -match '254')                                 "True"
Check "subnet /24 first"     ($text -match '192\.168\.1\.1 - 192\.168\.1\.254')   "True"
Check "subnet /24 binary"    ($text -match '11111111\.11111111\.11111111\.00000000') "True"

$lines = $subnetM.Invoke($null, @('10.0.0.77', '255.255.255.128'))
$text = ($lines -join "`n")
Check "dotted mask -> /25"   ($text -match '/25')                                 "True"
Check "mask /25 network"   ($text -match '10\.0\.0\.0')                           "True"
Check "mask /25 bcast"     ($text -match '10\.0\.0\.127')                         "True"

$text = (($subnetM.Invoke($null, @('172.16.5.9', '30'))) -join "`n")
Check "/30 hosts = 2"        ($text -match 'Hosts\D*2|2\r?$' -or $text -match ': *2\r?$')  "True"
Check "/30 bcast"            ($text -match '172\.16\.5\.11')                        "True"

$text = (($subnetM.Invoke($null, @('192.168.0.55', '32'))) -join "`n")
Check "/32 hosts = 1"        ($text -match '1\r?$' -or $text -match ': *1\r?$')   "True"

$threw = $false; try { $subnetM.Invoke($null, @('999.1.1.1', '24')) | Out-Null } catch { $threw = $true }
Check "bad ip throws"        $threw                                               "True"
$threw = $false; try { $subnetM.Invoke($null, @('10.0.0.1', '255.255.0.255')) | Out-Null } catch { $threw = $true }
Check "non-contiguous mask"  $threw                                               "True"

# ---- 2) Ping ----
$pr = $pingM.Invoke($null, @('127.0.0.1', 2000))
Check "ping localhost"       ([string]$pr -match 'reply from')                    "True"

# ---- 3) Tracert one hop ----
$done = $false
$hopArgs = @('127.0.0.1', 1, 2000, $done)
$hop = $hopM.Invoke($null, $hopArgs)
Check "tracert 1 hop done"   ([string]$hop -match 'done')                         "True"

# ---- 4) TestPort ----
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$openPort = $listener.LocalEndpoint.Port
$open = $portM.Invoke($null, @('127.0.0.1', $openPort, 1500))
Check "open port detected"   ([string]$open -match 'open')                        "True"
$listener.Stop()
$closed = $portM.Invoke($null, @('127.0.0.1', 9, 1500))      # discard port: essentially always closed
Check "closed port detected" ([string]$closed -match 'closed')                    "True"

# ---- 5) LocalNetInfo ----
$info = [string]$localM.Invoke($null, @())
Check "local info has host"  ($info.Contains([System.Net.Dns]::GetHostName()))    "True"

# ---- 6) registry ----
$tmp = [string](Join-Path $env:TEMP ('wgime-net-test-' + [guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tmp | Out-Null
$loadC.Invoke($null, @($tmp))
$apps = $appsF.GetValue($null)
Check "net registered"   ($apps.ContainsKey('net')  -and $apps['net'][1]  -eq 'builtin:nettools') "True"
Check "wlgj registered"  ($apps.ContainsKey('wlgj') -and $apps['wlgj'][1] -eq 'builtin:nettools') "True"
Remove-Item $tmp -Recurse -Force

# ---- 7) form renders ----
$ntType = $wbType.GetNestedType('NetToolsForm', 'NonPublic')
$ctor = $ntType.GetConstructors([Reflection.BindingFlags]'Instance, Public, NonPublic')[0]
$form = $ctor.Invoke(@())
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
$bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
$form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
$png = Join-Path $PSScriptRoot 'nettools-form.png'
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$form.Close()
Check "nettools form rendered" (Test-Path $png) "True"
Write-Output "nettools form screenshot: $png"

Write-Output ""
Write-Output "== $pass passed, $fail failed =="
if ($fail -gt 0) { exit 1 }
