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

### §D8.2 第二台机器（Store Python 3.13）从头装一遍（本轮）

**先说结论：上面那套东西（`C:\Tools\wgime-local-asr\`、`portable\`、`wgime-asr-portable.zip`）
只在第一台机器上有。第二台机器（本机：PATH 上的 `python` = Microsoft Store 版 3.13.14）
当时**一样都没有**（目录不存在、`import sherpa_onnx` 为 False、找不到 `model.int8.onnx`）。
所以"第六十四轮本机已装"这句话必须按机器看 —— 换机器要重装。**

本机实际执行的步骤（可照抄）：

```powershell
python -m pip install --no-input sherpa-onnx          # -> 1.13.8 (cp313 win_amd64 + core)
New-Item -ItemType Directory -Force C:\Tools\wgime-local-asr\models\sense-voice
$base = 'https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main'
curl.exe -L --retry 5 -C - -o C:\Tools\wgime-local-asr\models\sense-voice\tokens.txt     "$base/tokens.txt"
curl.exe -L --retry 5 -C - -o C:\Tools\wgime-local-asr\models\sense-voice\model.int8.onnx "$base/model.int8.onnx"
# 然后用 verify 脚本核对 model.int8.onnx == 239233841 B
```

- 实测下载速度 hf-mirror **13.4 MB/s**（17 秒下完 228MB），反倒 pip 只有 123 kB/s。
- `tokens.txt` **315894 B**、`model.int8.onnx` **239233841 B**（与第一台机器逐字节同尺寸）。
  `resolve/main` 会 302 到 `cas-bridge.xethub.hf.co` 的签名 URL，`curl -L` 能跟。
- wrapper 用 §D8 那份的**同款接口**：`--itn=0|1` / `--lang=zh|auto` / `--threads=N`
  （`--itn=0` 与 `--itn 0` 都认），另有 `WGIME_STT_ITN` / `WGIME_STT_LANG` 环境变量回退。
  顺手修掉一个真缺陷：docstring 里的 `\models\` 会触发
  `SyntaxWarning: invalid escape sequence '\m'`（改 raw docstring）—— 它虽只进 stderr，
  但把警告留在干净输出旁边没有好处。
- 出错一律 **stdout 空 + stderr 一行原因 + 退出码非 0**（`_cmd_recognize` 取"第一行非空输出"，
  用法提示混进 stdout 就会被当成识别结果上屏）。

**本机实测（4 句中文，系统 TTS `Microsoft Huihui Desktop` 合成 16k/单声道/16bit）**

| 环节 | 耗时 |
|---|---|
| 空解释器启动 | 0.09s |
| `import sherpa_onnx` | **0.03s** |
| 建识别器（载模型，**每句重付**） | **1.31s** |
| 解码 | 0.20 ~ 0.24s |
| **每句合计** | **1.48 ~ 1.57s** |

三引擎对比与 ITN 的 A/B（数字、探针名）见 `CHANGELOG.md` 同日那条。
**要点：`--itn=1`（缺省）95.0% 且有标点，`--itn=0` 99.2%、3/4 逐字全对但没有标点**；
`--itn=1` 的"错"大半是它有意做的数字规范化（`三点`→`3点`），不是识别错。

**接法（本机）**：`package\config.txt` 里 `voice = 1` / `voice_engine = sherpa` /
`stt_script = C:\Tools\wgime-local-asr\wgime-stt.py` / `stt_itn` / `stt_threads` / `stt_python`（绝对路径），
whisper 那几行注释掉（`sherpa` 引擎不看它们，留着会让"哪个键在生效"说不清 —— 同 §D8 的安装脚本做法）。
解释器必须写绝对路径：`_cmd_recognize`/warm 助手都是直接起进程，没有便携相对路径可用。
**回验**：`engine.load_config` + `voice.recognize` 走真实配置，4 句 1.48~1.57s（一次性）全通。

### §D8.3 常驻模式 `--serve`（同一天补做：每句 1.5s → 0.1s）

**起因**：1.5s 里有 **1.31s 是每句重付的模型加载**，解码只要 0.2s。照第六十三轮 whisper 那套"常驻助手"
做一遍就行 —— 而且父进程侧本来就是通用的（见下）。

**wrapper 的 `--serve` 契约**（`wgime-stt.py`，这是父子进程之间的接口，改它要同时改 `voice.py`）：

```
python wgime-stt.py --serve [--itn=0|1] [--lang=zh] [--threads=4]
  父 -> 子  {"id":1,"wav":"C:\\...\\a.wav"}
  子 -> 父  {"ready":true,"model":"sense-voice","boot_ms":1003,"itn":true,"lang":"zh"}   (启动时一行)
            {"id":1,"ok":true,"text":"...","ms":110,"audio_ms":4610}
            {"id":1,"ok":false,"error":"..."}          (坏 wav 只报这一条, 助手不倒)
            {"id":1,"ok":true,"text":"","ms":0}        (cmd=ping)
  {"cmd":"exit"} 或 **stdin 关闭(父进程退出)** -> 自己结束
```

**serve 模式下 stdout 只有 JSON**（日志一律 stderr）—— 父进程把每一行都 `json.loads`。
**`--itn` / `--lang` / `--threads` 是"建识别器"的参数**，想改必须重启进程；父进程按 `key` 判断，
所以这几个键改了会**自动重启助手**（whisper 的 `lang/prompt/beam` 相反，是每次请求带的）。

**父进程侧：把第六十三轮那套抽成通用的 `voice._WarmSrv`**，差异只剩三个钩子：
`key(cfg)`（要不要重启）/ `spawn(cfg)`（怎么起 → `(argv, env)`）/ `request_obj(cfg, rid, wav)`（发什么）。
`_WhisperSrv`（源码走环境变量 + `-c` 引导）与 `_SherpaSrv`（起 wrapper 的 `--serve`）各实现一遍。
共用机制（起/杀、READY、两个锁、1 秒限流、连续失败 3 次停手、串包丢弃、EOF、超时）**在两份回归里各钉一遍**。

**一个真踩到的 bug（被现有回归抓出来）**：一开始把"引擎名 → 助手实例"的映射**在导入时**固化进 dict，
于是 `voice._WSRV = voice._WhisperSrv()` 这种"换干净实例做隔离"就失效 —— `warm()` 操作旧对象、
`recognize()` 用新对象，whisper 回归 A11/A12 立刻红。改成 `_warm_srv()` **调用时** `globals()[名字]` 取；
两份回归的 A3 也加强成"起了进程**而且就是当前这个实例上的**"。

**实测**（`%TEMP%\wg-sherpa-warm-e2e.py` / `wg-sherpa-serve-probe.py`，真子进程 + 真模型）：

| 项 | 结果 |
|---|---|
| 每句（模型已载） | **0.08~0.15s**；真实配置链路（`wg-sherpa-config-timing.py`）**0.136~0.160s** |
| 首句 | 1.23s（等 READY；`boot_ms=1003` 是模型加载） |
| 文本 vs 一次性模式 | **4/4 完全一致** |
| 坏 wav | 只报 `ok:false`，助手照常服务下一句 |
| 改 `stt_itn` | 真重启（pid 12812 → 12768，旧进程已退出） |
| `shutdown()` | 子进程消失、`_SSRV.proc is None` |

**回归**：`wgime-py-pure\tests\sherpa-warm-test.py`（**74 项**，纯桩）。守卫有效性自检
（`%TEMP%\wg-sherpa-guard2.py`）：itn 字符串 → `J3` 失败；`_warm_srv` 导入时取全局 → `A3` 失败；
去掉"没配 stt_script 要报错" → `C1/C2/C3` 失败；基线 0 失败。
**顺手把测试里"起进程失败"的路径改成优雅记 FAIL**（原来会崩在 `p.emit`/`p.written[i]`/`old_q.queue`
上）—— 挂死或崩溃的测试比失败的测试难查得多。

**注意**：`_SSRV.ready` 的含义是"**已经消费过 READY 消息**"，不是"子进程已经载好模型" ——
预热（`prewarm_bg`）只 spawn、不消费，所以预热之后 `ready` 仍是 False，而第一句不会慢
（READY 就在队列里，请求时顺手消费掉）。别把 `ready` 当成"助手活着"的判据，那是 `proc`。

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

#### §D8.3.1 第七十二轮补：本机 wrapper 的 `--serve` **实现** + 实测校正

**缺口**: §D8.3 写的是契约，客户端 `voice.py::_SherpaSrv` 也在仓库里 —— 但服务端 wrapper 在仓库外
（`C:\Tools\wgime-local-asr\wgime-stt.py`），本机那份还是 9/15 的一次性版本（没有 `--serve`）。
于是本机一旦 `voice_engine = sherpa`，助手起不来（会报"起不来 + HINT"）。

**已补**（一次性模式一行没改，连退出码 3/4/5/6/7 都与旧版一致）:
- 启动即建识别器 → `{"ready":true,"boot_ms":…,"model":…,"itn":…,"lang":…}`；
- 每行 stdin `{"id","wav"}` → `{"id":…,"ok":true,"text":…,"ms":…,"segs":1,"audio_ms":…}` /
  `{"id":…,"ok":false,"error":…}`（**单句失败不退出**）；
- 支持 `{"cmd":"ping"}`（立刻回 `{"id":…,"ok":true,"text":"","ms":0}`）与 `{"cmd":"exit"}` / stdin EOF；
- 服务模式 stdout **只有 JSON 行**，日志一律 stderr；回包 `ensure_ascii=True`。
- wrapper 同步到便携包 `portable\wgime-stt.py`。

**本机接法（已生效）**: `package\config.txt` = `voice_engine = sherpa` /
`stt_script = C:\Tools\wgime-local-asr\wgime-stt.py` / `stt_itn = 1` / `stt_threads = 8` /
`voice_fallback =`（空）。

**实测（本机 = Intel Core Ultra 7 155H，8 核 / **8 逻辑核**，`test-zh.wav` 音频 4.7s）**:

| 项 | 结果 |
|---|---|
| 载模型（只在启动付一次） | **1312 ~ 2375 ms** |
| 解码 · threads 扫描 | 2 / 4 / 8 / 16 → **1532 / 1265 / 1171 / 1640 ms**（8 线程最优，再多反而退化） |
| 走 `voice.recognize()` | 第一句 **2.66 ~ 3.31s**、第二句 **1.06 ~ 1.38s**（差值就是省掉的载模型） |
| 子进程 | 常驻同一个 pid，`shutdown()` 后干净退出（不留孤儿） |

**校正 §D8.3 表格里的一处数字**: 那行"每句 0.08~0.15s（`audio_ms=4610`）"在本机**复现不出** ——
同一段 4.6~4.7s 音频，本机最好 1.17s（≈ 4x 实时）。常驻真正省掉的是**每句固定 ~1.3s 的载模型**，
解码耗时与音频长度成正比（实测 ≈ **0.25~0.27 × 时长**）。所以对外报数要说
"省掉每句 1.3s；短口令（~0.5s）常驻后 0.1~0.2s，按住说一句 2~3s 的话 0.6~0.9s"，
**别**说成"4 秒的话 0.1 秒就能出"。（0.08~0.15s 那个数应该来自另一台机器/另一段更短的音频。）

**探针**: `%TEMP%\wg-r72-wrapper-serve-probe.py`（21 项，只测 wrapper：一次性协议纯净 / ready 字段 /
两句文本正确 / 坏路径不退出 / 第二次更快 / `exit`+EOF 干净退出 / stdout 每行都是 JSON）、
`%TEMP%\wg-r72-app-sherpa-probe.py`（14 项，走**应用自己的** `voice.recognize()`：配置认得出 /
助手是活着的子进程且 ready / 第二句更快 / `shutdown()` 不留孤儿）。

**已办（第七十三轮）**: wrapper 作为**参考副本**收进仓库 `wgime-py-pure\voicepack\wgime-stt.py`
（同一目录还有 `README.txt`: 两种模式、装机步骤、实测数字），并加了守卫
`wgime-py-pure\tests\voicepack-sync-test.py`（13 项）:
- A 参考副本存在/可编译/协议要点齐全；
- B 取 `package\config.txt` 的 `stt_script`（或 `--installed <路径>`）与参考副本比：
  先比字节，再比**协议字段集合**（源码里所有 `'key':` 的集合 + `emit({...})` 打出去的字段）——
  **集合不同就 FAIL**（少一个 = 协议丢了；多一个 = 只改了一侧）；文件不存在 = SKIP（没装语音包的机器不算错）；
- C 有模型时真起一次 `--serve` 只验协议（ready / `ping` 立刻回 / 坏 wav 回 `ok=false` 且不退出 / `exit` rc=0）。
**守卫有效性自证**: 把在用副本里的 `audio_ms` 字段整个改掉 → **3 条失败、rc=1**；还原后 13/13。

## §D9 第六十七轮：keyfix 的"牺牲字符"必须不可见

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

### §D11.2 第六十九轮补充：默认改成**关**（用户反馈"影响到鼠标移动"）

**用户报**："跟着鼠标跑的那个小圆点可以拿掉吗？好像影响到鼠标移动了。"

**先量清楚到底是什么在影响**（真窗口实测，探针 `%TEMP%\wg-dot-mouse-probe.py`）：

| 查什么 | 结果 |
|---|---|
| 外框扩展样式 | `0x080800A8` = `NOACTIVATE / LAYERED / TRANSPARENT / TOOLWINDOW / TOPMOST` **全都在** |
| `WindowFromPoint(圆点中心)` | 返回**底下的窗口** → 鼠标事件**确实穿透**（点击/悬停都没被它吃掉）|
| 落点 vs 算出来的位置 | 偏差 **0px**（没有 DPI 错位）；圆点矩形也**不含光标** |
| 每拍开销 | `Tk.geometry()` **1.95ms/次**；直接 `SetWindowPos` **0.68ms**（快 **2.9 倍**）|

→ 它**不是"抢事件"**，而是"**每 32ms 挪一次置顶窗口**"这份稳定开销：12px 的窗贴着光标每秒挪 30 次、
DWM 每次重新合成，慢机器/远程桌面上就是"鼠标发涩"。**用户的体感是对的，别用"它是穿透的"去驳回。**

**四件事**（都为了"要么别开、开了也别碍事"）：
1. **默认关**：`engine.load_config` 缺省 `statedot=False`，`config.txt` 模板 `statedot = 0`。
   功能一行没删 —— 托盘「选项 → 状态提示点」勾一下、或 config 改成 1 就回来（`statedot = 0` 时**一个窗口都不建**）；
2. **挪窗走 `win.move_topmost()`**（`SetWindowPos` + `NOSIZE|NOACTIVATE|NOSENDCHANGING|ASYNCWINDOWPOS`，
   目标 `HWND_TOPMOST` 顺带保住置顶）—— 别再用 `top.geometry()`；
3. **按住鼠标键期间隐藏**（`win.mouse_buttons_down()`：拖动/框选/调窗口大小正是最碍事的时候，松开下一拍回来）；
4. **光标没动且状态没变 → 一个 Win32 调用都不做**（`main._DOT_AT` 记上次的光标位置；`Dot.color()` 供比色）。

**顺手抓出的两个真问题**：
- `dot.py` docstring 里的 `\w`（`%TEMP%\wg-dot-...`）→ `SyntaxWarning`；改 raw docstring。
- **harness 的两条"默认值"断言其实在读用户那份 `package\config.txt`**：main.py 里
  `APP_DIR = dirname(DICT_DIR)`（`main.py:107`），而 harness 把 `WGIME_DICT_DIR` 指向 `package\dicts`
  → `ns['CFG']` 来自**用户可编辑的活文件**（实测那份里 `followcaret`/`statedot` 都是 1）。
  于是"默认关"这种断言会**随用户配置变红/变绿** —— 测的不是代码默认值。改成
  `sys.modules['engine'].load_config(<不存在的路径>)` 取代码默认值再断言（注意 main.py 里
  `engine` 这个名字被 `Engine` 实例占了，所以要用 `sys.modules['engine']`，别用 `ns['engine']`）。

**回归**：`wgime-py-pure\tests\dot-mouse-test.py`（**24 项**）：A 组纯函数 10 项（颜色/录音优先/取模、
四边翻转、负坐标副屏、离谱坐标钳制 + **遍历 5 种工作区 × 全部光标位置**的不变量"圆点永不盖住光标、
永不越出工作区"）；B 组真窗口 14 项（样式写在外框上、`WindowFromPoint` 确认穿透、落点无 DPI 偏差、
`move_topmost` 真挪且样式没被重置、hide/再显示/颜色/destroy）—— **没有交互桌面就整组 SKIP**（退出码仍 0）。
harness 33 → **39 项**（+代码默认关、+光标没动不重复摆窗、+状态变了才重绘、+按住鼠标键隐藏、+松开回来）。

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

## §D12b 第七十轮：内嵌「漏依赖」这一类 bug（pystray → six）

> 编号撞车说明：本节原先也标成 §D12，而 `AGENTS.md` §38 与 CHANGELOG 里引的 **§D12 指的是"第五十八~六十二轮
> 语音真因"那一节**（文件下方）。第七十轮这节改 **§D12b**，内容一字未动。

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

## §D14 第七十四~七十六轮：语音"点击落点"(`voice_click`)、流式 ASR(`voice_engine = stream`)、测试自足性

> 三个参考实现（PhoneMic / MouthWrite / IMEDot）逐文件读过的结论在 **§D11** 末尾那张表里；本节只写
> 由它引出的这两个功能、以及踩到的坑。通信/协议类细节都配了**不依赖外网**的回归（本机网络常年时通时断）。

### 1) `voice_click` —— 点击落点（第七十四轮）
**动机**（来自 MouthWrite 的结论）: 进程外工具**没法可靠知道**"文字该进哪个输入框"。MouthWrite 最后把
"自动粘贴到光标处"撤掉了（`_finish_with_paste` 注释: "不再自动粘贴到输入框"），改成**只进剪贴板 + 等用户点
鼠标左键**，再 `QTimer.singleShot(150)` 发 Ctrl+V。**那一下点击本身就是最可靠的目标选择**。

**流程**: 识别完 → `win.clipboard_set(text)` → 候选条提示「点目标输入框粘贴 / Esc 放弃」→
`win.click_watch_start()` 等下一次**左键按下** → 命中即收钩 → 150ms 后 `inject(text)`（复用现有上屏链:
剪贴板/keyfix/UIPI 全兼容）。配置键 `voice_click`（白名单，默认 0；只在 `voice_auto = 0` 时有效）。

**三条刻意的设计**:
* **不吞这次点击**（`CallNextHookEx`）—— 这一下点击正是"聚焦目标"的那一下；
* 命中后**立刻收钩**（在回调前）—— 回调里再点一次不会被吃第二次；
* 取消路径全收钩: Esc / 新录一句 / 退出 / 切模式（取色器那次"✕ 关窗没收钩, 之后鼠标左键被吞"的教训）。

**踩到并修掉的两个静默 Win32 坑**（写探针才发现的；`tools.py` 取色器里同样存在, 一并修）:
| 坑 | 症状 | 修法 |
|---|---|---|
| `GetModuleHandleW` 没设 restype | 64 位 HMODULE(`0x7FF6…`) 被截断成负数 → `SetWindowsHookExW` 返回 0 且**不报错** → 钩子根本没装上 | `restype = c_void_p` + `argtypes=[c_wchar_p]`；失败写 always-on 日志 |
| `CallNextHookEx` 没声明 argtypes | 第 4 个参数(LPARAM) 按默认 `c_int` 转换 → `OverflowError: int too long to convert` → 回调抛异常 → **那次点击丢掉** | `restype=c_ssize_t` + `argtypes=[c_void_p,c_int,c_void_p,c_void_p]` |

判据: `%TEMP%\wg-r74-hook-diag.py`（截断 / NULL / 真句柄三种装钩对比）+
`wgime-py-pure\tests\voice-click-test.py`（真钩子 7 项，含"点一下必须落到窗口上" —— 探针建 scratch 窗口接
`<Button-1>`，并先把光标挪到自己窗口、结束还原，绝不点用户界面）。

### 2) `voice_engine = stream` —— 流式 ASR（第七十五轮）
**动机**: 其它后端都是"整句识别完才出结果"，用户对着候选条只见"识别中…"（坏网络下十几秒黑箱）。
MouthWrite 那种形态是**边说边出**。

**实现**: POST OpenAI 兼容 `chat/completions`（`stream: true`，音频 base64 塞 messages）：
* **两种 payload 按 URL 自动选**（对齐 MouthWrite 的关键字探测）：含 `dashscope`/`aliyuncs` →
  `input_audio` + `asr_options.enable_itn`（百炼 `qwen3-asr-flash`）；否则 `audio_url`（自建 vLLM Qwen3-ASR）；
* `voice._http_stream()` = **`_http_post` 的同一套网络语义**（代理顺序 / 连接层同路重试 / 服务端回过话不重发 /
  每条路重建 `Request` / 自动模式记住可用路径），只把"一次读完"换成"按行读 SSE"；
* 每段 `choices[0].delta.content` 累积 → `on_delta` → 主线程 `VOICE_Q.put(('partial', 文本))` →
  `_voice_drain` 更新 `_VOICE['partial']` → `show_page` 在 busy 时显示实时文本；定稿清 `partial`；
* 健壮性: `[DONE]` 收尾、坏 JSON 行/心跳注释跳过、**服务端忽略 stream 时整段 JSON 再解析**、
  `<|zh|>` 之类标签剥掉（`clean_asr_text`）；`_http_stream` 迭代出来是 **bytes**，要先 decode（探针抓过这个）。

回归 `wgime-py-pure\tests\stream-asr-test.py`（22 项，**本地假 SSE 服务器**，不依赖外网/不需要 key）:
增量按序 + 越接越长 / 两种 payload 形状 / 非流式兜底 / HTTP 500 只发一次 / 坏行跳过 / 黑洞端口明确报错 /
`_dispatch('stream')` 真路由 / 缺 `stt_url` 与坏 wav 的提示 / `clean_asr_text` 单元断言。
**线上链路尚未验证**（没有百炼/vLLM 的 key）—— 要用就 `voice_engine = stream` +
`stt_url`/`stt_key`/`stt_model`；本机默认仍是常驻 sherpa（离线）。

### 3) 两条工程教训
* **`git checkout -- wgime-py-pure\dist\wgime-py.py`（§30 那条）只适用于没改内嵌模块时**。本轮改了
  `main.py/win.py/tools.py/engine.py` 却习惯性回退 dist → `dist-sync` 立刻报 `main.py embedded match: False`。
  改了内嵌模块**必须重建 dist 并提交**。
* **运行时配置的重建脚本要跟着功能走**: 旧的 `%TEMP%\wg-r66-apply-cfg.py` 是云端方案，构建后跑它会把
  `voice_engine = sherpa` / `stt_script` 覆盖掉（本轮就中了一次，`voicepack-sync-test` 从 13 项掉到 4 项 →
  立刻暴露）。现在用 `%TEMP%\wg-runtime-cfg.py`（权威版本：sherpa + `stt_threads=8` + `statedot=0` +
  `followcaret=0` + `voice_click=0`），**每次 build-package 之后只跑它**。

### 4) 第七十六轮：**测试自己**的两处缺陷（拉完第七十二~七十五轮后跑全量回归才暴露）
两条都不是产品代码的错，但都会污染以后每一次回归 —— 一条让整份测试**在没跑之前就红**，一条让测试**看现场脸色**。

**① `stream-asr-test.py` 依赖机器上一份不存在的录音**
* 第七十五轮把 `WAV` 写死成 `C:\Tools\wgime-local-asr\portable\test-zh.wav` —— 本机**没有** `portable\`
  这个目录（那里只有 `models\` 与 `wgime-stt.py`），于是 A/B 两组在"读不到录音文件"上全红；
* 更糟的是第 120 行 `p = SEEN[-1][1]`：**服务端一条请求都没收到 → IndexError traceback 崩掉**，
  而不是干净地 FAIL（规矩：测试要么 OK 要么 FAIL，不能中途炸 —— 与第六十九轮"桩不能比真的更宽容"同源）；
* `PURE` 也写死 `C:\Tools\wgime\wgime-py-pure`，只有本机这个 checkout 碰巧对（Windows 大小写不敏感才没炸）；
  同病的还有 `voice-click-test.py` 的 `sys.path.insert(0, r'C:\Tools\wgime\wgime-py-pure')`。
* **修法**（三条，都不依赖机器）：
  1. 流式这条路只要求"能从文件读出字节再 base64"，**内容无关** —— 测试开头用 `wave` 自己搓
     0.2s / 16kHz / 单声道 / 全 0 样本的 wav 到 `tempfile.gettempdir()`；
  2. `PURE = dirname(dirname(abspath(__file__)))`（测试在 `<pure>\tests\` 下）；
  3. 加 `last_seen()`（空则 `{}`），所有"取最后一条请求"的地方走它；顺手把**恒真断言**改真：
     原来 `check('Authorization 头带上 key', SEEN[-1][0] and True)`（`SEEN[-1][0]` 是 path，非空即真）永远 OK ——
     现在服务端把 `Authorization` 头记进 `SEEN` 第三元，断言它**正好 = `Bearer sk-fake`**。
* 结果 `22/22`（原 3 FAIL + 1 crash）。

**② `tests\pure-state-harness.py` 的"状态提示点"段会被屏幕前的人干扰**
* 后台跑全量时**恰好红了 3 条**：`ime 模式 tick 后圆点已显示` / `状态变了(模式) -> 重新上色` /
  `松开之后 -> 自动回来`；前台单跑 4 次全绿。**不是随机**：`_dot_tick`（第六十九轮）读的是**物理**
  `win.mouse_buttons_down()` 与**真实** `win.cursor_pos()`，**按住左键时圆点本来就该隐藏** ——
  那一刻正好有人在 Web GUI 里点鼠标。同理"光标没动、状态没变 -> 不再摆窗"是**靠真实光标恰好没动蒙过的**。
* **修法**：这一段把这两个真实输入**打桩**（存旧值、段尾还原；"按住/松开"两种真实语义仍由显式打桩测），
  并补一条**正向断言** `光标动了 -> 重新摆窗`（只测"没动就不动"是半个断言）。
* **守卫有效性自检**（"一个不会失败的测试等于没写"）：把 `_dot_tick` 的两处保护分别改坏跑一遍 ——
  去掉"光标没动才跳过"（`_DOT_AT[0] == p and` 删掉）→ **恰好 1 条红**（新断言）；
  去掉"按住鼠标键就隐藏"（`if win.mouse_buttons_down():` 改 `if False and ...`）→ **恰好 1 条红**（隐藏那条）；
  还原后全绿。脚本：`%TEMP%\wg-mutate-dot.py`（改前先 `git show` 备份、跑完写回，别手改产品文件）。
* 教训固化成 `AGENTS.md` §4 那条硬规则：**测试要自足**（机器绝对路径/外部 fixture 一律现造）+
  **读真实输入的断言必须打桩**。

## §D15 第七十六轮补充：发布资产预检（v1.2.13 泄漏事故复盘）

> 这一节记的是**发布流程**上的一个真事故：v1.2.13 的 python 资产里带着开发机私用 `config.txt`（含一把
> 硅基流动 API key）。它跟代码/测试都无关，但"只有校验能拦"这条结论要留在这儿。

### 1) 事故是怎么发现的
拉完远端第七十二~七十五轮、准备发版时，按 §7 流程先看"python 包取自哪里"：
`tests\build-release-assets.ps1` 的 `$pkg = wgime-py-pure\package`，而 `Get-ChildItem` 一看，
`package\config.txt` 是 **11865 B、12:12 修改**，里面 `voice = 1` / `voice_engine = sherpa` /
`stt_script = C:\Tools\wgime-local-asr\wgime-stt.py` / `stt_python = C:\Users\watl\...python.exe` ——
**那是本机在用的活配置**（`build-package.ps1` 会用仓库根模板覆盖它，但本机跑过脚本/改过配置后又变回去了）。
再下线上 v1.2.13 的 python 资产（25598416 B）核对：里面的 `config.txt` 是 **12859 B**，`voice = 1`、
`stt_url = https://api.siliconflow.cn/v1/audio/transcriptions`、
**`stt_key = sk-…（64 字符真 key）`**、`stt_cmd`/`stt_script` 指向本机路径 —— 泄漏已经发生（资产自
2026-09-17T01:44Z 起公开可见，`download_count = 1`，是本机回验时下的那一次）。
顺手核了历史版本：v1.2.12 的 `config.txt` 3303 B、v1.2.11 的 2385 B，**都是干净模板**
（0 个 `sk-`、0 条启用的本机 `stt_*`）—— 只有 v1.2.13 这一个版本中招。

### 2) 处置（三步）
1. **修**：`powershell -File wgime-py-pure\build-package.ps1` 重建 `package\`（`config.txt` 回到仓库根模板，
   12492 B）+ `%TEMP%\wg-restore-baseline-zip.py` 把 `THIRD_ZIP_B64` 还原成 HEAD 基线
   （`build-package.ps1` 不是可复现构建，见 §30）→ 确认 `git status` 对 `dist\wgime-py.py` 干净、
   `Copy-Item dist\wgime-py.py package\wgime-py.py`（两者必须逐字节相等，发布脚本自己有这道 hash 守卫）
   → `tests\build-release-assets.ps1 -Version 1.2.14` → `tests\publish-release.ps1 …`。
2. **补**：新增 `tests\release-assets-check.py`（本地、不联网、退出码即判据）。判据见 `AGENTS.md` §7。
   **守卫有效性自检**（这条规矩的又一次实践）：
   * 干净资产 `.release-stage-v1214` → **27/27 全绿**；
   * 拿**那份泄漏的** `wgime-v1.2.13-python.zip`（存在 `%TEMP%\wg-rel\`）跑 → 13 项里 **5 项红**：
     `config.txt 与模板逐字节一致`(12859 vs 12492)、`没有 API key`、`没有启用的本机 stt_* 项`，
     外加两条"bat/ps1 文件存在"（那个目录里只有 python zip）——**该红的都红了**；
   * 报错里的 key 一律打码（`sk-***MASKED***`），别让检查器自己变成第二个泄漏点。
3. **清**：把 v1.2.14 的 python zip 复制成 `wgime-v1.2.13-python.zip`（内容 = 干净包），
   用 `publish-release.ps1 -Version 1.2.13 -BodyFile <从 API 取回的原文+补记> -AssetsDir <那个目录>
   -TargetSha 56f7ffe…` 走 PATCH + **覆盖同名资产**（脚本会先 DELETE 旧资产再上传）。
   **`-TargetSha` 必须显式给 v1.2.13 当时的 commit**：脚本默认用本地 HEAD，会给出一条
   "local HEAD != origin/master" 的警告，而这次我们**不是**要移动 tag。
   改完回验：python 资产 25598416 → 25598298 B（created 时间变成新的）、bat/ps1 **一字未动**、
   body 与本地逐字符一致、tag 仍 `56f7ffe`。

### 3) 可复用的命令/脚本（都在 `%TEMP%`，换机器要重写）
* `wg-fetch-release.ps1`：按 tag 取 release JSON + 下载指定资产（PS `HttpWebRequest`，**python urllib 在本机
  经代理会 SSL EOF**，别用）。
* `wg-verify-release.ps1` / `wg-verify-release2.ps1`：publish 之后的线上回验（资产 SHA256 / 内层文件 /
  body / tag）。**注意 part1 里 `[IO.Compression.ZipFile]::Open((New-Object IO.MemoryStream(,$bytes)),'Read')`
  这种写法在 PS 5.1 会解析成 `Open(string,…)` 去磁盘找文件** —— 落盘再 `OpenRead($path)` 最省事。
* 中文只许出现在**数据文件**里：`wg-fetch-body.ps1` 第一版把中文写进 `Write-Host`，PS 5.1 按 ANSI 读 `.ps1`
  → 直接把整个脚本解析坏（§2 那条规矩的又一次实锤）。


## §D16 第七十七轮：PDF 工具（内嵌纯 Python `pypdf` + `plugins/pdf.py`）的调研与实测

### 1) 为什么不能照抄 itools（结论先写死）
`C:\Tools\ITools\ITools.bat` 的 PDF 是 **WebView2 + pdf.js + pdf-lib**：整份 HTML UI 塞进 Edge 内核
(`NavigateToString`)，`###PDFJS:…###` 分段 base64 内嵌、解包到 `%LOCALAPPDATA%\itools\pdfjs`、
`SetVirtualHostNameToFolderMapping` 挂虚拟主机加载；C# `PDFBridge` 只做原生对话框/文件读写，九个面板
(compress/split/merge/analyze/rotate/delete/extract/images/edit) 全在 JS 里算。**wgime 没有 WebView2、
也不能要求用户装 Edge Runtime**，所以那套一行都抄不过来 —— 只有"分段 base64 内嵌 + 解包"这个**做法**
可以借（wgime 早有同类机制），代码本身不行。

### 2) 依赖可行性的实测台账（`%TEMP%\wg-pdf-feas\`）
| 项 | 实测 |
|---|---|
| pypdf 6.19.0 | wheel `py3-none-any`，60 个 `.py`，**0 个 `.pyd/.so`**，BSD-3-Clause，`Requires-Python >=3.9`，classifier 列到 **3.14** |
| 强制依赖 | **无**。`typing_extensions` 只在 `python_version < '3.11'`，且源码里是 `if sys.version_info >= (3,11): from typing import Self else: from typing_extensions import Self` |
| 3.13/3.14 移除的 stdlib | 全量 grep `imghdr/sndhdr/cgi/pipes/telnetlib/audioop/distutils/imp/…` → **0 处**（匹配到的都是 `chunk`/`crypt` 这类词内子串） |
| 隔离自检 | `python -S -E` + 只挂内嵌 zip（`site-packages` 不在 sys.path）：读/页数/元数据/拆分/合并/旋转/删页/取字 全通 |
| import 成本 | **zipimport 冷启 865 ms**（同一份源码放普通目录 388 ms，第二次 0 ms）→ 插件必须懒 import + 窗口一开后台预热 |
| 体积 | 源码 1,708,063 B → zip **380,633 B**（4.5×）→ base64 **+507,511 字符** → dist `619,381 → 1,137,049 B`（605 KB → 1.11 MB） |
| 踩到的构建陷阱 | 用**目录遍历**打包会把 `__pycache__/*.pyc` 一起收（源码 1.71MB→3.72MB，zip 0.38MB→**1.12MB**）。`collect_thirdparty` 走 `spec.origin` 读 `.py` 本来安全，但仍加了死断言 + 回归断言 |

### 3) 能力边界（别在文档/UI 里吹过头）
* **结构压缩没用**: `compress_content_streams` + `compress_identical_objects` 实测 —— 真实图片型
  PDF(1900.6 KB) → 1874.9 KB（**99%**）；小的文字型 PDF(1359 B) → 1452 B（**107%，反而变大**）。
  要真能缩小只能栅格化重排（P2）。
* **取文字看 PDF 类型**: 手写 fixture(文字型) 精确取到；本机两份真实 PDF（都是
  `Microsoft: Print To PDF` 产物，1.9MB/1.4MB）**取到 0 字符** —— 图片型。所以 UI 要如实报
  "可能是扫描件"，别把 0 字符当成功。
* **加密**: AES → `DependencyError: cryptography>=3.1 is required`（`cryptography` 在 `_THIRD_SKIP`，
  是 C 扩展）；**RC4-40 / RC4-128 走 `_crypt_providers/_fallback.py` 纯 Python 回退能开**
  （实测 `decrypt()` 返回真值且取到原文）。
* **加文字**: `PageObject` 只有 `merge_page/merge_transformed_page/merge_resources`，
  `dir(PdfWriter)` 里**没有任何字体嵌入 helper** → 拉丁文还能自己拼 content stream + 标准 Helvetica，
  **中文要自己写 CIDFontType2 子集嵌入**。性价比最低，本轮不做。

### 4) P2（WinRT 那条腿）已验证可用 —— 探针结论
`render3.ps1`（PS 5.1，`powershell.exe -NoProfile -ExecutionPolicy Bypass -File`）：
```
load 2 pages           99 ms
page size              1587 x 1123 pt
render png 1240px      146,065 B / 626 ms
render jpg 1240px      110,587 B
render 2 pages as jpg  196,268 B  = 原件的 9.7%   (原 1,900,600 B)
WinRT PdfPage text API NONE
Windows.Media.Ocr      AvailableRecognizerLanguages = en-US, zh-Hans-CN
```
三个必须记住的坑（都真踩过）：
1. PS 5.1 里 WinRT 类型**必须**写全 `[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]`，
   光写 `[Windows.Storage.StorageFile]` 报 `Unable to find type`；
2. `PdfPage.RenderToStreamAsync()` 返回的是 **`IAsyncAction`** —— 要用 `AsTask` 的**非泛型**重载
   (`GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'`)；塞进泛型 `AsTask<T>` 会报
   `Object of type 'System.__ComObject' cannot be converted to type 'IAsyncOperation`1[…]'`。
   `GetFileFromPathAsync` / `LoadFromFileAsync` 是 `IAsyncOperation<T>`，才走泛型那条；
3. `PdfPageRenderOptions` **没有 `JpegQuality`**（只有 `DestinationWidth/Height`、`BackgroundColor`、
   `BitmapEncoderId`、`SourceRect`）→ 质量档要再用 `System.Drawing` 的 JPEG 编码器重编一次。
设计: 一个**常驻 PowerShell 子进程 + JSON 行协议**（照抄第六十三/六十四轮 `_WarmSrv` 那套：源码走环境
变量不落盘、stdout 只许 JSON、父进程退出=stdin EOF=自退；key = (宽, 编码, 质量)）；渲染 ~340 ms/页@1240px，
100 页要进度条 + 可取消。压缩必须让用户显式选"结构无损"还是"转图片(有损)"，不做 itools 那种自动档。

**落地后（第七十七轮 P2 已完成）的实测/实现要点**：
* 交付方式: 源码**内嵌在 `plugins/pdf.py`**（`_W32_SRC` 常量），运行时经环境变量
  `WGIME_PDFW32_SRC` + `powershell -NoProfile -STA -ExecutionPolicy Bypass -Command "iex $env:WGIME_PDFW32_SRC"`
  —— **不落盘**（没有 sidecar .ps1）、命令行只有 **89 字符**（脚本 7.3KB 不进命令行）。
* 实测: spawn 28 ms; **就绪（spawn→能用）1.2~1.8 s**; 渲染 **~217 ms/页**@1240px;
  OCR 1 页 ~0.3 s; 渲染出的图**写到磁盘**是"渲染到 `InMemoryRandomAccessStream` 再用
  `System.IO.WindowsRuntimeStreamExtensions::AsStreamForRead` 拷贝"（`DataReader` 那条路要处理
  `IAsyncOperation<uint32>`，更绕）; OCR 走 `BitmapDecoder.CreateAsync → GetSoftwareBitmapAsync → OcrEngine.RecognizeAsync`，
  全程内存、不落临时图。
* 协议: 请求 `{id,cmd,...}`，回包 `{id,ok,...}` + `{id,progress:{i,total,page}}` 进度行，父进程按 `id` 配对
  （串包/过期回包直接丢）；**取消的语义 = 杀掉助手**（单线程助手渲染途中读不到 stdin），下次调用自动重启
  —— 回归里专门有一条"杀掉后能自动重启"，否则取消一次就把功能永久废掉。
* 有损压缩的最后一棒是**纯 Python** 的 `build_pdf_from_jpegs`（JPEG 以 `/DCTDecode` 原样内嵌 + 页尺寸取原
  mediabox），**不需要 pypdf 的图片 API，也不需要 pdf-lib**。`tests/pdf-test.py` 用**手搓的 SOF0 字节流**
  测 `jpeg_size`（尺寸解析只读标记、不解码像素，所以 fixture 完全自足）。
* **`.ps1` 里放中文会要命**（§2 那条规矩的第 N 次实锤）：助手第一版带中文注释/中文报错，`-File` 跑直接
  ParserError（PS 5.1 按 ANSI 读 .ps1）。现在助手**纯 ASCII**，面向用户的中文提示全在 Python 侧。
  走"环境变量 + `iex`"时环境块是 UTF-16、没有 ANSI 解码问题，但**纯 ASCII 更省心**。
* **别用子进程自己报的 boot_ms**: 它只算"PS 起来之后脚本初始化"那一段（0.1 s），用户真等的是
  powershell.exe 冷启 + WinRT 初始化（1.2~1.8 s）。父进程侧用 `spawn 时刻 → 收到 ready` 才诚实。

### 5) 插件形态的判据（本轮最重要的可复用结论）
带 UI 的插件必须写成 **`plugins/*.py`**：`main.load_py_plugins()` 用 `exec_module` 收进 `PLUGINS`，
上屏编码命中后 `run_launcher()` 直接调 `run()` —— 那是 **Tk 主线程**，能直接用宿主 `ui.make_window`。
`plugins/*.txt` 的 `[python]` 块**不行**：它是 `python.exe <临时 .py>` 子进程（`_run_python_block`，
默认 60s 熔断），`sys.path` 里没有单文件的 `thirdparty.zip`，import 不到内嵌的 pypdf，也开不了窗口。
（反过来, 需要"崩了也不拖垮输入法"的重活才应该用 `[python]` 块。）

### 6) 给"带 UI 的插件"写回归时的一个陷阱（第七十七轮踩到，会假红）
子线程 `win.after(0, …)` 回主线程改控件是插件里**唯一**允许的跨线程 UI 路径（所有操作日志/进度都走它）。
但**用 `root.update()` 循环驱动事件来测它必假红**：`_tkinter` 会以
`RuntimeError: main thread is not in main loop` 直接拒绝子线程的 `createcommand`（`Tkapp_CreateCommand`
只在主线程真的在 `mainloop()` 里、`dispatching` 为真时才放行）。第一版探针就是这么被骗的 —— 看着像
"插件的日志路径坏了"，其实只是测法不对。**判据**：UI 断言必须**真跑 `mainloop()`**，用主线程里排的
`root.after(5000, 收网)` + `root.quit()` 退出。`tests/pdf-test.py` 最后 5 项就是这么写的（无桌面 → 整段 SKIP），
另外用 AGENTS §42 的审计法断言"26 个控件没有一个越出窗口"。

**补（用户当场发现的真 bug）**：**"越出窗口"的审计查不出"控件互相压住"**。P2 把第 3 行操作磁贴放在
`y=270`，而「页码范围/角度」那行还在 `y=272` —— 39 个控件全在窗口内、越界审计全绿，两行却叠在一起。
现在 `tests/pdf-test.py` 的 UI 段多加一条**两两不重叠**断言：遍历 `content` 的直接子控件，矩形
**真相交**才算冲突（**贴边不算** —— `ui.console_text` 的 Text 与它自己的滚动条本来就是贴着的），
命中就把两对坐标打进失败信息。守卫自检照规矩做了：**先拿坏布局跑 → 1/74 红**（打印出
`(12,272,62,32)` vs `(12,270,196,32)`），改完布局 → **74/74**。
**规则**：这类窗口全用 `place()` 显式坐标（没有布局管理器兜底），所以"出界"和"重叠"**两条都要断言**；
窗口最终布局记在插件顶部注释里（三行磁贴 194/232/270、参数 310/348、日志 390/h140、底栏 540、窗口 640×626）。

**再补（2026-09-20，用户截图反馈的两个问题）**：
* **`ui.flat_button` 不能用来做"选中态"**：它的 Enter/Leave/Press/Release 处理器把 `bg` 恢复到
  **创建时**那一份（闭包绑死）。事后 `.configure(bg=ACCENT, fg='white')` 的按钮被 hover 一次就复位成
  CARD 白底 + 白字 = 文字消失（'90°'/'PNG'/'自动' 三个默认项实测全看不见）。修法是插件内
  `_toggle_btn`（颜色每次重画都从状态现算）。**同类存量**: `plugins/chat.py:156` 同写法，待修。
  **测法细节**: 模拟 hover 时**只发 Enter/Leave、别带 Release** —— 带上 Release 的话 flat_button
  会"先复位 bg → 再触发 command → 又把色配回来"，恰好把 bug 盖住；颜色比较用 `winfo_rgb` 解析后比，
  否则 'white' ≠ '#ffffff' 会漏判。
* **预览**: `preview_first_page()`（pypdf 读 mediabox 算贴框缩放 → WinRT 渲染 → `tk.PhotoImage`，
  保引用防 GC、token 丢弃过期结果）。Tk 8.6 的 PhotoImage **原生支持 PNG**，不需要 Pillow。


## §D17 第七十八轮：中文全角标点映射表（标准输入法逻辑）与两个测试陷阱

### 1) 完整映射表（C# `MapPunct` 与 python `map_punct` 逐条一致，交叉核对 7/7）

| 物理键 | 裸键 | Shift | 备注 |
|---|---|---|---|
| `` ` ``(0xC0) | · U+00B7 | ～ U+FF5E | |
| `1`–`0`(0x31..0x30) | 数字/候选键 | **！ ＠ ＃ ￥ ％ …… ＆ ＊ （ ）** | Shift 只在**空闲**时映射；组字中被数字分支吞走选候选 |
| `-`(0xBD) | 放行 | —— U+2014×2 | |
| `=`(0xBB) | 放行 | ＋ U+FF0B | |
| `[`(0xDB) | 【 | 『 U+300E | Shift 以前放行 |
| `]`(0xDD) | 】 | 』 U+300F | Shift 以前放行 |
| `\`(0xDC) | 、 | ｜ U+FF5C | Shift 以前放行 |
| `;`(0xBA) | ； | ： | |
| `'`(0xDE) | ‘’ 交替 | “” 交替 | `_sq_open`/`_dq_open` 两侧同名 |
| `,`(0xBC) | ， | 《 | |
| `.`(0xBE) | 。 | 》 | |
| `/`(0xBF) | 放行 | ？ | 裸 `/` 保持半角是**有意**的 |

**决策记录（别再来回改）**：
* `Shift+4` = 全角 `￥`(U+FFE5)，**不再是**半角 `¥`(U+00A5) —— 与整套全角表一致，也是标准输入法输出；
* `Shift+8` 给 `＊`(U+FF0A 全角星) 而不是 `×`（保持 ！＠＃￥％ 这个全角系列的一致性；要 `×` 走 vf 面板）；
* `Shift+6` = `……`(U+2026×2)，`Shift+-` = `——`(U+2014×2)，都是**两个码元**（`inject`/OnPunct 本来就按字符串注入）；
* 裸 `/`、裸 `-`、裸 `=`、裸数字、Shift+字母 = 透传半角（`hook.py` 的吞键集与 C# `MapPunct` 的 null 一一对应）；
* `cnpunct=0`（半角）时 hook 整个标点分支不吞，全透传；`_HALF_PUNCT` 只是组字中防吞键后的 ASCII 回退表；
* `handle_punct` 的既有语义不动：组字中按标点 = 先上屏首候选(记 recent 链、不强化词频)再上屏标点。

### 2) 两个"测试与代码同错"的陷阱（第七十六轮那条规矩的又一例）
* **共享的错误数据源会同时污染实现和断言**：数字行数组第一版按物理键序 `1..9,0` 写
  `('！','＠','＃','￥','％','……','＆','＊','（','）')`，而索引用的是 `vk-0x30`（0=Shift+0）——
  代码和测试循环用了**同一个错 tuple**，循环断言全绿（Shift+1 实际给了 ＠）。是被**独立推导**的
  单点断言（`Shift+4` 必须是 ￥、不是 ¥）抓出来的。**规则**：映射表这类"代码里一张表"的东西，
  测试至少要有几条**不抄表、手写期望**的单点（本轮加了 `Shift+1→！`）。
* **有状态的被测函数会污染后续用例**：引号交替（`‘’‘’…`）放在表循环后面测时，表循环已经把
  `‘’` 消耗过一对，断言顺序不同结果就不同。交替断言**前后都显式复位** `_sq_open/_dq_open` —
  测试要自足，不许被前面的段污染（与第七十六轮"打桩要在段尾还原"是同一条）。

### 3) hook 吞键矩阵的常驻化
以前 hook 的吞键判定矩阵只活在 `%TEMP%` 探针里（第十二轮 89 例）。本轮把关键 24 组常驻进
`tests/pure-state-harness.py`（伪造 `KBDLLHOOKSTRUCT` + 假 `_key_state` 直调 `hook._proc`，
断言 rc 与 EVENTS 内容；段尾还原 `_key_state`/ACTIVE/COMPOSING/PUNCT 并排空 EVENTS）。
覆盖：空闲 Shift+数字吞(带 0x200)、组字中 Shift+数字按数字吞(不带)、裸 `/`/`-`/`=` 透传、
cnpunct=0 全透传、未激活全透传。


## §D18 第七十九轮：双模式插件（`plugins/*.py` 既能被宿主装载，也能 `python xxx.py` 独立运行）

**用户约定全文在 `docs/WGIME_插件规范.md` §8.7**；这里记实现的细节和坑。

### 1) 为什么"文件头"必须放在第一个宿主 import 之前
插件的 `import ui`/`import engine`/`import win` 大多在**模块级**（`calc.py` 第 19 行就是 `import ui`）。
独立跑 `python plugins/calc.py` 时 `sys.path[0]` 是 `plugins/`，宿主目录(`wgime-py-pure/`)不在里面，
`import ui` 直接 ImportError —— **而且文件尾的 `if __name__ == '__main__':` 块根本来不及执行**
（模块级的 import 先炸）。所以 sys.path 的修复必须放在**文件头**(docstring 之后、第一个宿主 import 之前)。
宿主装载时 `__name__` 是合成模块名(`wgime_ext_<hash>_calc`)，文件头/文件尾两块都不执行，零冲突。

### 2) 共享引导层 `plugins/_standalone.py`
**名字以 `_` 开头是故意的**: `load_py_plugins` 跳过 `_` 开头的文件(`fn.startswith('_')`)，所以它不会被
当成插件收(没有 CODE/run 也不会报 "plugin must define CODE and callable run()")，但跟插件同目录，
`import _standalone` 找得到。`build-package.ps1` 的 `plugins\*.py` glob 也照拷它进 package。
`standalone(run, title)` 做的事：补 sys.path → 挂内嵌第三方 zip(见下) → 建**隐藏** Tk root →
`run()` 建窗 → **200ms 轮询 `win.winfo_exists()`，窗口关了就 `root.quit()`**(插件窗是隐藏 root 下的
Toplevel，不加这个 watch，关窗后进程还赖在 mainloop 里)；成功打印 `STANDALONE-OK`；
测试钩子 `WGIME_STANDALONE_AUTOEXIT_MS` 到点自动关窗。

### 3) STANDALONE 识别标记
清单常量 `STANDALONE = True`(与 CODE/NAME/PERM 同风格)。`main._py_plugin_meta_static` 用正则
`^\s*STANDALONE\s*=\s*(True|1)\b` 读它(**不 import**)；插件管理器的行格式在 `kind=py` 且有该标记时
显示 `py·双模`(tools.py)。

### 4) 内嵌第三方 zip 的独立运行时定位
`pypdf` 这类内嵌依赖由单文件 preamble 解到 `%LOCALAPPDATA%\wgime-py\site\thirdparty.zip`
(Store Python 虚拟化则 `~\wgime-py\site\`)。`_standalone._add_embedded_zip()` 按这两个已知位置挂进
sys.path；都找不到就不管(插件自己懒 import 时报人话)。**所以"独立运行"要正常工作，前提是这台机器上
单文件至少跑过一次**(把 zip 解出来过)，或宿主机 `pip install` 了那份依赖。

### 5) 回归
`tests/standalone-plugin-test.py`(6 项)：把每个插件当真独立程序跑 —— 子进程 +
`WGIME_STANDALONE_AUTOEXIT_MS=2500` + **`LOCALAPPDATA` 指向临时目录**(绝不碰用户数据) +
`PYTHONIOENCODING=utf-8`，断言子进程打印 `STANDALONE-OK` 且退出码 0；起不了 Tk(无桌面)整体 SKIP。
注意 pdf.py 独立跑会顺带把 WinRT 助手也起出来 —— 进程退出时助手 stdin EOF 自退，无残留。




## §D25 第三方库内嵌（AGENTS.md §12 压缩前的原文）
> 压缩前逐字保留（AGENTS.md 现在只留规则 + 指针）。

12. **纯 Python 第三方库内嵌（零 pip 依赖）**：python 版（`wgime-py-pure`）进程内**不再** import `uiautomation`/`comtypes`（第四十四轮起 0 处；光标跟随改独立 Caret Helper 子进程，见 §17）。内嵌机制：`build-wgime-pure.py` 收集第三方源码打包 zip，运行时解压到 `%LOCALAPPDATA%\wgime-py\site` + `zipimport`。**收集时用 `m.ispkg` 区分**——包写 `__init__.py`、模块写 `.py`（`six` 就是单模块），否则同名模块+包（`comtypes._post_coinit`）会崩。**必须连同声明依赖一起收**（读 METADATA 的 `Requires-Dist`；`Pillow` 在排除表里）—— 漏了依赖时单文件的 import 会**回退到宿主 site-packages**，「构建机恰好装了」就把缺口盖住（第六十九轮 pystray→`six` ⇒ 干净机器上**整个托盘消失**，见 §D12b）。两个守卫: 构建期 `verify_thirdparty_isolation()`（`python -S -E` + 只挂那个 zip，失败**中止构建**）、回归 `python wgime-py-pure\tests\embedded-isolation-test.py`（改内嵌清单后必跑，会断言清单**正好**是什么）。**第七十一轮收紧**: roots 只剩 `pystray`（`comtypes`/`uiautomation` 已删 —— 单文件 898.8 → 573.0 KB）；依赖收集是**传递闭包**（BFS）；**C 扩展内嵌不了**（`.pyd` 与解释器 ABI 绑定：构建机 cp312、用户机可能 cp314），一律走"可用则用、不可用则明确降级"，清单在 `build-wgime-pure.py` 的 `_THIRD_SKIP`（每条写原因）。本机构建只需 `pip install pystray`（读源码内嵌）+ `pillow`（构建期画图标）+ **第七十七轮起的 `pypdf`**（`plugins/pdf.py` 用；base64 **+497KB** → 单文件 1.11MB；边界见 §D16），分发的单文件零依赖。

## §D24 插件 Manifest / 权限 / 隔离（AGENTS.md §16 压缩前的原文）
> 压缩前逐字保留（AGENTS.md 现在只留规则 + 指针）。

16. **插件 Manifest + 权限（wgime-py-pure）**：plugins/*.txt 头部支持 `code/name/desc/version/author/requires/perm`；plugins/*.py 模块级 `CODE/NAME/DESC/VERSION/AUTHOR/PERM`（+`STANDALONE = True`＝双模式/可独立运行，见规范 §8.7）。`plugins.py plugin_meta()` 统一读取（兼容两类）；`perm=network/run/registry/destructive` 的插件运行前 `main._confirm_plugin()` 弹确认，`run_steps` 对 `file-del/reg-set/reg-del/kill` 动词前强确认。旧插件无这些字段默认 `perm=low`，不弹确认。**插件 txt 的登记条件**（第二十一轮）：C# `LoadPlugins` 要求 `code`/`name` 非空**且 `body.Count > 0`** —— 只有头部的半成品**不算插件**（`error='no body'`，别当"解析失败"列出）；头部解析在第一个非头部行停止。别破坏这一权限模型。**③④ 隔离+JSON IPC**：`[python]` 块子进程运行（超时60s）+ JSON IPC 契约（`handle(ctx)->actions`，stdout `@wgime <json>` 行协议）；`run_steps` 的 `run`/`shell` 超时 120s、静默块 300s；别把 `[python]` 块改回同进程 `exec`（会拖垮宿主）。**插件禁用名单（`plugins-disabled.txt`）= 小写文件名**（对齐 C# `DisabledPlugins`）：`main.load_py_plugins` 按 `fn.lower() in disabled` 判定（内嵌插件无文件才退回 code，生产分发不内嵌插件）；`plugins.py load_plugins` 与 `main._read_disabled` 两侧都小写。插件管理器写的也是文件名——**别把装载器改回按 code 过滤，否则「启停」对 .py 插件无声失效**。

## §D23 英汉表 (ec) 与词典模式的核对台账（AGENTS.md §22 压缩前的原文）
> 压缩前逐字保留（AGENTS.md 现在只留规则 + 指针）。

22. **英汉表 (ec) 只在「词典」模式 (mode 3) 参与候选**（C# `AddTranslate`）：`engine.candidates` 的 mode 0/1 绝不能查 ec——实测拼音模式打 `no` 会串出"不/没有/无"并把"弄/浓/农"顶掉。词典模式的 EN 前缀匹配要给**每个命中词的全部释义**（C# `AddCands`），不是只取首个。**第十七轮核对结论（别再"修"）**：mode 3 的候选**集合**与 C# `AddTranslate` 逐条一致 —— EN 精确 + EN 前缀 + CN→EN 反查（`PyDict` 全拼 + `Acro` 简拼 → 每个中文词查 `ce`）；`ce`（CN→EN）由 `build_reverse` 建，与 C# `BuildReverse` 逐行一致（EN ordinal 升序、每词上限 8、去重），实测 **701531 键全等**；mode 3 用**合并**频率视图（`self.freq`，同 C# `fb = ... : Freq`）且**不做** LastPick 置顶（同 C# `lpb = null`）。**唯一差异是 python §14 的频率排序**（稳定排序，探针复算后与 engine 输出逐项相同），不是 bug。**第四十四/四十六轮**：词典模式先取消、又被用户加回（英中查询顺手），现在 `ime.mode` 0..3（`% 4`）；「译文」选项（`config trans`，默认开）另管 —— ① 非词典模式候选挂 `translate_hint` 译文；② **仅当本模式零候选**（`not cands and not exact_wubi and mode < 3`）才 `candidates(buf,3,py)` 兜底；③ 词典模式本身不挂 `→译文`（候选就是译文），反查码照旧。所以本条"有拼音候选绝不查 ec"照旧成立。

## §D21 反向差异清单的完整原文（AGENTS.md §27 压缩前的原文）
> 压缩前逐字保留（AGENTS.md 现在只留规则 + 指针）。

27. **反向差异清单（python 有、C# 没有；别当成 bug 去"对齐"掉）**：`cnpunct` + Ctrl+. 全角标点切换、`F8` 硬开关、`Ctrl+Alt+Q` 退出、候选条主题（dark/light）、`learnk`/`recentk` 与近期热度排序（§14）、剪贴板「粘贴上屏」、`_CLIP_FORCE`（开始菜单/搜索强制剪贴板上屏，C# 在那类 UI 里注入会失败）、tray 的整句/联想/全角标点开关、**「译文」选项（离线词典译文；与「词典」模式并存：模式管逐条翻看，选项管日常打字的提示/兜底）**、造词对话框（C# 是剪贴板直造）、**鼠标旁的状态提示点（`statedot`，第六十九轮，**默认关** —— 见 §D11.2）**。**要往 C# 补需要用户明确要求**：改 wgime.bat 得走 §3 的瘦 DLL + ps1 + 15 项测试整条链。C# 的 `inDialog`（自带模态框期间让按键直通）python 有意不跟进——python 的造词/导入框含文本框，需要输入法可用。
    **第五十二轮登记的两处 hook 差异（用户已确认"保持现状"，别去"对齐"）**：① **Shift 轻拍更保守**：
    Ctrl/Alt/Win 按住时不武装轻拍、且松键有 0.4s 时限（C# 是 `if (shiftTap) shiftArm = true;` 无修饰键门控、
    `WM_KEYUP` 也无时限）；② **字母键判定排在空格/翻页之后**（C# 的 a-z 分支在前面）—— 于是 `config.txt`
    写 `key_first = a` 时 python 把 `a` 当空格确认、C# 当字母入码。两条都更像"python 有意保守化"，
    保持现状；**另外几处 python 有意比 C# 好的**：`_save_cfg`（写 config 失败弹气泡，C# `catch {}` 静默）、
    `calc._to_long` 越界报 `Err`（C# unchecked 给 long.MinValue，`x%3` 算出垃圾值）、
    `_write_config` 保持 config.txt 原有行尾（C# 也保持，但 python 修好了"LF 被改成 CRLF"）。
    **第六十七轮登记**：`keyfix` 的"牺牲字符"python 用 **`U+200B` 零宽空格**（`win.QT_FIX_SENTINEL`），C# 用可见的 `'X'` —— python 有意分歧：牺牲字符一旦没被应用吸收、退格又没生效，可见字符会留在文档里（用户报的"联想时打标点显示 X"），零宽空格则**看不见**。别再改回 `ord('X')`；改这块跑 `%TEMP%\wg-r67-qtfix-probe.py`（16 项，直接查注入事件序列）。

## §D22 read_text 的完整名单与行尾约定（AGENTS.md §28 压缩前的原文）
> 压缩前逐字保留（AGENTS.md 现在只留规则 + 指针）。

28. **用户可改的文本一律用 `engine.read_text()` 读**（`utf-8-sig` → `gbk` → `utf-8+replace`）：中文 Windows 下记事本/编辑器"另存为 ANSI(GBK)"会把 config.txt / tools.txt / plugins\*.txt / pastemode.txt / plugins-disabled.txt / userwords.txt / userdict_*.txt / lastpick_*.txt / assoc.txt 写成非 UTF-8 —— 用 `open(..., encoding='utf-8')` 会**抛 UnicodeDecodeError 直接崩启动**（C# 侧 `File.ReadAllLines(UTF8)` 是替换式解码, 不抛）。`read_text` 只以 OSError 表示不可读，编码问题一律降级；新增读取点照此办理（plugins.py 已 `import engine as engmod` 复用）。**便签文件也在名单里**（第二十三轮）：`notes\*.txt`（便签正文，用户最常拿记事本改）、`notes.txt`（旧版迁移源）、`notes-meta.txt`、`note-color.txt` —— 用严格 `open(..., encoding='utf-8')` 读会抛 `UnicodeDecodeError`，而那里的 `except OSError` 抓不到，结果是**便签窗口打不开/半死**（`_note_win[0]` 已置上，再点只是 deiconify 坏窗口），C# 的 `File.ReadAllText(UTF8)` 则是替换式解码永不抛。**码表与插件也在名单里**（第三十二轮）：`py.txt`/`wb.txt`/`ec.txt`/`trad.txt`/`import_*.txt`（`engine.parse_dict` —— 严格 utf-8 会让 GBK 码表**把启动直接打崩**，且 BOM 会让**第一行读不进来**，所以快路径用 `utf-8-sig`、失败退回 `read_text`）、用户手改过的 `import_*.txt`（`load_import_base`）、插件 `.py`（`main._py_plugin_meta_static`：GBK+coding 声明的插件 python 能跑，严格 utf-8 会让插件管理器列举时崩）。
   **配套：写这些文件时行尾要跟 C# 对齐** —— C# 的 `ImportCodeTable` 写 `import_*.txt` 是 `WriteAllText(..., UTF8Encoding(false))` + `'\n'`（**裸 LF**），python 的 `open(..., 'w')` 在 Windows 上会翻成 CRLF（`import_*.txt` 是入库跟踪文件，被翻成 CRLF 就是整文件 diff）；所以 `engine.write_import_file` 必须带 `newline='\n'`。反之 `config.txt` 是 C# `WriteAllLines`（CRLF），python 默认写 CRLF 正好一致。
   **读的那一侧注意**：`read_text` **不做 universal newlines**，行尾 `\r` 会进值 —— 见 §39。

## §D20 字节级改写与不可复现构建（AGENTS.md §30 压缩前的原文）
> 压缩前逐字保留（AGENTS.md 现在只留规则 + 指针）。

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

## §D27 语音输入的完整原文（AGENTS.md §38 压缩前）
> 压缩前逐字保留（AGENTS.md 现在只留规则 + 指针）。

38. **语音输入（python 独有）**：`voice.py` = waveIn 录音（纯 ctypes，VAD 静音自停，别用已移除的 `audioop`）
    + 五种后端（`voice_engine`：`system` 系统离线引擎（`powershell -EncodedCommand` 内联脚本**不落盘**、结果 base64 回传）
    / `http` Whisper 兼容 / `whisper` **常驻本地 faster-whisper 子进程** / `sherpa` **常驻本地 sherpa-onnx**（首选）
    / `cmd` 外部命令带 `{wav}` / `stream` **流式云端**（OpenAI 兼容 `chat/completions` + SSE；地址仍填
    `stt_url/stt_key/stt_model`，payload 按 URL 关键字选：含 `dashscope`/`aliyuncs` → `input_audio`(+`asr_options`)，
    否则 `audio_url`）。热键 `hotkey_voice`（Ctrl+Alt+V）按住说话，hook 的 `WM_KEYUP` 报 `VK_VOICE_UP`，
    **只在 `VOICE_ON` 为真时吞键**（按下也要门控，否则没开语音时热键被吞还弹气泡）。「语音」模式（`MODE_VOICE=4`）
    里 `VOICE_MODE` 让钩子把按键**全部透传**，轻点热键 = 常录。**切到语音模式 = 顺手打开语音功能**（`_voice_set_on`，
    幂等），离开不关；**选项里关掉语音时若在语音模式则自动切回混合**；模式子菜单叫「语音模式」，选项叫
    「语音输入 (总开关)」。结果默认进候选条等空格确认（`voice_auto=1` 直接上屏；`voice_click=1` 点击落点：只进
    剪贴板 + 候选条提示，见 §D14），上屏走 `inject()` 但**不进词频学习**。麦克风 Deny 时 `waveInOpen` rc=1 →
    报"去开 设置→隐私和安全性→麦克风"（`voice.mic_consent()`）。**`_write_config()`**：`config.txt` 不存在就
    **新建**（别静默失败，否则托盘开关"点了不落盘"），返回 True/False。
    **要照做的规则**（叙事/实测数字/探针见 §D12/§D6/§D8/§D14）：
    ① **按住热键的自动重复必须丢掉**（Windows 每 ~33ms 补发 `WM_KEYDOWN`，`KBDLLHOOKSTRUCT` 里**没有**重复标志）：
    `hook` 里 `if VOICE_DOWN[0]: return 1`，并在**修饰键已松开**的 V 按下处清 `VOICE_DOWN[0]`。
    ② **录音期间要重画候选条**（`main._voice_tick()`，poll ~4Hz；`voice_down` 把 `_VOICE_TICK[0]` 归零）。
    ③ **VAD 阈值 `thr = min(clamp(floor*3.5,180,1200), clamp(peak*0.25,180,600))`**（`floor` 取**最小** RMS，
    `peak` 每块 ×0.9 慢衰减）——**别改回"只留 thr_abs"或"头 500ms 取中位数"**：说话声会被判成静音；关自动停用
    `voice_silence = 0`；全 0 PCM 报"麦克风给的是纯静音"。④ 每次录音/系统识别各留一行 **always-on** 诊断。
    ⑤ `http` 统一走 `voice._http_post`（`stt_proxy`：auto=先代理后直连 / `direct` / 指定 URL）：**每条路都重建
    `Request`**（`set_proxy()` 会**就地改 `req.host`**）、**服务端回过话(HTTPError)就不换路/不重发**、把**每条路的
    原因**一起报出来。⑥ 系统引擎 `Recognize()` **一次只返回一段**，必须循环收齐再拼（CJK `''`、其它 `' '`）；
    流读完后**再调会抛**，循环内自己 try 住 break。改 VAD 必须跑 `voice-vad-test.py`（31 项）。
    **常驻助手（whisper/sherpa 同一套 `_WarmSrv`，只有 `key/spawn/request_obj` 三个钩子不同）**：照 §17 helper
    （源码走环境变量 / JSONL 走 stdio / **回包用 `ensure_ascii` JSON** / **父进程退出=stdin EOF=子进程自退**）。
    **两个锁别合并**：`lock` 管起杀（预热在主线程调，绝不能等识别）、`rlock` 管一问一答。预热两处：启动 +4s 后台
    （`stt_prewarm=0` 关）+ **按下热键那一刻**。改这块跑 `whisper-warm-test.py`（67）/`sherpa-warm-test.py`（74）。
    **key 的语义两边不同**：sherpa 的 `itn`/`lang`/`threads`/`script` 是**建识别器**的参数（改了要重启助手），
    whisper 的 `lang`/`prompt`/`beam` 是每次请求带的。**这套东西在仓库外、按机器各装一份**（重装步骤见 §D8.2）。
    **坏网络**：国内站 key 必须配 `api.siliconflow.cn`（`.com` 回 401）；`stt_retry`（同路重试默认 3，
    **HTTPError 不重试**）、`stt_timeout`（默认 15s）、**记住可用路径**；`voice_fallback` = 第二引擎与主引擎
    **同时开跑、谁先成功用谁**，两个都失败才报错，`http` 配了它时重试/超时收紧成 2×10s。

## §D19 第五十三/五十五轮：Tk 窗口与滚动区布局审计（AGENTS.md §41/§42 压缩前的原文）
> 压缩前逐字保留（AGENTS.md 现在只留规则 + 指针）。

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

## §D26 第五十五轮：窗口高度与按钮条审计（AGENTS.md §42 压缩前的原文）
> 压缩前逐字保留（AGENTS.md 现在只留规则 + 指针）。

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

## §D28 发布回验记录（AGENTS.md §7 压缩前的原文）
> 压缩前逐字保留（AGENTS.md 现在只留规则 + 指针）。

  **发布回验记录**（publish 之后必做：线上 zip 比对 + body 逐字符 + tag 指向本地 HEAD；本机 `git ls-remote`
到 github 常年连不上，**tag 要用 GitHub API** `/repos/<repo>/git/ref/tags/<tag>`，别把空结果当"tag 没建"）：
v1.2.14（id 391874873，tag = 本地 HEAD `d85a98e`）与 v1.2.11/v1.2.12/v1.2.13（python 资产已换成干净包，
tag 仍 `56f7ffe`）= 三个 zip 的 SHA256 与 stage 全同、body 无 `?` 且与本地逐字符一致、内层 `wgime-py.py`
与 dist 逐字节一致（逐项数字/release id 见 CHANGELOG）；线上资产下载偶尔 `Unable to connect`，重试即可。
**v1.2.15（id 393363320，tag = 本地 HEAD `2aaee38`）**：同上一套之外，还**以老用户身份端到端验了一回自动更新** ——
真 `update.plan('1.2.14-py')` → 发现 v1.2.15 → 真 `stage()`（raw 通道下载）→ 四道校验通过、落盘与本机 dist
逐字节同；这条正是 §D35 那个"单文件自称旧版本"bug 的**反向证明**（修之前这里必被 `verify_source` 拒绝）。
探针 `%TEMP%\wg-r85c-verify.py`（20 项全过）。

## §D29 第八十一轮：把普通单文件 Python 应用改造成插件（规范 §8.8 + 可跑模板 + 回归）

### 1) 这一轮补的是什么

用户问「普通的 python 应用（单文件）要怎么改才能作为 wgime 的插件？」。答案散在 `main.load_py_plugins()`
（`main.py:694`）、`run_launcher()`（`main.py:2091`）、`_run_plugin_file()`（`main.py:2235`）和规范 §8.1/§8.7 里，
没有一处**面向"我有个现成单文件程序"**的成文指南。本轮把它写成规范 **§8.8**，并配一个**可跑模板**
`plugins\_example-plugin.py`（双模式三块齐全，`python` 直接能跑）+ 回归 `tests\example-plugin-test.py`。

### 2) 为什么模板文件以 `_` 开头

`load_py_plugins()` 明确跳过 `_` 开头的文件（既有的 `_standalone.py` 共享层用的就是这条约定）。
所以模板**不会被自动装载**：插件管理器里看不到它、不占启动编码、不影响任何现有行为，
但它又确实躺在插件目录里（`_standalone` 同目录，独立运行 `import _standalone` 找得到）。
要当插件用：复制成 `myplugin.py` + 改 `CODE`。

### 3) 实测澄清的一处「不对称」（不是 bug，别"修"）

- `.py` 插件：`base\plugins` **和** `APP_DIR\plugins` **两个目录都扫**（`main.py:715-719`）。
- `.txt` 插件：**只**从 `APP_DIR\plugins` 读（`main.py:689` → `plugins.load_plugins(APP_DIR\plugins, DATA_DIR)`）。
- 开发版取值：`BASE = wgime-py-pure\`（`main.py:69`），`DICT_DIR =` 仓库根（根目录有 `py.txt`，`main.py:99`），
  故 `APP_DIR = DICT_DIR =` 仓库根（`main.py:107`，basename 不是 `dicts`）⇒ txt 插件目录 = 仓库根 `plugins\`；
  分发版 `DICT_DIR` 是 `package\dicts` ⇒ `APP_DIR = package\`，两者都是成品目录。

这个分工正好对应两种插件的来源：txt 插件是与 C# 版共用的格式（放仓库根 `plugins\`，`sync-dist`/`build-package`
负责分发），.py 插件是纯 Python 版专有（放 `wgime-py-pure\plugins\`，`build-package.ps1:48` 拷进 `package\plugins`）。

### 4) 回归怎么钉住「不被装载」

光断言"文件名有下划线"是在测我自己写的谓词；所以测试两头都查：
①用**宿主同一谓词**遍历真实目录（模板被排除、`pdf.py` 被包含）；
②断言 `main.py` 源码里确实存在 `fn.startswith('_')` 这一句 —— 谓词改了测试就会红。
另有：双模式三块、"文件头必须在第一个宿主 import 之前"（用位置比较，不是子串包含）、清单六键、
按 `load_py_plugins` 同一套判据装载（`CODE` 非空 + `run` 可调用）、`run()` 真建出窗口（`max(winfo_width,
winfo_reqwidth) >= 300`）、独立运行（子进程 + `WGIME_STANDALONE_AUTOEXIT_MS` + `LOCALAPPDATA` 隔离）、
文档一致性（§8.8 存在且指向模板、写明目录差异）。
## §D30 第八十二轮：首次启动自动检查依赖并安装（`deps.py` + 依赖自检窗口）

### 1) 需求与边界

用户要"首次启动时自动检查依赖并安装"。这个项目的依赖分三类，边界由此确定：

| 类别 | 例子 | 处置 |
|---|---|---|
| 核心 | 宿主自身 | **零依赖不变**（单文件自带 pystray/pypdf），绝不因缺件拒绝启动 |
| 可一键装的可选件 | `psutil` / `cryptography` / `argostranslate` | 探测 + 勾选安装 |
| 重件 | `faster-whisper` / `sherpa-onnx` | **只报告**（几百 MB + 还要模型，见 §D8.2） |

用户拍板的两条产品决定：**首次弹一次确认框、默认「否」**；**语音大件只报告不代装**。

### 2) 为什么装到 `DATA_DIR\site\pip` 而不是 `--user` / `ensurepip`

`pip install --target <私有目录>` + 把该目录挂到 `sys.path` 一次解决四个问题：
①不污染用户 Python（卸载＝删目录）；②绕开 Store Python 把 `%LOCALAPPDATA%` 虚拟化到
`Packages\...\LocalCache` 的坑（`DATA_DIR` 本身已经做过虚拟化探测）；③与既有内嵌 zip
（`site/thirdparty.zip`）**同址**，心智模型一致；④C 扩展也能装（解开的目录，不是 zip）。
代价：需要自己 `importlib.invalidate_caches()`，否则装完 `find_spec` 还看旧缓存（表现为"装好了还是缺"）。

### 3) 接线里最容易错的一处

`deps.ensure_site_on_path(DATA_DIR)` 必须在**那 30ms 的插件装载之前**跑完 —— 插件的模块级
`import psutil` 之类在 `load_py_plugins()` 里就执行了，挂晚了插件根本看不见私有目录。
自检本身排在 `root.after(2000, ...)`（poll/托盘/tools 之后），保证不抢"能不能打字"的时间。

### 4) 测试怎么做到"不联网"

`probe(finder=...)` 与 `install(runner=...)` 都做成可注入：回归 `tests\deps-test.py`（51 项）全程用假
finder/runner，只验证**分类、命令行形态、失败翻译、状态文件、sys.path 幂等**。两条硬断言：
`pip_argv` **不含 `--user`**；`read_state` 的值里**不带 `\r`**（§39 那个静默失效的老坑）。

另有 4 项**几何审计**（依赖窗口是手工 `place()` 排版）：建出窗口后遍历子孙、累加父偏移算绝对坐标，
越界即红。这里踩了两个自己的坑：①第一版 walk 一路走到 `root`，把窗口在屏幕上的位置也加进去了 ⇒ 假红
（改成走到 `win` 为止）；②`dist` 的 `MODULES` 是一行超长 dict 字面量，正则窗口取 400 字符只够装下第一个
value ⇒ 假红（改成整行匹配 `'deps':`）。两条都说明**报错先怀疑测试自己**。

守卫自检（§43 的规矩：不会失败的测试等于没写）：把窗口高度 `+38` 故意改成 `+0`，几何审计如期变红
（`bottom=506 H=480`），还原后 51/51。

### 5) 验证链

`py_compile -W error::SyntaxWarning` 0 / `undefined-globals.py` 24 文件 0 / `deps-test.py` **51/51** /
`pure-state-harness.py` 全部通过(67) / `example-plugin-test.py` 24/24 / `standalone-plugin-test.py` 6/6 /
`embedded-isolation-test.py` 14/14 / dist-sync `project modules embedded=12, mismatches=0`、
`main.py embedded match: True`。重建 dist（`1136.1 KB`）+ `build-package.ps1`（`package\` 57.5 MB），
之后按惯例跑 `%TEMP%\wg-runtime-cfg.py` 还原开发机活配置（sherpa/`stt_*`）。

### 6) 本机实测（2026-09-21）

present = `pypdf` / `psutil` / `cryptography` / `sherpa_onnx`；missing = `argostranslate`（可一键装）、
`faster_whisper`（只报告）。也就是说这条链在开发机上是**真的会触发一次确认框**的。


### 7) 真实启动冒烟（成品 dist）与应答分支

单测覆盖了 `deps.py` 与窗口，但**启动接线那 4 行**（`ensure_site_on_path` + `root.after(2000, _deferred_depcheck)`）
不被 harness 覆盖（harness 在 `# ---------- 主循环` 处截断）。所以另跑了一次**真成品冒烟**：
隔离 `LOCALAPPDATA` + `WGIME_DICT_DIR=C:\Tools\wgime` 跑 `dist\wgime-py.py`，11 秒后收工。
结果（`<temp>\wgime-py\debug.log`）：

```
tray start ok=True has_tray=True exe=...\pythonw.exe err=
tray selfcheck: nim_add=True(count=1) promoted=True ... console=no(pythonw)
deps: first-run check, missing=argostranslate,faster_whisper
```

即：**探测真的在启动链里跑了**，缺件集合与进程内探针一致，无 Traceback；日志里**没有** `deps prompt err`，
而 `deps-state.txt` 也没落盘 —— 说明当时**正停在模态确认框上**（格式串有问题会被 `except` 抓成 `prompt err`
并写状态）。应答后的分支另用一次性探针 `%TEMP%\wg-r82-prompt.py`（harness 同款：exec main 前缀 +
把 `tkinter.messagebox.askyesno/showinfo` 换成桩 + 桩掉 `_deps_open_window`）补验，**11/11**：
否 → `declined`+`asked=1`；是 → `opened`+真开窗；只有语音缺件 → `reported`（走 `showinfo` 而非询问）；
弹框自己抛异常 → `result=error` 但**仍记 `asked=1`**（不每次启动反复炸）；并断言"问过就不问"。

### 8) 两个自己踩的坑（都值得记住）

**① 成品会自我重启成 pythonw ⇒ 冒烟必须设 `WGIME_RELAUNCHED=1`。** 第一次冒烟"进程已退出、无日志、无状态文件"
全是假象：`python dist\wgime-py.py` 起的启动器把真正的 IME 交给 `pythonw` 子进程后自己退出了，而我杀的是启动器。
更糟的是日志/data 写在 `%LOCALAPPDATA%\wgime-py\`（我在 `%LOCALAPPDATA%\` 找，什么都没找到），且因为我把
`config.txt` 放错了层级，那两个实例按缺省 **ime** 模式跑、**装了键盘钩子** —— 一度有三个 wgime 在跑。
清理时按**启动时间**区分归属（27 分钟前那个是用户自己的，17:10 那两个才是我的），只杀自己的。
教训：冒烟脚本一律 `WGIME_RELAUNCHED=1`（harness 早就这么干了，见 `tests\pure-state-harness.py:72`）。

**② `git add -A -- wgime-py-pure` 会把 `testing\` 暂存进去。** 那是永不入库的草稿目录；已
`git restore --staged wgime-py-pure/testing` 撤回，并复查 `git grep -I -l --cached 'ghp_'` 为空。
附带一个自摆乌龙：`git grep ... --cached ghp_` 把 `--cached` 写在模式**之后** ⇒ git 报
`option '--cached' must come before non-option arguments`，而那条 stderr 被 `Measure-Object` 数成"命中 1"，
看着像泄露了密钥、实际什么都没匹配到。查密钥的正确写法：`git grep -I -l --cached 'ghp_'`。

### 9) 文档行尾：`.md` 也要按 blob 走（§30 的老规矩不只适用于 txt）

`docs\WGIME_使用说明.md` 与 `docs\WGIME_技术文档.md` 的 **blob 是 CRLF**（347/347、472/472 行），
而我的生成脚本里有 `t.replace('\r\n', '\n')` 的兜底 ⇒ 整个文件被规整成 LF，`git diff --numstat` 变成
376/347 的"整文件改动"，而 `--ignore-cr-at-eol` 只剩 29/26 行（= 我真正加的行）。修法：按 blob 行尾写回
（`%TEMP%\wg-r82-fixeol.py`），再 `sync-dist` 一次，diff 收敛到 29/26。**改任何文本文件前先看 blob 行尾**
（`git cat-file blob HEAD:<path>` 数 `\r\n`）—— 注意别用 PowerShell 按行拆分去数，那样会把行尾证据弄丢。


## §D31 第八十三轮：翻译插件"无法结束进程"（两个 `__main__` 入口并列 → 关一次回来一次）

> 用户报："翻译那个插件无法结束进程哦, (目前)"。这一节记真因、实测数字、修法与守卫自检，以及"为什么双模式那条腿
> 必须另起一个**进程内**入口"。

### 1) 复现（先量，不猜）
探针 `%TEMP%\wg-r83-translate-probe.ps1`（ASCII only —— 第一版把中文写进 `.ps1`，PS 5.1 按 ANSI 读直接把脚本
解析坏，§2 规则又踩一次）：
1. 记下当前所有"命令行含 `wgtranslate.py`"的 python 进程 pid（`Get-CimInstance Win32_Process`，只有 WMI 拿得到命令行）；
2. `Start-Process python plugins\wgtranslate.py --wgime-translate-window`，等 4s；
3. `taskkill /PID <新 pid>` **不带 `/F`**（= 送 WM_CLOSE，与用户点窗口 ✕ 同一条路），等 4s；
4. 再看进程表。

实测（修前）：
```
BEFORE: 47172                                     # 用户当时那扇关不掉的窗口
UP    : 47172(parent=39320), 11456(parent=51892)  # 11456 = 我起的
taskkill 11456 -> SUCCESS
AFTER : 47172(parent=39320), 36188(parent=11456)  # 36188 的 parent 正是刚被关掉的 11456
RESULT: RESPAWNED
```
**关一次回来一次**，这就是用户看到的现象；新进程的 parent pid 直接指认了"是谁又生了一个"。

### 2) 真因
`plugins\wgtranslate.py` 文件尾曾是两个**并列**的守卫：
```python
if __name__ == "__main__" and CHILD_ARG in sys.argv:
    _window_main()
if __name__ == '__main__':
    import _standalone
    _standalone.standalone(run, NAME)
```
子窗口进程（`--wgime-translate-window`）里 `_window_main()` 跑完 `mainloop()` 返回后，执行**继续往下落**到第二块 ——
`standalone(run, NAME)` → `run()` → `_start_detached_window()` → **又起一个 detached 窗口**（还顺带建了一个隐藏 Tk root）。
其它双模式插件（pdf/clock/chat/calc/wgime-qr）都只有一个 `__main__` 尾块，所以只有这个插件中招。

### 3) 修法（两处，都在文件尾）
① **入口互斥**：只留一个分派块
```python
if __name__ == "__main__":
    if CHILD_ARG in sys.argv:
        _window_main()
    else:
        import _standalone
        _standalone.standalone(_run_standalone, NAME)
```
② **独立运行改走进程内建窗的 `_run_standalone()`**（建窗后 `return root` 交给 `_standalone` 看守）：
```python
def _run_standalone():
    root = tk.Tk(); App(root); return root
```
为什么不能复用 `run()`：`run()` 是**宿主入口**，它必须 `_start_detached_window()` 另起进程（纯 Python 插件入口要在
`[python]` 块的 60 秒超时内返回，窗口也不能被宿主收尾带走）；可独立运行不需要，复用它的后果是
**父进程立刻返回 0、留下一扇没主的孤儿窗口**，`_standalone` 的 `WGIME_STANDALONE_AUTOEXIT_MS` 也管不住它
（它监视的是 `win`，而 `run()` 返回 `None`）—— 所以 `standalone-plugin-test.py` 每跑一次就漏一个真窗口出来。

### 4) 守卫与自检
新回归 `wgime-py-pure\tests\translate-window-test.py`（13 项）：
* **S 结构**（不依赖桌面，用 **AST**：注释/文档串里提到 `__name__ == '__main__'` 不算数 —— 第一版用正则，直接把
  注释里那句话也数进去，误报 3 处）：入口分派块只有一个 / 体内先判 `CHILD_ARG` 走 `_window_main()` /
  双模式尾块在 `else` 里 / 独立运行走 `_run_standalone`（不是会另起进程的 `run`）；
* **A 子窗口**：起进程 → 优雅关窗（`taskkill /PID` 不带 `/F`）→ 原进程退出，且 **6 秒内不得出现新进程**；
* **B 独立运行**：`WGIME_STANDALONE_AUTOEXIT_MS=2500 python wgtranslate.py` → rc 0、stdout 有 `STANDALONE-OK`、
  **不留孤儿**。没桌面只跑 S 并 SKIP A/B。
* 安全：只统计/清理**本测试自己起的**进程（先记 before 集合），用户已开着的窗口一律不碰。

**守卫有效性**（"一个不会失败的测试等于没写"）：把 HEAD 的修前版本换回去跑同一份测试 →
`入口分派块只有一个: found 2` / `入口体内先判 CHILD_ARG: body=['Import','Expr']` /
`关窗后没有新进程: respawned=[34684]` / `独立运行不留孤儿窗口: orphan=[13160]`（共 4~6 条红）；
换回修好的版本 13/13。修前/修后的补丁留在 `%TEMP%\wgtranslate-prefix.py` / `wgtranslate-fixed.py`。

### 5) 生效方式与现场清理
* `main._run_plugin_file` → `_run_py_file_once` 每次「运行」都 `spec_from_file_location` + `exec_module`
  **重新读一遍文件**，所以把修好的 `wgtranslate.py` 放进 `package\plugins\` 之后**不用重启 WgIme**；
* 用户当时那扇关不掉的窗口（pid 47172）连同探针/测试留下的窗口已 `Stop-Process -Force` 清掉，跑完确认进程表里
  再无 `wgtranslate.py`。


## §D32 第八十四轮：插件管理器「结束窗口」（找得到、关得掉、不误伤）

> 第八十三轮修好了"翻译窗口关一次回来一次", 但用户还是只能去任务管理器里找那个进程 —— 因为宿主**既没有
> 它的句柄也不知道它的 pid**(窗口在 `run()` 另起的 detached 子进程里)。这一节记那个入口怎么做的、为什么
> 每一步都要那么写, 以及实测/自检数字。

### 1) 为什么不能只靠 tk
`wgtranslate` 的窗口在**另一个进程**里 (`python wgtranslate.py --wgime-translate-window`), 主进程的
`winfo_children()` 什么都看不到。所以走 Win32: `win.enum_top_windows()` = `EnumWindows` + `IsWindowVisible` +
`GetWindowTextLengthW > 0` + `GetWindowThreadProcessId`, 返回 `[(hwnd, pid, title)]`。
`GetWindowText` 必须先取长度再取文本(拿 `GetWindowTextW` 的返回值当长度会截断, 文档里也这么说)。

### 2) 认领规则（`tools.plugin_window_match`，纯函数）
三条线索, 从强到弱: ①插件**文件名主干**(`wgtranslate` ← `wgtranslate.py`; 插件普遍拿它当 `title`/`APP` 名);
②`NAME`(「剪贴板翻译」); ③`CODE`(`fy`/`pdf`)。规则细节:
* **短 CODE(<3 字符)只认完全相等**。第一版对 `fy` 也做子串匹配, 结果"标题里含 fy"的窗口全被认领 ——
  那是别人的窗口, 关掉/杀掉就是事故;
* 长的候选做**双向包含**(`cand in t or t in cand`): 插件把标题写成 `wgtranslate 翻译窗口` 也能认出来。

**安全阀**(`tools.plugin_windows`): 只收 `win.process_exe_name(pid).startswith('python')` 的窗口 ——
插件都是宿主用 python 跑的; 万一标题撞上别的程序(比如用户开了个同名窗口), 一律不动。

### 3) 结束顺序（`tools.end_plugin_windows`）
先 `win.post_close(hwnd)`(**WM_CLOSE**, 等价于点标题栏 ✕, 投递即返回), 等 `wait=1.2s`; 仍活着**且 pid 不是
WgIme 自己**才 `win.terminate_process(pid)`。两条路都要, 因为插件窗口有两种活法:
* **本进程内**的窗口(`pdf`/`clock` 那种 `run()` 直接建窗): 只能 WM_CLOSE —— `terminate_process` 里写着
  "拒绝 `pid<=0` / 拒绝本进程", 杀自己等于自杀;
* **另起进程**的窗口(`wgtranslate` 的 detached 子进程): WM_CLOSE 之后还要确认它真退了。
返回值 `{'found','closed','killed','pids'}` 直接决定气泡里那句话。

### 4) UI 放哪 + 布局审计
插件管理器**顶部**按钮条已经用满(7 个按钮 494+6×6=530, bar 宽 540, 只剩 10px), 塞不下第 8 个 —— 新按钮
放**底部**那行: 「结束窗口」`x=10 y=410 w=100`, 右侧一行灰字提示 `x=118 w=344`(右缘 462 < 关闭按钮的 470)。
探针 `%TEMP%\wg-r83-pluginmgr-audit.py` 用 §42 的判据量: **16 个控件没有一个越出窗口、同父兄弟两两不重叠**
(`place()` 摆的控件要看**绝对**坐标 —— 第一版探针直接读 `winfo_rootx()`, 而窗口没 `deiconify()` 时所有控件
都返回同一个值, 看起来"16 个全越界"; 改成沿父链累加 `winfo_x/winfo_y` 才对)。

### 5) 回归与自检（`tests\plugin-window-test.py`，23 项）
* S 纯函数: matcher 的命中/短码不误伤/空标题/无关窗口 + `terminate_process` 拒绝自杀与非法 pid;
  **安全阀用打桩测**(不依赖桌面): `win.enum_top_windows`/`win.process_exe_name` 换成假的,
  标题一样但 exe 是 `notepad.exe` -> 不许认领; 换成 `pythonw.exe` -> 认领(对照);
* A 真窗口优雅路径: 起一个标题 `wgtranslate` 的 Tk 子进程 -> `plugin_windows` 找得到(pid 对得上) ->
  `end_plugin_windows` 之后 `found>=1`/`killed==0`/`closed>=1`/子进程退出/无残留窗口;
* B 安全阀真机: 标题 `WgIme 不相关测试窗` 的 python 子进程不被认领, 调完 `end_plugin_windows` 它还活着;
* C 强杀路径: `WM_DELETE_WINDOW` 写成 `lambda: None` 的窗口(点 ✕ 关不掉 = 用户遇到的形态)
  -> `killed == 1`, 进程被结束;
* 安全: 只统计/清理**本测试自己起的** pid; 开跑前若发现用户已有该插件窗口, A/B/C 整体 SKIP。

**守卫有效性自检**（"一个不会失败的测试等于没写"）:
| 突变 | 结果 |
|---|---|
| `plugin_window_match` 改成永远为真 | **5 条红**: 短码不误伤 / 空标题 / 无关窗口(Firefox) / 无关标题不被认领 / 无关子进程还活着 |
| 去掉"只认 python 进程"的安全阀 | **1 条红**: 非 python 进程的同名窗口不被认领 |
还原后 23/23。脚本留在 `%TEMP%\wg-r83-mutate-pluginwin.py`。

### 6) 顺手被自己的守卫抓到的一个真错
第一版在"气泡失败"的 except 里写了 `_dfn('plugin-end tip failed')` —— 那**是 main.py 的函数**, `tools.py`
里没有。`tests\undefined-globals.py`(symtable 版 mini-pyflakes)立刻报:
`tools.py: tools.py.show_plugin_mgr.on_end_windows._work._done -> _dfn`, 1 处。
改成 `w32.dfn_always(...)`(win.py 里那个"与 `main._dfn_always` 同一个 debug.log"的实现)之后归零。
**这类错在 pythonw 下完全无声**(`except` 把 NameError 吞了, 用户只看到"点了没反应") —— 所以 §35 那条
"改完 .py 先跑 undefined-globals" 不是仪式, 是真的会在几分钟内抓到人。

### 7) 重建与复跑
`tools.py`/`win.py` 都在 dist 的内嵌清单里 -> `wgime-py-pure\build-package.ps1` 重建:
12 个内嵌模块与磁盘逐字符一致(自写校验 `%TEMP%\wg-r83-dist-verify.py`, 用 `ast.literal_eval` 读 dist 的
`MODULES`, **不 import dist** —— import 它会真启动输入法); `main` 与磁盘一致、dist 编译通过;
`Copy-Item dist\wgime-py.py package\wgime-py.py` 后两者逐字节相同(hash `86544357…`), 用户的
`package\config.txt` 建包前后 hash 不变(`C7C08ACB…`)。
复跑全绿: harness 67 / deps 51 / embedded-isolation 14 / plugin-window 23 / standalone 6 / example-plugin 24 /
translate-window 13 / undefined-globals 0。
> 注意: 这次 `THIRD_ZIP_B64 == HEAD baseline` 是 **False**(改了内嵌模块, dist 必须重新提交) ——
> `%TEMP%\wg-dist-verify2.py` 里那条断言只适用于"没动内嵌模块"的场合(§30)。


## §D33 第八十五轮：自动更新（服务器 = GitHub Releases）

> 用户原话："加一个自动更新功能吧, 就用 github 来当服务器"。方案(用户选): **启动后台检查 + 托盘提示, 点一下才下载并重启**,
> 范围**只换纯 Python 单文件**。这一节记设计取舍、真机数字、以及验收时抓出来的那个"VERSION 陈旧"。

### 1) 为什么是"两条下载路 + 四条安全线"
* **`raw` 优先**: 发行包 `*-python.zip` 有 **25.6MB**(里面装的是 dicts, 真正的代码只有 1.1MB)。`raw` 取仓库里
  `wgime-py-pure/dist/wgime-py.py` 只要 1.1MB —— 用户点一次更新的等待从"几分钟(国内)"变成"几秒"。
* **`asset` 兜底**: raw 走的是 `raw.githubusercontent.com`(国内时通时断), 而且它**没有**独立校验和; 发行包那条路
  可以用 release body 里那张资产表的 **SHA256**(本仓库发布流程会写)做完整性核对。两条路互相兜底, 各自失败原因都记进
  `%LOCALAPPDATA%\wgime-py\update.log`。
* **安全线**除"标记 + 编译 + 体积"外, 关键是**版本必须真的变新**: `verify_source()` 会拒"低于 tag"和"不比当前新"
  两种情况 —— 防的是"有人拿旧构建重新打了 tag"这类发布事故(下面第 4 节就是这么被抓出来的)。
* **替换前备份**: `wgime-py.py.bak-<旧版本>` 与被换掉的文件同目录, 回滚就是改个文件名。

### 2) 替换为什么必须另起一个进程
Windows 上 `python wgime-py.py` 的**文件本身**其实可以被改名/覆盖(python 读完就关了句柄), 但:
* 正在跑的进程内存里还是旧代码, 必须重启;
* 杀软/索引器/编辑器偶尔会短时占住文件, 原地替换会偶发 `PermissionError`;
* 我们**不希望**"更新"这件事发生在打字/录音中途 —— 所以顺序是: 用户点确认 → 下载校验(几秒) → 落 `.new` →
  拉起助手 → **本进程正常退出** → 助手等到 pid 真的消失 → 备份 → `os.replace`(重试 10s) → `pythonw` 启新文件。
助手的等待用 `OpenProcess(SYNCHRONIZE)+WaitForSingleObject`(比轮询进程表准; 进程已退出时 `OpenProcess` 直接失败=立刻往下走)。
助手源码走环境变量 `WGIME_UPDATE_SRC`(照 §17 caret helper 的老规矩: 不落盘 .py、进程命令行只有短引导), job 走
`WGIME_UPDATE_JOB`(JSON: src/dst/wait_pid/old_version/relaunch/cwd)。

### 3) 真机对真 GitHub 的验收(`%TEMP%\wg-r85-real-github.py`, 9/9)
```
fetch_latest -> tag=v1.2.14, assets=[bat, ps1, python]        ; body 里的 sha256 抠得出来
plan('1.2.13-py') -> 有新版计划(raw_url 带 tag, asset 25598298 B, sha=f6210635…)
raw 下载 619381 B  -> 能编译 + 三个标记齐 (== 该 tag 的历史尺寸)
asset 下载 -> sha256 == body 里写的; 内层 == raw(两个源给出同一份文件)
verify_source(这份文件, info_version='1.2.14') -> **被拒绝**: '下载到的文件是旧版本(1.2.12-py < 1.2.14)'
```
最后那一条就是"VERSION 陈旧"的证据: v1.2.14 的资产里 `VERSION` 还写着 `1.2.12-py`。

### 4) 由此落下的两条修改
1. `main.VERSION` = `1.2.14-py`(此前是 `1.2.12-py`, 一直没人改 —— 而它正是单文件里"我是谁"的唯一标识);
2. `tests\release-assets-check.py` 增加一条**发版预检**: 从 python zip 的内层 `wgime-py.py` 里抠 `VERSION`,
   必须**等于** `--version`。自检: 用 1.2.15 的名字跑同一份 stage →
   `python: 单文件 VERSION == 发布的版本  FAIL VERSION='1.2.14-py' vs --version 1.2.15`。
   **正则的坑(文档级)**: dist 里 main.py 是"嵌套转义"的字符串, 真实字节是 `VERSION = \\'1.2.14-py\\'` ——
   反斜杠要允许**任意多个**; 而且必须要求**以数字开头**, 否则会先命中 `update.py` 自己文档里那句 `VERSION = '...'`(实测踩过)。

### 5) 回归测试的 30+ 项怎么来的
`tests\update-test.py` 起一个**本地假 GitHub**(`http.server`): `/repos/o/r/releases/latest` 返回带 body 表的 JSON,
`/raw…` 与 `/dl/<asset>` 各返回假单文件/假 zip; 假单文件是"三个标记 + VERSION + 填充到 210KB"的可编译文本。
覆盖: 纯函数(S)、检查/下载校验(A)、**真替换助手**(B)、端到端 `spawn_apply`(C)。
**三个突变自检**(`%TEMP%\wg-r85-mutate-update.py`): sha256 核对去掉 → 3 红; "必须比当前新"去掉 → 2 红;
助手不等目标进程 → 1 红。其中第 2 条一开始**没红** —— 因为"低于 tag"那条先拦住了, 于是补了一个"内层版本 == tag
但比当前旧"的用例, 才真正压到那行。
**测试抓到的真 bug**: 助手脚本原来结尾是裸 `apply_job(...)`, 返回值不进进程退出码 → "新文件不存在"那条断言
(rc≠0)失败; 改成 `sys.exit(apply_job(...))`。


## §D34 第八十五轮补：PDF 预览"刚杀过助手就必失败"（常驻助手调用的两条纪律）

**症状**: 全量回归里 `pdf-test.py` 稳定 1/78 红 —— `[UI] 预览: 第 1 页渲染进了预览框` 失败, label 文案停在
`渲染预览…`(既没成功也没报错)。先 `git stash` 掉本轮 main/tray/engine/config 的改动重跑, **一样红** →
排除"本轮引入", 是插件自己的时序问题(此前时绿时红, 现在必红)。

**量出来的机制**（探针 `%TEMP%\wg-r85-pdfhang-probe.py`）:
```
1) 首次 winrt_info: ok=True  (0.37s)                 # 助手正常
2) shutdown -> winrt_info: ok=False (0.00s)          # 1 秒防风暴门: 拒绝重启, 直接返回"还没就绪"
3) 双 shutdown + 1.3s 后再 preview: OK (1.74s)        # 门放行后, 冷启 + 渲染一共 1.74s
T_COLD=180.0  T_TIMEOUT=1800.0  MAX_FAIL=3
```
* `_W32.ensure()` 里有"起得太密就挡一下"的 1 秒门(`now - self.started < 1.0` → 返回 False);
  PDF 工具的「取消」就是 `shutdown()`(杀助手), 所以**取消之后的第一次调用**会立刻吃 `还没就绪`;
* 冷启上限 `T_COLD=180s`、热态 `T_TIMEOUT=1800s` —— 预览跟着一起等, 表现就是"一直写着 渲染预览…"。

**修法**(三处, `plugins/pdf.py`):
1. `call()` → 拆 `_call_once()`, 对 `还没就绪`/`超时` **自动重试一次**(0.4s 后再来), 两次原因都报;
2. `call(timeout=)` 新增本次上限, 透传到 `render_images(timeout=)`;
3. `preview_first_page()` 用 `timeout=20.0` —— 预览卡住就报"预览不可用", 不拖住界面。

**验证**: `pdf-test.py` 78/78 × 3 次; `package\plugins\pdf.py` 同步(插件不内嵌 dist, `dist\wgime-py.py` 未动)。

**两条纪律(写给以后)**:
* 常驻助手只要能被"取消/杀掉", 那么**紧随其后的调用必须自带重试** —— 1 秒防风暴门、冷启窗口、
  管道半死这几种状态都会让"第一次"失败, 而用户刚点过取消, 看到的却是一次莫名其妙的失败;
* **"锦上添花"的调用(预览、提示、边角渲染)要给自己的短上限**, 不要继承批量任务的长超时(180s/1800s);
  长任务才配长超时, 短交互宁可"如实说不可用"。

## §D35 发布 v1.2.15：把自动更新发出去，以及"单文件自称旧版本"这个会让更新永远装不上的坑

**为什么要发这一版**: 自动更新(第八十五轮)只存在于仓库与新构建的单文件里, 而线上最新的 `v1.2.14`
**还没有这段代码** —— 老用户既不会自动升, 也没有「检查更新」可点。所以必须发一版把功能带出去。
反过来说: **凡是"让用户自动拿到新版本"的功能, 第一版只能靠用户手动装一次**(发布说明里写清了这句)。

**① 发布预检抓到的真问题（这才是这次发版最大的收获）**

`release-assets-check.py` 拿 `--version 1.2.15` 跑, 报:
```
python: 单文件 VERSION == 发布的版本   FAIL   VERSION='1.2.14-py' vs --version 1.2.15
```
而构建产物里 `main.VERSION` 明明已经是 `1.2.15-py`。**量出来的机制**:
```
dist 里 version_in_text 正则的全部命中(修前):
  #0  value='1.2.14-py'   ← 来自 MODULES 里 update.py **自己文档**里那句解释转义的示例
  #1  value='1.2.15-py'   ← 真正的 main.VERSION
```
`MODULES` 是按 `MODULES = [...]` 顺序拼的, `update` 在 `main` **之前**, 而 `version_in_text()` 老实现是
"全文搜第一个 `VERSION = '数字...'" ⇒ 抠到的是**文档里的旧版本号**。

**后果(很隐蔽, 而且正好打在自动更新上)**: `update.verify_source()` 会拿它跟 release tag 比 ——
下载到 v1.2.15 的文件被判 `下载到的文件是旧版本(1.2.14-py < 1.2.15)`, 于是**永远更新不上去**;
用户界面上只看到"有新版本"却装不上。这与 v1.2.14 那次的"VERSION 陈旧"(里面写着 1.2.12)是同类问题的另一种形态。

**修法(两层, 缺一不可, 都在 `build-wgime-pure.py` + `update.py` + `release-assets-check.py`)**:
1. **构建期写一行顶层明文身份**: `build-wgime-pure.py` 从 `main.py` 抠出 `VERSION`, 在 dist 头部写
   `WGIME_VERSION = '<版本>'` —— 它在 `repr` 之外, 没有转义、没有歧义; 抠不到 `VERSION` 就**拒绝构建**。
   `update.version_in_text()` 与发布预检**先认它**, 老的 `VERSION = '数字...'` 正则只作旧文件兜底。
2. **文档里不许再出现带数字的 `VERSION = ` 示例**(包括 `version_in_text` 自己的 docstring —— 它原来正是
   罪魁)。兜底正则的"以数字开头"只挡得住 `VERSION = '...'` 那种占位写法, 挡不住"举了个真版本号"。

**② 回归: 这次写成"拿真东西断言"的了**
`update-test.py` 从 32 项 → **36 项**, 新增的关键一条是**拿仓库里真实那个 `dist\wgime-py.py`** 断言
`version_in_text(dist) == main.py 的 VERSION`(外加 `is_single_file(dist)` 为真、以及"文档里的旧版本号
不许抢先命中"一条)。**自检**: 在**修之前**的 dist 上跑 → 必红 `dist='1.2.14-py' main='1.2.15-py'`,
修完 36/36。教训: 光测假文件不够 —— 假文件里没有"自己的文档藏着版本示例"这个**形状**;
凡是"读一个仓库里的真实产物"的逻辑, 回归就该去读那个真实产物。

**③ 发版流程里踩到的其它事实(记下来省下次的时间)**
* `build-package.ps1` 会用仓库根模板覆盖 `package\config.txt` ⇒ 用户在本机用的活配置要**先备份**;
  但**打包发行资产必须用模板**(否则又被 `release-assets-check.py` 拦下, 而且真的会泄露私用路径/key) ⇒
  正确次序是 **构建 → 打资产 → 跑预检 → 再还原用户配置**(`package\` 不入库, 还原不影响提交)。
* 第一次打完资产才发现 ① ⇒ **修完必须重打**(dist 变了, python 包的 SHA256 就变了), 发布说明里那张
  SHA256 表要用**最终 stage** 的值。
* `build-wgime-pure.py` 有 "missing import_ec.txt" 警告属正常(本机不产 EC 表)。

**回验(v1.2.15, 探针 `%TEMP%\wg-r85c-verify.py`, 20/20)**: release id **393363320**、tag `v1.2.15` = 本地 HEAD
`2aaee38`、三个线上资产 SHA256 与 `.release-stage-v1215\` 全同、线上 python 包内层与 `dist\wgime-py.py` 逐字节同、
body 无 `?`、资产表三条 SHA256 对得上; **并以 `1.2.14-py` 的老用户身份真跑了一遍 `plan`+`stage`** ——
下载 v1.2.15、四道校验通过(修 ① 之前这条必被拒)、落盘与本机 dist 逐字节同。记录见 §D28;
`release-assets-check.py --version 1.2.15` **28/28**。

## §D36 桌面宠物 widget（目标轮次 1）：全屏 / 鼠标穿透 / 不抢焦点 —— 可行性已实测, 语言与内核已定

**需求**(用户原话, 场景 1/2/3): 一个**全屏、鼠标穿透**的小挂件; 主角随打字运球/空闲自由活动、
回车投篮; 或驮挎包的小狗, 用游戏式快捷键呼出工具面板, 点工具就"从包里叼出来抛到屏幕中间展开"、
展开的是**输入法插件**; 活动范围扩展到屏幕四边框(左右要爬树)、跟鼠标躲猫猫。
**交付形态**: wgime-py 版的**独立插件**, "可以是 dll, 不能有 exe"。

### 1) 结论: 纯 Python 就够, 不需要 DLL / EXE

- wgime-py 的插件形态就是 `plugins\*.py`(见 `docs\WGIME_插件规范.md` §8.7/§8.8): 模块级 `CODE`/`NAME`/… +
  可调用 `run()` + `STANDALONE = True`(双模式)。**DLL 与 EXE 都不需要**;
  真要"独立运行"也只是 `python xxx.py`, 用的还是用户自己那个解释器。
- 关键约束: **`run()` 跑在宿主 Tk 主线程且同步执行** ⇒ 一个长期活着的动画窗口必须照
  `wgtranslate`/`clock` 那套**起 detached 子进程**(`CREATE_NO_WINDOW`, 子进程里自带消息循环)。
  这正好也是我们想要的: widget 与输入法**进程隔离**, 它再卡也卡不到打字。
- **不要用 tkinter 画这个浮层** —— 理由见下面 2) 的实测: Tk 建窗即 map, 激活已经发生, 抢焦点拦不住。

### 2) 实测(本机 3840x2160, 单屏; 探针 `wgime-py-pure\testing\pet-probe-*.py`, 原型勿入库)

| 做法 | 结果 |
|---|---|
| Tk:`overrideredirect` + `-transparentcolor` + `win.set_overlay_styles()` | 透明/穿透/四条样式都对, 4K 全屏 12 个精灵 **290fps**; 但**第一个窗口必抢前台**(实测 `stole=1`) |
| Tk + 先 `withdraw` 再 `ShowWindow(SW_SHOWNOACTIVATE)` | **还是 `stole=1`** —— 因为 Tk 建 Toplevel 时就 map 了, withdraw 已经太晚 |
| Tk + "抢了再 `SetForegroundWindow(prev)` 还回去" | `stole=0`, 能救, 但中间有 ~0.3s 抢着 ⇒ 正在打字时按键会**丢进我们的空窗口** |
| **自己 `CreateWindowExW`, 创建时就带 `WS_EX_NOACTIVATE`** | **`stole=0` 且第一帧就不抢**, 从根上解决 |

**最终内核配方**(探针 4/5, 全绿):
```
CreateWindowExW(WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST,
                WS_POPUP, 0,0, SW,SH)          # 尺寸用 SM_CXSCREEN/CYSCREEN(整屏, 不是工作区)
SetLayeredWindowAttributes(hwnd, KEY_COLORREF, 0, LWA_COLORKEY)   # 键色透明
ShowWindow(hwnd, SW_SHOWNOACTIVATE); SetWindowPos(HWND_TOPMOST, …, SWP_NOACTIVATE)
```
- 动画: **独立线程 + `timeBeginPeriod(1)` + `PostMessage(WM_APP+n)`**, 主线程 `GetMessage` 阻塞循环。
  实测 **59.5fps**, wndproc 最慢 **1.45ms**。
  **别用 `WM_TIMER` + 轮询 `sleep`**: 实测只有 **40fps**(消息队列被 sleep 饿住), 与渲染无关。
- 重画只 `InvalidateRect(脏矩形)`(旧位+新位两块), 绝不用 `InvalidateRect(NULL)`。
- 客观判据(别靠肉眼, 这几个都实测过):
  ① `GetPixel(GetDC(NULL), 精灵处) == 球色` ⇒ **分层窗真的可见**; 有了这条, 下面这条才不是空转;
  ② 同法取窗口内空白点, 显示前后**像素不变** ⇒ 键色**真透明**;
  ③ `WindowFromPoint(x,y)` 返回的 root ≠ 本窗 ⇒ **真穿透**(连精灵上那点也穿透);
  ④ `GetForegroundWindow()` 前后一致 ⇒ **没抢焦点**;
  ⑤ `GetWindowLongPtrW(GWL_EXSTYLE)` 四条样式齐。

### 3) 交互态(场景 2 点工具的关键性质, 已实测)

平时 `WS_EX_TRANSPARENT` ⇒ 整屏穿透。要用户点工具时, **只去掉 `WS_EX_TRANSPARENT`**(保留 NOACTIVATE):
- 画了面板的地方 `WindowFromPoint` **就是本窗** ⇒ 点得到工具;
- 面板外的空白处**仍然穿透** —— 因为 `LWA_COLORKEY` 连**命中测试**也按键色透明;
- **全程前台窗口不变** ⇒ 点工具**不会把输入框的焦点/光标弄丢**。这条是"输入法旁边挂件"最要紧的性质。

### 4) 踩坑与硬规矩(写给后面的轮次)

1. **样式必须创建时给**: 任何"先建窗再补 `WS_EX_NOACTIVATE`"的路线都已经激活过一次了。Tk 这条路走不通。
2. **所有 Win32 函数都要声明 `argtypes`/`restype`** —— 64 位下句柄按默认 `c_int` 传会被**截断**
   (探针第一版就靠这个才没崩: 显式声明后 `CreateWindowExW`/`SetWindowPos` 才正常)。
3. `WS_EX_TOPMOST` 是**只读位**(`SetWindowLong` 设不上, 见 §D11.1/§42), 但 `CreateWindowExW` 的 `dwExStyle`
   里给**有效**(实测读回来 `0x080800a8` 含 0x8); 要再压 Shell 层才走 `win.set_topmost()`。
4. `WNDPROC` 的 `WINFUNCTYPE` 对象**必须保引用**, 否则被 GC ⇒ 回调进已释放内存。
5. 键色选**精灵里绝不会出现的颜色**(沿用 `dot.py` 的 `#010203`); 颜色键是硬边(无逐像素 alpha),
   所以美术走**像素风/扁平色块**最合适; 想要抗锯齿边缘再上 `UpdateLayeredWindow`(留作后续升级)。
6. 全屏浮层一旦画错就是"整屏糊住"用户 ⇒ 先铺键色再画, 起窗失败/样式失败**立刻销毁退出**,
   并且一定要有"到点自杀"的兜底(探针里就留着)。
7. 目标轮次 1 只做到"把可行性证死 + 定内核"; 插件本体见 **§D37**(已完成: `plugins\wgpet.py` +
   `tests\pet-overlay-test.py` 47 项 + 变异自检 4/4); 场景 1(篮球)与 3(四边框攀爬/躲猫猫)还没做。

## §D37 目标轮次 2：桌面宠物插件本体（场景 2 跑通）+ 47 项客观回归 + 变异自检

**这一轮做了什么**: `wgime-py-pure\plugins\wgpet.py`(双模式插件, 约 47KB, 纯 ctypes+Win32, **不用 Tk**)
+ `wgime-py-pure\tests\pet-overlay-test.py`(47 项, 无桌面只跑 S 段)。

**结构**(后面几轮照着加场景就行):
| 部件 | 说明 |
|---|---|
| `PetWindow` | 自建分层窗 + 消息循环 + 脏矩形; `_style()` 一行决定"穿透 or 交互" |
| `Gfx` | 一帧的笔刷/画笔/字体缓存 + 圆角/椭圆/多边形/线段/文字; **删对象前先把系统对象选回 DC**(否则 DeleteObject 失败=GDI 句柄泄漏, 每秒 60 帧会堆起来) |
| `DogScene` | 主角状态机: `walk`(自己溜达)/`alert`(你在打字就站住抬头竖耳朵)/`sit`(开了面板); 走路用 `sin(phase)` 摆腿+上下颠 |
| `discover_tools()` | 挎包里的工具 = 你自己的插件, **现读插件目录**(复用宿主 `plugins.py` 解析 `.txt`, 正则静态读 `.py` 的 CODE/NAME/PERM) |
| `run_tool()` | 在**本进程后台线程**里跑工具: `.py` 走 `importlib` + `run()`; `.txt` 走宿主 `plugins.run_steps`(自带 `msgbox(title,text)` / `confirm(text,title,buttons,default_no)` 两个回调, 签名与宿主一致)。非 low 权限照 §16 先 `MessageBoxW` 确认 |

**三条设计决定(别改回去)**:
1. **不改宿主一行代码**: 宠物是独立进程, 工具由它自己执行 —— 所以不需要 IPC、不需要给 `main.py` 加钩子,
   也就不需要重建 dist(插件本来就不进 dist)。
2. **打字的感知用 `GetAsyncKeyState` 轮询, 不装键盘钩子**: 钩子哪怕只观察也有拖慢/吞键的风险, 而挂件只要
   "知道你在打字"就够了。回车单独判, 用来触发叫/投篮。
3. **呼出用 `RegisterHotKey`(Ctrl+Alt+P)而不是钩子**: 不抢焦点、不吞键、键被别的程序占了也只记一行日志。
   另外"直接点狗"也能开面板(平时穿透, 点得到就说明点在它身上)。

**唯一一处偏离插件规范**: 规范 §8.7 的双模式尾块是 `import _standalone; _standalone.standalone(run, NAME)`,
本插件**没走它** —— 因为 `_standalone` 是给 **Tk 插件**用的(建隐藏 Tk root + 监视 `win.winfo_exists()`),
而宠物是纯 Win32 消息循环, 用它会白建一个 Tk root 且根本监视不到这个窗口。取而代之: 自己实现同样的**契约**
(`STANDALONE-OK` 标记 + `WGIME_STANDALONE_AUTOEXIT_MS` 自动退出), 所以 `standalone-plugin-test.py` 照样通过。

**47 项回归**(`python wgime-py-pure\tests\pet-overlay-test.py`)—— 全是**客观量**, 没有一条靠肉眼:
* S 段(无桌面也跑): 清单契约 / `_py_meta` 缺 CODE 或缺 run() 就不算插件 / 工具按 code 去重(实测真的出现过
  重复: 同一个插件在两个插件目录里各有一份)/ 清单不含宠物自己 / **模块导入不建窗**(§8.8 陷阱 1)/
  **入口只有一个 `__main__` 块**(§45)/ 独立运行契约齐。
* L 段(真起浮层, 无桌面 SKIP): 五条扩展样式齐 / 起窗前后 `GetForegroundWindow` 不变 / `WindowFromPoint`
  在屏幕中部不是本窗 / 屏幕中部像素没被糊住 / **在狗身上扫到毛色**(证明真画上去了)/ 帧率 >=30fps /
  狗位置真的在变 / 呼出后面板开 + `TRANSPARENT` 去掉 + `NOACTIVATE` 仍在 + 面板处 `WindowFromPoint` **就是本窗**
  + 面板**扫得到底色** + 面板外仍穿透 + 前台不变 / 点格子 -> 记录"叼出去"的是**点的那个**工具 + 面板收起
  + 抛到中间后**触发了执行**(`WGIME_PET_NO_LAUNCH=1` 让它只记不跑, 免得测试里真开出工具窗)/ 到点自己退出 rc=0 /
  终版 dump 写出 / 窗口已销毁 / 没留下我们的窗口。
* 测试钩子(都在插件里, 生产环境无副作用): `WGIME_PET_SELFTEST_MS`/`WGIME_STANDALONE_AUTOEXIT_MS`(自动退出)、
  `WGIME_PET_DUMP`(退出时写状态)、**`WGIME_PET_DUMP_LIVE`(每 0.4s 写一次, 让回归能在它运行时断言)**、
  `WGIME_PET_NO_LAUNCH`(只记不跑)、`WGIME_PET_OPEN_PALETTE`、`WGIME_PET_SCENE`。
* **变异自检 4/4**(`%TEMP%\wg-pet-mutate.py`, 改坏->跑->还原, 探针脚本没入库):
  `_style` 永不加 TRANSPARENT → 红 1; 工具改回按 path 去重 → 红 1; 创建时去掉 NOACTIVATE → 红 2;
  面板开合不切样式 → 红 2(含"面板处点不到")。
  **一个诚实的注脚**: "创建时不带 NOACTIVATE"那次**没有**红掉"起窗后没抢焦点"那条 —— 在这个 spawn 路径下
  (测试进程拉起的 detached 子进程)Windows 没把前台给它。也就是说**真正兜底的是样式断言**(GWL_EXSTYLE),
  "前台没变"只是端到端旁证; 别因为后者绿了就以为前者可以不查。

**实测数字**: 帧率 **58.5~58.7fps**(独立线程 + timeBeginPeriod(1) + PostMessage); 单帧 wndproc 无异常;
本机列出 8 个工具(jsq/lt/sz/pdf/qrcode/fy 六个 .py + qls/qping 两个 .txt)。

**下一步(目标轮次 3+)**: 场景 1(篮球: 打字运球/回车投篮/呼出时把球砸向屏幕中间炸开)、场景 3(活动范围扩到
四边框 + 左右攀爬 + 跟鼠标躲猫猫); 还有"挎包盖打开后工具图标从包里冒出来"的细节, 以及 `config.txt` 里
`pet_scene` 的登记(sync-dist + release 模板)。

## §D38 目标轮次 3：场景 1(篮球)与场景 3(四边框攀爬 + 躲猫猫) + 「读屏幕像素」这一课

**新增两个场景**(`plugins\wgpet.py`, 场景由 `config.txt` 的 `pet_scene` 或 `WGIME_PET_SCENE` 选):
* **场景 1 篮球**: 主角在屏幕下缘活动, **左右两边各一块篮板/篮筐**(离地 430px); 你打字他就**原地运球**
  (每 0.9~2.0s **随机换手**, 像胯下运球), 闲下来接着溜达; **回车投篮** —— 球划弧飞向最近那块篮板,
  进筐时篮筐亮起并抖出三道声波, 然后落地、自己把球捡回来接着运。**呼出工具时先把球砸向屏幕中间、
  炸开、再弹面板**(用户点名要的那个手感)。
* **场景 3 四边框攀爬 + 躲猫猫**: 把整圈**周长参数化成一条一维路径** `s`(0=左下角向右) —— 于是"绕四边跑"
  就只是 `s += v*dt`, `_place()` 把 s 映射回 (x, y, 边, 朝向)。左右边框是**攀爬**(四肢一上一下交替),
  上方是**倒挂**(从"天空"垂下的藤/绳), 下方是走路。**鼠标靠近 300px 就撒腿跑**(往离鼠标远的那头),
  **贴到 105px 以内就缩起来躲**(hide 0..1); 被逼住或闲得慌就**横跳(leap)**到离鼠标最远的那段边框 ——
  这就是"扩展到全屏都能成为活动范围"。鼠标位置用 `GetCursorPos` 轮询(测试用 `WGIME_PET_FAKE_MOUSE` 打桩,
  **绝不真去动用户的鼠标**)。

**三条设计规矩**:
1. 场景是**可插拔的**: `_make_scene(scene_no)` 按号造对象, 三个场景实现同一套接口
   (`tick(dt, activity, enter, mouse)` / `draw(g)` / `bbox()` / `mouth()` / `panel_anchor()`) ——
   `PetWindow` 只认接口, 加场景不用碰窗口/面板/工具那套。
2. 场景 3 的"躲"要和**面板**讲和: 面板一开(`palette_open`)场景就切 roam 且速度归零, 免得它一边躲一边抖。
3. 每个场景自己算 `panel_anchor()`(面板挂在主角上方), `slots()` 再把它夹到屏幕里。

### 这一轮最贵的一课: 读屏幕像素的代价

**实测数字**(本机 3840x2160, DWM, 分层窗还在 60fps 重画):
```
GetPixel                    8.48 ms/次      <- 一次只能读一个像素
BitBlt 400x300 + GetDIBits  9.86 ms/次      <- 一次读 12 万像素(但见下面的坏消息)
整条下缘逐点扫 3840x178     162 秒          <- 直接把被测进程的存活窗口(25s)耗光
```
踩出来的连锁反应特别有教育意义: 扫描跑到一半, 被测的宠物**已经到点退出了**, 于是它后面
"没反应"(activity 一直 0、投篮没发生、面板没弹) —— 看起来像**功能坏了**, 其实是**测试自己太慢**。
(中间还误判过两次: 一是以为宠物卡死, 二是以为球没画出来; 真相是拿 dump 里**过期的坐标**去扫,
而球运球时纵向峰值 ~700px/s、场景 3 横跳时 0.4s 能差 400px。)

**最后定下来的四条规矩**(已写进 AGENTS.md §5 规则 50):
1. 先**冻住动画**再验像素: 测试钩子 `WM_APP_PAUSE`(wp=1 冻 / 0 解)。**必须显式指定, 不要 toggle** ——
   多处调用时 toggle 会错位(实测: 一次忘了解冻, 后面 fps/移动两条直接假红)。
2. **只扫几十个像素**: 按状态 dump 的坐标扫一小段, 绝不整屏/整条。
3. dump 是**状态快照**, `InvalidateRect -> WM_PAINT` 是**异步**的 ⇒ 冻住之后要**等到位置连续两次不变**
   (`wait_still(live)`)再采, 否则拿到的还是上一拍的坐标。
4. 扫精灵**别扫正中心那一行** —— 球/圆的十字线正好画在那儿, 扫到的是深色线而不是填充色(这条也真踩了)。

**BitBlt 那条路走不通**(记下来省下次的时间): 本想用"抓一块到内存再找"把成本降下来, 结果
`BitBlt(screenDC)` **抓不到这个分层窗**(抓回来整片空白), 而 `GetPixel` 看得见它。所以只能靠第 2 条省钱。

**顺带修掉的两处测试脆弱性**:
* "前台窗口没变过" ⇒ 改成 "**本窗不是前台**"。前者会被屏幕前的人点一下鼠标搞成假红(真发生过一次);
  后者才是我们真正保证的不变量(NOACTIVATE)。
* `WM_APP_PAUSE` 从 toggle 改成显式 wp=0/1。

**回归**: `pet-overlay-test.py` **47 → 69 项**(新增 L2 场景 1 十三项 + L3 场景 3 九项), 全绿(连跑两次);
`standalone-plugin-test.py` **7/7**(它会把每个插件当独立程序跑一遍, `wgpet.py` 也在内 —— 这正是第 2 轮
自己实现"STANDALONE-OK + AUTOEXIT"契约的回报); `undefined-globals.py` 0。

**测试钩子清单**(生产环境无副作用): `WGIME_PET_SCENE` / `WGIME_PET_OPEN_PALETTE` / `WGIME_PET_FAKE_MOUSE` /
`WGIME_PET_LEAP_MS` / `WGIME_PET_NO_LAUNCH` / `WGIME_PET_DUMP` / `WGIME_PET_DUMP_LIVE` /
`WGIME_PET_SELFTEST_MS`; 消息 `WM_APP_TOGGLE`(开合面板) / `WM_APP_ENTER`(假回车) /
`WM_APP_ACTIVITY`(假打字) / `WM_APP_PAUSE`(wp=1/0 冻结/解冻)。

**还没做**: `config.txt` 里的 `pet_scene` 还没登记进仓库模板(要跑 sync-dist + release 模板, 等插件定型再一起做);
场景 1/3 的美术仍是"色块级"(够用但不算精致); 挎包打开时工具图标从包里冒出来的细节没做。

## §D39 目标轮次 4：宿主 API(给插件用的正式入口) + 宠物形象与动作重做

### 1) 用户报的四件事, 逐条查实

| 用户说的 | 真相 |
|---|---|
| 「点工具没看到小工具运行」 | **真 bug**。用户机器上的 pet 日志: `tool qrcode -> ok=False ModuleNotFoundError: No module named 'ui'` / `tool lt -> ok=False ... 'wspy'`。发行版是单文件, 插件的 `run()` 要 `import ui/win/wspy`, 而这些只在**宿主进程的 sys.modules** 里 -> 子进程(宠物)永远 import 不到 |
| 「狗的运动范围太小」 | 真的小: 54px/s, 3840 宽的屏横穿要 70 秒, 而且一打字就站住 -> 看着几乎不动 |
| 「实现非常难看」 | 真的难看: 色块级 GDI, 比例差、无对比、耳朵画成一根刺、挎包和身体同色看不见 |
| 「避开鼠标没实现」 | **写在了场景 3**(四边框躲猫猫), 而默认是场景 2; 更糟的是 `pet_scene` **没登记进 config.txt 模板** -> 用户根本没法发现怎么换场景 |

> 我第 2 轮"验证工具能跑"是**在源码目录**做的(那里 `ui.py` 就在旁边, 探针拿到 `ok=True`),
> 当成了通用结论 —— 这是验证漏洞。教训已写进 §5 规则 50/51: **工具启动必须在发行版布局下验**。

### 2) 宿主 API(第八十六轮, `main.py`)

```
<宿主文件> --api list-plugins        -> 一行 JSON: 可用插件(code/name/kind/perm/path)
<宿主文件> --api run-plugin <code>   -> 建 Tk root -> 按 code 加载插件 -> run() -> mainloop
```
* **为什么必须做在 main.py 里**: 单文件发行版下 `ui`/`win`/`wspy` 不是磁盘文件, 只有 main.py 自己的
  exec 环境里有 —— 任何"单独一个 api.py"的方案在发行版下都拿不到这些模块。
* **两个插入位置约束**(都踩过): ①`_relaunch_if_console_python()` 那条调用要加
  `if '--api' not in sys.argv` —— 否则 python.exe 启动会被**重启成 pythonw 并 detach**, CLI 的 stdout 直接丢;
  ②API 函数体要放在 `APP_DIR = ...` **之后**(插件目录从 BASE/APP_DIR 推), 而分发(`sys.exit(_api_main(...))`)
  就放在同一段后面。
* `run-plugin` 细节: `.py` 走 importlib(与宿主 `_run_py_file_once` 同款) + 权限确认; `.txt` 走 `plugins.run_steps`
  (msgbox/confirm 用 MessageBoxW 现造; `[csharp]`/`[python]` 块明确报"不支持, 用输入法里的启动编码");
  跑完看有没有 Toplevel 决定是否 mainloop(翻译那种自己 spawn 独立窗口的别干等)。
* 顺手修掉一个静默 bug: 宠物里 `import plugins` 在发行版下撞到**同名的目录**(命名空间包),
  `plugins.load_plugins` 不存在 -> 两个 `.txt` 插件被无声丢掉(用户面板只有 6 个, 少 2 个)。
  现在由宿主 `--api list-plugins` 说了算。

### 3) 宠物改成"让宿主跑工具"

* `_host_file()`: 发行版 `<package>\wgime-py.py`, 源码版 `<wgime-py-pure>\main.py`。
* `discover_tools()`: **先本地静态扫**(读 `.py` 的 CODE/NAME/PERM 与 `.txt` 的头部)让面板立刻出得来,
  再后台 `refresh_tools_async()` 问宿主, 拿到就替换(宿主口径唯一)。
* `run_tool()`: `Popen([python, host, '--api', 'run-plugin', code])` —— **stdout 落临时文件而不是管道**
  (工具活下来后管道塞满会把工具卡死); 1.2s 内就退的说明起不来, 把它的 JSON 错误捞出来给人看。
* 面板排序 `_tool_rank()`: 风险低/`.py` 的排前面, `destructive` 排最后 —— 实测(未排序时)面板第一个格子
  就是「清空回收站」, 一点先弹权限确认, 很吓人。

### 4) 形象与动作重做(用户主要诉求)

* **新增 `ScaledGfx`**(缩放适配器): 主角按屏幕放大而不用改 draw() 里那堆常数; 缩放**绕脚下那一点**做,
  所以它原地长大不跑偏。
* **狗**: 描边 + 双色明暗 + 像样比例; 四条腿**四拍走**(前后错相)+ 抬脚掌; 尾巴三段摆动;
  **会眨眼**(1.5~4.5s 随机, 0.12s 闭合); 状态机 `walk/run/alert/sit/sleep/flee`; 回车**叫**(张嘴+三道声波+小跳);
  闲 7s 坐下、24s 睡着(冒 zzz); 挎包深棕 + 亮扣 + 背带, 打开时露出三个彩色工具。
* **鼠标**: 240px 内**看你**(头与眼珠朝光标偏), 110px 内**掉头小跑躲开**。
* **运动**: 走 150px/s、**偶尔自动快跑 360px/s(0.8~2.2s)**、活动范围 5%~95% 全宽、还会小跳。
* **篮球**: 球衣号码 23、五官、双色球鞋、躯干加宽; 运球时手跟着球; 回车投篮(弧线 + 进筐亮起 + 声波)。
* **四边框**: 主角与狗同一套形象(身体/头/垂耳/脚掌/尾巴), 按所在边框摆姿势
  `stand/climb/hang/air`; **锚点按"接触点"处理**(身体朝屏幕里侧偏) —— 直接画在接触点上会半个身子在屏幕外(实测只露一个头)。
* **右键点主角 = 换场景**(1→2→3→1) 并就地改 config.txt 的 `pet_scene`(只动这一行, 保留原行尾, 二进制读写);
  `pet_scene` 也写进了仓库 config.txt 模板(注释说明 1/2/3)。

### 5) 视觉验证的方法(值得复用)

分层窗 **BitBlt/CopyFromScreen 抓不到**(实测整片空白), 而肉眼没法在 CI 里看 —— 于是加了测试钩子
`WGIME_PET_SHOT=1`: 改成**普通不透明窗** + 铺浅灰底(模拟桌面) + 只盖屏幕底部一条, 这样
`CopyFromScreen` 抓得到, 我就能真的看图改图(改一轮看一轮)。`Gfx` 因此加了 `oy` 偏移
(画布原点相对屏幕的 y), 否则绝对屏幕坐标全落到窗外面 —— 第一版截图整张灰就是这个原因。
另外这一轮两次栽在同一个坑: **用字符串判断"改没改成功"** —— `if "'paw'" not in 文件` 被*画图代码里*
的 `PAL['paw']` 骗过, 于是补配色的补丁被跳过、`KeyError('paw')` 刷屏。改成 **import 模块后查 `md.PAL`** 才靠谱。

### 6) 回归

`pet-overlay-test.py` **69 → 72 项**全绿: 新增"宠物找得到宿主本体"、"宿主 API 通(list-plugins 返回插件清单)"、
"API 清单里有工具" —— 就是这次真事故的守卫。`standalone-plugin-test.py` 7/7。
真机(发行版布局)端到端另验过: 宠物从 `package\plugins\` 起, 点第一个工具 -> 日志
`tool jsq -> 交给宿主 API (pid ...)` + `ok=True 已启动 计算器`, 且 EnumWindows 真看到新窗口。

## §D40 第八十七轮：桌面宠物改 Rust —— 渲染路线用实测钉死(ULW, 不是 DComp)

### 1) 起因与选型

用户问"python 不适合做这个, 看看用什么语言更适合? rust? C++? Java? 或者 go?"。先摸本机事实再回答:

```
rustc 1.98.0 (host: x86_64-pc-windows-gnu)   ✓ 已装
cargo 1.98.0                                  ✓ 已装
C:\Tools\WgIme\wgime-tsf\Cargo.toml           crate-type = ["cdylib"]  ← 本仓库早已在用 Rust 出 DLL
wgime-tsf\target\release\wgime_tsf.dll        1,433,485 字节
cl / g++ / go                                  ✗ 不在 PATH (VS BuildTools 18 在, 需 vcvars)
javac / java                                   JDK 17 (Adoptium)
```

→ **Rust 第一**(工具链已装 + 仓库已有同形态 crate + `windows` crate 有全套 D2D/DComp 绑定), C++ 并列
(D2D/DComp 官方样例全是 C++, 但要手工管 COM 生命周期、仓库新增一套 C++ 构建), Java 不合适(GraalVM
native-image 出 shared lib 勉强可行, 但无 D2D 生态、要靠 FFM/JNI 手搓 COM、本机连 GraalVM 都没装),
Go 不合适(`-buildmode=c-shared` 能出 DLL 但拖一整套运行时, 而且**没有 GPU 2D 绑定** —— 最后还是 GDI,
换语言换不来画面)。C# 是暗牌(`csc.exe` 系统自带、仓库里还有 `tray_cs.cs`), 但托管 DLL 不能被 `ctypes.CDLL`
载入, 要 NativeAOT + MSVC 或写薄 C++ shim, 只能作备选。

开写前的关键判断: **让宠物难看的不是 Python, 而是渲染路径** —— ①`LWA_COLORKEY` 是 1 位透明(边缘必然锯齿、
没有半透明光晕); ②形状是代码一行行画的, 不是美术资源; ③全屏窗 + 手算脏矩形(残影 bug 的温床)。
语言只解决第一条里"GPU 合成"那部分。

### 2) 坑一: DirectComposition —— 画对了、Present 成功、屏幕上什么都没有

第一版按"正解"写: `WS_EX_NOREDIRECTIONBITMAP` + D3D11 + `CreateSwapChainForComposition`
(`B8G8R8A8_UNORM` + `DXGI_ALPHA_MODE_PREMULTIPLIED` + `FLIP_SEQUENTIAL`) + `DCompositionCreateDevice` /
`CreateTargetForHwnd` / `CreateVisual` / `SetContent` / `SetRoot` / `Commit` + D2D `CreateBitmapFromDxgiSurface`。

客观测量全部"正常": 扩展样式五条齐、**120.0fps**、不抢焦点、`WindowFromPoint` 命中自己(说明窗是可见的)。
像素验证却全线失败, 于是加了两件诊断: **回读后台缓冲**(拷到 staging 纹理再 `Map`)与 **HRESULT 逐步日志**:

```
D3D11CreateDevice ok
CreateSwapChainForComposition ok
DirectComposition: target/visual/content/rootset/commit ok
D2D device context ok, dpi=96
center BGRA = (250, 158, 51, 255)   ← 本体色, 分毫不差
(4,4)  BGRA = (0, 0, 0, 0)          ← 真透明
alpha 直方图 top: [(46, 1578), (255, 931), (119, 877)]   ← 0.18 / 0.35+0.18 / 1.0 三档全对
frames/1s = 120
```

**渲染是对的, 屏幕上看不到**。三种"看"法(BitBlt / GetPixel / `PrintWindow(PW_RENDERFULLCONTENT)`)都看不到,
于是**请用户用眼睛当裁判** —— 用户答"什么都没看到"。两个独立原因:

- **原因 A(致命)**: `dcomp` / `target` / `visual` 是建窗函数的**局部变量**, 函数返回即 drop ⇒ COM 引用计数
  归零 ⇒ 合成树被拆。C++ 样例里这三个都是窗口生命周期的成员。**这条一修, 画面就出来了**(用户肉眼确认了
  品红背景上那个橙色发光团)。
- **原因 B(路线级)**: DComp 窗的内容**不按 alpha 做命中测试** —— 整窗区域 `WindowFromPoint` 都命中本窗。
  唯一能强制穿透的 `SetWindowRgn` 做对照实验: **装空区域后精灵像素变成背景色, 关掉立刻变回 `(250,158,51)`**
  ⇒ 区域会把 DComp 内容一起裁掉。"看得见"和"点得穿"在 DComp 上只能二选一。

### 3) 坑二: 换 `UpdateLayeredWindow` —— 逐像素 alpha 命中测试, 天然穿透

- 窗口: `WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST`(不带 NOREDIRECTIONBITMAP)。
- 表面: `CreateDIBSection` 32bpp 顶朝下 DIB + `CreateCompatibleDC`; D2D 用 **`CreateDCRenderTarget`**
  (`D2D1_RENDER_TARGET_TYPE_SOFTWARE` + 预乘 BGRA + dpi 96 => 1DIP=1px)。
- 提交: `UpdateLayeredWindow(ULW_ALPHA)` + `BLENDFUNCTION{AC_SRC_OVER, 255, AC_SRC_ALPHA}`,
  **同时负责"移到哪"和"长什么样"**(不用另调 SetWindowPos)。
- 命中测试**逐像素按 alpha**: 没画到的像素鼠标直接穿过去。被动态实测**连本体都不挡**
  (`WindowFromPoint` 三点全部跳过本窗); 交互态只摘 `WS_EX_TRANSPARENT` ⇒ **只有画到的像素挡鼠标**,
  面板外空白照旧穿透, 前台全程不变。

三条实测数字: **ULW 不做 vsync 节流** —— 不限速跑出 **2085fps**(纯烧 CPU), 必须自己限速
(`timeBeginPeriod(1)` + 每帧算 deadline, 常量 `FPS_CAP=120`, 限速后稳 120.0); 窗口做成**精灵大小**
(260×260)并跟着角色横移, 全屏窗 + 手算脏矩形那一整类残影 bug 因此**不存在**(每帧整块重画);
D2D 软件光栅在这个尺寸上完全不是瓶颈。

### 4) 验收: `wgpet-rs/verify-overlay.py` 25/25

纯品红背景窗 + 精灵不同半径采样, 全靠像素与句柄:

| 断言 | 实测 |
|---|---|
| 三层 alpha 叠加逐通道吻合 | `pix=(255,97,185)` vs 期望 `(255,96,185)`(=`0.35` 叠在 `0.18` 叠在品红上) |
| 三层边界都有中间色(真抗锯齿) | `aa=[(254,113,152), (255,82,198), (255,36,239)]` |
| 窗内空白 = 纯背景色 | `(255,0,255)` 精确相等 |
| 本体核心 = 本体色 | `(250,158,51)` 精确相等 |
| 眼睛在上方(证明 DIB 没上下翻转) | `(26,23,31)` 精确相等 |
| 透明处/本体处/光晕处全部穿透 | 三点 `WindowFromPoint` 都不是本窗 |
| 交互态: 本体可点而空白仍穿透 | `wfp=self` / `wfp≠self`, 且前台不变 |
| 帧率 | 120.0fps |

**顺带一条测试纪律**: 探针中途集体变红, 读数全是 `(102,0,102)`(品红被 40% 黑盖住)、前台窗口在测试中途
自己变了 —— 是**用户的截图遮罩层**盖在屏幕上。现在采像素前有**环境闸门**: 先确认角点是干净的纯品红再往下断言,
否则报"环境不干净"而不是假装是代码 bug。

### 5) Rust 侧小坑

`windows 0.58` 的 `ID2D1RenderTarget::CreateSolidColorBrush` 挂在 **`Foundation_Numerics`** feature 之下
(不打开就是 "no method named CreateSolidColorBrush"); `IDXGISwapChain1::Present` 返回 **`HRESULT`** 而不是
`Result`(用 `.ok()` 转); `DCompositionCreateDevice` / `D2D1CreateFactory` 是**泛型**返回(要写
`let d: IDCompositionDevice = DCompositionCreateDevice(&dev)?`); `SelectObject` 要显式 `HGDIOBJ(hbmp.0)`
(泛型推断不出来); `ID2D1DeviceContext::SetUnitMode` 只存在于 DeviceContext(不在 RenderTarget 上),
而 `ID2D1DCRenderTarget` 没有这个方法 —— DC 渲染目标靠 dpi 96 保证 1:1;
`IDWriteFactory::CreateTextLayout(&[u16], format, w, h)` **直接返回布局**(不是 out 参数);
`Matrix3x2::rotation(angle, x, y)` 的 (x,y) 是**旋转中心**, 且 `Matrix3x2` 有 `Mul`;
`ID2D1RenderTarget::GetTransform(&mut m)` 是 out 参数。

### 6) ABI 2: 百宝袋(工具面板)+ 掏出来扔向屏幕中间

- **面板与角色共用一个窗**: 关着 300x280, 开着 620x320。**脚底在屏幕上的位置不变**这个约束是靠
  "锚点按离窗口**底边**的距离算"满足的(`ANCHOR_BOTTOM=34`), 用离顶边的距离会让角色在开面板瞬间下跳 46px。
- **`UpdateLayeredWindow` 的 psize 允许小于 DIB**: DIB 按最大尺寸(620x320)一次分配, 提交时只交当前需要的那块,
  于是不必在开合面板时重建 DIB/render target。
- **`layout()` 是唯一的布局出处**: 绘制、命中测试、给探针的矩形全用它算出来的那一份 —— 三处各算一遍迟早错位。
- **点击坐标统一成屏幕坐标**: `WM_LBUTTONDOWN` 给的是**客户端**坐标(要 `ClientToScreen`), 而
  `wgime_pet_click` 注入的是屏幕坐标; 两条路混用坐标系时命中测试会整体偏移(真踩过)。
- **飞行物必须单独一个窗**(`fx`, 220x220, 平时 `SW_HIDE`): 它要飞到屏幕正中, 把角色窗撑到半个屏幕的话,
  每帧要提交的像素会涨到几 MB(120fps 就是几百 MB/s)。小窗跟着飞行物走, 每帧几十 KB。
- **`ground` 取工作区底边**(`SystemParametersInfoW(SPI_GETWORKAREA)`), **不是屏幕底边**: 屏幕底边 40px 处
  已经在任务栏里, 半透明任务栏会透出底下的东西, 观感像"脚被切了", 而且标定点读数会偏 1 个通道
  (实测 (176,145,177) vs 期望 (177,6,178), 查了一轮才发现是脚下那块不是纯色背景)。
- 动作时间线(秒): `T_PULL=0.22` 从挎包抽出来(被点中那格朝角色滑出并缩小) → `T_FLY=0.62` 抛物线
  (弧高 150px、自转)飞到屏幕正中 → 到位**才**回调宿主启动工具, 并在落点炸 0.38s 的圈。
  `wgime_pet_fx()` 报飞行物屏幕坐标给探针, `wgime_pet_last_launched()` / 回调收到的 code 用来断言。
- 实测(探针 `%TEMP%\wg-rustpet-palette.py`): 面板 rect 与 6 个格子 rect 正确、悬停命中 hover=0、
  点击 → `idx=0` → 飞行物从 (1191,2049) 沿抛物线到 (1920,1080) → 回调收到 `jsq`。

### 7) 面板做完整: 分页 / 动效 / 关闭 / 自适应高度

- **每页 12 格(2x6)**, 超了就分页, 标题条右侧有 `‹ 1/2 ›` 与 `✕`。`layout()` 里 `per = COLS*rows`,
  `rows` 由**工具总数**决定(不是当前页), 所以翻页时面板尺寸不跳。
- **窗口高度按工具数自适应**(工具少不留一片空白): `palette::win_size(n)`; DIB 仍按最大尺寸(430px)分配,
  提交时只交当前那块。实测 16 个工具: 关 280px → 开 423px, 角色脚底屏幕 y 两态都是 2106(不动)。
- **悬停动效**: 每个格子一个 0..1 的值朝目标靠(不是硬切), 用来做"微微放大 + 投影 + 加粗描边"。
  实测光标移上去后同一块区域有 **5959** 个像素变化。
- **关闭**: 标题条 ✕, 以及点面板外任意处收起(`inside(l.panel)` 之外即收起)。滚轮也接(WM_MOUSEWHEEL),
  但滚轮默认发给**焦点窗**而本窗永不取焦点, 只有 Win10+ 的"悬停时滚动非活动窗口"才送得过来 —— 所以 `‹ ›` 是主力。
- **两个测试纪律**: ①`wgime_pet_dog_xy()` 直接报角色的屏幕坐标, **别让探针拿窗口矩形去猜**
  (开合面板时锚点从"离底边 240"变成"离底边 34", 猜必错一处); ②**凡依赖光标位置的断言一律用
  `wgime_pet_set_cursor()` 钉住光标** —— 光标一被真人挪走, 悬停断言就假红(真踩过: 命中测试日志明明打出
  `hover -1 -> 0 cursor=(1596,1830) local=(346,113)`, 但光标自己漂到 (1507,1868) 才去读, 读数就成了 -1)。
- 回归: `%TEMP%\wg-rustpet-panel.py` **16/16**(装 16 个工具/2 页/翻页/翻页后点第 2 页的格子回调收到 `t12`/
  悬停命中与动效/✕ 收起/点空白收起/窗口高度与脚底不动); `verify-overlay.py` 21/21 保持;
  `wg-rustpet-e2e.py` 端到端仍通(点工具 → 宿主 `--api run-plugin` → 真多一个窗口)。

### 8) 形象返工: "耳朵诡异 / 尾巴不像狗 / 狗头不像狗"

用户看的是对的, 三个都是**画法**错, 不是参数没调好:

- **狗头**: 原来是"一个圆 + 一个奶油色大椭圆当口鼻", 读起来像海豹/水獭。改成**一条侧面轮廓路径**
  (`build_head`: 颅顶圆 → 前额 → **前伸的吻部** → 上唇 → 下巴 → 后脑闭合, 用 `AddBezier`), 再叠奶油色吻部与额前白斑。
- **耳朵**: 原来是两个圆椭圆"耷"在头顶, 像发髻。改成**三角立耳**(`build_ear`: 底边在 y=0、尖端朝上的圆角三角),
  远侧耳在头之前画、近侧耳在头之后画, 近侧耳再叠一层内耳(缩小 0.52 的同形状, 只填色)。
- **尾巴**: 原来是"一根渐细的线 + 末端一个球", 像老鼠尾巴。改成**羽状尾** —— 沿脊柱算左右两侧轮廓
  (宽度剖面 `3.2 + 7.6*sin(t*π*0.9)`: 根部细、中后段最蓬松、尖端收)闭合成路径再填充 + 描边, 尾尖点一撮白毛。
- **形状缓存**: 头与耳的形状是**固定**的(只有位置/角度在变), 所以 `Shapes` 里各建一次路径, 之后只用
  `place(geo, at, angle, sx, sy, fill, outline)` 摆; 尾巴的脊柱每帧在变, 才每帧建一条路径。
  `Ctx` 因此多了 `factory` 与 `shapes` 两个字段(画三角/路径要它们)。
- **眨眼时的墨镜 bug**: 眼睛高光点(`eye_hi`, r=1.5)原来**不随眼皮缩**, 于是眨眼那帧眼睛被压成一条线、白点却还是
  原来的大小 —— 截图放大了看就是"戴墨镜"。修法: 高光半径与偏移都乘 `k=(1-blink)`。
  顺带加了 `wgime_pet_set_blink()` 看画钩子(截图前钉住睁眼, 否则随机抓到眨眼帧)。
- 回归: 改完 `verify-overlay.py` 21/21、面板 16/16 保持(本体标定点仍落在纯背毛上)。

### 9) 换成柴犬 + 两个隐蔽 bug

用户接着要"柴犬, 要搞得像一点"。柴犬的**识别特征**比"狗"具体得多, 所以按特征逐条对上:
- **里白(urajiro)**: 吻部/下颊一片白 + 胸腹一片白 + **四肢下段白袜子**(`leg()` 里大腿用 `fur`、小腿以下用 `urajiro`,
  远侧用 `urajiro_dim`) + 尾尖白。新增 `URAJIRO`(0.996,0.980,0.957) 与 `URAJIRO_DIM` 两支笔刷。
- **眉上两个白点(眉斑)**: 位置有两个坑, 都真踩过 —— ①不能画在白底上(那道白鼻梁一开始铺到额头, 把左边的点吞了);
  ②不能比耳根高(耳根压在额头上会把两个点都盖住)。现在白鼻梁只到两眼之间, 白点落在赤毛上、比耳根低。
- **卷尾**: 沿一圈螺旋生成脊柱(半径 17→15, 扫过 200°→-63°), 再算左右轮廓闭合填充。
  **圈半径必须明显大于尾巴粗细**: 一开始 r=15.5 配半宽 11.4, 内孔半径只剩 4, 整条尾巴糊成"背上一根横香肠"。
- **吻部**: 比上一版更短更钝(吻尖 30.5 → 27.5), 太长就成狐狸了。
- **眼**: 杏形、外眼角略上挑(`rot_at` 转 -0.22/-0.26 弧度); 面罩收小, 赤色要占主体。

**两个隐蔽 bug(比形象更值得记)**:
1. **眨眼逻辑写反了**: `blink = if blink_t > 0.86 { (blink_t-0.86)/0.14 }` —— `blink_t` 一大就等于 1(闭着),
   而 `blink_t` 大部分时间都在 0.86 以上 ⇒ **眼睛几乎永远半闭/全闭**。表现是"像戴墨镜/一直眯着眼",
   我第一轮只把高光跟着眼皮缩(治标), 这回才找到根。正确写法: 只在 `blink_t < 0.14` 那最后 0.14s 闭眼。
   连带的看画钩子 `wgime_pet_set_blink()` 也把 `blink_t` 设成 0.5(不是 999)。
2. **cargo 更新不了 `target/release/wgpet.dll` 时不报错**: demo 进程占着 DLL 时, cargo 把新构建写进
   `target/release/deps/wgpet.dll`, 而 `target/release/wgpet.dll` **还是旧的** —— 于是"明明 rebuild 了,
   画面却没变", 白看了两轮图(改卷尾、改吻部都没进画面)。**规矩: 改完先杀占着 DLL 的进程, 再核
   `target/release/wgpet.dll` 的时间戳**(不是 deps 那个); 曾经有一次是明确报 `failed to remove file`,
   这次却静默 —— 所以不能只靠"有没有报错"判断。
- 回归: 柴犬版 `verify-overlay.py` 21/21、面板 16/16。





