# Probe: same-machine UDP delivery (broadcast loopback / multicast loopback / shared port)
Add-Type -AssemblyName System.Net
$ErrorActionPreference = 'Continue'

function New-Udp($port) {
    $u = New-Object System.Net.Sockets.UdpClient
    $u.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $u.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $port)))
    $u.EnableBroadcast = $true
    return $u
}

$a = New-Udp 20003
$b = New-Udp 20003
$b.Client.ReceiveTimeout = 2000

# 1. broadcast loopback: A -> 255.255.255.255:20003, does B get it?
$msg = [Text.Encoding]::UTF8.GetBytes('{"probe":"bcast"}')
$a.Send($msg, $msg.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, 20003))) | Out-Null
$got = 'NONE'
try { $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0); $r = $b.Receive([ref]$ep); $got = [Text.Encoding]::UTF8.GetString($r) + ' from ' + $ep.Address } catch { $got = 'TIMEOUT' }
Write-Host "broadcast loopback: $got"

# 2. multicast: mc listener on 5353 joined group, sender sends to group
$mc = New-Object System.Net.Sockets.UdpClient
$mc.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
$mc.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 5353)))
$mc.JoinMulticastGroup([System.Net.IPAddress]::Parse('224.0.0.251'))
$mc.Client.ReceiveTimeout = 2000
$msg2 = [Text.Encoding]::UTF8.GetBytes('{"probe":"mc"}')
$a.Send($msg2, $msg2.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('224.0.0.251'), 5353))) | Out-Null
$got2 = 'NONE'
try { $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0); $r = $mc.Receive([ref]$ep); $got2 = [Text.Encoding]::UTF8.GetString($r) + ' from ' + $ep.Address } catch { $got2 = 'TIMEOUT' }
Write-Host "multicast loopback: $got2"

# 3. unicast to own real IP on shared port: which socket gets it?
$ownIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress
Write-Host "own ip: $ownIp"
if ($ownIp) {
    $msg3 = [Text.Encoding]::UTF8.GetBytes('{"probe":"uni"}')
    $a.Send($msg3, $msg3.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($ownIp), 20003))) | Out-Null
    $got3 = 'NONE'
    try { $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0); $r = $b.Receive([ref]$ep); $got3 = 'B got: ' + [Text.Encoding]::UTF8.GetString($r) } catch { $got3 = 'B TIMEOUT' }
    Write-Host "unicast own-ip: $got3"
}
$a.Close(); $b.Close(); $mc.Close()
