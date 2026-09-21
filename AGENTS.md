# AGENTS.md — 面向 AI Agent 的项目上下文

> 本文件是给 AI Agent（及多会话）的速查上下文。接手任务时先读这里，避免重复踩坑、避免上下文失忆。
> 人类视角的说明见 README.md；逐版本记录见 CHANGELOG.md。
> **细节在 `AGENTS-DETAIL.md`**：本文件受 64KB 注入预算限制，只放"要照着做的规则"；
> 实测数字、探针清单、历史轮次的来龙去脉都在 `AGENTS-DETAIL.md`，动到相关代码时去 read 对应章节。

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
python wgime-py-pure\tests\standalone-plugin-test.py # 双模式插件: 装载 + 独立运行（6 项）
python wgime-py-pure\tests\tray-swap-test.py          # 托盘换图状态机回归（42 项，§43）
python wgime-py-pure\tests\voice-vad-test.py          # 语音录音 VAD 回归（31 项，§38）
python wgime-py-pure\tests\whisper-warm-test.py       # 常驻 whisper 助手回归（67 项，§38）
python wgime-py-pure\tests\sherpa-warm-test.py        # 常驻 sherpa 助手回归（74 项，§38）
python wgime-py-pure\tests\dot-mouse-test.py          # 状态提示点回归（24 项，无桌面则 SKIP，§D11.2）
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

1. **行尾**：`wgime.bat` 必须 CRLF 无 BOM（.gitattributes `eol=crlf`，仓库存储 LF、checkout 转 CRLF）。build 脚本用 LF 内部处理、写出时转 CRLF。**不要用 -text**（那会导致 blob 存成 LF，别人 clone 后 cmd 解析失败）。
2. **编码**：`wgime.bat` 是 UTF-8 无 BOM（C# 里中文直接用）。`.ps1` 构建脚本必须 ASCII（PS 5.1 按 ANSI 读），非 ASCII 内容放 UTF-8 模板文件。测试脚本也是 ASCII。
3. **提交消息**：含 `>`/`▶`/中文的 commit message 用 `git commit -F 文件`（不要用 `-m`，会破坏 PowerShell 解析）。
4. **大文件推送**：39MB ps1 推送可能 HTTP 408，先 `git config core.compression 0`。
5. **码表 txt**：`py.txt`/`wb.txt`/`ec.txt`/`import_*` 已**入库跟踪**（根目录，构建源）。它们也用于 build-wgime-dll 生成 trailer。
6. **wgime.bat 瘦 DLL 陷阱**：`build-wgime-dll.ps1` 产出的是**含码表 + launcher 的完整 DLL（5.3MB）**，只该给 WgIme.ps1。wgime.bat 的内嵌 DLL 是**纯 WordBoard（555KB）**，必须用 `tests\rebuild-wgime-bat-payload.ps1` 生成——否则 wgime.bat 会涨到 9.6MB。
7. **WordBoard 与 WgImeLauncher 解耦**：WordBoard 不硬引用 WgImeLauncher，用 `TrailerExtractor` 委托字段。bat 版不设置它（码表走 RunApp 参数），ps1 版 launcher 设置它。改动时保持这个解耦。
8. **种子**：首次播种只留 `tools.txt` + `plugins\README.txt` + `plugins\calc.txt`（三段 here-string：`$seedTools`/`$seedPluginReadme`/`$seedCalc`）。config.txt 是运行时 C# `DefaultConfigText()` 生成的，**不是种子**。
9. **自启**：程序**不自带**自启（无 -Install / 无计划任务 / 无菜单自启项）。用户自己挂任务/启动文件夹。
10. **码表数据块 `###WGIME_DATA###`**：wgime.bat 的内置码表（原 5 段 here-string）已移到文件尾部的 `###WGIME_DATA###` 数据块（在 `###WGIME_DLL###` 之前），分段标记 `###PYDATA###`/`###WBDATA###`/`###ECDATA###`/`###PYWORDS###`/`###PYWFREQ###`。PS 引导层用 `Get-DictSeg` 按 `###NAME###` + 下一个 `\n###` 分段提取，码表**不参与 PS 脚本解析**（消除 Invoke-Expression 扫描大 here-string 的启动开销）。cmd bootstrap 用 `$j=$s.LastIndexOf('###WGIME_DATA###')` 截断 `$p`——**必须 LastIndexOf**（marker 也出现在 bootstrap 行本身和提取逻辑注释里，IndexOf 会定位错）。固化码表（`BakeTables`）用 `ReplaceDictSeg(bat,"PYDATA"/"WBDATA"/"ECDATA",…)` 写回数据块对应 segment；`build-wgime-dll.ps1` 用同名 `Get-DictSeg` 从数据块取码表。
11. **遍历字典构建索引必须排序**：.NET `Dictionary` 的遍历顺序取决于键 hash + **插入顺序**；bake 的 `SerializeDict` 按 code 排序重写码表、改变插入顺序。凡是用 `foreach (var kv in <字典>)` 构建顺序敏感的索引/列表（`BuildCharPy`/`BuildAcro`/`BuildCharWb`/`BuildReverse`/`AddWubiWildcard`/`BuildRevWb`）必须改成 `.OrderBy(k => k.Key, StringComparer.Ordinal)`，否则 bake 前后多音字简拼 key、同频候选 tie-break 会不一致。
12. **纯 Python 第三方库内嵌（零 pip 依赖）**：进程内**不再** import `uiautomation`/`comtypes`（光标跟随走 §17 helper）。
    `build-wgime-pure.py` 收第三方**源码**打 zip → 运行时解压 `%LOCALAPPDATA%\wgime-py\site` + `zipimport`。规则：
    ① 用 `m.ispkg` 区分「包 / 单模块」（否则同名模块+包会崩）；② 依赖收**传递闭包**（读 METADATA 的
    `Requires-Dist`，BFS）—— 漏一个就会**回退到宿主 site-packages**、被「构建机恰好装了」盖住；③ roots 只留
    `pystray`，`_THIRD_SKIP` 每条写原因；④ **C 扩展一律不内嵌**（`.pyd` 绑 ABI），只做「可用则用、不可用降级」。
    两个守卫：构建期 `verify_thirdparty_isolation()`（`python -S -E` + 只挂那个 zip，失败**中止构建**）+
    `tests\embedded-isolation-test.py`（改清单必跑，断言清单**正好**是什么）。本机构建 `pystray`+`pillow`+`pypdf`。
    原文见 §D25，边界见 §D13 / §D16。
13. **Store 版 Python 虚拟化 `%LOCALAPPDATA%`**：用户机器 `python` 若命中 Microsoft Store 版 Python（`...\Microsoft\WindowsApps\...PythonSoftwareFoundation...`，AppContainer 沙箱），它对 `%LOCALAPPDATA%` 的写入会被 Windows **重定向（虚拟化）** 到 `...\Packages\<pkg>\LocalCache\Local\`，导致真实 `%LOCALAPPDATA%\wgime-py` **不存在**、用户看不到/管不了词库、配置、导入码表。C# 版无此问题（非 Store 应用）。**修复**：`main.py` 启动时用探针（在 `%LOCALAPPDATA%\wgime-py` 建目录，看 `realpath` 是否含 `\packages\`+`\localcache\`）检测虚拟化，命中则把 `DATA_DIR` 切到 `os.path.expanduser('~')\wgime-py`（真实、不被虚拟化），并把虚拟化位置旧数据搬过去；`build-wgime-pure.py` 的单文件 preamble（`_third_dir`）同样处理。改数据目录逻辑时务必同步 `main.py`（DATA_DIR）与 `build-wgime-pure.py`（preamble `_third_dir`）两处，且检测判断（`\packages\`+`\localcache\`）保持一致。
14. **字频(candidate 排序)保留 python 版逻辑，且已升级**：python 版候选排序用 `语料先验 word_freq + 学习词频 fb×learn_k + 近期热度 freq_recent×recent_k`（常见词靠前 + 主动选过的词上顶 + 最近常打的词靠前），比 C# 版（只按学习词频 `fb`）更优，是**有意保留**的决策，不要"对齐"成 C# 版。配套机制：① 只在"主动选择"(非默认第1位/非动态)时学全量词频 + LastPick 置顶，空格确认默认词不强化；④ `freq_recent` 滑动窗口（RE_CAP=500，上屏即计、溢出自动过期）；② 上屏词退格删除即 `unlearn` 回滚(词频/LastPick/近期窗口)；③ config.txt 的 `learnk`(默认5000)/`recentk`(默认200) 可调。learn/save 递增/上限/保存前20000/flush 与 C# 版一致。
15. **候选条宽度上限（python 版）**：候选条最大宽度封顶 `max(240, min(屏幕工作区宽-24, 880px))`（不再铺满整屏；880 来自 `199f0bd` 修超屏的定论，用户明确嫌长，别改回 720 或铺满屏）；超上限时 `bar.show()` **逐级退化**（第四十五轮：每条都挂提示 → 只给选中那条挂 → 只挂译文 → 只剩词；**绝不把 `(imya)` 切成 `(imya…`**，只有"词"本身太长才截词 + `…`），全部候选仍可见、可数字键选。改 `bar.py` 的候选渲染时保持这一限制与这套退化次序。
16. **插件 Manifest + 权限（wgime-py-pure）**：`.txt` 头部 / `.py` 模块级字段 `code/name/desc/version/author/requires/perm`
    （`.py` 另加 `STANDALONE = True` ＝双模式，见规范 §8.7），`plugins.py plugin_meta()` 统一读取。`perm` 是**逗号多值表**
    （`network,run` 这种），命中 `network/run/registry/destructive` 的插件运行前 `main._confirm_plugin()` 弹确认，
    `run_steps` 对 `file-del/reg-set/reg-del/kill` 前强确认；缺字段默认 `perm=low` 不弹。**txt 登记条件**：
    `code`/`name` 非空**且 `body.Count > 0`** —— 只有头部的半成品不算插件（`error='no body'`，别当解析失败列出），
    头部解析遇第一个非头部行即停。**隔离**：`[python]` 块走**子进程 + JSON IPC**（60s；`handle(ctx)->actions`，
    stdout `@wgime <json>`），`run`/`shell` 超时 120s、静默块 300s —— **别改回同进程 `exec`**（会拖垮宿主）。
    **禁用名单 `plugins-disabled.txt` = 小写文件名**：`main.load_py_plugins`/`plugins.load_plugins`/`main._read_disabled`
    三处都按小写比较，**别改成按 code 过滤**，否则「启停」对 .py 插件无声失效。原文见 §D24。
17. **光标跟随 = 独立 Caret Helper 子进程（wgime-py-pure）**：**第六十八轮起 `followcaret` 默认 0 并冻结** ——
    默认不起 helper、`_caret_follow()` 是唯一读取点, 整条链一行没删, 改 1 或点托盘即恢复（细节/验证见 §D10）。
    主进程**绝不**初始化 COM/UIA（helper 崩溃会拖垮键盘 hook 的教训，别把 UIA 改回进程内跑，别恢复鼠标跟随）。
    `win.py` 把内嵌的 helper 源码（`_EMBEDDED_CARET_HELPER`，纯 ctypes 直调 `UIAutomationCore` vtable）**经环境变量
    `WGIME_CARET_HELPER_SRC` 交给子进程 —— 既不落盘 .py，也不进进程命令行**（**别再改回"落盘 + Popen([...,path])"
    或把源码塞进 `-c`**：前者会被 `runtime\` 里 pythonnet 残留的 python38 整包抢占标准库 import（起来就秒退），
    后者让进程命令行变成 7.4KB 的怪异 `-c`，EDR/任务管理器记的正是这条）。引导脚本先剥掉 `sys.path` 里的
    `''`/`.`/cwd 再 `os.environ.pop` 取走源码执行；命令 `subprocess.Popen([sys.executable,'-u','-c',_HELPER_BOOTSTRAP], env=…)`
    + CREATE_NO_WINDOW 常驻，JSONL stdin/stdout IPC（`request_caret_refresh` → `{id,reason,hwnd}`，reader 线程校验
    `hwnd==请求窗口==当前前台` 才写缓存）。`bar.show()` 每键请求刷新；定位先读 `get_ipc_caret()`，无则按窗口锚点/
    可见位兜底，35/80ms 后 `_ipc_reposition` 贴精确位。`get_caret_pos()` 兜底链：UIA 缓存 → GUITI(rcCaret) →
    聚焦框 → last → 前台原点。**定位的工作区选择别搞错**：跟随用**光标所在显示器**（`win.workarea_at()`），
    带宽上限取**主屏**（`win.screen_workarea()`）；`y+h` 超下边界要翻到光标上方、x 要钳进工作区。`_start_helper`
    保留**连续秒退 3 次后不再重试**（`_helper_fail`）。实测数字/A/B 证据见 §D10 与 CHANGELOG 第三十八/四十三/四十四轮。
18. **可配置快捷键 / 候选操作键（两版共用 config 键）**：`hotkey_toggle/mode/makeword/trad` + `key_first/pageup/pagedown/back/cancel/raw/pickfirst/picklast`。C# 侧在 `KeyBordHook`（`VkFromName`/`ParseHotkey`/`SetKeyConfig`/`MatchMods`，缺省见类字段）；**python 侧在 `hook.py`**（`vk_from_name`/`parse_hotkey`/`configure`/`_rebuild_swallow` + `HOTKEYS`/`KEYS` 状态），由 `main.apply_config()` 用 `CFG['hotkeys']`/`CFG['ckeys']` 安装（`engine.load_config` 只原样收下，缺省在 hook 里），`main.handle()` 的按键分派全部改读 `hook.KEYS`。语义要点：`none`=禁用(0)、无效值忽略保持缺省、`hotkey_toggle` 非 `shift_tap` 时 Shift 轻拍停用、热键在"输入法未激活"时也生效（C# 热键判定在 IsLocked 之前）、组字中吞的候选键 = 配置键 + PgUp/PgDn 常驻。改这块时别再把键位写死回 `VK['SPACE']` 之类。
19. **单实例（wgime-py-pure）**：`win.single_instance('WgImePySingleInstance')`（ctypes 命名互斥体，句柄存 `main._SINGLETON` 保活）+ `win.message_box`（纯 Win32 弹窗，启动早期不建 tk）；已有实例则提示并 `sys.exit(0)`。名字带 `Py` 后缀，与 C# 的 `WgImeSingleInstance` 互不干扰；测试用 `WGIME_NO_SINGLETON=1` 跳过。
20. **联想开关要真的生效**：`engine.assoc_enabled`（由 `main.apply_config` 从 `CFG['assoc']` 同步）同时管**学习**（`learn_assoc` 提前返回）与**显示**（`get_assoc` 返回空 + `main.show_assoc` 提前返回），对齐 C# `AssocEnabled`。以前只翻了托盘勾选、实际照学照显示，是 bug。
21. **反查编码 (showcode) 的方向别搞反**：C# `CodeHint` = 五笔模式显**拼音**码、其余模式显**五笔**码（即"显示另一种码"）。python 侧用 `engine.build_rev_wb`（词→五笔码，按码 ordinal 升序扫、每词取最小码，同 C# `BuildRevWb`）+ `Engine.rev_wb_code()` **后台**建表（第三十四轮改：**首次用绝不同步建** —— `showcode=1` 是出厂默认值，同步建会让**每次启动的首键卡 1326ms**；没建好直接返回 `None`，`warm_rev_wb()` 起后台线程，`_invalidate_rev_wb()` 在 `_build()`/造词改 wb 时失效；详见 §6）。`main._with_code` 是唯一入口。
22. **英汉表 (ec) 只在「词典」模式 (mode 3) 参与候选**：mode 0/1 **绝不能**查 ec（打 `no` 会串出「不/没有/无」
    并把「弄/浓/农」顶掉）；词典模式的 EN 前缀要给**每个命中词的全部释义**，不是只取首个。**第十七轮核对过、
    别再「修」**：mode 3 的候选**集合**与 C# `AddTranslate` 逐条一致（EN 精确 + 前缀 + CN→EN 反查；`ce` 同 C#
    `BuildReverse`，701531 键全等），用**合并**频率视图、**不做** LastPick 置顶 —— **唯一差异**是 §14 的 python
    频率排序，非 bug。「译文」选项（`config trans`，默认开）另管：非词典模式候选挂 `translate_hint`；**仅当本模式
    零候选**（`not cands and not exact_wubi and mode < 3`）才 `candidates(buf,3,py)` 兜底；词典模式本身不挂 `→译文`。
    台账见 §D23。
23. **双拼 (shuangpin>0) 下的门控**（C# `if (Shuangpin == 0)`）：rq/sj/xq 动态候选、v 金额候选、**启动器候选**都不挂（两键即音节会撞码）；`digit_as_code()` 也要带 `CFG['shuangpin'] == 0`。另 `refresh()` 开头要有 C# 的两处面板复位：`sym_cat>0 && buf != 'vf'` 与 `shuangpin>0` 时清 `sym_cat`。
24. **五笔唯一四码自动上屏**要排除启动器候选：`refresh()` 里条件含 `cands[0] != ime.app_cand`（对齐 C# `!appSet.Contains(cands[0])`），否则会"自动启动程序"。
25. **状态反馈 = 托盘气泡（不是弹窗、也不是只写日志）**：C# 所有 `TrayTip`/`ShowBalloonTip` 调用点在 python 都有对应：`msg` 步骤、工具/插件执行结果（`开始执行…`/`完成`/`已取消`/失败）、per-app 上屏与 keyfix 切换结果、启动失败、[csharp] 插件编译/运行错误、造词剪贴板无汉字、钩子安装失败（`hook.start()` 同步返回成功与否 + `last_error()`，main 气泡）。python 侧统一走 `main._notify` → `TRAY.notify`（pystray），无托盘时退回 `tools._msgbox`；tools 层走 `tools._tip`。别再给这类结果提示写回 `_msgbox` 或只写 `_dfn`。
26. **tools.txt / 插件 txt 的块标签集合要完整**：`plugins.py` 的 `_TOOL_BLOCK_TAGS` 必须含 **8 个开标签**（shell/cmd/powershell/ps/shellx/cmdx/powershellx/psx）**与 8 个闭标签**——原来正则漏了 `cmdx`/`powershellx`/`[/cmd]`/`[/ps]` 等，会把块标签建成假按钮、块内容错位。另外 `load_tools` 要认 `[button 名]` 前缀、`code = xx` 允许写在步骤之后（都对齐 C# `LoadTools`）。块标签在 steps 里保留原文，由 `run_steps` 执行期配对（闭标签必须与开标签对应：`[ps]` 只由 `[/ps]` 收尾，同 C#）。**第二十轮补齐的 tools.txt 结构规则别回退**（详见 CHANGELOG 第二十轮 11 组 fixtures）：① 默认标签 `工具` **按需创建**（只含注释的 tools.txt 必须返回**空列表**）；② **没有按钮的标签页要保留**；③ `[tab ]` 空名用 `"?"`；④ `code` 行判定是 C# 的 `t.StartsWith("code")`（大小写敏感）+ `ToolToks(t)[2]`；⑤ 步骤行尾不带 `\r`。
27. **反向差异清单（python 有、C# 没有；别当 bug 去「对齐」掉）**：`cnpunct`+Ctrl+.、`F8`、`Ctrl+Alt+Q`、候选条主题、
    `learnk`/`recentk` 与近期热度排序（§14）、剪贴板「粘贴上屏」、`_CLIP_FORCE`（开始菜单/搜索强制剪贴上屏）、tray 的
    整句/联想/全角标点开关、**「译文」选项**、造词对话框、**鼠标旁状态提示点 `statedot`（默认关，§D11.2）**。
    **要往 C# 补需用户明确要求**（得走 §3 的瘦 DLL + ps1 + 15 项测试整条链）。C# 的 `inDialog` python 有意不跟进
    （python 的造词/导入框含文本框，需要输入法可用）。
    **第五十二轮登记、用户已确认「保持现状」**：① Shift 轻拍更保守（Ctrl/Alt/Win 按住不武装、松键 0.4s 时限）；
    ② 字母键判定排在空格/翻页**之后**（`key_first = a` 时 python 当空格确认、C# 当字母入码）。**python 有意比 C# 好的**：
    `_save_cfg` 写失败弹气泡、`calc._to_long` 越界报 `Err`、`_write_config` 保持 config.txt 原有行尾。
    **第六十七轮**：`keyfix` 牺牲字符用 **`U+200B` 零宽空格**（`win.QT_FIX_SENTINEL`），C# 用可见的 `'X'` ——
    **别再改回 `ord('X')`**；改这块跑 `%TEMP%\wg-r67-qtfix-probe.py`。原文见 §D21。
28. **用户可改的文本一律用 `engine.read_text()` 读**（`utf-8-sig` → `gbk` → `utf-8+replace`）：记事本「另存为
    ANSI(GBK)」之后再严格 `open(..., encoding='utf-8')` 会**抛 UnicodeDecodeError 崩启动**（C# 的
    `File.ReadAllLines(UTF8)` 是替换式解码、不抛）。`read_text` 只以 OSError 表示不可读；新增读取点照此办理。
    名单：`config.txt`/`tools.txt`/`plugins\*.txt`/`pastemode.txt`/`plugins-disabled.txt`/`userwords.txt`/
    `userdict_*.txt`/`lastpick_*.txt`/`assoc.txt`；**便签**（`notes\*.txt`/`notes.txt`/`notes-meta.txt`/`note-color.txt`
    —— 那里的 `except OSError` 抓不到解码错，结果是**便签窗半死**）；**码表与插件**（`py/wb/ec/trad/import_*.txt`
    见 `engine.parse_dict`：快路径 `utf-8-sig`、失败退 `read_text`，BOM 会让**第一行读不进来**；`load_import_base`；
    插件 `.py` 见 `main._py_plugin_meta_static`）。**写的一侧对齐 C# 行尾**：`write_import_file` 必须带
    `newline='\n'`（C# 写裸 LF；`import_*.txt` 入库跟踪，翻成 CRLF 就是整文件 diff）；`config.txt` 是 CRLF 默认即可。
    **读的一侧**：`read_text` 不做 universal newlines，`\r` 会进值 —— 见 §39。原文见 §D22。
29. **未闭合的多行块整块丢弃**（对齐 C# `ParseToolSteps`/`LoadTools`：块只在遇到闭标签时才入 steps）：`plugins.run_steps` 若扫描到行尾仍没找到闭标签，记一条 `块未闭合…已跳过` 就 `continue`，**不要执行**半截块（否则会把后面的行当脚本体跑掉）。
30. **改 `.py` 的脚本必须二进制写（LF）**：`.py` 在仓库里是 **LF**；`open(p,'w',encoding='utf-8')` 在 Windows 上会把
    `\n` 翻成 `\r\n` → **整个文件变成「全部改动」**（曾造成 1885 行幽灵 diff）。用 `newline=''` 或
    `[IO.File]::WriteAllBytes`；改完统计 `\r\n` 应为 0，并核对 `git diff --stat` 的行数。`build-wgime-pure.py`
    内嵌模块源码，**行尾变了要重建 dist**，否则 payload 与源码不一致。
    **txt 按各自 blob 的行尾走**：`core.autocrlf=false` 时 git 比的是**字节**，仓库里一批 txt 是 **blob LF + 工作区 CRLF**
    （历史遗留），字节改写会让整文件报改动 → 先 `git cat-file -p HEAD:<path>` 看 blob 行尾、按它写回、再用
    `git diff --numstat -- <path>` 校验只剩目标行。**行尾不统一**：根 `plugins\wgtranslate.txt` 的 blob 是 LF，
    而 `release\plugins\wgtranslate.txt` 是 CRLF —— `sync-dist.ps1` 逐字节拷完要按 release 的 blob 再写一次。
    **`build-package.ps1` 不可复现**（内嵌 zip 带当前时间戳，源码没改 dist 也会脏）：只改插件等**不内嵌**的文件时，
    构建后 `git checkout -- wgime-py-pure\dist\wgime-py.py` 回退噪声，再跑 `%TEMP%\wgime-dist-sync-check.py`
    确认 dist 与磁盘逐字节一致。原文见 §D20。
31. **config 键的"取值语义"以 C# 为准，白/黑名单别搞混**（第十轮审计发现 `followcaret` 搞混了）：C# `LoadConfig`（wgime.bat 1663-1747）里 **白名单**（`v=="1"||v=="on"||v=="true"`，非法值一律判"关"）= `showcode`/`keyfix`/`followcaret`/`hideidle`/`trad`/`starton`；**黑名单**（`v!="0"&&v!="off"&&v!="false"`，非法值判"开"）= `sentence`/`assoc`。python 侧逐键照此（`engine.load_config`）；python 独有键 `cnpunct` 用黑名单。`paste`（on/always→1, off→2, key/unicode→3, 其余→0）、`shuangpin`（xiaohe/小鹤/flypy→1, ziranma/自然码/zrm→2, ms/微软/mspy→3, 其余→0）、`mode`（仅 `tray` 生效）、`fuzzy`（none/off/空→清空；一对都解析不出则保持缺省）也都与 C# 逐值对齐过（275 组用例）。**改 `load_config` 后要重建 dist + package**（dist 内嵌模块源码）。有意保留：非法 `hotkey_*`/`key_*` C# 保持当前字段、python 回缺省；python 多认单引号 `app =` 命令。

32. **步骤 DSL（`plugins.py` `run_steps`/`_run_verb`）的动词语义对齐 C# `ExecToolStep`**（第十一轮审计）：① `confirm` 的 `title=`/`buttons=`/`default=` 三项必须**真的生效**（`_confirm_args(arg, confirm, **msgbox**)` —— `msgbox` 是参数，原来漏传导致 `buttons=ok` 直接 `NameError` 崩；`okcancel` 走 OK/Cancel，缺省按钮是"否"对齐 C# `MessageBoxDefaultButton.Button2`），回调签名 `confirm(text, title, buttons, default_no)`，保留单参数旧回调兼容；② `kill` 只看**第一个 token**（C# `tk[1]`），不是整行 rest；③ 缺参动词（`run` 无程序名、`reg-set` <4 token、`reg-del` 无键路径）必须**记一步失败**，不能静默成功（C# 是 `tk[n]` 越界抛异常）；④ 多行块控制台显示名按 C# 映射：`cmd→[shell]`、`shellx|cmdx→[shellx]`、`powershellx→[psx]`、`powershell|ps→[powershell]`。python 有意保留：破坏性动词执行前强确认（§16）、块开标签大小写不敏感、`file-del C:\*` 拒删（C# 会真删 C 盘根）。改完 `plugins.py`/`tools.py`/`main.py` 要重建 dist + package。

33. **hook 吞键表的判定次序：别把 `Shift` 提前透传**（第十二轮审计）：C# `bare = !ModifierDown()`，而 `ModifierDown()` **只含 Ctrl/Alt/LWin/RWin**（wgime.bat 124-130）——所以**组字中** `Shift`+数字/退格/Esc/回车/空格/PgUp/PgDn/配置翻页键在 C# 里照样被吞；只有 `a-z`、`;`（SemiAsCode）、以词定字 `[`/`]` 显式要求 `!sh`。python `hook._proc` 的次序必须是：数字（`COMPOSING`）→ `_swallow`（退格/取消/回车/空格/翻页，只要求 bare）→ `_swallow_pick`（`!sh`）→ 中文标点（标准全角映射，全表见 §D17）→ `if shift: 透传` → 裸字母；`_rebuild_swallow` 就按这两组建表。改动后跑 hook 判定矩阵（伪造 lParam + `_key_state` 直接调 `_proc`，见 CHANGELOG 第十二轮 89 例；第七十八轮起 24 组常驻在 harness）再提交。

34. **「自动造词链」`record_commit` 与「词频学习」`engine.learn` 是两件事，别再绑在同一个门控里**（第十三轮审计）：C# 在**每条上屏路径**都调 `RecordCommit`（`Hook_OnSpaced` 空格与数字共用段、`Hook_OnPunct` 标点自动上屏、五笔唯一四码自动上屏），而 python 的 `commit()` 原来把它跟 `engine.learn` 一起塞在 `if i > 0` 里 → "打全拼 + 空格逐字确认"这条最常见的路径永不进 `ime.recent`，**自动造词几乎不触发**。现在的规则：`record_commit(text, code)` 在 `commit()` 里**无条件**调用（含 `commit(0)`，于是五笔自动上屏也覆盖）、`handle_punct` 自动上屏首候选时也补记；**只有动态候选/`vf` 面板符号不参与**（提前 return）。`if i > 0` 只该管 `engine.learn` + `_last_learn`(LastPick/词频回滚)。改上屏路径后跑 CHANGELOG 第十三轮的 headless 状态机 harness（真 engine + 出口打桩 + 临时 `LOCALAPPDATA`，别碰用户数据）。

35. **别把代码写进行尾注释 —— 用 `tests\undefined-globals.py` 兜底（第四十轮的真 bug）**：`win.py` 曾经是
    `_helper_t0=[0.0]; _helper_fail=[0]   # …; _ipc_req_hwnd={}; _last_fg=[0]` —— 两个全局量被**行尾注释吞掉**，
    从未定义，而 `request_caret_refresh()` 会 `_ipc_req_hwnd[rid]=hwnd`（NameError → 被它自己的 `except Exception`
    吞掉 → **`p.kill()` 杀掉跟随 helper**）、`get_caret_pos()` 第一行读 `_last_fg[0]`（NameError 直接抛 → 候选条
    定位失败）。表现完全不像"未定义变量"：跟随失效、每键杀一个 python 子进程、`_helper_fail` 三次后不再起 helper。
    **C# 侧有编译器兜（用不存在的字段直接 CS0103），python 侧没有** —— 所以：① 改完 `.py` 跑
    `python wgime-py-pure\tests\undefined-globals.py`（symtable 版 mini-pyflakes，扫"引用了不存在的全局量"，
    应输出 0）；② 写注释时别在行尾追加"示例代码"；③ 参与"是否还活着"判断的全局量（`_helper_fail`/`_ipc_done`）
    出现异常时先怀疑这类错误。

36. **托盘图标"个别机器看不见"的根因 = 宿主没装 Pillow（第四十一/四十二轮，别再依赖 PIL）**：
    托盘图标**构建时**渲染成 9 个 ICO 内嵌（`build-wgime-pure.py` → `TRAY_ICONS`），运行时
    `win.icon_from_ico_bytes()` 写进 `runtime\icons\` 再 `LoadImageW` 成 HICON，**不再需要宿主 Pillow**
    （PIL 带 `_imaging.pyd`，ABI 绑定，内嵌源码跨版本没用 —— 没装的机器 `import PIL` 失败 → **整个托盘消失**）；
    换图标走 `NIM_MODIFY|NIF_ICON`（看 `tray.NIM['modify_ok']`）；`HAS_PIL` 只作源码布局的回退路径。
    诊断（别删）：pystray 报错只走 `logging`→`sys.stderr`，而 pythonw 下 `sys.stderr is None` → 收
    `tray.LOGS`/`NIM['add_ok']`/`last_error`，`main._tray_selfcheck()` 写 **always-on** 日志并在真失败时
    **从后台线程**弹框（主线程弹会卡住 poll=打字停摆）。三个坑：① `Shell_NotifyIconGetRect` 不能当
    "登记上没有"的判据；② GetRect 的 uID 必须是 `id(icon)`；③ 判断"用户能不能看见"用 `win.tray_promoted()`。
    判据固定为: 用 `python -S -E` 跑一遍真成品，或跑 `tests\embedded-isolation-test.py`；探针 `%TEMP%\wg-r70-clean-live.py`。

37. **译文质量 = 英语常用词表（第四十五轮）**：`ce` 由 `ec.txt` 反建，旧代码取字母序第一个 →
    `测试→dvdram`/`你好→alohas`/`老师→dorina`（生僻词/人名/缩写，用户实测"不太妙"）。现在
    `build_reverse(ec, load_en_rank(dict_dir))`：按 `en-freq.txt`（Hermit Dave FrequencyWords `en_50k`，
    **MIT**，随分发目录一起发）排序，**没有常用英语词的干脆不进 `ce`**（查不到就不挂）；表读不到就退回
    旧行为（stderr 说明）。`EN_HINT_MAX_RANK=50000` 可调；`en-freq.txt` 在 `CACHE_FILES` 里（换表 → 老缓存失效一次）。

38. **语音输入（python 独有）**：`voice.py` = waveIn 录音（纯 ctypes，VAD 静音自停，**别用已移除的 `audioop`**）+
    五后端（`voice_engine`：`system` 离线引擎（`powershell -EncodedCommand` 内联、不落盘、base64 回传）/ `http`
    Whisper 兼容 / `whisper` 常驻 faster-whisper / `sherpa` 常驻 sherpa-onnx（首选）/ `cmd` 外部命令带 `{wav}` /
    `stream` 流式云端（OpenAI 兼容 SSE；payload 按 URL 关键字选：含 `dashscope`/`aliyuncs` → `input_audio`(+`asr_options`)，
    否则 `audio_url`））。热键 `hotkey_voice`（Ctrl+Alt+V）按住说话，`WM_KEYUP` 报 `VK_VOICE_UP`，**只在 `VOICE_ON`
    为真时吞键**（按下也要门控）。`MODE_VOICE=4` 里钩子**全部透传**、轻点热键=常录；**切到语音模式 = 顺手开语音**
    （`_voice_set_on`，幂等），离开不关；**选项里关语音时若在语音模式则自动切回混合**。结果默认进候选条等空格
    （`voice_auto=1` 直接上屏；`voice_click=1` 点击落点＝只进剪贴板 + 提示，见 §D14），上屏走 `inject()` 但
    **不进词频学习**。麦克风 Deny（`waveInOpen` rc=1）→ 提示去开「设置→隐私和安全性→麦克风」。`_write_config()`：
    文件不存在要**新建**、返回 True/False（别静默失败）。
    **硬规则**（叙事/数字/探针见 §D6 / §D7 / §D8 / §D12 / §D14）：① 按住热键的**自动重复必须丢**（`KBDLLHOOKSTRUCT`
    里没有重复标志）：`if VOICE_DOWN[0]: return 1`，并在修饰键已松开处清标志；② 录音期间 ~4Hz 重画候选条
    （`main._voice_tick()`）；③ VAD 阈值 `thr = min(clamp(floor*3.5,180,1200), clamp(peak*0.25,180,600))`
    （`floor` 取**最小** RMS、`peak` 每块 ×0.9 慢衰减）—— **别改回「只留 thr_abs」或「头 500ms 取中位数」**；
    关自动停用 `voice_silence = 0`；全 0 PCM 报「纯静音」；④ 每次录音/系统识别各留一行 **always-on** 诊断；
    ⑤ `http` 统一走 `voice._http_post`（`stt_proxy`）：**每条路都重建 `Request`**、**服务端回过话(HTTPError)就不换路
    不重发**、把**每条路的原因**一起报出来；⑥ 系统引擎 `Recognize()` **一次只返回一段**，循环收齐再拼（CJK `''`、
    其它 `' '`），流读完**再调会抛**，循环内 try 住 break。改 VAD 必须跑 `voice-vad-test.py`（31 项）。
    **常驻助手**（whisper/sherpa 同一套 `_WarmSrv`，只有 `key/spawn/request_obj` 三个钩子不同）：照 §17 helper 的套路
    （源码走环境变量 / JSONL 走 stdio / **回包用 `ensure_ascii` JSON** / **父进程退出=stdin EOF=子进程自退**）。
    **两个锁别合并**：`lock` 管起杀（预热在主线程调、绝不能等识别）、`rlock` 管一问一答；预热＝启动 +4s 后台
    （`stt_prewarm=0` 关）+ **按下热键那一刻**。跑 `whisper-warm-test.py`（67）/ `sherpa-warm-test.py`（74）。
    **key 语义两边不同**：sherpa 的 `itn`/`lang`/`threads`/`script` 是**建识别器**的参数（改了要重启助手），
    whisper 的 `lang`/`prompt`/`beam` 每次请求带。这套东西**在仓库外、按机器各装一份**（见 §D8.2）。
    **坏网络**：国内站 key 必须配 `api.siliconflow.cn`（`.com` 回 401）；`stt_retry`（同路默认 3，**HTTPError 不重试**）、
    `stt_timeout`（默认 15s）、**记住可用路径**；`voice_fallback` = 两引擎**同时开跑、谁先成功用谁**，都失败才报错，
    `http` 配了它时重试/超时收紧成 2×10s。原文见 §D27。
39. **`read_text` 的行尾 `\r` 不能进值（第五十轮真 bug）**：`read_text` **不做 universal newlines**，CRLF 的 `\r`
    会留在行尾、被当成词的一部分存进 `lastpick_m`；写盘时 text 模式又把 `\n` 翻成 `\r\n` → **每轮载入/存盘多一个 `\r`**。
    **真危害**不是文件难看，而是 `candidates()` 的 LastPick 置顶靠**值比较**（`if lp and lp in cands`）—— 带 `\r`
    的值永不相等，「上次选的词置顶」**静默失效**。**规则**：按 `'\n'` 切行后第一件事 `line = line.rstrip('\r')`
    （或 `rstrip('\r\n')`）；**新写的解析点别省这一步**。写盘仍保持 CRLF（同 C# `File.WriteAllLines`），脏文件
    下次载入自愈。永久回归：harness（`lastpick 值不带 \r` + `lastpick 仍置顶`）+ `%TEMP%\wg-r50-lastpick-probe.py`；
    叙事见 §D4。
40. **全量审计的硬规则（第五十一轮；明细见 CHANGELOG 第五十一轮与 §D5）**：
    ① **`_merge_user_words` 必须 py + wb + acro 三样都补**，且 `_init_state` 里三张派生表（char_wb/wb_by_len/word_freq）
    要在合并用户词**之前**就绪（合并要用 `char_wb` 算五笔构词码）；
    ② **读用户文件要先读完再动内存**（别开头就 `ALARMS.clear()`，读失败就只剩"空"，紧接着的 `save_cfg` 会覆盖整份）；
    ③ **缓存/索引签名要覆盖它依赖的全部输入**（漏了 `userwords.txt` 就会出现删不掉的"幽灵词"）；
    ④ **给 helper/子进程写管道必须非阻塞**（helper 串行读 stdin + 4KB 管道 ⇒ `stdin.write` 会把 Tk 主线程永久阻塞；
    改 `os.set_blocking(fd, False)` + `os.write`，满则丢弃这次刷新）；
    ⑤ **后台线程里的异常必须兜住并报出来**（pythonw 下 `sys.stdout/stderr` 都是 None，裸线程抛异常完全无声）——
    `main._bg_plugin` 是统一入口；
    ⑥ 菜单/图标/模式表索引一律 `% len(表)`，不要写死数字；
    ⑦ `.py` 插件的"停用"判断要在 `exec_module` **之前**（否则被停用的插件每次启动仍执行模块级副作用）；
    ⑧ **权限是多值的**：`perm` 支持 `network,run` 这类逗号列表，判定要拆集合求交，别用整串 `in`。

41. **`place()` 的子控件不撑大父容器 —— Canvas 滚动区的 `inner` 必须显式给尺寸（第五十三轮真 bug）**：
    `tools.py show_toolbox` 用 `Canvas` + `create_window(inner)`，磁贴由 `ui.flat_button` 用 **`place()`** 摆；
    `place()` 不进父容器的 requested size → `inner` 只有 **1x1**、`canvas.bbox('all')==(0,0,1,1)`、`winsize=0x0`，
    磁贴**建出来了却全被裁掉**（「标签页在、按钮一个都看不见」）。修法**三件事都要做**：
    `inner.configure(width=,height=)` + `create_window(...,width=,height=)` + `canvas.configure(scrollregion=(0,0,w,h))`
    （只设 scrollregion 不解决裁剪）。**判据**：`bbox('all')==(0,0,1,1)` 即中招；凡「Canvas + place 子控件」照此办。
    连带：① 滚动条**只在内容真超出可视区时** place（`need_sb = inner_h > BODY_H`），磁贴宽度恒用 `inner_w`；
    ② 挂在 `content` 上的控件按**内容区**高度算 y/height（`content` 是标题栏下方那块：`y=38,height=h-38`），
    统一用 `CH = H - 38` 推；底部日志 `ui.console_text` 要有**垂直滚动条 + 滚轮**（工具箱/网络工具/聊天窗共用）。
    数字/探针见 §D19。
42. **`ui.make_window` 的窗口高度 = 内容真正需要的高度 + 38（标题栏）（第五十五轮，一次修了 5 个窗口）**：
    `content` 只占 `h-38`，按「可用区」排 y/height 却按整窗高给高度 → **底部控件被窗口边缘裁掉**（剪贴板/取色器/
    造词/用户词表/插件管理都中过）。同轮还修：插件管理顶部按钮条总宽超出 bar（最右按钮被切）、剪贴板那句提示
    不限定宽度又放在 `x=390`（右边缘冲出窗口）→ 挪到按钮下方单独一行 + 显式 `width`。**审计别靠肉眼**：把窗口建出来
    遍历子孙算绝对 `(x+w,y+h)` 比窗口宽高 —— `%TEMP%\wg-window-audit2.py`（10 个内置工具窗）、`wg-window-audit3.py`
    （造词/用户词表用假 engine）；数字见 §D26。**便签滚动条按需**：`yscrollcommand` 里判 `yview()==(0.0,1.0)`
    （装得下）就 `place_forget`，溢出才 `place`，**正文宽度保持不变**。**给 tk 窗口设 Win32 样式必须写「顶层外框」**：
    `winfo_id()` 是 `TkChild` 子窗口，真正的外框是 `GetAncestor(GA_ROOT)` → 用 `win.top_level_hwnd()`
    （写子窗口上等于没生效，§D11.1）。
43. **托盘图标的句柄时序（第五十六/五十七轮）**：
    ① **图标还没登记上（`icon.visible` 为假）时绝不换图** —— 否则 shell 记住的是**已销毁的句柄**。
    ② **换图顺序:先注入新句柄 → `NIM_MODIFY` → shell 接受之后才 `DestroyIcon` 旧句柄**。pystray 的
    `_release_icon()` 销毁的是**当前** `_icon_handle`（不是刚换下来的那个），销毁旧句柄用 `win.destroy_icon()`；
    同一张图（key 相同）重复刷新只 `update_menu()`，不重建 HICON、不惊动 shell。
    ③ **图标要"早挂"**：词库加载是**主线程 join**，`_boot_tray()` 在 join **之前**先挂最小菜单图标，
    词库读完由 `_deferred_tray` 补完整菜单；**别把 `_boot_tray()` 挪到 join 之后**；`tray.start(boot=True)`
    用最小 api（只有 toggle/is_active/get_mode/quit），**不要在 boot 分支里加需要 CFG/工具/插件的调用**。
    ④ **换图"成没成"只能看 `NIM['modify_ok']`，绝不能看 `icon._message()` 的返回值**（pystray `_win32._message()`
    **没有 return** → `bool(...)` 恒为 False）。换图统一走 `Tray._notify_icon(h, key, old)`，状态拆两个：
    `_cur_key` = pystray 当前句柄对应的 key（注入后立刻推进），`_shown_key`/`_shown_handle` = **shell 确认接受**过的
    （只有 `modify_ok is True` 才销毁旧的；**shell 拒收时不谎报**，下次用同一个句柄补发）。改这块**必须**跑
    `tray-swap-test.py`（42 项）—— **桩不能比真的更宽容**（假 icon `return True` 就漏掉了本回归）；记住：
    **一个不会失败的测试等于没写**。故事/实测见 CHANGELOG 第五十六/五十七轮。

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
- 版本 tag：`v1.0.0` ~ `v1.2.14`（后续版本递增）。插件更新不单独发 release。
  **发版前必跑**（第七十六轮新增）：`python tests\release-assets-check.py --version X --assets <stage>` ——
  断言三个 zip 的 `config.txt` 与仓库模板**逐字节一致**、不含 `sk-` 私钥 / `C:\Users\` 私用路径 / 启用的 `stt_*` 行。
  来由：**v1.2.13 的 python 包带着开发机私用 config（含一把 API key + 本机路径）发了出去**，根因是
  `build-release-assets.ps1` 逐字节打包 `package\`，而那里的 `config.txt` 常常是"本机在用的活配置"。
  自检：拿那份泄漏包跑它必红。
  **发布回验记录**（publish 之后必做：线上 zip 比对 + body 逐字符 + tag 指向本地 HEAD；本机 `git ls-remote`
  到 github 常年连不上，**tag 要用 GitHub API** `/repos/<repo>/git/ref/tags/<tag>`，别把空结果当"tag 没建"）：
  v1.2.14（id 391874873，tag = 本地 HEAD `d85a98e`）与 v1.2.11/v1.2.12/v1.2.13（python 资产已换成干净包，
  tag 仍 `56f7ffe`）= 三个 zip 的 SHA256 与 stage 全同、body 无 `?` 且与本地逐字符一致、内层 `wgime-py.py`
  与 dist 逐字节一致（逐项数字/release id 见 CHANGELOG）；线上资产下载偶尔 `Unable to connect`，重试即可。

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
