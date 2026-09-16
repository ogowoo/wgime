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
### §D8.1 拿去其它设备（便携包）

**结论：语音输入只有 python 版有**（bat/ps1 版没有这个功能），所以目标机必须是
「python 版 wgime + Python 3.8~3.14(x64)」。在这个前提下，本机已经打好了便携包：

- 目录：`C:\Tools\wgime-local-asr\portable\`，压缩包：`C:\Tools\wgime-asr-portable.zip`（**184 MB**，17 项）
- 内容：`wgime-stt.py`（wrapper）+ `models\sense-voice\{model.int8.onnx(228MB), tokens.txt}` +
  `wheels\`（sherpa-onnx 的 **cp38~cp314 win_amd64** 轮子 + core 轮子）+ `setup-asr.py` +
  `安装-语音识别.cmd` / `卸载-语音识别.cmd` + `test-zh.wav`（自检用）+ `README.txt`
- 三步用法：拷过去 → `安装-语音识别.cmd "<wgime目录>"`（离线 pip + 写 config.txt + 自检）→
  启动 wgime、托盘「配置→重载配置」、按住 `Ctrl+Alt+V` 说话

**三个设计要点（换设备时必须守住）**
1. **wrapper 按自身位置找模型**（`DEFAULT_MODEL_DIR = <脚本目录>\models\sense-voice`），所以模型目录
   整包一起搬就行，不用改代码；
2. **`stt_cmd` 里的路径必须按机器写死** —— `_cmd_recognize` 是 `shell=True` 跑一条命令行，
   没有便携的相对路径可用。所以由 `setup-asr.py` 在本机取 `sys.executable`（`pythonw` 就换同目录
   `python.exe`）并把两个绝对路径**带引号**写进 `stt_cmd`；**每台设备各跑一次安装脚本**。
   安装脚本同时会清掉旧的 `voice_engine/stt_*` 生效行，避免重复键"谁生效说不清"。
3. **离线可装**：`wheels\` 里带全了 cp38~cp314 的 win_amd64 轮子（`sherpa_onnx` 那个轮子是
   **cp3xx 专用**，只带当前版本会装不上别的 Python），安装脚本用
   `pip install --user --no-index --find-links wheels sherpa-onnx`，失败才回退联网。

**验证过**（都在本机、不依赖外网）：① `--no-index --find-links wheels --target <tmp>` 装出来的副本
**真的能识别**（同一批轮子自足）；② 造了个"假设备"目录（只有 config.txt，路径与安装位置无关），
跑 `setup-asr.py` 后 `stt_cmd` 写成该机的绝对路径，再用 `engine.load_config` + `voice.recognize`
跑通 → `今天天气不错，我们下午3点开会。`；③ wrapper 在**另一个路径**（`portable\`）下按自身找模型正常。

**没做的事（有意）**：**不打包 Python 运行时**。Windows 版 embeddable Python **不含 tkinter**，
而 wgime 的候选条/托盘全是 Tk —— 打进去也跑不起来，目标机还是得装标准 Python。

**按目标机情况选后端**（都在 `config.txt` 里改一行，代码不用动）：
| 目标机情况 | 选哪个 |
|---|---|
| 中文 Windows、只想要能出声就行 | `system` + `voice_lang = zh-CN`（零文件，需系统装了中文语音包；第六十二轮修好了长句截断） |
| 能装 pip、想离线又要准 | 本便携包 `cmd` + SenseVoice（1.7s/句） |
| 能联网、不想放模型 | `http` + 硅基流动**国内站** key（~1s/句；国际站没有 ASR 模型，见 §D7） |
| 已装 faster-whisper | `voice_engine = whisper`（第六十三轮，常驻，3~5s/句，中文 88~100%） |
### §D7.1 第六十五轮补充：国内站 key + 坏网络下的 http 后端

- **判站点**：`GET https://api.siliconflow.cn/v1/models` 带 `Authorization: Bearer <key>` ——
  200 = 国内站 key；401 `{"code":30014}` = 不是这个站的 key。国际站的 key 在 `.cn` 回 30014，
  国内站的 key 在 `.com` 也回 30014，**两者长得一模一样，只能两边都试一次**。
- **本机连接层实测（与 key 无关）**：`GET /v1/models` 10 次成功 3 次（6× `SSLV3_ALERT_BAD_RECORD_MAC`、
  1× `RemoteDisconnected`）；语音请求一段时间 3/5（**成功时 0.6~0.85s**）、过一会儿 1/6
  （`The read/write operation timed out`）。同一份配置、同一个 key，波动全在网络路径。
- **`stt_retry`（默认 3，1~8）**：只对**连接层**异常重试（URLError/SSLError/OSError/RemoteDisconnected…），
  间隔 0.4s；`urllib.error.HTTPError`（服务端回过话：401/429/500）**直接抛，不重试**。
  最终错误文本带"共试 N 次"，重试过程写 always-on 日志。
- **`stt_timeout`（默认 15s，5~60）**：单次尝试超时；代理是黑洞时它决定回退直连前等多久。
- **记住可用路径**（`voice._prefer_direct`）：只在自动模式（`stt_proxy` 空/auto）生效 ——
  哪条路成功就把它排到下次第一位，并写一行 always-on。本机那个 `127.0.0.1:10808` 现在是**黑洞**
  （连上但不响应，不再是 10061 秒拒），auto 每句白等 `3×timeout`（实测第一句 100s），
  记住直连后回到 0.6s 级。显式 `stt_proxy = direct` / 指定代理时不会改顺序（探针 D 段依赖这一点）。
- **探针**：`%TEMP%\wg-r59-stt-proxy-probe.py` G2 段用"先把连接掐掉一次"的假服务器证明重试
  （服务端收到 2 次请求），并用 `stt_retry = 1` 证明不重试时只发 1 次、错误写"共试 1 次"。

### §D7.2 第六十六轮：双引擎赛跑（`voice_fallback`）

- **语义**：主引擎（`voice_engine`）+ 第二引擎（`voice_fallback`）**同时开跑**，谁先返回**成功**（`err is None`，含 `text == ""` 的"没听清"）就用谁；另一个结果丢弃（daemon 线程）。
  两个都失败 -> 返回 `"<A> 失败: …；<B> 失败: …"`。
- **为什么不用串行回退**：本机实测云端要 10~20s 才报错，串行版每句 24~38s（虽然 4/4 都对，但没法用）；
  赛跑版平均 **2.80s / 4 全对**（三次本地 ~3.5s 赢、一次云端 0.73s 赢）。
- **收紧后台线程**：`http` 主引擎配了第二引擎时，`_http_post` 把 `stt_retry`/`stt_timeout` 收到
  `min(2)` / `min(10s)` —— 反正本地兜底，别让被丢弃的云端线程占几十秒。
- **同名防自环**：`voice_fallback == voice_engine` 时按"没有第二引擎"处理。
- **代价**：每句都跑一次本地引擎（SenseVoice 建会话 ~1.5s 的 CPU）；不想白跑就别配 `voice_fallback`。
- **探针**：`%TEMP%\wg-r59-stt-proxy-probe.py` H 段（6 项）+ 解析 3 组。

### §D9 第六十七轮：keyfix 的"牺牲字符"必须不可见

- **机制**（C# `UnicodeCommitQtFix` 同款）：Qt 类应用（微信 4.x）在全角标点后会把**下一个注入字符**
  错认成该标点，所以 python 在标点后追加 `[牺牲字符 down/up][VK 0x08 down/up]` 把它吸收+擦掉。
- **真 bug**：牺牲字符原来是可见的 `X`；**退格那一下失效**（应用正忙、或把退格也当成要吸收的字符）
  时 `X` 就永久留在文档里 —— 用户报"输入完成、有联想时打标点会显示 X"。
- **修法**：`win.QT_FIX_SENTINEL = 0x200B`（零宽空格）。退格成功一样干净；失败也**看不见**。
  汉字/ASCII/emoji 判定不变（代理对不算 trigger，与 C# 一致）。C# 仍是 `'X'`（AGENTS §27）。
- **诊断**：`win.qtfix_note_app()` —— 每个前台程序**第一次**走这条路径时写一条 always-on
  （`keyfix: 标点吞字修复在 <程序名> 上启用 …`）；出问题就用托盘「这个程序 → 标点吞字修复」关掉它。
- **探针**：`%TEMP%\wg-r67-qtfix-probe.py`（16 项）—— 拦住 `win.user32.SendInput` 直接验事件序列
  （标点 → U+200B → 退格，且**没有 0x58**），并用真 `main.py` 前缀构造"联想中打标点"确认只注入一次。

## §D10 第六十八轮：`followcaret` 默认 0 并冻结（代码全保留）

**用户决定**（原话）："我做个决定, 把光标跟随的功能去掉了，但是屏幕边缘粘贴的保留。…
改成默认0吧，先改成这个并冻结功能，代码不删。"

**"冻结"的准确定义**：改的只有**默认值**和**开关读取点**，跟随的实现一行没删：

| 还在的东西 | 位置 |
|---|---|
| 独立 Caret Helper 子进程（纯 ctypes vtable 直调 UIAutomationCore、源码走环境变量、JSONL stdio IPC） | `win.py` `_EMBEDDED_CARET_HELPER` / `_HELPER_BOOTSTRAP` / `ensure_caret_bg()` |
| helper 的定位兜底链（UIA 缓存 → GUITI rcCaret → 聚焦框 → last → 前台原点；鼠标兜底仍是禁的） | `win.get_caret_pos()` / `win.workarea_at()` |
| 候选条跟随定位链（`bar.show(..., follow)` + 35/80ms 后的 `_ipc_reposition`） | `bar.py` / `main.show_page()` |
| 托盘「候选窗跟随光标」开关（勾选状态读 `get_followcaret`） | `tray.py` 选项菜单 |
| 配置键 `followcaret`（白名单: `1/on/true`=开, 其它=关） | `engine.load_config` |

**唯一的行为差异**：
1. `engine.py` 缺省 `followcaret=False`（config.txt 不写这一行时按关）;
2. 默认**不起 helper 子进程** —— 两个 spawn 点都加了门控: 启动早期那条 helper 线程读 `_EARLY_CFG`
   （那时 `CFG` 还没建），启动收尾那条读 `_caret_follow()`;
3. `main._caret_follow()` 是**唯一**开关读取点（`show_page` / `get_followcaret` / `toggle_followcaret` 都走它）
   —— 以前有些地方写 `CFG.get('followcaret', True)`、有些写 `False`，这种不一致就是将来"有的地方跟随、
   有的地方不跟随"的种子。

**怎么开回来**（用户随时可能要）：`config.txt` 写 `followcaret = 1`，或托盘「选项 → 候选窗跟随光标」点一下
（`toggle_followcaret` 立即 `show_page()` 重定位，并落盘）。开回来之后行为与第三十八～四十四轮**完全一致**
（那不是"近似恢复"，是同一份代码）。

**C# 侧没动**：`wgime.bat` / `WgIme.ps1` 的 `LoadConfig` 代码缺省仍是"开"；但**出厂 config.txt 是
`followcaret = 0`**（本轮的根模板 + release 模板），所以两个版本开箱默认行为一致（都固定贴边）。
要动 C# 的代码缺省得按 AGENTS §3 走"瘦 DLL + ps1 + 15 项测试"整条链。

**验证**：`%TEMP%\wg-r68-followcaret-probe.py`（**29/29**，不建 Tk / 不碰词库 / 不碰用户数据）:
- A `engine.load_config`：缺省行 / `1` / `on` / `true` / `0` / `off` / `yes`(非法值→关) 共 7 组;
- B `_caret_follow()`：`CFG` 空 → False（默认冻结）、显式 False → False、True → True;
- C **AST 判定**：`main.py` 里 `ensure_caret_bg` 的引用恰好 2 处, 且都在 `if followcaret…` 门控里;
- D **把两条门控语句从源码 AST 节点编译出来真跑一遍**（`win`/`threading` 打桩）: 关着 0 次调用、开着 1 次
  —— 这一步是关键: C 段只证明"字面上有 if", D 段证明"那个 if 真的拦住/放行了";
- E `toggle_followcaret()` 0→1→0 并落盘 `followcaret = 1/0`；`show_page` 用 `_caret_follow()`;
  源码里没有残留 `CFG.get('followcaret', True)`;
- F 根模板 / release 模板 / 运行时 `package\config.txt` 三份都是 `followcaret = 0` 且行尾没被翻成 CRLF。

**永久回归**：`tests\pure-state-harness.py` 新增 5 项（**23 → 28 项**）: `CFG` 缺省关、`_caret_follow()`
默认 False、打开后为真、托盘开关能关掉并落盘 0、能再开回来并落盘 1 —— 后两项就是"冻结 ≠ 删除"的守卫。

**实机 A/B（跑真成品单文件, 不是源码目录）**: 同一份 `dist\wgime-py.py`, 只改 `followcaret`:
`0`（默认）→ 1.5/3/6/10s 四个采样点**都是 0 个 python 子进程**（日志 0 行 caret/helper）;
`1` → 1.5s 起稳定 **1 个**, 日志 `IPC helper started pid=… (167-char cmdline)` → 65ms 后
`IPC recv {'type':'ready','mode':'stable-focus-cooldown'}`。**装置三坑**（都踩过）:
① `mode = tray` 时分不出区别 —— 早期 helper 段被 `if mode != 'tray'` 包着（main.py:210）;
② 设 `WGIME_DICT_DIR` 会让程序读**别的目录的 config.txt** —— 因为 `APP_DIR = dirname(DICT_DIR)`;
   正确做法: 临时目录里 `mklink /J dicts <仓库 package\dicts>`, **不设** `WGIME_DICT_DIR`;
③ `win._dlog` 的开关是 **`WGIME_DEBUG=1`**（不是 `WGIME_DEBUG_CARET`）——写错了就"日志一行没有",
   很容易误判成"代码没走到"。
安全配置: `mode = ime` + `starton = 0`（钩子装了但不激活 ⇒ 按键透传, 不抢用户的键盘）+
`hotkey_toggle/mode/makeword/trad/voice = none`（测试实例无法被激活）+ `LOCALAPPDATA` 指向临时目录;
数子进程一律按 **ParentProcessId** 归属, 别按命令行全局匹配（会误伤用户正在运行的实例）。

**行尾坑（每次改文档都会踩）**：`config.txt`(根/release/package) 与 `AGENTS*.md`/`CHANGELOG.md`
都是**纯 LF**，而 `docs\WGIME_*.md` 是 **CRLF** —— 改这几份文本一律
`io.open(p, encoding='utf-8', newline='')` 读、按原行尾写回，改完用
`git diff --numstat` 核对增删行数（本轮: 根/release config.txt `4 2`、使用说明 `3 1`、技术文档 `1 1`）。
`sync-dist.ps1` 之后照例 `git checkout -- release\plugins\wgtranslate.txt` 消掉那个已知的行尾噪声。

## §D11 第六十九轮：状态提示点（`dot.py`）+ 三个参考项目的调研结论

### 需求来源
`hideidle = 1`（默认）时空闲不显示候选条 → 用户**看不出输入法是开还是关**。第五十七轮的真实抱怨
（"托盘图标都不会变了 / 混合的模式切换不过去"）根因是**没有可见反馈**：候选条不显示、托盘图标还可能被
Windows 收进 `^`（§36 `tray_promoted`）。所以要的是一个**常驻、极小、不打扰**的状态显示。

### 三个参考项目（2026-09-16 逐文件读过，浅克隆在 `%TEMP%\wg-refs\`）
| 项目 | 它怎么落地"免注册" | 我们拿什么 |
|---|---|---|
| [franj/PhoneMic](https://github.com/franj/PhoneMic/)（局域网手机当麦，PySide6+pywin32+PyAutoGUI） | **完全不跟踪光标**，只认"谁有焦点"；剪贴板/模拟键盘两档注入；无焦点悬浮窗预览 | 印证"不跟随"是好设计；语音链路可借（流式、逐字注入、终端回退） |
| [xiuleitan/MouthWrite](https://github.com/xiuleitan/MouthWrite/)（Windows AI 语音输入，PySide6+pynput+sounddevice+httpx） | **最终撤掉了自动粘贴**：`controller._finish_with_paste` 注释写明"不再自动粘贴到输入框"，改成**只写剪贴板 + 等用户点鼠标左键**，关自己的窗 → `QTimer.singleShot(150)` → `pynput` 发 Ctrl+V | ①"点击落点"这个交互（我们还没做，见下面"未做"）；②ASR 走 `chat/completions` 多模态 + SSE 流式（`input_audio`/`audio_url`，`asr_options.enable_itn=False`，剥 `<\|zh\|>` 标记）—— 我们的 `http` 后端只有一次性 multipart；③热键 `_is_pressed` 去重复 = 我们第五十八轮那个修法；④`duration < 0.3s` 丢弃 |
| [harold-lu-bit/IMEDot](https://github.com/harold-lu-bit/IMEDot/)（Ubuntu+PyQt6 光标边状态点，~350 行） | 独立**进程**跑 GLib 主循环 + D-Bus 监听 IBus `GlobalEngine`（rime/xkb）= 状态；GUI 进程画一个 12px 圆点 | **本轮照它做的**（形态）；另外两点印证/提醒见下 |

**IMEDot 的两个关键事实（别误读）**：
1. **它跟的是鼠标，不是文本光标**：`indicator.py` 里 `pynput.mouse.Controller().position` →
   `move(x+8, y-16)`，`QTimer` 16ms 刷新。Linux 上没有统一可查的 caret API（要 AT-SPI，多数应用不实现），
   所以"轮询 + 置顶小窗"这条路线在桌面上的可落地形态就是"跟鼠标"。我们**有意**照做：候选条跟随已冻结
   （§17/§D10），而状态点跟鼠标没有"离正文太远"的问题。
2. **状态检测放独立进程 + `mp.Queue`**（`monitor.py`：D-Bus 信号驱动、GUI 进程零轮询）—— 和我们
   caret helper（§17）**同构**，是对"把易挂的系统 API 隔离到子进程"的又一次外部印证。差异是它**事件驱动**、
   我们**每键请求 + 35/80ms 精修**；Windows 侧 UIA 有 `TextSelectionChangedEvent`，理论上也能事件驱动
   （真要做先探针验证跨进程回调的稳定性，别直接改）。
3. 它的窗口属性组合 `FramelessWindowHint|WindowStaysOnTopHint|Tool` + `WA_TranslucentBackground` +
   **`WA_TransparentForMouseEvents`**（鼠标穿透）。注意：Qt 的 `Tool` 在 X11 下天然不抢焦点，
   **Windows 没有这个等价性** —— 所以我们的 `WS_EX_NOACTIVATE` 不能省（别照抄着删掉）。

### `dot.py` 的实现要点（改这块先读）
- 颜色/位置是**纯函数**（`dot_color` / `dot_pos`），所以能 headless 断言四边翻转、多屏工作区、模式取模；
- `win.set_overlay_styles(hwnd, click_through=True)` 是本轮新加的 Win32 原语：
  `WS_EX_NOACTIVATE`（永不抢焦点，否则会把输入框焦点夺走）+ `WS_EX_LAYERED|WS_EX_TRANSPARENT`
  （鼠标穿透，否则 12px 也会挡住点击）+ `WS_EX_TOOLWINDOW`（不进任务栏/Alt-Tab）；
- **`WS_EX_TOPMOST`(0x8) 不能通过 `SetWindowLong` 设、本机也读不回来**（实测：显式
  `SetWindowPos(HWND_TOPMOST)` 之后 `GetWindowLongPtrW(GWL_EXSTYLE)` 仍无 0x8；Tk 层
  `attributes('-topmost')` = 1）。所以置顶一律 `win.set_topmost()`（= `SetWindowPos`，bar.py 同款），
  探针也不拿这个位当证据 —— 这条已写成可执行断言（`wg-r69-dot-probe.py` C2 段）；
- 32ms 一拍（`main.poll` 每 4 拍）+ 颜色/位置没变不碰窗口；`statedot = 0` 时**一个窗口都不建**；
  tray 模式隐藏（没有"输入法开关状态"）。
- 坑：`-transparentcolor` 的键色（`dot.KEY = '#010203'`）**不能**与任何状态色相同；`deiconify` 之后再补一次
  `set_overlay_styles`/`set_topmost`（§43 托盘句柄时序那类"窗口重建后样式丢失"的教训）。

### 本轮**没做**、但已论证过成本的三件事（用户要的时候直接接着做）
1. **点击落点模式**（MouthWrite 的结论，成本最低）：待确认文本只放剪贴板 + 候选条提示 → 一次性
   `WH_MOUSE_LL` 捕获左键 → 关提示 → 短延迟 Ctrl+V。我们有取色器的鼠标钩子先例，也要照它的教训做**清理断言**。
2. **流式 ASR**（成本中，需换服务商）：`chat/completions` + SSE delta；硅基流动没有 chat 形态 ASR，
   可选 DashScope `qwen3-asr-flash` 或自建 vLLM Qwen3-ASR。
3. **表盘点名但不是"光标跟随"**：IMEDot 的鼠标跟随**只适合状态灯**，不要拿它去改候选条定位。

### 验证
`%TEMP%\wg-r69-dot-probe.py` **67/67**（A 颜色 / B 位置数学 10 例 / C 真窗口样式与显隐销毁 /
C2 `WS_EX_TOPMOST` 环境事实 / D 配置 6 组 / E 接线 AST 真跑 / F 文件卫生）；
`tests\pure-state-harness.py` **33 项**（+5：默认开 / 关掉不建窗 / tray 不建窗 / 真 tick 显示 / 开关反映）；
`undefined-globals` 0；tray-swap 42；voice-vad 31；whisper-warm 67；`wgime-dist-sync-check` OK。

### §D11.1 第六十九轮补充：Tk 的 Toplevel 是**两层** HWND（样式必须写外框）

**发现方式（值得照抄的流程）**：源码探针 70/70 全绿 ≠ 真的对。拿**真成品单文件**启动, 用
`EnumWindows` 枚举该进程的顶层窗口, 打印"类名 / 矩形 / 扩展样式 / 是否可见" —— 一眼就看出问题:

```
t=12s  TkTopLevel  vis=1  12x12  @919,980  ex=0x80088     <- 圆点窗口, 位置**正好**等于 dot_pos() 期望值
t=12s  TkTopLevel  vis=0  378x265 @0,0     ex=0x80088     <- 候选条(隐藏)
```

位置对、样式不对: `0x80088` 里只有 Tk 自己设的 `LAYERED|TOOLWINDOW|TOPMOST`,
我写的 `WS_EX_NOACTIVATE`(0x08000000) 与 `WS_EX_TRANSPARENT`(0x20) **不见了**。微探针
(`%TEMP%\wg-r69-wrapper-micro.py`) 立刻给出答案:

```
winfo_id()          cls=TkChild     ex=0x4        <- 我一直在写这个
GetParent(winfo_id) cls=TkTopLevel  ex=0x80088    <- 真正的外框
GetAncestor(GA_ROOT)cls=TkTopLevel  ex=0x80088
把样式写到 winfo_id()  -> TkChild 变 0x80800a4, 外框**纹丝不动**
把样式写到 GA_ROOT     -> 外框变 0x80800a8 (NOACTIVATE|LAYERED|TRANSPARENT|TOOLWINDOW|TOPMOST)
```

**结论(照做)**: 凡是要给 tk 窗口设**不激活 / 鼠标穿透 / 透明 / 置顶**的地方, 目标 HWND 必须是
`win.top_level_hwnd(<winfo_id()>)`(= `GetAncestor(GA_ROOT)`, 带"拿不到就原样返回"的回退)。
现有调用点: `dot.Dot.hwnd()`、`bar.py` 的两处 `set_topmost`。

**两个连带的坑**:
1. **外框守卫**: 外框要等 Tk 真的映射过窗口才存在。`_apply_styles` 里若发现
   `top_level_hwnd(wid) == wid`(还没有外框), 要**直接 return 且不要置 `_styles_done`** ——
   否则样式写到子窗口上、还被标记成"已完成", 之后永远不补(圆点会抢焦点/挡点击/渲染成白块)。
2. **deiconify 只是"请求映射"**: 之后要补一次 `update_idletasks()` 外框才真的建出来, 否则第一次显示
   会闪过一个没样式的白块(下一拍 ~32ms 才补上)。

**探针为什么第一次没抓到**: 源码探针读的是 `d.hwnd()`, 而 `hwnd()` 当时也指向 `TkChild` ——
**"自己写给自己的窗口、再自己读回来"永远自洽**。教训: 涉及 Win32 窗口样式/时序的改动,
除了进程内读回, 还要**从进程外**验证一次(枚举窗口/类名/样式), 这一层才代表窗口管理器看到的东西。
同样地, **颜色不要在进程外查**: 分层(`-transparentcolor`)窗口用 `GetPixel` 读到的是它自己的像素
(微探针里 `#6B6B6B` 的圆点读回来是 `#000000`/`#FFFFFF`), 颜色只能进程内读 canvas 的 item fill。

## §D12 第七十轮：内嵌「漏依赖」这一类 bug（pystray → six）

### 现象（用户机截图，Python 3.14 + pythonw）
```
托盘图标没能创建。  NIM_ADD: None
原因: site\thirdparty.zip\pystray\__init__.py line 64, in <module> -> backend().Icon
      ImportError: this platform is not supported: No module named 'six'
```
输入法本身在跑，**只是托盘菜单整个没有**（工具箱/插件管理/所有托盘开关都进不去）。

### 根因
- `pystray` 的 `_base.py:24` / `_win32.py:22` 有 `from six.moves import queue`；METADATA 也写着
  `Requires-Dist: six`。而构建脚本只 `collect_thirdparty(['comtypes','uiautomation','pystray'])`
  —— **没嵌 six**（内嵌 zip 里 `six` 条目 0 个）。
- 单文件运行时的第三方 import 会**回退到宿主 site-packages**：构建机（本机）碰巧装了 six
  （`...\local-packages\Python312\site-packages\six.py`），于是本地怎么测都正常。
- 干净机器上 `import pystray` 直接 ImportError → pystray 的 `backend()` 把它包成
  "this platform is not supported: No module named 'six'"。
- **和第四十二轮 Pillow 那个坑同一类**（宿主恰好装了 X，于是内嵌缺口测不出来）。区别是 Pillow
  那次我们改成构建期预渲染 ICO，这次必须真把依赖嵌进去。

### 复现（判据，修前修后都用它）
```
python -S -E -c "import sys; sys.path.insert(0, r'%LOCALAPPDATA%\wgime-py\site\thirdparty.zip'); import pystray"
```
`-S` 不加载 site-packages（= 干净机器）、`-E` 忽略 `PYTHON*` 环境变量。
修前: 上面那条命令原样吐出用户的错误；修后: 通过。

### 修法（要点，防这一类而不是只补 six）
1. `collect_thirdparty` **自动收声明依赖**: 读 `importlib.metadata.metadata(name)` 的
   `Requires-Dist`，**只收无条件项**（带 `;` marker 的平台/extra 依赖不收 —— 我们只跑 Windows，
   extra 是插件的可选能力）；排除表 `_THIRD_EXCLUDE = {'Pillow'}`（C 扩展 ABI 绑定，图标已在
   构建期渲染成 ICO）。构建日志会打印：
   `third-party to embed: comtypes, uiautomation, pystray, six`。
2. 顶层入口按 `ispkg` 写 —— `six` 是**单模块**，写 `six.py`（老代码一律写 `name/__init__.py`，
   对模块而言是「能 import 但形态错」）。
3. **构建期干净环境自检** `verify_thirdparty_isolation(zip_bytes, top_names)`: 把 zip 写临时文件，
   `python -S -E` + 只挂该 zip 的 `sys.path`，逐个 import 顶层名字；失败打印 stderr 并
   **`sys.exit(1)` 中止构建**。日志: `third-party isolation check: THIRD-ISOLATION-OK ...`。
4. **永久回归** `wgime-py-pure\tests\embedded-isolation-test.py`（9 项）: 从 `dist\wgime-py.py`
   解出 `THIRD_ZIP_B64`，同样用 `-S -E` 干净解释器逐个 import，并专门断言「真 bug 的形状」
   （`import pystray` + `from six.moves import queue`）。**修复前的 dist 上它会报 3 项失败**
   （内嵌无 six / import pystray 失败 / 组合失败）—— 守卫有效性已自证。
5. **干净环境实机探针** `%TEMP%\wg-r70-clean-live.py`（5 项）: 用 `python -S -E` 跑真
   `dist\wgime-py.py`（隔离 LOCALAPPDATA + `dicts` 目录联接 + 复制一份 dict 缓存热启动），
   断言 pystray 的托盘消息窗口 `WgIme-Pure<pid>SystemTrayIcon` 出现、`tray start ok=True`、
   `tray selfcheck: nim_add=True(count=1)`、日志里没有 `six`/ImportError（顺带确认状态提示点也在）。
6. 构建脚本自身的坑: 被 `powershell -File` 调用时 stdout 是 **cp1252** —— 本轮我加的中文提示直接
   `UnicodeEncodeError` 把构建打死，而 `build-package.ps1` 会**沿用旧产物**还报成功（`build=0`）。
   现在构建脚本开头 `sys.stdout/stderr.reconfigure(encoding='utf-8', errors='replace')`。
   **判据**: 构建日志里必须有 `third-party to embed:` / `third-party isolation check:` 两行，
   且 `built ... dist\wgime-py.py` 的字节数变了 —— 只有这行、字节数没变 = 构建其实没跑成。

### 影响面与用户绕过
- **已发布版本都受影响**（v1.2.x 内嵌方式相同）: 干净环境（没装 six）的用户没有托盘菜单。
- 临时绕过: 用启动它的解释器装一次 —— `"C:\Program Files\Python314\python.exe" -m pip install --user six`。
- 第六十九轮的状态提示点**不依赖托盘**（`dot.py` 自带窗口），托盘挂了也还能看出输入法开/关。

## §D13 第七十一轮：依赖内嵌的边界（纯 Python 全嵌 / C 扩展只降级）

### 一句话契约
**纯 Python 依赖 100% 内嵌（含传递依赖）；C 扩展依赖不可能内嵌，必须"可用则用、不可用则明确降级"。**

### 为什么 C 扩展内嵌不了（不是偷懒）
`.pyd`/`.so` 是**编译产物，与解释器版本 + ABI 绑死**。构建机是 Microsoft Store 的 **cp312**，
而用户机实测是 `C:\Program Files\Python314`（cp314）—— 把 cp312 的 `_imaging.pyd` 塞进单文件，
在那台机器上导入必然失败。我们单文件的价值恰恰是"同一个文件在任何已装 Python 上跑"，
所以**只有纯 Python 源码可以内嵌**。（当年 Pillow 那次就是这个原因改成"构建期渲染 ICO"。）

### 现在的内嵌清单（正好两项，测试会断言）
| 顶层 | 为什么在 | 体积 |
|---|---|---|
| `pystray` | `tray.py` 真 import（托盘） | 26.9 KB |
| `six` | pystray 的**声明依赖**（`from six.moves import queue`） | ~10 KB |

`thirdparty.zip` 281.2 KB → **36.8 KB**，内嵌模块 85 → 14，单文件 898.8 → **573.0 KB（-36%）**。
`comtypes`/`uiautomation` 已删：第四十四轮起光标跟随 helper 是 `win.py` 里纯 ctypes 的源码字符串，
全项目 0 处 import（有 `A/B` 实机验证：`followcaret=1` 时 helper 仍起、175ms ready）。

### `_THIRD_SKIP`（构建脚本里的显式跳过表，每条必须有原因）
`Pillow`（C 扩展；托盘图标构建期渲染成 ICO，运行时不需要）、`psutil`（C 扩展；`plugins.py` 里可选，
缺了回退 wmic）、`cryptography`（C 扩展；chat 插件加密的可选能力）、`faster-whisper`（C 扩展 + 模型；
只有 `voice_engine=whisper` 要）、`argostranslate`（含语言模型；wgtranslate 的离线翻译可选）、
`comtypes`/`uiautomation`（已无人 import）。
**判据**: 构建日志里每个 `skip third-party <名字>` 后面都跟着原因；新加依赖时若不在闭包里、
又不在跳过表里，`isolation check` 会在构建期报错（缺模块）——不会溜到用户机上。

### 本轮修的一个"静默崩溃"
`plugins/chat.py` 原来在 `Crypto.enc/dec` 里**用到时才** `from cryptography...`。缺包时这会在 Tk
回调里抛 `ImportError`，而 pythonw 下 stderr 是 None → 用户看到的是"回车没反应、输入框还留着字"。
现在: 模块级 `HAS_CRYPTO` 探测 → `enc` 返回 `None` → 调用处 `set_status('加密不可用 (需 cryptography):
pip install cryptography —— 未发送')` 且**保留输入内容**；**绝不退回明文**（设了房间密钥却发明文是安全问题）。
`dec` 返回 None 时走已有的 `[encrypted]` 兜底。

### 验证（这一轮新增/沿用的东西）
- `wgime-py-pure\tests\embedded-isolation-test.py`（**10 项**，tracked）: 从 dist 解出 `THIRD_ZIP_B64`，
  `python -S -E` 干净解释器逐个 import；断言内嵌顶层**正好** `{pystray, six}`、
  `comtypes/uiautomation` 不在、`PIL` 不在、以及"真 bug 形状" `import pystray` + `from six.moves import queue`。
- `%TEMP%\wg-r71-optdep-probe.py`: 干净环境里逐项验证"不可用则降级"（PIL→`tray.HAS_PIL=False` 仍能起托盘、
  cryptography→`enc/dec` 返回 None、psutil→`[]`、voice 提示、核心模块 import、comtypes 不在）。
- `%TEMP%\wg-r70-clean-live.py`: 真成品 + `python -S -E` 实机（托盘消息窗口/状态点/`nim_add=True`）。
- `%TEMP%\wg-r68-live-ab4.py`: `followcaret` 0/1 的 helper A/B（删 uiautomation 后的回归）。

---

## §D12 第五十八~六十二轮：语音的一串真因（AGENTS.md §38 的叙事原文）

> AGENTS.md 有 64K 注入预算，这里放**原文**（含实测数字）；正文只留"要照做的规则"。

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

**第六十轮（硅基流动两站的区别，实测）**：见 §D7。

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

**当时的后端选型结论**（后来被第六十四轮取代）：`voice_engine = whisper`（本地常驻 faster-whisper，
离线、中文 88~100%、每句 3~5s）、`voice_engine = http` + 硅基流动**国内站** `SenseVoiceSmall`（每句 ~1s，
要国内站 key）、或 `voice_engine = cmd` + 本地 whisper.cpp（**每句都新起进程，实测 20s+，别拿它跑本地
whisper**）；`system` 只适合"完全不想配置"的场景。第六十四轮之后 **`cmd` + sherpa-onnx/SenseVoice 才是
本机首选**（1.5s 建会话 + 0.24s 解码）。