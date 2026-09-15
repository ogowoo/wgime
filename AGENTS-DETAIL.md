# AGENTS 细节附录（AGENTS.md 的配套文件）

`AGENTS.md`（常驻上下文）只放**要照着做的规则**，受 65536 字节 workspace instruction 预算限制；
这里放**完整细节**：实测数字、探针清单、历史轮次的来龙去脉、被精简掉的解释。
**接手任务时先读 `AGENTS.md`；要动它指向的某块时，再来这里查对应章节。**

- 对应 §5「关键约束」各条的完整解释：见本文 §D1（如有）。
- 原 §6「加载与性能」全文：见 §D2。
- 原 §8「当前状态速览」全文：见 §D3。

---

## §D2 加载与性能（原 AGENTS.md §6 全文）

## 6. 加载与性能（已做的优化，改动时别回退）

- **缓存命中跳过 trailer 解压**：`WgImeLauncher.ComputeTrailerHash`（压缩字节 md5，不解压）→ `BuildDicts` 用它查 `.mb` 缓存；miss 才 `ExtractDictsFull` 解压（经 `TrailerExtractor` 委托）。
- **WGB4 缓存格式**：批量块读取 + 并行 ToMap + `CompressionLevel.Fastest`。
- **词频保存后台化**：`SaveFreq` 走线程池（`freqSaving` 防堆积），退出时 `SaveFreqSync` 同步落盘。内存上限：FreqM/LastPickM 各 3 万、Freq 9 万、Assoc key 2 万。
- **启动计时日志**：`startup: LoadFreq+BuildDicts=XXXms ApplySwap=YYYms`。
- **固化码表预生成缓存**：`BakeTables` 固化后（无论是否勾选"删除源文件"）`PrebuildCacheAfterBake` 用 bake 后的输入重算 md5 并复用内存字典直接写 `wgime.mb`，下次启动命中缓存，跳过 ~10-24s 冷重建。md5 的 overlay 文件字节用 `SafeRead` 读实际状态；它对新码表 `TrimEnd` 末尾换行，与 `Get-DictSeg` 读数据块时的 `TrimEnd` 字节级一致，否则 md5 对不上。保留源文件时下次启动的 overlay 是幂等的（`AddDictLine` 覆盖 + `MergeUserWords` 只追加），冷启动结果等于内存字典。
- **启动顺序（第三十八～四十轮，别改回去）**：用户报的"启动后按 Shift 打字要 1-3 秒才上屏"其实是**两段时间**：
  ① 按键**进不进输入法**（钩子什么时候装上）；② 键进了队列之后**什么时候真正上屏**（`root.mainloop()` 里
  `poll()` 什么时候开始跑）。三轮分别压了这两段，现在的顺序：
  `单实例检查` → **`load_config`(1ms) + `hook.configure` + `hook.start()` + `hook.set_active(starton)`**
  → **`Engine()` 后台线程**（只读文件/建表，不碰 Tk）+ 跟随 helper spawn 线程 → `import tkinter/tools/plugins/bar`
  （dist 里这几个模块是**懒装载**） → `root = tk.Tk()` + 加载窗 → `join` 词库线程 → 配置/候选条 →
  `root.after(8, poll)` → **`root.after(30/150/600, 插件·托盘·tools 三段收尾)`** → `mainloop`。
  要点：**Tk/加载窗与读词库并行**（加载窗仍然盖住建表的 1 秒）、**收尾三段必须在 poll 之后**（它们合计
  ~500ms，排在 poll 前面就是白等）、**`_splash.destroy()` 改 `withdraw()` + 主循环里再 destroy**（destroy 要 90ms）。
  语义不变：**未激活时按键照常透传**；已激活时按键进 `hook.EVENTS` 队列，等 `poll()` 起来后按顺序处理
  （前几秒敲的字不丢、也不漏成半截拼音）。尾巴上的 `hook.start()` 是幂等的，只有真失败才弹气泡。
  **A/B 实测**（同数据目录+同码表, 从进程启动算）：钩子 **+2650 → +1397 → +824/+985 → +498/+416ms**（三十八~四十轮）；
  主循环 **+2694/+2590 → +1954/+1877ms**。探针 `%TEMP%\wg-r40-timeline.py` / `wg-r40-ab.py` / `wg-r40-selftest.py`（35 项）。
- **dist 单文件的内嵌模块是"懒装载"的（第四十轮，别改回全量 eager）**：`build-wgime-pure.py` 只 eager exec
  **`win`/`hook`/`engine`**，`bar`/`wspy`/`plugins`/`ui`/`tools`/`tray` 用 PEP 562 模块级 `__getattr__`
  在**首次属性访问**时才 exec（`_EAGER`/`_PENDING`/`_load_into`，`threading.RLock` 可重入）。原来 9 个模块
  一律启动即 exec 共 **~490ms**，其中 **367ms 是钩子用不到的 UI/插件/托盘模块**（还连带 `import tkinter`/PIL/pystray）
  —— 全部白排在"按键进输入法"前面。**注意 `import tools` 这种裸 import 不会触发装载**（只拿到 stub），
  属性访问才会；`_deferred_tools()` 就是靠 `tools.set_notifier(_notify)` 这第一个属性访问触发 tools 装载的。
  改动时保持"钩子之前只依赖 win/hook/engine"这条线。
- **跑真实 dist 的探针要注意 `APP_DIR`**（第三十九轮踩到）：`APP_DIR` 是**由 `DICT_DIR` 推出来的**
  （`APP_DIR = dirname(DICT_DIR)` 当 `DICT_DIR` 以 `dicts` 结尾，否则 `DICT_DIR`），所以
  `WGIME_DICT_DIR=<...>\package\dicts` 时读的是 **`package\config.txt`**，放在临时目录里的
  `config.txt (mode=tray)` **完全不生效** —— 想"托盘模式以免抢键盘"就必须把码表复制到 `<stage>\dicts`
  并把 `WGIME_DICT_DIR` 指过去；否则探针会真的装键盘钩子（此时只有 `starton=0` 才无害，因为未激活会透传）。
- **python 版启动实测（第四十轮复测，真实单文件 dist，`starton=0` → 按键透传）**：warm 全程
  **+498/+416ms** 钩子装好 → `poll` 起来 **+1954/+1877ms**（HEAD 是 2694/2590ms）；引擎读完 +1546ms
  （load_ms ≈ 0.9-1.1s，与 Tk/加载窗并行）；冷启动（重建索引）**14s 级**（不变）。剩下的固定开销：
  解释器启动 + 解析 727KB 单文件 **~300ms**、第三方 zip base64/md5 ~18ms、三个必装模块 ~93ms、主循环前收尾 0ms。
- **"启动头几秒打字卡/打不出字"的三个根因（第三十四/三十五轮，别再种回去；细节见 CHANGELOG 那两轮）**：
  ① **反查表(rev_wb)绝不同步建**：`showcode=1` 是出厂默认，原来首次调用同步 `build_rev_wb`（30.2 万码 / 143.8 万
  词条）→ **首键卡 1326ms**。现在 `rev_wb_code()` 只查 `_rev_wb`，没建好就 `warm_rev_wb()` 起后台线程返回 None；
  `_invalidate_rev_wb()`（`_rev_gen` 代数）在码表变动时作废在飞结果。**别把预热搬回 `apply_config()`**（那 1.2s
  抢 GIL 会把 `hook.start()` 从 +2.29s 推到 +3.70s）——预热只在钩子装好后（`engine.warm_ec()`）与用户打开
  「反查编码」时做。② **缓存分两段读**（`CACHE_VER=5`）：第一段=核心表 `(py,pk,pv,wb,wk,wv,char_py,acro)` +
  派生表 `(char_wb,wb_by_len,word_freq,word_freq_total)`（47MB），第二段=只给词典模式(3)的 `(ec,ek,ev,ce)`（46MB，
  `ensure_ec()` 用 `_YieldingReader` 后台读，加载期间每键 1–40ms）。**四个部件必须打成一个 pickle 段**（拆开丢
  字符串去重，90.6→121.9MB）；`candidates()` 的 mode 3 在 `_ec_ready` 为假时**必须返回三元组 `cands,False,False`**
  （曾写成 `return []` → `main.refresh` 抛 ValueError）并顺手 `ensure_ec()`；两段都失败才 `_ec_fail` 打住。
  ③ **三张"每次重算"的派生表必须留在缓存第一段**：`char_wb`/`wb_by_len`/`word_freq`（原来在 `_init_state()` 里
  每次重算 ≈0.92s；现在 `_build_core_extra()` 算一次随缓存写出，`_core_extra_ready` 只是兜底）。**`pywfreq.txt`
  必须在 `CACHE_FILES` 里**（否则改语料缓存不失效）；**`wb_by_len` 桶内顺序必须原样保留**（= C# `OrderBy`，§11）。
  合计热启动 Engine() 1401→**998ms**、装钩子 3.70→**1.98s**；缓存 93.1MB。探针 `%TEMP%\wgime-warmec-probe.py`（40 项）。
- **加载提示窗每次都显示**：`_splash` 无条件建，第二行按 `_dict_cache_stale()` 区分"要建索引 / 正在读缓存"（热启动也有反馈）。
- **缓存内容别"精简"**：`pk/pv/wk/wv`、`ce`（build_reverse 3.3s）、`acro`（2.0s）都留在缓存里（实测去掉改成启动重建净亏 308ms；zlib 压缩净亏 +652ms）。
- **冷启动反馈窗**：320x72 无边框置顶小窗（对齐 C# 候选条的"(词库加载中...)"）在 `Engine()` 之前建，故 `root = tk.Tk()` 已提到建表前；**全文件只创建一次 Tk root**（`bar = CandBar(root)` 复用），别再在启动后段新建。
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



---

## §D3 当前状态速览（原 AGENTS.md §8 全文）

## 8. 当前状态速览

- **已完成一次全面体检并修复高危+中危问题**（2026-08-29，main/engine/win/tools/hook/plugins/ui 七模块）：详见 CHANGELOG。核心：词频保存线程竞争（RLock）、剪贴板改 ctypes 原生、`send_unicode` 按 UTF-16 码元注入、hook 的 Shift 轻拍/F8/数字键/注入键/异常保护。
- 最近工作：码表数据块化（`###WGIME_DATA###`）、固化码表 + 预生成 `.mb` 缓存、词库加载优化（缓存命中跳解压）、启动顺序优化（第三十八～四十轮，见 §6）、**chat 插件重写（2026-08-25：relay 裸 JSON + 真 MQTT 双模式、auto 兜底、Active Rooms、6s×3 重连，修复与 PC/Android 双向不互通的致命缺陷；新增 `tests\chat-protocol-smoke.ps1` 联网协议验证）**、clock 多提醒、文档同步、**纯 Python 版托盘菜单分组 + 中英双语（按 `GetUserDefaultUILanguage` 判定，与 C# 版 `CultureInfo` 一致）**。
- 纯 Python 版托盘菜单：分组(ime 模式)=开关/模式/选项{繁体输出, 反查编码, 整句输入, 联想, 全角标点(Ctrl+.), 空闲隐藏, 跟随光标, 主题}/词库{造词, 批量造词…, 用户词表…, 导入码表…}/这个程序{剪贴板上屏, 标点吞字修复}; tray 模式才显示 工具箱/内置工具/插件管理/config 应用/**运行模式{输入法(IME), 托盘工具箱(Tray)}**/退出；标签经 `tray.L(zh,en)` 双语化，造词走 `api['makeword']` → `makeword_clipboard()`；**托盘勾选态要齐**（第十六轮审计）：C# `RefreshMenuChecks` 给 8 类项打勾 —— `开关`(`is_active`)、4 个模式(`get_mode`)、`反查编码`、`繁体输出`(`get_trad`)、`候选窗跟随光标`、`空闲隐藏`、`改用剪贴板上屏`(`get_apppaste` = `APPMODES.get(前台,0)==1`)、`标点吞字修复`(`get_appkeyfix` = `effective_keyfix()`)；这些 `get_*` 都由 `main.py` 的托盘 `api` 注册（pystray 在**菜单打开时**求值 `checked` 回调，所以是活状态）；改托盘菜单时别把这几项的 `checked=` 删掉，也别新增只用 `toggle_*` 而没有 `get_*` 的开关项。批量造词 `show_batch_makeword`（选词表文件→2-8 汉字去重→确认→`engine.add_user_words_batch`）/用户词表 `show_user_words`（多选删除→落盘 `userwords.txt`→后台 `engine.reload()` 重建，对齐 C# BuildDicts+ApplySwap）。**造词对话框必须带汉字校验**（第十九轮）：`show_makeword` 的 `do_make` 是 `not (2 <= len(w) <= 8) or not engmod.is_all_cjk(w)` → 提示「词语需 2-8 个汉字」（对齐 C# `MakeWordFromClipboard` 的 `IsAllCJK`）—— 否则"手填编码"这条 python 额外路径能把纯英文/混排词写进用户词库。批量造词的行规则（trim、空行不计、2-8 汉字否则计 skipped、重复计 skipped）与 C# `CollectWordLines` 逐条一致，别改。**内置工具 1:1 对齐 C#**：工具箱/网络工具/便签/剪贴板/取色器/插件管理/造词/批量造词/用户词表/导入码表均已复刻（`tools.py`，对照表见 `wgime-py-pure\README.md`）；**网络工具纯计算部分**（第二十六轮）与**剪贴板历史三条判定**（第二十二轮：只在窗口开着时收集 / 纯空白不记 / selfSet 跳过）都已逐项对齐，都别改（细节见 CHANGELOG）。C# 的「固化码表(BakeDialog)」在 python 无对应物（`py/wb/ec.txt` + `import_*.txt` 即源，导入即固化）。tools.txt 的 `code = xxx` 与 C# 一致注册为启动器候选（`main.find_launcher` → `tools.run_tool_code`，结果走托盘气泡；冲突优先级 插件 > tools code= > config app= > 内置别名）。**`config.txt app=` 的启动要走 ShellExecute**（第二十五轮）：C# `LaunchApp` 对"不含 `://`、含 `\`/`/`、非绝对路径"的目标先 `Path.Combine(BatDir, target)`（**相对路径按程序目录**解析，不是进程 CWD），再用 `UseShellExecute=true` + `Arguments` 启动；python 对应 `main.run_launcher` 的 `app` 分支里做同样的 join，并调 `win.shell_execute()`（ctypes `ShellExecuteW 'open'`）——**不要**改回 `subprocess.Popen(..., shell=True)`（会过 `cmd.exe`，参数里的 `&`/`^`/`%` 被解释）。**运行模式**：`config.txt mode=ime|tray`（ime=输入法默认；tray=纯托盘工具无键盘 hook/候选窗，对齐 C# 版合并 wgtray 方案），托盘「运行模式」切换 → 写 config + 自动重启进程；`main.is_tray_mode()`/`switch_mode()`/`tray._tool_icon_img()` 实现。全/半角标点：`hook.py` 吞 `, . ; ' / \ [ ] Shift+4` → `main.map_punct`（对齐 C# MapPunct 含引号开闭交替），组字中先上屏首候选再标点（C# Hook_OnPunct 对齐），`;` 在微软双拼组字中仍是韵母 ing 键、`[`/`]` 有候选时仍以词定字；`cnpunct=0` 时标点键透传半角，`config.txt cnpunct` 持久化。
- 纯 Python 版(`wgime-py-pure/`)概览：功能与 C# 版对齐(四模式/词频/简拼/双拼/造词/码表导入固化/启动器/工具箱/插件/候选窗/托盘/反查/简繁/整句/联想/空闲隐藏)；单文件 `dist\wgime-py.py`(内嵌模块+pystray/uiautomation/comtypes zip，**不内嵌插件**)；数据目录 `%LOCALAPPDATA%\wgime-py`(Store Python 自动切 `USERPROFILE\wgime-py`)；词频机制已升级(语料+学习+近期热度、`learnk`/`recentk` 可配)；UI 用 `ui.py` 设计系统。详见 README「纯 Python 版」章节与 `docs\WGIME_*`.md 对应小节、`wgime-py-pure\README.md`。
- 纯 Python 插件（`wgime-py-pure\plugins\*.py`）：契约=模块级 `CODE/NAME/DESC/VERSION/AUTHOR/PERM` + `run()`，窗口用 `ui.py` 设计系统（`make_window/flat_button/rounded_entry/console_text`），不建 `tk.Tk()`、不调 mainloop，定时用 `win.after`，后台线程经 queue+`root.after` 派发。已从 C# 1:1 移植：`calc.py`(计算器 jsq，calc 为别名)、`chat.py`(聊天 lt)、`clock.py`(悬浮时钟 sz)、`wgime-qr.py`(二维码 qrcode，见下面单独一条)；**`wgtranslate.py`(剪贴板翻译 fy) 不是 1:1 移植，是另一份重写（v2.2.0）** —— 差异见下面单独一条。插件**不内嵌**：`build-package.ps1` 把本目录 `plugins\*.py` 全量拷进 `package\plugins\`、把仓库根 `plugins\*.txt` 只挑**步骤 DSL 类**(clean-bin/qping/README)拷入——含完整 `[csharp]` 插件块的 txt(calc/chat/clock/wgtranslate 的 C# 源)被同 CODE 的 `.py` 取代，不再进 python 分发(避免生产 csc 编译路径)；生产环境从外部插件目录加载（`load_py_plugins` 扫 APP_DIR/plugins，`.py` 优先于同 CODE 的 `.txt` 步骤插件）。仓库根 `plugins\` 保留 C# 版插件源(txt)，Python 版源在本目录 `plugins\*.py`。python 版 `_run_csharp_plugin`/`run-csharp-plugin.ps1` 的 [csharp] 运行能力仍保留作兼容回退(如用户自放 C# txt)，但内置分发不再带 C# 插件。**托盘「插件」子菜单**（`tray._plugins_menu`）列出 plugins 目录全部插件(.py/.txt)点击即运行，尾部接「插件管理…」；**插件管理器复刻 C# 版**(`tools.show_plugin_mgr` 重写): 列表(名称/编码/类型/启停/**状态**/文件)+按钮(重载/启停/打开目录/编辑/删除/新建模板/运行)+双击运行。**第十八轮补齐的几点别回退**：① 状态列由 `plugins.count_steps(body)`（与 `run_steps` 同规则：块算 1 步、闭标签缺失整块丢弃）算出，`main._list_plugin_files` 负责带 `status`（`正常 (N 步)`/`解析失败`/`未加载`/`—`）；② 禁用的行要 `lst.itemconfig(..., foreground=ui.SUB)` 灰显（对齐 C# `ForeColor = Gray`）；③ **删除确认必须 `default=messagebox.NO`**（C# 是 `MessageBoxDefaultButton.Button2`，缺省"是"会一记回车删掉插件文件），标题 `WgIme`；④ 双击 = 运行是 python 的有意选择（C# 是编辑），已记在此处。
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
- **二维码插件（`wgime-qr.py`，第三十七轮审计）**: 编码范围 = **QR Model 2 / v1..v10 / 纠错 M / 字节模式 +
  ECI 26 (UTF-8)**，超长抛 ValueError（真实上限 **212 个 UTF-8 字节**：v10/M 有 216 个数据码字 = 1728 位，
  减 ECI 12 + 模式 4 + 计数 16 = 32 位 → 1696/8；文案里曾写"约 213"，第三十七轮改成 212）。
  **验证方式不是"看着像"**：`%TEMP%\wg-qr-probe.py`（**78 项 0 失败**）自带一个**独立解码器** ——
  不复用插件的任何表/GF 代码，独立实现 ISO/IEC 18004 M 级块结构表、对齐图形位置表、功能图形分布图、
  格式/版本信息 BCH、Z 字形码字读取、反交织与 **Reed-Solomon 校验子**（GF(256)/0x11D）；
  12 组输入（ASCII/URL/数字/各版本容量边界/中文/日文+emoji/变音符）全部 **校验子全 0 + payload 逐字节回读相同**，
  格式信息/版本信息与独立 BCH 一致，mask = 独立罚分函数的 argmin，容量边界（13/14/25/26/41/42/61/62/83/84/
  105/106/121/122/151/152/**179/180**/212）选到最小可用版本，剩余位 v2..v6=7、其余 0。
  PNG 写出（手工 zlib/struct）是 **RGB8（色彩类型 2）**、每行 filter 0、全部块 CRC 正确、BGRX→RGB 顺序正确。
  **改这个插件的编码器/渲染后必须重跑该探针**（它不联网、不碰用户数据）。仓库里没有 C# 版 qr 插件源，
  所以这条不是 C#↔python 对照，而是对规范/参考算法做独立验证；C# 侧那份 `wgime-qr-clean-border-style-v2.5`
  不在本仓库。
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
- **"启动头几秒打不出字"（第三十四/三十五轮）与"按 Shift 打字 1-3 秒才上屏"（第三十八～四十轮）都已修**：
  前者三个根因（首键同步建反查表 1326ms、整份 90.6MB 缓存同步 pickle.load、`_init_state` 每次重算派生表
  ≈0.92s）见 §6 的"三个根因"那条；后者是**钩子装得太晚 + 收尾挡在 poll 前面**，三轮分别把钩子提到
  **Tk/加载窗/重 import/读词库之前**（钩子可用 +2650ms → +498/+416ms）、把读词库放后台线程与 UI 并行、
  把插件/托盘/tools 收尾挪进主循环（`poll` 起来 +2694ms → **+1954/+1877ms**）。**别把这几处改回同步/串行**，
  细节与"别再改回去"清单都在 §6。验证：`%TEMP%\wgime-warmec-probe.py`（40 项）、缓存生命周期（14 项）、
  `%TEMP%\wg-r40-selftest.py`（35 项）、harness 18/18。
- chat 插件要点：relay=`chat.seee.uno` 走裸 JSON 文本帧，其余 broker 走 MQTT over WS（`/mqtt` 路径 + **必须 `mqtt` 子协议**，否则 EMQX 400/Mosquitto 断连）；TLS 需 1.2+。详见 `docs\WGIME_CHAT_技术文档.md` §8。
- 待用户验证：chat 插件与 PC/Android 真机互通（协议层已实机验证）、词库加载速度（缓存命中路径）、固化码表后启动速度（应已降到缓存命中级别）。

## §D4 `lastpick_*.txt` 的 `\r` 累积（第五十轮）

- **现场**：用户指着 `%LOCALAPPDATA%\wgime-py\lastpick_mix.txt` 说"有点诡异"。实测该文件 1375 B / 68 条，
  每个词后面挂着一串**裸 CR**：`bm 出\r\r\r\r\r\r\r\r\r\r\r\r`（最老的 12 个）；`Get-Content` 按
  `StreamReader.ReadLine` 切（`\r`、`\n`、`\r\n` 都算行尾）会得到 730 行，其中 662 行是空行。
  统计：`CR=730 LF=68 CRLF=68 bareCR=662`。C# 侧 `%LOCALAPPDATA%\wgime\lastpick_mix.txt` 干净：
  3302 B / 293 条 / `CR=LF=CRLF=293 bareCR=0`（C# `File.WriteAllLines` 写 CRLF，值里不带 `\r`）。
- **根因**：`engine._load_freq` 的 `for line in read_text(p).split('\n')` + `line[sp+1:].rstrip('\n')`。
  `read_text` 是**二进制读 + 解码**（`open(path,'rb')` + `utf-8-sig → gbk → utf-8+replace`），
  **没有 universal newlines**，所以 CRLF 的 `\r` 留在行尾、被当成词的一部分；写盘 `open(...,'w')` 又把
  `\n` 翻成 `\r\n` → **每轮 载入/存盘 净增一个 `\r`**。探针实测一轮往返 17 → 19 字节、值 `'出\r'` → `'出\r\r'`；
  这也解释了 CR 个数为什么是 12/11/8/7/6/5/4/3 递减（不同时间加入的词经历的存盘轮数不同）。
- **为什么是真 bug（不只是文件难看）**：`candidates()` 的 LastPick 置顶是
  `lp = self.lastpick_m[mode].get(keys)` → `if lp and lp in cands: cands.remove(lp); cands.insert(0, lp)`，
  **字符串比较**；值带 `\r` 永不相等 → "上次选的词置顶"（§14 机制）**静默失效**。
  探针 C 组：脏值 `['办','出']`（没置顶）vs 干净值 `['出','办']`（置顶生效）。
  另外破坏 §28 说的"C#/python lastpick 同格式可互换"。
- **修法**：`_load_freq` 两个解析点各加一行 `line = line.rstrip('\r')`（userdict 那处原来写的是**无效的**
  `line.rstrip('\n')`——行已按 `\n` 切过——一并纠正）。写盘保持 CRLF（对齐 C# `File.WriteAllLines`），
  值干净后自愈；**用户已有的脏文件不用手删**：载入时值即干净（`'出\r\r\r'` → `'出'`），
  下次存盘整份重写成 `bm 出\r\n`。
- **探针**：`%TEMP%\wg-r50-lastpick-probe.py`（A 载入 CRLF 键值都干净 / B 一轮往返 15→15 且行尾仍 CRLF /
  C 脏值置顶失效 vs 干净值置顶生效 / D userdict int 对照组 / E 12 个 CR 的脏文件载入干净 + 存盘痊愈）。
  修前 **5 通过 / 4 失败**（A1/B1/B2/B3），修后 **11/11**。
- **永久回归**：`tests\pure-state-harness.py` 从 16 项加到 **18 项**（新增两条在"退格"之后）：
  ① 往隔离数据目录写一份 CRLF（且尾部故意带 3 个裸 `\r`）的 `lastpick_mix.txt`，`eng._load_freq()` 后
  `lastpick_m[0].get(k1)` 必须等于纯词；② 取该编码候选的**第二个**词当"上次选的词"，置顶必须真的把它
  换到第一位（故意不用首候选，否则置顶失效也看不出来）。写文件的键/词对取自 `eng.char_py`，
  数据目录在临时目录内（harness 自带隔离断言）。
- **顺手扫过的同类读取点**（都没问题，别改回没 `strip()` 的写法）：`engine.load_config`（`raw.strip()`）、
  `_load_assoc`（`line[tab+1:].strip()`）、`load_user_words`（`raw.strip()`）、`load_en_rank`（`.strip()`）、
  `convert_file`/`_add_dict_line`（`.strip()`）、`parse_dict`（快路径 text 模式自动处理 CRLF；慢路径显式
  `replace('\r\n','\n').replace('\r','\n')`）、`plugins.py:163`（`raw.rstrip('\r\n')`）、
  `main` 的 pastemode/plugins-disabled、`tools.py` 的造词/插件禁用名单、`clock.py` 的 `cfg` 读取。

## §D5 第五十一轮全量审计台账（7 路并行审计 + 已修/未修清单）

**做法**：`wgime-py-pure` 的 10 个模块 + 5 个插件分 7 份，各起一个只读审计 subagent（要求：精确 `文件:行号` +
可复跑证据 + 区分"有意设计/真 bug"，禁止改仓库文件、禁止启动真输入法、禁止碰 `%LOCALAPPDATA%\wgime-py`），
我同时跑横切检查：`%TEMP%\wg-r51-ast-probe.py`（重复定义 / dict 重复键 / if-else 同体 / 不可达代码 / 空 try /
宽异常静默点清单：**A~E 结构性 0 条，F 列出 127 处 `except Exception: pass` 供人工分诊**）、
`%TEMP%\wg-r51-invariants-probe.py`（30 项跨模块不变量）。**共 56 条候选，本轮修掉 20 项。**

**已修（20）**：`_merge_user_words` 五笔+简拼（engine）｜`clock.cfg` 读失败覆盖整份闹钟（clock，高危）｜
缓存签名加 `userwords.txt`（engine）｜`_write_config` 走 `read_text` + 行尾跟原文件（main）｜`pywfreq.txt`
宽松读（engine）｜`unlearn` 只回滚自己写的 lastpick（engine）｜剪贴板历史 list 当函数传（tools）｜剪贴板窗口
单例（tools）｜perm 多值绕过确认（plugins）｜Caret Helper stdin 非阻塞写（win，最严重：主线程会永久冻死）｜
`_destroy_splash` NameError（main）｜`_run_csharp_plugin` 宽松读 + `_bg_plugin` 兜底（main）｜rev_wb 并发构建
+ 缓存 tmp 清理（engine）｜`win.dfn_always` + 换图失败 always-on（win/tray）｜托盘 `_on` try/finally（tray）｜
托盘切语音模式要开语音（main，第四十九轮漏的入口）｜语音待确认 COMPOSING（main）｜vf 里 `[`/`]` 发 【/】（main）｜
以词定字学整词 + dyn 门控 + 联想（main）｜标点路径补 `learn_assoc`/`last_commit`（main）｜托盘图标 `% 4`→`% len`
（tray）｜候选条截断下限 8→4 字（bar）｜非跟随钳制取所在屏工作区（bar）｜主题切换重绘 + `ui.font` 缓存（main/ui）｜
`[csharp]`/`[python]` 标签锚定整行（plugins）｜闭标签大小写（plugins）｜`load_tools` 块状态机（plugins）｜
动词按任意空白切分（plugins）｜`kill` 看返回码（plugins）｜`reg-del` 缺键视为成功（plugins）｜DNS 自指指针死循环
（tools）｜造词手填编码校验（tools）｜子网地址类型用输入地址（tools）｜时钟 nan/inf（clock）｜`poll` 里
`import tray` 抢跑（main）｜被停用 .py 插件先判断再 exec（main）｜3 处死代码（main/engine）。

**未修（已测量/已定位，留待后续）**：

> **第五十二轮更新：下面这批已按用户要求全部修完**（明细见 CHANGELOG 第五十二轮）。各项探针：
> `%TEMP%\wg-r52-tools-probe.py`（11/11，含真 Tk 窗口驱动的用户词表删除用例）、
> `wg-r52-chat-probe.py`（13/13；同一探针跑 HEAD 版 chat.py 有 11 项 FAIL，A/B 成立）、
> `wg-r52-hookwin-probe.py`（24/24）、`wg-r52-dprobe.py`（17/17）、`wg-r52-voice-probe.py`（7/7，真麦克风）。
> 两条产品决策按用户的话办：**`hideidle=0` 让拖动生效**（`show_page` 改传 `fixed=None`，交给 bar 的"保持当前位置、
> 越界才钳"分支；首次仍用 pos.txt/底部居中）、**hook 两处差异保持现状**（已写入 `AGENTS.md` §27 反向差异清单，
> 避免下轮又被当 bug "对齐"）。**语音真机**：麦克风隐私改成 Allow 后实测 `waveInOpen` 成功、真录 2s
> （58452 B/1.83s/16k 单声道）、System.Speech 后端无异常；本机是英文 Windows Server（无 zh-CN 语音包）所以识别为空，
> 中文识别质量仍需在中文机验收。

- **tools**：① 用户词表"第二次删除删错词"（`items` 快照与已删短的 Listbox 下标错位；真跑复现：删 cc 后再删
  dd 实际又删 cc，dd 仍在文件里且永远删不掉）；② 取色器 / 插件管理器**没有单例**（开两个后关任一个，另一个
  半死，与剪贴板同类）；③ 中文 Windows 下 Ping RTT 恒 0ms、Tracert 每跳 timeout（解析 `时间=13ms`/`TTL 传输中过期`
  的中文回显；本机是英文 locale，只做了打桩验证）；④ 工具箱防重入粒度过粗（整窗一个 `running[0]`）。
- **chat**：⑤ 重连 6s 等待期内"离开→加入"产生两个并发会话（实测并发峰值 2，需加会话代次）；⑥ relay 空闲房间
  约 60s 被判死重连（PONG 被 wspy 消费不上抛，`idle` 单调涨）；⑦ `send()` 不看连接状态（未连接也会清空输入框 +
  本地回显）；⑧ `state['joined']` 跨会话不复位（重连不等 CONNACK 就算"已连接"，但没发 SUBSCRIBE/join）；
  ⑨ 离开不发 leave（对端"在线 N"永不减少）；⑩ 连接期间不禁用 昵称/房间/密钥（send 用实时控件、会话用快照，
  房间框清空后密钥不一致 → 对端全是 `[encrypted]`）；⑪ `chat.py` 缺 `PERM='network'`/VERSION（运行不弹联网确认）。
- **hook/win/voice**：⑫ 语音热键的 **keyup 无条件吞**（`VOICE_ON` 为真时普通 V / Ctrl+V 的松键也被吞 →
  应用侧 V 卡住；要记住"这次按下是否真命中热键"）；⑬ `_focus_edit_rect` 用 `GetFocus()`（线程本地，永远拿的是
  自己窗口）→ 改用 GUITI 的 `hwndFocus`；⑭ `voice._cmd_recognize` 按 utf-8 解子进程输出（控制台是 OEM 代码页
  → 中文变 `????` 且当成功上屏）；⑮ `hook.last_error()` 恒 0（`ctypes.windll` 不维护私有 last-error，要
  `WinDLL(use_last_error=True)`）；⑯ `clipboard_set` 无失败信号（`OpenClipboard`/`SetClipboardData` 失败时
  `paste_text` 仍按 Ctrl+V → 粘出上一份内容；`GlobalLock` 失败还漏 HGLOBAL）；⑰ `win.py` 的 `_sys` 在 import 前使用
  （潜伏 NameError）、`_uia_disabled`/`_ipc_started` 死状态、`_ipc_req_hwnd` 无界增长。
- **clock/qr/calc**：⑱ 主时钟窗关掉后闹钟管理窗每次操作抛 TclError（`changed()` 没 try）；⑲ 二维码窗固定 884px
  高（1366×768 屏上底部按钮在屏幕外）；⑳ 二维码「复制图片」的 32bpp CF_DIB 第 4 字节全 0（按 alpha 混合的应用
  会当全透明）；㉑ `calc._to_long` 判 Err，而 C# 的 `(long)` 是 unchecked（给 long.MinValue）——**python 的 Err
  更合理，建议只在 docstring 写明是有意差异**。
- **需要产品决策**：㉒ `hideidle=0` 常驻时每次 `show(fixed='bottom-right')` 覆盖位置，`pos.txt` 记的拖动位置
  在这条路径上永远不生效（要么承认"常驻固定右下角"并停止写 pos.txt，要么改 `fixed=None` 让固定分支接管）；
  ㉓ hook 的 Shift 轻拍有"Ctrl/Alt/Win 按住不武装 + 0.4s 时限"（C# 两者都没有）、字母判定排在空格/翻页之后
  （C# 在前，`key_first=a` 时行为不同）——两条都更像 python 的有意保守化，建议写进 §27 而不是改代码。

---

## §D6 第六十三轮：`voice_engine = whisper`（常驻本地 faster-whisper）

### 为什么必须常驻（实测数字）

`voice_engine = cmd` + `stt_cmd = python -c "...faster_whisper..."` 这条路**准确率没问题、延迟不能用**。
同一批真实中文语音（`%TEMP%\wgcmd-*/*.wav`），逐项计时（`%TEMP%\wg-r63-timing.py`）：

| 环节 | 耗时 |
|---|---|
| 只启动解释器 | 58 ms |
| `import faster_whisper` | **6.5 s** |
| 载模型 `small`/`int8`（热文件缓存） | 2.2 s（冷缓存 ~9 s） |
| 真转写（17~33 字中文） | 2.2 ~ 4.6 s |
| **`cmd` 现状 = 每句一个新进程** | **21.4 / 22.1 s** |
| **常驻进程（模型只载一次）** | **3.0 / 4.6 s** |

冷/热对照探针：`%TEMP%\wg-r63-warm-probe.py`。结论：20 秒里 **16 秒是每句重付的导入+载模型**，
所以"常驻"不是优化项而是**能不能用**的分界线。准确率（同一批 WAV、`small`/int8、带简体提示词）：
"你好" 100%、17 字 100%、33 字 88%（`五笔→舞笔`、`语音→预音`，无繁体字）。

### 实现要点（照 §17 光标跟随 helper 的同一套）

- **源码走环境变量** `WGIME_WHISPER_SRC`（+ 选项 JSON `WGIME_WHISPER_OPTS`），命令行只留 ~230 字符引导；
  既不在磁盘上落 `.py`，也不把几 KB 源码塞进"进程创建命令行"。
- **JSONL over stdin/stdout**：请求 `{id,wav,lang,prompt,beam}` → 回包 `{id,ok,text,ms,segs}`，
  另有 `{ready:true,boot_ms,model}` 与 `{ready:false,error}`。
- **文本用 `json.dumps(ensure_ascii=True)` 回传**：子进程 stdout 的代码页在中文机是 936，
  直接写裸 UTF-8 汉字会变 `?`（system 后端当年走 base64 就是为了这个）。JSON 转义成 `\uXXXX` 最省事。
  实测 `%TEMP%\wg-r63-warm-engine-probe.py` C3：请求行里全是 ASCII。
- **父进程退出 → stdin EOF → 子进程 `for line in sys.stdin` 结束 → 自己退出**。`quit_app()` 用的是
  `os._exit(0)`（不跑 atexit、不 join 子进程），靠的就是这条 EOF 语义；`voice.shutdown()` 只是显式收一次
  （`quit_app` 里已调用）。**别改成"落盘脚本 + Popen([..., path])"**（§17 的老坑）。
- **两个锁**：`lock` 只管起/杀进程（`ensure()` 不等待 READY，实测 75~100 ms 返回 —— 预热要在 Tk 主线程调），
  `rlock` 只管一问一答（识别线程会持着它等 3~5 s，首句还要等十几秒的载模型）。合成一个锁 = 预热会把主线程
  卡在识别期间 = **打字停摆**。
- **预热两处**：① 启动后 4 s 起后台线程 `prewarm_bg()`（`stt_prewarm=0` 关；只在 `voice=1` 且
  `voice_engine=whisper` 时才 import voice.py）；② `voice_down()` 里 `warm()` 一次 —— 载模型与"用户正在说话"
  这段时间**重叠**。
- **子进程 stderr 收进 30 行环形缓冲**，出错时报最后 3 行（`stderr: …`），DEVNULL 会丢掉真原因。

### 同轮修掉的两个真 bug（都是顺序相关、偶发、极难查）

1. **录音文件名固定 `voice-last.wav` → 改成 `voice-<pid>-<序号>.wav`**：常驻助手是**过几秒**才去读这个
   wav 的，固定名会让"上一句还在识别、这一句又录完"把文件覆盖掉 → 上一句识别出**这一句**的内容（张冠李戴）。
   现在识别完各自删各自的（`VOICE_Q` 里带 wav 路径），顺带 best-effort 清掉旧版遗留的固定名文件。
2. **`ensure()` 里"换了参数(key 变了)"必须清 `last_err`**：实测先试坏的 `stt_python`（FileNotFoundError）、
   1 秒内再换 `stt_device=cuda` 试 —— 报出来的**还是** FileNotFoundError，用户会以为自己的修改没生效。
   现在 `key != key` 就清；真连续 3 次起不来时报"已停止重试(重启 WgIme 才重新试)"**并附上上次真实原因**
   （只说"连续起不来"等于没说）。

### 配置键与语义

`stt_model`（默认 `small`；决定助手是否重启）/ `stt_device`（`cpu`）/ `stt_compute`（`int8`）—— 这三个进
`key`，改了会重启助手；`stt_lang` / `stt_prompt` / `stt_beam` 是**每次请求**带的，改了不用重启（探针 C7/A11）；
`stt_python`（缺省=宿主解释器，另装了 faster-whisper 的解释器就指过去；进 `key`）；`stt_prewarm`（默认 1）。
1 秒内不重复 spawn（防"助手秒退时每次按键起一个 python"的启动风暴）；失败计数到 `WSRV_MAX_FAIL=3` 后本进程
不再重试。这几个键在 `engine.load_config` 里：字符串键进那个元组，`stt_prewarm` 走白名单布尔，
`stt_beam` 是 `max(1,min(10,int(v)))`。

### 回归与探针

- **永久回归** `wgime-py-pure/tests/whisper-warm-test.py`（**67 项**，毫秒级、不需要 faster-whisper/模型）：
  把 `voice.subprocess.Popen` 换成**照抄真管道语义**的假进程 —— 没数据时 `for line in proc.stdout` 会**阻塞**、
  进程死了写 stdin 会**抛 ValueError**、只有 `kill()`/`end()` 之后才 EOF；开头还有一组"桩自检"（0a~0d）
  证明桩真的像管道，否则后面全是空转。覆盖 A 起进程/预热不阻塞、B READY 与初始化失败、C 串包丢弃/中途崩溃/
  请求字段、D 超时、E 连续 3 次停手、F 陈旧错误、G 重启时旧读取线程的 EOF 不得落进新队列、H shutdown 与限流、
  I `prewarm_bg`、J 9 个引擎别名的分派表、J5 取值边界。
- **守卫有效性自检** `%TEMP%\wg-r63-guard-check.py`：把两处守卫**改回旧写法**各跑一遍 —— 去掉
  `last_err` 清除 → `I2` 失败；`_reader(p, q)` 改用 `self.q` → `H3`/`H4` 失败；基线 0 失败。
  （"一个不会失败的测试等于没写"。）
- **真进程端到端** `%TEMP%\wg-r63-warm-engine-probe.py`（24 项，真子进程 + 真模型）：
  冷 20.0 s（含 `boot_ms=2821` 的载模型）/ 热 **4.0 s**；并发两句 9.1 s 且各拿各的结果；
  `shutdown()` 后 `GetExitCodeProcess` 确认进程真没了；坏 `stt_python`/坏 `stt_device` 都报真原因；
  1 秒内换参数不报陈旧错误。
- 配置模板 `config.txt`（root + release）加了"本机离线识别"整段注释；`docs\WGIME_使用说明.md` 引擎表加了
  `whisper` 一行 + "本地 whisper 怎么配"。

---

## §D7 第六十轮：硅基流动两站的区别（实测记录）

**国内站 `cloud.siliconflow.cn` 与国际站 `siliconflow.com` 是两套账号/密钥，互不通用；而且国际站没有可用的
语音识别模型。** 实测（同一把国际站 key + 真实中文语音 WAV，走我们自己的 `voice.recognize`）：

| 请求 | 结果 |
|---|---|
| `api.siliconflow.com/v1/models` | **200**（key 有效）；79 个模型里音频类**只有合成**：`FunAudioLLM/CosyVoice2-0.5B`、`IndexTeam/IndexTTS-2`、`fishaudio/fish-speech-1.5` |
| `.com` + `FunAudioLLM/SenseVoiceSmall` | **403** `{"code":30003,"message":"Model disabled."}` |
| `.com` + `TeleAI/TeleSpeechASR` | **400** `{"code":20012,"message":"Model does not exist."}` |
| 同一把 key 打 `.cn` 的任意接口 | **401** `{"code":30014,"message":"Token is invalid."}` |

**这个 401 是"站点用错了"，不是 key 错** —— 排查先对站点，再怀疑 key。
`CosyVoice2` 是 **TTS（合成）**，不是识别，`/v1/audio/transcriptions` 用不了它。
要中文识别只有三条路：① 国内站 key + `SenseVoiceSmall`；② 本地离线（`voice_engine = whisper`，见 §D6）；
③ 换任何 OpenAI 兼容的识别服务（只改 `stt_url`/`stt_key`/`stt_model`）。
代理相关的坑（本机注册表里留着已关闭的 `127.0.0.1:10808` → 云端识别永远失败）见 AGENTS.md §38 第五十九轮。

## §D8 第六十四轮：本地离线识别（`voice_engine = cmd` + sherpa-onnx / SenseVoice-Small int8）

**装在哪（都在仓库外，`C:\Tools\wgime-local-asr\`，附 `README.md`）**

| 路径 | 说明 |
|---|---|
| `wgime-stt.py` | 识别入口 wrapper。**stdout 只打印识别文本**，其余一律 stderr（`_cmd_recognize` 取"第一行非空输出"）；出错时 stdout 空、stderr 一行原因、退出码非 0 |
| `wg-dl.py` | 带断点续传/重试的下载器（本机外网时通时断；**服务端不给 Content-Length 时读干净一轮就算完成**，否则下一轮 Range 换来 60 次 HTTP 416） |
| `models\sense-voice\model.int8.onnx` | SenseVoice-Small int8，**228 MB**（`239233841` B） |
| `models\sense-voice\tokens.txt` | 词表（315894 B） |
| 运行时 | `pip install sherpa-onnx` → **1.13.8**（core 16.9 MB + 轮子 2.2 MB，装在 Store Python 的用户 site-packages，**与双击运行 wgime 的解释器同一个**） |

**模型来源**：`hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17`
（HF 的国内镜像；**必须带浏览器 UA**，否则 403。HF 直连不通；GitHub 上那份 `...tar.bz2` 是 **999 MB** 的
fp32+int8 合集，没必要下 —— 只要 `model.int8.onnx` + `tokens.txt`）。许可：SenseVoice 系 Apache-2.0。

**接法**（`package\config.txt`，未入库；`build-package.ps1` 会用模板覆盖它，重建后要重填）：
`voice = 1` / `voice_engine = cmd` / `stt_cmd = python C:\Tools\wgime-local-asr\wgime-stt.py {wav}`

**实测**（CosyVoice2 合成音频当"人声"；本机麦克风是纯数字静音，只能这样验）：
中文"今天天气不错，我们下午三点开会。" → `今天天气不错，我们下午3点开会。`（`use_itn=True` 转阿拉伯数字，
`--itn=0` 可保留"三点"、但没有标点）；英文全对。
耗时 **建会话 1.5s + 解码 0.24s**（`--threads=4`；2 线程 2.4s + 0.41s）—— 比第六十三轮的 whisper 常驻
（3~5s/句）更快，比 `cmd` 每句新起 faster-whisper（20s+）快一个数量级。

**顺带查清的两件事**：① ModelScope 的 `iic/SenseVoiceSmall-onnx`（`model_quant.onnx` 230 MB）是
**FunASR 格式**，配 `funasr-onnx`，而那个包**只支持 Paraformer、不含 SenseVoice** → 与 sherpa-onnx 不通用；
② 想要**常驻**（每句 ~0.25s）得自己加进程，当前 wrapper 是每句新起（1.5s 是建会话的钱）。

**和第六十一~六十三轮的关系**：这轮与并行的语音工作（VAD 相对阈值 / 系统引擎分段 / whisper 常驻）**不冲突**，
四种后端各管一段：`whisper`（离线、3~5s、中文 88~100%）/ `cmd`+SenseVoice（离线、1.7s）/
`http`（云端、~1s、要国内站 key）/ `system`（零配置、最弱）。