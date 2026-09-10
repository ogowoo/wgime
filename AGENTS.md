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
```

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
15. **候选条宽度上限（python 版）**：候选条最大宽度收紧为 `min(屏幕工作区宽-24, 720px)`（不再铺满整屏）；候选总宽超上限时 `bar.py show()` 动态收紧候选截断（24→4 字符逐档），全部候选仍可见、可数字键选。别改成"铺满屏"（用户明确嫌长）。改 `bar.py` 的候选渲染时保持这一限制和 `max_w = max(240, min(wa.width-24, 720))`。
16. **插件 Manifest + 权限（wgime-py-pure）**：plugins/*.txt 头部支持 `code/name/desc/version/author/requires/perm`；plugins/*.py 模块级 `CODE/NAME/DESC/VERSION/AUTHOR/PERM`。`plugins.py plugin_meta()` 统一读取（兼容两类）；`perm=network/run/registry/destructive` 的插件运行前 `main._confirm_plugin()` 弹确认，`run_steps` 对 `file-del/reg-set/reg-del/kill` 动词前强确认。旧插件无这些字段默认 `perm=low`，不弹确认。改插件加载/执行时别破坏这一权限模型。**③④ 隔离+JSON IPC**：`[python]` 块子进程运行（超时60s）+ JSON IPC 契约（`handle(ctx)->actions`，stdout `@wgime <json>` 行协议）；`run_steps` 的 `run`/`shell` 超时 120s、静默块 300s；别把 `[python]` 块改回同进程 `exec`（会拖垮宿主）。
17. **光标跟随 = 独立 Caret Helper 子进程（wgime-py-pure，对齐 testing v3）**：主进程**绝不**初始化 COM/UIA。`win.py` 把内嵌的 helper 源码（`_EMBEDDED_CARET_HELPER`，纯 ctypes 直调 `UIAutomationCore` vtable，无 comtypes/uiautomation）落盘到 `%LOCALAPPDATA%\wgime-py\runtime\wgime-caret-helper-v3-stable-embedded.py`，用 `subprocess.Popen([sys.executable,'-u',path])` + CREATE_NO_WINDOW 常驻，JSONL stdin/stdout IPC（`request_caret_refresh` → `{id,reason,hwnd}`，reader 线程校验 `hwnd==请求窗口==当前前台` 才写缓存，过期结果丢弃）。`bar.show()`（跟随且出候选时）每键请求刷新；定位先读 `get_ipc_caret()`，无新结果则用 per-window anchor/当前可见位兜底，35/80ms 后再 `_ipc_reposition` 贴精确位。`get_caret_pos()` 兜底链：UIA 缓存(前台未变时) → GUITI(rcCaret.top+抖动检测) → 聚焦输入框矩形 → last → 前台原点；**鼠标兜底禁用**。改动时别把 UIA 改回进程内跑（helper 崩溃会拖垮键盘 hook 的教训），别恢复鼠标跟随。注意：若 `runtime\` 残留 pythonnet 时代的 python38 整包（`_ctypes.pyd` 等），helper 与其同目录会因 pyd 抢占导入而 ImportError → 静默回退纯 Win32 链（仍可跟随，只是无 UIA 精度）；不要为"修"这个失败随意改路径，先确认用户机器是否有该残留。
18. **可配置快捷键 / 候选操作键（两版共用 config 键）**：`hotkey_toggle/mode/makeword/trad` + `key_first/pageup/pagedown/back/cancel/raw/pickfirst/picklast`。C# 侧在 `KeyBordHook`（`VkFromName`/`ParseHotkey`/`SetKeyConfig`/`MatchMods`，缺省见类字段）；**python 侧在 `hook.py`**（`vk_from_name`/`parse_hotkey`/`configure`/`_rebuild_swallow` + `HOTKEYS`/`KEYS` 状态），由 `main.apply_config()` 用 `CFG['hotkeys']`/`CFG['ckeys']` 安装（`engine.load_config` 只原样收下，缺省在 hook 里），`main.handle()` 的按键分派全部改读 `hook.KEYS`。语义要点：`none`=禁用(0)、无效值忽略保持缺省、`hotkey_toggle` 非 `shift_tap` 时 Shift 轻拍停用、热键在"输入法未激活"时也生效（C# 热键判定在 IsLocked 之前）、组字中吞的候选键 = 配置键 + PgUp/PgDn 常驻。改这块时别再把键位写死回 `VK['SPACE']` 之类。
19. **单实例（wgime-py-pure）**：`win.single_instance('WgImePySingleInstance')`（ctypes 命名互斥体，句柄存 `main._SINGLETON` 保活）+ `win.message_box`（纯 Win32 弹窗，启动早期不建 tk）；已有实例则提示并 `sys.exit(0)`。名字带 `Py` 后缀，与 C# 的 `WgImeSingleInstance` 互不干扰；测试用 `WGIME_NO_SINGLETON=1` 跳过。
20. **联想开关要真的生效**：`engine.assoc_enabled`（由 `main.apply_config` 从 `CFG['assoc']` 同步）同时管**学习**（`learn_assoc` 提前返回）与**显示**（`get_assoc` 返回空 + `main.show_assoc` 提前返回），对齐 C# `AssocEnabled`。以前只翻了托盘勾选、实际照学照显示，是 bug。
21. **反查编码 (showcode) 的方向别搞反**：C# `CodeHint` = 五笔模式显**拼音**码、其余模式显**五笔**码（即"显示另一种码"）。python 侧用 `engine.build_rev_wb`（词→五笔码，按码 ordinal 升序扫、每词取最小码，同 C# `BuildRevWb`）+ `Engine.rev_wb_code()` **惰性**建表（首次用才建，`_build()`/造词改 wb 时置 None 失效）。`main._with_code` 是唯一入口。
22. **英汉表 (ec) 只在「词典」模式 (mode 3) 参与候选**（C# `AddTranslate`）：`engine.candidates` 的 mode 0/1 绝不能查 ec——实测拼音模式打 `no` 会串出"不/没有/无"并把"弄/浓/农"顶掉。词典模式的 EN 前缀匹配要给**每个命中词的全部释义**（C# `AddCands`），不是只取首个。
23. **双拼 (shuangpin>0) 下的门控**（C# `if (Shuangpin == 0)`）：rq/sj/xq 动态候选、v 金额候选、**启动器候选**都不挂（两键即音节会撞码）；`digit_as_code()` 也要带 `CFG['shuangpin'] == 0`。另 `refresh()` 开头要有 C# 的两处面板复位：`sym_cat>0 && buf != 'vf'` 与 `shuangpin>0` 时清 `sym_cat`。
24. **五笔唯一四码自动上屏**要排除启动器候选：`refresh()` 里条件含 `cands[0] != ime.app_cand`（对齐 C# `!appSet.Contains(cands[0])`），否则会"自动启动程序"。

## 6. 加载与性能（已做的优化，改动时别回退）

- **缓存命中跳过 trailer 解压**：`WgImeLauncher.ComputeTrailerHash`（压缩字节 md5，不解压）→ `BuildDicts` 用它查 `.mb` 缓存；miss 才 `ExtractDictsFull` 解压（经 `TrailerExtractor` 委托）。
- **WGB4 缓存格式**：批量块读取 + 并行 ToMap + `CompressionLevel.Fastest`。
- **词频保存后台化**：`SaveFreq` 走线程池（`freqSaving` 防堆积），退出时 `SaveFreqSync` 同步落盘。内存上限：FreqM/LastPickM 各 3 万、Freq 9 万、Assoc key 2 万。
- **启动计时日志**：`startup: LoadFreq+BuildDicts=XXXms ApplySwap=YYYms`。
- **固化码表预生成缓存**：`BakeTables` 固化后（无论是否勾选"删除源文件"）`PrebuildCacheAfterBake` 用 bake 后的输入重算 md5 并复用内存字典直接写 `wgime.mb`，下次启动命中缓存，跳过 ~10-24s 冷重建。md5 的 overlay 文件字节用 `SafeRead` 读实际状态；它对新码表 `TrimEnd` 末尾换行，与 `Get-DictSeg` 读数据块时的 `TrimEnd` 字节级一致，否则 md5 对不上。保留源文件时下次启动的 overlay 是幂等的（`AddDictLine` 覆盖 + `MergeUserWords` 只追加），冷启动结果等于内存字典。

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
- **发 release 的中文坑**：release body 必须用 `HttpWebRequest` + `[Text.Encoding]::UTF8.GetBytes(json)` 显式 UTF-8 字节发送（`publish-release.ps1` 已内置）。**不要用 `Invoke-RestMethod` + `ConvertTo-Json`**——PowerShell 5.1 会把中文 body 编码成 `?`（曾导致 v1.2.0~v1.2.4 的 release 描述全变问号）。
- **Token**：`publish-release.ps1` 依次取 `-Token` → `$env:GITHUB_TOKEN` → `$env:GH_TOKEN` → Windows 凭据管理器（`git:https://github.com`，`CredRead` 直读）→ `git credential fill`。**把 `git credential fill` 放最后**：GCM 有时会弹 UI 卡死整条发布流程（2026-09-10 实际踩到，表现为脚本长时间无输出且没建 release）。另：本机 WinINET 代理 `127.0.0.1:10808` 常年失效，脚本已 `[Net.WebRequest]::DefaultWebProxy = $null` 直连。
- 版本 tag：`v1.0.0` ~ `v1.2.7`（后续版本递增）。插件更新不单独发 release。

## 8. 当前状态速览

- **已完成一次全面体检(review)并修复高危+中危问题**（2026-08-29，覆盖 main/engine/win/tools/hook/plugins/ui 七模块）：详见 CHANGELOG 对应条目。核心：词频保存线程竞争已用 RLock 状态锁修复；剪贴板改 ctypes 原生（零子进程）；`send_unicode` 按 UTF-16 码元注入（支持 emoji）；hook 修 Shift 轻拍/F8 修饰键/数字键/注入键/异常保护。
- 最近工作：码表数据块化（`###WGIME_DATA###`，消除启动时 PS 解析大 here-string）、固化码表写数据块 + 预生成 `.mb` 缓存（下次启动跳过 ~10s 冷重建）、词库加载优化（缓存命中跳解压）、wgime.bat 恢复瘦 DLL、种子精简、**chat 插件重写（2026-08-25：relay 裸 JSON + 真 MQTT 双模式、auto 兜底、Active Rooms、6s×3 重连，修复与 PC/Android 双向不互通的致命缺陷；新增 `tests\chat-protocol-smoke.ps1` 联网协议验证）**、clock 多提醒、文档同步、**纯 Python 版托盘菜单分组 + 中英双语（按 `GetUserDefaultUILanguage` 判定，与 C# 版 `CultureInfo` 一致）**。
- 纯 Python 版托盘菜单：分组(ime 模式)=开关/模式/选项{繁体输出, 反查编码, 整句输入, 联想, 全角标点(Ctrl+.), 空闲隐藏, 跟随光标, 主题}/词库{造词, 批量造词…, 用户词表…, 导入码表…}/这个程序{剪贴板上屏, 标点吞字修复}; tray 模式才显示 工具箱/内置工具/插件管理/config 应用/**运行模式{输入法(IME), 托盘工具箱(Tray)}**/退出；标签经 `tray.L(zh,en)` 双语化，造词走 `api['makeword']` → `makeword_clipboard()`；批量造词 `show_batch_makeword`（选词表文件→2-8 汉字去重→确认→`engine.add_user_words_batch`）/用户词表 `show_user_words`（多选删除→落盘 `userwords.txt`→后台 `engine.reload()` 重建，对齐 C# BuildDicts+ApplySwap）。**内置工具 1:1 对齐 C#**：工具箱/网络工具/便签/剪贴板/取色器/插件管理/造词/批量造词/用户词表/导入码表均已复刻（`tools.py`，对照表见 `wgime-py-pure\README.md`）；C# 的「固化码表(BakeDialog)」在 python 无对应物（`py/wb/ec.txt` + `import_*.txt` 即源，导入即固化）。tools.txt 的 `code = xxx` 与 C# 一致注册为启动器候选（`main.find_launcher` → `tools.run_tool_code`，结果走托盘气泡；冲突优先级 插件 > tools code= > config app= > 内置别名）。**运行模式**：`config.txt mode=ime|tray`（ime=输入法默认；tray=纯托盘工具无键盘 hook/候选窗，对齐 C# 版合并 wgtray 方案），托盘「运行模式」切换 → 写 config + 自动重启进程；`main.is_tray_mode()`/`switch_mode()`/`tray._tool_icon_img()` 实现。全/半角标点：`hook.py` 吞 `, . ; ' / \ [ ] Shift+4` → `main.map_punct`（对齐 C# MapPunct 含引号开闭交替），组字中先上屏首候选再标点（C# Hook_OnPunct 对齐），`;` 在微软双拼组字中仍是韵母 ing 键、`[`/`]` 有候选时仍以词定字；`cnpunct=0` 时标点键透传半角，`config.txt cnpunct` 持久化。
- 纯 Python 版(`wgime-py-pure/`)概览：功能与 C# 版对齐(四模式/词频/简拼/双拼/造词/码表导入固化/启动器/工具箱/插件/候选窗/托盘/反查/简繁/整句/联想/空闲隐藏)；单文件 `dist\wgime-py.py`(内嵌模块+pystray/uiautomation/comtypes zip，**不内嵌插件**)；数据目录 `%LOCALAPPDATA%\wgime-py`(Store Python 自动切 `USERPROFILE\wgime-py`)；词频机制已升级(语料+学习+近期热度、`learnk`/`recentk` 可配)；UI 用 `ui.py` 设计系统。详见 README「纯 Python 版」章节与 `docs\WGIME_*`.md 对应小节、`wgime-py-pure\README.md`。
- 纯 Python 插件（`wgime-py-pure\plugins\*.py`）：契约=模块级 `CODE/NAME/DESC/VERSION/AUTHOR/PERM` + `run()`，窗口用 `ui.py` 设计系统（`make_window/flat_button/rounded_entry/console_text`），不建 `tk.Tk()`、不调 mainloop，定时用 `win.after`，后台线程经 queue+`root.after` 派发。已从 C# 1:1 移植：`calc.py`(计算器 js)、`chat.py`(聊天 lt)、`clock.py`(悬浮时钟 sz)、`wgime-qr.py`(二维码 qrcode，Nayuki 算法已逐位对齐参考实现)、`wgtranslate.py`(剪贴板翻译 fy, perm=network,run)。插件**不内嵌**：`build-package.ps1` 把本目录 `plugins\*.py` 全量拷进 `package\plugins\`、把仓库根 `plugins\*.txt` 只挑**步骤 DSL 类**(clean-bin/qping/README)拷入——含完整 `[csharp]` 插件块的 txt(calc/chat/clock/wgtranslate 的 C# 源)被同 CODE 的 `.py` 取代，不再进 python 分发(避免生产 csc 编译路径)；生产环境从外部插件目录加载（`load_py_plugins` 扫 APP_DIR/plugins，`.py` 优先于同 CODE 的 `.txt` 步骤插件）。仓库根 `plugins\` 保留 C# 版插件源(txt)，Python 版源在本目录 `plugins\*.py`。python 版 `_run_csharp_plugin`/`run-csharp-plugin.ps1` 的 [csharp] 运行能力仍保留作兼容回退(如用户自放 C# txt)，但内置分发不再带 C# 插件。**托盘「插件」子菜单**（`tray._plugins_menu`）列出 plugins 目录全部插件(.py/.txt)点击即运行，尾部接「插件管理…」；**插件管理器复刻 C# 版**(`tools.show_plugin_mgr` 重写): 列表(名称/编码/类型/启停/版本/文件)+按钮(重载/启停/打开目录/编辑/删除/新建模板/运行)+双击运行。
- chat 插件要点：relay=`chat.seee.uno` 走裸 JSON 文本帧，其余 broker 走 MQTT over WS（`/mqtt` 路径 + **必须 `mqtt` 子协议**，否则 EMQX 400/Mosquitto 断连）；TLS 需 1.2+。详见 `docs\WGIME_CHAT_技术文档.md` §8。
- 待用户验证：chat 插件与 PC/Android 真机互通（协议层已实机验证）、词库加载速度（缓存命中路径）、固化码表后启动速度（应已降到缓存命中级别）。
