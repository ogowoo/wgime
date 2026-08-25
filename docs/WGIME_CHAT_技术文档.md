# WgIme Chat 扩展技术文档 —— ITools Chat 系统全解析

> 版本：2026-08-25 ｜ 读者：要在 WgIme 中实现/扩展聊天插件（与 itools-chat 互通）的工程师或 Agent
> 信息来源：`C:\Tools\itools-chat`（Chat.bat / cloudflare worker）、`C:\Tools\itools-chat-android`（Kotlin app）实际代码逐行提取；`ITOOLS_ARCHITECTURE.md` 等仓库内文档**部分内容已过时**，一律以本文为准。
> 相关文档：`docs/WGIME_插件规范.md`（插件运行机制）、`docs/WGIME_窗体设计语言.md`（UI 规范）

---

## 目录

1. [系统总览](#1-系统总览)
2. [传输层](#2-传输层)
3. [应用层消息协议](#3-应用层消息协议)
4. [加密规范](#4-加密规范)
5. [文件/图片传输](#5-文件图片传输)
6. [Active Rooms 注册表](#6-active-rooms-注册表)
7. [各端实现要点](#7-各端实现要点)
8. [WgIme chat 扩展指南](#8-wgime-chat-扩展指南)
9. [附录](#9-附录)

---

## 1. 系统总览

### 1.1 组件清单

| 组件 | 位置 | 技术栈 | 角色 |
|---|---|---|---|
| PC 聊天端 | `itools-chat\Chat.bat`（也内嵌于 `ITools.bat` 的"实用工具→聊天"页） | batch + PowerShell 5.1 + C#（PDFBridge）+ WebView2 内嵌 HTML/JS（Paho MQTT + crypto-js） | 功能最全的参考实现 |
| Android 聊天端 | `itools-chat-android\android\` | Kotlin + Jetpack Compose + Paho MQTT 1.2.5 + OkHttp WebSocket + webrtc-sdk 125.6422.07 | 手机端，v2.0 原生重写（已弃用 WebView/chat.html 旧方案） |
| Cloudflare Relay | `itools-chat\cloudflare\worker.js`（45 行） | Cloudflare Worker + Durable Objects | 私有极简中继 `wss://chat.seee.uno`，每房间一个 DO 广播 |
| 公共 MQTT broker | 第三方公共服务（EMQX / HiveMQ / Mosquitto） | MQTT 3.1.1 over WebSocket / TCP / TLS | 无服务器组网的核心 |
| WgIme chat 插件 | `WgIme\plugins\chat.txt` | WgIme C# 插件（WinForms） | **2026-08-25 已重写**：relay/MQTT 双模式互通（M1+M2 完成），见 §8.2 |

### 1.2 三种组网模式

```
模式 A：公共 MQTT broker（默认，跨互联网）
  Client ──MQTT over WS/TCP──► 公共 broker ──► Client
  支持：全部功能（聊天/文件/注册表/P2P 信令）

模式 B：Cloudflare 私有 relay（wss://chat.seee.uno）
  Client ──WebSocket 裸 JSON──► Worker DO(房间) ──广播──► 同房间其他 Client
  支持：聊天/文件/P2P 信令；不支持：Active Rooms 注册表（房间隔离）

模式 C：LAN-only 纯局域网（不连任何服务器）
  Client ──UDP 20003 广播/组播/单播──► 同子网 Client
  支持：明文聊天/文件；不支持：加密、typing、注册表

叠加层：P2P 直连（任意模式下自动建立，建立后消息绕过服务器）
  WebRTC DataChannel（跨 NAT，STUN-only）
  UDP 单播打洞（企业内网 / 公网映射，端口 20003）
  LAN-TCP 直连（仅 PC 端实现）
```

### 1.3 功能矩阵

| 功能 | PC Chat.bat | Android | WgIme 插件（2026-08-25 重写后） |
|---|---|---|---|
| MQTT broker 模式 | ✅ 5 broker 自动兜底 | ✅ 5 broker 自动兜底 | ✅ 同 5 broker auto 兜底 + 记住上次成功项 |
| Cloudflare relay 模式 | ✅ 裸 JSON | ✅ 裸 JSON | ✅ 裸 JSON 文本帧（按 broker 地址自动识别） |
| LAN-only 模式 | ✅ | ✅ | ✅（beacon/组播/子网扫描/lan-msg/文件 3000 字符块） |
| AES 加密聊天 | ✅ | ✅ | ✅（crypto 实现正确） |
| join/leave/online | ✅ 收发 | 收 only（不发 leave/online） | ✅ 收发 |
| typing 提示 | ✅ | ❌ | ✅（已补 ts 字段） |
| quote 引用 | ✅（嵌套 ≤4 层） | ✅ | ✅（双击引用，嵌套 ≤4 层单行拍平显示） |
| 文件/图片传输 | ✅ | ✅ | ✅（内存路径 ≤2MB，含 gap 检测/重发/超时） |
| Active Rooms 注册表 | ✅（MQTT 模式） | ✅（MQTT 模式） | ✅（MQTT 模式，双击切换房间） |
| WebRTC P2P | ✅ 单 peer | ✅ 单 peer | ❌ |
| UDP LAN/打洞 | ✅ | ✅ | ❌ |
| LAN-TCP 直连 | ✅ | ❌ | ❌ |
| 消息持久化 | ✅ 每房间 80 条 | ✅ 每房间 80 条 | ✅ 每房间 80 条（`chat-history.txt`） |
| 断线自动重连 | ✅ 6s×3 | ✅ 3s | ✅ 6s×3 |

---

## 2. 传输层

### 2.1 MQTT over WebSocket（模式 A）

**PC 端 broker 列表**（`Chat.bat`（`feature/chat-standalone` 分支）内 `var brokers=[...]`，自动模式按序轮询，从 localStorage `itools-chat-broker` 记录的上次成功项开始）：

> ⚠️ itools 仓 **master 分支的 ITools.bat** 内嵌聊天是**旧版**：brokers 只有 EMQX/Mosquitto/HiveMQ，**没有 Cloudflare relay**。relay 互通要用独立版 Chat.bat（chat-standalone 分支）或 Android app。

| # | 名称 | host | 端口 | TLS | 备注 |
|---|---|---|---|---|---|
| 0 | Cloudflare | `wss://chat.seee.uno` | — | wss | `cf:true`，**不是 MQTT**，走 relay（见 §2.2） |
| 1 | HiveMQ-TLS | broker.hivemq.com | 8884 | ✅ | |
| 2 | EMQX | broker.emqx.io | 8084 | ✅ | |
| 3 | Mosquitto | test.mosquitto.org | 8081 | ✅ | |
| 4 | HiveMQ | broker.hivemq.com | 8000 | ❌ | 纯 ws |

> 注：Flespi（mqtt.flespi.io:443，token 认证）已在 commit `df236ec` 移除；早期文档中的记载已过时。

**Android 端 broker 列表**（`ChatProtocol.BROKERS`，Paho 原生 tcp/ssl URI）：

| # | 名称 | URI | 备注 |
|---|---|---|---|
| 0 | Cloudflare | `wss://chat.seee.uno` | `relay=true`，走 RelayClient |
| 1 | HiveMQ-TLS | `ssl://broker.hivemq.com:8883` | |
| 2 | HiveMQ | `tcp://broker.hivemq.com:1883` | |
| 3 | EMQX | `tcp://broker.emqx.io:1883` | |
| 4 | Mosquitto | `ssl://test.mosquitto.org:8883` | |

**跨端互通要点**：两端连上**同一个公共 broker**即可互通（如 PC 走 `wss://broker.emqx.io:8084`、Android 走 `tcp://broker.emqx.io:1883`，是同一台 broker，topic 一致即通）。

**连接参数**：

| 参数 | PC | Android |
|---|---|---|
| WebSocket 路径 | 固定 `/mqtt`（`new Paho.MQTT.Client(host, port, '/mqtt', clientId)`） | N/A（Paho tcp/ssl 直连） |
| **WS 子协议** | **`mqtt`**（Paho 自动携带；EMQX 缺子协议返回 400、Mosquitto 直接断连——手写 WS 客户端必须 `AddSubProtocol("mqtt")`） | N/A |
| MQTT 版本 | 3.1.1（Paho 默认） | 3.1.1 |
| clientId | = docId（见 §3.1），每次 join 重新生成 | = docId，每次启动生成 |
| cleanSession | true | true |
| keepAlive | 30s | 30s |
| 连接超时 | 10s | 10s |
| QoS | 恒 0，非 retained | 恒 0 |
| 断线重连 | 6s 后重试，最多 3 次 | 3s 后重试 |
| 认证 | 支持 userName/password 字段（当前 broker 均未配置） | Broker data class 含 user/pass（未使用） |

**Topic 命名**（仅两个模板）：

| 用途 | Topic | 说明 |
|---|---|---|
| 房间（聊天+文件+P2P 信令共用） | `itools/chat/<room>` | `<room>` 为用户输入原文，**不做 URL 编码** |
| 房间注册表 | `itools/registry/rooms` | 全局唯一，所有 MQTT 客户端订阅（见 §6） |

### 2.2 Cloudflare Relay（模式 B）—— **WgIme 扩展的最短路径**

**Worker 行为**（`cloudflare/worker.js` 全文 45 行，`wrangler.toml` 绑定 DO `ROOMS`→class `Room`）：

- `GET /` 或 `/health` → `200 "ITools Chat Relay OK"`；其他非 `/room/` 路径 → 404
- `/room/<room>`：`decodeURIComponent` 取房间名（空 → `"default"`），`env.ROOMS.idFromName(room)` 每房间一个 Durable Object
- Room DO：非 WebSocket Upgrade 请求 → 426；否则 `WebSocketPair` + **Hibernation API**（`state.acceptWebSocket`，空闲休眠、免费层友好）
- `webSocketMessage`：**原样扇出给房间内所有其他 socket（不回显发送者）**
- **无鉴权、无状态、无消息解析**——relay 对载荷完全透明，文本/二进制都照转

**客户端协议**（PC `chatCfConnect` / Android `RelayClient`，两端一致）：

- URL：`wss://chat.seee.uno/room/` + `encodeURIComponent(room)`
- **线格式 = WebSocket 文本帧，内容就是一条消息 JSON 原文**（与 MQTT 房间 topic 里跑的 JSON 完全相同）
- 没有 MQTT 帧、没有 CONNECT/CONNACK/SUBSCRIBE——连上即可直接收发 JSON
- PC 端实现方式：伪造一个 Paho 接口对象（`send` 直接 `ws.send(m.payloadString)`，`subscribe` 空操作，topic 参数被忽略）
- Android 端：OkHttp `newWebSocket`，`pingInterval 25s`；`onMessage(text)` 喂给 `handleMessage("relay", text)`
- 断线：非主动关闭 → 3s（Android）/ 6s（PC）后重连

**relay 模式下的功能裁剪**（两端一致）：Active Rooms 注册表禁用（房间隔离，无共享 registry topic；👥 按钮禁用）；WebRTC/WAN 打洞/LAN-TCP 信令仍走房间 WS，功能保留。

### 2.3 LAN-only 纯局域网模式（模式 C）

- join 时勾选 "LAN Only"：不连任何 broker；`lanDocId = 'lan-' + Date.now().toString(36)`
- **UDP 端口 20003**：IPv4 + IPv6 双栈持久监听（SO_REUSEADDR，4MB 接收缓冲）；另起 multicast 监听 `224.0.0.251:5353`（仅入队含 `"type":"lan-` 的包）
- 收包分类：首字节 `0x7b`（`{`）→ 聊天 JSON 队列；否则进 STUN 响应队列。队列上限 5000/2000，满丢最旧
- **lan-beacon**（对端发现在线名单的唯一依据）：`{"type":"lan-beacon","room","nick","id"}`，每 **2s** 三路发送：
  1. UDP 广播 `255.255.255.255:20003`（临时 socket）
  2. multicast `224.0.0.251:5353`
  3. 单播所有已知 `unicastPeers`
- 子网扫描：每 **30s** 对每个 up 的 IPv4 接口按掩码枚举单播（上限 512 主机/接口，从持久 socket 发出以打开防火墙回包路径）
- 房间扫描：`{"type":"lan-room-query","nick","id":"scan-..."}` 广播，收到者单播回 beacon；beacon 里的 room 进入可点击的房间列表
- 消息：`{"type":"lan-msg","room","nick","text","ts","id","quote"}` —— **明文不加密**，经广播+组播+单播发送；按 `room` 过滤，按 `id:ts` 去重
- 文件：file-start/file-chunk（**3000** 字符块，file-start 连发 3 次 0/60/120ms 抗丢包），无 file-end/resend
- 无 join/leave/online/typing/registry

> ⚠️ Android 端 lan-beacon 的 `room` 字段带 `itools/chat/` 前缀且多一个 `port:20003` 字段（例：`{"type":"lan-beacon","room":"itools/chat/blue-nova-123","nick":"Alice","id":"lan-lx9zz","port":20003}`），PC 端是不带前缀的房间名。**兼容实现解析 beacon 时应两种都接受**（去前缀后再比较）。

### 2.4 P2P 直连通道（叠加层）

**WebRTC**（PC + Android 均有，跨 NAT）：

- DataChannel：label = `"chat"`，`{ordered:true}`；DC 上跑与 MQTT 相同的消息 JSON（chat/file-start/file-chunk/file-end/file-resend）
- STUN：PC 用 5 个 Google STUN（`stun:stun.l.google.com:19302` ~ `stun4`）；Android 用前 2 个。**均无 TURN**（对称 NAT 失败）
- 信令走房间 topic/relay（无独立 topic）：收到他人 join 且未有 p2p → createOffer → 发 `rtc-offer`；应答 `rtc-answer`；ICE `rtc-ice`
- ICE 过滤：跳过 mDNS（candidate 含 `.local`）；PC 在 gathering 结束后主动注入真实局域网 IP host candidate
- 未 setRemoteDescription 前的 ICE 缓存 `pendingIce`
- **两端都只有一对 pc/dc，多 peer mesh 未实现**（`chatS.mpcs`/`directPeers` 仅引用从未赋值）
- 信令消息 PC 端不带 `to` 字段、Android 端带 `to` 字段——兼容实现应容忍两种（单 peer 假设下忽略 `to` 即可）

**UDP 打洞 / 企业内网直连**（PC + Android）：

- STUN（PC C# 手工实现 RFC 5389）：Binding Request `0x0001`，magic cookie `0x2112A442`，服务器 `stun.l.google.com:19302`（DNS 失败回退 `74.125.250.129`），3s 超时；解析 XOR-MAPPED-ADDRESS（0x0020）与 MAPPED-ADDRESS（0x0001）。经聊天 socket 发出，故映射端口即 20003 的公网映射
- 地址宣告：`udp-addr`（每 15s 重发）/ `udp6-addr` / `lan-addr`（企业内网 IP）
- 打洞：收到地址宣告后向对方每 2s 发 lan-beacon，最多 30 次；收到对方 beacon 且源 IP 匹配即建立直连，之后聊天改走 UDP 单播（仍是**加密** JSON）
- IPv6 过滤：排除 fe80/::1/fc/fd/2001:0:/2002: 前缀（Android 的 `globalIpv6()` 已实现但**无调用点**）

**LAN-TCP**（仅 PC）：`LanStartServer()` 监听 `TcpListener(Any,0)` 随机端口，房间 topic 发 `lan-tcp{host,port,id}`，对端 `LanConnect` 连接。**消息以 `\n` 分帧的行 JSON**。

**发送路由优先级**（PC，`chatSend` 文本 vs `chatSendRaw` 其他消息，两处顺序不一致——文本优先 LAN-TCP、文件优先 DC）：

```
chatSend（文本）:  LAN-TCP → WebRTC DC → corpPeer → wanUdp6 → wanUdp → MQTT/relay
chatSendRaw（文件/信令）: WebRTC DC → LAN-TCP → corp → wan6 → wan4 → MQTT/relay
Android sendRaw:   LAN 广播 → UDP 单播 → WebRTC → MQTT/relay
```

> ⚠️ 已知局限：直连建立后 sendRaw 不再向 MQTT/relay 发送，多 peer 房间内第三方的客户端收不到直连双方的消息（两端一致的协议层缺陷）。

---

## 3. 应用层消息协议

### 3.1 公共字段与身份

| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | string | 消息类型（见 §3.2） |
| `id` | string | 发送方 docId，**全通道回声过滤的唯一依据** |
| `nick` | string | 昵称（localStorage/SharedPreferences 持久；缺省 PC `User_`+6 位 base36 随机，WgIme `用户_`+6 位 hex） |
| `ts` | long | `Date.now()` 毫秒时间戳 |

- **docId 生成**：PC = `'itls-c' + Date.now().toString(36) + Math.random().toString(36).slice(2,6)`（每次 join 新建，兼作 MQTT clientId）；LAN-only = `'lan-' + ts36`；打洞 beacon 加前缀 `wan-`/`corp-`；房间扫描 `scan-`；WgIme 插件现用 `'wg-' + 10位hex`。**任何唯一字符串均可**，前缀仅作来源识别
- "You/我" 标记：纯 UI 层——发送方本地先把消息以 isMe=true 上屏，**网络层没有 you 字段**
- 自己回声过滤：`id === 自己的 docId` → 丢弃（relay 不回显，MQTT broker 会回显）

### 3.2 消息类型总表

MQTT 房间 topic / Cloudflare relay / WebRTC DC / UDP 单播上跑的是**同一套 JSON**（LAN-only 的 lan-* 系列除外）：

| # | type | 方向 | JSON 示例 | 说明 |
|---|---|---|---|---|
| 1 | `join` | 发/收 | `{"type":"join","nick":"Alice","ts":1735000000000,"id":"itls-clx1a2b3c"}` | 连接成功后立即发送 |
| 2 | `online` | 发/收 | `{"type":"online","nick":"Alice","ts":...,"id":"..."}` | **收到他人 join 后回应**（在线宣告）。Android 只收不发 |
| 3 | `leave` | 发/收 | `{"type":"leave","nick":"Alice","ts":...,"id":"..."}` | 主动离开时。Android 只收不发（直接断连） |
| 4 | `chat` | 发/收 | `{"type":"chat","nick":"Alice","text":"<ivHex>:<ctHex>:<hmacHex>","enc":true,"ts":...,"id":"..."}` | 正文密文，见 §4；`enc` 恒 true |
| 5 | `typing` | 发/收 | `{"type":"typing","nick":"Alice","ts":...,"id":"..."}` | 发送节流 2s；接收方 4s 后清除。Android 未实现 |
| 6 | `rtc-offer` | 发/收 | `{"type":"rtc-offer","sdp":"v=0\r\no=…","id":"itls-cA","to":"itls-cB"}` | WebRTC 信令；PC 不带 `to`，Android 带 |
| 7 | `rtc-answer` | 发/收 | `{"type":"rtc-answer","sdp":"…","id":"itls-cB","to":"itls-cA"}` | 同上 |
| 8 | `rtc-ice` | 发/收 | `{"type":"rtc-ice","candidate":{"candidate":"candidate:…","sdpMid":"0","sdpMLineIndex":0},"id":"...","to":"..."}` | 同上 |
| 9 | `lan-tcp` | 发/收 | `{"type":"lan-tcp","host":"192.168.x.x","port":52341,"id":"..."}` | PC LAN-TCP 直连宣告 |
| 10 | `udp-addr` | 发/收 | `{"type":"udp-addr","addr":"203.0.113.5:20003","id":"..."}` | STUN 公网映射宣告，每 15s 重发 |
| 11 | `udp6-addr` | 发/收 | `{"type":"udp6-addr","addr":"240e:...","id":"..."}` | 全局 IPv6 宣告 |
| 12 | `lan-addr` | 发/收 | `{"type":"lan-addr","ip":"10.0.0.5","id":"..."}` | 企业内网 IP 宣告 |
| 13 | `file-start` | 发/收 | `{"type":"file-start","nick":"Alice","sid":"itls-c...","caption":"","quote":null,"name":"a.zip","size":5242880,"id":"flx9z42","total":657}` | 见 §5 |
| 14 | `file-chunk` | 发/收 | `{"type":"file-chunk","id":"flx9z42","idx":3,"seq":3,"total":657,"sid":"itls-c...","data":"QUJD…","len":8000}` | 见 §5 |
| 15 | `file-end` | 发/收 | `{"type":"file-end","id":"flx9z42","total":657,"sid":"itls-c..."}` | 见 §5（PC 仅在 WebRTC DC 通道解析！） |
| 16 | `file-resend` | 发/收 | `{"type":"file-resend","id":"flx9z42","missing":[3,17],"room":"blue-nova-123"}` | 见 §5（同上限制） |
| 17 | `room-beacon` | 发/收 | `{"type":"room-beacon","room":"blue-nova-123","nick":"Alice","id":"itls-c...","ts":...}` | **发在 `itools/registry/rooms`**，见 §6 |

LAN-only 模式（仅 UDP，不走 MQTT/relay）：

| type | JSON 示例 | 说明 |
|---|---|---|
| `lan-msg` | `{"type":"lan-msg","room":"...","nick":"...","text":"<明文>","ts":...,"id":"lan-...","quote":null}` | 明文聊天，不加密 |
| `lan-beacon` | `{"type":"lan-beacon","room":"...","nick":"...","id":"lan-..."}` | 2s 心跳；Android 版 room 带 `itools/chat/` 前缀且多 `port:20003` |
| `lan-room-query` | `{"type":"lan-room-query","nick":"...","id":"scan-..."}` | 房间扫描 |

### 3.3 在线名单维护规则

1. 自己 join 成功 → 发 `join` → 本地把 nick 排名单第一
2. 收到他人 `join` → `users[id]=nick` → **回一条 `online`**
3. 收到 `online` → `users[id]=nick`
4. 收到 `leave` → 删除该 id
5. 自己离开 → 发 `leave` → 断连

> ⚠️ 已知怪癖：Android 不发 `leave`/`online`，PC 名单里已离开的 Android 用户会残留（无超时清理）。WgIme 扩展**应该**正常发送 leave/online（现有插件已做到）。

### 3.4 去重规则

- 聊天消息去重 key：`'m' + nick + ':' + ts`（MQTT 与 UDP 双通道同达时去重）
- `recentMsgs` 超过 300 条**整体清空**（两端一致）
- LAN-only 按 `id:ts` 去重

### 3.5 quote 引用（加密内层 payload）

- 有引用时，**加密前的明文**是 `JSON.stringify({"t":<正文>, "q":<quote>})`；无引用时明文就是纯文本
- 解密后尝试 `JSON.parse`，含字符串字段 `t` 则拆出正文与引用
- quote 结构：`{"nick":<str>, "text":<原消息前 120 字符；图片为 "[图片] name"、文件为 "[文件] name">, "thumb":<60px JPEG base64 q0.6，可选>, "file":<可选>, "q":<嵌套引用，可选>}`
- UI 渲染嵌套深度 ≤4

### 3.6 typing

- 发送：输入变化时发送，节流 2s；消息含 `ts`
- 接收：显示 "xxx 正在输入…"，4s 无更新清除
- Android 未实现（不发送也不处理）

---

## 4. 加密规范

**三端（PC crypto-js / Android javax.crypto / WgIme C#）已验证字节级一致**，WgIme 插件现有实现无需改动：

```
密钥派生:  raw = room + ":" + (customKey 非空 ? customKey : room)
           key = SHA-256(UTF-8 字节(raw))               // 单次 SHA-256，无 PBKDF2、无 salt
加密:      AES-256-CBC + PKCS#7（CryptoJS/Java/.NET 默认一致）
           IV = 16 字节密码学随机（每条消息独立）
编码:      ivHex = 小写 hex(iv)；ctHex = 小写 hex(ciphertext)
认证:      hmac = HMAC-SHA256(key, UTF-8 字节(ivHex + ":" + ctHex))   // ← 对 hex 文本做 MAC，不是原始字节！
线上格式:  text = ivHex + ":" + ctHex + ":" + hmacHex                  // 冒号三段
```

- **Encrypt-then-MAC**：解密先校验 HMAC，不等 → 返回 null（UI 显示 `[encrypted]`，可能是密钥不符）
- **无自定义密钥时 key = SHA256(`room:room`)**——即所有消息始终加密，但密钥可从房间名公开推导：**这只是混淆，不是机密性**。真正保密必须在 🔒 密钥框设置自定义密码
- **只加密聊天文本 payload（含 quote 内层）**；file-start/chunk/end 的 `data` 是**明文 base64**（两端一致）
- CryptoJS 对应调用：`CryptoJS.AES.encrypt(plain, sha256WordArray, {iv})`，`WordArray.toString()` 默认即小写 hex
- .NET 对应：`Aes.Create() { Key=key, IV=iv, Mode=CBC, Padding=PKCS7 }`；`HMACSHA256(key).ComputeHash(UTF8.GetBytes(ivHex+":"+ctHex))`

---

## 5. 文件/图片传输

### 5.1 发送双路径

| | 内存路径 | 流式路径 |
|---|---|---|
| 触发 | PC：size ≤ 8MB（8388608）**或**是图片；Android：size ≤ 10MB（10485760）或图片 | 大文件（PC >8MB、Android >10MB，非图片） |
| 读取 | 整文件读 base64 | `ReadFileChunk` / content URI 分段读 |
| **chunk 大小** | **8000 个 base64 字符**（LAN-only 3000） | **12000 原始字节**独立 base64（LAN-only 3000） |
| file-end | **不发** | 发完后发 |

> 8000（base64 字符）与 12000/3000（原始字节）均为 3 的倍数 → 各块 base64 直接拼接 = 整文件 base64，接收端无需边界处理。

### 5.2 消息时序与字段

```
发送方:  file-start ──► file-chunk × total ──► [file-end（仅流式）]

file-start: {type, nick, sid, caption, quote, name, size, id, total}
file-chunk: {type, id, idx, seq, total, sid, data, len}
file-end:   {type, id, total, sid}
file-resend:{type, id, missing:[...], room}
```

- `fid = 'f' + Date.now().toString(36) + Math.floor(Math.random()*99)`；`sid` = 发送方 docId
- LAN-only 下 file-start 连发 3 次（0/60/120ms）抗 UDP 丢包

### 5.3 接收与重发

- 校验：`sid` 匹配；`len === data.length`；`seq != null` 时要求 `seq === idx`（重发的 chunk 不带 seq）；按 `idx` 乱序入槽
- gap 检测：`received === total` 时检查空槽 → 发 `file-resend{id, missing, room}`
- 重组校验：`|b64.length − ceil(size/3)*4| ≤ expectLen/200 + 2`，不符请求全量重发
- file-end 到达且缺块 → 再发 file-resend，**最多 5 轮** → `paused`；pending 文件 **15s 超时**清理
- Android 接收上限：`total > 20000` 或 `size > 200MB` 直接拒绝
- 接收落盘：Android 非图片文件立即写入 `Android/data/<pkg>/Download/chat`（图片留内存做预览，点击另存）；PC 弹 SaveFileDialog（`SaveChatFile`）

### 5.4 限制与已知协议缺陷

- **relay 限制**：无任何直连通道（p2p/lanPeer/lanOnly/corp/wanUdp/wanUdp6）且 size > **2MB（2097152）** → 拒绝发送（两端一致）
- ⚠️ **PC 端 `file-end`/`file-resend` 只在 WebRTC DataChannel 处理器里解析**：MQTT onMessageArrived、LAN-TCP、UDP 接收循环均不处理这两种类型——纯 relay/UDP 路径下重发请求实际被丢弃（Android 端全通道处理，行为不对称）
- ⚠️ 重发方仅支持内存路径（流式文件的重发请求被跳过）
- 图片扩展名：`/\.(png|jpe?g|gif|webp|bmp)$/`
- 发送节流：DC `bufferedAmount > 8MB` 时 80ms/块，否则 3~4ms/块
- 缩略图（`ReadImageThumb`，≤320px JPEG）仅本地预览卡用，**不随消息发送**；粘贴图片命名 `paste_<ts36>.png`

---

## 6. Active Rooms 注册表

- **Topic**：`itools/registry/rooms`（QoS 0），**仅 MQTT broker 模式**（relay 模式房间隔离无此功能，LAN-only 用 lan-beacon 代替）
- Beacon：`{"type":"room-beacon","room","nick","id":docId,"ts"}`，连接后立即发 + **每 10000ms** 重发
- 接收：忽略自己；按 room 聚合 nicks 与最新 ts；**ts 超过 25000ms 未更新 → 删除房间**
- Browse 模式：房间名留空 join = 只连 broker + 订阅 registry 不进房间，从列表点房间切换
- 👥 Active Rooms 面板：当前房间显示 `(你)`，其他显示 `(N 人在线)`

---

## 7. 各端实现要点

### 7.1 PC Chat.bat（参考实现，最权威）

**架构**：WebView2 内嵌 HTML/JS（聊天逻辑主体，here-string 内，约行 1134–1367）↔ `window.chrome.webview.hostObjects[.sync].bridge` ↔ C# `PDFBridge`（行 170–1108）↔ PowerShell 宿主。JS 库（`mqttws31.js` Paho、`crypto-js.min.js`）以 base64 内嵌在 bat 尾部，运行时解到 `%LOCALAPPDATA%\itools-chat\libs\`，经虚拟主机 `https://chat.libs/` 加载。C# 编译缓存 `%LOCALAPPDATA%\itools-chat\PDFBridge.<md5前8>.dll`；WebView2 数据目录 `%LOCALAPPDATA%\itools-chat\wv2_data`。

**聊天相关 C# 桥接方法**（返回 `"ERR:..."` / `"OK..."` 约定）：

| 方法 | 用途 |
|---|---|
| `StartChatListener(port)` / `StopChatListener()` / `PollChatPackets()` | UDP 20003 持久监听（v4+v6+multicast 5353）与收包队列 `[{host,data}]` |
| `UdpBroadcast(port,payload)` / `UdpMulticast(group,port,payload)` | 广播 / 组播发送 |
| `ChatSendUnicast(ip,payload)` / `ChatSendUnicastTo(ip,port,payload)` / `ChatSendUnicast6(...)` | 持久 socket 单播（v4/v6） |
| `ChatSendSubnet(payload)` | 子网扫描（≤512 主机/接口）→ `"OK:<sent>"` |
| `StunDiscover()` / `GetGlobalIPv6()` | STUN 公网映射 `"ip:port"` / 全局 IPv6 |
| `LanStartServer()` / `LanConnect(host,port)` / `LanIsConnected()` / `LanSend(data)` / `LanPoll()` / `LanClose()` / `LanGetIP()` | LAN-TCP 直连（`\n` 分帧行 JSON） |
| `SelectAnyFile()` / `ReadFileBase64(path)` / `ReadFileChunk(path,offset,len)` / `ReadImageThumb(path)` | 文件选择与读取（`SelectAnyFile` 返回 `path+'\x1f'+size`） |
| `SaveChatFile(base64,suggestedName)` / `WriteFileBase64(base64,path)` | 收到的文件保存（对话框 / 唯一文件名） |
| `SaveChatStore(key,value)` / `LoadChatStore(key)` | 持久 KV（temp+File.Replace 原子写） |

**持久化**：WebView2 `NavigateToString` 为 null origin，localStorage 被 polyfill 到 `SaveChatStore('localStorage', ...)`；落盘 `%LOCALAPPDATA%\itools-chat\chatstore.json`（`Dictionary<string,string>` JSON）。keys：`itools-chat-nick`、`itools-chat-peerip`、`itools-chat-broker`、`itools-chat-msgs-<room>`（每房间**最近 80 条**，slim 处理：file.data=null、quote 截断；内存上限 500 条）。

### 7.2 Android app（`com.itools.chat` 扁平包，11 个 Kotlin 文件）

| 文件/类 | 职责 |
|---|---|
| `ChatApp.kt` → `ChatApp : Application` | 进程级 `ChatEngine` 单例（`by lazy`），保证连接在 Activity 重建/后台切换后存活 |
| `MainActivity.kt` | 唯一 Activity，Compose 入口；按 `connected‖browsing` 切 Welcome/Chat 两屏 |
| `ChatViewModel.kt` | 薄壳：透出 engine 的 StateFlow ×9，转发方法；`onCleared()` **显式空实现**（不销毁 engine） |
| `WelcomeScreen.kt` | 加入界面：昵称/房间/🎲/join/👥浏览模式 + "服务器 & 调试" 折叠区（broker 芯片、LAN-only 开关、密钥框） |
| `ChatScreen.kt` | 聊天界面：顶栏（房间/在线/🏠LAN·⚡直连·📡中继 指示/👥/离开）、消息 LazyColumn、emoji 面板、附件（OpenDocument 契约）、引用预览条 |
| `ChatEngine.kt`（808 行，核心） | 连接生命周期与 broker fallback、消息收发去重、在线名单、registry 心跳、文件收发重组、UDP/WebRTC 直连、sendRaw 路由、LAN-only。数据类 `Msg`/`RoomInfo`/`PendingFile`/`SentFile` |
| `ChatProtocol.kt` | 协议常量（topic 前缀、BROKERS 表）+ 加密原语（`deriveKey`/`encrypt`/`decrypt`/`packPayload`/`unpackPayload`）+ `randomRoom()`（word-word-3digits，20 词表） |
| `RelayClient.kt` | Cloudflare relay：OkHttp WebSocket，`pingInterval 25s`，裸 JSON 文本帧，topic 假值 `"relay"` |
| `UdpP2p.kt` | UDP 20003 监听/单播/广播；收包队列 `host\x1fjson`；`globalIpv6()` 未接线 |
| `WebRtcP2p.kt` | WebRTC DataChannel（label `"chat"`），STUN-only 无 TURN，rtc 信令接口回调，pendingIce 缓存 |
| `ChatStore.kt` | SharedPreferences `"chat"`：nick/room/cryptoKey（**明文存储**）/broker + `msgs:<room>` 最近 80 条（图片 fileData 持久化保缩略图） |

**构建**：minSdk 26 / targetSdk 34，AGP 8.5.2，GitHub Actions CI（secrets 签名）。无前台 Service、无保活——进程被杀连接即断。

### 7.3 Cloudflare worker（部署事实）

- 名称 `itools-chat-relay`，compatibility_date 2024-09-01，DO 迁移 tag v1
- 行为见 §2.2；部署：`cd cloudflare && npx wrangler deploy`（需 Cloudflare 账号权限）

---

## 8. WgIme chat 扩展指南

### 8.1 插件运行环境约束（摘自 `docs/WGIME_插件规范.md`）

- `[csharp]` 块，必须有类含 `public static void Run()` 入口（第一个匹配的类生效）
- `Run()` 在插件专用 STA 线程（`WgImePlugins`，独立消息循环）上调用：`new Form().Show()` 直接可用，阻塞只卡自己的窗体
- 编译引用：`System` / `System.Windows.Forms` / `System.Drawing` / `System.Core` / `System.Data` + WPF（GAC 全路径）；**C# 5 语法**（无字符串插值、无 out var、无 `?.`）
- **没有 NuGet**——一切依赖只能用 .NET Framework 4.x 自带的（`System.Net.WebSockets.ClientWebSocket` 可用，`System.Security.Cryptography` 可用）
- 现有 `plugins\chat.txt`（549 行）已具备：无边框窗体 + 圆角控件范式、WinForms 消息 UI、配置持久化（`%LOCALAPPDATA%\wgime\chat.cfg`）、**正确的加密实现**

### 8.2 现有 `plugins\chat.txt` 做了什么（2026-08-25 重写，M1+M2 完成）

- **传输分流**：broker 地址命中 `chat.seee.uno` → relay 裸 JSON 文本帧；否则 → MQTT 3.1.1 over WebSocket（路径 `/mqtt`，**携带 `mqtt` 子协议**）
- **auto 兜底**：Broker 框填 `auto`（默认）按 PC 端顺序尝试 Cloudflare→HiveMQ-TLS→EMQX→Mosquitto→HiveMQ，上次成功项持久化到 `chat.cfg` 的 `lastbroker`
- **后台连接**：连接/接收全部在后台线程（UI 经 SynchronizationContext 更新）；连接超时 10s（`Task.WhenAny` 兜底——.NET 4.x 的 token 取消对 ConnectAsync 不及时）；CONNACK 超时 8s 判失败换下一个 broker
- **MQTT 健壮性**：WS 分片按 EndOfMessage 重组、一帧多包循环解析、CONNACK 驱动订阅+加入、SUBACK/PINGRESP 忽略、QoS1/2 PUBLISH 跳过 packet id
- **消息**：join/leave/online/chat/typing 五种，chat 带 `enc:true`、typing 带 `ts`；解密失败显示 `[encrypted]`；每次加入重新生成 docId
- **Active Rooms**：MQTT 模式订阅 `itools/registry/rooms`，10s room-beacon 心跳 + 25s 过期，右栏"活跃房间"列表双击切换房间
- **重连**：意外断线 6s×3 自动重连
- **TLS**：启动时 `ServicePointManager.SecurityProtocol |= Tls11|Tls12`（EMQX/Mosquitto 要求 TLS 1.2+）
- **加密**：§4 全套，**与 PC/Android 字节级兼容** ✅
- **UI**：连接栏（昵称/房间/密钥/Broker 下拉）+ 消息列表 + 在线列表 + 活跃房间列表 + 输入栏；头部"调试"开关把原始收发 JSON 记录到 `%LOCALAPPDATA%\wgime\chat-debug.log`（排查互通问题用）

### 8.3 兼容性缺陷清单（历史记录——2026-08-25 重写已全部修复，按严重程度）

| # | 严重度 | 缺陷 | 后果 | 状态 |
|---|---|---|---|---|
| 1 | 🔴 致命 | **relay 上发 MQTT 二进制帧**：PC/Android 在 relay 上发的是**裸 JSON 文本帧**（§2.2），旧插件却发 MQTT PUBLISH 二进制帧；接收方向 PC/Android 的文本帧被旧插件 `if (MessageType != Binary) continue` 丢弃 | **与任何端双向都不互通** | ✅ 已修复（relay 走裸 JSON 文本帧） |
| 2 | 🔴 致命 | **WsConnect 在 UI 线程同步阻塞等 CONNACK**：relay 永远不会发——房间内无人说话时**永远阻塞，聊天窗冻结** | 点"加入"后窗体卡死 | ✅ 已修复（连接/接收全后台线程） |
| 3 | 🟠 严重 | **broker URL 拼接写死 `/room/<room>`**：换真 MQTT broker 会拼错路径（Paho 约定 `/mqtt`） | 模式 A 整体不可用 | ✅ 已修复（按模式分流 URL） |
| 4 | 🟠 严重 | **MQTT 接收未处理 PUBLISH QoS1 packet id、PINGRESP、多分片 WebSocket 帧** | 接真 broker 后随机丢消息/解析错位 | ✅ 已修复（EndOfMessage 重组 + 多包解析 + QoS 处理） |
| 5 | 🟡 次要 | chat 消息缺 `"enc":true` 字段 | 未来版本若校验 enc 会断兼容 | ✅ 已补齐 |
| 6 | 🟡 次要 | typing 消息缺 `ts` | 无 | ✅ 已补齐 |
| 7 | 🟡 次要 | 未实现：registry（Active Rooms）、文件/图片、quote、LAN-only、WebRTC/UDP | 功能差距 | registry ✅ 已实现；其余见 §8.4 路线 |
| 8 | 🟡 次要 | `HandleMqtt` 不解析 SUBACK/PUBACK | 鲁棒性 | ✅ 已处理（显式忽略并正确跳过包体） |

**重写中新发现的两个环境坑**（实测验证，见 `tests\chat-protocol-smoke.ps1`）：

1. **MQTT over WS 必须携带 `mqtt` 子协议**：EMQX 缺子协议返回 HTTP 400，Mosquitto 直接断连；`ClientWebSocket` 需 `Options.AddSubProtocol("mqtt")`（Paho 自动携带，所以 PC 端无感知）
2. **TLS 1.2+**：EMQX/Mosquitto 拒绝 TLS 1.0；.NET 4.x 进程建议 `ServicePointManager.SecurityProtocol |= Tls11|Tls12`

### 8.4 推荐实现路线（里程碑）

**M1 — MVP：relay 模式互通（✅ 2026-08-25 已完成）**
1. ✅ 传输分流：`brokerUrl` 命中 relay（`chat.seee.uno`）→ 走**裸 JSON 文本帧**路径
2. ✅ 修复阻塞：连接/接收全部移到后台线程，UI 更新走 `SynchronizationContext.Post`
3. ✅ 消息补齐 `enc:true`、typing 补 `ts`
4. ✅ 验证：relay 裸 JSON 文本帧扇出已由 `tests\chat-protocol-smoke.ps1` 实机验证；**双向互通（含加密互解）已由 `tests\interop\` 套件验证通过**——Node 协议参考端（按 chat-standalone Chat.bat / chat-android 源码对齐）vs 真实插件代码，relay + MQTT(EMQX) 双模式双向 PASS

**M2 — 真 MQTT broker 模式 + Active Rooms（✅ 2026-08-25 已完成）**
1. ✅ URL 规则：`wss://<host>:<port>/mqtt`；broker 表抄 §2.1 PC 版，Auto 轮询 + `lastbroker` 持久化上次成功项；**必须 `AddSubProtocol("mqtt")`**（实测 EMQX 缺它 400、Mosquitto 断连）
2. ✅ MQTT 帧健壮性：按 `EndOfMessage` 循环拼帧、一帧多包解析、CONNACK 驱动订阅、QoS0/1/2 PUBLISH 解析
3. ✅ registry：订阅 `itools/registry/rooms`，10s room-beacon 心跳，25s 过期清理，右栏"活跃房间"列表（双击切换房间）
4. ✅ 验证：`tests\interop\` MQTT 用例双向 PASS（EMQX 实机）

**M3 — quote 引用 + 文件/图片（✅ 2026-08-25 已完成）**
1. ✅ quote：发送侧明文 `{"t":...,"q":...}` 包装（§3.5），接收侧解包单行拍平显示（嵌套 ≤4）
2. ✅ 文件：内存路径（8000 base64 字符 chunk，file-start/chunk/end，≤2MB）；收端按 idx 入槽 + gap 检测 + file-resend（≤5 轮）+ 15s 超时清理；图片双击预览、文件双击保存
3. ✅ 顺带补齐消息持久化（每房间 80 条，`chat-history.txt`，加入房间自动回放）
4. ✅ 验证：`tests\interop\` 6 项断言（聊天/引用/文件 sha256 × 双向）relay + MQTT 双模式 PASS

**M4 — LAN-only 模式（✅ 2026-08-25 已完成）**
- ✅ UDP 20003 持久监听（SO_REUSEADDR）+ 255.255.255.255 广播 + 224.0.0.251:5353 组播；lan-beacon 2s 三路心跳（PC 格式：room 不带前缀）；解析时容忍 Android 带 `itools/chat/` 前缀的 room
- ✅ 子网扫描 30s（按接口掩码枚举，≤512 主机/接口）；lan-room-query 应答（单播回 beacon）；LAN 房间列表（beacon 来源，双击切换）
- ✅ lan-msg 明文聊天（按 room 过滤、id:ts 去重、支持 quote 字段）；文件传输 3000 字符块 + file-start 连发 3 次（0/60/120ms），无 file-end/resend
- ✅ 验证：`tests\interop\` LAN 用例 6 项 PASS（同机回环，真实插件代码 vs Node dgram 参考端）

**M5 — P2P（确认跳过）**：WebRTC 在 .NET Framework 插件环境无内置支持（无 NuGet），UDP 打洞价值有限——由 PC/Android 端享受 P2P 即可，插件始终有 relay/MQTT/LAN 三条可用路径。

### 8.5 互操作测试方案

| 场景 | 步骤 | 预期 |
|---|---|---|
| relay 文本互通 | PC Chat.bat → broker 选 Cloudflare → 进房间 `test1`；插件 broker `wss://chat.seee.uno` → 进 `test1` | 双向收发文本；PC 在线列表显示插件 nick |
| relay + Android | Android → Cloudflare → `test1` | 三方互发；插件发 leave 后 PC 列表移除（Android 不发 leave，其头像会残留——已知怪癖） |
| 加密 | 房间 `test1` 无密钥互发 → 密钥框设 `abc` 互发 → 一端改 `abd` | 无密钥互通（key=SHA256(`test1:test1`)）；同密钥互通；异密钥显示 `[encrypted]` |
| MQTT 模式 | PC + 插件同选 EMQX | 互通 + 👥 列表互见房间 |
| LAN-only | 同子网 PC 勾 LAN Only + 插件 LAN 模式 | 明文互通、beacon 在线列表 |
| 大文件 | PC 发 5MB 文件（relay） | 插件按块重组（PC 端 >2MB 需 P2P 才能发，纯 relay 会被 PC 拒绝——测试用 ≤2MB） |

---

## 9. 附录

### 9.1 常量速查

| 常量 | 值 |
|---|---|
| 房间 topic | `itools/chat/<room>` |
| 注册表 topic | `itools/registry/rooms` |
| relay URL | `wss://chat.seee.uno/room/<encodeURIComponent(room)>` |
| MQTT WS 路径 | `/mqtt` |
| QoS | 0（非 retained） |
| keepAlive / 超时 | 30s / 10s |
| PC 重连 | 6s × 3 次；Android 3s |
| registry 心跳 / 过期 | 10000ms / 25000ms |
| lan-beacon 间隔 | 2000ms（子网扫描 30s，≤512 主机/接口） |
| 加密 | SHA-256(room ":" (key‖room)) → AES-256-CBC/PKCS7，IV 16B，hex，`iv:ct:hmac` |
| 文件 chunk | 内存路径 8000 base64 字符；流式 12000 原始字节；LAN-only 3000 |
| 文件限制 | relay 无直连时 ≤2MB；PC 流式阈值 8MB / Android 10MB；Android 接收上限 20000 块 / 200MB；重发 5 轮；pending 15s 超时 |
| 去重 | `'m'+nick+':'+ts`，>300 清空 |
| 消息历史 | 每房间 80 条（内存 500） |
| docId | PC `itls-c…` / LAN `lan-…` / WgIme `wg-…`（任意唯一即可） |

### 9.2 端口速查

| 端口 | 用途 |
|---|---|
| UDP 20003 | 聊天 LAN/WAN P2P（beacon、单播、STUN 映射） |
| UDP 5353（组播 224.0.0.251） | lan-* 组播 |
| TCP 随机 | PC LAN-TCP 直连 |
| 8084/8081/8884/8000（WS） | 公共 MQTT broker（PC） |
| 1883/8883（TCP/TLS） | 公共 MQTT broker（Android） |
| UDP 19999 / 20001、TCP 20000+ | （ITools 主程序，非聊天：版本发现 / 资产上报 / 更新下载） |

### 9.3 存储路径速查

| 端 | 路径 |
|---|---|
| PC | `%LOCALAPPDATA%\itools-chat\chatstore.json`（localStorage KV）、`libs\`（JS 库）、`wv2_data\`、`PDFBridge.<md5>.dll` |
| Android | SharedPreferences `"chat"`（nick/room/cryptoKey/broker/msgs:<room>）；收到的文件 `Android/data/<pkg>/Download/chat` |
| WgIme 插件 | `%LOCALAPPDATA%\wgime\chat.cfg`（nick/room/key/broker/lastbroker） |

### 9.4 已知协议缺陷与坑（实现时绕开）

1. PC 的 `file-end`/`file-resend` 仅在 WebRTC DC 通道解析——relay/UDP 路径重发请求被丢弃
2. 流式文件不支持重发（重发方仅内存路径）
3. 直连建立后不再向 relay/MQTT 扇出——多 peer 房间第三方漏消息（两端一致的局限）
4. Android 不发 leave/online——roster 残留
5. 单 peer WebRTC——mesh 未实现
6. PC chatSend 与 chatSendRaw 路由优先级不一致（文本 LAN-TCP 优先、文件 DC 优先）
7. Android lan-beacon 的 room 带 `itools/chat/` 前缀且有 port 字段——解析 beacon 要宽容
8. rtc 信令 PC 不带 `to`、Android 带 `to`——单 peer 假设下忽略即可
9. Android 自定义密钥**明文**存 SharedPreferences——WgIme 插件的 chat.cfg 同样明文，注意告知用户
10. relay 无鉴权无加密（传输层只有 wss TLS）——机密性完全依赖 §4 的端到端加密，而无自定义密钥时密钥可从房间名推导（仅混淆）
11. MQTT over WebSocket 必须带 `mqtt` 子协议（EMQX 缺它 400、Mosquitto 断连）；EMQX/Mosquitto 要求 TLS 1.2+
12. PowerShell 里手写 MQTT 变长 Remaining Length 编码别用 `[int]($rem/128)`——PS 数值转换**四舍五入**而非截断（93/128 得 1），用 `[math]::Floor`；C# 的 int 除法无此坑
13. relay 模式房间名**不要带空格**：Android 用 `URLEncoder.encode`（空格→`+`），插件用 `%20`，而 worker 的 `decodeURIComponent` 不解 `+`——两端会进不同房间 DO
14. Android 端解密失败显示**空气泡**而非 `[encrypted]`（`unpackPayload("")` 怪癖）——对端空气泡=密钥不符
15. 注意 PC 有两个版本：itools **master 分支 ITools.bat 内嵌聊天无 relay**（broker 仅 EMQX/Mosquitto/HiveMQ）；`feature/chat-standalone` 分支的独立 Chat.bat 才有 Cloudflare relay（broker 0）。要 relay 互通需对方用独立版/Android

### 9.5 参考文件清单

| 文件 | 内容 |
|---|---|
| `C:\Tools\itools-chat\Chat.bat` | PC 端完整实现（聊天 JS 约行 1134–1367；C# 桥行 170–1108） |
| `C:\Tools\itools-chat\cloudflare\worker.js` / `wrangler.toml` | relay 全文 / 部署配置 |
| `C:\Tools\itools-chat-android\android\app\src\main\java\com\itools\chat\` | Android 11 个 Kotlin 文件（ChatEngine.kt 808 行为核心） |
| `C:\Tools\itools-chat\ITOOLS_ARCHITECTURE.md` | ITools 主程序架构（聊天章节部分过时，以本文为准） |
| `C:\Tools\WgIme\plugins\chat.txt` | 现有 WgIme 插件（缺陷见 §8.3） |
| `C:\Tools\WgIme\docs\WGIME_插件规范.md` / `WGIME_窗体设计语言.md` | 插件机制 / UI 规范 |
