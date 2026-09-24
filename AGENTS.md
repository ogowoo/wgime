# AGENTS.md — 面向 AI Agent 的项目上下文

> 本文件是给 AI Agent（及多会话）的速查上下文。接手任务时先读这里，避免重复踩坑、避免上下文失忆。
> 人类视角的说明见 README.md；逐版本记录见 CHANGELOG.md。
> **细节在 `AGENTS-DETAIL.md`**：本文件受 64KB 注入预算限制，只放"要照着做的规则"；
> 实测数字、探针清单、历史轮次的来龙去脉都在 `AGENTS-DETAIL.md`，动到相关代码时去 read 对应章节。
> **§5 记法**：`NN. 主题|硬规则` —— 一条一物理行（便于 grep / 精确定位），`|` 后为规则正文，正文内用 `;` 与 `①` 分隔要点；标识符、路径、命令一律逐字原样；`原文 §Dxx` 指向 `AGENTS-DETAIL.md` 里压缩前的完整叙述。

## 1. 项目是什么

WgIme = 免安装单文件悬浮输入法（拼音/五笔/混合/英汉词典）。每个分发文件内置两种**运行模式**：`ime`（输入法，默认）与 `tray`（纯托盘工具箱，原独立 WgTray 已收敛为此模式）。
三种形态（bat 带载荷 / ps1 带载荷 / 纯 Python），全部单文件自包含，每种都支持 ime/tray 双模式。

## 2. 关键文件与职责

| 文件 | 角色 | 注意 |
|---|---|---|
| `wgime.bat` | **C# 源码真身** + bat 版（内嵌瘦 DLL + 码表 `###WGIME_DATA###` 数据块） | 改输入法/工具箱/插件核心逻辑一律改这里 |
| `WgIme.ps1` | WgIme ps1 版（内嵌完整 DLL + 码表 trailer） | **从 wgime.bat 生成**，不要手改 |
| `build-wgime-dll.ps1` | 编译 WgIme 完整 DLL（含码表 + WgImeLauncher + trailer） | 给 ps1 版用 |
| `build-wgime-ps1.ps1` | 组装 WgIme.ps1（调 build-wgime-dll 到临时目录再 base64 嵌入） | 同步 root + release |
| `tests\rebuild-wgime-bat-payload.ps1` | **重编译 wgime.bat 的内嵌瘦 DLL**（纯 WordBoard，555KB） | 改 wgime.bat 的 `$cs` 后必须跑这个 |
| `config.txt` / `tools.txt` | 配置 / 工具箱模板 | root 与 release 同步 |
| `plugins\*.txt` | 插件（calc 种子 / clock / chat / clean-bin / qping / wgtranslate） | 三处同步 |
| `sync-dist.ps1` | **一键刷分发目录**（config/tools/插件/码表/文档/wgime.bat → release） | 改完这些文件后跑一次 |
| `release\` | 纯成品目录 | 成品 + 码表 txt + config/tools + docs + plugins，不放 build/test |
| `AGENTS-DETAIL.md` | **本文件的细节附录**（实测数字/探针清单/历史轮次来龙去脉） | 本文件有 64KB 注入上限；正文只留规则，动手前按指针去读对应章节（§D2 性能、§D3 状态速览） |

> **运行模式（ime/tray）**：wgtray 已于 2026-09 退役并收敛为 wgime 的运行模式——每个分发
> 文件(bat/ps/py)都由 `config.txt mode = ime|tray` 决定形态(缺省 ime)。C# 侧在 WordBoard 内
> 用 `TrayMode` 静态标志(读自 config)控制: tray 时 `OnLoad` 跳过 `Hook.Start()`、候选条窗体隐藏、
> 托盘菜单切工具风格、`RestartInMode()` 写 config+重启; python 侧 `main.is_tray_mode()`/`switch_mode()`
> 同样处理。托盘菜单「运行模式」切换。原 wgtray 构建脚本/文件已删(git 历史保留)。

## 3. 改动后必做的连锁动作

**改了 `wgime.bat` 的 C#（`$cs`）**：
1. `powershell -File tests\rebuild-wgime-bat-payload.ps1`（重编译 bat 内嵌瘦 DLL）
2. `powershell -File build-wgime-ps1.ps1`（重生成 WgIme.ps1 + 同步 release）
3. `Copy-Item wgime.bat release\wgime.bat`（手动同步，build 脚本不复制它）
4. 跑测试（见 §4）
5. 更新 CHANGELOG.md + 相关 docs

**改了 `config.txt`/`tools.txt`/插件 `plugins\*.txt`/码表 `py.txt`/`wb.txt`/`ec.txt`/`import_*`/文档 `docs\WGIME_*.md`/`wgime.bat`**：跑 `powershell -File sync-dist.ps1` 一键同步到 release（替代手工 Copy-Item；码表只进 release，文档只进 release\docs，WGIME_*.md 不含 AGENTS/CHANGELOG）。

## 4. 测试

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime-ps1.tests.ps1    # WgIme ps1 版（15 项）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\chat-protocol-smoke.ps1  # chat 协议冒烟（需联网）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\interop\run-interop.ps1  # chat 双向互通验证（需联网+node）
python tests\pure-state-harness.py                    # 纯 Python 版状态机 headless 回归（67 项）
python tests\pure-state-harness.py --ref HEAD~1       # 对旧版 main.py 跑同一组用例（before/after 对照）
python wgime-py-pure\tests\undefined-globals.py       # 未定义全局量静态扫描（应输出 0）
python wgime-py-pure\tests\embedded-isolation-test.py # 内嵌第三方自足性（干净环境逐个 import，14 项，§12）
python wgime-py-pure\tests\voicepack-sync-test.py     # 语音包 wrapper 协议一致性（仓库副本 vs 在用那份，13 项）
python wgime-py-pure\tests\voice-click-test.py       # 语音"点击落点"真实鼠标钩子（7 项，无桌面 SKIP，§D14）
python wgime-py-pure\tests\stream-asr-test.py        # 流式 ASR（假 SSE 服务器，22 项，§D14）
python wgime-py-pure\tests\pdf-test.py               # PDF 插件（pypdf + WinRT + UI，78 项，§D16）
python wgime-py-pure\tests\standalone-plugin-test.py # 双模式插件: 装载 + 独立运行（8 项）
python wgime-py-pure\tests\example-plugin-test.py    # 示例插件模板: 契约 + 不被装载 + 独立运行（24 项，§D29）
python wgime-py-pure\tests\tray-swap-test.py          # 托盘换图状态机回归（42 项，§43）
python wgime-py-pure\tests\voice-vad-test.py          # 语音录音 VAD 回归（31 项，§38）
python wgime-py-pure\tests\whisper-warm-test.py       # 常驻 whisper 助手回归（67 项，§38）
python wgime-py-pure\tests\sherpa-warm-test.py        # 常驻 sherpa 助手回归（74 项，§38）
python wgime-py-pure\tests\dot-mouse-test.py          # 状态提示点回归（24 项，无桌面则 SKIP，§D11.2）
python wgime-py-pure\tests\deps-test.py             # 可选依赖自检/安装（51 项，不联网，§44）
python wgime-py-pure\tests\translate-window-test.py  # 翻译插件"关窗即退/独立运行不留孤儿"（13 项，无桌面只跑结构 S，§45）
python wgime-py-pure\tests\plugin-window-test.py     # 插件管理器「结束窗口」：找窗口/关/强杀/不误伤（23 项，无桌面只跑 S，§46）
python wgime-py-pure\tests\update-test.py            # 自动更新：检查/下载/四道校验/真替换助手 + 真 dist 版本自洽（36 项，假 GitHub，§47）
python wgime-py-pure\tests\pet-overlay-test.py       # 桌面宠物浮层：穿透/不抢焦点/真透明/交互态点工具 + 三场景 + 宿主 API 路径（74 项，无桌面只跑 S，§49/§D37/§D38/§D39）
python wgime-py-pure\tests\pet-dll-plugin-test.py    # 宠物 Rust 浮层(wgpet.dll)接入: DLL 在插件旁边/ABI/导出符号/工具编码 + 真机"拉插件→再拉开合面板→关窗不留孤儿"（22 项，无桌面只跑 S，§D40）
python wgime-py-pure\tests\pyshot-plugin-test.py    # PyShot 插件: 单文件双模包装/装载零重依赖/真装载器/global 序言 A/B/独立运行(70 项，§53)
python wgime-py-pure\tests\dsl-verbs-test.py        # 步骤 DSL 动词: 新 start(拉起常驻程序且不等退出)/与 run 对照/两侧动词表不许漂移(29 项，§32)
```

- **`tests\pure-state-harness.py`（纯 Python 版状态机回归）**：真跑 `wgime-py-pure\main.py` 的**前缀**（截止到 `# ---------- 主循环: 轮询钩子事件 ----------`，真 engine + 真状态机），只把副作用出口打桩（注入/托盘/词频落盘/插件执行/启动器）；进程内把 `LOCALAPPDATA` 指到临时目录（用完删）、`WGIME_DICT_DIR` 默认 `wgime-py-pure\package\dicts`（无则仓库根），**用户真实的 `%LOCALAPPDATA%\wgime-py` 绝不读写**（脚本会断言 `DATA_DIR` 在临时目录内，否则退出码 2）。改上屏路径/状态机（`commit`/`record_commit`/`handle`/`handle_punct`/`refresh`）后跑它。首跑会打印一条 `[wgime] dict-cache load failed`（隔离目录无缓存）属正常。

- **测试要自足、且不许被"现场"干扰**（第七十六轮两条实证）：① 机器绝对路径/外部 fixture 一律**现造**
  （`stream-asr-test.py` 曾写死 `...\portable\test-zh.wav` —— 本机没这文件就整份全红，且末行 `SEEN[-1]` 直接
  `IndexError` 崩掉而不是 FAIL；现在自己搓 0.2s wav 到 `%TEMP%`，`PURE` 从 `__file__` 推）；② 被测代码读**真实
  输入**（物理鼠标键/真实光标，如 `_dot_tick`）时，断言里必须**打桩**，否则屏幕前的人一点鼠标就假红 ——
  桩要在段尾还原，且顺带补一条"输入真的变了就重画"的正向断言（只测"没动就不动"是靠环境恰好不动蒙过的）。
- 测试需要 Windows PowerShell 5.1（`powershell.exe`，不是 pwsh）。
- 测试会启动真实 IME 进程，可能被**单实例锁**影响；失败时先杀掉残留的 powershell 进程（`Get-CimInstance Win32_Process | ? CommandLine -match 'WgIme' | % { Stop-Process $_.ProcessId -Force }`），清理 `%LOCALAPPDATA%\wgime\WgIme.*.dll` 和 `wgime.mb` 缓存后重跑。
- schtasks 相关断言在无交互会话会 SKIP（已处理）。

## 5. 关键约束（踩过的坑）

1. 行尾|`wgime.bat` 须 CRLF 无 BOM(`.gitattributes eol=crlf`: 仓库存 LF、checkout 转 CRLF). build 脚本内部用 LF、写出转 CRLF. 勿用 `-text`(否则 blob 存 LF,他人 clone 后 cmd 解析失败).
2. 编码|`wgime.bat` UTF-8 无 BOM(C# 内中文直用). `.ps1` 构建脚本须 ASCII(PS 5.1 按 ANSI 读),非 ASCII 入 UTF-8 模板文件; 测试脚本同 ASCII.
3. 提交消息|含 `>`/`▶`/中文者用 `git commit -F 文件`,勿用 `-m`(毁 PowerShell 解析).
4. 大件推送|39MB ps1 或 HTTP 408,先 `git config core.compression 0`.
5. 码表 txt|`py.txt`/`wb.txt`/`ec.txt`/`import_*` 已入库跟踪(根目录=构建源); `build-wgime-dll` 亦用其生成 trailer.
6. 瘦 DLL 陷阱|`build-wgime-dll.ps1` 产完整 DLL(含码表+launcher,5.3MB),只给 WgIme.ps1; `wgime.bat` 内嵌须纯 WordBoard(555KB),必用 `tests\rebuild-wgime-bat-payload.ps1` 生成,否则涨到 9.6MB.
7. WordBoard 解耦|WordBoard 不硬引用 WgImeLauncher,用 `TrailerExtractor` 委托字段; bat 版不设(码表走 RunApp 参数),ps1 版 launcher 设之. 保持此解耦.
8. 种子|首播只留 `tools.txt`+`plugins\README.txt`+`plugins\calc.txt`(三段 here-string: `$seedTools`/`$seedPluginReadme`/`$seedCalc`). `config.txt` 由运行时 C# `DefaultConfigText()` 生成,非种子.
9. 自启|程序不自带(无 `-Install`/无计划任务/无菜单自启项); 用户自挂任务或启动文件夹.
10. 码表数据块(wgime.bat)|`###WGIME_DATA###` 居文件尾(`###WGIME_DLL###` 之前),段标 `###PYDATA###`/`###WBDATA###`/`###ECDATA###`/`###PYWORDS###`/`###PYWFREQ###`. PS 引导层 `Get-DictSeg` 按 `###NAME###`+下一个 `\n###` 提取,码表不参与 PS 解析(免 Invoke-Expression 扫大 here-string). cmd bootstrap 用 `$j=$s.LastIndexOf('###WGIME_DATA###')` 截断 `$p`,须 LastIndexOf(marker 亦见于 bootstrap 行与注释,IndexOf 定位错). 固化 `BakeTables` 用 `ReplaceDictSeg(bat,"PYDATA"/"WBDATA"/"ECDATA",…)` 写回; `build-wgime-dll.ps1` 用同名 `Get-DictSeg` 取码表.
11. 字典遍历须排序|.NET `Dictionary` 遍历序=键 hash+插入序; bake 的 `SerializeDict` 按 code 排序重写会改插入序. 凡 `foreach (var kv in <字典>)` 建序敏感索引/表者(`BuildCharPy`/`BuildAcro`/`BuildCharWb`/`BuildReverse`/`AddWubiWildcard`/`BuildRevWb`)须 `.OrderBy(k => k.Key, StringComparer.Ordinal)`,否则 bake 前后多音字简拼 key、同频候选 tie-break 不一.
12. 内嵌第三方|零 pip 依赖. 进程内不 import `uiautomation`/`comtypes`(光标跟随走 §17 helper). 机制: `build-wgime-pure.py` 收源码打 zip→运行时解压 `%LOCALAPPDATA%\wgime-py\site`+`zipimport`. 规则: ①`m.ispkg` 分「包/单模块」(否则同名模块+包崩); ②依赖收传递闭包(读 METADATA `Requires-Dist`,BFS),漏则回退宿主 site-packages(被「构建机恰好装了」盖住); ③roots 只留 `pystray`,`_THIRD_SKIP` 每条写因; ④C 扩展不内嵌(`.pyd` 绑解释器 ABI),只「可用则用、不可用降级」. 守卫: 构建期 `verify_thirdparty_isolation()`(`python -S -E`+只挂该 zip,失败中止构建)、回归 `tests\embedded-isolation-test.py`(改清单必跑,断言清单正好). 本机构建装 `pystray`+`pillow`+`pypdf`. 原文 §D25; 边界 §D13/§D16.
13. Store Python 虚拟化|Store 版 python(`...\Microsoft\WindowsApps\...PythonSoftwareFoundation...`,AppContainer)写 `%LOCALAPPDATA%` 被重定向到 `...\Packages\<pkg>\LocalCache\Local\`,致真实 `%LOCALAPPDATA%\wgime-py` 不存在. 修: `main.py` 启动探针(建目录看 realpath 是否含 `\packages\`+`\localcache\`)命中则 `DATA_DIR` 切 `os.path.expanduser('~')\wgime-py` 并搬旧数据; `build-wgime-pure.py` preamble(`_third_dir`)同办. 改此逻辑须同步两处且判据一致.
14. 字频排序(有意保留)|用 `word_freq`(语料先验)+`fb`×`learn_k`+`freq_recent`×`recent_k`,胜 C# 仅按 `fb`,勿「对齐」回 C#. 配套: ①仅「主动选择」(非默认第1位/非动态)才学全量词频+LastPick 置顶,空格确认默认词不强化; ②上屏后退格删除即 `unlearn` 回滚(词频/LastPick/近期窗); ③`config.txt` 的 `learnk`(默认5000)/`recentk`(默认200) 可调; ④`freq_recent` 滑窗 RE_CAP=500,上屏即计、溢出过期. learn/save 递增/上限/保存前20000/flush 同 C#.
15. 候选条宽度上限|封顶 `max(240, min(屏幕工作区宽-24, 880px))`(880 出自 `199f0bd`,勿改回 720 或铺满屏). 超限时 `bar.show()` 逐级退化: 每条挂提示→只选中那条挂→只挂译文→只剩词; 绝不把 `(imya)` 切成 `(imya…`,唯词本身过长才截词+`…`. 余候选仍可见、可数字键选. 改 `bar.py` 渲染时守此.
16. Manifest+权限(wgime-py-pure)|`.txt` 头部/`.py` 模块级字段 `code/name/desc/version/author/requires/perm`(`.py` 另 `STANDALONE = True`=双模式,见规范 §8.7),`plugins.py plugin_meta()` 统一读. `perm` 为逗号多值表(`network,run`),命中 `network/run/registry/destructive` 者运行前 `main._confirm_plugin()` 弹确认,`run_steps` 于 `file-del/reg-set/reg-del/kill` 前强确认; 缺字段默认 `perm=low` 不弹. txt 登记条件: `code`/`name` 非空且 `body.Count > 0` —— 仅头部的半成品不算插件(`error='no body'`); 头部解析遇首个非头部行即止. 隔离: `[python]` 块走子进程+JSON IPC(超时60s; `handle(ctx)->actions`,stdout `@wgime <json>` 行协议); `run`/`shell` 超时120s、静默块300s; 勿改回同进程 `exec`. 禁用名单 `plugins-disabled.txt`=小写文件名: `main.load_py_plugins`/`plugins.load_plugins`/`main._read_disabled` 三处皆小写比较,勿改按 code 过滤(否则启停对 .py 无声失效). 原文 §D24.
17. 光标跟随=独立 Caret Helper 子进程(wgime-py-pure)|`followcaret` 默认 0 并冻结(§D10): 不起 helper,`_caret_follow()` 是唯一读取点,整链未删,改 1 或点托盘即恢复. 主进程**绝不**初始化 COM/UIA(helper 崩会拖垮键盘 hook; 勿改进程内跑,勿恢复鼠标跟随). helper 源码 `_EMBEDDED_CARET_HELPER`(纯 ctypes 直调 `UIAutomationCore` vtable)走**环境变量 `WGIME_CARET_HELPER_SRC`**(不落盘 .py、不进进程命令行; **勿改回**「落盘+`Popen([...,path])`」或塞 `-c`),引导脚本先剥 `''`/`.`/cwd 再 `os.environ.pop` 取源执行,`subprocess.Popen([sys.executable,'-u','-c',_HELPER_BOOTSTRAP], env=…)`+CREATE_NO_WINDOW 常驻,JSONL IPC(`request_caret_refresh`→`{id,reason,hwnd}`,reader 校验 `hwnd==请求窗口==当前前台`). `bar.show()` 每键刷新; 定位先 `get_ipc_caret()`,无则窗口锚点/可见位兜底,35/80ms 后 `_ipc_reposition` 贴精确位; `get_caret_pos()` 链: UIA 缓存→GUITI(rcCaret)→聚焦框→last→前台原点. 工作区: 跟随用**光标所在显示器**(`win.workarea_at()`)、带宽上限取**主屏**(`win.screen_workarea()`),`y+h` 超下界翻到上方、x 钳进工作区. `_start_helper` 连续秒退 3 次不再重试(`_helper_fail`). 原文 §D41(实测证据 §D10 与 CHANGELOG 第三十八/四十三/四十四轮).
18. 可配置键|`hotkey_toggle/mode/makeword/trad`+`key_first/pageup/pagedown/back/cancel/raw/pickfirst/picklast`. C# 在 `KeyBordHook`(`VkFromName`/`ParseHotkey`/`SetKeyConfig`/`MatchMods`); python 在 `hook.py`(`vk_from_name`/`parse_hotkey`/`configure`/`_rebuild_swallow`+`HOTKEYS`/`KEYS`),由 `main.apply_config()` 用 `CFG['hotkeys']`/`CFG['ckeys']` 安装(`engine.load_config` 只原样收,缺省在 hook),`main.handle()` 分派全读 `hook.KEYS`. 要义: `none`=禁用(0); 无效值忽略守缺省; `hotkey_toggle` 非 `shift_tap` 时 Shift 轻拍停用; 热键于「未激活」亦生效(C# 判于 IsLocked 之前); 组字中吞的候选键=配置键+PgUp/PgDn 常驻. 勿写死回 `VK['SPACE']`.
19. 单实例(wgime-py-pure)|`win.single_instance('WgImePySingleInstance')`(ctypes 命名互斥体,句柄存 `main._SINGLETON` 保活)+`win.message_box`(纯 Win32 弹窗,启动早期不建 tk); 已有实例则提示并 `sys.exit(0)`. 名带 `Py` 后缀,与 C# `WgImeSingleInstance` 互不扰; 测试用 `WGIME_NO_SINGLETON=1` 跳过.
20. 联想开关须真生效|`engine.assoc_enabled`(由 `main.apply_config` 同步自 `CFG['assoc']`)同管学习(`learn_assoc` 提前返回)与显示(`get_assoc` 返空+`main.show_assoc` 提前返回),对齐 C# `AssocEnabled`. 昔只翻勾选、照学照显,是 bug.
21. 反查编码方向|C# `CodeHint`=五笔模式显拼音码、余模式显五笔码. python 用 `engine.build_rev_wb`(按码 ordinal 升序扫、每词取最小码,同 C# `BuildRevWb`)+`Engine.rev_wb_code()` 后台建表: 首次用绝不同步建(`showcode=1` 是出厂默认,同步建令每次启动首键卡 1326ms); 未建好返 `None`,`warm_rev_wb()` 起后台线程,`_invalidate_rev_wb()` 于 `_build()`/造词改 wb 时失效(§6). 唯一入口 `main._with_code`.
22. ec 只入词典模式(mode 3)|mode 0/1 绝不查 ec(打 `no` 会串出「不/没有/无」并顶掉「弄/浓/农」). 词典模式 EN 前缀须给每个命中词的全部释义,非只取首. 第十七轮已核对勿再「修」: mode 3 候选集合与 C# `AddTranslate` 逐条一致(EN 精确+EN 前缀+CN→EN 反查; `ce` 同 C# `BuildReverse`),用合并频率视图、不做 LastPick 置顶. 唯一差异=§14 python 频率排序,非 bug. `ime.mode` 0..3(`% 4`; 第四十四轮取消、第四十六轮加回). 「译文」选项(`config trans`,默认开)另管: ①非词典模式候选挂 `translate_hint`; ②仅本模式零候选(`not cands and not exact_wubi and mode < 3`)才 `candidates(buf,3,py)` 兜底; ③词典模式本身不挂 `→译文`. 台账 §D23.
23. 双拼门控|`shuangpin>0` 时(C# `if (Shuangpin == 0)`)rq/sj/xq 动态候选、v 金额候选、启动器候选皆不挂(两键即音节撞码); `digit_as_code()` 亦须带 `CFG['shuangpin'] == 0`. `refresh()` 开头须有 C# 两处面板复位: `sym_cat>0 && buf != 'vf'` 与 `shuangpin>0` 时清 `sym_cat`.
24. 五笔唯一四码自动上屏|须排除启动器候选: `refresh()` 条件含 `cands[0] != ime.app_cand`(同 C# `!appSet.Contains(cands[0])`),否则自动启动程序.
25. 状态反馈=托盘气泡|非弹窗、非仅日志. C# 各 `TrayTip`/`ShowBalloonTip` 点在 python 皆有对应: `msg` 步骤、工具/插件结果(`开始执行…`/`完成`/`已取消`/失败)、per-app 上屏与 keyfix 切换、启动失败、`[csharp]` 插件编译/运行错、造词剪贴板无汉字、钩子安装失败(`hook.start()` 同步返成败+`last_error()`,main 弹气泡). python 统一 `main._notify`→`TRAY.notify`(pystray),无托盘退 `tools._msgbox`; tools 层走 `tools._tip`. 勿改回 `_msgbox` 或只写 `_dfn`.
26. tools.txt/插件 txt 块标签须全|`plugins.py _TOOL_BLOCK_TAGS` 须含 8 开(shell/cmd/powershell/ps/shellx/cmdx/powershellx/psx)与 8 闭 —— 旧正则漏 `cmdx`/`powershellx`/`[/cmd]`/`[/ps]`,会造假按钮、块内容错位. `load_tools` 须认 `[button 名]` 前缀、`code = xx` 可写在步骤之后(同 C# `LoadTools`). 块标签在 steps 存原文,`run_steps` 执行期配对: 闭须应开(`[ps]` 唯 `[/ps]` 收,同 C#). 第二十轮结构规则勿退(CHANGELOG 第二十轮 11 组 fixtures): ①默认标签 `工具` 按需创建(仅注释者须返空列表); ②无按钮的标签页须留; ③`[tab ]` 空名用 `"?"`; ④`code` 行判定同 C# `t.StartsWith("code")`(大小写敏感)+`ToolToks(t)[2]`; ⑤步骤行尾不带 `\r`.
27. 反向差异清单(python 有 C# 无,勿「对齐」掉)|`cnpunct`+Ctrl+. 全角标点、`F8` 硬开关、`Ctrl+Alt+Q` 退出、候选条主题(dark/light)、`learnk`/`recentk`+近期热度(§14)、剪贴板「粘贴上屏」、`_CLIP_FORCE`(开始菜单/搜索强制剪贴上屏)、tray 的整句/联想/全角标点开关、「译文」选项、造词对话框(C# 是剪贴板直造)、状态提示点 `statedot`(默认关,§D11.2). 往 C# 补须用户明示(得走 §3 的瘦 DLL+ps1+15 项测试整链). C# `inDialog` 有意不跟进(python 造词/导入框含文本框,须输入法可用). 第五十二轮登记、用户已确认保持现状: ①Shift 轻拍更保守(Ctrl/Alt/Win 按住不武装、松键 0.4s 时限); ②字母键判定排在空格/翻页之后(故 `key_first = a` 时 python 当空格确认、C# 当字母入码). python 有意胜 C#: `_save_cfg` 写败弹气泡、`calc._to_long` 越界报 `Err`、`_write_config` 保持 config.txt 原行尾. 第六十七轮: `keyfix` 牺牲字符用 `U+200B`(`win.QT_FIX_SENTINEL`),C# 用 `'X'` —— 勿改回 `ord('X')`; 改此跑 `%TEMP%\wg-r67-qtfix-probe.py`. 原文 §D21.
28. 用户可改文本一律 `engine.read_text()`|(`utf-8-sig`→`gbk`→`utf-8+replace`). 记事本「另存为 ANSI(GBK)」后再 `open(..., encoding='utf-8')` 会抛 UnicodeDecodeError 崩启动(C# `File.ReadAllLines(UTF8)` 替换式解码,不抛). `read_text` 仅以 OSError 表不可读; 新读取点照办. 名单: `config.txt`/`tools.txt`/`plugins\*.txt`/`pastemode.txt`/`plugins-disabled.txt`/`userwords.txt`/`userdict_*.txt`/`lastpick_*.txt`/`assoc.txt`; 便签 `notes\*.txt`/`notes.txt`/`notes-meta.txt`/`note-color.txt`(彼处 `except OSError` 抓不到解码错→便签窗半死); 码表与插件 `py.txt`/`wb.txt`/`ec.txt`/`trad.txt`/`import_*.txt`(`engine.parse_dict` 快路径 `utf-8-sig`、失败退 `read_text`; BOM 会令首行读不进)、`load_import_base`、插件 `.py`(`main._py_plugin_meta_static`). 写侧对齐 C# 行尾: `engine.write_import_file` 须带 `newline='\n'`(C# `ImportCodeTable` 写裸 LF; `import_*.txt` 入库跟踪,翻 CRLF=整文件 diff); `config.txt` 为 C# `WriteAllLines`(CRLF),默认即可. 读侧: `read_text` 不做 universal newlines,行尾 `\r` 入值 —— 见 §39. 原文 §D22.
29. 未闭合多行块整块弃|同 C# `ParseToolSteps`/`LoadTools`(块遇闭标签才入 steps): `plugins.run_steps` 扫至行尾仍无闭标签,记 `块未闭合…已跳过` 并 `continue`,勿执行半截块(否则后文当脚本跑).
30. 改 `.py` 须二进制写|`.py` 在仓库为 LF; `open(p,'w',encoding='utf-8')` 在 Windows 翻 `\n` 为 `\r\n`→整文件成「全部改动」(曾致 1885 行幽灵 diff). 用 `open(p,'w',encoding='utf-8',newline='')` 或 `[IO.File]::WriteAllBytes`; 改毕验 `\r\n`=0 并核 `git diff --stat`. `build-wgime-pure.py` 内嵌模块源码,行尾变须重建 dist,否则 payload 与源码不一致. txt 依各自 blob 行尾(`core.autocrlf=false` 时 git 比字节; 根 `plugins\*.txt`/`tools.txt` 等 blob=LF 而工作区=CRLF 系历史遗留): 先 `git cat-file -p HEAD:<path>` 观 blob 行尾、依之写回,再 `git diff --numstat -- <path>` 验只剩目标行(`--ignore-cr-at-eol` 辅助). 行尾不统一: 根 `plugins\wgtranslate.txt` blob=LF,`release\plugins\wgtranslate.txt` blob=CRLF —— `sync-dist.ps1` 逐字节拷后须依 release 的 blob 再写一次. `build-package.ps1` 非可复现(内嵌 zip 带当前时间戳,源码未改 dist 亦脏,唯 `THIRD_ZIP_B64` 行异): 只改插件等不内嵌之物时,构建后 `git checkout -- wgime-py-pure\dist\wgime-py.py` 退噪,再 `%TEMP%\wgime-dist-sync-check.py` 验 dist 与磁盘逐字节一致. 原文 §D20.
31. config 取值语义以 C# 为准|C# `LoadConfig`(wgime.bat 1663-1747)白名单(`v=="1"||v=="on"||v=="true"`,非法判关)=`showcode`/`keyfix`/`followcaret`/`hideidle`/`trad`/`starton`; 黑名单(`v!="0"&&v!="off"&&v!="false"`,非法判开)=`sentence`/`assoc`. python 逐键照此(`engine.load_config`); python 独有 `cnpunct` 用黑名单. `paste`(on/always→1,off→2,key/unicode→3,余→0)、`shuangpin`(xiaohe/小鹤/flypy→1,ziranma/自然码/zrm→2,ms/微软/mspy→3,余→0)、`mode`(仅 tray 生效)、`fuzzy`(none/off/空→清空; 一对皆解析不出则守缺省)皆与 C# 逐值对齐(275 组用例). 改 `load_config` 后须重建 dist+package. 有意保留: 非法 `hotkey_*`/`key_*` C# 守当前字段、python 回缺省; python 多认单引号 `app =`.
32. 步骤 DSL(`plugins.py run_steps`/`_run_verb`)对齐 C# `ExecToolStep`|①`confirm` 的 `title=`/`buttons=`/`default=` 须真生效(`_confirm_args(arg, confirm, **msgbox)` —— `msgbox` 是参数,旧漏传致 `buttons=ok` 直接 NameError; `okcancel` 走 OK/Cancel,缺省按钮「否」同 C# `MessageBoxDefaultButton.Button2`),回调签名 `confirm(text, title, buttons, default_no)`,兼容单参数旧回调; ②`kill` 只看首 token(C# `tk[1]`),非整行; ③缺参动词(`run` 无程序名、`reg-set` <4 token、`reg-del` 无键路径)须记一步失败,勿静默成功(C# `tk[n]` 越界抛); ④多行块控制台显示名同 C#: `cmd→[shell]`、`shellx|cmdx→[shellx]`、`powershellx→[psx]`、`powershell|ps→[powershell]`. python 有意保留: 破坏性动词前强确认(§16)、块开标签大小写不敏感、`file-del C:\*` 拒删(C# 会真删 C 盘根). 改 `plugins.py`/`tools.py`/`main.py` 后须重建 dist+package. ⑤`start`(第九十轮加): **只拉起、不等它退出** —— `run`/`shell`/`shellx`/多行块全是 `subprocess.run`(等到超时 120s/300s/86400s 再把子进程**收掉**), `open` 又不能传参数/选解释器/藏窗口, 所以常驻程序(托盘工具/截图器)以前根本启动不了; 两侧同款: python `Popen(parts, stdin/stdout/stderr=DEVNULL, close_fds=True, creationflags=CREATE_NO_WINDOW)`(三流不继承: pythonw 下 `sys.stdout/stderr` 是 None, 子进程会拿到无效句柄; 也不接管道, 免得没人读塞满卡死), C# `Process.Start` + `UseShellExecute=false/CreateNoWindow=true`(分支内**不许**有 `WaitForExit`); 程序名展开 `%VAR%`、参数原样(同 `run`); 缺参/找不到程序都要**带程序名**记一步失败(Windows 的 FileNotFoundError 文本里没有文件名)。**动词表两侧不许漂移**: 回归 `tests\dsl-verbs-test.py`(29 项)把"别名归一(`shellblock↔[shell]`…)后两侧动词集合完全相等"钉死, 还断言 C# start 分支没有 `WaitForExit`。
33. hook 吞键次序(勿提前透传 Shift)|C# `bare = !ModifierDown()`,`ModifierDown()` 只含 Ctrl/Alt/LWin/RWin(wgime.bat 124-130) —— 故组字中 Shift+数字/退格/Esc/回车/空格/PgUp/PgDn/配置翻页键在 C# 亦被吞; 唯 `a-z`、`;`(SemiAsCode)、以词定字 `[`/`]` 显式要求 `!sh`. python `hook._proc` 次序须为: 数字(`COMPOSING`)→`_swallow`(退格/取消/回车/空格/翻页,只求 bare)→`_swallow_pick`(`!sh`)→中文标点(全角映射,表见 §D17)→`if shift: 透传`→裸字母; `_rebuild_swallow` 依此二组建表. 改后跑 hook 判定矩阵(伪造 lParam+`_key_state` 直调 `_proc`; CHANGELOG 第十二轮 89 例,第七十八轮起 24 组常驻 harness)再提交.
34. `record_commit` 与 `engine.learn` 勿绑同门控|C# 每条上屏路径皆调 `RecordCommit`(`Hook_OnSpaced` 空格与数字共用段、`Hook_OnPunct` 标点自动上屏、五笔唯一四码自动上屏); python 旧把二者同塞 `if i > 0`,致「全拼+空格逐字确认」永不入 `ime.recent`,自动造词几不触发. 今制: `record_commit(text, code)` 于 `commit()` 无条件调用(含 `commit(0)`,覆盖五笔自动上屏),`handle_punct` 自动上屏首候选时补记; 唯动态候选/`vf` 面板符号不参与(提前 return). `if i > 0` 只管 `engine.learn`+`_last_learn`(LastPick/词频回滚). 改上屏路径后跑 CHANGELOG 第十三轮 headless 状态机 harness(真 engine+出口打桩+临时 `LOCALAPPDATA`,勿碰用户数据).
35. 勿写行尾注释代码|用 `tests\undefined-globals.py` 兜底(第四十轮真 bug): `win.py` 曾 `_helper_t0=[0.0]; _helper_fail=[0]   # …; _ipc_req_hwnd={}; _last_fg=[0]` —— 二全局量被行尾注释吞,从未定义: `request_caret_refresh()` 的 `_ipc_req_hwnd[rid]=hwnd` NameError 被自身 `except Exception` 吞→`p.kill()` 杀跟随 helper; `get_caret_pos()` 首行读 `_last_fg[0]` NameError 直抛→候选条定位败. 表现不似未定义变量: 跟随失效、每键杀一 python 子进程、`_helper_fail` 三次后不再起 helper. C# 有编译器兜(CS0103),python 无 —— 故: ①改毕 `.py` 跑 `python wgime-py-pure\tests\undefined-globals.py`(symtable 版 mini-pyflakes,应输出 0); ②注释勿在行尾追加示例代码; ③`_helper_fail`/`_ipc_done` 等存活判据异常时先疑此类.
36. 托盘图标「个别机器看不见」=宿主无 Pillow|构建期渲 9 个 ICO 内嵌(`build-wgime-pure.py`→`TRAY_ICONS`),运行时 `win.icon_from_ico_bytes()` 写 `runtime\icons\` 再 `LoadImageW` 成 HICON,不需宿主 Pillow(PIL 带 `_imaging.pyd` ABI 绑定,内嵌源码跨版本无用 —— 未装机器 `import PIL` 败→整个托盘消失). 换图走 `NIM_MODIFY|NIF_ICON`(看 `tray.NIM['modify_ok']`); `HAS_PIL` 仅源码布局回退. 诊断勿删: pystray 报错只走 `logging`→`sys.stderr`,pythonw 下 `sys.stderr is None`→收 `tray.LOGS`/`NIM['add_ok']`/`last_error`; `main._tray_selfcheck()` 写 always-on 日志并于真失败时从后台线程弹框(主线程弹会卡 poll=打字停摆). 三坑: ①`Shell_NotifyIconGetRect` 不可作「未登记」判据; ②GetRect 的 uID 须 `id(icon)`; ③判「用户能否看见」用 `win.tray_promoted()`. 判据: `python -S -E` 跑真成品,或 `tests\embedded-isolation-test.py`; 探针 `%TEMP%\wg-r70-clean-live.py`.
37. 译文质量=英语常用词表|`ce` 由 `ec.txt` 反建,旧取字母序首(`测试→dvdram`/`你好→alohas`/`老师→dorina`). 今 `build_reverse(ec, load_en_rank(dict_dir))`: 按 `en-freq.txt`(Hermit Dave FrequencyWords `en_50k`,MIT,随分发目录发)排序,无常用英语词者不进 `ce`(查不到即不挂); 表读不到则退旧行为(stderr 说明). `EN_HINT_MAX_RANK=50000` 可调; `en-freq.txt` 在 `CACHE_FILES`(换表→老缓存失效一次).
38. 语音输入(python 独有)|`voice.py`=waveIn 录音(纯 ctypes,VAD 静音自停,**勿用 `audioop`**)+多后端(`voice_engine`: `system`/`http`/`whisper`/`sherpa`(首选)/`cmd`/`stream`; 逐一说明见 §D44,其中 `stream` 的 payload 按 URL 关键字选(含 `dashscope`/`aliyuncs`→`input_audio`+`asr_options`,否则 `audio_url`)). 热键 `hotkey_voice`(Ctrl+Alt+V)按住说话,`WM_KEYUP` 报 `VK_VOICE_UP`,**唯 `VOICE_ON` 真时吞键**(按下也门控); `MODE_VOICE=4` 里钩子**全部透传**、轻点热键=常录; **切语音模式=顺手开语音**(`_voice_set_on` 幂等),离开不关,选项里关语音时若在语音模式则切回混合. 结果默认进候选条等空格(`voice_auto=1` 直上屏; `voice_click=1` 只进剪贴板+提示,§D14),上屏走 `inject()` 但**不进词频学习**. 麦克风 Deny(`waveInOpen` rc=1)→提示去开隐私麦克风(`voice.mic_consent()`). `_write_config()` 缺文件要**新建**、返 True/False. **硬规则**: ①按住热键的**自动重复必须丢**(`KBDLLHOOKSTRUCT` 无重复标志: `if VOICE_DOWN[0]: return 1`,修饰键已松开处清标志); ②录音期 ~4Hz 重画候选条(`main._voice_tick()`,归零 `_VOICE_TICK[0]`); ③VAD 阈值 `thr = min(clamp(floor*3.5,180,1200), clamp(peak*0.25,180,600))`(`floor` 取**最小** RMS、`peak` 每块 ×0.9 慢衰减) —— **勿改回「只留 thr_abs」或「头 500ms 取中位数」**; 关自动停用 `voice_silence = 0`; ④每次录音/识别各留一行 always-on 诊断; ⑤`http` 走 `voice._http_post`(`stt_proxy`): **每路都重建 `Request`**、**服务端回过话(HTTPError)就不换路/不重发**、各路原因并报; ⑥系统引擎 `Recognize()` **一次只返一段**,循环收齐再拼,流读完再调会抛(循环内 try 住). **常驻助手**(whisper/sherpa 同套 `_WarmSrv`,唯 `key/spawn/request_obj` 三钩异): 照 §17 helper 那套(源码走环境变量/JSONL 走 stdio/回包 `ensure_ascii`/**父进程退出=stdin EOF=子进程自退**),**二锁勿并**(`lock` 管起杀、`rlock` 管一问一答),预热=启动 +4s(`stt_prewarm=0` 关)+**按下热键那刻**; 跑 `voice-vad-test.py`(31)/`whisper-warm-test.py`(67)/`sherpa-warm-test.py`(74). 坏网络: 国内站 key 配 `api.siliconflow.cn`; `stt_retry`(同路默认 3,**HTTPError 不重试**)/`stt_timeout`/**记住可用路径**; `voice_fallback`=两引擎同时开跑谁先成用谁. 原文 §D44(叙事 §D6/§D7/§D8/§D12/§D14).
39. `read_text` 行尾 `\r` 勿入值|第五十轮真 bug: `read_text` 是二进制读+解码(§28)且不做 universal newlines,CRLF 的 `\r` 留行尾、被当词的一部分存入 `lastpick_m`; 写盘 text 模式又翻 `\n` 为 `\r\n`→每轮载入/存盘多一 `\r`. 真危害非文件难看,而在 `candidates()` 的 LastPick 置顶靠值比较(`lp = lastpick_m[mode].get(keys); if lp and lp in cands`): 带 `\r` 永不相等,「上次选的词置顶」静默失效. 规则: 按 `'\n'` 切行后首事 `line = line.rstrip('\r')`(或如 `plugins.py` 用 `rstrip('\r\n')`); 新解析点勿省. 写盘仍 CRLF(同 C# `File.WriteAllLines`),脏文件下次载入/存盘自愈. 回归: harness(`lastpick 值不带 \r`+`lastpick 仍置顶`)+`%TEMP%\wg-r50-lastpick-probe.py`; 叙事 §D4.
40. 全量审计硬规则(第五十一轮; 明细 CHANGELOG 第五十一轮+§D5)|①`_merge_user_words` 须 py+wb+acro 三样皆补,且 `_init_state` 三张派生表(char_wb/wb_by_len/word_freq)须在合并用户词前就绪(合并要用 `char_wb` 算五笔构词码); ②读用户文件须读完再动内存(勿开头 `ALARMS.clear()`,读败只剩空,继而 `save_cfg` 覆盖整份); ③缓存/索引签名须覆盖其依赖的全部输入(漏 `userwords.txt` 则出删不掉的「幽灵词」); ④给 helper/子进程写管道须非阻塞(helper 串行读 stdin+4KB 管道⇒`stdin.write` 会永阻 Tk 主线程; 改 `os.set_blocking(fd, False)`+`os.write`,满则弃此刷新); ⑤后台线程异常须兜住并报出(pythonw 下 `sys.stdout/stderr` 皆 None,裸线程抛异常无声) —— `main._bg_plugin` 为统一入口; ⑥菜单/图标/模式表索引一律 `% len(表)`,勿写死; ⑦`.py` 插件「停用」判定须在 `exec_module` 之前(否则停用插件每次启动仍执行模块级副作用); ⑧权限多值: `perm` 支持 `network,run` 逗号表,判定拆集合求交,勿整串 `in`.
41. `place()` 子控件不撑父容器|第五十三轮真 bug: `tools.py show_toolbox` 磁贴区为 `Canvas`+`create_window(inner)`,磁贴由 `ui.flat_button` 用 `place()` 摆; `place()` 不入父容器 requested size→`inner` 仅 1x1、`canvas.bbox('all')==(0,0,1,1)`、`winsize=0x0`,磁贴建出却被 Canvas 全裁(「标签页在、按钮一个都看不见」). 修法三事皆须: `inner.configure(width=,height=)`+`create_window(...,width=,height=)`+`canvas.configure(scrollregion=(0,0,w,h))`(只设 scrollregion 不解裁剪). 判据: `bbox('all')==(0,0,1,1)` 即中招; 凡「Canvas+place 子控件」照办. 连带: ①滚动条只在内容真超可视区时 place(`need_sb = inner_h > BODY_H`; 磁贴宽恒用 `inner_w`,免栅格跳动); ②挂 `content` 的控件须按内容区高度算 y/height(`content`=标题栏下方,`y=38,height=h-38`),统一 `CH = H - 38` 推; 底部日志 `ui.console_text` 须有垂直滚动条+滚轮(工具箱/网络工具/聊天窗共用). 数字/探针 §D19.
42. `ui.make_window` 窗高=内容所需+38(标题栏)|第五十五轮一次修 5 窗: `content` 只占 `h-38`,y/height 按可用区排却按整窗高给→底部控件被裁(剪贴板/取色器/造词/用户词表/插件管理皆中). 规则: 窗高=内容真需高度+38(再留 ~10px 边距). 同轮另修: 插件管理顶部按钮条总宽 `494+7*8=542 > bar 540`(最右「运行」被切 2px)→起点 0、间距 8→6; 剪贴板提示不限宽又置 `x=390`(右缘冲 606,窗仅 520)→移至按钮下方单独一行+显式 `width`. 审计勿靠肉眼: 建窗遍历子孙算绝对 `(x+w,y+h)` 比窗宽高 —— `%TEMP%\wg-window-audit2.py`(10 个内置工具窗)、`wg-window-audit3.py`(造词/用户词表用假 engine); 数字 §D26. 便签滚动条按需: `yscrollcommand` 内判 `yview() == (0.0, 1.0)` 则 `place_forget`,溢出才 `place`; 正文宽度不变. 给 tk 窗设 Win32 样式(不激活/穿透/透明/置顶)须写顶层外框: `winfo_id()` 是 `TkChild` 子窗口,真外框是 `GetAncestor(GA_ROOT)`(`TkTopLevel`) —— 写子窗口上 `GetWindowLong` 读得回但窗口管理器不看,等于未生效(第六十九轮真 bug,改 `win.top_level_hwnd()`; §D11.1).
43. 托盘句柄时序(第五十六/五十七轮)|①图标未登记上(`icon.visible` 假)时绝不换图,否则 shell 记住已销毁句柄. ②换图序: 先注入新句柄→`NIM_MODIFY`→shell 接受后才 `DestroyIcon` 旧句柄; pystray `_release_icon()` 销毁的是当前 `_icon_handle`(非刚换下的),销毁旧句柄用 `win.destroy_icon()`; 同图(同 key)重复刷新只 `update_menu()`,不重建 HICON、不惊动 shell. ③图标须早挂: 词库加载为主线程 join,`_boot_tray()` 在 join 前先挂最小菜单图标,词库读完由 `_deferred_tray` 补全; 勿把 `_boot_tray()` 挪到 join 后; `tray.start(boot=True)` 用最小 api(唯 toggle/is_active/get_mode/quit),boot 分支勿加需 CFG/工具/插件之调用. ④换图成否唯看 `NIM['modify_ok']`,绝不可看 `icon._message()` 返回值(pystray `_win32._message()` 无 return→`bool(...)` 恒 False). 换图统一走 `Tray._notify_icon(h, key, old)`,状态分二: `_cur_key`=pystray 当前句柄对应 key(注入后即推进)、`_shown_key`/`_shown_handle`=shell 确认接受过者(唯 `modify_ok is True` 才销毁旧的; shell 拒收时不谎报,下次同句柄补发). 改此必跑 `tray-swap-test.py`(42): 桩不可比真的更宽容(假 icon `return True` 即漏此回归); 一个不会失败的测试等于没写. 故事/实测见 CHANGELOG 第五十六/五十七轮.
44. 可选依赖自检/安装(py 版, 第八十二轮)|核心零依赖不变, 只管可选件: `psutil`/`cryptography`/`argostranslate`(+源码目录缺的 `pypdf`) 可一键装; 语音 `faster-whisper`/`sherpa-onnx` **只报告不代装**(体积大+要模型). 三条硬规矩: ①装到 `DATA_DIR\site\pip`(`pip install --target`)+挂 `sys.path`, **不用 `--user`/不写系统 site-packages**(不污染用户 Python、绕开 Store 虚拟化、卸载=删目录); ②首启只问一次(默认否), 状态在 `DATA_DIR\deps-state.txt`(`asked=1` 后不再打扰), 重跑走启动编码 `deps`/`yilai`; ③探测/安装都在后台线程, 失败只记日志+气泡, 绝不拖累打字. `deps.ensure_site_on_path()` 必须在 30ms 插件装载**之前**挂 sys.path, 否则插件模块级的可选 import 看不到私有目录. 改 `deps.py` 后跑 `tests\deps-test.py`(51 项, 不联网)且**必须重建 dist**(`deps` 在内嵌清单, 测试会查). 写成品冒烟脚本须设 `WGIME_RELAUNCHED=1` —— 成品会**自我重启成 pythonw**, 否则你杀的是启动器、真正例还在跑 (两个实例抢键盘钩子), 且日志/data 都在 `LOCALAPPDATA\wgime-py\` 而不是 `LOCALAPPDATA\`. 原文 §D30.
45. 双模式插件入口须互斥(第八十三轮)|`plugins/*.py` 的 `__main__` 里若把"子窗口进程"和"独立运行入口"写成**并列两个** `if __name__ == '__main__':`, 子窗口关窗后 `mainloop()` 返回会**继续落到**双模式尾块 → `run()` → `_start_detached_window()` 再起一个新窗口 = 用户报的"翻译插件无法结束进程"(关一次回来一次, 还每次多一个隐藏 Tk root; 实测新进程的 parent = 刚被关掉那个 pid). 规则: 入口分派块**只有一个**, 体内 `if CHILD_ARG in sys.argv: _window_main() else: import _standalone; _standalone.standalone(_run_standalone, NAME)`; **独立运行必须走进程内建窗的入口**(`_run_standalone` 建窗后 `return root` 交给 `_standalone` 看守), 不可复用会另起进程的 `run()`(否则父进程立刻返回 0、留一扇没主的孤儿窗口, `WGIME_STANDALONE_AUTOEXIT_MS` 也管不住它). 回归 `wgime-py-pure\tests\translate-window-test.py`(13 项; 拿修前版本跑必红 4~6 条, 含"关窗后没有新进程"); 探针 `%TEMP%\wg-r83-translate-probe2.ps1`. 原文 §D31.
46. 插件管理器「结束窗口」(第八十四轮,§D48)|插件窗口可能在**独立进程**里(`wgtranslate` 的 detached 子进程),宿主既没句柄也不知 pid. **找**: `tools.plugin_windows()` = `win.enum_top_windows()`(EnumWindows,只要可见+有标题)过滤 `tools.plugin_window_match(title, name, code, filename)`: 文件名主干(`wgtranslate` ← `wgtranslate.py`)/`NAME`/`CODE` 三线索,**短 CODE(<3 字符,如 `fy`)只认完全相等**,且**只收 `python*` 进程的窗口**(`win.process_exe_name`). **结束**: `tools.end_plugin_windows()` 先 `win.post_close()`(WM_CLOSE),等 1.2s 不退再 `win.terminate_process(pid)` —— 后者自带「拒绝 pid<=0 / 拒绝本进程」(pdf/clock 的 `run()` 窗口就在宿主进程里,杀进程=自杀). UI 在**底部**那行(顶部按钮条塞不下第 8 个按钮),重活走后台线程 + `win.after(0,…)` 弹气泡(§25). 回归 `tests\plugin-window-test.py`(23 项; 检测到用户的同插件窗口则 A/B/C SKIP). 原文 §D48.
47. 自动更新(GitHub Releases, 第八十五轮,§D49)|只换**纯 Python 单文件** `wgime-py.py`(config/dicts/plugins 一概不碰). **检查** `update.plan()`(`/releases/latest`,404 退 `/releases` 取第一个非 draft/prerelease),比 `main.VERSION` **严格新**才算; 启动 +7s 后台一次(6h 内不重复),**只发托盘提示**,查到后 `TRAY.rebuild()` 让菜单那行变「更新到 vX…」. **下载两路互备**: `raw`(仓库 `wgime-py-pure/dist/wgime-py.py`)优先,失败退 `asset`(`*-python.zip`,核 release body 里那张表的 sha256); urllib **直连**(`ProxyHandler({})`)失败退 PowerShell `HttpWebRequest`; `update_mirror` 加前缀. **四条安全线**: ①三个标记(`MODULES =`/`PLUGIN_SRC =`/`THIRD_ZIP_B64`)+`compile()`+`>=200KB`,内层 `VERSION` 须比当前新且不低于 tag; ②asset 路 sha256 须对; ③先落 `.part` 失败即删,校验通过才写 `.new`,替换前备份 `wgime-py.py.bak-<旧版本>`; ④**只在用户点「更新」后才动手**(绝不自动重启). **替换**: detached 助手(源码走环境变量,照 §17)用 `OpenProcess(SYNCHRONIZE)+WaitForSingleObject` **等本进程退出**→备份→`os.replace`(重试 10s)→pythonw 重启. 只对单文件生效(`update.is_single_file` = 头 8KB 有 `MODULES = `); 配置键 `update_auto/repo/api/mirror/source(默认 raw)/timeout`. **`VERSION` 必须等于发布 tag**; **抠版本一律先认顶层明文 `WGIME_VERSION`**(构建期写在 dist 头部; 读它的是 `update.version_in_text`) —— 别改回"全文搜第一个 `VERSION = '数字...'`": 会被 update.py 自己文档里的版本示例抢先命中 ⇒ 自动更新**永远装不上**; 推论: **内嵌 `.py` 文档里不许出现带数字的 `VERSION = ` 示例**. 回归 `tests\update-test.py`(36 项)/真机探针 `%TEMP%\wg-r85-real-github.py`(9 项). 原文 §D49(事故复盘 §D33/§D35).
48. 常驻助手的"取消后第一调用"必须自带重试(第八十五轮补)|PDF 工具的 WinRT 助手是常驻子进程, `ensure()` 有"起得太密就挡一下"的 **1 秒防风暴门**, 而「取消」就是 `shutdown()`(杀助手) ⇒ **紧随取消的第一次调用**会立刻吃 `还没就绪`(实测 0.00s 返回, 不是慢是直接失败); 冷启上限 `T_COLD=180s`、热态 `T_TIMEOUT=1800s`, 预览这种"锦上添花"的调用跟着干等就成了"预览框一直写着 渲染预览…". 两条纪律: ①**可重试失败(`还没就绪`/`超时`)自动重试一次**(`_W32.call` → `_call_once` + 0.4s 重试, 两次原因都报); ②**短交互给短上限** —— `call(timeout=)` 本次上限逐级透传, `preview_first_page` 用 `timeout=20.0`(长任务才配 180s/1800s). 回归 `tests\pdf-test.py`(78 项, 含"取消助手后立刻预览"这条真实时序; 修前稳定 1/78 红, 修后连跑 3 次全绿). 探针 `%TEMP%\wg-r85-pdfhang-probe.py`. 插件**不进 dist** ⇒ 只改 `plugins\*.py` 时**不用重建 dist**(§30), 但 `package\plugins\` 要同步. 原文 §D34.
49. 全屏穿透浮层(桌面宠物)必须**创建时就带 `WS_EX_NOACTIVATE`**(§D50)|`CreateWindowExW(WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST, WS_POPUP, …)` + `SetLayeredWindowAttributes(hwnd, 键色, 0, LWA_COLORKEY)` + `ShowWindow(SW_SHOWNOACTIVATE)`; **别用 tkinter 做这个浮层**(Tk 的 Toplevel 建窗即 map=激活已发生, "先 withdraw 再 SW_SHOWNOACTIVATE" 实测照样抢前台). 动画=**独立线程 + `timeBeginPeriod(1)` + `PostMessage(WM_APP+n)`** + 主线程 `GetMessage` 阻塞循环(**别用 `WM_TIMER`+轮询 sleep**),重画只 `InvalidateRect(脏矩形)`. 交互态(要用户点工具)**只去掉 `WS_EX_TRANSPARENT`、保留 NOACTIVATE**(面板处点得到、面板外仍穿透、前台不变). 所有 Win32 函数**必须声明 `argtypes`/`restype`**,`WNDPROC` 的 `WINFUNCTYPE` **必须保引用**. 交付形态=**`plugins\*.py` 双模式插件 + detached 子进程**(§8.7). 客观判据、flag 组合与实测数字见 §D50/§D36~§D38.
50. 读屏幕像素**绝不允许整屏/整条扫描**(§D47)|`GetPixel` 很贵(实测 **~8.5ms/次**): 扫一条 `3840x178` 要 **162 秒**, 会把被测进程的存活窗口耗光 → 后面的断言全变**假红**(真踩过). 规矩: ①先用测试钩子**冻住动画**再验像素(`WM_APP_PAUSE` 且 `wParam=1/0` **显式**指定, 别用 toggle —— 多处调用会错位); ②只按状态 dump 里的坐标扫**几十个像素**, 别扫全屏; ③dump 是**状态快照**而 `InvalidateRect`→`WM_PAINT` 是**异步**的, 暂停后要**等位置连续两次不变**(`wait_still`)再采, 否则拿到的是上一拍坐标; ④扫精灵别扫它**正中心那一行**(十字线在那儿). **`BitBlt(screenDC)` 抓不到这个分层窗**(实测整片空白), 只有 `GetPixel` 看得见它. 长跑断言要写「**本窗不是前台**」而不是「前台没变过」—— 后者被屏幕前的人点一下鼠标就假红. 原文 §D47.
51. 插件**不许自己跑插件** —— 要跑就走宿主 API `--api`(第八十六轮,§D51)|插件进程里**没有** `ui`/`win`/`wspy`(单文件发行版它们只存在于宿主 `sys.modules`), 自己 import 插件的 `run()` 必 `ModuleNotFoundError: No module named 'ui'`. 规则: ①宿主入口在 `main.py`, 两个命令 `--api list-plugins`(JSON) / `--api run-plugin <code>`(建 Tk root 跑插件); ②**必须在 `_relaunch_if_console_python()` 之前**判掉(否则 python.exe 被重启成 pythonw 并 detach, CLI 的 stdout 直接丢), 函数体放在 `APP_DIR` 算完之后; ③**别把 API 做在单独文件里**(单文件发行版下 `ui`/`win` 不是磁盘文件); ④插件侧用 `_host_file()` 找宿主(发行版 `<package>\wgime-py.py`, 源码版 `<wgime-py-pure>\main.py`), `run-plugin` 用 Popen + **stdout 落临时文件**(别用管道: 工具活下来后管道塞满会把工具卡死), 1.2s 内退出的说明起不来; ⑤`--api` 输出一律 UTF-8 显式解码. 守卫: `tests\pet-overlay-test.py` 里那条「宿主 API 通(list-plugins 返回插件清单)」. 细节 §D39.
52. 浮层渲染路线: 用 `UpdateLayeredWindow`(逐像素 alpha),**别用 DirectComposition**(第八十七轮,§D52)|①DComp 是死路: `WS_EX_NOREDIRECTIONBITMAP` 合成窗的内容**不按 alpha 做命中测试**(`WindowFromPoint` 照样命中整块窗外框), 唯一能强制穿透的 `SetWindowRgn` 会把 DComp 内容**一起裁掉** ⇒ 「看得见」与「点得穿」二选一; ②ULW 可行: `WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST` + `CreateDIBSection`(32bpp 预乘) + D2D **DC 渲染目标**(`CreateDCRenderTarget`, dpi 96 ⇒ 1DIP=1px) + `UpdateLayeredWindow(ULW_ALPHA)`, 命中测试**逐像素按 alpha**; ③交互态**只摘 `WS_EX_TRANSPARENT`**(保留 NOACTIVATE): 只有画到的像素挡鼠标、面板外照旧穿透、前台全程不变; ④**ULW 不做 vsync 节流**, 必须自己限速(`timeBeginPeriod(1)`+每帧算 deadline, 上限常量 `FPS_CAP`); ⑤**窗口做成精灵大小并跟着角色移动**, 不要全屏窗(全屏+手算脏矩形那一类残影 bug 由此不存在); ⑥Rust 侧 **COM 对象必须活到窗口销毁**(放进长期结构体): 放建窗函数里当局部变量, 函数一返回就 drop ⇒ 画面正确、`Present` 成功、**屏幕上却什么都没有**; ⑦工具链 `x86_64-pc-windows-gnu` + `windows 0.58` crate 直接出 `cdylib`, 需要 `Foundation_Numerics` 才有 `CreateSolidColorBrush`; ⑧**面板布局只能有 `layout()` 一处出处**(绘制/命中测试/探针共用), **点击坐标统一屏幕坐标**(`WM_LBUTTONDOWN` 是客户端坐标, 要 `ClientToScreen`), 窗口高度按工具数动态算、锚点按离**底边**算, 探针要角色坐标用 `wgime_pet_dog_xy`(别拿窗口矩形猜); ⑨凡断言依赖"光标在哪"**必须走测试钩子**(`wgime_pet_set_cursor`; python 版 `WGIME_PET_FAKE_MOUSE`); ⑩飞到屏幕中间的东西**单独一个窗**(角色窗撑到半个屏幕每帧要提交几 MB); ⑪角色站**工作区底边**(`SystemParametersInfoW(SPI_GETWORKAREA)`); ⑫验收探针 `wgpet-rs\verify-overlay.py`(21 项). 原文 §D52(实测数字 §D40).
53. 重依赖 GUI 程序(Qt 等)接插件一律「整个程序体缩进进 `_app_main()`」的**单文件**双模包装(第八十九轮补; 用户明确要单文件+可独立运行, 别再拆"薄插件+下划线载荷")|PySide6/Qt 这类**不能内嵌**(§12)、import 常在**模块级**、还常带模块级依赖自举(缺包自己 pip 装、装不上 `SystemExit`)、且 Qt 与宿主 Tk 不能共用主线程事件循环 ⇒ **绝不能**模块级平铺当 `plugins\*.py`(装载器在**输入法启动时** exec: 拖慢启动/当场联网装 200MB/缺依赖时插件静默消失). 做法: ①用 `wgime-py-pure\build-wrap-qt-plugin.py` 生成(`wrap()` 纯函数, 原程序**一个字节不改**): 整个程序体(含它自己的 `if __name__ == '__main__':` 块 —— 在函数里照样成立, 独立运行时 `__name__` 仍是 `'__main__'`, **入口仍只有一个**)缩进进 `_app_main()`, 模块级只留清单 + `pyside_available()`/`spawn()`/`run()`; 生成器拒绝"输入=输出", 并对生成物做 `ast.parse` 守卫; ②**`_app_main()` 靠前那句 `global` 序言是承重的, 不许删**: 原程序里 `global _settings_cache/_current/_cache` 指向模块级缓存, 缩进后不声明 ⇒ `_app_main` 的初始化变成**函数局部**、与嵌套函数里的 `global` 成了两个变量(缓存静默失联, `current_language()` 当场 `NameError`); 包装脚本自动收集**全部** `global` 名写成一行, 回归有 A/B 断言(删掉必红); ③`run()` 只做"查依赖 → 把**本文件自己**作为独立进程拉起(`pythonw`+`CREATE_NO_WINDOW`)→ 发气泡"并**立刻返回**(Tk 主线程同步调), **别**复用 `_standalone.py` 那套 Tk 看守(本程序不是 Tk 程序); ④缺依赖发气泡给人话(启动编码 `deps` 或 `pip install`), **别在插件里悄悄装几百 MB**; 私有依赖目录 `%LOCALAPPDATA%\wgime-py\site[\pip]` 要进子进程 `PYTHONPATH`; ⑤`python 本文件.py` = 原程序, `--check-deps` = 只报依赖, 再留测试钩子 `WGIME_STANDALONE_AUTOEXIT_MS`(钩子下自动 `PYSHOT_SKIP_DEPS=1`/`PYSHOT_NO_ALERT=1` + 补 `--check-deps` + 打 `STANDALONE-OK`; 挡住 PySide6 时打 `STANDALONE-SKIP-DEPS` 且 **rc=0**, 免得别的机器上整条链变红); ⑥包装前安全单: 原程序不许有 `__future__`/`nonlocal`/`globals()`/`eval()`/`multiprocessing`/`pickle`(`exec(` 的命中要逐个确认是 Qt 的 `app.exec()` 而非内建), 且**方法体看得见外层函数的局部名**(类作用域不阻断闭包 —— 整套包法的前提, 已实测); ⑦`tests\undefined-globals.py` 的 `SKIP_FILES` **只**登记 `plugins\PyShot.py`(第三方生成物的嵌套作用域会被 symtable 误判, 7 处假阳性); ⚠ **Windows 大小写不敏感**: 别把包装写成与载荷同名(`pyshot.py` 会**覆盖** `PyShot.py` —— 第八十九轮真踩过, 靠 `C:\Explorer\pyshot\PyShot.py` 副本救回; 回归断言"同目录只有一份"). 参考 `plugins\PyShot.py`(480KB 原程序+包装共一个文件)+`build-wrap-qt-plugin.py`, 回归 `tests\pyshot-plugin-test.py`(70 项), 原文 §D49.

## 6. 加载与性能（已做的优化，改动时别回退）

> 实测数字/探针清单/历史轮次来龙去脉都在 `AGENTS-DETAIL.md`（需要时 read，别凭记忆猜）。

- **启动顺序（第三十八～四十轮）**：`单实例检查` → `load_config`+`hook.configure/start/set_active` →
  `Engine()` 后台线程（不碰 Tk）+ 跟随 helper spawn → `import tkinter/tools/plugins/bar`（dist 里懒装载）→
  `tk.Tk()`+加载窗 → join 词库线程 → 配置/候选条 → `root.after(8, poll)` → `root.after(30/150/600, 插件/托盘/tools 收尾)`
  → `mainloop`。要点：**Tk/加载窗与读词库并行**、**收尾三段必须在 poll 之后**、**未激活时按键照常透传**、
  已激活按键进 `hook.EVENTS` 等 `poll()` 顺序处理。实测：钩子 **+498/+416ms**、主循环 **+1954/+1877ms**（warm）。
- **别再回退的几件事**：dist 只 eager exec `win`/`hook`/`engine`（其余 PEP 562 懒加载）；
  **反查表 rev_wb 不同步建**、**词库缓存分两段读**（`CACHE_VER=5`）、
  **派生表 `char_wb`/`wb_by_len`/`word_freq` 进缓存第一段**；`pywfreq.txt`/`en-freq.txt` 在 `CACHE_FILES` 里；
  **空索引绝不写缓存**（缓存签名 + 侧车 `.sig`）；`_find_dict_dir()` 要带 `..\package\dicts` 兜底。
- 探针（跑之前先看 §D2 的"注意 APP_DIR"那条）：`%TEMP%\wgime-warmec-probe.py`（40）、`wg-r40-selftest.py`（35）、
  缓存生命周期 14、`wg-hookorder-probe.py`。

## 7. Git / 分支

- 主分支 `master`（唯一活跃分支）。原独立 WgTray 程序已于 2026-09 退役（收敛为 `mode=tray` 运行模式），历史版本见早期 tag/提交。
- 提交后推 `origin/master`。release 发版本用 GitHub API + zip，**已脚本化**（2026-09-10）：
  1. `tests\build-release-assets.ps1 -Version X` → 三个 zip
     （`.release-stage-vX\`；`-OnlyPython` 只重做 python 包）。脚本内的三条坑：zip 条目要逐条写 `/`、源目录必须长路径、
     **python 包取自 `package\`，改完源码先跑 `build-package.ps1`**（有 hash 守卫，防发出上一个构建）。
  2. `tests\publish-release.ps1 -Version X -BodyFile <body.md> -AssetsDir <stage>`（同 tag 走 PATCH + 覆盖资产）。
     **务必先 push 再 publish**（脚本用本地 HEAD sha 作 target_commitish —— 传 master 会按远端解析，v1.2.9 就踩过）。
  3. 发完**回验**：线上 python zip 的 SHA256 与 stage 相同、内层 `wgime-py.py` 与 dist 逐字符一致、body 无 `?`、tag=本地 HEAD。
- **中文坑**：release body 用 `HttpWebRequest` 显式 UTF-8 字节发（脚本已内置）；**别用 `Invoke-RestMethod`+`ConvertTo-Json`**（PS 5.1 把中文变 `?`）。
- **Token**：脚本依次 `-Token`→`GITHUB_TOKEN`→`GH_TOKEN`→凭据管理器→`git credential fill`（放最后，GCM 可能弹 UI 卡死）；本机 WinINET 代理常年失效，脚本已置 `DefaultWebProxy=$null`。
- **暂存纪律**：**别用 `git add -A -- wgime-py-pure`** —— 会把 `wgime-py-pure\testing\`（**永不入库**的草稿目录）一起暂存进去；提交前 `git diff --cached --name-only` 过一眼，并查密钥：`git grep -I -l --cached 'ghp_'`（注意 `--cached` 必须写在**模式之前**，否则 git 直接报错、那条错误会被 `Measure-Object` 当成"命中 1"，白紧张一场）。
- 版本 tag：`v1.0.0` ~ `v1.2.15`（后续版本递增）。插件更新不单独发 release。
  **发版前必跑**（第七十六轮新增）：`python tests\release-assets-check.py --version X --assets <stage>` ——
  断言三个 zip 的 `config.txt` 与仓库模板**逐字节一致**、不含 `sk-` 私钥 / `C:\Users\` 私用路径 / 启用的 `stt_*` 行。
  来由：**v1.2.13 的 python 包带着开发机私用 config（含一把 API key + 本机路径）发了出去**，根因是
  `build-release-assets.ps1` 逐字节打包 `package\`，而那里的 `config.txt` 常常是"本机在用的活配置"。
  自检：拿那份泄漏包跑它必红。
  第八十五轮**又加一条**：单文件里的 `VERSION` 必须**等于** `--version`（自动更新拿它比对；v1.2.14 时代里面还写着
  1.2.12，真机验收时被 `update.verify_source` 拒绝过）—— 自检：拿 1.2.15 的名字跑 → `VERSION='1.2.14-py' vs --version 1.2.15` 红。
  **抠版本一律先认顶层明文 `WGIME_VERSION`**（第八十五轮补起由 `build-wgime-pure.py` 写在 dist 头部）：v1.2.15 发布时
  预检真抓到过"正则被 update.py 自己文档里的版本示例抢先命中 ⇒ 单文件自称旧版本 ⇒ 自动更新永远装不上"，
  详见 §5 规则 47 与 §D35。
  **publish 后必回验**：线上 zip 的 SHA256 与 stage 同、内层 `wgime-py.py` 与 dist 逐字符同、body 无 `?`、
  tag 指向本地 HEAD；本机 `git ls-remote` 到 github 常年连不上，**tag 要用 GitHub API**
  `/repos/<repo>/git/ref/tags/<tag>`，别把空结果当"tag 没建"；资产下载偶 `Unable to connect`，重试即可。
  历史回验记录（v1.2.11~v1.2.14 的 release id 与 SHA 比对）见 §D28。

## 8. 当前状态速览

> 实测数字/探针清单/历史轮次来龙去脉都在 `AGENTS-DETAIL.md`（需要时 read，别凭记忆猜）。

- 已完成一次全面体检并修复高危+中危问题（2026-08-29，main/engine/win/tools/hook/plugins/ui 七模块），详见 CHANGELOG。
- 托盘菜单（ime 模式）：开关 / 模式{混合,拼音,五笔,词典,语音} / 选项{**语音输入**, 繁体输出, 译文, 反查编码, 整句输入,
  联想, 全角标点, 空闲隐藏, 跟随光标, 主题} / 词库{造词, 批量造词, 用户词表, 导入码表} / 这个程序{剪贴板上屏, 标点吞字修复}；
  tray 模式另加 工具箱/内置工具/插件管理/config 应用/运行模式/退出。**勾选态要齐**（每个开关都要有 `get_*`，
  只加 `toggle_*` 会让勾选永远不动）；删除确认要 `default=NO`；造词要校验 2-8 汉字。
- 各插件/模块的审计结论与"别回退"清单（clock/calc/wgtranslate/qr/wspy+chat/bar 粘附/码表导入）见 §D3。
- 纯 Python 版概览：功能与 C# 对齐（含四模式 + 语音）；单文件 `dist\wgime-py.py` 内嵌第三方 zip、**不内嵌插件**；
  数据目录 `%LOCALAPPDATA%\wgime-py`（Store Python 自动切 `USERPROFILE\wgime-py`）。详见 README 与 `docs\WGIME_*.md`。
- 待用户验证：chat 与 PC/Android 真机互通、词库加载速度（缓存命中）、语音中文识别效果（需装 zh-CN 语音包）。
