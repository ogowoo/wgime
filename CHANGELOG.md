# 更新记录 (Changelog)

> 本文件记录 WgIme 的每次代码更新。以后任何更新都追加到本文件顶部(新版本在最上)。

---

## 2026-08-25 (chat 插件:互通性实机验证通过 + 调试日志)

- **双向互通实机验证通过**:新增 `tests\interop\` 互操作测试套件——`ref-client.js`(Node 实现的协议参考端,按 itools chat-standalone 分支 Chat.bat / feature/chat-android 分支 Android 源码逐字段对齐)+ `plugin-harness.ps1`(Add-Type 加载**真实插件代码**无界面驱动)+ `run-interop.ps1`(双模式双向断言)。relay(Cloudflare)与 MQTT(EMQX)两种模式、收发两个方向全部 PASS,含端到端加密互解
- **插件新增"调试"开关**:头部勾选后把原始收发 JSON 记录到 `%LOCALAPPDATA%\wgime\chat-debug.log`,用于现场排查互通问题
- 源码级发现(以 itools 仓 `feature/chat-standalone` 与 `feature/chat-android` 分支为准):
  - Android 端 `handleMessage` 对解密失败的消息显示**空气泡**(而非 `[encrypted]`,因 `unpackPayload("")` 返回空串)——对端看到空气泡=密钥不符
  - Android 中继 URL 用 `URLEncoder.encode`(空格变 `+`),插件用 `%20`——**relay 模式房间名不要带空格**(worker 的 decodeURIComponent 不解 `+`,会进不同房间)
  - Android 不发 leave/online(已知怪癖,在线列表会残留);Android 收到 join 会尝试 WebRTC offer(插件忽略,无影响)
  - 注意:itools **master 分支的 ITools.bat 内嵌聊天没有 Cloudflare relay**(broker 只有 EMQX/Mosquitto/HiveMQ);relay 模式只在独立版 `feature/chat-standalone` 分支的 Chat.bat 和 Android app 里有

---

## 2026-08-25 (chat 插件重写:修复致命兼容性缺陷,实现 M1+M2 路线)

### 修复的致命缺陷(此前与 PC/Android 双向都不互通)

- **relay 改发裸 JSON 文本帧**:旧版在 Cloudflare relay 上发 MQTT 二进制帧,而 PC/Android 走 relay 时发的是裸 JSON 文本帧——双向不互通的根因。现在按 broker 地址自动识别:`chat.seee.uno` 走裸 JSON 文本帧,其余走 MQTT over WebSocket
- **连接不再卡死 UI**:旧版在 UI 线程同步等 CONNACK(relay 永不发送,窗体冻结)。现在连接/接收全部在后台线程,UI 更新走 SynchronizationContext;连接超时 10s(WhenAny 兜底,.NET 4.x 的 token 取消不及时)

### MQTT 模式(真 broker,新增)

- broker URL 规则修正为 `wss://<host>:<port>/mqtt`(旧版错误拼接 `/room/<房间>`)
- **必须带 `mqtt` 子协议**(`ws.Options.AddSubProtocol("mqtt")`),否则 EMQX 返回 400、Mosquitto 断连——实测验证
- 帧解析健壮性:WebSocket 分片按 EndOfMessage 重组、一帧多包循环解析、CONNACK 驱动订阅、SUBACK/PINGRESP 忽略、QoS1/2 PUBLISH 跳过 packet id、SUBSCRIBE packet id 自增
- **auto 自动兜底**:Broker 填 `auto`(默认)按 PC 端顺序尝试 Cloudflare→HiveMQ-TLS→EMQX→Mosquitto→HiveMQ,记住上次成功项(`lastbroker` 持久化)
- **Active Rooms 注册表**:MQTT 模式订阅 `itools/registry/rooms`,10s room-beacon 心跳、25s 过期,右栏新增"活跃房间"列表,双击即切换房间
- 断线自动重连 6s×3,状态栏实时反馈

### 协议对齐

- chat 消息补 `"enc":true`、typing 补 `ts`;解密失败显示 `[encrypted]`(与 PC 端一致)
- 每次加入重新生成 docId(兼作 MQTT clientId,与 PC 端每次 join 重建一致)

### 验证

- 新增 `tests\chat-protocol-smoke.ps1`(需联网,PS 5.1):relay 裸 JSON 文本帧扇出+发送者无回显;EMQX 实机 CONNECT/CONNACK、SUBSCRIBE/SUBACK、PUBLISH 回环全通过
- 注意:TLS 需 1.2+(插件启动时 `ServicePointManager.SecurityProtocol |= Tls11|Tls12` 兜底)

### 仍未实现(后续路线 M3+)

- quote 引用、文件/图片传输、LAN-only 模式(见 `docs\WGIME_CHAT_技术文档.md` §8.4)

---

## 2026-08-24 (修复:bake 后词频/候选顺序变动)

- **根因**:bake 用 `SerializeDict` 按 code 排序重写内置表,改变了字典的键**插入顺序**;而 `BuildCharPy`/`BuildAcro`/`BuildCharWb`/`BuildReverse` 等遍历字典构建索引,结果依赖插入顺序 → bake 前后多音字简拼 key、同频候选 tie-break、五笔反查码都可能不一致
- **修复**:这些方法改为按 code 排序遍历(`OrderBy(k => k.Key, StringComparer.Ordinal)`),消除对字典插入顺序的依赖,bake 与未 bake 行为一致
- **影响面**:`BuildCharPy`(单字拼音表,决定简拼 key)、`BuildAcro`(简拼表)、`BuildCharWb`(单字五笔码,决定用户词五笔码)、`BuildReverse`(英汉反向)、`AddWubiWildcard`(五笔 z 通配)、`BuildRevWb`(反查五笔)
- 顺带:`build-wgtray.ps1` 切片行号 +6 对齐

---

## 2026-08-24 (新增 sync-dist.ps1 一键刷分发目录)

- 新增 `sync-dist.ps1`：把 config/tools/插件/码表/文档/wgime.bat 从 root 一键同步到 wg-all + release，替代手工 Copy-Item
- 同步规则：config/tools/插件 进 wg-all + release；码表只进 release；文档（`docs\WGIME_*.md`，不含 AGENTS/CHANGELOG）只进 release\docs；wgime.bat 只进 release
- 顺带修复：`release\docs\插件规范.md` 的"随附插件"说明（clock/chat/calc）与根对齐；`release\docs` 补上此前缺失的 `WGIME_TSF评估.md`；若干分发文件行尾与根统一

---

## 2026-08-24 (文档改名:插件 UI 规范 → 窗体设计语言)

- `docs\WGIME_插件UI规范.md` 改名为 `docs\WGIME_窗体设计语言.md`——该规范不止服务插件,还覆盖内置工具箱/便签/网络工具等 WgIme 家族窗体
- 同步更新所有引用:README、插件规范文档的"相关"指向、种子文本(plugins README)、WgTray/wgtray 产物

---

## 2026-08-24 (真机验证:固化码表后启动命中缓存)

### 验证通过:PrebuildCacheAfterBake 在真实 bake 流程下闭环

- 真机实测:托盘"固化码表"(未勾选删除源文件)后,`PrebuildCacheAfterBake` 当场预生成 `wgime.mb`,重启**第一次启动即命中**(`BuildDicts=2878ms`),对比此前的冷重建 9.9s
- 时间线:06:20:31 bake 写回 55MB 自包含 bat → 06:20:35 预生成 `.mb` → 06:21:09 重启命中
- 确认 `delSrc=false` 场景的幂等判断正确:保留源文件时下次启动的重复 overlay 结果等于内存字典
- 注意事项:未删除的 txt/import 仍参与缓存 md5,后续改动这些 txt 会使缓存失效回到冷重建;如需真正自包含单文件,固化时勾选"完成后删除 txt/import"

---

## 2026-08-24 (固化码表预生成缓存:覆盖"不删源文件"场景)

### 修复:不勾选删除 txt/import 时也预生成缓存

- 上一版 `PrebuildCacheAfterBake` 只在勾选"完成后删除源文件"时触发;实测用户 bake 但未勾选删除时,下次启动仍冷重建(实测 6.9s、24.4s,码表越大越慢)
- 现在**无论是否删除源文件都预生成缓存**:md5 用 `SafeRead` 读实际文件状态(删除后为空,保留则原内容),内存字典直接复用
- 依据:`AddDictLine` 覆盖(`d[k]=v`)+ `MergeUserWords` 只追加不重复,保留源文件时下次启动的 overlay 是**幂等**的,冷启动结果等于当前内存字典

---

## 2026-08-24 (固化码表后预生成 `.mb` 缓存)

### 固化后下次启动直接命中缓存(消除 ~10s 冷重建)

- 固化码表勾选"完成后删除 txt/import"时,`BakeTables` 在写回数据块并删除源文件后,新增 `PrebuildCacheAfterBake`:用 bake 后的输入计算缓存 md5,并复用当前内存字典(已含合并结果)与排序数组,直接 `SaveMb` 写 `wgime.mb`
- 下次启动 `BuildDicts` 用相同输入算出相同 md5,命中缓存,跳过 `ParseDict` + `BuildAcro` + `BuildReverse` + `BuildSorted` + Deflate 冷重建(实测冷重建约 9.8s,缓存命中约 1.6s)
- 关键一致性:`PrebuildCacheAfterBake` 对 bake 后的码表 `TrimEnd` 末尾换行,与 `Get-DictSeg` 读取数据块时 `TrimEnd` 的行为字节级一致,确保 md5 匹配

---

## 2026-08-24 (码表数据块化)

### 码表从 here-string 移到 `###WGIME_DATA###` 数据块(固化码表后启动更快)

- wgime.bat 的 5 段内置码表 here-string(`$pyData`/`$wbData`/`$ecData`/`$pyWords`/`$pyWFreq`)整体移到文件尾部的 `###WGIME_DATA###` 数据块,PS 引导层用 `Get-DictSeg` 按 `###PYDATA###` 等 segment 提取,码表不再被 `Invoke-Expression` 当作脚本逐行解析(消除固化码表后启动时扫描大 here-string 的开销)
- cmd bootstrap 改为 `$j=$s.LastIndexOf('###WGIME_DATA###')` 截断 `$p`——码表在 `$p` 之外,不参与脚本解析
- 固化码表(`BakeTables`)从 `ReplaceHereString` 改为 `ReplaceDictSeg`,写回数据块对应 segment(`###PYDATA###`/`###WBDATA###`/`###ECDATA###`),并在对话框里更新说明(数据块不参与解析,启动速度不受影响)
- `build-wgime-dll.ps1` 的 `Get-HereString` 改为从数据块取码表(`Get-DictSeg`),供 WgIme.ps1 组装
- 新增 `tests\refactor-dict-blocks.ps1`(一次性转换脚本)与 `tests\verify-dictrefactor.ps1`/`tests\verify-bake-seg.ps1`(结构校验)

### build-wgtray 修复(HEAD 遗留问题,本次 $cs 改动暴露)

- `$sliceDefs` 切片行号 +3 对齐(HEAD 时切片已与 `$cs` 失配)
- 种子精简同步:`wgtray_ps_body.txt` / `build-wgtray.ps1` / `build-wgtray-dll.ps1` 移除已删除的 clean-bin/clock 种子
- `-NoPayload`(ps1)同步 bug 修复:之前会用 nopayload 版覆盖 `wg-all\WgTray.ps1` 和 `release\WgTray.ps1`,现在按 `$out` 文件名同步到各自的 `WgTray-nopayload.ps1`

---

## 2026-08-23 (HEAD `d9a90e3`)

### 词库加载优化(针对"从缓存加载也慢"的修复)

- **缓存命中跳过 trailer 解压**:之前每次启动都解压内嵌的 28MB 压缩码表 trailer(即使 .mb 缓存命中),只为了算出 md5 判断缓存有效性。现在改为:
  - `WgImeLauncher.ComputeTrailerHash()` 只算 trailer **压缩字节**的 md5(不解压)
  - `BuildDicts` 用它作为缓存 key;命中则全程不解压,miss 才调 `ExtractDictsFull` 解压
- **WGB4 缓存格式**:词表批量块读取 + 并行建表 + `CompressionLevel.Fastest` 压缩(解压更快)
- **启动计时日志**:日志新增 `startup: LoadFreq+BuildDicts=XXXms ApplySwap=YYYms`,便于诊断
- **wgime.bat 保持 3.4MB 瘦体积**:wgime.bat 内嵌的是纯 WordBoard DLL(555KB,码表由 RunApp 参数传入),不是 WgIme.ps1 的 5.3MB 完整 DLL。用 `TrailerExtractor` 委托解耦 WordBoard 与 WgImeLauncher,bat 版不设置它,ps1 版 launcher 设置它

### 首次运行种子精简

- 自动播种的插件只保留 `tools.txt` + `plugins\README.txt` + `plugins\calc.txt`
- 移除 clean-bin / clock / chat 的自动播种(用户从 plugins\ 目录手动取用)
- config.txt 保持运行时生成(不做种子)

### chat 插件(plugins\chat.txt,输入 `lt`)

- **MQTT over WebSocket**(默认 `wss://chat.seee.uno`),与 itools-chat (chat.bat) 及手机网页互通
- AES-256-CBC + HMAC-SHA256 加密,密钥派生 `SHA256(房间:密钥)`,格式 `iv:ct:hmac`
- join / online / leave / chat / typing 消息;昵称 / 房间 / 自定义密钥 / broker 可配
- 早期版本曾用 UDP 局域网协议(已废弃,手机无法联通)

---

## 2026-08-23 (commit `12b9787`)

### clock 插件多提醒方式

- 闹钟提醒方式可选:居中弹窗 / 全屏强制休息(全屏置顶遮罩+每3秒重响+必须点确认) / 托盘气泡
- 闹钟管理界面新增"提醒方式"下拉框

---

## 2026-08-22 及更早

(见 git 历史:`git log --oneline`;此前未维护 changelog)
