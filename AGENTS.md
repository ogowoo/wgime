# AGENTS.md — 面向 AI Agent 的项目上下文

> 本文件是给 AI Agent（及多会话）的速查上下文。接手任务时先读这里，避免重复踩坑、避免上下文失忆。
> 人类视角的说明见 README.md；逐版本记录见 CHANGELOG.md。

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
python tests\pure-state-harness.py                    # 纯 Python 版状态机 headless 回归（16 项，不装钩子/不联网）
python tests\pure-state-harness.py --ref HEAD~1       # 对旧版本的 main.py 跑同一组用例（before/after 对照）
```

- **`tests\pure-state-harness.py`（纯 Python 版状态机回归）**：真跑 `wgime-py-pure\main.py` 的**前缀**（截止到 `# ---------- 主循环: 轮询钩子事件 ----------`，真 engine + 真状态机），只把副作用出口打桩（注入/托盘/词频落盘/插件执行/启动器）；进程内把 `LOCALAPPDATA` 指到临时目录（用完删）、`WGIME_DICT_DIR` 默认 `wgime-py-pure\package\dicts`（无则仓库根），**用户真实的 `%LOCALAPPDATA%\wgime-py` 绝不读写**（脚本会断言 `DATA_DIR` 在临时目录内，否则退出码 2）。改上屏路径/状态机（`commit`/`record_commit`/`handle`/`handle_punct`/`refresh`）后跑它。首跑会打印一条 `[wgime] dict-cache load failed`（隔离目录无缓存）属正常。

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
12. **纯 Python 第三方库内嵌（零 pip 依赖）**：python 版（`wgime-py-pure`）早期现代应用光标跟随用 `uiautomation`（纯 Python，基于 `comtypes`）在进程内跑，2026-09 起已改为**独立 Caret Helper 子进程（见 §17，纯 ctypes vtable，进程内不再 import uiautomation/comtypes）**。内嵌机制保留：`build-wgime-pure.py` 收集第三方源码打包 zip，运行时解压到 `%LOCALAPPDATA%\wgime-py\site` + `zipimport`（标准 import 机制，包结构正确）。**收集时用 `m.ispkg` 区分**——包写 `__init__.py`、模块写 `.py`，否则同名模块+包（`comtypes._post_coinit`）会崩。本机构建仍要 `pip install uiautomation`（从已装包读源码），分发的单文件零依赖。
13. **Store 版 Python 虚拟化 `%LOCALAPPDATA%`**：用户机器 `python` 若命中 Microsoft Store 版 Python（`...\Microsoft\WindowsApps\...PythonSoftwareFoundation...`，AppContainer 沙箱），它对 `%LOCALAPPDATA%` 的写入会被 Windows **重定向（虚拟化）** 到 `...\Packages\<pkg>\LocalCache\Local\`，导致真实 `%LOCALAPPDATA%\wgime-py` **不存在**、用户看不到/管不了词库、配置、导入码表。C# 版无此问题（非 Store 应用）。**修复**：`main.py` 启动时用探针（在 `%LOCALAPPDATA%\wgime-py` 建目录，看 `realpath` 是否含 `\packages\`+`\localcache\`）检测虚拟化，命中则把 `DATA_DIR` 切到 `os.path.expanduser('~')\wgime-py`（真实、不被虚拟化），并把虚拟化位置旧数据搬过去；`build-wgime-pure.py` 的单文件 preamble（`_third_dir`）同样处理。改数据目录逻辑时务必同步 `main.py`（DATA_DIR）与 `build-wgime-pure.py`（preamble `_third_dir`）两处，且检测判断（`\packages\`+`\localcache\`）保持一致。
14. **字频(candidate 排序)保留 python 版逻辑，且已升级**：python 版候选排序用 `语料先验 word_freq + 学习词频 fb×learn_k + 近期热度 freq_recent×recent_k`（常见词靠前 + 主动选过的词上顶 + 最近常打的词靠前），比 C# 版（只按学习词频 `fb`）更优，是**有意保留**的决策，不要"对齐"成 C# 版。配套机制：① 只在"主动选择"(非默认第1位/非动态)时学全量词频 + LastPick 置顶，空格确认默认词不强化；④ `freq_recent` 滑动窗口（RE_CAP=500，上屏即计、溢出自动过期）；② 上屏词退格删除即 `unlearn` 回滚(词频/LastPick/近期窗口)；③ config.txt 的 `learnk`(默认5000)/`recentk`(默认200) 可调。learn/save 递增/上限/保存前20000/flush 与 C# 版一致。
15. **候选条宽度上限（python 版）**：候选条最大宽度封顶 `max(240, min(屏幕工作区宽-24, 880px))`（不再铺满整屏；880 来自 `199f0bd` 修超屏的定论，用户明确嫌长，别改回 720 或铺满屏）；候选总宽超上限时 `bar.py show()` 动态收紧候选截断（24→8 字符逐档），全部候选仍可见、可数字键选。改 `bar.py` 的候选渲染时保持这一限制与当前公式。
16. **插件 Manifest + 权限（wgime-py-pure）**：plugins/*.txt 头部支持 `code/name/desc/version/author/requires/perm`；plugins/*.py 模块级 `CODE/NAME/DESC/VERSION/AUTHOR/PERM`。`plugins.py plugin_meta()` 统一读取（兼容两类）；`perm=network/run/registry/destructive` 的插件运行前 `main._confirm_plugin()` 弹确认，`run_steps` 对 `file-del/reg-set/reg-del/kill` 动词前强确认。旧插件无这些字段默认 `perm=low`，不弹确认。**插件 txt 的登记条件**（第二十一轮核对）：C# `LoadPlugins` 要求 `code`、`name` 非空**且 `body.Count > 0`**（头部之后至少有一行，哪怕是空行/注释）——所以「只有头部」的半成品文件**不算插件**，`parse_plugin` 会返回 `error='no body'`，插件列表里不该出现（别再把它当"解析失败"列出来）。头部解析在**第一个非头部行**处停止，之后出现的 `code=` 只是普通步骤行。改插件加载/执行时别破坏这一权限模型。**③④ 隔离+JSON IPC**：`[python]` 块子进程运行（超时60s）+ JSON IPC 契约（`handle(ctx)->actions`，stdout `@wgime <json>` 行协议）；`run_steps` 的 `run`/`shell` 超时 120s、静默块 300s；别把 `[python]` 块改回同进程 `exec`（会拖垮宿主）。**插件禁用名单（`plugins-disabled.txt`）= 小写文件名**（对齐 C# `DisabledPlugins`）：`main.load_py_plugins` 按 `fn.lower() in disabled` 判定（内嵌插件无文件才退回 code，生产分发不内嵌插件）；`plugins.py load_plugins` 与 `main._read_disabled` 两侧都小写。插件管理器写的也是文件名——**别把装载器改回按 code 过滤，否则「启停」对 .py 插件无声失效**。
17. **光标跟随 = 独立 Caret Helper 子进程（wgime-py-pure，对齐 testing v3）**：主进程**绝不**初始化 COM/UIA。`win.py` 把内嵌的 helper 源码（`_EMBEDDED_CARET_HELPER`，纯 ctypes 直调 `UIAutomationCore` vtable，无 comtypes/uiautomation）落盘到 `%LOCALAPPDATA%\wgime-py\runtime\wgime-caret-helper-v3-stable-embedded.py`，用 `subprocess.Popen([sys.executable,'-u',path])` + CREATE_NO_WINDOW 常驻，JSONL stdin/stdout IPC（`request_caret_refresh` → `{id,reason,hwnd}`，reader 线程校验 `hwnd==请求窗口==当前前台` 才写缓存，过期结果丢弃）。`bar.show()`（跟随且出候选时）每键请求刷新；定位先读 `get_ipc_caret()`，无新结果则用 per-window anchor/当前可见位兜底，35/80ms 后再 `_ipc_reposition` 贴精确位。`get_caret_pos()` 兜底链：UIA 缓存(前台未变时) → GUITI(rcCaret.top+抖动检测) → 聚焦输入框矩形 → last → 前台原点；**鼠标兜底禁用**。改动时别把 UIA 改回进程内跑（helper 崩溃会拖垮键盘 hook 的教训），别恢复鼠标跟随。注意：若 `runtime\` 残留 pythonnet 时代的 python38 整包（`_ctypes.pyd` 等），helper 与其同目录会因 pyd 抢占导入而 ImportError → 静默回退纯 Win32 链（仍可跟随，只是无 UIA 精度）；不要为"修"这个失败随意改路径，先确认用户机器是否有该残留。**定位的工作区选择别搞错**（第十五轮核对）：跟随用**光标所在显示器**（`win.workarea_at()` → `MonitorFromPoint(MONITOR_DEFAULTTONEAREST)`+`GetMonitorInfoW`），而带宽上限取**主屏**（`win.screen_workarea()` → `SPI_GETWORKAREA`）—— 与 C# 的 `Screen.FromPoint` / `Screen.PrimaryScreen` 一一对应；`y+h` 超下边界要翻到光标上方、x 要钳进工作区（几何断言见 CHANGELOG 第十五轮）。
18. **可配置快捷键 / 候选操作键（两版共用 config 键）**：`hotkey_toggle/mode/makeword/trad` + `key_first/pageup/pagedown/back/cancel/raw/pickfirst/picklast`。C# 侧在 `KeyBordHook`（`VkFromName`/`ParseHotkey`/`SetKeyConfig`/`MatchMods`，缺省见类字段）；**python 侧在 `hook.py`**（`vk_from_name`/`parse_hotkey`/`configure`/`_rebuild_swallow` + `HOTKEYS`/`KEYS` 状态），由 `main.apply_config()` 用 `CFG['hotkeys']`/`CFG['ckeys']` 安装（`engine.load_config` 只原样收下，缺省在 hook 里），`main.handle()` 的按键分派全部改读 `hook.KEYS`。语义要点：`none`=禁用(0)、无效值忽略保持缺省、`hotkey_toggle` 非 `shift_tap` 时 Shift 轻拍停用、热键在"输入法未激活"时也生效（C# 热键判定在 IsLocked 之前）、组字中吞的候选键 = 配置键 + PgUp/PgDn 常驻。改这块时别再把键位写死回 `VK['SPACE']` 之类。
19. **单实例（wgime-py-pure）**：`win.single_instance('WgImePySingleInstance')`（ctypes 命名互斥体，句柄存 `main._SINGLETON` 保活）+ `win.message_box`（纯 Win32 弹窗，启动早期不建 tk）；已有实例则提示并 `sys.exit(0)`。名字带 `Py` 后缀，与 C# 的 `WgImeSingleInstance` 互不干扰；测试用 `WGIME_NO_SINGLETON=1` 跳过。
20. **联想开关要真的生效**：`engine.assoc_enabled`（由 `main.apply_config` 从 `CFG['assoc']` 同步）同时管**学习**（`learn_assoc` 提前返回）与**显示**（`get_assoc` 返回空 + `main.show_assoc` 提前返回），对齐 C# `AssocEnabled`。以前只翻了托盘勾选、实际照学照显示，是 bug。
21. **反查编码 (showcode) 的方向别搞反**：C# `CodeHint` = 五笔模式显**拼音**码、其余模式显**五笔**码（即"显示另一种码"）。python 侧用 `engine.build_rev_wb`（词→五笔码，按码 ordinal 升序扫、每词取最小码，同 C# `BuildRevWb`）+ `Engine.rev_wb_code()` **后台**建表（第三十四轮改：**首次用绝不同步建** —— `showcode=1` 是出厂默认值，同步建会让**每次启动的首键卡 1326ms**；没建好直接返回 `None`，`warm_rev_wb()` 起后台线程，`_invalidate_rev_wb()` 在 `_build()`/造词改 wb 时失效；详见 §6）。`main._with_code` 是唯一入口。
22. **英汉表 (ec) 只在「词典」模式 (mode 3) 参与候选**（C# `AddTranslate`）：`engine.candidates` 的 mode 0/1 绝不能查 ec——实测拼音模式打 `no` 会串出"不/没有/无"并把"弄/浓/农"顶掉。词典模式的 EN 前缀匹配要给**每个命中词的全部释义**（C# `AddCands`），不是只取首个。**第十七轮核对结论（别再"修"）**：mode 3 的候选**集合**与 C# `AddTranslate` 逐条一致 —— EN 精确 + EN 前缀 + CN→EN 反查（`PyDict` 全拼 + `Acro` 简拼 → 每个中文词查 `ce`）；`ce`（CN→EN）由 `build_reverse` 建，与 C# `BuildReverse` 逐行一致（EN ordinal 升序、每词上限 8、去重），实测 **701531 键全等**；mode 3 用**合并**频率视图（`self.freq`，同 C# `fb = ... : Freq`）且**不做** LastPick 置顶（同 C# `lpb = null`）。**唯一差异是 python §14 的频率排序**（稳定排序，探针复算后与 engine 输出逐项相同），不是 bug。
23. **双拼 (shuangpin>0) 下的门控**（C# `if (Shuangpin == 0)`）：rq/sj/xq 动态候选、v 金额候选、**启动器候选**都不挂（两键即音节会撞码）；`digit_as_code()` 也要带 `CFG['shuangpin'] == 0`。另 `refresh()` 开头要有 C# 的两处面板复位：`sym_cat>0 && buf != 'vf'` 与 `shuangpin>0` 时清 `sym_cat`。
24. **五笔唯一四码自动上屏**要排除启动器候选：`refresh()` 里条件含 `cands[0] != ime.app_cand`（对齐 C# `!appSet.Contains(cands[0])`），否则会"自动启动程序"。
25. **状态反馈 = 托盘气泡（不是弹窗、也不是只写日志）**：C# 所有 `TrayTip`/`ShowBalloonTip` 调用点在 python 都有对应：`msg` 步骤、工具/插件执行结果（`开始执行…`/`完成`/`已取消`/失败）、per-app 上屏与 keyfix 切换结果、启动失败、[csharp] 插件编译/运行错误、造词剪贴板无汉字、钩子安装失败（`hook.start()` 同步返回成功与否 + `last_error()`，main 气泡）。python 侧统一走 `main._notify` → `TRAY.notify`（pystray），无托盘时退回 `tools._msgbox`；tools 层走 `tools._tip`。别再给这类结果提示写回 `_msgbox` 或只写 `_dfn`。
26. **tools.txt / 插件 txt 的块标签集合要完整**：`plugins.py` 的 `_TOOL_BLOCK_TAGS` 必须含 **8 个开标签**（shell/cmd/powershell/ps/shellx/cmdx/powershellx/psx）**与 8 个闭标签**——原来正则漏了 `cmdx`/`powershellx`/`[/cmd]`/`[/ps]` 等，会把块标签建成假按钮、块内容错位。另外 `load_tools` 要认 `[button 名]` 前缀、`code = xx` 允许写在步骤之后（都对齐 C# `LoadTools`）。块标签在 steps 里保留原文，由 `run_steps` 执行期配对（闭标签必须与开标签对应：`[ps]` 只由 `[/ps]` 收尾，同 C#）。**第二十轮补齐的 tools.txt 结构规则别回退**：① 默认标签 `工具` **按需创建**（第一个 `[cols N]`/按钮出现时才建；只含注释的 tools.txt 必须返回**空列表**，好让 `show_toolbox` 给"tools.txt 为空"提示）；② **没有按钮的标签页要保留**（C# 会显示成空页，别再 `filter(t['buttons'])`）；③ `[tab ]` 空名字用 `"?"`；④ `code` 行的判定是 C# 的 `t.StartsWith("code")`（**大小写敏感**）+ `ToolToks(t)[2]` 非空 → 认 `code = x`/`codes = x`/`code = x 多余`，`CODE = x` 不算 code 行（会当步骤）；⑤ 步骤文本行尾不带 `\r`（`rstrip('\r\n')`）。oracle 对照见 CHANGELOG 第二十轮 11 组 fixtures。
27. **反向差异清单（python 有、C# 没有；别当成 bug 去"对齐"掉）**：`cnpunct` + Ctrl+. 全角标点切换、`F8` 硬开关、`Ctrl+Alt+Q` 退出、候选条主题（dark/light）、`learnk`/`recentk` 与近期热度排序（§14）、剪贴板「粘贴上屏」、`_CLIP_FORCE`（开始菜单/搜索强制剪贴板上屏，C# 在那类 UI 里注入会失败）、tray 的整句/联想/全角标点开关、造词对话框（C# 是剪贴板直造）。**要往 C# 补需要用户明确要求**：改 wgime.bat 得走 §3 的瘦 DLL + ps1 + 15 项测试整条链。C# 的 `inDialog`（自带模态框期间让按键直通）python 有意不跟进——python 的造词/导入框含文本框，需要输入法可用。
28. **用户可改的文本一律用 `engine.read_text()` 读**（`utf-8-sig` → `gbk` → `utf-8+replace`）：中文 Windows 下记事本/编辑器"另存为 ANSI(GBK)"会把 config.txt / tools.txt / plugins\*.txt / pastemode.txt / plugins-disabled.txt / userwords.txt / userdict_*.txt / lastpick_*.txt / assoc.txt 写成非 UTF-8 —— 用 `open(..., encoding='utf-8')` 会**抛 UnicodeDecodeError 直接崩启动**（C# 侧 `File.ReadAllLines(UTF8)` 是替换式解码, 不抛）。`read_text` 只以 OSError 表示不可读，编码问题一律降级；新增读取点照此办理（plugins.py 已 `import engine as engmod` 复用）。**便签文件也在名单里**（第二十三轮）：`notes\*.txt`（便签正文，用户最常拿记事本改）、`notes.txt`（旧版迁移源）、`notes-meta.txt`、`note-color.txt` —— 用严格 `open(..., encoding='utf-8')` 读会抛 `UnicodeDecodeError`，而那里的 `except OSError` 抓不到，结果是**便签窗口打不开/半死**（`_note_win[0]` 已置上，再点只是 deiconify 坏窗口），C# 的 `File.ReadAllText(UTF8)` 则是替换式解码永不抛。**码表与插件也在名单里**（第三十二轮）：`py.txt`/`wb.txt`/`ec.txt`/`trad.txt`/`import_*.txt`（`engine.parse_dict` —— 严格 utf-8 会让 GBK 码表**把启动直接打崩**，且 BOM 会让**第一行读不进来**，所以快路径用 `utf-8-sig`、失败退回 `read_text`）、用户手改过的 `import_*.txt`（`load_import_base`）、插件 `.py`（`main._py_plugin_meta_static`：GBK+coding 声明的插件 python 能跑，严格 utf-8 会让插件管理器列举时崩）。
   **配套：写这些文件时行尾要跟 C# 对齐** —— C# 的 `ImportCodeTable` 写 `import_*.txt` 是 `WriteAllText(..., UTF8Encoding(false))` + `'\n'`（**裸 LF**），python 的 `open(..., 'w')` 在 Windows 上会翻成 CRLF（`import_*.txt` 是入库跟踪文件，被翻成 CRLF 就是整文件 diff）；所以 `engine.write_import_file` 必须带 `newline='\n'`。反之 `config.txt` 是 C# `WriteAllLines`（CRLF），python 默认写 CRLF 正好一致。
29. **未闭合的多行块整块丢弃**（对齐 C# `ParseToolSteps`/`LoadTools`：块只在遇到闭标签时才入 steps）：`plugins.run_steps` 若扫描到行尾仍没找到闭标签，记一条 `块未闭合…已跳过` 就 `continue`，**不要执行**半截块（否则会把后面的行当脚本体跑掉）。
30. **改 `.py` 的脚本必须用二进制写**：python 文件在仓库里是 **LF**（只有 `wgime.bat` 走 `eol=crlf`）。用 `open(p, 'w', encoding='utf-8')` 在 Windows 上写会把 `\n` 自动翻成 `\r\n`，于是**整个文件变成"全部改动"**（曾造成 1885 行幽灵 diff，还得回滚重写）。脚本改文件时用 `open(p,'w',encoding='utf-8',newline='')` 或 `[IO.File]::WriteAllBytes` 写二进制；改完用 `CRLF=0` 自检（PowerShell 统计 `\r\n` 数），并确认 `git diff --stat` 的行数符合预期。`build-wgime-pure.py` 内嵌模块源码，**行尾变了要重新构建 dist** 否则 payload 与源码不一致。

   **txt 的行尾要按各自的 blob 走（第三十六轮发现，别再制造整文件 diff）**：`core.autocrlf=false` 且没有 `text`
   属性时，git 比较的是**字节**；仓库里一批 txt（根 `plugins\*.txt`、`tools.txt`…）**blob 是 LF 而工作区是 CRLF**
   （历史遗留，靠 index 的 stat 缓存才显示"干净"），于是**用字节改写这类文件会让整文件报改动**（整文件 186 行）。
   改这种 txt 的正确做法：先看 blob 的行尾（`git cat-file -p HEAD:<path>` 数 `\r\n`），按**blob 的行尾**写回，
   再用 `git diff --numstat -- <path>` 校验只剩目标行（`--ignore-cr-at-eol` 可辅助判断"是否只是行尾差异"）。
   注意行尾在仓库里并不统一：根 `plugins\wgtranslate.txt` 的 blob 是 **LF**，而 `release\plugins\wgtranslate.txt`
   的 blob 是 **CRLF** —— 同一个文件在两处不同，**`sync-dist.ps1` 逐字节拷贝会让 release 侧整文件报改动**，
   同步完要按 release 的 blob 行尾再写一次。
   **`build-package.ps1` 不是可复现构建**：它内嵌的第三方 zip 带**当前时间戳**，所以**源码没改也会让
   `wgime-py-pure\dist\wgime-py.py` 变脏**（只有一个 `THIRD_ZIP_B64` 行不同）。dist 只内嵌 9 个项目模块 +
   `main.py`（**不含插件**），所以只改插件（或任何不内嵌的文件）时，构建完应
   `git checkout -- wgime-py-pure\dist\wgime-py.py` 把这条噪声回退掉，再用
   `%TEMP%\wgime-dist-sync-check.py` 确认 dist 仍与磁盘逐字节一致。

31. **config 键的"取值语义"以 C# 为准，白/黑名单别搞混**（第十轮审计发现 `followcaret` 搞混了）：C# `LoadConfig`（wgime.bat 1663-1747）里 **白名单**（`v=="1"||v=="on"||v=="true"`，非法值一律判"关"）= `showcode`/`keyfix`/`followcaret`/`hideidle`/`trad`/`starton`；**黑名单**（`v!="0"&&v!="off"&&v!="false"`，非法值判"开"）= `sentence`/`assoc`。python 侧逐键照此（`engine.load_config`）；python 独有键 `cnpunct` 用黑名单。`paste`（on/always→1, off→2, key/unicode→3, 其余→0）、`shuangpin`（xiaohe/小鹤/flypy→1, ziranma/自然码/zrm→2, ms/微软/mspy→3, 其余→0）、`mode`（仅 `tray` 生效）、`fuzzy`（none/off/空→清空；一对都解析不出则保持缺省）也都与 C# 逐值对齐过（275 组用例）。**改 `load_config` 后要重建 dist + package**（dist 内嵌模块源码）。有意保留：非法 `hotkey_*`/`key_*` C# 保持当前字段、python 回缺省；python 多认单引号 `app =` 命令。

32. **步骤 DSL（`plugins.py` `run_steps`/`_run_verb`）的动词语义对齐 C# `ExecToolStep`**（第十一轮审计）：① `confirm` 的 `title=`/`buttons=`/`default=` 三项必须**真的生效**（`_confirm_args(arg, confirm, **msgbox**)` —— `msgbox` 是参数，原来漏传导致 `buttons=ok` 直接 `NameError` 崩；`okcancel` 走 OK/Cancel，缺省按钮是"否"对齐 C# `MessageBoxDefaultButton.Button2`），回调签名 `confirm(text, title, buttons, default_no)`，保留单参数旧回调兼容；② `kill` 只看**第一个 token**（C# `tk[1]`），不是整行 rest；③ 缺参动词（`run` 无程序名、`reg-set` <4 token、`reg-del` 无键路径）必须**记一步失败**，不能静默成功（C# 是 `tk[n]` 越界抛异常）；④ 多行块控制台显示名按 C# 映射：`cmd→[shell]`、`shellx|cmdx→[shellx]`、`powershellx→[psx]`、`powershell|ps→[powershell]`。python 有意保留：破坏性动词执行前强确认（§16）、块开标签大小写不敏感、`file-del C:\*` 拒删（C# 会真删 C 盘根）。改完 `plugins.py`/`tools.py`/`main.py` 要重建 dist + package。

33. **hook 吞键表的判定次序：别把 `Shift` 提前透传**（第十二轮审计）：C# `bare = !ModifierDown()`，而 `ModifierDown()` **只含 Ctrl/Alt/LWin/RWin**（wgime.bat 124-130）——所以**组字中** `Shift`+数字/退格/Esc/回车/空格/PgUp/PgDn/配置翻页键在 C# 里照样被吞；只有 `a-z`、`;`（SemiAsCode）、以词定字 `[`/`]` 显式要求 `!sh`。python `hook._proc` 的次序必须是：数字（`COMPOSING`）→ `_swallow`（退格/取消/回车/空格/翻页，只要求 bare）→ `_swallow_pick`（`!sh`）→ 中文标点（MapPunct：`/` 只有 Shift 有映射、`\ [ ]` 只有裸键有映射）→ `if shift: 透传` → 裸字母；`_rebuild_swallow` 就按这两组建表。改动后跑 hook 判定矩阵（伪造 lParam + `_key_state` 直接调 `_proc`，见 CHANGELOG 第十二轮 89 例）再提交。

34. **「自动造词链」`record_commit` 与「词频学习」`engine.learn` 是两件事，别再绑在同一个门控里**（第十三轮审计）：C# 在**每条上屏路径**都调 `RecordCommit`（`Hook_OnSpaced` 空格与数字共用段、`Hook_OnPunct` 标点自动上屏、五笔唯一四码自动上屏），而 python 的 `commit()` 原来把它跟 `engine.learn` 一起塞在 `if i > 0` 里 → "打全拼 + 空格逐字确认"这条最常见的路径永不进 `ime.recent`，**自动造词几乎不触发**。现在的规则：`record_commit(text, code)` 在 `commit()` 里**无条件**调用（含 `commit(0)`，于是五笔自动上屏也覆盖）、`handle_punct` 自动上屏首候选时也补记；**只有动态候选/`vf` 面板符号不参与**（提前 return）。`if i > 0` 只该管 `engine.learn` + `_last_learn`(LastPick/词频回滚)。改上屏路径后跑 CHANGELOG 第十三轮的 headless 状态机 harness（真 engine + 出口打桩 + 临时 `LOCALAPPDATA`，别碰用户数据）。

## 6. 加载与性能（已做的优化，改动时别回退）

- **缓存命中跳过 trailer 解压**：`WgImeLauncher.ComputeTrailerHash`（压缩字节 md5，不解压）→ `BuildDicts` 用它查 `.mb` 缓存；miss 才 `ExtractDictsFull` 解压（经 `TrailerExtractor` 委托）。
- **WGB4 缓存格式**：批量块读取 + 并行 ToMap + `CompressionLevel.Fastest`。
- **词频保存后台化**：`SaveFreq` 走线程池（`freqSaving` 防堆积），退出时 `SaveFreqSync` 同步落盘。内存上限：FreqM/LastPickM 各 3 万、Freq 9 万、Assoc key 2 万。
- **启动计时日志**：`startup: LoadFreq+BuildDicts=XXXms ApplySwap=YYYms`。
- **固化码表预生成缓存**：`BakeTables` 固化后（无论是否勾选"删除源文件"）`PrebuildCacheAfterBake` 用 bake 后的输入重算 md5 并复用内存字典直接写 `wgime.mb`，下次启动命中缓存，跳过 ~10-24s 冷重建。md5 的 overlay 文件字节用 `SafeRead` 读实际状态；它对新码表 `TrimEnd` 末尾换行，与 `Get-DictSeg` 读数据块时的 `TrimEnd` 字节级一致，否则 md5 对不上。保留源文件时下次启动的 overlay 是幂等的（`AddDictLine` 覆盖 + `MergeUserWords` 只追加），冷启动结果等于内存字典。
- **python 版启动实测（第三十五轮复测，改动前先看这组数）**：冷启动 ≈ **12.1–12.9s**（`ec` 解析 1.1s + `build_reverse` 3.3s + `build_acro` 2.0s + `build_char_py` 0.45s + 三组 `build_sorted` 0.5s + **写 93MB 缓存 2.5s**）；热启动**引擎构造 ≈ 1.0s**、`main` 前缀（到装钩子）**≈ 1.98s**（第三十四轮前是 3.70s，见下面①②③）。每键热路径都很便宜（`candidates("ni")` 0.05ms / `candidates("zhongguo")` 0.25ms / `best_sentence` 0.07ms），**别去动热路径**。
- **"启动头几秒打字卡/打不出字"的三个根因（第三十四/三十五轮，别再种回去）**：
  ① **反查表(rev_wb)绝不能同步建**：`showcode = 1` 是 `config.txt` **出厂默认值**，原来 `rev_wb_code()` 首次调用时同步
  `build_rev_wb`（30.2 万码 / 143.8 万词条纯 Python 循环）→ **每次启动的第一下按键卡 1326ms**。现在 `rev_wb_code()`
  只返回 `_rev_wb.get(w)`，没建好就调 `warm_rev_wb()` 起后台线程并返回 `None`（候选暂时不显示反查码），
  `build_rev_wb` 每 4000 码 `time.sleep` 让 GIL（`chunk=0` 关闭，oracle 用），码表变动 `_invalidate_rev_wb()` 用
  `_rev_gen` 代数作废在飞结果。**不要把预热搬回 `apply_config()`**：那 1.2s 抢 GIL 会把 `hook.start()` 从 +2.29s
  推到 +3.70s（键更晚可用）；预热只在钩子装好后（`main` 里 `engine.warm_ec()`）和打开「反查编码」开关时做。
  ② **缓存分两段读**（`CACHE_VER = 5`）：第一段=核心表 `(py,pk,pv,wb,wk,wv,char_py,acro)` +
  **三张派生表 `(char_wb, wb_by_len, word_freq, word_freq_total)`**（第三十五轮加，共 47.0MB），
  第二段=**只有「词典」模式(3)用得到**的 `(ec,ek,ev,ce)`（46MB）。启动只**同步**读第一段（`f.tell()` 记下第二段偏移
  `_ec_off`，`_ec_ready=False`、`ec/ek/ev/ce=None`），第二段由 `ensure_ec()` 在后台线程里用 `_YieldingReader`
  （每次 `read` 之间 sleep 0.2ms，让 `_pickle` 周期性交还 GIL）加载 —— 实测加载期间每键 **1–40ms**。
  **四个部件必须打成一个 pickle 段**（`pickle.dump((ec,ek,ev,ce), f)`）：拆成 4 个会丢字符串去重，缓存 90.6MB→121.9MB。
  `candidates()` 的 mode 3 分支在 `_ec_ready` 为假时**必须返回 `cands, False, False`**（三元组！曾经写成 `return []`
  让 `main.refresh` 抛 `ValueError: not enough values to unpack`），并调 `ensure_ec()` 顺手起加载。
  第二段损坏/截断（`.sig` 仍匹配、缓存"看起来可用"）→ 后台线程里 `_build_ec()` 重建；两条路都失败才 `_ec_fail` 打住
  （否则词典模式每按一键起一个读 24MB 码表的线程）。探针：`%TEMP%\wgime-warmec-probe.py`（40 项）。
  ③ **三张"每次重算"的派生表必须留在缓存第一段**（第三十五轮）：`char_wb`（单字→最长五笔码，21,781 键）、
  `wb_by_len`（五笔码按码长分桶，z 通配用）、`word_freq`（`pywfreq.txt` 71,580 词）—— 原来写在
  `_init_state()` 里**每次启动重算**，实测 char_wb 707ms + wb_by_len 61ms + pywfreq 155ms ≈ **0.92s**。
  现在统一在 `_build_core_extra()` 里算（`_build()` 调一次并随缓存写出；`_init_state()` 只在
  `_core_extra_ready` 为假时兜底现算）。**`pywfreq.txt` 必须在 `CACHE_FILES` 里**，否则改了语料缓存不失效、
  `word_freq` 一直是旧的。**`wb_by_len` 桶内顺序必须原样保留**（ordinal 升序 = C# `OrderBy`，见 §11）。
  热启动 Engine() 构造 1401→**998ms**、端到端装钩子 2.29→**1.98s**（第三十四轮前是 3.70s）；缓存 93.1MB。
- **加载提示窗每次启动都显示（第三十四轮）**：热启动也要读 93MB 缓存 + 装钩子（~2.0s），只在"缓存过期要重建"时
  才显示会让热启动那两三秒毫无反馈。现在 `_splash` 无条件建，第二行按 `_dict_cache_stale()` 区分
  "首次启动需建立索引, 请稍候 (之后走缓存, 秒开)" / "正在读取词库缓存, 几秒后即可输入"。
- **缓存内容别"精简"**：`pk/pv/wk/wv/ek/ev` 六个派生数组看着冗余（占缓存 90MB 里的 ~57MB），但实测把它们从缓存里去掉改成启动时 `build_sorted` 重建是**净亏 308ms**（缓存只省 13.5MB，重建要 487ms）——已量化验证，保持现状。`ce`（`build_reverse` 3.3s）与 `acro`（2.0s）必须留在缓存。zlib 压缩缓存也不划算（145MB→42MB 但解压 +652ms）。
- **冷启动反馈窗（python 版）**：`_dict_cache_stale()`（缓存缺失或比任一码表旧）为真时，在 `Engine()` 之前显示一个 320x72 的"WgIme 正在加载词库…"无边框置顶小窗，建表完成后销毁（对齐 C# 候选条的"(词库加载中...)"）。为此 `root = tk.Tk()` 已提到建表之前，**全文件只创建一次 Tk root**（`bar = CandBar(root)` 复用同一个），别再在启动后段新建 root。
- **索引缓存（`dict-cache.pkl`）的判定与写入规则（第三十一轮，别回退）**：判定统一走 `engine.cache_is_reusable(dict_dir, data_dir)`
  = 缓存文件存在 **且** 侧车 `dict-cache.pkl.sig`（小 JSON：`ver + 绝对词库目录 + 每个码表 (size,mtime)`）
  == 当前 `engine.cache_sig(dict_dir)`。所以 **只有码表真的变了（或换了词库目录/缓存版本）才重建**，
  热启动既不重建也**不重写**缓存文件（实测 11.5–12.7s 冷 / **0.87–1.01s 热**，见上面"两段缓存"）。铁律：
  ① **一个码表都没读到（第一段的 `py`/`wb` 全空，第三十四轮起不再看 `ec`——它在第二段）绝不写缓存**，否则会留下"签名自洽的空索引缓存"，
  之后每次启动都命中它 → 词库凭空为空且毫无提示（用户机器上真出现过 75 字节的
  `sig=[None]*7` 缓存）；`_load_cache` 命中到空索引时也要拒绝并重建；② `_save_cache` 失败**不许静默**
  （会打印原因）；③ 缓存失效时同步删掉侧车 `.sig`，否则启动提示会以为"缓存可用"而不再显示加载窗；
  ④ `_find_dict_dir()` 要带 `..\package\dicts` / 上级目录兜底（`python wgime-py-pure\dist\wgime-py.py`
  时码表在 package 里），实在找不到要 **stderr + 托盘气泡**说清"空词库"，不能静默退化。

## 7. Git / 分支

- 主分支 `master`（唯一活跃分支）。原独立 WgTray 程序已于 2026-09 退役（收敛为 `mode=tray` 运行模式），历史版本见早期 tag/提交。
- 提交后推 `origin/master`。release 发版本用 GitHub API + zip，**已脚本化**（2026-09-10）：
  1. `powershell -NoProfile -ExecutionPolicy Bypass -File tests\build-release-assets.ps1 -Version 1.2.7`
     → 产出 `bat`/`ps1`/`python` 三个 zip（stage 在仓库内 `.release-stage-v127\`）。`-OnlyPython` 只重做 python 包。
     三条坑已写进脚本：`.NET ZipFile.CreateFromDirectory` 写 `\` 分隔条目（改逐条 `CreateEntryFromFile` + 转 `/`，
     脚本自检）、源目录必须长路径（8.3 短路径会把 `ADMINI~1` 带进条目名）、**python 包取自
     `wgime-py-pure\package\`，改完源码必须先跑 `wgime-py-pure\build-package.ps1`**（否则发出去的是上一个构建；
     脚本已加哈希守卫：`package\wgime-py.py` ≠ `dist\wgime-py.py` 直接 throw）。
  2. 把 release body 存成 UTF-8 文件，`powershell -NoProfile -ExecutionPolicy Bypass -File tests\publish-release.ps1
     -Version 1.2.7 -BodyFile <body.md> -AssetsDir <stage 目录>`（脚本自己创建 release + 上传三个资产；
     同 tag 已存在时改走 PATCH + 覆盖同名资产）。
     **务必先 `git push` 再 publish**：脚本已改用 `target_commitish = 本地 HEAD sha`（不再传 `master`，
     否则 GitHub 按**远端** master 解析，会把 tag 打到上一个提交 —— v1.2.9 就踩了这条，tag 落在
     `4abb843` 而 dist 刷新提交是 `3142cf5`），并在 HEAD≠origin/master 时打 `Write-Warning` 提醒。
  3. 每次发完都做**回验**：下载线上 python zip → 解出 `wgime-py.py` 与本地 `dist\wgime-py.py` 逐字符比对，
     并检查 release body 无 `?`、tag 指向本地 HEAD（v1.2.7 曾把上一个构建发出去，靠这步才发现）。
- **发 release 的中文坑**：release body 必须用 `HttpWebRequest` + `[Text.Encoding]::UTF8.GetBytes(json)` 显式 UTF-8 字节发送（`publish-release.ps1` 已内置）。**不要用 `Invoke-RestMethod` + `ConvertTo-Json`**——PowerShell 5.1 会把中文 body 编码成 `?`（曾导致 v1.2.0~v1.2.4 的 release 描述全变问号）。
- **Token**：`publish-release.ps1` 依次取 `-Token` → `$env:GITHUB_TOKEN` → `$env:GH_TOKEN` → Windows 凭据管理器（`git:https://github.com`，`CredRead` 直读）→ `git credential fill`。**把 `git credential fill` 放最后**：GCM 有时会弹 UI 卡死整条发布流程（2026-09-10 实际踩到，表现为脚本长时间无输出且没建 release）。另：本机 WinINET 代理 `127.0.0.1:10808` 常年失效，脚本已 `[Net.WebRequest]::DefaultWebProxy = $null` 直连。
- 版本 tag：`v1.0.0` ~ `v1.2.10`（后续版本递增）。插件更新不单独发 release。
  **v1.2.10（2026-09-11）发布回验记录**（`tests\publish-release.ps1` 之后必做）：release body 与本地
  body 文件逐字符一致（1789 字、**0 个 `?`**）、线上 `wgime-v1.2.10-python.zip` 的 SHA256 与本地
  `.release-stage-v1210\` 里的 zip **完全相同**、zip 内层 `wgime-py.py` 与本地 `dist\wgime-py.py` 一致、
  tag/release target 指向本地 HEAD。

## 8. 当前状态速览

- **已完成一次全面体检(review)并修复高危+中危问题**（2026-08-29，覆盖 main/engine/win/tools/hook/plugins/ui 七模块）：详见 CHANGELOG 对应条目。核心：词频保存线程竞争已用 RLock 状态锁修复；剪贴板改 ctypes 原生（零子进程）；`send_unicode` 按 UTF-16 码元注入（支持 emoji）；hook 修 Shift 轻拍/F8 修饰键/数字键/注入键/异常保护。
- 最近工作：码表数据块化（`###WGIME_DATA###`，消除启动时 PS 解析大 here-string）、固化码表写数据块 + 预生成 `.mb` 缓存（下次启动跳过 ~10s 冷重建）、词库加载优化（缓存命中跳解压）、wgime.bat 恢复瘦 DLL、种子精简、**chat 插件重写（2026-08-25：relay 裸 JSON + 真 MQTT 双模式、auto 兜底、Active Rooms、6s×3 重连，修复与 PC/Android 双向不互通的致命缺陷；新增 `tests\chat-protocol-smoke.ps1` 联网协议验证）**、clock 多提醒、文档同步、**纯 Python 版托盘菜单分组 + 中英双语（按 `GetUserDefaultUILanguage` 判定，与 C# 版 `CultureInfo` 一致）**。
- 纯 Python 版托盘菜单：分组(ime 模式)=开关/模式/选项{繁体输出, 反查编码, 整句输入, 联想, 全角标点(Ctrl+.), 空闲隐藏, 跟随光标, 主题}/词库{造词, 批量造词…, 用户词表…, 导入码表…}/这个程序{剪贴板上屏, 标点吞字修复}; tray 模式才显示 工具箱/内置工具/插件管理/config 应用/**运行模式{输入法(IME), 托盘工具箱(Tray)}**/退出；标签经 `tray.L(zh,en)` 双语化，造词走 `api['makeword']` → `makeword_clipboard()`；**托盘勾选态要齐**（第十六轮审计）：C# `RefreshMenuChecks` 给 8 类项打勾 —— `开关`(`is_active`)、4 个模式(`get_mode`)、`反查编码`、`繁体输出`(`get_trad`)、`候选窗跟随光标`、`空闲隐藏`、`改用剪贴板上屏`(`get_apppaste` = `APPMODES.get(前台,0)==1`)、`标点吞字修复`(`get_appkeyfix` = `effective_keyfix()`)；这些 `get_*` 都由 `main.py` 的托盘 `api` 注册（pystray 在**菜单打开时**求值 `checked` 回调，所以是活状态）；改托盘菜单时别把这几项的 `checked=` 删掉，也别新增只用 `toggle_*` 而没有 `get_*` 的开关项。批量造词 `show_batch_makeword`（选词表文件→2-8 汉字去重→确认→`engine.add_user_words_batch`）/用户词表 `show_user_words`（多选删除→落盘 `userwords.txt`→后台 `engine.reload()` 重建，对齐 C# BuildDicts+ApplySwap）。**造词对话框必须带汉字校验**（第十九轮）：`show_makeword` 的 `do_make` 是 `not (2 <= len(w) <= 8) or not engmod.is_all_cjk(w)` → 提示「词语需 2-8 个汉字」（对齐 C# `MakeWordFromClipboard` 的 `IsAllCJK`）—— 否则"手填编码"这条 python 额外路径能把纯英文/混排词写进用户词库。批量造词的行规则（trim、空行不计、2-8 汉字否则计 skipped、重复计 skipped）与 C# `CollectWordLines` 逐条一致，别改。**内置工具 1:1 对齐 C#**：工具箱/网络工具/便签/剪贴板/取色器/插件管理/造词/批量造词/用户词表/导入码表均已复刻（`tools.py`，对照表见 `wgime-py-pure\README.md`）；**网络工具的纯计算部分已逐项核对一致**（第二十六轮）：`_ip_type`/`_ip_class`（20 个边界地址）、`subnet_calc`（含 /0 /31 /32 与点分掩码、非连续掩码报错）、`subnet_split`（count 取整、`/30 拆 2` 报"拆得太碎了"）、`range_to_cidr`（含反向、全范围）、`mask_table`（逐行含对齐）、`test_port` 的 `open  Xms` / `closed (timeout Xms)` 串格式 —— 都别改。唯一**有意差异**：连接被拒时 C# 是 `closed (SocketException)`、python 是 `closed (<Python 异常类名>)`（异常体系不同，别去映射成 .NET 类名）。**剪贴板历史的三条判定别回退**（第二十二轮）：① **只在窗口开着时收集**（C# 关窗即 `RemoveClipboardFormatListener`；`_clip_consider(t, _clip_win[0] is not None)`），别让轮询线程关窗后还每 0.3s 读剪贴板；② **纯空白不记**（C# `t.Trim().Length > 0`）；③ **selfSet**：`copy_sel`/`paste` 写回剪贴板前记 `_clip_self[0]`，轮询遇到就跳过并推进 `_clip_last[0]`，否则点一条旧记录会把它重新顶到历史最前。`_clip_push` 的语义（去重/移置顶/容量 200，只在插入路径裁剪）与 C# `ClipPush` 一致。C# 的「固化码表(BakeDialog)」在 python 无对应物（`py/wb/ec.txt` + `import_*.txt` 即源，导入即固化）。tools.txt 的 `code = xxx` 与 C# 一致注册为启动器候选（`main.find_launcher` → `tools.run_tool_code`，结果走托盘气泡；冲突优先级 插件 > tools code= > config app= > 内置别名）。**`config.txt app=` 的启动要走 ShellExecute**（第二十五轮）：C# `LaunchApp` 对"不含 `://`、含 `\`/`/`、非绝对路径"的目标先 `Path.Combine(BatDir, target)`（**相对路径按程序目录**解析，不是进程 CWD），再用 `UseShellExecute=true` + `Arguments` 启动；python 对应 `main.run_launcher` 的 `app` 分支里做同样的 join，并调 `win.shell_execute()`（ctypes `ShellExecuteW 'open'`）——**不要**改回 `subprocess.Popen(..., shell=True)`（会过 `cmd.exe`，参数里的 `&`/`^`/`%` 被解释）。**运行模式**：`config.txt mode=ime|tray`（ime=输入法默认；tray=纯托盘工具无键盘 hook/候选窗，对齐 C# 版合并 wgtray 方案），托盘「运行模式」切换 → 写 config + 自动重启进程；`main.is_tray_mode()`/`switch_mode()`/`tray._tool_icon_img()` 实现。全/半角标点：`hook.py` 吞 `, . ; ' / \ [ ] Shift+4` → `main.map_punct`（对齐 C# MapPunct 含引号开闭交替），组字中先上屏首候选再标点（C# Hook_OnPunct 对齐），`;` 在微软双拼组字中仍是韵母 ing 键、`[`/`]` 有候选时仍以词定字；`cnpunct=0` 时标点键透传半角，`config.txt cnpunct` 持久化。
- 纯 Python 版(`wgime-py-pure/`)概览：功能与 C# 版对齐(四模式/词频/简拼/双拼/造词/码表导入固化/启动器/工具箱/插件/候选窗/托盘/反查/简繁/整句/联想/空闲隐藏)；单文件 `dist\wgime-py.py`(内嵌模块+pystray/uiautomation/comtypes zip，**不内嵌插件**)；数据目录 `%LOCALAPPDATA%\wgime-py`(Store Python 自动切 `USERPROFILE\wgime-py`)；词频机制已升级(语料+学习+近期热度、`learnk`/`recentk` 可配)；UI 用 `ui.py` 设计系统。详见 README「纯 Python 版」章节与 `docs\WGIME_*`.md 对应小节、`wgime-py-pure\README.md`。
- 纯 Python 插件（`wgime-py-pure\plugins\*.py`）：契约=模块级 `CODE/NAME/DESC/VERSION/AUTHOR/PERM` + `run()`，窗口用 `ui.py` 设计系统（`make_window/flat_button/rounded_entry/console_text`），不建 `tk.Tk()`、不调 mainloop，定时用 `win.after`，后台线程经 queue+`root.after` 派发。已从 C# 1:1 移植：`calc.py`(计算器 jsq，calc 为别名)、`chat.py`(聊天 lt)、`clock.py`(悬浮时钟 sz)、`wgime-qr.py`(二维码 qrcode，Nayuki 算法已逐位对齐参考实现)；**`wgtranslate.py`(剪贴板翻译 fy) 不是 1:1 移植，是另一份重写（v2.2.0）** —— 差异见下面单独一条。插件**不内嵌**：`build-package.ps1` 把本目录 `plugins\*.py` 全量拷进 `package\plugins\`、把仓库根 `plugins\*.txt` 只挑**步骤 DSL 类**(clean-bin/qping/README)拷入——含完整 `[csharp]` 插件块的 txt(calc/chat/clock/wgtranslate 的 C# 源)被同 CODE 的 `.py` 取代，不再进 python 分发(避免生产 csc 编译路径)；生产环境从外部插件目录加载（`load_py_plugins` 扫 APP_DIR/plugins，`.py` 优先于同 CODE 的 `.txt` 步骤插件）。仓库根 `plugins\` 保留 C# 版插件源(txt)，Python 版源在本目录 `plugins\*.py`。python 版 `_run_csharp_plugin`/`run-csharp-plugin.ps1` 的 [csharp] 运行能力仍保留作兼容回退(如用户自放 C# txt)，但内置分发不再带 C# 插件。**托盘「插件」子菜单**（`tray._plugins_menu`）列出 plugins 目录全部插件(.py/.txt)点击即运行，尾部接「插件管理…」；**插件管理器复刻 C# 版**(`tools.show_plugin_mgr` 重写): 列表(名称/编码/类型/启停/**状态**/文件)+按钮(重载/启停/打开目录/编辑/删除/新建模板/运行)+双击运行。**第十八轮补齐的几点别回退**：① 状态列由 `plugins.count_steps(body)`（与 `run_steps` 同规则：块算 1 步、闭标签缺失整块丢弃）算出，`main._list_plugin_files` 负责带 `status`（`正常 (N 步)`/`解析失败`/`未加载`/`—`）；② 禁用的行要 `lst.itemconfig(..., foreground=ui.SUB)` 灰显（对齐 C# `ForeColor = Gray`）；③ **删除确认必须 `default=messagebox.NO`**（C# 是 `MessageBoxDefaultButton.Button2`，缺省"是"会一记回车删掉插件文件），标题 `WgIme`；④ 双击 = 运行是 python 的有意选择（C# 是编辑），已记在此处。
- **悬浮时钟插件（`clock.py`，第二十七轮）三个别回退的点**：① **报时/闹钟守护必须与 C# 用同名互斥体**
  `WgImeClockChime`（`win.single_instance`，句柄存 `_watch_mx` 保活）——C# 靠 `new Mutex(true,name,out createdNew)`
  保证全机只有一个守护；python 若只用模块级 `_watch_started` 布尔，则「C# 版与 python 版同时运行」（两者
  共用同一份 `clock.cfg`）和「托盘重载插件后旧守护线程还在跑、再开时钟窗又起一个」都会导致**同一闹钟弹两次、
  整点响两声**（实测线程 1→2）。② `clock.cfg`/`pomodoro.txt` 必须走 `_read_text()`（宿主 `engine.read_text`，
  §28）：`load_cfg` 是在 `ALARMS.clear()` **之后**才读文件，严格 UTF-8 抛 `UnicodeDecodeError` 会被
  `except Exception` 静默吞掉 → 整份闹钟消失，随后任意一次保存就把配置覆盖掉（真数据丢失）。③ 闹钟时间输入框
  用 `str.isdecimal()`（不是 `isdigit()`）判 3-4 位数字：`'²'.isdigit()` 为 True 而 `int('²')` 抛 ValueError，
  该异常会从 `ui.flat_button` 回调里抛出来把按钮打崩（C# `int.TryParse` 只认 ASCII 数字，从不抛）。
- **计算器插件（`calc.py`，第二十八轮）四个别回退的点**：① 求值**不是** `eval` —— 逐字移植 C# 的
  递归下降解析器（`_expr`/`_term`/`_fac`）：`%` 是**整数取余**且与 `* /` 同级（`10%3`=1、`100%7`=2、
  `50%`=Err、`2%0`=Err、`-5%3`=-2），`_cs_mod` 必须用 C# 的 long 取余语义（余数符号跟**被除数**，
  python 的 `a % b` 是跟除数，直接用就错）；② 结果格式对齐 `Calc` 末尾 —— 整数值且 |v|<1e15 →
  `str(_to_long(v))`（`4/2`→`2`），否则 `'%.10G'`（`1/3`→`0.3333333333`、`0.1+0.2`→`0.3`），
  失败一律 `Err`（不是 `错误`/`仅支持…`）；③ 启动编码是 **`jsq`**（C# 插件头部 `code = jsq`），
  `calc` 是 `main.PLUGIN_CODE_ALIASES` 的**盲转发**别名（对齐 C# `Apps["calc"] = Apps["jsq"]`）；
  `js` 不是任何一版的编码；④ 键位/显示对齐 C#：键位 `C <- ( )`…（**没有 `%` 键**，所以必须保留
  `_KEYS` 键盘直输，否则取余没法输入），显示是两行（小字 `表达式 =` + 大字，空串显 `0`）。
- **wgtranslate 插件（`wgime-py-pure\plugins\wgtranslate.py`，第三十六轮审计）**：python 侧**不是 C# 的 1:1 移植**
  （另一份重写 v2.2.0），差异是**有意的**，别"对齐"回去：python 通道是**超集**（多 `SimplyTranslate 公共实例`、
  `Argos 离线`）、多「保留格式」开关（`layout_units()` 逐行只翻正文，保留缩进/项目符号/尾空格/空行/行尾）、
  按**句子边界**分段（`chunks()` 430B；C# `SplitUtf8` 是纯字节切 450B）、统一 `html.unescape`、
  MyMemory 先校验 `responseStatus`（C# 不校验 → 会把"今日免费额度用尽"那句警告**当译文显示**）、
  Libre 的 zh-TW 用 `zt`（LibreTranslate 的繁体码；C# 一律 `zh`）、auto 方向按**主导文字**判定
  （C# 只要**一个汉字**就当中文）、`PERM = network,run`（运行前弹确认）。**相同的部分**：33 项语言表、
  Lingva 三台主机与码映射（zh-CN→zh / zh-TW→zh_HANT）、自动容错回退顺序与「所有通道均失败：」文案、
  剪贴板重试（6×80ms、空文本提示）。python 标签写 `自动判断`（C# 是 `自动检测`），且 python **没有**
  `自动中英互译` 菜单项 —— 默认 源=自动判断/目标=简体中文 时按检测到的语言自动翻转方向（与 C# 默认效果等价）。
  **C# 侧在本轮修掉一个真 bug**：`GoogleCloud` 的请求体多了一层转义，运行期是 `{\"q\":\"…`（非法 JSON），
  该通道**从来不可能成功**；已改成 `{"q":"…"`（`csc` 编译+运行的 before/after 证据见 CHANGELOG 第三十六轮）。
- **语言表别漏项**：C# `LANG_NAMES`/`LANG_CODES` 是 **33 项**（含 `保加利亚语`/`bg`）；python 曾漏掉 `bg`，已补。
  改这张表或通道映射时跑 `%TEMP%\wg-wgtranslate-probe.py`（62 项，含"C# 每项在 python 里都有同码"的断言）。
- **WebSocket 传输层（`wspy.py` + `chat.py` 保活，第二十九轮）五个别回退的点**：① `_read_headers`
  必须把 `\r\n\r\n` **之后**的字节留在 `self._buf`（服务端常把 101 响应和第一帧写在同一 TCP 段里，
  丢了首帧整条流就错位）；② `_read_message` 必须看 **FIN** 并重组 `OP_CONT` 分片（原来忽略 FIN，
  半截 JSON 被当成一条消息，剩下的片变成下一条）；③ 控制帧在 `_recv_data` 里就地处理、不计入消息体
  （首帧是 PING 时不能把 ping 载荷交给上层）；④ `_readexact` 异常时把已读字节存回 `_buf`，且
  **帧中间**中断要抛 `RuntimeError` 当断线（只有帧头之前的 `socket.timeout` 才是"暂时没数据"，可重试）；
  ⑤ `chat.py` 的 `_keepalive_loop` 每 15s 发一次 `PINGREQ 0xC0 0x00`(MQTT) / WS PING(relay) ——
  否则 keepalive=30s + 读超时 30s 会让空闲聊天窗 30 秒必掉线；`_recv_loop` 只对帧间的
  `socket.timeout` 宽容（连续两轮≈60s 才判死），且**只负责退出**，UI 收尾与是否重连都交给 `_net_loop`。
  **未做**：`Sec-WebSocket-Accept` 校验。
- **chat 掉线重连（`chat.py` `_net_loop`/`_session`，第三十轮）**：掉线 → `已断开, 6 秒后重连 (N/3)…`，
  最多 3 次 → `重连失败, 已断开`；**连接失败不重试**；用户点"离开"/关窗（`state['manual']`）不重连
  （对齐 C# `OnDisconnected`/`manualLeave`）。**重连预算只在会话稳稳跑过 `HEALTHY_SEC`(20s) 后清零** ——
  别照 C# 那样"连上就清零"（那样"连上后立刻掉"会无限重试，`(N/3)`/"重连失败"永远到不了，
  写探针时就是死循环才暴露出来）。
- **候选条靠边粘附 + 位置持久化（`bar.py`，第三十一/三十三轮）**：拖动时离工作区边缘 ≤ `SNAP_PX`(24px)
  自动贴齐，水平/垂直各判一次（四个角也能贴），拖开超过阈值自动脱开；粘附方向记在 `_snap_h`/`_snap_v`，
  `show()` 的固定模式分支用 `_apply_edge_snap()` 重新贴齐，所以**候选变宽/变高后仍贴同一条边**。
  位置持久化对齐 C# `LoadPos`/`SavePos`：`DataDir\pos.txt` 内容 `"x,y"`、**松手时**才写
  (`<ButtonRelease-1>` → `_drag_end`)，`CandBar(root, data_dir)` 的 `data_dir` 为 None 时完全不碰文件
  （探针/单测用），首次 `show()` 用回存下来的位置并按当前尺寸**重新推断粘附边**；坏文件/异编码一律容错退回默认。
  改 `_drag_move`/固定模式定位时别把这两段丢掉（探针见 CHANGELOG 第三十一轮 17 项 + 第三十三轮 15 项）。
- **码表导入路径（`engine.py` 转换段 + `tools.show_import`，第三十二轮）**：转换逻辑（`valid_code`/`skip_line`/
  `detect_format`/`convert_file`/`suggest_target`/重导入幂等）已用 oracle 对 C# 逐函数核对 **58 项 0 差异**，
  别改语义；两个坑别回退：① `write_import_file` **必须 `newline='\n'`**（C# 写裸 LF，python 默认会翻 CRLF）；
  ② 读 `parse_dict`/`load_import_base`/`_py_plugin_meta_static` 都要宽松（见 §28，GBK 码表严格 utf-8 会把启动打崩）。
- **启动头几秒打字卡 = 已修（第三十四/三十五轮，用户报告"每次启动头几秒打不出字"）**：三个根因都在 §6 ——
  ① 首键同步建反查表（`showcode=1` 是出厂默认，1326ms）→ 改后台建；② 启动同步 `pickle.load` 整份 90.6MB 缓存
  （2050–2611ms）→ 拆两段，词典那半张表惰性后台加载；③ `_init_state` 每次重算 `char_wb`/`wb_by_len`/`word_freq`
  （~0.92s）→ 进缓存第一段（`CACHE_VER = 5`）。合计热启动**装钩子 3.70s → 1.98s**、**首键 1326ms → 60ms**，
  缓存 93.1MB（冷启动 ~12.1–12.9s 不变）。另外热启动也固定显示"正在加载词库"小窗。
  **别把这三处改回同步/每次重算**（§6 有完整"别再种回去"清单）。验证：`%TEMP%\wgime-warmec-probe.py` **40 项**、
  缓存生命周期 **14 项**、`tests\pure-state-harness.py` **16/16** 全绿。
- chat 插件要点：relay=`chat.seee.uno` 走裸 JSON 文本帧，其余 broker 走 MQTT over WS（`/mqtt` 路径 + **必须 `mqtt` 子协议**，否则 EMQX 400/Mosquitto 断连）；TLS 需 1.2+。详见 `docs\WGIME_CHAT_技术文档.md` §8。
- 待用户验证：chat 插件与 PC/Android 真机互通（协议层已实机验证）、词库加载速度（缓存命中路径）、固化码表后启动速度（应已降到缓存命中级别）。
