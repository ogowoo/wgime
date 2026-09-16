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
python tests\pure-state-harness.py                    # 纯 Python 版状态机 headless 回归（33 项，不装钩子/不联网）
python tests\pure-state-harness.py --ref HEAD~1       # 对旧版本的 main.py 跑同一组用例（before/after 对照）
python wgime-py-pure\tests\undefined-globals.py       # 未定义全局量静态扫描（symtable mini-pyflakes，应输出 0）
python wgime-py-pure\tests\embedded-isolation-test.py # 内嵌第三方自足性（-S -E 干净环境逐个 import，9 项，见 §12）
python wgime-py-pure\tests\tray-swap-test.py          # 托盘换图状态机回归（42 项，假桩照抄真 pystray 语义，见 §43 ④）
python wgime-py-pure\tests\voice-vad-test.py          # 语音录音 VAD 回归（31 项，纯桩不碰麦克风，见 §38 第六十一轮）
python wgime-py-pure\tests\whisper-warm-test.py       # 本地常驻 whisper 助手回归（67 项，假 Popen 照抄真管道语义，见 §38 第六十三轮）
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
12. **纯 Python 第三方库内嵌（零 pip 依赖）**：python 版（`wgime-py-pure`）早期现代应用光标跟随用 `uiautomation`（纯 Python，基于 `comtypes`）在进程内跑，2026-09 起已改为**独立 Caret Helper 子进程（见 §17，纯 ctypes vtable，进程内不再 import uiautomation/comtypes）**。内嵌机制保留：`build-wgime-pure.py` 收集第三方源码打包 zip，运行时解压到 `%LOCALAPPDATA%\wgime-py\site` + `zipimport`（标准 import 机制，包结构正确）。**收集时用 `m.ispkg` 区分**——包写 `__init__.py`、模块写 `.py`（`six` 就是单模块），否则同名模块+包（`comtypes._post_coinit`）会崩。**必须连同声明依赖一起收**（读 METADATA 的 `Requires-Dist`；`Pillow` 在排除表里）—— 第六十九轮的真 bug: pystray 需要 `six`（`from six.moves import queue`）却漏嵌，而单文件的 import 会**回退到宿主 site-packages**，于是「构建机恰好装了 six」把缺口盖住，干净机器（官方 Python 3.14）上**整个托盘消失**。两个守卫: 构建期 `verify_thirdparty_isolation()`（`python -S -E` + 只挂那个 zip，失败**中止构建**）、回归 `python wgime-py-pure\tests\embedded-isolation-test.py`（改内嵌清单后必跑）。本机构建仍要 `pip install uiautomation`（从已装包读源码），分发的单文件零依赖。
13. **Store 版 Python 虚拟化 `%LOCALAPPDATA%`**：用户机器 `python` 若命中 Microsoft Store 版 Python（`...\Microsoft\WindowsApps\...PythonSoftwareFoundation...`，AppContainer 沙箱），它对 `%LOCALAPPDATA%` 的写入会被 Windows **重定向（虚拟化）** 到 `...\Packages\<pkg>\LocalCache\Local\`，导致真实 `%LOCALAPPDATA%\wgime-py` **不存在**、用户看不到/管不了词库、配置、导入码表。C# 版无此问题（非 Store 应用）。**修复**：`main.py` 启动时用探针（在 `%LOCALAPPDATA%\wgime-py` 建目录，看 `realpath` 是否含 `\packages\`+`\localcache\`）检测虚拟化，命中则把 `DATA_DIR` 切到 `os.path.expanduser('~')\wgime-py`（真实、不被虚拟化），并把虚拟化位置旧数据搬过去；`build-wgime-pure.py` 的单文件 preamble（`_third_dir`）同样处理。改数据目录逻辑时务必同步 `main.py`（DATA_DIR）与 `build-wgime-pure.py`（preamble `_third_dir`）两处，且检测判断（`\packages\`+`\localcache\`）保持一致。
14. **字频(candidate 排序)保留 python 版逻辑，且已升级**：python 版候选排序用 `语料先验 word_freq + 学习词频 fb×learn_k + 近期热度 freq_recent×recent_k`（常见词靠前 + 主动选过的词上顶 + 最近常打的词靠前），比 C# 版（只按学习词频 `fb`）更优，是**有意保留**的决策，不要"对齐"成 C# 版。配套机制：① 只在"主动选择"(非默认第1位/非动态)时学全量词频 + LastPick 置顶，空格确认默认词不强化；④ `freq_recent` 滑动窗口（RE_CAP=500，上屏即计、溢出自动过期）；② 上屏词退格删除即 `unlearn` 回滚(词频/LastPick/近期窗口)；③ config.txt 的 `learnk`(默认5000)/`recentk`(默认200) 可调。learn/save 递增/上限/保存前20000/flush 与 C# 版一致。
15. **候选条宽度上限（python 版）**：候选条最大宽度封顶 `max(240, min(屏幕工作区宽-24, 880px))`（不再铺满整屏；880 来自 `199f0bd` 修超屏的定论，用户明确嫌长，别改回 720 或铺满屏）；超上限时 `bar.show()` **逐级退化**（第四十五轮：每条都挂提示 → 只给选中那条挂 → 只挂译文 → 只剩词；**绝不把 `(imya)` 切成 `(imya…`**，只有"词"本身太长才截词 + `…`），全部候选仍可见、可数字键选。改 `bar.py` 的候选渲染时保持这一限制与这套退化次序。
16. **插件 Manifest + 权限（wgime-py-pure）**：plugins/*.txt 头部支持 `code/name/desc/version/author/requires/perm`；plugins/*.py 模块级 `CODE/NAME/DESC/VERSION/AUTHOR/PERM`。`plugins.py plugin_meta()` 统一读取（兼容两类）；`perm=network/run/registry/destructive` 的插件运行前 `main._confirm_plugin()` 弹确认，`run_steps` 对 `file-del/reg-set/reg-del/kill` 动词前强确认。旧插件无这些字段默认 `perm=low`，不弹确认。**插件 txt 的登记条件**（第二十一轮）：C# `LoadPlugins` 要求 `code`/`name` 非空**且 `body.Count > 0`** —— 只有头部的半成品**不算插件**（`error='no body'`，别当"解析失败"列出）；头部解析在第一个非头部行停止。别破坏这一权限模型。**③④ 隔离+JSON IPC**：`[python]` 块子进程运行（超时60s）+ JSON IPC 契约（`handle(ctx)->actions`，stdout `@wgime <json>` 行协议）；`run_steps` 的 `run`/`shell` 超时 120s、静默块 300s；别把 `[python]` 块改回同进程 `exec`（会拖垮宿主）。**插件禁用名单（`plugins-disabled.txt`）= 小写文件名**（对齐 C# `DisabledPlugins`）：`main.load_py_plugins` 按 `fn.lower() in disabled` 判定（内嵌插件无文件才退回 code，生产分发不内嵌插件）；`plugins.py load_plugins` 与 `main._read_disabled` 两侧都小写。插件管理器写的也是文件名——**别把装载器改回按 code 过滤，否则「启停」对 .py 插件无声失效**。
17. **光标跟随 = 独立 Caret Helper 子进程（wgime-py-pure，对齐 testing v3）**：**第六十八轮起 `followcaret` 默认 0 并冻结** —— 默认不起 helper、`_caret_follow()` 是唯一读取点, 整条链一行没删, 改 1 或点托盘即恢复（细节/验证见 `AGENTS-DETAIL.md` §D10）。主进程**绝不**初始化 COM/UIA。`win.py` 把内嵌的 helper 源码（`_EMBEDDED_CARET_HELPER`，纯 ctypes 直调 `UIAutomationCore` vtable，无 comtypes/uiautomation）**经环境变量 `WGIME_CARET_HELPER_SRC` 交给子进程 —— 既不落盘 .py，也不进进程命令行**（第四十三轮先做成命令行内联 `-c <源码>`：不落盘了，但 7200 字符让"进程创建命令行"变成一条 7.4KB 的怪异 `-c`，而 EDR/任务管理器记的正是这条；第四十四轮改走环境块，命令行只剩 ~250 字符的 `_HELPER_BOOTSTRAP` 引导）。`ensure_caret_bg()` 启动时只 best-effort 删掉更早落盘的历史遗留文件（`%LOCALAPPDATA%\wgime-py\runtime\caret-helper\wgime-caret-helper-v3-stable-embedded.py`）。实测：子进程收到的源码 **sha256 逐字节一致**、helper 的 OS CommandLine **7427 → 287 字符**、继承环境块仅 5.4KB（+7.2KB 远低于上限，实测塞到 100KB 仍能创建进程）。引导脚本先剥掉 `sys.path` 里的 `''`/`.`/cwd（`-c` 下 `sys.path[0]` 是**当前工作目录**），维持"标准库不被抢占"的隔离；再 `os.environ.pop` 取走源码执行（不把 7KB 留在 helper 自己的环境里）。命令 `subprocess.Popen([sys.executable,'-u','-c',_HELPER_BOOTSTRAP], env=…)` + CREATE_NO_WINDOW 常驻，JSONL stdin/stdout IPC（`request_caret_refresh` → `{id,reason,hwnd}`，reader 线程校验 `hwnd==请求窗口==当前前台` 才写缓存，过期结果丢弃）。`bar.show()` 每键请求刷新；定位先读 `get_ipc_caret()`，无则按窗口锚点/可见位兜底，35/80ms 后 `_ipc_reposition` 贴精确位。`get_caret_pos()` 兜底链：UIA 缓存 → GUITI(rcCaret) → 聚焦框 → last → 前台原点；**鼠标兜底禁用**。改动时别把 UIA 改回进程内跑（helper 崩溃会拖垮键盘 hook 的教训），别恢复鼠标跟随。**`runtime\` 残留（第三十八 → 四十三轮，已根治）**：老机器 `runtime\` 残留 pythonnet 时代的 python38 整包（`.pyd`/`Lib`…），helper 以脚本目录为 `sys.path[0]` 时它们会抢占标准库 import → 起来就秒退（用户日志：5 次里 4 次 0.15-0.19s `IPC helper exited`，跟随静默失效 + 每键白 spawn 一个 python）。现在**环境变量传源码 + 引导脚本剥掉 cwd** —— **别再改回"落盘 + `Popen([...,path])`"，也别改回把源码塞进 `-c`**（那会让进程命令行变成 7.4KB）。`_start_helper` 保留**连续秒退 3 次后不再重试**（`_helper_fail`）。A/B 证据见 CHANGELOG 第三十八/四十三/四十四轮（带残留的 `runtime\` 起不来；内联 `-c` → ready 137ms；环境变量版 → 命令行 287 字符、源码 sha256 逐字节一致）。**定位的工作区选择别搞错**（第十五轮核对）：跟随用**光标所在显示器**（`win.workarea_at()` → `MonitorFromPoint(MONITOR_DEFAULTTONEAREST)`+`GetMonitorInfoW`），而带宽上限取**主屏**（`win.screen_workarea()` → `SPI_GETWORKAREA`）—— 与 C# 的 `Screen.FromPoint` / `Screen.PrimaryScreen` 一一对应；`y+h` 超下边界要翻到光标上方、x 要钳进工作区（几何断言见 CHANGELOG 第十五轮）。
18. **可配置快捷键 / 候选操作键（两版共用 config 键）**：`hotkey_toggle/mode/makeword/trad` + `key_first/pageup/pagedown/back/cancel/raw/pickfirst/picklast`。C# 侧在 `KeyBordHook`（`VkFromName`/`ParseHotkey`/`SetKeyConfig`/`MatchMods`，缺省见类字段）；**python 侧在 `hook.py`**（`vk_from_name`/`parse_hotkey`/`configure`/`_rebuild_swallow` + `HOTKEYS`/`KEYS` 状态），由 `main.apply_config()` 用 `CFG['hotkeys']`/`CFG['ckeys']` 安装（`engine.load_config` 只原样收下，缺省在 hook 里），`main.handle()` 的按键分派全部改读 `hook.KEYS`。语义要点：`none`=禁用(0)、无效值忽略保持缺省、`hotkey_toggle` 非 `shift_tap` 时 Shift 轻拍停用、热键在"输入法未激活"时也生效（C# 热键判定在 IsLocked 之前）、组字中吞的候选键 = 配置键 + PgUp/PgDn 常驻。改这块时别再把键位写死回 `VK['SPACE']` 之类。
19. **单实例（wgime-py-pure）**：`win.single_instance('WgImePySingleInstance')`（ctypes 命名互斥体，句柄存 `main._SINGLETON` 保活）+ `win.message_box`（纯 Win32 弹窗，启动早期不建 tk）；已有实例则提示并 `sys.exit(0)`。名字带 `Py` 后缀，与 C# 的 `WgImeSingleInstance` 互不干扰；测试用 `WGIME_NO_SINGLETON=1` 跳过。
20. **联想开关要真的生效**：`engine.assoc_enabled`（由 `main.apply_config` 从 `CFG['assoc']` 同步）同时管**学习**（`learn_assoc` 提前返回）与**显示**（`get_assoc` 返回空 + `main.show_assoc` 提前返回），对齐 C# `AssocEnabled`。以前只翻了托盘勾选、实际照学照显示，是 bug。
21. **反查编码 (showcode) 的方向别搞反**：C# `CodeHint` = 五笔模式显**拼音**码、其余模式显**五笔**码（即"显示另一种码"）。python 侧用 `engine.build_rev_wb`（词→五笔码，按码 ordinal 升序扫、每词取最小码，同 C# `BuildRevWb`）+ `Engine.rev_wb_code()` **后台**建表（第三十四轮改：**首次用绝不同步建** —— `showcode=1` 是出厂默认值，同步建会让**每次启动的首键卡 1326ms**；没建好直接返回 `None`，`warm_rev_wb()` 起后台线程，`_invalidate_rev_wb()` 在 `_build()`/造词改 wb 时失效；详见 §6）。`main._with_code` 是唯一入口。
22. **英汉表 (ec) 只在「词典」模式 (mode 3) 参与候选**（C# `AddTranslate`）：`engine.candidates` 的 mode 0/1 绝不能查 ec——实测拼音模式打 `no` 会串出"不/没有/无"并把"弄/浓/农"顶掉。词典模式的 EN 前缀匹配要给**每个命中词的全部释义**（C# `AddCands`），不是只取首个。**第十七轮核对结论（别再"修"）**：mode 3 的候选**集合**与 C# `AddTranslate` 逐条一致 —— EN 精确 + EN 前缀 + CN→EN 反查（`PyDict` 全拼 + `Acro` 简拼 → 每个中文词查 `ce`）；`ce`（CN→EN）由 `build_reverse` 建，与 C# `BuildReverse` 逐行一致（EN ordinal 升序、每词上限 8、去重），实测 **701531 键全等**；mode 3 用**合并**频率视图（`self.freq`，同 C# `fb = ... : Freq`）且**不做** LastPick 置顶（同 C# `lpb = null`）。**唯一差异是 python §14 的频率排序**（稳定排序，探针复算后与 engine 输出逐项相同），不是 bug。**第四十四/四十六轮**：词典模式先取消、又被用户加回（英中查询顺手），现在 `ime.mode` 0..3（`% 4`）；「译文」选项（`config trans`，默认开）另管 —— ① 非词典模式候选挂 `translate_hint` 译文；② **仅当本模式零候选**（`not cands and not exact_wubi and mode < 3`）才 `candidates(buf,3,py)` 兜底；③ 词典模式本身不挂 `→译文`（候选就是译文），反查码照旧。所以本条"有拼音候选绝不查 ec"照旧成立。
23. **双拼 (shuangpin>0) 下的门控**（C# `if (Shuangpin == 0)`）：rq/sj/xq 动态候选、v 金额候选、**启动器候选**都不挂（两键即音节会撞码）；`digit_as_code()` 也要带 `CFG['shuangpin'] == 0`。另 `refresh()` 开头要有 C# 的两处面板复位：`sym_cat>0 && buf != 'vf'` 与 `shuangpin>0` 时清 `sym_cat`。
24. **五笔唯一四码自动上屏**要排除启动器候选：`refresh()` 里条件含 `cands[0] != ime.app_cand`（对齐 C# `!appSet.Contains(cands[0])`），否则会"自动启动程序"。
25. **状态反馈 = 托盘气泡（不是弹窗、也不是只写日志）**：C# 所有 `TrayTip`/`ShowBalloonTip` 调用点在 python 都有对应：`msg` 步骤、工具/插件执行结果（`开始执行…`/`完成`/`已取消`/失败）、per-app 上屏与 keyfix 切换结果、启动失败、[csharp] 插件编译/运行错误、造词剪贴板无汉字、钩子安装失败（`hook.start()` 同步返回成功与否 + `last_error()`，main 气泡）。python 侧统一走 `main._notify` → `TRAY.notify`（pystray），无托盘时退回 `tools._msgbox`；tools 层走 `tools._tip`。别再给这类结果提示写回 `_msgbox` 或只写 `_dfn`。
26. **tools.txt / 插件 txt 的块标签集合要完整**：`plugins.py` 的 `_TOOL_BLOCK_TAGS` 必须含 **8 个开标签**（shell/cmd/powershell/ps/shellx/cmdx/powershellx/psx）**与 8 个闭标签**——原来正则漏了 `cmdx`/`powershellx`/`[/cmd]`/`[/ps]` 等，会把块标签建成假按钮、块内容错位。另外 `load_tools` 要认 `[button 名]` 前缀、`code = xx` 允许写在步骤之后（都对齐 C# `LoadTools`）。块标签在 steps 里保留原文，由 `run_steps` 执行期配对（闭标签必须与开标签对应：`[ps]` 只由 `[/ps]` 收尾，同 C#）。**第二十轮补齐的 tools.txt 结构规则别回退**（详见 CHANGELOG 第二十轮 11 组 fixtures）：① 默认标签 `工具` **按需创建**（只含注释的 tools.txt 必须返回**空列表**）；② **没有按钮的标签页要保留**；③ `[tab ]` 空名用 `"?"`；④ `code` 行判定是 C# 的 `t.StartsWith("code")`（大小写敏感）+ `ToolToks(t)[2]`；⑤ 步骤行尾不带 `\r`。
27. **反向差异清单（python 有、C# 没有；别当成 bug 去"对齐"掉）**：`cnpunct` + Ctrl+. 全角标点切换、`F8` 硬开关、`Ctrl+Alt+Q` 退出、候选条主题（dark/light）、`learnk`/`recentk` 与近期热度排序（§14）、剪贴板「粘贴上屏」、`_CLIP_FORCE`（开始菜单/搜索强制剪贴板上屏，C# 在那类 UI 里注入会失败）、tray 的整句/联想/全角标点开关、**「译文」选项（离线词典译文；与「词典」模式并存：模式管逐条翻看，选项管日常打字的提示/兜底）**、造词对话框（C# 是剪贴板直造）、**鼠标旁的状态提示点（`statedot`，第六十九轮，见 §D11）**。**要往 C# 补需要用户明确要求**：改 wgime.bat 得走 §3 的瘦 DLL + ps1 + 15 项测试整条链。C# 的 `inDialog`（自带模态框期间让按键直通）python 有意不跟进——python 的造词/导入框含文本框，需要输入法可用。
    **第五十二轮登记的两处 hook 差异（用户已确认"保持现状"，别去"对齐"）**：① **Shift 轻拍更保守**：
    Ctrl/Alt/Win 按住时不武装轻拍、且松键有 0.4s 时限（C# 是 `if (shiftTap) shiftArm = true;` 无修饰键门控、
    `WM_KEYUP` 也无时限）；② **字母键判定排在空格/翻页之后**（C# 的 a-z 分支在前面）—— 于是 `config.txt`
    写 `key_first = a` 时 python 把 `a` 当空格确认、C# 当字母入码。两条都更像"python 有意保守化"，
    保持现状；**另外几处 python 有意比 C# 好的**：`_save_cfg`（写 config 失败弹气泡，C# `catch {}` 静默）、
    `calc._to_long` 越界报 `Err`（C# unchecked 给 long.MinValue，`x%3` 算出垃圾值）、
    `_write_config` 保持 config.txt 原有行尾（C# 也保持，但 python 修好了"LF 被改成 CRLF"）。
    **第六十七轮登记**：`keyfix` 的"牺牲字符"python 用 **`U+200B` 零宽空格**（`win.QT_FIX_SENTINEL`），C# 用可见的 `'X'` —— python 有意分歧：牺牲字符一旦没被应用吸收、退格又没生效，可见字符会留在文档里（用户报的"联想时打标点显示 X"），零宽空格则**看不见**。别再改回 `ord('X')`；改这块跑 `%TEMP%\wg-r67-qtfix-probe.py`（16 项，直接查注入事件序列）。
28. **用户可改的文本一律用 `engine.read_text()` 读**（`utf-8-sig` → `gbk` → `utf-8+replace`）：中文 Windows 下记事本/编辑器"另存为 ANSI(GBK)"会把 config.txt / tools.txt / plugins\*.txt / pastemode.txt / plugins-disabled.txt / userwords.txt / userdict_*.txt / lastpick_*.txt / assoc.txt 写成非 UTF-8 —— 用 `open(..., encoding='utf-8')` 会**抛 UnicodeDecodeError 直接崩启动**（C# 侧 `File.ReadAllLines(UTF8)` 是替换式解码, 不抛）。`read_text` 只以 OSError 表示不可读，编码问题一律降级；新增读取点照此办理（plugins.py 已 `import engine as engmod` 复用）。**便签文件也在名单里**（第二十三轮）：`notes\*.txt`（便签正文，用户最常拿记事本改）、`notes.txt`（旧版迁移源）、`notes-meta.txt`、`note-color.txt` —— 用严格 `open(..., encoding='utf-8')` 读会抛 `UnicodeDecodeError`，而那里的 `except OSError` 抓不到，结果是**便签窗口打不开/半死**（`_note_win[0]` 已置上，再点只是 deiconify 坏窗口），C# 的 `File.ReadAllText(UTF8)` 则是替换式解码永不抛。**码表与插件也在名单里**（第三十二轮）：`py.txt`/`wb.txt`/`ec.txt`/`trad.txt`/`import_*.txt`（`engine.parse_dict` —— 严格 utf-8 会让 GBK 码表**把启动直接打崩**，且 BOM 会让**第一行读不进来**，所以快路径用 `utf-8-sig`、失败退回 `read_text`）、用户手改过的 `import_*.txt`（`load_import_base`）、插件 `.py`（`main._py_plugin_meta_static`：GBK+coding 声明的插件 python 能跑，严格 utf-8 会让插件管理器列举时崩）。
   **配套：写这些文件时行尾要跟 C# 对齐** —— C# 的 `ImportCodeTable` 写 `import_*.txt` 是 `WriteAllText(..., UTF8Encoding(false))` + `'\n'`（**裸 LF**），python 的 `open(..., 'w')` 在 Windows 上会翻成 CRLF（`import_*.txt` 是入库跟踪文件，被翻成 CRLF 就是整文件 diff）；所以 `engine.write_import_file` 必须带 `newline='\n'`。反之 `config.txt` 是 C# `WriteAllLines`（CRLF），python 默认写 CRLF 正好一致。
   **读的那一侧注意（第五十轮）**：`read_text` 是**二进制读 + 解码**，**不做 universal newlines**（§39），
   所以按 `'\n'` 切行后行尾的 `\r` 还在——需要值干净的地方必须自己 `line = line.rstrip('\r')`。
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
   `wgime-py-pure\dist\wgime-py.py` 变脏**（只有一个 `THIRD_ZIP_B64` 行不同）。dist 内嵌 11 个项目模块 +
   `main.py`（**不含插件**；第六十九轮起含 `dot`，见 §D11），所以只改插件（或任何不内嵌的文件）时，构建完应
   `git checkout -- wgime-py-pure\dist\wgime-py.py` 把这条噪声回退掉，再用
   `%TEMP%\wgime-dist-sync-check.py` 确认 dist 仍与磁盘逐字节一致。

31. **config 键的"取值语义"以 C# 为准，白/黑名单别搞混**（第十轮审计发现 `followcaret` 搞混了）：C# `LoadConfig`（wgime.bat 1663-1747）里 **白名单**（`v=="1"||v=="on"||v=="true"`，非法值一律判"关"）= `showcode`/`keyfix`/`followcaret`/`hideidle`/`trad`/`starton`；**黑名单**（`v!="0"&&v!="off"&&v!="false"`，非法值判"开"）= `sentence`/`assoc`。python 侧逐键照此（`engine.load_config`）；python 独有键 `cnpunct` 用黑名单。`paste`（on/always→1, off→2, key/unicode→3, 其余→0）、`shuangpin`（xiaohe/小鹤/flypy→1, ziranma/自然码/zrm→2, ms/微软/mspy→3, 其余→0）、`mode`（仅 `tray` 生效）、`fuzzy`（none/off/空→清空；一对都解析不出则保持缺省）也都与 C# 逐值对齐过（275 组用例）。**改 `load_config` 后要重建 dist + package**（dist 内嵌模块源码）。有意保留：非法 `hotkey_*`/`key_*` C# 保持当前字段、python 回缺省；python 多认单引号 `app =` 命令。

32. **步骤 DSL（`plugins.py` `run_steps`/`_run_verb`）的动词语义对齐 C# `ExecToolStep`**（第十一轮审计）：① `confirm` 的 `title=`/`buttons=`/`default=` 三项必须**真的生效**（`_confirm_args(arg, confirm, **msgbox**)` —— `msgbox` 是参数，原来漏传导致 `buttons=ok` 直接 `NameError` 崩；`okcancel` 走 OK/Cancel，缺省按钮是"否"对齐 C# `MessageBoxDefaultButton.Button2`），回调签名 `confirm(text, title, buttons, default_no)`，保留单参数旧回调兼容；② `kill` 只看**第一个 token**（C# `tk[1]`），不是整行 rest；③ 缺参动词（`run` 无程序名、`reg-set` <4 token、`reg-del` 无键路径）必须**记一步失败**，不能静默成功（C# 是 `tk[n]` 越界抛异常）；④ 多行块控制台显示名按 C# 映射：`cmd→[shell]`、`shellx|cmdx→[shellx]`、`powershellx→[psx]`、`powershell|ps→[powershell]`。python 有意保留：破坏性动词执行前强确认（§16）、块开标签大小写不敏感、`file-del C:\*` 拒删（C# 会真删 C 盘根）。改完 `plugins.py`/`tools.py`/`main.py` 要重建 dist + package。

33. **hook 吞键表的判定次序：别把 `Shift` 提前透传**（第十二轮审计）：C# `bare = !ModifierDown()`，而 `ModifierDown()` **只含 Ctrl/Alt/LWin/RWin**（wgime.bat 124-130）——所以**组字中** `Shift`+数字/退格/Esc/回车/空格/PgUp/PgDn/配置翻页键在 C# 里照样被吞；只有 `a-z`、`;`（SemiAsCode）、以词定字 `[`/`]` 显式要求 `!sh`。python `hook._proc` 的次序必须是：数字（`COMPOSING`）→ `_swallow`（退格/取消/回车/空格/翻页，只要求 bare）→ `_swallow_pick`（`!sh`）→ 中文标点（MapPunct：`/` 只有 Shift 有映射、`\ [ ]` 只有裸键有映射）→ `if shift: 透传` → 裸字母；`_rebuild_swallow` 就按这两组建表。改动后跑 hook 判定矩阵（伪造 lParam + `_key_state` 直接调 `_proc`，见 CHANGELOG 第十二轮 89 例）再提交。

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
    python 版托盘以前**运行时**用 Pillow 画图标，而单文件只内嵌 comtypes/uiautomation/pystray，**没内嵌 Pillow**
    （带 `_imaging.pyd`，ABI 绑定，内嵌源码跨版本没用）→ 没装 Pillow 的机器 `import PIL` 直接失败、**整个托盘消失**；
    "`python wgime-py.py` 却正常"是因为 PATH 上的 python 恰好是**另一个装了 Pillow 的版本**（与双击用的解释器不同）。
    现在：构建时渲染 9 个 ICO（`build-wgime-pure.py` → `TRAY_ICONS`，5.2 KB base64）内嵌，运行时
    `win.icon_from_ico_bytes()` 写进 `runtime\icons\` 再 `LoadImageW` 成 HICON，**不再需要宿主 Pillow**；
    换图标走 `NIM_MODIFY|NIF_ICON`（看 `tray.NIM['modify_ok']`）；`HAS_PIL` 只作源码布局的回退路径。
    诊断（第四十一轮，别删）：pystray 不检查 `Shell_NotifyIcon` 返回值、报错只走 `logging`→`sys.stderr`，
    而 pythonw 下 `sys.stderr is None` → 收 `tray.LOGS`/`NIM['add_ok']`/`last_error`，`main._tray_selfcheck()`
    写 **always-on** 日志并在真失败时**从后台线程**弹框（主线程弹会卡住 poll=打字停摆）。三个坑：
    ① `Shell_NotifyIconGetRect` 不能当"登记上没有"的判据（`NIM_ADD=True` 时也可能回 E_FAIL，只反映在不在可见区）；
    ② GetRect 的 uID 必须是 `id(icon)`；③ 判断"用户能不能看见"用 `win.tray_promoted()`
    （`HKCU\...\NotifyIconSettings\<hash>\IsPromoted`，新机器/新 exe 默认隐藏进 `^`）。**同类坑第六十九轮又踩一次**（pystray 的 `six` 漏嵌，见 §12）—— 判据固定为: 用 `python -S -E` 跑一遍真成品，或跑 `tests\embedded-isolation-test.py`；`%TEMP%\wg-r70-clean-live.py` 是干净环境实机探针。
    探针：`%TEMP%\wg-tray-selfcheck-probe.py`、`wg-nopil-tray-probe.py`（假 PIL + 真实 pythonw）、
    `wg-nopil-switch-probe.py`（切模式换图标）、`wg-shellnotify-probe.py`。

37. **译文质量 = 英语常用词表（第四十五轮）**：`ce` 由 `ec.txt` 反建，旧代码取字母序第一个 →
    `测试→dvdram`/`你好→alohas`/`老师→dorina`（生僻词/人名/缩写，用户实测"不太妙"）。现在
    `build_reverse(ec, load_en_rank(dict_dir))`：按 `en-freq.txt`（Hermit Dave FrequencyWords `en_50k`，
    **MIT**，随分发目录一起发）排序，**没有常用英语词的干脆不进 `ce`**（查不到就不挂）；表读不到就退回
    旧行为（stderr 说明）。`EN_HINT_MAX_RANK=50000` 可调；`en-freq.txt` 在 `CACHE_FILES` 里（换表 → 老缓存失效一次）。

38. **语音输入（第四十七轮，python 独有）**：`voice.py` = waveIn 录音（纯 ctypes，VAD 静音自停，别用已移除的 `audioop`）
    + 四条后端（`voice_engine`：`system` 系统离线引擎 System.Speech，走 `powershell -EncodedCommand` 内联脚本
    **不落盘**、结果 base64 回传 / `http` Whisper 兼容 / `whisper` **常驻本地 faster-whisper 子进程**（第六十三轮，
    见本条第末）/ `cmd` 外部命令带 `{wav}`）。热键 `hotkey_voice`（Ctrl+Alt+V）
    按住说话，hook 的 `WM_KEYUP` 报 `VK_VOICE_UP`，**只在 `VOICE_ON` 为真时吞键**；「语音」模式（`MODE_VOICE=4`）
    里 `VOICE_MODE` 让钩子把按键**全部透传**（不组字），轻点热键 = 常录。结果默认进候选条等空格确认
    （`voice_auto=1` 直接上屏），上屏走 `inject()` 但**不进词频学习**。麦克风隐私开关 Deny 时 `waveInOpen` 会 rc=1 →
    必须报"去开 设置→隐私和安全性→麦克风→允许桌面应用访问麦克风"（`voice.mic_consent()`）。
    **第四十八轮补的坑**：① `_write_config()` 以前在 `APP_DIR\config.txt` **不存在**时静默失败（`except OSError: pass`），
    而 python 版可以不带 config.txt 跑 → **所有托盘开关都"点了不落盘"**；现在文件不存在就**新建**，返回 `True/False`，
    失败写 always-on 日志。② hook 里 voice 热键的**按下**也要按 `VOICE_ON` 门控，否则"没开语音"时 Ctrl+Alt+V
    被吞还弹"没打开"气泡（语音没开就该完全透传）。
    **第四十九轮**：**切到「语音」模式 = 顺手打开语音功能**（`_voice_set_on`，幂等；否则模式菜单点了"没作用"）；
    离开模式不关功能（热键随处可用）；**选项里关掉语音时若在语音模式则自动切回混合**；模式子菜单显示名
    「语音模式」（`tray.MODE_MENU`），选项叫「语音输入 (总开关)」——别再两个都叫"语音"。
    **第五十八轮（"感觉收不了音/一直 0s"的三个真因）**：① **按住热键的自动重复必须丢掉**——Windows
    对按住的键每 ~33ms 补发一次 `WM_KEYDOWN`（`KBDLLHOOKSTRUCT` 里**没有**重复标志，只能靠自己的
    "键还按着"状态挡），以前每次重复都入队一个 `VK_VOICE`，而 `voice_down()` 见"已经在录"就当成
    **第二次点** -> `voice_finish()`，下一次重复又开一段**新**录音（`t0` 归零、界面永远 "(0s)"、
    说话被切碎、松开时已经没有 rec 可收尾）；现在 `hook` 里 `if VOICE_DOWN[0]: return 1`，并在
    **修饰键已松开**的 V 按下处清 `VOICE_DOWN[0]`（防松键丢失后热键被永久卡死）。② **录音期间要重画
    候选条**（`main._voice_tick()`，poll 里 ~4Hz；`voice_down` 把 `_VOICE_TICK[0]` 归零）——以前
    全程不重画，条上那句 "(0s)" 是按下瞬间的**死字符串**，用户根本看不出在不在录。③ **VAD 阈值 =
    自适应底噪**：`_floor` 取**最小**（`if r < floor: floor = r`）、`thr = clamp(floor*3.5, 180, 1200)`。
    别改回"头 500ms 取中位数、凑不够 2 块就兜底 300"——块是 200ms，再叠上 `waveInOpen/Start` 的
    启动延迟（实测 100~300ms），那个窗口经常只落进 1 块，于是阈值永远是写死的 300。
    诊断提示也要能判断：全 0 PCM（`voice.peak() == 0`）报"**麦克风给的是纯静音**(输入设备被静音/
    选错设备)"，否则报峰值/音量数值。探针 `%TEMP%\wg-r58-voice-hold-probe.py`（18 项：假造自动重复
    喂真 `hook._proc`、真 `handle()` 的 start/finish 序列、真 `_on_data` 的 VAD 单元测试、静音提示）。
    **第五十九轮（云端 STT 的代理坑）**：`voice_engine = http` 的请求统一走 `voice._http_post(url, body,
    headers, cfg)`，按 `stt_proxy` 决定顺序：空/`auto` = 先系统/环境代理、**连不上就回退直连**；`direct` =
    只直连；`http://host:port` = 只用它。两个必须守住的点：① **每条路都要重建 `Request`** —— 走代理时
    `OpenerDispatcher` 会 `req.set_proxy()` **就地改 `req.host`**，复用同一个 req 去"直连"其实还是连那个死
    代理（回退白做）；② 服务端**回过话**（HTTPError）就不换路/不重发，只在**连接层**失败时换路，并把
    **每条路的原因**一起报出来。本机真实故障：注册表里留着已关闭的 `http://127.0.0.1:10808` ->
    `getproxies()` 每次都去连它 -> 10061，云端识别永远失败；硅基流动端点直连实测能拿到 `HTTP 401
    {"code":30014,"message":"Token is invalid."}`（端点/鉴权/multipart 形状都对）。
    探针 `%TEMP%\wg-r59-stt-proxy-probe.py`（18 项，全打**本地假服务器**，不依赖外网 —— 本机外网时通时断，
    真端点做断言不可复现）。硅基流动接入（`config.txt`）：`voice_engine=http`、
    `stt_url=https://api.siliconflow.cn/v1/audio/transcriptions`、`stt_key=sk-…`、
    `stt_model=FunAudioLLM/SenseVoiceSmall`、`stt_lang` 留空（该接口只认 `file`/`model`，SenseVoice 自判语种）。
    **第六十轮（硅基流动两站的区别，实测）**：**国内站 `cloud.siliconflow.cn` 与国际站 `siliconflow.com`
    是两套账号/密钥、互不通用，而且国际站没有可用的识别模型**（音频类只有 TTS 合成）。用错站点的症状是
    **401 `Token is invalid`** —— **先对站点，再怀疑 key**。实测代码/模型清单见 `AGENTS-DETAIL.md` §D7。
    **第六十一轮（"按了 Ctrl+Alt+V，说不到 2 秒就自动停"的真因）**：VAD 阈值**不能只看绝对底噪**。
    第五十八轮写成 `thr = clamp(floor*3.5, 180, 1200)`（`floor` = 见过的**最小** RMS），于是
    **"按住热键就说话"**（开头压根没有一个静音块）或**麦克风增益偏热**时，`floor` 是从**说话声**里取的
    （比如 600）→ `thr` 被顶到上限 **1200**；而正常说话只有几百~一千出头 → **说话声自己**被判成"静音"
    → 攒够 `voice_silence`（默认 1.2s）就收尾。停止时刻 = `MIN_MS(400) + 1200 ≈ 1.2~1.6s`，与"说不到 2 秒"吻合。
    **现在阈值取两者较小**：`thr = min(clamp(floor*3.5,180,1200), clamp(peak*0.25,180,600))`，
    `peak` = 最近听过的最响块（每块 ×0.9 慢衰减，防麦克风开启那一下的爆音长期抬高阈值；再叠 600 上限）。
    相对项**只会把阈值往下拉**，所以句内换气/弱音节不再被当成"说完了"；真静音（接近 0）仍远低于两者，
    该停还是停。**别改回"只留 thr_abs"** —— 那就是第五十八轮那版，会把说话判成静音。
    代价：噪声大的房间里噪声会被当成说话 → 不会自动停（宁可不停：用户本来就是松开热键结束，
    要彻底关掉自动停就 `voice_silence = 0`）。**每次录音都留一行 always-on 诊断**
    （`voice: rec <ms> blocks=… spoke=… auto_stop=… floor=… thr=… peak=… quiet=…ms silence=…ms`，
    不含音频内容）—— 这类问题只能靠现场数字定位。判据拆在 `Recorder._vad_block(r, elapsed)` 里就是为了能
    headless 测：**改 VAD 必须跑 `python wgime-py-pure\tests\voice-vad-test.py`**（31 项，纯桩不碰麦克风；
    把阈值改回旧写法会 **10 条失败**，其中 A1 直接复现"停在块 6" = 1.2 秒）。
    **第六十二轮（"中文识别率太低"）**：先分清事实 —— 系统引擎走的是 `System.Speech`
    （`Microsoft Speech Recognizer **8.0** for Windows`，SAPI5 老桌面引擎），跟 Win+H「语音输入」用的
    神经引擎**不是同一套**，天花板本来就低。但这里确实还有我们自己的一个真 bug：
    **`Recognize()` 一次只返回一段**（引擎按停顿把一句话切成多段），原来只取第一段 → 长句只出来前半截。
    实测（用系统 TTS `Microsoft Huihui Desktop` 合成中文再喂我们自己的路径；探针 `%TEMP%\wg-r62-sysrec-probe.py`）：
    33 字那句修前只回 **16 字 / LCS 覆盖 18%**（后半句整段消失），修后 **27 字 / 39%**（`segs=2`）。
    修法：循环 `Recognize()` 收齐所有段再拼接（CJK 用 `''` 拼、其它语言用 `' '`）。
    **坑**：WAV 流读完后**再调 `Recognize()` 不是返回 `$null`，而是抛 "No audio input is supplied"**（实测），
    所以循环内必须自己 try 住并 break —— 否则异常冒到外层 catch，已经收到的段全丢
    （只有**第一次**就抛才算真错误，留给外层报）。每次识别另记一行 always-on：
    `voice: sys-rec segs=<段数> chars=<字数>`。
    **要真正提升中文识别率只能换后端**（都不用改代码，只改 config.txt）：`voice_engine = whisper`
    （**本地常驻 faster-whisper，离线、中文 88~100%、每句 3~5s —— 推荐**）、`voice_engine = http` +
    硅基流动**国内站** `SenseVoiceSmall`（每句 ~1s，要国内站 key）、或 `voice_engine = cmd` + 本地 whisper.cpp
    （**每句都新起进程，实测 20s+，别拿它跑本地 whisper**）；`system` 只适合"完全不想配置"的场景。
    **第六十三轮（`voice_engine = whisper`）**：**别再让本地 whisper 每句新起进程** —— 实测每句 20s 里有 16s
    是重付的 `import faster_whisper`(6.5s)+载模型(2~9s)，常驻后每句 3~5s。做法照 §17 helper（源码走环境变量 /
    JSONL 走 stdio / **回包用 `ensure_ascii` JSON**，裸 UTF-8 在中文机会变 `?` / **父进程退出=stdin EOF=子进程自退**）。
    **两个锁别合并**：`lock` 只管起杀（预热在主线程调它，绝不能等识别，否则打字停摆）、`rlock` 管一问一答。
    预热两处：启动 +4s 后台（`stt_prewarm=0` 关）+ **按下热键那一刻**（与说话重叠）。键：`stt_model`/`stt_lang`/
    `stt_prompt`/`stt_device`/`stt_compute`/`stt_beam`/`stt_python`。改这块**必须**跑
    `python wgime-py-pure\tests\whisper-warm-test.py`（67 项，假 Popen 照抄真管道语义）。实测数字/两处真 bug/探针见 `AGENTS-DETAIL.md` §D6。
    **第六十四轮（本地离线识别已落地，实测可用）**：`voice_engine = cmd` + `stt_cmd = python C:\Tools\wgime-local-asr\wgime-stt.py {wav}`（本机已装 sherpa-onnx 1.13.8 + SenseVoice-Small int8 228MB；**wrapper 的 stdout 只许打印识别文本**，`_cmd_recognize` 取第一行非空）。实测中文 TTS：`今天天气不错，我们下午3点开会。`，**建会话 1.5s + 解码 0.24s**（比 whisper 常驻 3~5s 更快）。细节/模型源/坑见 `AGENTS-DETAIL.md` §D8。
    **第六十五轮（硅基流动国内站 + 坏网络三件套）**：同一把 key 在 `.com` 回 **401**、在 `.cn` 的
    `/v1/models` 回 **200** -> 国内站 key 必须配 `api.siliconflow.cn`（与第六十轮正好相反）。
    新增 `stt_retry`（连接层失败同路重试，默认 3，1~8；**HTTPError 不重试**，免得白花额度）、
    `stt_timeout`（默认 15s，5~60，取代写死的 30s）、**记住可用路径**（自动模式哪条通就下次优先；
    本机那个本地代理已是"黑洞"，不记住的话每句白等 3×timeout）。本机实测成功时 **0.6~0.85s**，
    但网络窗口坏时 1/6~3/5 成功、失败一次 ~30s —— 那是环境（中间设备改 TLS 记录），不是配置问题；
    要稳就用离线 `cmd`+SenseVoice。数字见 `CHANGELOG.md` 第六十五轮与 `AGENTS-DETAIL.md` §D7.1。
    **第六十六轮（双引擎赛跑 `voice_fallback`）**：第二个引擎与主引擎**同时开跑、谁先成功用谁**
    （`voice._race_engines`），不是"失败再回退" —— 坏网络下云端要十几秒才报错，串行回退每句要 24~38s，
    赛跑后平均 **2.80s / 4全对**（本地 ~3.5s 赢或云端 0.73s 赢）。两个都失败才报错(带两边原因)；
    `http` 主引擎配了它时重试/超时收紧成 2×10s。命中第二个引擎写 always-on 日志，不弹气泡。
    代价：每句都会跑一次本地引擎。探针 `%TEMP%\wg-r59-stt-proxy-probe.py` H 段 6 项覆盖。

39. **`read_text` 读来的行尾 `\r` 不能进值 —— 字符串比较会静默失效（第五十轮的真 bug）**：`read_text` 是
    **二进制读 + 解码**（为了 GBK/ANSI 兼容，§28），**不做 universal newlines**，所以 CRLF 的 `\r` 会留在行尾。
    `engine._load_freq` 读 `lastpick_*.txt` 时按 `'\n'` 切行后只 `rstrip('\n')`（**无效**，行早就按 `\n` 切了），
    于是 `\r` 被当成词的一部分存进 `lastpick_m`；写盘时 text 模式又把 `\n` 翻成 `\r\n` →
    **每轮"载入/存盘"长一个 `\r`**（用户现场 `%LOCALAPPDATA%\wgime-py\lastpick_mix.txt` =
    `bm 出\r\r\r\r\r\r\r\r\r\r\r\r`，探针实测 17→19 字节/轮）。**真危害**：`candidates()` 的 LastPick 置顶是
    `lp = lastpick_m[mode].get(keys); if lp and lp in cands` 的**比较** —— 值带 `\r` 永不相等，
    "上次选的词置顶"**静默失效**（文件难看只是表征）。**规则**：按 `'\n'` 切行后第一件事 `line = line.rstrip('\r')`
    （或像 `plugins.py` 那样 `rstrip('\r\n')`）；扫过的其它读取点（config/assoc/userwords/pastemode/tools/插件/便签）
    都靠 `strip()` 侥幸躲过——**新写的解析点别省这一步**。写盘仍保持 CRLF（与 C# `File.WriteAllLines` 一致）；
    脏文件在下次载入/存盘时自愈。永久回归：harness（`lastpick 值不带 \r` + `lastpick 仍置顶`），
    探针 `%TEMP%\wg-r50-lastpick-probe.py`（修前 5/9 → 修后 11/11）。

40. **全量审计的硬规则（第五十一轮）**：7 路 subagent 分模块审 + 横切 AST/不变量探针（56 条候选，
    修掉 20 项；已修/未修明细见 CHANGELOG 第五十一轮与 `AGENTS-DETAIL.md` §D5）。要照做的：
    ① **`_merge_user_words` 必须 py + wb + acro 三样都补**（C# 是 `MergeUserWords` → `MergeUserWordsWb`
    → `BuildAcro`），且 `_init_state` 里三张派生表（char_wb/wb_by_len/word_freq）要在合并用户词**之前**就绪
    （合并要用 `char_wb` 算五笔构词码）—— 只并拼音表的后果是"造的词重启后简拼/五笔查不到"；
    ② **读用户文件要先读完再动内存**：`clock.load_cfg` 原来开头就 `ALARMS.clear()`，读失败（被独占/GBK/
    读到 C# 写一半）就只剩"空"，紧接着一次无条件 `save_cfg` 把整份闹钟覆盖掉；
    ③ **缓存/索引签名要覆盖它依赖的全部输入**（`userwords.txt` 曾漏 → 删词后出现删不掉的"幽灵词"）；
    ④ **给 helper/子进程写管道必须非阻塞**（helper 串行读 stdin + 4KB 管道 ⇒ `stdin.write` 会把 Tk 主线程
    永久阻塞，输入法卡死且不可自愈；改 `os.set_blocking(fd, False)` + `os.write`，满则丢弃这次刷新）；
    ⑤ **后台线程里的异常必须兜住并报出来**（pythonw 下 `sys.stdout/stderr` 都是 None，裸线程抛异常完全无声，
    用户只看到"点了没反应"）—— `main._bg_plugin` 是统一入口；
    ⑥ 菜单/图标/模式表索引一律 `% len(表)`，不要写死数字（第四十九轮 `% 5`、第五十一轮托盘图标 `% 4`）；
    ⑦ `.py` 插件的"停用"判断要在 `exec_module` **之前**（否则被停用的插件每次启动仍执行模块级副作用）；
    ⑧ **权限是多值的**：`perm` 支持 `network,run` 这类逗号列表，判定要拆集合求交，别用整串 `in`。

41. **`place()` 布局的子控件不会撑大父容器 —— Canvas 滚动区的 `inner` Frame 必须显式给尺寸（第五十三轮的真 bug）**：
    `tools.py show_toolbox` 的磁贴区是 `Canvas` + `create_window(inner)`，而磁贴由 `ui.flat_button` 用 **`place()`** 摆。
    **`place()` 不参与父容器的 requested size**，所以 `inner` 只有 **1x1**、`canvas.bbox('all')` = `(0,0,1,1)`、
    window item `winsize=0x0` —— 磁贴**明明已经建出来、尺寸和坐标都对**（245x46 @ 14,14），却全被 Canvas 裁掉，
    表现为"**标签页在、按钮一个都看不见**"（用户报的"工具箱里的配置都无法显示了"就是这个）。
    修法：按磁贴行列算出真实尺寸，**三件事都要做** —— `inner.configure(width=, height=)`、
    `create_window(..., width=, height=)`、`canvas.configure(scrollregion=(0,0,w,h))`（只设 scrollregion 不解决裁剪）。
    **判据**：`canvas.bbox('all')` 若等于 `(0,0,1,1)` 就是中了这个坑。凡是"Canvas + place 子控件"的滚动区都照此办理。
    **同一处还有两个连带坑（第五十三轮一并修掉）**：
    ① **滚动条只在内容真的超出可视区时才 place**——原文无条件 `vsb.place(...)`，两个磁贴也挂一条滚动条
    （`need_sb = inner_h > BODY_H`）。磁贴宽度两种情况下都用 `inner_w`，免得滚动条出现/消失时栅格跳动。
    ② **挂在 `content` 上的控件必须按内容区高度算 y/height**——`ui.make_window` 的 `content` 是**标题栏下方**那块
    （`y=38, height=h-38`），而日志框原先按**整窗高**算 `y=H-118` 却挂在 `content` 上，底边落到 456、超出内容区
    (432) 整整 24px，最后几行被窗口边缘切掉。**统一用 `CH = H - 38` 推**（本窗：`LOG_H=132`、`BODY_H=CH-46-LOG_H-GAP-4=240`，
    240 仍够放 4 行磁贴）。底部日志由 `ui.console_text` 建，第五十三轮给它补了**垂直滚动条 + 滚轮**
    （工具箱/网络工具/聊天窗三处共用；以前光秃秃一个 `Text` + `wrap='none'` + `see('end')`，输出一多就只剩最后几行且无法回看）。

42. **`ui.make_window` 的窗口高度必须把标题栏那 38px 算进去（第五十五轮，一次修了 5 个窗口）**：
    `content` 只占 `h-38`，但这些窗口的 y/height 都是按"可用区"排的（例：剪贴板按钮 `y=348+30=378`），
    窗口高度却按 380 给 → **底部控件被窗口边缘裁掉**。**规则：窗口高度 = 内容真正需要的高度 + 38**（再留 ~10px 边距）。
    本轮审计出并修掉的：剪贴板 380→**452**、取色器 210→**246**、造词 200→**232**、用户词表 342→**378**、
    插件管理 420→**452**。同一轮还修了：① 插件管理顶部按钮条总宽 `494+7*8=542 > bar 的 540`（最右「运行」
    被右边缘切 2px）→ 起点改 0、间距 8→6（530）；② 剪贴板那句提示不限定宽度又放在 `x=390` → 右边缘冲到 606
    （窗口才 520）→ 挪到按钮下方单独一行 + 显式 `width`。
    **审计方法（别再靠肉眼）**：把窗口建出来，遍历子孙算绝对 `(x+w, y+h)` 与窗口宽高比，超出的即被裁 ——
    探针 `%TEMP%\wg-window-audit2.py`（覆盖 10 个内置工具窗口）、`wg-window-audit3.py`（造词/用户词表用假 engine）。
    **便签滚动条改成按需**：Text 的 `yscrollcommand` 里判断 `yview() == (0.0, 1.0)`（装得下）就 `place_forget`，
    溢出才 `place`；**正文宽度保持不变**，免得滚动条出现/消失时文字左右重排。
    **给 tk 窗口设 Win32 样式（不激活/穿透/透明/置顶）必须写"顶层外框"**：`winfo_id()` 给的是 **`TkChild` 子窗口**，
    真正的外框是 `GetAncestor(GA_ROOT)`（`TkTopLevel`）—— 写到子窗口上 `GetWindowLong` 读得回来、但窗口管理器不看，
    等于没生效（第六十九轮实机 dump 抓出来的真 bug，一行改动：`win.top_level_hwnd()`；细节见 `AGENTS-DETAIL.md` §D11）。

43. **托盘图标的句柄时序（第五十六轮，两条都是真踩过的坑）**：
    ① **图标还没登记上（`icon.visible` 为假）时绝不换图** —— `Tray.start()` 注入 h0 后由 `run_detached()` 的
    **setup 线程**发 `NIM_ADD`，主线程紧接着的 `_refresh()` 若此时销毁 h0，shell 记住的就是**已销毁的句柄**
    （表现：刚启动那一下托盘图标空白/乱）。第五十一轮那版"无条件 `_release_icon()`"就是这个回归。
    ② **换图顺序:先注入新句柄 → `NIM_MODIFY` → shell 接受之后才 `DestroyIcon` 旧句柄**。pystray 的
    `_release_icon()` 销毁的是**当前** `_icon_handle`（不是刚换下来的那个），要销毁旧句柄用 `win.destroy_icon()`；
    同一张图（key 相同）重复刷新只 `update_menu()`，不重建 HICON、不惊动 shell。
    ③ **图标要"早挂"**：词库加载是**主线程 join**（热 1.5-1.9s、冷建 7.8s），托盘原排在 join 之后的
    `after(150)` 里 → 那段时间托盘里什么都没有。现在 `_boot_tray()` 在 join **之前**先挂最小菜单图标，
    词库读完由 `_deferred_tray` 补完整菜单（`TRAY.api = _tray_api(); rebuild(); _refresh()`）。
    **改启动顺序时别把 `_boot_tray()` 挪到 join 之后**；`tray.start(boot=True)` 用的是最小 api
    （只有 toggle/is_active/get_mode/quit），**不要在 boot 分支里加需要 CFG/工具/插件的调用**。
    实测（真成品冷启动）：boot icon @+0.76s，engine load @+5.19s（差 4.43s），完整菜单 @+5.40s。
    ④ **换图"成没成"只能看 `NIM['modify_ok']`，绝不能看 `icon._message()` 的返回值**（第五十七轮的真 bug）：
    pystray `_win32._message()` 只是调 `Shell_NotifyIcon(...)`、**没有 return** → `bool(...)` 恒为 False。
    第五十六轮据此判定"换图失败"，于是 `_cur_key` 永不推进 → "同 key 只刷菜单"这条分支拿旧状态当
    "图标已经是新的" → **从语音/词典切回混合、或按开关打开输入法时图标纹丝不动**（用户报"托盘图标都不会变了" /
    "混合的模式切换不过去"：空闲隐藏下候选条不显示，图标是切模式**唯一**的反馈，所以看起来像"模式没切" ——
    模式循环本身没问题，`%TEMP%\wg-r57-mode-cycle-probe.py` 21/21）；同时旧句柄永不销毁 → 每次刷新漏一个 HICON。
    现在换图统一走 `Tray._notify_icon(h, key, old)`，状态拆两个：`_cur_key` = **pystray 当前句柄**对应的 key
    （注入后立刻推进），`_shown_key`/`_shown_handle` = **shell 确认接受**过的 key/句柄（只有 `modify_ok is True`
    才销毁旧的 `_shown_handle`；**shell 拒收时不谎报**，下次用**同一个句柄**补发 `NIM_MODIFY`，不重建、不漏）。
    改这块**必须**跑 `python wgime-py-pure\tests\tray-swap-test.py`（42 项，假 icon 照抄真 pystray 的
    "`_message` 无返回值"语义）—— 第五十三轮那个探针的假 icon `return True`，比现实宽松，因此漏掉了本回归：
    **桩不能比真的更宽容**。该文件第五十七轮写完文档却**忘了提交**（2026-09-15 补齐），补时做了"守卫有效性"
    自检：把 `_notify_icon` 临时改回第五十六轮那种 `bool(icon._message(...))` 写法 → 测试 **11 条失败**
    （含 B7「返回 None 而状态仍推进」），还原后 **42/42** —— 记住：**一个不会失败的测试等于没写**。

## 6. 加载与性能（已做的优化，改动时别回退）

> **细节在 `AGENTS-DETAIL.md`**：正文只留"要照着做的规则"，实测数字/探针清单/历史轮次来龙去脉
> 都搬到了 `AGENTS-DETAIL.md`（需要时 read 它，别凭记忆猜）。AGENTS.md 有 64KB 的注入预算上限。

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
  1. `powershell -NoProfile -ExecutionPolicy Bypass -File tests\build-release-assets.ps1 -Version 1.2.7` → 三个 zip
     （`.release-stage-v127\`；`-OnlyPython` 只重做 python 包）。脚本内的三条坑：zip 条目要逐条写 `/`、源目录必须长路径、
     **python 包取自 `package\`，改完源码先跑 `build-package.ps1`**（有 hash 守卫，防发出上一个构建）。
  2. `tests\publish-release.ps1 -Version X -BodyFile <body.md> -AssetsDir <stage>`（同 tag 走 PATCH + 覆盖资产）。
     **务必先 push 再 publish**（脚本用本地 HEAD sha 作 target_commitish —— 传 master 会按远端解析，v1.2.9 就踩过）。
  3. 发完**回验**：线上 python zip 的 SHA256 与 stage 相同、内层 `wgime-py.py` 与 dist 逐字符一致、body 无 `?`、tag=本地 HEAD。
- **中文坑**：release body 用 `HttpWebRequest` 显式 UTF-8 字节发（脚本已内置）；**别用 `Invoke-RestMethod`+`ConvertTo-Json`**（PS 5.1 把中文变 `?`）。
- **Token**：脚本依次 `-Token`→`GITHUB_TOKEN`→`GH_TOKEN`→凭据管理器→`git credential fill`（放最后，GCM 可能弹 UI 卡死）；本机 WinINET 代理常年失效，脚本已置 `DefaultWebProxy=$null`。
- 版本 tag：`v1.0.0` ~ `v1.2.12`（后续版本递增）。插件更新不单独发 release。
  **发布回验记录**（`tests\publish-release.ps1` 之后必做：下线上 zip 比对 + body 逐字符 + tag 指向本地 HEAD）：
  v1.2.12（release id 388497981，含 bat/ps1/python 三个资产；第四十四～五十五轮，19 个提交）= body 2385 字、
  **0 个 `?`**、含中文；三个 zip 的 SHA256 全部与 `.release-stage-v1212\` 相同（bat `4F9C04D1…`、ps1 `7DD902A8…`、
  python `72C96996…`）；线上 python zip **与 stage 逐字节一致**且内层 `wgime-py.py` 853398 B / `E2B88F4A…`
  与本地 dist 一致（含 `dicts/`）；tag = 本地 HEAD `e1934bb`。
  v1.2.11（第四十轮，release id 386885107，含 bat/ps1/python 三个资产）= body 与本地逐字符一致（1478 字、
  0 个 `?`）、三个 zip 的 SHA256 全部与 `.release-stage-v1211\` 相同、`wgime-v1.2.11-python.zip` 内层
  `wgime-py.py` 744413 B / `6D6A6505…` 与本地 dist 一致、target = 本地 HEAD。
  （线上资产下载偶尔 `Unable to connect`，重试即可，别当成发布失败。）

## 8. 当前状态速览

> **细节在 `AGENTS-DETAIL.md`**：正文只留"要照着做的规则"，实测数字/探针清单/历史轮次来龙去脉
> 都搬到了 `AGENTS-DETAIL.md`（需要时 read 它，别凭记忆猜）。AGENTS.md 有 64KB 的注入预算上限。

- 已完成一次全面体检并修复高危+中危问题（2026-08-29，main/engine/win/tools/hook/plugins/ui 七模块），详见 CHANGELOG。
- 托盘菜单（ime 模式）：开关 / 模式{混合,拼音,五笔,词典,语音} / 选项{**语音输入**, 繁体输出, 译文, 反查编码, 整句输入,
  联想, 全角标点, 空闲隐藏, 跟随光标, 主题} / 词库{造词, 批量造词, 用户词表, 导入码表} / 这个程序{剪贴板上屏, 标点吞字修复}；
  tray 模式另加 工具箱/内置工具/插件管理/config 应用/运行模式/退出。**勾选态要齐**（每个开关都要有 `get_*`，
  只加 `toggle_*` 会让勾选永远不动）；删除确认要 `default=NO`；造词要校验 2-8 汉字。
- 各插件/模块的审计结论与"别回退"清单（clock/calc/wgtranslate/qr/wspy+chat/bar 粘附/码表导入）见 §D3。
- 纯 Python 版概览：功能与 C# 对齐（含四模式 + 语音）；单文件 `dist\wgime-py.py` 内嵌第三方 zip、**不内嵌插件**；
  数据目录 `%LOCALAPPDATA%\wgime-py`（Store Python 自动切 `USERPROFILE\wgime-py`）。详见 README 与 `docs\WGIME_*.md`。
- 待用户验证：chat 与 PC/Android 真机互通、词库加载速度（缓存命中）、语音中文识别效果（需装 zh-CN 语音包）。
