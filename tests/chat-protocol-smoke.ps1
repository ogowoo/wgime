# Smoke test for wgime chat plugin protocol assumptions (PS 5.1, ASCII only)
$ErrorActionPreference = 'Stop'
function Step($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

function New-Ws($url, $subproto) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    if ($subproto) { $ws.Options.AddSubProtocol($subproto) }
    $cts = New-Object System.Threading.CancellationTokenSource(10000)
    $ws.ConnectAsync([Uri]$url, $cts.Token).Wait()
    return $ws
}
function Send-Text($ws, $s) {
    $b = [Text.Encoding]::UTF8.GetBytes($s)
    $ws.SendAsync([ArraySegment[byte]]$b, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}
function Send-Bin($ws, [byte[]]$b) {
    $ws.SendAsync([ArraySegment[byte]]$b, [System.Net.WebSockets.WebSocketMessageType]::Binary, $true, [Threading.CancellationToken]::None).Wait()
}
function Recv($ws, $timeoutMs) {
    $buf = New-Object byte[] 65536
    $ms = New-Object IO.MemoryStream
    $lastType = $null
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    do {
        $task = $ws.ReceiveAsync([ArraySegment[byte]]$buf, [Threading.CancellationToken]::None)
        $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0) { throw "recv timeout" }
        $delay = [Threading.Tasks.Task]::Delay($remaining)
        $done = [Threading.Tasks.Task]::WhenAny($task, $delay).Result
        if ($done -ne $task) { throw "recv timeout" }
        $res = $task.Result
        $ms.Write($buf, 0, $res.Count)
        $lastType = $res.MessageType
    } while (-not $res.EndOfMessage)
    return @{ Type = $lastType; Data = $ms.ToArray() }
}

# ---- Test 1: Cloudflare relay, bare JSON text frames ----
$room = 'dshtest' + (Get-Random)
Step "relay: connect A"
$a = New-Ws "wss://chat.seee.uno/room/$room" $null
Step "relay: connect B"
$b = New-Ws "wss://chat.seee.uno/room/$room" $null
Step "relay: connected"
Start-Sleep -Milliseconds 500
$json = '{"type":"chat","nick":"A","text":"hello","enc":true,"ts":123,"id":"a1"}'
Send-Text $a $json
Step "relay: send + recv"
$got = Recv $b 8000
$text = [Text.Encoding]::UTF8.GetString($got.Data)
if ($got.Type -ne [System.Net.WebSockets.WebSocketMessageType]::Text) { throw "relay: expected Text frame, got $($got.Type)" }
if ($text -ne $json) { throw "relay: payload mismatch: $text" }
# sender must NOT get echo (wait 3s, expect timeout)
$echo = $true
try { Recv $a 3000 | Out-Null } catch { $echo = $false }
if ($echo) { throw "relay: sender got echo (should not)" }
$a.Abort(); $b.Abort()
Write-Host "PASS relay: bare JSON text frame fan-out, no sender echo"

# ---- Test 2: real MQTT broker over WebSocket ----
Step "mqtt: connect"
$mqtt = New-Ws "wss://broker.emqx.io:8084/mqtt" 'mqtt'
Step "mqtt: connected, send CONNECT"
# CONNECT frame (protocol MQTT, level 4, clean session, keepalive 30, client id)
$cid = [Text.Encoding]::UTF8.GetBytes("wg-smoketest")
$pl = New-Object Collections.Generic.List[byte]
$pl.Add(0); $pl.Add(4); $pl.AddRange([Text.Encoding]::UTF8.GetBytes("MQTT"))
$pl.Add(4); $pl.Add(2); $pl.Add(0); $pl.Add(30)
$pl.Add([byte]($cid.Length -shr 8)); $pl.Add([byte]($cid.Length -band 0xFF)); $pl.AddRange($cid)
$pkt = New-Object Collections.Generic.List[byte]
$pkt.Add(0x10); $pkt.Add([byte]$pl.Count); $pkt.AddRange($pl)
Send-Bin $mqtt $pkt.ToArray()
$r = Recv $mqtt 8000
if ($r.Data[0] -ne 0x20 -or $r.Data[3] -ne 0) { throw "mqtt: bad CONNACK: $([BitConverter]::ToString($r.Data))" }
Write-Host "PASS mqtt: CONNECT accepted by broker.emqx.io (CONNACK success)"

# SUBSCRIBE itools/chat/<room> qos0, packet id 7
$tp = [Text.Encoding]::UTF8.GetBytes("itools/chat/$room")
$pl = New-Object Collections.Generic.List[byte]
$pl.Add(0); $pl.Add(7)
$pl.Add([byte]($tp.Length -shr 8)); $pl.Add([byte]($tp.Length -band 0xFF)); $pl.AddRange($tp)
$pl.Add(0)
$pkt = New-Object Collections.Generic.List[byte]
$pkt.Add(0x82); $pkt.Add([byte]$pl.Count); $pkt.AddRange($pl)
Send-Bin $mqtt $pkt.ToArray()
$r = Recv $mqtt 8000
if ($r.Data[0] -ne 0x90) { throw "mqtt: expected SUBACK, got $([BitConverter]::ToString($r.Data))" }
Write-Host "PASS mqtt: SUBSCRIBE acked"

# PUBLISH JSON to room topic, expect echo back on our subscription
$body = [Text.Encoding]::UTF8.GetBytes($json)
$pl = New-Object Collections.Generic.List[byte]
$pl.Add([byte]($tp.Length -shr 8)); $pl.Add([byte]($tp.Length -band 0xFF)); $pl.AddRange($tp)
$pl.AddRange($body)
$pkt = New-Object Collections.Generic.List[byte]
$pkt.Add(0x30)
$rem = $pl.Count
do { $bb = [byte]($rem % 128); $rem = [math]::Floor($rem / 128); if ($rem -gt 0) { $bb = $bb -bor 0x80 }; $pkt.Add($bb) } while ($rem -gt 0)
$pkt.AddRange($pl)
Send-Bin $mqtt $pkt.ToArray()
$r = Recv $mqtt 8000
if (($r.Data[0] -band 0xF0) -ne 0x30) { throw "mqtt: expected PUBLISH echo, got $([BitConverter]::ToString($r.Data))" }
# parse: skip remaining len (assume < 128), skip topic
$i = 1
while (($r.Data[$i] -band 0x80) -ne 0) { $i++ }; $i++
$tl = ($r.Data[$i] -shl 8) -bor $r.Data[$i+1]; $i += 2
$topic = [Text.Encoding]::UTF8.GetString($r.Data, $i, $tl); $i += $tl
$payload = [Text.Encoding]::UTF8.GetString($r.Data, $i, $r.Data.Length - $i)
if ($topic -ne "itools/chat/$room") { throw "mqtt: wrong topic $topic" }
if ($payload -ne $json) { throw "mqtt: payload mismatch: $payload" }
$mqtt.Abort()
Write-Host "PASS mqtt: PUBLISH roundtrip on itools/chat/<room>"

Write-Host "ALL SMOKE TESTS PASSED"
