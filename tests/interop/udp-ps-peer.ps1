# UDP sender/receiver probe (cross-process): bind 20003 reuse, listen, send broadcast
$u = New-Object System.Net.Sockets.UdpClient
$u.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
$u.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 20003)))
$u.EnableBroadcast = $true
$u.Client.ReceiveTimeout = 1000

$msg = [Text.Encoding]::UTF8.GetBytes('{"from":"ps"}')
$u.Send($msg, $msg.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, 20003))) | Out-Null
$u.Send($msg, $msg.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('224.0.0.251'), 5353))) | Out-Null
Write-Host 'sent broadcast + multicast'

$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 12000) {
    try {
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $r = $u.Receive([ref]$ep)
        Write-Host ('GOT from ' + $ep.Address + ': ' + [Text.Encoding]::UTF8.GetString($r))
    } catch {}
}
$u.Close()
