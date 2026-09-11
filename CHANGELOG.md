# 更新记录 (Changelog)

> 本文件记录 WgIme 的每次代码更新。以后任何更新都追加到本文件顶部(新版本在最上)。

---

## 2026-09-10 (第二十四轮审计: 取色器 — 取色中关窗必须收掉全局鼠标钩子)

换维度: C# `ColorForm`(3986-4065) vs python `tools.show_color`。

- **补齐(真差异)**: C# 在 `FormClosed += delegate { StopPick(); }` 里**无论怎么关窗都收钩**;
  python 只在 `WM_DELETE_WINDOW`(协议)与 `Esc` 上收钩, 而 `ui.make_window` 的 **✕ 按钮直接
  `destroy()`**(不经过协议回调) → **取色过程中点 ✕**: 全局 `WH_MOUSE_LL` 钩子一直挂着, 之后系统里
  任何鼠标左键都会被"吞掉"(还会往已销毁的窗口 `after` 回调), 只能重启 wgime 才恢复。
  已把标题栏 ✕ 重绑到 `on_close`(先 `stop_pick()` 再 `destroy()`)
- **核对一致(未改)**: `WH_MOUSE_LL` 左键取色并**吞掉该次点击**、右键取消(两者都 `return 1`);
  「拾取 (点屏幕)」按钮与提示文案; 色块 + `#RRGGBB   rgb(r,g,b)` + HSV 两行显示; `ColorHex` 用大写
  `X2`; `ColorHsv` 的 H/S/V 取整与格式(`H 210  S 78%  V 100%`); 「复制 HEX」只复制 hex;
  钩子装不上时不报错(下次点击可重试)
- **验证**: 用桩替换 Win32 钩子函数跑**真窗口** —— 点「拾取」→ 钩子装上; 点 ✕ → **`UnhookWindowsHookEx`
  被调用** 且窗口销毁; `Esc` 绑定与协议回调指向同一个 `on_close`; HSV/HEX 格式三例(纯红 `H 0 S 100% V 100%`、
  `#2196F3` → `S 86% V 95%`、HEX 大写)→ **0 差异**; `tests\pure-state-harness.py` 16/16 通过;
  dist 内嵌 `tools.py` 与磁盘逐字节相同、`dist==package` SHA256 相同(`2CD9C0FA…`)

---

## 2026-09-10 (第二十三轮审计: 便签 — 用户手改的便签文件必须宽松解码)

换维度: C# `NoteForm`(3614-3986) vs python `tools.show_notes`。

- **补齐(真差异)**: C# 读便签正文 / 迁移源 / 元数据一律 `File.ReadAllText(..., Encoding.UTF8)`
  (**替换式解码, 永不抛**); python 的便签窗口里有 **5 处严格 `open(..., encoding='utf-8')` 读取** ——
  `notes\*.txt`(便签正文)、`notes.txt`(旧版迁移源)、`notes-meta.txt`、`note-color.txt` 与取标题行。
  而便签正是**最容易被用户用记事本"另存为 ANSI"的文件**: 一旦这样保存, `UnicodeDecodeError`
  不是 `OSError`(那里的 `except OSError` 抓不到) → **便签窗口打不开/半死**(`_note_win[0]` 已经被置上,
  后续点击只是 deiconify 那个坏窗口), 要重启进程才恢复。已全部改用 `engine.read_text()`
  (`utf-8-sig` → `gbk` → `utf-8+replace`, AGENTS §28 的既有约定)
- **核对一致(未改)**: 多便签存储 `notes\N.txt` + `notes-meta.txt`(存第 N 个, 1 基) + 全局
  `note-color.txt`(缺省 `yellow`, 6 色 pastel); **旧版单文件迁移**(`notes.txt` → `notes\1.txt` 并删除);
  去抖保存 **800ms**(同 C# `saver.Interval = 800`)+ 关窗保存; 一个便签都没有时创建空 `1.txt`;
  主题色/标签取首行; 单例窗口
- **验证**: 便签 8 项断言 **0 差异** —— 先演示"严格 utf-8 读 GBK 便签会抛 `UnicodeDecodeError`",
  再验证 GBK 便签正文能正确打开、GBK `notes-meta.txt` 指向第 2 个便签、GBK 的旧 `notes.txt` 迁移成功
  且落盘为 UTF-8、`note-color.txt` 读取不崩; `tests\pure-state-harness.py` 16/16 通过;
  dist 内嵌 `tools.py` 与磁盘**逐字节相同**、`dist==package` SHA256 相同(`2AC63268…`)

---

## 2026-09-10 (第二十二轮审计: 剪贴板历史 — 只在窗口开着时收集 + selfSet 防回录)

换维度: C# `ClipForm`(3539-3607) + `ClipPush`(3529-3537) vs python `tools.show_clipboard`/`_clip_poll`
/`_clip_push`。

- **补齐(真差异)**:
  1. **收集范围**: C# 在窗口打开时 `AddClipboardFormatListener`、关闭时 `RemoveClipboardFormatListener`
     —— 也就是**关窗就不再监听**; python 的轮询线程从第一次打开起**永远每 0.3s 读一次剪贴板**
     (关窗后照收, 还会与别的程序抢剪贴板)。现在按窗口是否开着判定(`_clip_consider(t, _clip_win[0] is not None)`),
     与 C# 和窗口上那行提示("本窗开着也持续收集")都一致
  2. **纯空白不记录**: C# 是 `t.Trim().Length > 0` 才入历史; python 原来只判空字符串, 于是"只有空格/换行"
     的剪贴板内容也会占一条。已跟
  3. **selfSet 防回录**: C# 用 `selfSet` 标志包住自己的 `Clipboard.SetText`, 防止"点条目复制回去"又被
     记一遍(那会把该条重新顶到最前); python 原来没有这个保护 —— 点某条旧记录后, 轮询会把它识别成
     "新内容"并移到顶部, 历史顺序被自己改掉。现在写回前记 `_clip_self[0]`, 轮询遇到就跳过并推进
     "已见"标记(C# 的 `selfSet` 语义)
- **核对一致(未改)**: `_clip_push` 与 C# `ClipPush` 同语义(空/与置顶项相同 -> 不动; 已在历史 -> 移到顶部;
  新内容 -> 插到顶部; 容量 **200** 且只在插入路径裁剪); 列表显示超 80 字截断加 `…`(同 C# `RefreshList`);
  历史跨开关窗存活(C# 是 `static History`); 单击/双击条目 = 复制回剪贴板(对应 C# `Click/DoubleClick -> CopySel`);
  清空历史按钮
- **有意差异(保留)**: python 用 **0.3s 轮询**(tk 没有 `WM_CLIPBOARDUPDATE` 钩子, 代码已注明折中);
  python 关窗期间复制的内容会在**下次开窗后**被补记一笔(C# 关窗期间的更新永久丢失) —— python 更贴近直觉;
  python 多"粘贴上屏"按钮
- **验证**: `_clip_consider`/`_clip_push` 语义 **19 项断言 0 差异**(窗口开/关、空串、纯空白、重复、
  新内容置顶、旧内容移顶、selfSet 跳过且标记消费、后续外部复制仍正常、容量 200 与裁剪边界、清空、
  以及 `_clip_poll`/`copy_sel`/`paste` 的源码形状检查); `tests\pure-state-harness.py` 16/16 通过;
  dist 内嵌 `tools.py` 与磁盘**逐字节相同**、`dist==package` SHA256 相同(`6BCE5FCA…`)

---

## 2026-09-10 (第二十一轮审计: 插件 txt 头部解析 — 只有头部的文件不算插件)

换维度: C# `LoadPlugins`(4104-4146) 的**登记条件** vs python `plugins.parse_plugin`/`load_plugins`。

- **补齐(真差异)**: C# 是 `if (code == null || name == null || code.Length == 0 || body.Count == 0) continue;`
  —— **只有头部、后面一行都没有**的插件文件**连 `PluginInfo` 都不登记**(插件列表里根本不出现);
  python 原来只查 code/name, 于是这种"半成品"文件会被登记成插件(管理器里显示 `解析失败`)。
  已补 `elif body_start is None: p.error = 'no body'`(与 C# 的 `body.Count == 0` 同义)
- **核对一致(未改)**: 缺 code 或缺 name → 两边都跳过; 头部后面**任意一行**(空行/注释/步骤/`[csharp]` 块)
  都算有 body → 两边都登记; 头部解析在**第一个非头部行**处停止(之后出现的 `code=` 不再算头部)；
  `desc:` 冒号写法; `LoadPlugins` 不看文件名(README.txt 也会被登记, 跳过它是**插件管理器**列表的规则)
- **有意差异(保留)**: python 头部还认 `version/author/requires/perm`(§16 的权限模型), C# 头部只解析
  `code/name/desc`; python 额外支持 `[python]` 块插件
- **验证**: 独立实现的 C# `LoadPlugins` oracle 跑 10 组 fixtures(只有头部 / 头部+空行 / 头部+注释 /
  头部+步骤 / 头部+`[csharp]` 块 / 缺 code / 缺 name / 非头部行先出现 / 头部注释混排 / `desc:` 冒号)
  → **0 差异**; 目录级 `load_plugins` 三例(只有头部不登记 / 正常登记 / README.txt 仍登记) → 0 差异;
  `tests\pure-state-harness.py` 16/16 通过; dist 内嵌 `plugins.py` 与磁盘逐字节相同、
  `dist==package` SHA256 相同(`09039BC4…`)

---

## 2026-09-10 (第二十轮审计: tools.txt 解析 — 标签页按需创建 / code 行按 C# 规则 / 空标签页保留)

换维度: C# `LoadTools`(2111-2172) vs python `plugins.load_tools`(工具箱 `tools.txt` 的结构解析)。

- **修正(真差异)**:
  1. **标签页创建时机**: C# 的默认标签 `工具` 是**按需创建**的(第一个 `[cols N]` 或按钮出现时才建) ——
     python 原来一进函数就建; 于是「tools.txt 只有注释」时 C# 得到 0 个标签 → 工具箱提示
     "tools.txt 为空或不存在", python 却会打开一个空标签页。已改成懒建
  2. **空标签页要保留**: python 原来 `return [t for t in tabs if t['buttons']]` 会把没有任何按钮的
     标签页(`[tab 空的]`)整页丢掉, C# 会显示成空页。已保留
  3. **`[tab ]` 空名字** → C# 用 `"?"`, python 原来给空字符串(标签栏上一个空标签)。已跟
  4. **`code` 行的判定规则**: C# 是 `act != null && t.StartsWith("code")`(**大小写敏感**)且
     `ToolToks(t)[2]` 非空 —— 认 `code = x`、也认 `codes = x` / `code = x 多余`; 而 `CODE = x`(大写)
     **不算** code 行, 会掉进步骤里。python 原来用正则 `^code\s*=\s*(\S+)$`(大小写不敏感) →
     恰好两头都反: 认了 `CODE = x`, 却把 `codes = x` / `code = x 多余` 当**步骤**执行(运行时报未知动词)。
     已按 C# 的 token 规则改
  5. 步骤文本行尾不再带 `\r`(C# `File.ReadAllLines` 已剥掉, python 原来只 `rstrip('\n')`)
- **核对一致(未改)**: `[cols N]` 夹到 1-6、非数字忽略; `[button 名]` 前缀; 按钮名空 → `?`;
  任何按钮**之前**的步骤行 / `code` 行忽略; 多行块 8 组别名与"未闭合块整块丢弃"; 空 `[tab]`(无空格)
  按按钮处理; `[cols N]` 先出现会自动建默认标签
- **有意差异(记录)**: python 的块标签匹配**大小写与内部空格不敏感**(`[ shell ]` python 当块、
  C# 当按钮 `shell`) —— 既有的宽松处理, 保留(§26 已记)
- **验证**: 用**独立实现**的 C# `LoadTools` oracle 跑 11 组 fixtures(综合: 标签/列数/按钮/code/空名标签/
  大写 `CODE`/列数夹取 · 全注释 · 空标签页 · 无标签直接按钮 · `cols` 先出现 · 块与步骤 · 四种块别名 ·
  无空格 `[tab]` · 未闭合块 · 按钮前步骤 · 按钮前 code) → **规范化后 0 差异**(python 把多行块按原样行
  存进 steps、执行期再配对, 比较前按 C# `ParseToolSteps` 同规则折叠成 1 步);
  另 UI 级验证 `show_toolbox`: 收到**空标签页**不崩、标签栏渲染出两个标签名、空列表仍给
  "tools.txt 为空或不存在"提示、单例复用同一窗口 → 0 差异; `tests\pure-state-harness.py` 16/16 通过;
  dist 内嵌 `plugins.py` 与磁盘**逐字节相同**、`dist==package` SHA256 相同(`9833112F…`)

---

## 2026-09-10 (第十九轮审计: 造词/批量造词/用户词表 — 补造词对话框的「2-8 汉字」校验)

换维度: C# `MakeWordFromClipboard`/`CodeFor`/`CollectWordLines`/`BatchAddWords`/`AddUserWord`/
`ManageUserWords` vs python `main.makeword_clipboard` + `tools.show_makeword`/`show_batch_makeword`/
`show_user_words` + `engine.code_for`/`add_user_word`/`add_user_words_batch`。

- **补齐(真差异)**: 造词对话框原来只校验长度 `2 <= len(w) <= 8`, **漏了 C# 的 `IsAllCJK`**;
  而对话框是 python 的额外功能(可以**手填编码**), 于是非汉字词(如 `abc` + 手填 `abc`)会被真的写进
  用户词库。C# `MakeWordFromClipboard` 是 `t.Length < 2 || t.Length > 8 || !IsAllCJK(t)` 直接拒。
  已改成 `not (2 <= len(w) <= 8) or not engmod.is_all_cjk(w)` + 提示「词语需 2-8 个汉字」
  (`tools.py` 顶端引入 `import engine as engmod`)
- **核对一致(未改)**: `engine.code_for` = C# `CodeFor`(每字取第一个拼音, 任一字缺拼音回 `None`);
  `add_user_word` = C# `AddUserWord`(去重 / 拼音表追加 / 五笔**双注册** / 简拼索引 / 落盘, python 额外把
  反查表置失效); `add_user_words_batch` = C# `BatchAddWords`(一次性注入 + 一次排序 + 一次落盘);
  **批量造词行规则** = C# `CollectWordLines`(trim、空行不计、2-8 汉字否则计 skipped、重复计 skipped);
  用户词表: 按 ordinal 排序、删除后落盘 + 后台重建(同 C# `SaveUserWords` + `BuildDicts`/`ApplySwap`)
- **有意差异(记录)**: python 造词用**对话框**(可手填编码、会报错原因), C# 是剪贴板直造(§27 已记);
  python 对"还没有用户词"给提示框, C# 静默返回; python 批量造词结束会报 added/skipped 气泡(C# 无);
  `main.makeword_clipboard` 的预填仍只对 2-8 汉字生效(同 C# 的剪贴板判定)
- **验证**: ① 造词对话框 8 组用例(纯英文 / 中英混排 / 1 字 / 9 字 / 2 字 / 4 字 / **非汉字+手填编码** /
  手填编码保留)+ 自动填码 → 0 差异(非汉字一律拒, 正常词与手填码照常入库);
  ② 批量造词与**独立 oracle** 比对 10 行样例(含前后空格 / 1 字 / 9 字 / 非汉字 / 重复 / 空行 / 日文):
  收集结果与跳过行数完全一致; 取消文件选择不造词; 全非法时不造词并提示「没有发现 2-8 个汉字的词」→ 0 差异;
  ③ `tests\pure-state-harness.py` 16/16 通过; ④ dist 内嵌 `tools.py` 与磁盘**逐字节相同**、
  `dist==package` SHA256 相同(`274D2B08…`)

---

## 2026-09-10 (第十八轮审计: 插件管理器 — 补状态列/禁用灰显, 删除确认改「否」缺省)

换维度: C# `PluginMgrForm`(4283-4445) vs python `tools.show_plugin_mgr` + `main._list_plugin_files`。

- **补齐(真差异)**:
  1. **状态列缺失**: C# 列表有「状态」列 —— 步骤插件显示 `正常 (N 步)` / `解析失败`, C# 插件显示 `编译失败`;
     python 完全没有状态信息 → 坏掉的插件和正常插件长得一样(点「运行」才发现没反应)。已加
     `plugins.count_steps(body)`(与 `run_steps` 同规则: 多行块算 1 步、闭标签缺失整块丢弃、空行/注释不计),
     `_list_plugin_files` 给每条带 `status`(`正常 (N 步)` / `解析失败` / `未加载` / `—`), 管理器行显示出来
  2. **禁用行灰显**: C# `it.ForeColor = Gray`; python 原来没做 → 现在 `lst.itemconfig(..., foreground=ui.SUB)`
  3. **删除确认的缺省按钮**: python `askyesno` 缺省是**"是"** → 手滑回车就把插件文件删了; C# 是
     `MessageBoxDefaultButton.Button2`(否)。已改 `default=messagebox.NO`, 标题对齐 C# 的 `WgIme`
     (与第十一轮 DSL `confirm` 的缺省按钮是同一类修复)
- **核对一致(未改)**: 重载 / 启用禁用(按**文件名**写 `plugins-disabled.txt`, 对齐 C# `DisabledPlugins`)/
  打开目录 / 编辑 / 新建模板 各操作与 C# 对应; 缺 code/name 的文件两边都跳过; 新建模板命名都是
  `new-HHMMSS.*`(C# 写 `.txt` 模板、python 写 `.py` 模板, 各自格式)
- **有意差异(记录)**: python 支持并列出 **.py 插件**(C# 只有 txt, 属超集); **双击**行为 python = 运行
  (AGENTS §8 已记)、C# = 编辑; `[csharp]`/`[python]` 块的状态显示 `—`(python 不预编译, 成败要到运行时才知)
- **验证**: ① `count_steps` 10 例表 + 与 `run_steps` **实际执行步数**逐例一致(块算 1 步、未闭合块两边都不计)
  → 0 差异; ② 真 main 前缀 + 临时插件目录跑管理器 UI: 4 行文本(含 `正常 (2 步)`、两条 `解析失败`、`未加载`)、
  `badhead.txt` 被跳过、7 个按钮齐全、禁用后写 `plugins-disabled.txt` 且该行**灰显**、删除确认
  `title=WgIme` 且 `default='no'`、选否不删 / 选是删除并刷新 → 0 差异; ③ 真插件目录里 5 个已装载 .py
  状态都是 `正常`; ④ `tests\pure-state-harness.py` 16/16 通过(无回归); ⑤ dist 里 9 个模块与磁盘源码
  **逐字节相同**、内嵌 main == 磁盘 `main.py`、`dist==package` SHA256 相同(`A207682A…`)

---

## 2026-09-10 (第十七轮审计: 词典模式(mode 3) 候选 — 与 C# AddTranslate 逐条一致)

换维度: C# `AddTranslate`(5157-5174) + `AddEcPrefix` + `BuildReverse`(5176-5188) vs python
`engine.candidates(mode=3)`。方法: 在探针里**独立**解析原始 `ec.txt`(657883 条)并按 C# 源码重写
`BuildReverse`/EN 精确/EN 前缀/`AddCands`, 当成 oracle 与真 engine 比对(不复用 engine 的解析与构建)。

- **`ce`(CN→EN 反查表) 全等**: 独立 BuildReverse 与 `engine.ce` **701531 个键的键集合与值全部相同**
  (按 EN ordinal 升序扫、每中文词上限 8、去重、空释义跳过 —— 与 C# `BuildReverse` 逐行一致)
- **候选集合全等**: 73 个 code 用例(EN 精确命中 40 个抽样 + EN 前缀 15 个 + `book/bo/computer/com/
  china/chi/a/ab/continent` + 全拼/简拼 `ni/hao/shu/zhongguo/sm/zg/wo/women/xuexi/zzzz`)——
  候选**集合与数量**与 oracle 完全一致; 空输入与不存在的长码都返回空
- **唯一差异 = 排序, 且是有意的**: python 在 `candidates()` 末尾对所有模式(含 mode 3)套用 §14 的频率排序
  (`语料先验 word_freq + 学习词频×learn_k + 近期热度×recent_k`, 稳定排序); 探针用同一公式把 oracle 的顺序
  复算了一遍, 与 engine 输出**逐项相同** → 证明差异只来自这条既定升级, 不是算法缺失。
  另核对: mode 3 用**合并**频率视图(`self.freq`, 同 C# `fb = ... : Freq`)、**不做** LastPick 置顶
  (C# `lpb = (mode < 3) ? LastPickM[mode] : null` 同样为 null) —— 两处都对得上
- **结论**: 词典模式无需改动(纯核对轮)。验证脚本要点已写进本条, 便于后续回归

---

## 2026-09-10 (第十六轮审计: 托盘菜单逐项对照 — 补 4 处勾选态; 另发现 C# 侧 1 个错字)

换维度: C# 托盘菜单(626-706) + `RefreshMenuChecks`(795-806) vs python `tray.py`。方法: 真 pystray 建出
菜单树 + 假 api, 把 `tray.L` 固定成中文, 逐项断言**项目齐全性 + 勾选态**。

- **补齐(真差异)**: C# 每次开菜单都会给 8 类项打勾 —— `开关`(`Hook.IsLocked`)、4 个模式、
  `反查编码`、`简繁输出`(`Trad`)、`候选窗跟随光标`、`空闲时隐藏候选窗`、`改用剪贴板上屏`
  (`AppModes[前台] == 1`)、`标点吞字修复`(`EffectiveKeyfix()`)。python 只有 模式/反查编码/跟随光标/
  空闲隐藏(+ 自己的 整句/联想/全角标点/主题) 带勾选态, **开关、繁体输出、改用剪贴板上屏、标点吞字修复
  四项完全没有勾** → 用户从托盘看不出输入法当前开着没、简繁是否开着、当前程序是否被单独设成
  剪贴板上屏/关闭 keyfix。已补: `tray.py` 加 4 个 `checked=`; `main.py` 的托盘 `api` 加
  `get_trad` / `get_apppaste`(`APPMODES.get(前台,0)==1`) / `get_appkeyfix`(`effective_keyfix()`),
  与 C# 的判定表达式一一对应。`_on()` 包装本来就会在动作后 `_refresh()`, 所以切换后勾选态立即刷新
- **顺带发现(C# 侧错字, 未改)**: C# tray 模式菜单「内置工具」里的便签写成了 **`便笾`**
  (wgime.bat **687 行**, 全文 1 处; 正确写法「便签」在别处出现 5 次), python 用的是「便签」。
  改 C# 要走 §3 的瘦 DLL + ps1 + 15 项测试整条链(且按 §27 需用户明确要求), 留待定夺
- **有意差异(保留)**: python「选项」组多 整句输入/联想/全角标点/主题; ime 模式也保留「运行模式」子菜单;
  tray 模式多「插件」子菜单(列出插件 + 插件管理)与「应用 (config.txt)」; C# 的「固化码表…」python 无
  对应物(AGENTS §8); 结构上 python 把 编辑配置/重载配置/数据目录 放进「这个程序」子菜单(C# 单列
  「配置」组), 项目本身一个不少
- **验证**: ime 菜单树 32 项 + tray 菜单树 18 项断言 **0 差异**(把假状态翻转后勾选态也跟着变:
  开关/繁体/剪贴板上屏/keyfix 关→不勾, 模式只勾当前项, 运行模式勾当前模式);
  仓库 `tests\pure-state-harness.py` 16/16 通过(无回归); dist 里 9 个模块与磁盘源码**逐字节相同**,
  `dist==package` SHA256 相同(`624C4E57…`)

---

## 2026-09-10 (第十五轮审计: 候选窗定位/跟随链 — 逐条核对, 未发现差异)

换维度: C# `FollowCaretNow`(5132-5144) + `RefreshLabel` 的宽度钳制(5294-5299) vs python `bar.show` 的跟随分支。

- **逐条一致(核对无误, 未改代码)**: ① 跟随用的工作区 = **光标所在显示器**
  (C# `Screen.FromPoint(cr.Left, cr.Bottom)` / python `win.workarea_at()` → `MonitorFromPoint
  (MONITOR_DEFAULTTONEAREST)` + `GetMonitorInfoW`); ② **宽度上限取主屏**工作区(C# `Screen.PrimaryScreen
  .WorkingArea` / python `win.screen_workarea()` → `SPI_GETWORKAREA`); ③ x 钳进工作区、`y+h` 超下边界就
  翻到光标上方; ④ 拿不到 helper 结果时有确定性兜底(每窗口 anchor → 上次可见位 → `get_caret_pos`)，
  不会乱跳
- **有意差异(保留)**: python **每键**都重贴(35/80ms 两次 IPC 精修), C# 只在组字首键(`keys.Length == 1`)
  贴一次(AGENTS §17 的既定升级); python 宽度封顶 **880**(AGENTS §15, C# 只按主屏右边界);
  python 对开始菜单/搜索类 Shell UI 固定右下角(避开浮窗); python 的"翻到上方"用
  `光标点 - h - 6`(helper 返回**点**而非矩形), C# 用 `cr.Top - Height - 6`
- **验证**: 真 `CandBar` + 真 Win32 工作区(实测主屏 1918x992), 伪造 helper 光标位置跑 **9 项几何断言
  全部通过**: 正常位 = 光标下方 +6 / 贴右边界 x 钳到 `right-w` / 贴下边界翻上且不出界 /
  左上角钳进工作区 / 宽度 ≤ `max(240, min(工作区宽-24, 880))` / Shell UI 固定右下角

---

## 2026-09-10 (第十四轮: 状态机 headless 回归固化成 `tests\pure-state-harness.py`)

第十三轮那个 harness 原来只在 `%TEMP%` 里, 这轮固化进仓库, 以后改状态机/上屏路径可以直接跑:

- 用法: `python tests\pure-state-harness.py`(跑工作区源码, 16 项) /
  `python tests\pure-state-harness.py --ref HEAD~1`(跑某个 git 版本的 `main.py`, 做 before/after 对照)。
  退出码 `0`=全通过, `1`=有用例失败, `2`=环境不可用(缺词库 / 无桌面 / Tk 起不来)
- 做法: 真跑 `wgime-py-pure\main.py` 的**前缀**(截止到 `# ---------- 主循环: 轮询钩子事件 ----------`,
  真 engine + 真状态机), 只把副作用出口打桩 —— 注入类(`win.send_unicode/send_unicode_qtfix/
  paste_text/send_key_backspace`)、`bar.show/hide`、`engine.learn/learn_assoc/touch_recent/
  add_user_word/save_freq`、`run_launcher/find_launcher/_notify/_dfn`。不装键盘钩子、不建托盘、不注入按键
- **数据隔离**: 进程内把 `LOCALAPPDATA` 指到临时目录(退出时删除), `WGIME_DICT_DIR` 默认
  `wgime-py-pure\package\dicts`(无则仓库根); 载入后**断言** `DATA_DIR` 落在临时目录内, 否则直接退出码 2 ——
  用户真实的 `%LOCALAPPDATA%\wgime-py` 绝不会被读写。首跑会打印一条 `[wgime] dict-cache load failed`
  (隔离目录里没有缓存)属正常, 已写进脚本 docstring
- 覆盖: 空格/默认候选进自动造词链且不强化词频、连续两字自动造词、数字选候选(学词频 + 记链)、
  标点自动上屏(记链、不学频、标点本身也上屏)、动态候选/启动器/vf 面板"不学不记"、退格只删组字缓冲
- 验证: 工作区源码 **16/16 通过(exit 0)**; `--ref HEAD~1`(修复前) **3 项失败(exit 1)** —— 正是第十三轮
  修掉的那三处(空格不进 recent 链 / 连续空格不造词 / 标点自动上屏不记链); 两次运行结束后临时目录均已清理
- `AGENTS.md` §4 测试清单同步(命令 + 隔离说明)

---

## 2026-09-10 (第十三轮审计: 上屏路径 — 空格/标点自动上屏漏记「自动造词链」)

换维度: 把 C# 的**每一条上屏路径**与 python 对齐。C# 在三个地方调 `Learn` + `RecordCommit`:
① `Hook_OnSpaced`(866-882, 空格与数字选候选**共用同一段代码**) ② `Hook_OnPunct`(895, 组字中按标点
先把首候选上屏) ③ 五笔唯一四码自动上屏(5246-5256)。python `commit()` 却把
`record_commit(text, code)` 塞在 `if i > 0`(主动选择)里面。

- **后果**: "打全拼 + 空格逐字确认"这条最常见的上屏路径**永远不往 `ime.recent` 记**, 而
  `record_commit` 是**自动造词**(90 秒内连续 2–4 个单字且编码可验证 → 自动成词; 技术文档 §9 有记)
  的唯一入口 → python 的自动造词实际只在"按数字选候选"时才会触发; `handle_punct` 的
  "按标点自动上屏首候选"更是完全不走这条链(C# 895 走)
- **修法**: `record_commit` 移出 `i > 0` 门控 —— 空格/默认候选、五笔唯一四码自动上屏(走 `commit(0)`)
  都记; `handle_punct` 在自动上屏首候选时补记一笔。**词频学习(`engine.learn`/LastPick 置顶)仍按
  AGENTS §14 只对"主动选择"生效, 空格确认默认词照旧不强化** —— 这次只恢复自动造词链
- **验证**: 新建 headless 状态机 harness(真 `engine` + 真状态机, 只把副作用出口打桩:
  `win.send_unicode/paste_text/send_key_backspace`、`bar.show/hide`、`engine.learn/learn_assoc/
  touch_recent/add_user_word/save_freq`; 进程内 `LOCALAPPDATA` 指向临时目录 + `WGIME_DICT_DIR`
  指向仓库根, **不碰用户数据**), 对 **git HEAD 版 main.py** 与当前版跑同一组用例:
  - HEAD: 空格上屏不进 recent ✗ / 连续空格逐字不造词 ✗ / 标点自动上屏不记链 ✗ → 3 DIFFS
  - 当前: **6/6 OK** —— 空格进链、连续两字自动 `add_user_word(字1字2, 码1码2)`、数字选候选
    (学词频 + 记链)、动态候选与启动器"不学不记"、空格路径仍不学词频
  - dist 内嵌 main 源码与磁盘 `main.py` **逐字节相同**; `dist==package` SHA256 相同(`61692F93…`)

---

## 2026-09-10 (第十二轮审计: 键盘 hook 吞键表 — 修 Shift+操作键在组字中漏给应用)

换维度: 把 C# `KeyboardHookProc`(wgime.bat 293-385) 的**判定矩阵**与 python `hook._proc` 逐例对齐
(哪个键在什么修饰键/是否组字下被吞、吞了发什么事件)。

- **关键事实**: C# 的 `bare = !ModifierDown()`, 而 `ModifierDown()` **只含 Ctrl/Alt/LWin/RWin, 不含 Shift**
  (124-130 行) —— 所以组字中 `Shift` + 数字/退格/Esc/回车/空格/PgUp/PgDn/配置翻页键(`-`/`=`)
  在 C# 里**照样被吞**; 只有 `a-z`、`;`(SemiAsCode)、以词定字键 `[`/`]` 显式要求 `!sh`
- **python 原先把 `if shift: 透传` 放在这些分支之前**, 于是组字中按住 Shift 按这些键会漏给应用:
  Shift+退格变成"删应用里上一个字"(输入法缓冲不动)、Shift+数字把 `$%^&` 打进文档而不是选候选、
  Shift+空格插入空格而不是选首候选、Shift+PgDn 不再翻页 …… 共 **19 例**行为不一致
- **修法**: 按 C# 判定次序重排 —— 数字 → `_swallow`(退格/取消/回车/空格/翻页键, 只要求 bare) →
  `_swallow_pick`(以词定字, 额外要求 `!sh`) → 中文标点(MapPunct 语义: `/` 只有 Shift 有映射,
  `\ [ ]` 只有裸键有映射) → 再 `if shift` 透传 → 裸字母。`_rebuild_swallow` 相应拆成两组
  (`_swallow` / `_swallow_pick`), 组字中用不到的 pick 键从 bare 组里移出

**验证**: 伪造 `KBDLLHOOKSTRUCT` + 伪造 `_key_state` 直接调 `hook._proc`, 跑 **89 例**判定矩阵
(0-9 × Shift × 组字/空闲、退格/Esc/回车/空格/PgUp/PgDn/`-`/`=`/`[`/`]`/`, . ; ' / \ $`、a-z、方向键、
Ctrl/Alt/Win 组合、输入法未激活、cnpunct 关) → 与逐行从 C# 推出的期望 **0 差异**;
事件编码抽查: Shift+`;`→`0x2BA`、Shift+4(空闲)→`0x234`(¥)、裸 `;`→`0xBA`、裸 `/`→透传、
Shift+`\`→透传。before/after 对照(同一矩阵跑 HEAD 版 hook.py)恰好只有那 19 例改变, 无其它副作用。
分发件里的 hook 与磁盘逐字节相同, 用**分发件的 hook** 重跑矩阵同样 0 差异。
构建: `py_compile` 通过, dist==package SHA256 相同(`3CE91B20…`)。

**有意保留**: python 额外的 F8 硬开关、Ctrl+Alt+Q 退出、Ctrl+. 全角标点开关都在 C# 判定之前的
独立分支, 且带 Ctrl/Alt/Win 一律透传(不劫持系统快捷键)。

---

## 2026-09-10 (第十一轮审计: 插件/工具箱步骤 DSL 动词语义 — 修 `confirm` 三处 + 4 处对齐)

换维度: 把 C# `ExecToolStep`(wgime.bat 2258-2363) 的 16 个动词与 python `plugins._run_verb`/`run_steps`
逐一对语义(参数取自哪、缺参怎么办、标签怎么写), 再用**真跑**的 smoke 覆盖每条路径。

**真 bug(已修)**:
- **`confirm … | buttons=ok` 一直是崩的**: `_confirm_args(arg, confirm)` 里引用 `msgbox`, 而这个名字
  **从来没传进函数** → `NameError: name 'msgbox' is not defined` → 该步记失败。即"纯提示型确认框"
  (文档化 DSL 特性) 完全不可用。改成 `_confirm_args(arg, confirm, msgbox)` 并在 `_run_verb` 传入
- **`confirm` 的 `title=` / `buttons=` / `default=` 解析后被丢弃**: `title`/`default_no` 赋值了却没人用,
  `buttons=okcancel` 与 `yesno` 走同一条路。现按 C# 语义全部生效: `title` 进弹窗标题、
  `okcancel` 走 OK/Cancel、`default=2`(缺省) 时**缺省按钮是"否"**(对齐 C# `MessageBoxDefaultButton.Button2`,
  防在破坏性步骤上顺手回车)、`default=1` 才是"是"; 回调签名升级为
  `confirm(text, title, buttons, default_no)`, 并保留"只吃一个文本参数"的旧回调兼容(TypeError 回退)
- **`kill` 取整行 rest 而不是第一个 token**: C# 用 `tk[1]`, python 用整行 → `kill foo bar` 在 python
  按"foo bar"这个名字找进程(找不到, 一个都不杀), C# 杀 foo。改为 `tokenize(arg)[0]`
- **缺参动词静默成功**: `run`(无程序名)/`reg-set`(<4 个 token)/`reg-del`(无键路径) 在 python 直接
  `return 0` 当成功; C# 是 `tk[1]…tk[3]` 越界抛异常 → 记一步失败。三处都改成报错计失败
- **多行块控制台标签对不上**: 块在控制台里的显示名 C# 是 `shellblock→[shell]`、`shellblockx→[shellx]`、
  `psblockx→[psx]`、`psblock→[powershell]`; python 原按开标签显示(`[cmd]`/`[shellx]`/`[powershellx]` 都错)。
  现按 C# 映射: `cmd→[shell]`, `shellx|cmdx→[shellx]`, `powershellx→[psx]`

**验证**: 用分发件里的 plugins 模块(dist `MODULES['plugins']` 与磁盘 `plugins.py` **逐字节相同**)
跑 24 项真跑 smoke, **0 差异**: run 参数引号 / shell 保留原始 rest / shellx 可见控制台 / open / wait /
kill / msg(原样不展开) / mkdir(带空格路径) / file-del(单文件·通配·整目录树·盘根拒删) /
reg-set(dword·含空格字符串·binary) / reg-del(单值·整棵子树, 写后读回并清理 HKCU\Software\WgimeProbeTest) /
`[shell]` `[ps]` 真跑块 / 未闭合块跳过 / 未知动词记失败。
另自写 AST+dis 静态检查器扫 10 个模块的"未定义全局名", 只有 main.py `_EMBEDDED_PLUGINS` 一例**误报**
(有 `if '_EMBEDDED_PLUGINS' in globals()` 守卫); 拿修复前的 HEAD 版跑同一检查器能抓出
`msgbox` 这个真阳性, 证明检查器有效。

**有意保留(不动)**: python 对 `file-del`/`reg-set`/`reg-del`/`kill` 的**执行前强确认**(AGENTS §16 的安全性增强,
C# 没有); 块开标签大小写不敏感(`[Shell]` 可跑, C# 只认小写 —— 更宽松, 不收紧);
`file-del C:\*` python **拒删**而 C# 会真删(C# 只判 `TrimEnd('\\').Length <= 3`, `C:\*` 长度 4 混过判断,
dir=`C:\` pat=`*` 会把 C 盘根下文件与目录全删) —— 安全方向保留。

---

## 2026-09-10 (第十轮审计: config 键取值语义 — 修真差异 `followcaret` 白/黑名单)

换维度: 把 **C# `LoadConfig`(wgime.bat 1663-1747) 的 25 个 config 键**与 python `engine.load_config`
逐键对语义(不是只看键名在不在)。方法: 用 C# 源码表达式当"期望值函数", 造 25 个取值
(`1/on/true/0/off/false/空/yes/2/ON/True/OFF/False/ xiaohe /ziranma/ms/微软/none/key/always/unicode/tray/TRAY/IME/tray `)
× 11 个布尔/枚举键 = **275 组用例**跑 headless 探针比对。

- **真差异(已修)**: `followcaret` C# 是**白名单**(`v == "1" || v == "on" || v == "true"`, wgime.bat:1704),
  python 却写成黑名单(`v not in ('0','off','false')`)——于是 `followcaret = yes`/空值/`2` 这类
  非法值 C# 判 **关**(候选窗固定不跟随), python 判 **开**, 两版行为相反。已改为白名单
  (`engine.py`), 与 C# 完全一致; 修完 275 组 **0 差异**
- 同批核对**无误**的键: `showcode`/`keyfix`/`hideidle`/`trad`/`starton`(白名单),
  `sentence`/`assoc`(黑名单), `paste`(on/always→1, off→2, key/unicode→3, 其余→0),
  `shuangpin`(xiaohe/小鹤/flypy→1, ziranma/自然码/zrm→2, ms/微软/mspy→3), `mode`(仅 tray 生效),
  `fuzzy`(none/off/空→清空, 解析不出对即保持缺省), `phrase`(tab/空格切分), `app`(tab 三段 / 正则两段)
- **顺带核对通过的另两项数据**: `pastemode.txt` 的模式映射(clipboard/on→1, off/sendkeys→2,
  keyfix→4, keyplain→5, 其余→3) 与 C# 逐值一致; `vf` 符号面板 5 类(15/21/37/35/33 个符号,
  含 emoji)与 C# `SymCats` **逐 token 相同**; 缺省模糊音对(zh-z/ch-c/sh-s/ang-an/eng-en/ing-in/n-l)
  与 C# `DefaultFuzzyPairs` 相同
- **有意保留的差异(不动)**: 非法 `hotkey_*`/`key_*` 值 C# "保持当前字段"、python 回缺省(AGENTS §18 已记);
  python 多认单引号 `app =` 命令(`'(...)'`, C# 只认双引号); python 独有 `learnk/recentk/cnpunct/theme`
- 验证: `py_compile` 12 模块通过 → `build-wgime-pure.py` + `build-package.ps1` 重建 →
  `dist\wgime-py.py` 与 `package\wgime-py.py` **SHA256 相同**(967D99CA…), 且从 dist 里把内嵌
  `MODULES['engine']` 抠出来与磁盘 `engine.py` **逐字节相同**, 用**分发件里的 engine** 重跑
  followcaret 用例 10/10 通过

---

## 2026-09-10 (第九轮审计: 文档与代码一致性 — 清掉 5 处陈旧断言)

本轮不查功能差异, 改查**文档是否还说得对**(文档腐化 = 后续会话按错文档改代码)。逐条与代码/`git ls-files` 对照:

- `docs\WGIME_技术文档.md` §12.2 `win.py` 行仍写"UIA 光标跟随(现代应用经内嵌 `uiautomation`)", 与
  §17 的架构(主进程**绝不**初始化 COM/UIA, 跟随走独立 Caret Helper 子进程)矛盾 —— 改为子进程描述
- 同文件 §12.1 补注: `uiautomation`/`comtypes` 只是历史内嵌残留, 主进程已不 import, 别按它们写新代码
- 同文件 §12.2 `bar.py` 行、`wgime-py-pure\README.md` 约定行仍写候选条宽上限 **720px**, 实际自 `199f0bd`
  起是 `max(240, min(工作区宽-24, 880))`(AGENTS §15 早已更正, 这两处漏了)
- 同文件 §13「已知局限(C# 版)」仍写"无法自定义组合快捷键", 但 C# 早已支持 `hotkey_*`/`key_*`
  (`KeyBordHook.ParseHotkey`/`SetKeyConfig`/`MatchMods`, 见 `wgime.bat` 213/236/1725-1736 行) —— 改为
  说明默认放行 Ctrl/Alt/Win 组合、仅被配置的热键吞掉
- `README.md` 写码表"已 gitignore", 但 `git ls-files` 显示 `py.txt/wb.txt/ec.txt/import_*.txt` **是入库跟踪的**
  (AGENTS §5.5) —— 改为"已入库跟踪"并注明用途
- `docs\WGIME_Python重实现方案.md` 的"遗留大补"仍列 WgTray 与 hotkey_* —— 两者其实都已完成
  (WgTray → `mode=tray`; hotkey_* → `hook.py`), 加"2026-09 追记"只留 emoji PNG 图片版
- 顺带修 2 处 Markdown 反引号失配(使用说明 §「常用按键」的 `Ctrl + \`` 与 §9 的 `Ctrl+\`` 会把
  后续文字吞进代码段/吃掉加粗), 改写为「Ctrl + 反引号」并附 `` ` `` 写法
- 同步: `sync-dist.ps1` 已把三份文档刷进 `release\docs\`; 使用说明 §9 快捷键表、码表上限(300/码、50 万)
  逐条核对**无误**, 未改

---

## 2026-09-10 (发布 v1.2.9 — 冷启动反馈窗 + 健壮性三修)

- **GitHub release v1.2.9**: 三个资产 `wgime-v1.2.9-{bat,ps1,python}.zip`; 本版只改纯 Python 版,
  内容是第七、八轮审计的 4 项改动(冷启动反馈窗 + 健壮性三修), 其中一项是**启动崩溃修复**
- **高危修复**: 用户把 `config.txt` 存成 ANSI(GBK) 时 Python 版启动即崩(`UnicodeDecodeError`),
  C# 侧是替换式解码不会崩 —— 新增 `engine.read_text()`(utf-8-sig → gbk → utf-8+replace) 并统一到
  config/tools/plugins/pastemode/disabled/userwords/freq/assoc 等全部用户可改文本读取点
- 未闭合的多行块改为**整块丢弃**(对齐 C# `ParseToolSteps`/`LoadTools`), 不再把后续行当脚本执行
- 冷启动(无缓存 ~12s)期间显示「WgIme 正在加载词库…」置顶小窗(对齐 C# 候选条的"(词库加载中...)"),
  建表完成即销毁; 为此 `root = tk.Tk()` 提到建表之前(全文件只建一次 Tk root)
- 发布后回验: 下载线上 python 包 → `wgime-py.py` 与本地 `dist\wgime-py.py` 逐字符一致, 且含
  `read_text` / `_TOOL_BLOCK_TAGS` / `_dict_cache_stale` 等新入口
- 小插曲(已修): 发版脚本原来把 `target_commitish` 传成 `master`, GitHub 按**远端** master 解析,
  而本地那次 dist 刷新提交还没 push → v1.2.9 的 tag 落在 `4abb843`(前一提交), 而非 `3142cf5`。
  两者**代码内容相同**(只差内嵌第三方 zip 容器的几十字节, MODULES/PLUGIN_SRC 逐字节一致),
  发布的 python 包与本地 dist 完全一致, 故不影响使用; 脚本已改为传本地 HEAD sha 并加未 push 告警。

---

## 2026-09-10 (对齐项: 异常/边界压力维度 - ANSI 保存的 config 不再崩启动 + 未闭合块丢弃)

第八轮差异审计换到**健壮性/边界** (畸形 config/tools/插件/码表、缺文件、超长输入、并发 reload,
共 30 余个用例):

- **高危: 用户把 config.txt 存成 ANSI(GBK) 会让 python 版启动就崩** (`UnicodeDecodeError`) —— 中文
  Windows 下记事本"另存为 ANSI"很常见。C# 的 `File.ReadAllLines(UTF8)` 是**替换式解码不抛**。
  新增 `engine.read_text()` (`utf-8-sig` → `gbk` → `utf-8+replace`, 只以 OSError 表示不可读),
  并把**所有用户可改文本**的读取点改用它: config.txt / tools.txt / plugins\*.txt / pastemode.txt /
  plugins-disabled.txt / userwords.txt / userdict_*.txt / lastpick_*.txt / assoc.txt
  (含 main/tools/plugins/engine 四处读取逻辑)
- **未闭合的多行块原来会被执行**: C# `ParseToolSteps`/`LoadTools` 只在遇到闭标签时才把块入 steps,
  行尾仍没闭合就整块丢弃; python 会把后面所有行当脚本体跑掉。现同样丢弃并记一条 `块未闭合…已跳过`
- `upper_amount` 加非数字防御 (原来 `upper_amount("abc")` 抛 IndexError; C# 也只在校验后调用,
  但 python 侧多一层保护无副作用)
- 其余 30 例全部通过 (无需改): 空/超长(1MB)/垃圾行的 config、BOM+值含 `=`、非法 int、目录当文件;
  tools.txt 空文件/步骤在按钮前/未闭合引号/cols 非法/只有 tab/二进制内容/名字含 `]`;
  插件 txt 缺 code/空 body/垃圾 perm/空 [csharp]·[python] 块; 坏码表目录/损坏缓存 pickle/空码表文件;
  超长编码(10k)/33 字符整句/`v`+17 位/孤立代理字符; `reload()` 与 3 线程同时读候选(零异常)
- 真实加载路径复核 (不是只看单函数): `load_py_plugins` 对语法错误/顶层抛异常/缺 CODE 的 .py
  只跳过不崩; `_list_plugin_files` (插件管理器列举) 走 AST 不执行坏文件; `_run_py_file_once` 有兜底

---

## 2026-09-10 (对齐项: 性能路径维度 - 冷启动反馈窗 + 启动/缓存实测基线)

第七轮差异审计换到**启动与缓存性能路径** (全程实测, 数字记入 AGENTS §6):

- **冷启动 10s+ 期间毫无反馈** (对齐缺口): C# 先起 UI, 候选条立刻显示"(词库加载中...)";
  python 是同步建表后才建窗口 —— 无缓存时约 12s 黑着没有任何提示。现新增
  `_dict_cache_stale()`(缓存缺失或比任一码表旧 → 本次会重建) + 建表前显示 320x72 无边框置顶
  「WgIme 正在加载词库…」小窗, 建表完成即销毁; 为此把 `root = tk.Tk()` 提到建表之前
  (**全文件只创建一次 Tk root**, `bar = CandBar(root)` 复用)
- **量化基线**(改动前先看): 冷启动 ≈12s(ec 解析 1.1s / build_reverse 3.3s / build_acro 2.0s /
  build_char_py 0.45s / 三组 build_sorted 0.5s / 写 90MB 缓存 2.4s); 热启动 ≈2.9s(pickle.load 90MB
  ≈2.1-2.4s); 每键热路径 0.005-0.25ms —— 热路径无需优化
- **否决了一个看似划算的"优化"**: 缓存里 `pk/pv/wk/wv/ek/ev` 六个派生数组占 ~57MB, 看着该改成
  启动时重建; 实测**净亏 308ms**(缓存只省 13.5MB, 重建要 487ms), zlib 压缩缓存同样不划算
  (145MB→42MB 但解压 +652ms) —— 结论写进 AGENTS, 防止后来者重复"优化"
- 顺带确认: `rev_wb_code` 反查表是惰性一次构建(首次 ~1.2s), 之后 O(1)(首轮曾误读为"每次 6.8ms",
  实为首次建表被 200 次平均)

验证: `_dict_cache_stale` 三态(无缓存/缓存旧/缓存新)正确; 启动顺序 root→engine→splash.destroy→CandBar
且只创建一个 Tk root; 真跑模块级启动无异常(root/bar 就绪, splash 已清空)

---

## 2026-09-10 (发布 v1.2.8 — 六轮 C#↔Python 差异审计的 27 项对齐)

- **GitHub release v1.2.8** 已发布 (tag 指向 `ee24358`, 与本地 HEAD 一致): 三个资产
  `wgime-v1.2.8-bat.zip`(1.64MB) / `wgime-v1.2.8-ps1.zip`(25.99MB) / `wgime-v1.2.8-python.zip`(24.28MB);
  release body 1903 字符, 中文无问号 (显式 UTF-8 字节发送)
- **发布后回验** (连续两次发布都做, 防 v1.2.7 那种"发了旧构建"事故): 下载线上 python 包 → 解出
  `wgime-py.py` 与本地 `dist\wgime-py.py` **逐字符完全一致** (672044 字符), 且新入口
  (`_TOOL_BLOCK_TAGS` / `build_rev_wb` / `single_instance` / `toggle_trad` / `run_tool_code` /
  `assoc_enabled`) 全部在包内
- 本版只改纯 Python 版 (bat/ps1 与 v1.2.7 内容相同); 内容为六轮审计的行为对齐, 无新功能:
  配置与快捷键 (AGENTS §18-20) / 输入算法 (反查方向·英汉表隔离·双拼门控·通配序, §21-24) /
  注入与步骤 DSL (emoji keyfix·%env% 展开位置·paste=off) / 工具栏与状态反馈
  (tools.txt 块标签·插件启停·气泡反馈, §16·25-26) / 候选条 (空闲提示·`[模式|开]`) / 插件契约
- AGENTS §5 新增 18–27 条把这一批的语义与"别再改回去"的约束固化; §5.27 记录**反向差异清单**
  (python 有 C# 没有的功能, 以及 C# `inDialog` 有意不跟进)

---

## 2026-09-10 (对齐项: tools.txt 结构解析维度 - 块别名被当成按钮的真 bug)

第六轮差异审计换到**tools.txt / 插件 txt 的加载解析** (C# `LoadTools` vs python `load_tools`):

- **`[cmdx]` / `[powershellx]` / `[/cmd]` / `[/ps]` 等标签被当成"按钮" (真 bug)**: python 的
  按钮判定用的是**不完整的排除正则** (只列了 shell/cmd/powershell/ps/shellx/psx 与 4 个闭标签),
  于是 `[cmdx]`、`[powershellx]` 会被建成名为 "cmdx"/"powershellx" 的假按钮, 块内容也错位成它的
  步骤。C# 的 LoadTools 明确把这 8 个开标签当块处理 (闭标签由开标签推导)。现用完整 frozenset
  (8 开 + 8 闭) 判定, 并对齐 C# 的 "闭标签必须与开标签匹配"(`[ps]` 只由 `[/ps]` 收尾)
- 顺带补齐两个 C# 解析细节: **`[button 名]` 前缀** (python 原来把 "button 名" 整个当按钮名)、
  **`code = xx` 可写在步骤之后** (python 原来要求必须在步骤前, 否则忽略)
- 审计确认一致: tab/cols/按钮/`code=`/步骤的**结构**在真实 `tools.txt` 与合成样例上逐项相同;
  `run_steps` 的块执行语义与 C# `ParseToolSteps`+`ExecToolStep` 相同 (含 `[cmdx]`/`[powershellx]`
  生成 shellblockx/psblockx、`[ps]`/`[cmd]` 的正常配对)
- 反向差异盘点 (python 有 C# 没有, **暂不动 C# 侧**: 改动 wgime.bat 需走瘦 DLL + ps1 + 15 项测试
  整条链, 属独立特性决策): `cnpunct`/Ctrl+. 全角标点切换、`F8` 硬开关、`Ctrl+Alt+Q` 退出、
  候选条主题、`learnk`/`recentk`、剪贴板「粘贴上屏」、`_CLIP_FORCE`(开始菜单强制剪贴板上屏)、
  tray 的整句/联想/全角标点开关 —— 已记入 AGENTS "反向差异" 清单, 待用户定夺
- C# `inDialog`(模态框期间让按键直通) **有意不跟进**: python 的造词/导入对话框含文本框, 需要输入法可用

验证: 真实 tools.txt 结构 (2 tab / 6 按钮 / `code=qlj` / cols) 与 C# 直译逐项相同;
合成样例 `[button 名]`+`code=` 后置+四种块别名结构与 C# 完全相同;
块语义 3 组 (别名配对 / `[ps]`+`[/powershell]` 混闭按 C# 规则吃到 `[/ps]` / 全部四别名) 逐项正确

---

---

## 2026-09-10 (对齐项: 导入转换 + 步骤 DSL 解析/执行维度)

第五轮差异审计换到**码表导入/转换算法**与**步骤 DSL 的解析/执行**:

- **`read_import_text` 兜底**: C# 的解码链 UTF-8(严格)→GB18030→GBK, GBK 解码在 .NET 里**永不失败**;
  python 三级失败后用 `utf-8+replace` 兜底 —— 改为 `gbk+replace`, 与 C# 的兜底解码语义一致
- **`tokenize` 原来会 `%env%` 全行展开** (C# `ToolToks` 不做展开, 展开只在各动词里按规则做):
  修掉后, `run` 只展开**程序名** (C# 展开 tk[1], 参数原样)、`reg-set/reg-del` 仍按 C# 展开注册表路径、
  `shell/shellx` 不再预先展开 (交给 cmd 自己展开, 与 C# 完全一致)。同时补齐 C# 的
  "空白含 tab" 与"未闭合引号吃到行尾"两个细节
- **`msg` 动词**: C# 是气泡标题 `WgIme` + 原文**不展开**; python 原来标题 `提示` 且展开 %env%。已对齐

审计确认**本来就一致**的: `SkipLine`(空/#/;//、---、...、yaml `key: value` 头) / `DetectFormat`
(tab 判词在前 / 首字段纯 ASCII 判码在前, 200 行探测) / `ConvertFile`(尾权重字段、EN 词+CN 释义、
词内空格计 skipped、单码 300 词上限、50 万码上限、大小写归一) / `ValidCode`(`^[a-z][a-z0-9']{0,31}$`) /
`SuggestTarget`(wubi/拼音/english 关键字 + yaml/yml/dict 默认五笔) / `_tool_path`(strip/去引号/展开) —
— 用整组 Rime yaml / ec 风格 / 权重行 / 空行注释混排输入做差分比对, 全部一致

验证: tokenize 9 例逐条一致 (空白含 tab/引号分组/未闭合引号/混排); `run` 程序名展开而参数原样;
`shell` 不预先展开; `msg` 标题与原样; 导入转换在 6 组样例上 acc/计数完全一致

---

## 2026-09-10 (对齐项: 候选条维度 - 常驻窗空闲提示 / 头部模式开关标记 / AGENTS §15 宽度定论同步)

第四轮差异审计换到**候选条渲染与交互**:

- **常驻候选窗缺 C# 的空闲提示**: hideidle=0 时 C# 显示 `   (Shift开关 Ctrl+`模式 vf符号)` 提示行,
  python 只显示模式头。现常驻窗同文案展示 (hideidle=1 空闲照常隐藏)
- **候选条头部缺模式开关标记**: C# 头是 `[混合|开]  ` (模式名 + 开/关状态), python 只有 `[混合]`。
  现补 `|开` (关时候选窗本就隐藏, 与 C# 的可见规则一致)
- **AGENTS §15 与代码脱节的纠正**: §15 写的是候选条宽上限 720px 并给了旧公式, 但代码实际是
  `max(240, min(屏宽-24, 880))` —— 来自用户定论 `199f0bd`「修复候选框超出屏幕」。是**文档过期**
  (不是代码错), 已把 §15 改成实际公式并注明"别改回 720 或铺满屏", 防止后续会话按旧文档误改
- 复核一致: 页码/候选编号/选中高亮/截断档位/拖动/跟随光标/多屏钳制/开始菜单固定右下角等
  (python 的页码 `◀ n/m ▶` 与选中高亮是刻意保留的增强项, C# 是纯 `(n/m)` 无高亮)

---

## 2026-09-10 (对齐项: 状态反馈/托盘气泡 + 插件契约维度)

第三轮差异审计换到**托盘图标与状态反馈**, 顺带把**插件系统契约**也核了一遍:

**插件契约**
- **插件管理器「启停」对 .py 插件完全无效 (真实 bug)**: C# 的 `plugins-disabled.txt` 存的是
  **小写文件名** (`DisabledPlugins`), 插件管理器写入的也是文件名; 但 python 的 `load_py_plugins`
  按 **CODE** 过滤 (`code in disabled`) —— 管理器禁用 `calc.py` 后, 装载器拿 code `jsq` 去匹配,
  永远中不了, 插件照样启用。现统一为: `.py` 装载器按文件名禁用 (`fn.lower() in disabled`,
  与 C# 及管理器一致; 内嵌插件无文件才退回 code, 生产分发不内嵌插件故无影响),
  `.txt` 装载器与读名单处统一**两侧都小写** (防 `Calc.TXT` 这类文件名大小写不一致误判启用)
- manifest 解析 (code/name/desc 顶部头) / `[csharp]` 编译路径 / `plugin:`/`codeplugin:` 注册与
  "插件后注册覆盖内置" 的优先级 / disabled 文件格式 —— 与 C# 一致 (此前已对齐, 复核无差异)

**托盘图标与状态反馈**
- 图标部分**早已一致** (不用改): 模式字 中/拼/五/译, 配色 #0078D4/#00B7C3/#CA5010/#881798,
  关闭态暖灰 #BEB9B3, 64px 圆角方块 (~22% 圆角) + 字符镂空, tray 模式"工"字蓝底 —— 与 C# `MakeIcon`
  逐字段相同
- **钩子装不上不再静默**: C# 在 hook 安装失败时弹错误气泡; python 的 `hook.start()` 原来不检查
  结果。现 `hook.start()` 同步等安装完成 (上限 2s) 返回成功与否 + `hook.last_error()`,
  main 在失败时气泡提示 `键盘钩子安装失败 (err N)`
- **结果反馈气泡补齐** (C# 全有, python 原来只写 debug 日志):
  - 造词: 剪贴板无 2-8 汉字 → 警告气泡 (python 保留造词对话框可手输, 只是不给预填)
  - 托盘「改用剪贴板上屏」「标点吞字修复」→ 结果气泡 (`name 改用剪贴板上屏` / `已恢复默认上屏` /
    `已单独关闭/开启` / `已恢复全局默认`; 获取不到前台进程 → `切换失败` 警告)
  - 启动器启动失败 → `启动失败: name: 错误`
  - 步骤 DSL 插件 → `开始执行…` + `完成` / `完成, N 个步骤失败` / `已取消` / `执行出错` 气泡
    (与 C# RunCodePlugin 相同)
  - [csharp] 插件编译失败 / 运行出错 → 气泡
  - 工具箱空文件、批量造词两条警告 → 由弹窗改为气泡 (对齐 C# TrayTip)

验证: `hook.start()` 成功路径 True/err=0、二次调用幂等; 桩探针确认 9 类气泡的标题与文案;
插件启停端到端 4 项 (.txt 大小写混合文件名禁用命中 / .py 按文件名禁用与恢复 / 管理器格式回放)。

---

## 2026-09-10 (对齐项: 输入算法维度 - 反查编码方向 / 双拼下的动态候选 / 英汉表参与模式)

第二轮差异审计换维度: 不查配置与界面, 查**输入算法的数据与规则**。
同轮后半段还审计了注入路径与几个纯函数, 一并记录:

- **keyfix 下 emoji 被误判为 trigger**: C# `UnicodeCommitQtFix` 把代理对(astral/emoji)视为**非** trigger
  原样注入; python 只判断 `code >= 0x3000`, 于是 emoji 的高/低代理半码(0xD83D/0xDE00)都被当成全角标点,
  每个半码插一对 X+Back —— 上屏 emoji 会带出多余擦除动作。已排除 0xD800..0xDFFF
- **`paste = off` (mode 2)** 原来只是 `pass` 后继续走 keyfix 注入; C# 该分支是 SendKeys(**不套** keyfix)。
  python 无 .NET SendKeys, 现在明确退回"普通 key 注入且不做 qtfix", 与 C# 分支语义一致
- **_build_wb_len 桶内改按码 ordinal 升序**: C# `AddWubiWildcard` 是 `foreach(OrderBy(key))`,
  python 原来按字典插入序 → z 通配候选顺序可能与 C# 不同 (AGENTS §11 点名的同一类坑)
- `is_all_cjk("")` 原来返回 True (C# 返回 False), 已补 `bool(s)`
- 审计确认**已一致**(无需改): 金额 `UpperAmount`/`Thousands` 35 例(含 16 位上限/前导零/跨组零)、
  v 模式候选顺序与边界、`BestSentence` 7 组输入、SendInput 事件序列 13 例(含 emoji 混排)、
  z 通配自身顺序(exact 优先 + 通配按码升序)

- **反查编码方向搞反了** (`showcode`): C# `CodeHint` 是"五笔模式显**拼音**码, 其余模式显**五笔**码",
  python 恰好相反 (拼音模式显示拼音码 = 把你刚打的码再显示一遍, 毫无意义)。现按 C# 修正, 并新增
  `engine.build_rev_wb`(词->五笔码, 按码 ordinal 升序扫、每词取最小码, 与 C# `BuildRevWb` 同规则) +
  `Engine.rev_wb_code()` 惰性建表 (首次 showcode 才建, 造词/重载后自动失效)
- **双拼模式下动态候选没关**: C# 在 `if (Shuangpin == 0)` 内才挂 rq/sj/xq、v 金额、启动器候选
  (两键即音节, 会撞码); python 无条件挂载 —— 双拼下打 `sj` 会插入"时间/14:07"候选。
  已同步门控, 并把 `digit_as_code()` 补上双拼判断; 另补 C# 的两处面板安全复位
  (`symCat>0 && keys!="vf"` / `Shuangpin>0` 时清 symCat)
- **英汉表(ec)在拼音/混合模式参与候选** (C# 只在「词典」模式用): 实测拼音模式打 `no` 给出的是
  **不/没有/无/吃/头/开**(词典释义), 把正确的 **弄/浓/农** 顶出前 8; `it` 更是只有词典释义。
  现按 C# 只在 mode 3 查 ec —— 拼音 `no` -> 弄/浓/农, 词典 `no` -> 不/没有/头/... 两不误。
  同时词典模式的 EN 前缀匹配改为给出**每个命中词的全部释义** (C# `AddCands`), python 原来只取首释义
- **五笔四码自动上屏**未排除启动器候选: C# 有 `!appSet.Contains(cands[0])` 守卫, 否则会变成
  "自动启动程序"; python 已补上同样判断

审计中确认**已对齐**的: 双拼三套方案表 (小鹤/自然码/微软) 规则逐条一致 + 2271 项输入行为完全一致;
模糊音变体 (含 16 上限/去重/迭代顺序/自定义 pairs) 18 项完全一致; rq/sj/xq 格式; 符号面板 5 类 141 个符号;
候选上限 60 / 简拼 60 / 五笔 z 通配 / 字频保存节流 / AddFromDict 二分前缀查找(前缀只收单字、exactWubi、
extendable 标记) 等。

验证: 上述每项都有对照冒烟 (反查方向 3 种模式、反查表惰性建立与造词后失效、双拼门控 8 项、
英汉表按模式隔离用真实码表实测 4 组词 + 词典前缀 2697 键)。

---

## 2026-09-10 (对齐项: 可配置快捷键/候选键 (hotkey_* / key_*) + 单实例 + 联想开关真生效)

一轮 C#↔Python 差异审计后补的功能对齐 (都不是"新功能", 而是 Python 版缺/写死的地方):

- **`hotkey_*` / `key_*` 配置键在 Python 版完全没被读取** (C# 支持可配置快捷键与候选操作键,
  Python 侧键位全写死在 `VK['SPACE']`/`hook._CTRL_KEYS` 里, 用户改了 config 毫无反应):
  - `hook.py` 新增 `vk_from_name` / `parse_hotkey` / `configure` / `_rebuild_swallow` 与 `HOTKEYS`/`KEYS`
    状态 (键名表/修饰键严格匹配/none=禁用/无效值忽略, 全部对齐 C# `VkFromName`/`ParseHotkey`/`MatchMods`)
  - `engine.load_config` 原样收下 `hotkey_*`/`key_*` (缺省留在 hook, 删行即回缺省);
    `main.apply_config()` 调 `hook.configure(...)` 安装, `main.handle()` 的按键分派全部改读 `hook.KEYS`
  - 语义对齐: 热键在"输入法未激活"时也生效 (C# 判定在 IsLocked 之前); `hotkey_toggle` 配成非 `shift_tap`
    时 Shift 轻拍停用; 组字中吞的候选键 = 配置键 + PgUp/PgDn 常驻; `key_pickfirst/last` 改键后
    `[`/`]` 回归"【】"标点
- **单实例保护**: Python 版原来可以双开 (两个键盘钩子互相吞键 + 两个托盘图标)。新增
  `win.single_instance()` (ctypes 命名互斥体, 对齐 C# `WgImeSingleInstance`) + `win.message_box()`
  (纯 Win32 弹窗, 启动早期不建 tk); 名字用 `WgImePySingleInstance`, 与 C# 版互不干扰;
  测试可用 `WGIME_NO_SINGLETON=1` 跳过
- **联想开关以前是"假开关"**: 托盘「联想」与 `assoc = 0` 只翻转勾选态, 实际照学照显示。
  新增 `engine.assoc_enabled` (由 `main.apply_config` 同步), `learn_assoc` 提前返回、`get_assoc`
  返回空、`main.show_assoc` 提前返回 —— 对齐 C# `AssocEnabled` 对学习与显示的双重门控
- **简繁切换不持久化**: Ctrl+Shift+F / 托盘切了简繁, 重启后回到 config 里的旧值 (C# 会
  `SaveConfigKey("trad", …)`)。新增 `main.toggle_trad()` = 翻转 + `_write_config('trad', …)` +
  reset + 刷新托盘, 键盘与托盘两条路径共用
- `config.txt` 补上两版共用的 `hotkey_*` / `key_*` 说明与缺省值 (老 WgTray 的
  `hotkey_toolbox/plugins/menu` 标注为退役遗留, 两版都不再读取)

验证 (全部实测, 无键盘注入): `vk_from_name` 34 例 / `parse_hotkey` 11 例逐项对齐 C#;
`hook.configure` 缺省→自定义→回缺省三态正确 (`none` 禁用、非法值保持缺省、swallow 集含 PgUp/PgDn);
把 main.py 的"主循环"段切掉后 exec, 用桩 commit/inject 探针跑按键分派 22 项: 缺省 space→commit、
enter→原样上屏、esc→reset、`[`/`]` 组字中→以词定字 (空闲→【】)、`key_first=enter` 后 space 无动作、
`key_cancel=none` 后 esc 无动作、`key_pickfirst=none` 后 `[` 回到【、`key_pickfirst=tab` 后 tab 定字、
`key_pageup=pgup` 后 PgUp 翻页; 单实例互斥体同进程/跨进程重复启动均被拦、持有者退出后可用;
联想关闭后学习与显示都被拒。

---

## 2026-09-10 (发布 v1.2.7 + 发布流程脚本化)

- **GitHub release v1.2.7** 已发布 (tag 指向 `f512c28`): 三个资产 `wgime-v1.2.7-bat.zip`(1.64MB)/
  `wgime-v1.2.7-ps1.zip`(25.99MB)/`wgime-v1.2.7-python.zip`(24.27MB); release body 走显式 UTF-8 字节,
  中文无问号. 本轮只有纯 Python 版有变化(bat/ps1 与 v1.2.6 内容相同), 为整体下载一并附上.
- **新增 `tests\build-release-assets.ps1`**: 一键产出三个发布 zip. 三条踩坑经验写进脚本:
  ① `.NET ZipFile.CreateFromDirectory` 在 Windows 上写 `\` 分隔条目 —— 改为逐条
  `CreateEntryFromFile` 并统一转 `/`(脚本自检, 出现反斜杠条目直接 throw);
  ② 源目录必须取长路径(`Get-Item -LiteralPath`), 用 8.3 短路径会把 `ADMINI~1` 带进 zip 条目名;
  ③ **python zip 取自 `wgime-py-pure\package\`(构建产物), 改完源码必须先在 `wgime-py-pure\` 跑
  `build-package.ps1`** —— 否则会把**上一个构建**发出去(本轮实际踩到: v1.2.7 首次上传的 python 包
  缺了 `数据目录…` 那次改动, 靠"下载已发布资产与本地 dist 比对"才发现); 现已加**哈希守卫**:
  `package\wgime-py.py` 与 `dist\wgime-py.py` 不一致直接 throw. 顺带确认: dist 重复构建的字节漂移
  只发生在内嵌第三方 zip 容器(84 条目内容逐字节相同), 模块源码部分稳定.
- **新增 `tests\publish-release.ps1`**: 创建/更新 release + 上传资产. body 用 `HttpWebRequest` +
  `[Text.Encoding]::UTF8.GetBytes()` 显式发送(规避 PS 5.1 把中文 body 变 `?` 的老坑, 见 AGENTS §7);
  上传超时放宽到 15 分钟(25MB 资产会超过默认 120s). Token 来源顺序: `-Token` → `$env:GITHUB_TOKEN`
  → `$env:GH_TOKEN` → **Windows 凭据管理器**(`git:https://github.com`, 用 `CredRead` 直读) →
  `git credential fill`(放最后: GCM 可能弹 UI 卡死整条流程, 本轮就踩到过).

---

## 2026-09-10 (wgime-py-pure: 内置工具 1:1 收尾 - 工具箱 ToolsForm + tools.txt 启动编码 + 用户词表/批量造词)

接上轮「内置工具 1:1 复刻」, 补齐工具箱本体与剩余 C# 内置对话框。

- **工具箱** (`show_toolbox`, C# ToolsForm 342 行): 560x470, 标签页按 `[cols N]` 磁贴平铺 (Canvas+滚动条),
  底部深色日志控制台(H-118), 磁贴区支持**鼠标滚轮**(逐个控件绑 `<MouseWheel>`, 对齐 C# WheelFilter);
  **逐步日志对齐 C# RunAction**: 先输出该步日志, 再打 `  [ok] <原始行>` /
  `  [失败] <原始行>  ->  <原因>`, 收尾 `-- 完成 --` / `-- 完成, N 个步骤失败 --` / `-- 已取消 --`;
  防重入(运行中再点直接忽略, 按钮变底色), 单例(已开则 deiconify+lift)
- **步骤执行层语义补齐** (`plugins.run_steps`): 新增 `on_step` 回调(工具箱逐步日志用) 与
  `StepResult`(int 子类, 带 `.aborted`)——confirm 拒绝 = abort 中止本按钮**全部后续步骤**(对齐 C# ExecToolStep),
  与「破坏性动词确认被拒 = 只跳过该步」区分开
- **`code = xxx` 启动编码消费** (对齐 C# `Apps[code] = {"工具:名称","tool:"+code}`): `main.find_launcher`
  扫描 tools.txt 按钮 code 命中后返回 `工具: 名称` 候选, 上屏即后台执行该按钮(等价点击), 结果以
  **托盘气泡**汇总 (`tools.run_tool_code`: 输出行 ` | ` 拼接, 无输出则用完成/失败/已取消文案);
  冲突优先级按 C# 后注册者胜重排: 插件 > tools.txt code= > config app= > 内置别名
- **气泡取代弹窗** (对齐 C# ShowBalloonTip): `msg` 步骤与工具执行结果走托盘气泡
  (`tray.Tray.notify` + `tools.set_notifier`), 无托盘时自动退回弹窗
- **批量造词** (`show_batch_makeword`, C# BatchMakeWords + ConfirmWordsDialog): 选 txt 词表(UTF-8/GB18030
  自动识别, 64MB 上限) → 收集 2-8 汉字去重 → 「检测到 N 个词 (跳过 M 行)」确认框 → 一次性注入
- **用户词表** (`show_user_words`, C# UserWordsDialog + ManageUserWords): 列表(词/编码, 按词序排列,
  多选) + 全选/全不选/删除选中/关闭; 删除只先落盘 userwords.txt, 随后后台 `engine.reload()` 重建词库
  (对齐 C# BuildDicts + ApplySwap); engine 新增 `add_user_words_batch`(一次排序一次落盘) 与
  `remove_user_words`; 托盘「词库」菜单补齐 造词/批量造词…/用户词表…/导入码表…
- **固化码表**: python 版无内嵌码表数据块(py/wb/ec.txt 即源文件, import_*.txt 恒为持久叠加层),
  导入即固化, 故不做 C# 的「烘焙回 bat」对话框; 已在 README 说明

验证: py_compile 全绿; 冒烟 — 六个内置窗口建窗+销毁 OK; confirm 拒绝中止后续步骤(fails=0/aborted=True,
后续 `run` 未执行) / 接受继续; 块别名 `[shell]…[/shell]` 逐步日志与 on_step 契约正确; `qlj` 命中
`('工具: 清理我的临时文件','tool','qlj')`、`itools/net` 仍走内置、未知编码返回 None; `run_tool_code`
命中执行+气泡汇总(`out: HI3 | exit 0`)、未命中给提示; 批量造词 5 行→2 词(重复/非汉字/超长各跳过);
用户词表删除→userwords.txt 落盘→reload 后拼音表已清除; dist 重建(659KB)含全部新入口.

---

## 2026-09-09 (wgime-py-pure: 内置工具 1:1 复刻 C# 版 - 网络工具/便签/剪贴板/取色器)

用户要求: py 版 wgime-py.py 的内置工具(非 plugins 目录)全部 1:1 复刻 C# 版对应窗体。
tools.py 四个内置工具按 C# NetToolsForm/NoteForm/ClipForm/ColorForm 重写:

- **网络工具** (`show_nettools` 重写, C# 808 行): 7 页签 (Ping/Tracert/DNS/HTTP/端口/子网/本机),
  每页**独立日志缓冲**(切页不丢); 探测全为模块级纯函数: 手写 DNS UDP 协议(可选服务器+7记录类型+TTL/
  NXDOMAIN), 子网全家桶用标准库 ipaddress(计算/拆分N子网/范围转最小CIDR/掩码速查表/地址类型),
  端口检测带耗时+原因+13常用端口扫描, HTTP 带状态码/Server/Content-Type/Body字节/TTFB+总耗时/
  HTTPError 状态码提取, Ping 带参数(次数0=∞/包大小)+丢包率与RTT统计+停止按钮(Popen 自持可终止),
  Tracert 逐跳(TTL递增+done即停), 本机枚举网卡(ipconfig /all 解析)+公网IP; 每页清除/保存/复制全部
- **便签** (`show_notes` 重写, C# 358 行): 多便签标签(上限9/chip标题取首行/删除后稠密重编号/
  notes-meta活动tab持久化/旧notes.txt迁移), 800ms防抖自动保存+已保存状态提示, 6色Win11 pastel主题
  +色点切换+note-color持久化, 窄滚动条, 单例防多开
- **剪贴板** (`show_clipboard` 重写, C# 83 行): 全局去重+移置顶(对齐 ClipPush), 容量 200, 0.3s 轮询
  (tk 无 WM_CLIPBOARDUPDATE 钩子折中), 清空历史按钮, 单击/双击条目即复制回剪贴板, Esc关闭; 保留
  python 独有「粘贴上屏」
- **取色器** (`show_color` 重写, C# 100 行): 鼠标钩子点取+锁定(WH_MOUSE_LL, 吞掉点击, 右键取消,
  取完卸钩, 回调防GC), 三格式显示 HEX/rgb/HSV(自实现 RGB→HSV 对齐 ColorHsv), 复制 HEX; ctypes
  低级钩子回调线程自带 GetMessage 消息泵

验证: py_compile 全绿; 子网/拆分/CIDR/速查表纯逻辑自检正确; 四工具建窗冒烟全部 OK; dist/package
重建(654KB)且字节一致; 内置工具函数全部存在.

剩余: 工具箱 ToolsForm(C# 342 行: 日志控制台/磁贴滚动/confirm管道选项+中止语义/防重入/code=启动编码
消费/块别名 cmdx·powershellx/[ps]闭标签/reg binary·删树) 留待下轮.

---

## 2026-09-09 (wgime-py-pure: 托盘菜单插件列出运行 + 插件管理器复刻 C# 完整功能)

- 用户反馈: tray 菜单应列出 plugins 目录插件并可直接运行; py 版插件管理器只会看列表无管理功能
- **托盘「插件」子菜单** (`tray._plugins_menu`): 枚举 plugins 目录全部插件(.py/.txt, 过滤禁用),
  点击即运行; 尾部接「插件管理…」; 两模式菜单均含
- **main 插件接口**: `_list_plugin_files()`(静态扫 manifest 列清单, .py 读 CODE/NAME/PERM, .txt 走
  parse_plugin) + `_run_plugin_file()`(.py 复用已加载模块/即时加载后权限确认运行; .txt 按 kind 走
  steps/[python]/[csharp] 分派) + `_plugin_dir()` + `_reload_all_plugins()`(插件管理器专用轻量重载)
- **插件管理器复刻 C#** (`tools.show_plugin_mgr` 重写): 列表(名称/编码/类型/启停/版本/文件) +
  按钮条(重载/启用禁用/打开目录/编辑/删除…/新建模板…/运行) + 双击运行 + Esc 关闭;
  类型区分 py/C#/py块/DSL, 状态区分启停, 删除/新建带确认, 新建生成 .py 模板
- 插件管理器签名扩展: `show_plugin_mgr(plugins, data_dir, reload_fn, run_file_fn, list_files_fn, plugin_dir_fn)`
  (main 两处调用点已带 run/list/dir 回调)
- 验证: py_compile 全绿; 插件列举(7 个: 5 py + 2 steps)正确识别 kind/code/enabled; 插件子菜单
  构建正确; 单文件 dist 内嵌含全部新逻辑; dist/package 字节一致

---

## 2026-09-09 (wgime-py-pure: ime 模式托盘菜单只保留输入法控制项)

- 用户反馈: py 版 ime 模式不应显示 tray 模式的工具类菜单
- `tray.py _ime_items()`: 移除「工具箱… / 内置工具」组, ime 菜单 = 开关/模式/选项/
  词库/这个程序/运行模式/退出; 工具在 ime 模式仍可用输入码 itools/net/clip/bj/ys 唤起
- tray 模式菜单不变(工具箱/内置工具/插件管理/config 应用)
- C# 版核对: wgime.bat ime 菜单本就不含工具项, 无需改
- 重建 dist/package; AGENTS.md §8 / wgime-py-pure\README.md 描述同步

---

## 2026-09-09 (删除 wg-all 分发目录 - 分发统一收敛到 release)

- 用户确认 wg-all 冗余: release 已含完整分发(wgime.bat + WgIme.ps1 + 码表 + docs + plugins),
  wg-all 只是 ps1 子集副本(install.bat + WgIme.ps1 + config/tools/plugins)
- git rm 整个 `wg-all\` (12 文件); 分发统一到 `release\`
- 脚本同步: `build-wgime-ps1.ps1`(不再写 wg-all, 只写 root + release)、`build-wgime-dll.ps1`
  (默认输出改临时目录)、`sync-dist.ps1`(只同步 release)、`vt-scan.ps1`(默认扫 release)
- 文档: README.md / AGENTS.md 的 wg-all 引用全部改为 release; 删除已完成的
  MERGE-TRAY-PLAN.md 方案文档
- 验证: sync-dist.ps1 新逻辑运行正常(只刷 release)

---

## 2026-09-09 (wgtray 退役 - 分发收敛为 bat/ps/py 三件套, 各含 ime/tray 运行模式)

- **删除独立 WgTray 全部产物** (19 文件, git rm): 根 `wgtray.bat`/`wgtray-nopayload.bat`/
  `WgTray.ps1`/`WgTray-nopayload.ps1`, 构建链 `build-wgtray.ps1`/`build-wgtray-dll.ps1`/
  `rebuild-tray.ps1`/`wgtray_glue.cs.txt`/`wgtray_ps_body.txt`/`wgtray_seed_patches.txt`,
  tests `wgtray.tests.ps1`/`wgtray-ps1.tests.ps1`/`check-tray-payload-consistency.ps1`,
  分发 release/wg-all 的 6 个 WgTray 文件 —— `mode=tray` 完全替代 (历史在早期 git 提交)
- **wg-all\install.bat**: 改为单入口 WgIme.ps1 (config mode 决定形态); 参数 ime/tray 强制写 config 后启动
- **vt-scan.ps1**: 扫描清单更新为 WgIme.ps1 + install.bat
- **release\wgime.bat** 同步为最新 (含 tray 模式); release 顶层只剩 wgime.bat/WgIme.ps1/config/tools/plugins/dicts/docs
- **文档**: README.md(头部/运行模式/构建/文件说明/演进/许可)、release\README.txt、wg-all\README.txt、AGENTS.md(§1-§5/§7) 全面更新为"单程序双模式"
- 分发最终形态: `wgime.bat`(bat) + `WgIme.ps1`(ps1) + `wgime-py-pure`(py), 每版都支持 `mode=ime|tray`

---

## 2026-09-09 (wgime: 修复运行模式消息循环 bug + ps1 版重建获得 ime/tray)

- **修复严重 bug**: 上一提交 0b76208 在清理诊断日志时误删了 RunApp 的
  `Application.Run(form)` 消息循环(整行随 RUNAPP 日志行一起被过滤), 导致 ime/tray 启动后
  RunApp 立即返回、进程秒退(托盘消失)。本轮发现并恢复:
  `if (TrayMode) { Application.Run(); } else { Application.Run(form); }`
  - tray 模式: 候选条窗体隐藏, 用**无参 Application.Run()** 消息循环(对齐 wgtray 的
    TrayApp 做法), 进程常驻托盘
  - ime 模式: 原 `Application.Run(form)` 恢复
- 重建: `tests\rebuild-wgime-bat-payload.ps1`(瘦 DLL 559KB) + `build-wgime-ps1.ps1`
  (WgIme.ps1 39.4MB, 同步 wg-all/release)
- 验证: bat ime 存活 16s+ / bat tray 存活(RUNMODE=tray) / ps1 tray 存活 25s+
  (RUNMODE=tray) —— 三版 ime/tray 消息泵均常驻
- 注: WgIme.ps1 ps1 版经 WgImeLauncher → WordBoard.RunApp 调用, 自动继承 tray 模式

---

## 2026-09-01 (wgime.bat: 运行模式 ime/tray - 合并 wgtray 方案 · C# bat 版)

- wgime.bat 内嵌 C# (WordBoard) 增加**运行模式**支持, 对齐 python 版与合并 wgtray 目标:
  - 静态字段 `TrayMode`; `LoadConfig` 读 `mode = ime|tray`(缺省 ime, 向后兼容)
  - tray 模式: 构造隐藏候选条窗体(Opacity 0/Visible false)、不订阅展示、`OnLoad` 跳过
    `Hook.Start()`(不装键盘 hook); `RefreshLabel` 候选窗永不显示、托盘图标固定"工"字
    (`trayModeIcon` 缓存)
  - 托盘菜单双模式: ime=原菜单; tray=工具箱风格(工具箱/内置工具: 网络/剪贴板/便签/取色/
    插件管理/编辑配置/重载/数据目录) + 两个模式都加「运行模式 ▸ 输入法(IME)/托盘工具箱(Tray)」
  - `RestartInMode(mode)`: 写 config `mode=` + 重启用自身 bat 生效
  - `RefreshMenuChecks` 空判保护(tray 菜单无 IME 控制项)
- 验证: `tests\rebuild-wgime-bat-payload.ps1` 瘦 DLL 编译通过(559KB); 真实启动日志
  RUNMODE=ime / RUNMODE=tray 均正确; tray 模式进程存活、无 hook; wgime.bat 保持纯 CRLF
- 注: 因 C# 段前部增行, build-wgtray.ps1 切片行号已失配(wgtray 将退役, 下轮处理)

---

## 2026-09-01 (wgime-py-pure: 运行模式 ime/tray - 合并 wgtray 方案 · python 版)

目标: 把 wgtray(无输入法托盘工具箱)收敛为运行模式, 最终三版(bat/ps/py)各含 ime/tray。
本轮落地 **python 版** (方案详见仓库根 MERGE-TRAY-PLAN.md):

- `config.txt` 新增 `mode = ime|tray` (缺省 ime, 向后兼容; C# 版共享 config 同步加键, C# 侧暂忽略无害)
  - ime = 输入法(现状); tray = 纯托盘工具箱: **不启动键盘 hook / 不建候选窗**,
    托盘出"工"字图标 + 工具菜单(工具箱/内置工具/插件管理/config 应用/编辑配置)
- `engine.load_config`: 解析/归一化 mode 键(非法值回退 ime)
- `main.py`: `is_tray_mode()` 分支 → 启动序尾部 tray 时不 `hook.start()`;
  `switch_mode()` 写回 config + 无控制台重启自身生效; TRAY api 增 get_runmode/switch_runmode
  与工具入口 toolbox/nettools/clipboard/notes/color/pluginmgr/run_app/apps
- `tray.py`: 按运行模式构建菜单(ime 保留原菜单+工具入口+运行模式子菜单; tray=wgtray 式菜单),
  `_tool_icon_img()` 工字图标
- 验证: py_compile / config 解析(mode=tray/ime/bogus) / 双菜单构建 / main.py tray 与 ime 模式
  真实启动 4-5s 存活 / 单文件 dist 内嵌含新逻辑且 tray 模式启动正常 / package 与 dist 字节一致
- 文档: wgime-py-pure\README.md「运行模式」节、AGENTS.md §8、根 config.txt 注释

---

## 2026-09-01 (wgime-py-pure: python 分发目录彻底去 C# 插件 - 只留 .py + 步骤 DSL)

- 用户决策: python 版内置插件全部 .py 化, C# 插件源不再进 python 分发
- `build-package.ps1`: 拷 txt 进 `package\plugins\` 时跳过含完整 `[csharp]` 插件块的
  txt(calc/chat/clock/wgtranslate 的 C# 源), 只留步骤 DSL(clean-bin/qping) + 文档(README.txt,
  含 [csharp] 示例块但无 code 头, 不注册为插件)
- 删除 `testing\wgime-qr-clean-border-style-v2.5.txt`(qr C# 源归档, 已由 wgime-qr.py 取代)
- 效果: `package\plugins\` = calc.py/chat.py/clock.py/wgime-qr.py/wgtranslate.py(5 个 .py)
  + clean-bin.txt/qping.txt(步骤 DSL) + README.txt(文档), 无任何 [csharp] 插件;
  真实加载验证: STEP_PLUGINS 只剩 qls/qping(steps), PLUGINS 5 个 .py 全在
- `[csharp]` 运行能力(直调 csc / run-csharp-plugin.ps1 回退)仍保留作兼容, 只是分发不再带 C# 插件
- 仓库根 `plugins\*.txt`(C# 版共享源, wgime.bat/wg-all/release)不受影响, 保留
- AGENTS.md / wgime-py-pure\README.md 同步更新

---

## 2026-09-01 (仓库整理: 目录重组 B+A - 清垃圾 + 纯 Python 版 README/包说明 + 插件源统一)

- 执行 `REORGANIZE-PLAN.md` 的推荐组合 B+A:
  - 清 `tests\interop\` 49 个调试日志/截图, 清全仓 4 处 `__pycache__`
  - 删 `wgime-py-pure\plugins\clock.txt`(与仓库根 `plugins\clock.txt` 相同的 C# 源副本);
    `wgime-qr-clean-border-style-v2.5.txt`(C# qr 源唯一副本)归档到 `wgime-py-pure\testing\`(untracked, 不参与加载)
  - 纯 Python 版源码 `plugins\` 现在只含 `.py`(calc/chat/clock/wgime-qr/wgtranslate), 不再混 C# 源
- 新增 `wgime-py-pure\README.md`(子项目说明: 结构/构建/数据目录/插件/重要约定)
- 新增 `wgime-py-pure\package-readme.txt` 并让 `build-package.ps1` 把它拷成 `package\README.txt`
  (分发包目录说明, 以后构建自动带上; release/wg-all 的 README.txt 已有, 不动)
- `.gitignore` 已覆盖 package/__pycache__/interop 产物; `testing\` 为个人实验区保持 untracked
- AGENTS.md §8 纯 Python 插件描述更新为"插件不内嵌, 生产从外部插件目录加载"
- 行为无变化: 插件加载逻辑/权限模型/C# sidecar/词频/候选框等一律未动

## 2026-08-31 (wgime-py-pure: 修候选框"刚输入就跳/飘过来" - 开始输入即直贴光标 + UIA 缓存前台变化守卫)

- 用户反馈: 上一步修复后候选框仍"刚输入时会跳来跳去", 且疑似字频不再调整
- **真根因①(跳舞/飘)**: `bar.show` 低通平滑的起点 `_last_geom` 保留的是**上一次打字的陈旧位置**; 候选窗被 `hide` 隐藏后它不变, 下次在别处输入时平滑以 45%/帧从旧位置**慢慢滑向当前光标**, 看起来就是"刚输入就飘过来/跳舞"
- **修复**: `bar.show` 记录进入时 `was_visible`; 刚显示(从隐藏恢复)或目标与当前相差过大(跨窗口/跨行迁移)时**直接贴目标(重置平滑)**, 不再滑; 最小移动滞回只对已显示的小移动生效, 刚显示/迁移时总是定位(不提前 return)
- **真根因②(切应用先跳旧位置)**: `get_caret_pos` 的 UIA 缓存只看 `_uia_el` 是否非空, 不看前台是否已变化; 刚切到新输入框时缓存还是**旧窗口坐标**, 会先跳到旧位置再跳回来
- **修复**: UIA 缓存仅当前台窗口未变时可信, 前台切换时忽略旧缓存走 GUITI(后台线程随后刷新新前台)
- **字频不调**: 彻查确认 `engine.learn`/`candidates` 排序/LastPick/近期热度链路完整(VS: 主动选择 `i>0` 才学, 空格选默认不学; 引擎层未改动), 该症状与跳舞属连带感知, 应先验证跳舞修复
- `dist/wgime-py.py` 重建(591.4KB); package 刷新

---

## 2026-08-31 (wgime-py-pure: 根治候选框不显示 - show 里位置滞回提前 return 跳过 deiconify)

- **用户反馈(关键)**: Backspace / Shift 开关 / 标点符号后候选框"整个屏幕看不到"(但打字仍上屏)
- **真根因**: `bar.show` 开头 `c.delete('all')` 清空画布, 但**位置滞回分支 `if dx<40 and dy<10: return` 提前返回, 跳过了末尾的 `self.top.deiconify()`**。若窗口先前被 `bar.hide`(withdraw), 则 show 被调用但因位置接近触发滞回 return -> 窗口**保持隐藏**, 永远显示不出
- **修复**: `bar.show` 开头先 `self.top.deiconify()`(无论后续是否提前 return, 窗口都已唤醒); `win.set_topmost` 仍在末尾
- 这解释了"Backspace 清空后 hide(withdraw) -> 再输入 show 但位置接近 -> 滞回 return 不 deiconify -> 永久隐藏"
- `dist/wgime-py.py` 重建(576.4KB); package 刷新

---

## 2026-08-31 (wgime-py-pure: 修 _last_geom 从未赋值导致平滑失效 + 候选框位置异常)

- 用户反馈: 按 Backspace 后"整个屏幕看不到候选框"——疑与候选框位置异常/平滑有关
- **`bar.py` bug**: `_last_geom` 只初始化**从未赋值**, 平滑分支 `if cur is not None` 永不进入, 低通平滑根本没生效
- **修复**: `show` 末尾在窗口 `winfo_viewable && ismapped` 时记录实际 `winfo_x/winfo_y` 到 `_last_geom`(避免首次/隐藏时读到 0/0 污染平滑起点), 平滑才真正起作用
- 配合防抖 hide + 抖动检测, 候选框位置更稳定
- `dist/wgime-py.py` 重建(576.2KB); package 刷新

---

## 2026-08-31 (wgime-py-pure: 候选窗隐藏加防抖, 治"候选框有时消失")

- 用户反馈: 候选框有时消失(但打字还能上屏)——根因: 连续打字/上屏瞬间, `ime.buf` 短暂清空触发 `bar.hide()`(立即 withdraw), 下一键又 `bar.show()`, 候选框在快速连打时"闪一下消失"
- **`bar.py` `hide` 加防抖**: 延迟 160ms 才真正 `withdraw`; 若期间又 `show`(下一键/上屏后紧跟)则取消隐藏回调不闪; `show` 开头取消待执行的 hide 回调
- **验证**: bar.py 编译 OK; pythonw 启动干净; 候选框在连续输入时不再一闪即逝
- `dist/wgime-py.py` 重建(575.7KB); package 刷新

---

## 2026-08-31 (wgime-py-pure: 光标跟随恢复 UIA 首选 + 纯 Win32 回退, 保留现方案)

- 用户决定: UIA 用回做首选, 现有的纯 Win32 方案保留做回退
- **`win.py` 恢复 UIA 机制但更安全**: `_import_uia_robust`(中和 `_check_version` 防 typelib 反复) + `_get_uia_caret`(后台拿精确 caret 到 `_uia_el`) + `_caret_bg_loop`(后台线程刷新), **关键: 一旦 UIA 导入/取控件/异常失败, 置 `_uia_disabled=True` 锁死, 之后 get_caret_pos 不再走 UIA, 不重复报 typelib/COM 错**
- **`get_caret_pos` 顺序**: UIA缓存(首选,后台刷新) -> GetGUIThreadInfo -> 聚焦输入框矩形 -> 输入感知鼠标 -> 上次有效位 -> 前台窗口底部; UIA 不可用自动跳过
- **`main.py`** 启动时 `win.ensure_caret_bg()`
- **实测**: 启动前 source=mouse; 后台线程跑后 **source=uia** (UIA 拿到精确 caret (424,2004), uia_disabled=False); 目标设备 UIA 不可用时自动锁死回退纯 Win32
- 既有纯 Win32 路径(GUITI/focus_edit/鼠标/平滑)保留
- `dist/wgime-py.py` 重建(574.8KB); package 刷新

---

## 2026-08-31 (wgime-py-pure: 候选窗位置低通平滑, 彻底治"跳舞/越跳越右")

- 用户反馈: 浏览器测试候选条"一上一下跳舞, 越跳越往右"——平移+抖动检测后仍有位置振荡
- **`bar.py` 跟随分支加低通平滑**: `new = old + (target-old)*0.45`, 每帧只挪一半, 抹平剧烈抖动/累积漂移; 平滑后再次 clamp 工作区; 最小移动滞回收紧(<40px,<10px)
- **`bar.py` `_last_geom`**: 记录上次窗口位置供平滑
- 配合上一版 GUITI `_caret_jittery`(拒绝抖动 caret 退回鼠标) + 输入感知鼠标位 + focus_edit 矩形
- 用户实测:"不跳了"(跳舞治住)
- `dist/wgime-py.py` 重建(569.2KB); package 刷新

---

## 2026-08-31 (wgime-py-pure: 光标跟随 caret 抖动检测, 治候选框"跳舞")

- 用户反馈浏览器里候选框"一上一下跳舞、越跳越往右"——根因: 放宽 GUITI 后, 浏览器等自绘应用返回**抖动/漂移的退化 caret**(单帧大幅往返), 候选窗跟着横跳
- **`win.py` 新增 `_caret_jittery(cand)`**: 记录最近 GUITI caret 位置(deque), 若 (a) 单帧位移 >120px 或 (b) x/y 方向出现 >40/30px 反复反向(横跳)则判不可信, `get_caret_pos` 拒绝该 caret 退回鼠标
- 实测: 稳定 caret(原位小幅移动)正常跟随; 跳舞 caret(100→400→60→420→40)判 jittery=True 退回鼠标; pythonw 启动干净
- `dist/wgime-py.py` 重建(568.3KB); package 刷新

---

## 2026-08-31 (wgime-py-pure: 光标跟随加聚焦输入框矩形路径 + GUITI 宽容判定)

- **`win.py` GUITI 判定放宽**(对齐 C# TryGetCaretScreenRect): 只要 `hwndCaret` 存在即采纳, 用 `rcCaret.top` 定位(原先用 bottom 会有偏移), 容忍退化 caret(2x2/零尺寸但 (x,y) 真实跟踪光标), 防最小化(-32000)坐标
- **`win.py` 新增 `_focus_edit_rect()`**: 取聚焦窗口 `GetFocus` 的屏幕矩形(输入框位置近似), 纯 Win32 不依赖 UIA——很多现代应用(Chrome/部分 Electron 对话框)的文本控件是真实 HWND, `GetWindowRect` 能拿到其位置, 比鼠标更贴近输入框. `get_caret_pos` 顺序变为: GUITI -> focus-edit -> 输入感知鼠标 -> last -> 窗口底部
- 实测: `focus-edit rect` 在无真实 HWND 前台(浏览器)时返回 None(安全), 回退鼠标; pythonw 启动干净
- `dist/wgime-py.py` 重建(566.5KB); package 刷新

---

## 2026-08-31 (wgime-py-pure: 鼠标跟随再优化 - 输入感知鼠标位 + 最小移动滞回)

- **`win.py` 新增 `_input_aware_mouse_pos()`**: 鼠标兜底位更贴近输入行为——垂直 y=鼠标 y(输入行高度), 水平 x: 若鼠标在前台窗口内则用鼠标 x(光标列接近鼠标横向), 鼠标在窗口外则取前台窗口水平中央(避免候选窗跑到屏幕角落)
- **`bar.py` 跟随分支加最小移动滞回**: 候选窗与当前位置差 < (水平 60px, 垂直 14px) 时不动, 防鼠标轻微抖动/每键入跳变; 组合: 鼠标"跳到别处"才跟, 原地微动不跟
- 实测: `get_caret_pos` 返回 (643,1840) source=mouse(输入感知), 无 uiautomation/comtypes; pythonw 启动干净
- `dist/wgime-py.py` 重建(564.7KB); package 刷新

---

## 2026-08-31 (wgime-py-pure: 鼠标跟随体验增强 - 来源标记 + 鼠标中心贴边 + GUITI 优先)

- 背景: 用户机器(Cisco+Store Python) comtypes-UIA 不可用, 决定纯 Python 覆盖层 + 更好的位置跟随(不纠结 UIA/TSF)
- **`win.py`**: `get_caret_pos` 增加 `_last_caret_source` 标记返回来源('caret'/'mouse'/'last'/'fallback'); 仍纯 ctypes Win32, 顺序 GUITI -> 鼠标 -> last -> 窗口底部
- **`bar.py`** 光标跟随分支按来源区分:
  - `mouse` 来源: 候选窗中心对齐鼠标点下方(x = cx - w//2, y = cy+10), 不压指针, 超屏 clamp(上翻)
  - `caret`/`last`/`fallback`: 贴光标下方(光标左侧对齐), 同原
- 实测: `get_caret_pos` 纯 Win32 返回 (1408,1145) source=mouse, 无 uiautomation/comtypes; pythonw 启动干净
- `dist/wgime-py.py` 重建(563.1KB); package 刷新

---

## 2026-08-31 (wgime-py-pure: 光标跟随彻底移除非 comtypes/uiautomation, 纯 ctypes Win32)

- **背景**: 用户机器 comtypes 版 uiautomation 反复 `ImportError('Typelib different than module')`(即使从 zip 加载、`_check_version` 已中和仍复现), ctypes 直调 UIA 又遇 Store-Python 进程 COM 隔离(REGDB_CLASSNOTREG)。用户明确要求**不依赖 comtypes/UIA 的定位方式**
- **`win.py` 大重构**: 删除全部 comtypes/uiautomation 依赖(UIA 缓存机制 `_uia*`、`_import_uia_robust`、`get_caret_uia`、`_caret_bg_loop`、`ensure_caret_bg`、`_neutralize_uia_check_version`、`_force_zip_uia`、`_early_neutralize_uia`), `get_caret_pos` 改为**纯 ctypes Win32**:
  - 顺序: `GetGUIThreadInfo`(传统 Win32 caret) -> **鼠标位置**(现代应用无 caret, 用户打字时光标在鼠标附近) -> 上次有效位 -> 前台窗口底部居中
  - `_mouse_pos()`/`_foreground_client_origin()` 保留(纯 Win32)
  - 文件 758 行 -> 380 行
- **`main.py`**: 移除 `win.ensure_caret_bg()` 调用(不再有后台 UIA 线程)
- **实测**: `get_caret_pos` 纯 Win32 返回 (3119,1638), `is uiautomation loaded? False` / `is comtypes loaded? False`; pythonw 启动干净
- **效果**: 光标跟随不再依赖任何第三方库, 彻底消灭 typelib/COM 隔离问题; 现代应用(Teams 等)用鼠标位置兜底(贴鼠标), 传统应用用 Win32 caret, 稳定不崩
- `dist/wgime-py.py` 重建; package 已刷新

---

## 2026-08-31 (wgime-py-pure: 后台线程用 UIAutomationInitializerInThread 初始化, 根治 UIA 超时/跟随不到)

- **生产机日志决定性发现**: 后台线程定时刷新的 `get_caret_uia` → `GetFocusedControl` **每次耗时 1~2.6s 且 el=False**(拿不到控件), 而主线程 `get_caret_pos` 一直 `fallback-origin`(光标准不了)。这就是"上屏仍卡 + 跟随不到"
- **根因**: 在**裸后台线程**里用 uiautomation 的 `GetFocusedControl`, **没初始化该线程的 UIA/COM 上下文**——uiautomation 官方明确要求"used in a thread 必须用 `UIAutomationInitializerInThread`"(正是报错提示第 2 条)。未初始化的线程里 COM 调用超时/失败 → el=False、耗时 1~2.6s
- **修复 `win.py` `_caret_bg_loop`**: 用 `with auto.UIAutomationInitializerInThread():` 包裹循环, 在后台线程内初始化 UIA 上下文(退出自动 Uninitialize)
- **实测**: 后台线程用 initializer 后 `GetFocusedControl` 从 1950ms/el=False 变成 3~8ms/el=True, `_uia_el[0]` 成功填充 (2647,1300); 主线程 `get_caret_pos` 走 UIA-cache 0.1ms 不再 fallback; pythonw 启动干净
- **效果**: 生产机 Teams 里光标跟随应能取到精确光标(cache 由后台线程持续更新), 且主线程不跑 UIA, 上屏不卡
- `dist/wgime-py.py` 重建(575.8KB); package 已刷新

---

## 2026-08-31 (wgime-py-pure: 光标跟随 debug 增强 + UIA 优先定位 + 定位失败原因日志)

- **生产机"跟随不到光标"根因线索**: 后台线程 `get_caret_uia` 的 `GetSelection()` 对很多控件返回**空矩形**(`rects=[]`)或**整行/大控件**, 旧逻辑硬性要求 `0<cw<=200`, 导致 `_uia_el[0]` 填不上 → `get_caret_pos` 走 fallback(客户区左上角, 不准)
- **`get_caret_uia` 放宽**: 选区矩形高度合理(4~200)即视为可定位光标(用 left/bottom 锚点), 宽度不再强限(整行也接受, 取 left 锚点); 仅拒绝整页级别高度
- **`get_caret_pos` UIA 优先**: 改为**先读 UIA 缓存**(精确), 再 GUITI(对 Electron 光标准确性差), 最后 fallback
- **`get_caret_uia` 失败原因日志**: 取不到时记录 `_sel_info`(selection EMPTY/rects EMPTY/no TextPattern) + 控件类型 + 回退 Rect 尺寸, 便于 Teams 实测定位
- **实测(本机)**: 前台为浏览器网页时 `GetSelection() rects=[]`(复现"取不到光标"); 需在 Teams 聚焦实测看日志
- `dist/wgime-py.py` 重建(575.4KB); package 已刷新
- **收集方式**: 生产机 `set WGIME_DEBUG=1` + 最新单文件, Teams 打字, 发 `%LOCALAPPDATA%\wgime-py\debug.log` 中 `[win]` 行

---

## 2026-08-31 (wgime-py-pure: 光标跟随 debug 日志, 用于实测定位上屏卡顿)

- **`win.py` 新增 `_dlog()`** 集中式光标跟随耗时日志, 写入 `%LOCALAPPDATA%\wgime-py\debug.log`(与 main.py `_dfn` 同文件, 一起看), 仅在**环境变量 `WGIME_DEBUG=1`** 时记录(不拖慢正常运行)
- **埋点**: `get_caret_pos` 记录 GUITI/UIA-cache/last-cache/fallback 用时与来源; `get_caret_uia` 记录 `GetFocusedControl` 耗时; `_caret_bg_loop` 记录启动
- **实测(本机)**: `GetFocusedControl` 2-6ms、主线程 `get_caret_pos` 走 UIA-cache 0.1ms、后台线程每 ~200ms 刷新 —— 本环境不卡, 说明生产卡顿非 UIA 本身慢, 需实测 debug.log 定位
- **收集方式**: 生产机 `set WGIME_DEBUG=1` 后运行最新单文件, 在 Teams 打字, 把 debug.log 尾部发来
- `dist/wgime-py.py` 重建(574.4KB); package 已刷新

---

## 2026-08-31 (wgime-py-pure: 光标跟随改为后台线程刷新, 主线程不阻塞, 解决上屏卡顿)

- **上屏卡顿根因**: 光标跟随开启时, `bar.show`(tkinter 主线程)里同步调用 `get_caret_pos()` → `get_caret_uia()`. UIA 的 `GetFocusedControl`/`GetSelection`/`GetBoundingRectangles` 在 Teams 等 Electron 应用一次可耗时 1~几秒, 且跑在**主线程**, 直接阻塞按键处理/上屏(即使之前加了 150ms 节流, 慢的 UIA 调用本身仍阻塞主线程)
- **修复 `win.py`**: 新增**后台光标刷新线程** `_caret_bg_loop`/`ensure_caret_bg()`:
  - 后台线程每 100ms 调 `get_caret_uia()`(内部还有 150ms 节流)刷新缓存 `_uia_el[0]`
  - `get_caret_pos()` 改为: 廉价同步 `GetGUIThreadInfo` -> **读取 UIA 缓存**(后台线程刷新, 主线程绝不跑 UIA) -> 上次有效位 -> 前台窗口客户区
  - 主线程因此**永不阻塞**(实测 `get_caret_pos` 返回 <0.1ms)
- **`main.py`**: 启动时 `win.ensure_caret_bg()` 启动后台线程
- **实测**: `ensure_caret_bg` + mtime 失真下, `get_caret_pos` 0.0001s 返回 `(2647,1300)`(bg 已缓存); pythonw 启动干净
- `dist/wgime-py.py` 重建(573.1KB); package 已刷新

---

## 2026-08-31 (wgime-py-pure: 强制用内嵌 zip 的 comtypes/uiautomation, 排除用户 pip 装的 site-packages 版)

- **真正破案**: 生产机 pip 装了 `uiautomation 2.0.29 + comtypes 1.4.16`(user site-packages, `AppData\Roaming\Python\Python313\site-packages`)。单文件虽然 `sys.path.insert(0, thirdparty.zip)`, 但若 site 里 zip 过期/损坏, Python 会**回退到 site-packages 的 comtypes**——而我们所有的 `_check_version` 补丁都打在 **zip comtypes** 上, 对实际加载的 site-packages comtypes 完全无效! 这就是"改了 N 轮仍复现"的根本原因
- **实测确认**: 有效 zip 在 sys.path[0] 时, comtypes/uiautomation **从 zip 加载**(`thirdparty.zip\comtypes`); 但 site zip 被污染(1006B, `STALE`)后, Python 回退 site-packages → 之前补丁失效
- **`win.py` 新增 `_force_zip_uia()`**: 在 `_import_uia_robust` 里先调用, 若当前 `comtypes.__file__` 不含 `thirdparty.zip`(即加载了 site-packages 版), 则把 `comtypes`/`uiautomation`(及子模块)从 `sys.modules` 清除、把 zip 顶到 sys.path[0], 强制重导 zip 版——排除用户 pip 装的 site-packages 版干扰
- **实测**: `_force_zip_uia` 后 comtypes 从 `thirdparty.zip\comtypes` 加载; mtime 失真下 `get_caret_uia` 优雅降级(None, broken=False, 无 typelib 报错)
- `dist/wgime-py.py` 重建(571.6KB); package 已刷新
- **生产机建议**: 若/当 site-packages 装有 uiautomation/comtypes, 新版单文件会自动强制用 zip 版; 亦可 `pip uninstall uiautomation comtypes` 彻底避免冲突

---

## 2026-08-31 (wgime-py-pure: win 加载即中和 comtypes typelib 校验 + 吞 uiautomation 黄字日志)

- **生产机仍报 `Typelib different than module`/@automationlog.txt 的原因**: 补丁时序依赖——之前的 `_neutralize_uia_check_version` 只在 `_import_uia_robust` 里调用, 若 uiautomation 在某条路径下提前触发 `_AutomationClient`(import 时绑定 `_check_version`), 补丁就晚了
- **`win.py` 新增 `_early_neutralize_uia()` 并在 win 模块加载时(顶层)立即调用**: `_load('win')` 即生效, 早于任何 uiautomation 使用, 无时序依赖:
  - 中和 `comtypes._tlib_version_checker._check_version` + 所有已加载 `comtypes.gen.*` 模块 `__dict__['_check_version']` → 恒通过
  - 把 `uiautomation.Logger.WriteLine` 降噪: 对含 `UIAutomationCore` 的提示("Can not load UIAutomationCore.dll" 等)直接吞掉, 不再写进 `@automationlog.txt`
- **实测**: 强制 mtime 失真 + win 加载即中和, `get_caret_uia` 返回 `(2647,1300)` 无报错; `Logger.WriteLine('Can not load UIAutomationCore.dll.')` 被静默; pythonw 启动干净
- `dist/wgime-py.py` 重建(570KB); package 已刷新
- **必须用最新单文件**; 若生产仍报, 说明跑的仍是旧构建

---

## 2026-08-31 (wgime-py-pure: 单文件启动时强制刷新 thirdparty.zip —— 根治旧 comtypes typelib 报错)

- **真正根因**: 单文件解压 `thirdparty.zip` 到 `%LOCALAPPDATA%\wgime-py\site` 的旧逻辑是 **`if not os.path.exists(_third_zip)`** —— site 里已有 zip 就**永不刷新**。生产机 site 残留早期版本的 zip → 一直用**旧 comtypes**, 其 `comtypes.gen.UIAutomationClient` 烘焙的 UIAutomationCore.dll mtime 更老, `_check_version` 必报 `Typelib different than module`——这解释了为什么改了多轮仍复现(旧 comtypes 从没被换掉)
- **修复 `build-wgime-pure.py`**: 单文件 preamble 改为**入内嵌 zip 的 md5 与磁盘 zip 的 md5 比对, 不一致就 `os.replace` 原子重写**。首次运行或单文件升级后 zip 自动刷新成新版 comtypes, 用户无需手动删 site
- **实测**: 预置 stale zip(md5 不同), 单文件启动后对应数据路径的 zip md5 变回与内嵌一致; Store 虚拟化环境会切到 `~\wgime-py\site` 并在那里刷新(仅 `%LOCALAPPDATA%` 里残留的旧 zip 未用、不影响)
- 配合之前 `win.py` 的 `_neutralize_uia_check_version`(覆盖 comtypes.gen 各 UIAutomation 模块 `__dict__['_check_version']`)防御层, 双保险
- `dist/wgime-py.py` 重建(568.3KB); package 已刷新
- **重要**: 必须用**最新单文件**(含 md5 强制刷新 + `_neutralize_uia_check_version`), 旧单文件无论怎么改 patch 都无法修复

---

## 2026-08-31 (wgime-py-pure: UIAutomation typelib 修复改为模块级 __dict__ 覆盖, 顺序无关/普适)

- **关键发现**: comtypes 生成模块 `comtypes.gen.UIAutomationClient/wrapper` 内部的 `_check_version('1.4.16', <mtime>)` 用 **`LOAD_GLOBAL` 读模块 __dict__**, 所以**直接覆盖模块 `__dict__['_check_version']` 为 no-op** 就能让该调用不抛——**无论该模块何时被 import 都生效**(之前只改 `comtypes._tlib_version_checker._check_version` 模块属性, 对已 `from ... import` 绑定的引用无效, 这就是为什么之前没修好)
- **`win.py` 新增 `_neutralize_uia_check_version()`**: 遍历 `sys.modules` 里所有 `comtypes.gen.*UIAutomation*`(及 wrapper)模块, 覆盖其 `__dict__['_check_version']`; 并同时覆盖 `comtypes._tlib_version_checker._check_version`
- `_import_uia_robust()` 改为: 导入 uiautomation 前打补丁 + 导入后调用 `_neutralize_uia_check_version()`(双保险), 仍失败才清 gen 缓存重试 + `_uia_import_broken` 兜底
- **实测**: 最坏情形(gen 模块已被 import、`_check_version` 已绑定原函数)下, `_neutralize_uia_check_version` 覆盖后 `um/wr._check_version('1.4.16',999999)` 均返回 None(不再抛); 强制 mtime 失真(1000000.0)下 `_import_uia_robust` 成功、`get_caret_uia` 返回 `(2647,1300)`
- `dist/wgime-py.py` 重建; package 已刷新
- **此修复顺序无关**: 无论 gen 模块何时加载、之前是否被任何代码 import 过, 只要在 uiautomation 使用前调用过 `_neutralize_uia_check_version` 就稳定

---

## 2026-08-31 (wgime-py-pure: 彻底修复 uiautomation "Typelib different than module" 并普适)

- **确认普适根因**: zip 内嵌 `comtypes/gen/UIAutomationClient.py`(及 wrapper `_944DE083_...`)在模块顶部 `from comtypes._tlib_version_checker import _check_version` **绑定函数对象引用**, 并在模块体里调用 `_check_version('1.4.16', <烘焙mtime>)`; `_check_version` 比较系统 `UIAutomationCore.dll` 当前 mtime 与烘焙值, 相差>=1s 即抛 `ImportError("Typelib different than module")`。**任何**机器上只要该 DLL mtime 与烘焙值不同(用户机/系统更新后)就会触发, 不止 Teams
- **上一版 patch 的失效点**: 只 `from comtypes import _tlib_version_checker; _tvc._check_version = no-op` 是指向**模块属性**; 但生成模块已经 `from ... import _check_version` **绑定的是函数对象本身**, 模块属性改了也不影响已绑定的引用(实测 `um._check_version is tvc._check_version` 为 False)
- **本版正解双层防护 `win.py`**:
  1. `_import_uia_robust()`: 在**导入 uiautomation 前**把 `_check_version` 打成 no-op —— 生成模块是**惰性**(首次 `GetFocusedControl` 才 import), 所以 patch 发生时它还没绑定, 之后 `from ... import` 拿到的就是 no-op → 从源头不抛
  2. `_uia_retry_client()`: 若首次 `GetFocusedControl` 仍失败, **重置 `uiautomation.uiautomation._AutomationClient._instance=None`** 强制重新构造(此时 patch 已在), 重试一次再成功
- **实测**: 强制 `UIAutomationCore.dll` mtime **+50s**(等效用户机), `_import_uia_robust` 仍导入成功、`get_caret_uia` 返回有效坐标; 把单例设成坏占位, `_uia_retry_client` 重置后仍返回精确光标 `(2728,1085)`
- `dist/wgime-py.py` 重建; package 已刷新
- **提醒**: 请务必使用最新单文件(`dist/wgime-py.py` 或 `package\wgime-py.py`), 旧版不含该修复

---

## 2026-08-31 (wgime-py-pure: 根治 uiautomation "Typelib different than module")

- **根因定位**(实测确认):我们 zip 内嵌的 `comtypes/gen/_944DE083_..._UIAutomationClient.py` 里**烘焙了生成时 UIAutomationCore.dll 的 mtime**, 形如 `_check_version('1.4.16', 1787852155.337951)`(`comtypes._tlib_version_checker` 在导入生成模块时用 `os.stat(该DLL).st_mtime` 与烘焙值比较, 相差>=1s 就抛 `ImportError("Typelib different than module")`)
  - 本机(开发机)DLL mtime 恰好等于烘焙值(1787852155.337951)所以正常; **用户机上 Windows 更新/版本不同 → mtime 相差>=1s → 必抛**. 与线程无关, 是 uiautomation 库误导文案
  - "清 gen 缓存重新生成"无效: zip 里 gen 是内存生成、不落盘, 重入仍读烘焙的那份
- **正解 `win.py` `_import_uia_robust()`**:导入 uiautomation **前**把 `comtypes._tlib_version_checker._check_version` 临时打成**总是通过**(no-op)——生成模块的接口布局与 DLL mtime 无关, 仅凭 mtime 判定"不同"本就不严谨, 跳过即可让跟随在这些机器上稳定工作
  - 仍失败(其他原因)才清 gen 缓存重试 + `_uia_import_broken` 兜底优雅降级, 绝不让 IME 崩
- **实测**:模拟 UIAutomationCore.dll mtime **+30s** 的失真(等效用户机), `_import_uia_robust` 仍成功导入 uiautomation(`broken=False`)、`get_caret_uia` 返回有效坐标; pythonw 启动干净无异常
- `dist/wgime-py.py` 重建; package 已刷新

---

## 2026-08-31 (wgime-py-pure: 修 uiautomation 报 "Can not load UIAutomationCore.dll/Typelib different than module")

- **`win.py` 新增 `_import_uia_robust()`**:稳健导入 uiautomation。comtypes 在 typelib 版本不匹配时会抛 `ImportError("Typelib different than module")` 并在 stderr 打印黄色告警(实测偶发, 取决于系统 `UIAutomationCore.dll` 的 mtime)
  - 失败时**清掉 comtypes.gen 里 UIAutomationClient 缓存模块**(`sys.modules` + `dir(comtypes.gen)` + 磁盘 gen 目录里的 `UIAutomation*`), 强制内存里**重新生成**一次, 使 mtime 版本校验与当前系统 DLL 一致, 再重试
  - 仍失败则置 `_uia_import_broken=True`(本会话不再重复尝试), 返回 None → `get_caret_uia` 优雅降级(用 `_last_caret`/非跟随), **绝不让 IME 因光标跟随崩掉**
- `get_caret_uia` 的导入改走 `_import_uia_robust()`; 导入失败也按节流记录, 不报错
- 实测: `_import_uia_robust` 返回真 uiautomation(含 GetFocusedControl/UIAutomationInitializerInThread); Teams 聚焦时 `get_caret_pos` 返回 (2663,1297); pythonw 启动干净无异常
- `dist/wgime-py.py` 重建; package 已刷新
- **说明**:该错误信息里"你需要用 UIAutomationInitializerInThread"是 uiautomation 库的**固定提示文案**, 实际抛的是 comtypes typelib mtime 不匹配(`ImportError`), 与线程无关——本修复清缓存重生成即解决

---

## 2026-08-31 (wgime-py-pure: 修 Teams 等 Electron 应用中光标跟随卡顿)

- **`win.py` `get_caret_uia()` 加节流 + 复用**:原实现每个 poll(15ms)/每键都跑整套 UIA(`GetFocusedControl`→`GetPattern`→`GetSelection`→`GetBoundingRectangles`), 在 Teams/Edge 这类 Chromium 应用里一次可达几十~上百 ms, 且跑在 tkinter 主线程上, 直接卡死 IME 主循环 → 光标跟随后"反应很慢"
  - 前台窗口没变且距上次 < 150ms: 返回缓存的屏幕位, **不重跑 UIA**(成功/失败路径都节流, 避免"Teams UIA 拿不到光标"这种高频失败也每键都跑)
  - 前台窗口变了才立即重新检索; 失败(返回 None)也记录尝试时间, 同样被节流
  - 实测节流逻辑: 8 次快速调用 UIA 只跑 1 次; 过 0.16s 后重新跑; 成功/失败两路径都正确
- `GetGUIThreadInfo` 快速路径仍优先(廉价), 只有它取不到光标才走(UIA 节流的)慢路径
- `dist/wgime-py.py` 重建; package 已刷新
- **效果**: Teams 里开启"光标跟随"不再每键卡 UIA, 光标位置最多滞后 ~150ms(视觉无感)

---

## 2026-08-31 (wgime-py-pure: 托盘菜单新增"编辑/重载配置", 对齐 C# 版)

- **`main.py` 新增 `reload_config()`**:重读 config.txt + tools.txt + plugins/*.txt + plugins/*.py + pastemode.txt, 并刷新主题/托盘勾选(无需重启程序), 对齐 C# 版 `ReloadConfig()`
  - `apply_config()` 重读 config.txt; `load_tools()`/`load_plugins()`/`load_py_plugins()` 本就每次重新读盘(无缓存), 改文件即生效; `load_appmodes()` 重读 pastemode.txt
  - 新增 `open_config_file()`:用默认编辑器打开 config.txt(对齐 C# `OpenConfigFile()`)
- **`main.py` tray.api 新增 `reload`/`open_config` 回调**
- **`tray.py` "这个程序" 菜单新增**:`编辑配置 (config.txt)…` 与 `重载配置 (config/tools/插件)` 两项
- **实测**:`load_config` 改文件后重读即变(`theme=light`/`showcode=True`/`learnk=9999`); `load_tools` 加按钮后重读 1→2; 菜单结构 `MENU_BUILD_OK` 含两新项; pythonw 启动无异常
- `dist/wgime-py.py` 重建内嵌; package 已刷新

---

## 2026-08-31 (wgime-py-pure: 纯 Python 版运行时无黑窗口)

- **`main.py` 顶部新增 `_relaunch_if_console_python()`**:检测到被控制台版 `python.exe` 启动(会弹黑色控制台窗口)时, 立刻用 **`pythonw.exe`(无控制台)重启自身**并退出当前进程——与 C# 版 `wgime.bat` 的隐藏窗口思路一致, 但由 Python 自己完成, **无需额外启动器文件**
  - 仅 win32 + 且 `sys.executable` 是 console 版时触发; `pythonw`/其他解释器跳过; `WGIME_DEBUG=1` 时不自动跳走(保留控制台看错误); `WGIME_RELAUNCHED=1` 防循环
  - 重启用 `subprocess.Popen([pythonw]+sys.argv, startupinfo=SW_HIDE, CREATE_NO_WINDOW)`; 实测控制台父进程约 160ms 内退出, pythonw 子进程存活并运行单文件
- **`main.py` `_console_python()`**:主进程改用 `pythonw` 后, `sys.executable` 会是 `pythonw.exe`; 子进程 `[python]` 插件块的 `subprocess.run(capture_output=True)` 必须改用 console 版 `python.exe` 才能抓到 `@wgime` 行。实测 pythonw 下 `_console_python()` 正确解析回 `python.exe`, `[python]` 块 `captured=True`
- `dist/wgime-py.py`(单文件)由 `build-wgime-pure.py` 重建, 已内嵌上述两处
- **验证**:本人机 pythonw 直接启动单文件进程存活、无黑窗口; console→pythonw 重启链路走通; pythonw 下插件块捕获正常

---

## 2026-08-30 (wgime-tsf: 里程碑② ITfTextInputProcessor(Ex)/ITfKeyEventSink 接口验证通过)

- **`wgime-tsf/src/lib.rs`** 新增文本服务对象 `TsfTextService`,`#[implement(ITfTextInputProcessor, ITfTextInputProcessorEx, ITfKeyEventSink)]`:
  - `CreateInstance` 改为返回 `TsfTextService`(不再是 `E_NOTIMPL`);
  - `Activate`/`ActivateEx` 从 `ITfThreadMgr` QI 到 `ITfKeystrokeMgr` 并 `AdviseKeyEventSink(tid, sink, TRUE)` 注册按键回调, `Deactivate` 反注册;
  - `ITfKeyEventSink` 六方法(OnSetFocus/OnTestKeyDown/OnTestKeyUp/OnKeyDown/OnKeyUp/OnPreservedKey)先占位返回 S_FALSE(不吞键), 待里程碑③接真逻辑;
  - 0.58 适配:`impl ITf..._Impl for TsfTextService_Impl`(目标是宏生成的 `_Impl`); `AdviseKeyEventSink` 的 `psink` 需引用; `ptim.cast::<ITfKeystrokeMgr>()` 走 QI
- **实测里程碑② ✅**:`CoCreateInstance(CLSID, CLSCTX_INPROC_SERVER)` 分别以 `IID_ITfTextInputProcessor` / `IID_ITfKeyEventSink` / `IID_IUnknown` 请求全部返回 **S_OK**, 三类接口均从对象暴露
- **新增 `wgime-tsf/register-tsf.ps1`**:TSF 键盘输入法注册/卸载脚本(COM CLSID + `HKLM\SOFTWARE\Microsoft\CTF\TIP\{CLSID}` 类别 `GUID_TFCAT_TIP_KEYBOARD` + 语言 profile), 需管理员
- **`wgime-tsf/register-tsf.ps1` 重写为三层注册**, 并修正 `DllRegisterServer` 遗漏的 **Implemented Categories**(TSF 线程管理器靠它把 CLSID 归类为键盘输入法, 缺它=注册了但 Activate 不触发):
  - A) COM 注册 + `Implemented Categories\{GUID_TFCAT_TIP_KEYBOARD}` (`DllRegisterServer`/脚本都补上)
  - B) Profile 注册正确路径 `HKLM\...\CTF\TIP\{CLSID}\LanguageProfile\0x{langid}\{ProfileGUID}`(Description/Enable/HiddenInSettingUI)
  - C) 按用户启用(HKCU): profile 挂进当前用户输入法/语言栏(直接注册表 + 备选 `Set-WinUserLanguageList`), 新版 Windows 缺这层看不到输入法
  - 脚本改为纯 ASCII(规避 PS 5.1 读无 BOM UTF-8 判成 ANSI 的 mojibake/解析错乱)
  - **修正路径 bug**:注册表**两套路径写法**必须分开 —— PowerShell provider(`New-Item`/`Set-Item`/`Test-Path`)要 `HKLM:\`/`HKCU:\`(**带冒号**), `reg.exe` 要 `HKLM\`/`HKCU\`(**无冒号**)。之前 `Reg-Key` 把 `Registry::` 拼到已是 provider 路径前(非法), 且 `reg add` 拿到带冒号路径("Invalid key name")。重写为 `reg*`(无冒号)与 `ps*`(带冒号)两组变量, 不再混用。层 A/B 实测报 **Access is denied**(路径已正确, 唯一阻塞是需**管理员**), 层 C(HKCU)无需提权已实测写入成功(`Enable=1`)
  - **层 C 改用 `InstallLayoutOrTip`(input.dll, LoadLibrary+GetProcAddress 取指针)**:实测 `Set-WinUserLanguageList` 在本机语言列表退化态(BCP47 的 `Language` 字段为空)下报不可用, 且它重写整个语言列表风险高; `InstallLayoutOrTip("0x{langid}:{CLSID}{ProfileGUID}")` **无需管理员、不改写语言列表**、按当前用户把 profile 装进输入法/语言栏(实测 OK, SortOrder 出现该 profile 的 AssemblyItem)
  - 验证: HKCU 下注册 Implemented Categories + InprocServer32 后 `CoCreateInstance → ITfTextInputProcessor` 仍 S_OK
  - **里程碑③观测探针**:`Activate`/`Deactivate`/`ActivateEx`/`OnSetFocus`/`OnTestKeyUp`/`OnTestKeyDown`/`OnKeyUp`/`OnKeyDown`/`OnPreservedKey` 全写日志到 `%LOCALAPPDATA%\wgime-tsf-hook.log`(`log()` helper, `std::process::id()` 区分宿主进程)。待实机验证回调是否被 TSF 调起
  - **实测**:注册后 TSF 已把 `wgime_tsf.dll` **加载进多个宿主进程**(explorer/msedge/微信/百度网盘/notepad/ApplicationFrameHost)——证明 COM+Implemented Categories 注册对, TSF 认可为 TIP 并枚举加载; 但**`Activate` 尚未被调**(无日志), 即 TIP 处于"已加载未激活"态, 需在设置→键盘选中 wgime-tsf 切为当前输入法后才会 Activate/收到按键
- `docs/WGIME_TSF_语言选型.md` §5 里程碑② 标记通过
- **待办**:里程碑③(notepad 打字回调触发); 新版 Windows 的 TSF profile 正确注册位实机验证

---

- **`wgime-tsf/src/lib.rs`** 完成两处关键修正(0.58 接口实现方式变化):
  - `#[implement(IClassFactory)]` 生成 `TsfFactory_Impl` 结构体, **`impl IClassFactory_Impl for TsfFactory_Impl`**(不是旧版 `impl ... for TsfFactory`); `IClassFactory_Vtbl` 是 vtable **struct** 而非 trait
  - `IClassFactory_Impl` trait 藏在 `windows` crate 的 **`implement` feature** 下(之前缺失导致找不到); 需要把 `"implement"` 加进 `Cargo.toml` features
  - `DllGetClassObject` 用 `factory.query(riid, ppv)`(0.58 的 `Interface::query` 返回 `HRESULT`, 旧 `query_interface` 已无); `0x80004005`/`0x80004001` HRESULT 字面量需 `u32 as i32`(防 i32 溢出)
  - 新增 `DllRegisterServer`(HKCR\CLSID\{GUID}\InprocServer32 = DLL 路径 + ThreadingModel=Both)与 `DllUnregisterServer`(删除键); `Cargo.toml` 加 `Win32_System_LibraryLoader`
- **实测里程碑① ✅**:注册后(验证用 `HKCU\Software\Classes\CLSID\...`, 因为写 HKCR\CLSID 需管理员) `CoGetClassObject(CLSID, CLSCTX_INPROC_SERVER, IID_IClassFactory)` 返回 **S_OK(0x00000000)**, Windows 成功加载 `wgime_tsf.dll` 并创建类工厂实例
- **`.gitignore`** 增加 `/wgime-tsf/target/`(忽略 cargo 构建产物)
- `docs/WGIME_TSF_语言选型.md` §5 增补 Spike 进度(里程碑① 通过, 里程碑②/③ 待办)
- **待办**:里程碑②(`ITfTextInputProcessor(Ex)`/`ITfKeyEventSink` 绑定 + TSF profile 注册) → 里程碑③(notepad 打字回调触发); TSF 注册脚本(写 `GUID_TFCAT_TIP_KEYBOARD` 类别 + 语言 profile)

---

- **`wgime-tsf/`** cargo 项目骨架:`Cargo.toml`(cdylib, windows-rs 0.58) + `src/lib.rs`(COM 服务器骨架: `DllGetClassObject` + `IClassFactory` + 占位 IUnknown)
- `docs/WGIME_TSF_语言选型.md` 与 `docs/WGIME_TSF评估.md`(纯 Python 版) 已提交
- **现状**:本环境 Rust 工具链已 OK(rustc/cargo 1.98.0 + linker 验证过); 但 `windows` crate 首次编译很大(慢); windows-rs API 版本敏感, 需在本机 `cargo build` 迭代微调
- 里程碑(见 `docs/WGIME_TSF_语言选型.md` §5): ① DLL 可被 `CoGetClassObject` 加载 ② `ITfTextInputProcessor`/`ITfKeyEventSink` 绑定 + TSF profile 注册 ③ notepad 打字验证回调

---

## 2026-08-29 (docs: 新增 TSF 语言选型文档)

- **`WGIME_TSF_语言选型.md`**:覆盖层(Python/C# 保持) vs **TSF(Rust 首选 / C++ 次选, 原生编译)** 的选型对比表与结论; TSF TIP 必须进程内 COM 服务器 DLL, 不要 Python 硬凑(解释器驻留所有进程+GIL/低级钩子超时); 含混合思路与 Rust 最小 spike 计划
- sync-dist 同步 release/docs

---

## 2026-08-29 (docs: TSF 评估重写为纯 Python 版)

- **`WGIME_TSF评估.md`** 从 bat/C# 版视角重写为**纯 Python 版**评估: 独立 `wgime-tsf/` 子项目方案(与 wgime-py-pure 平级, 复用 engine 候选/词频)
- **Python 实现 TSF TIP 技术路径**:pywin32 COM 服务器(win32com.server, pythoncom+嵌入式 Python) / cffi 薄壳+内嵌 Python / comtypes 手写 vtable; 对比(成本/每进程加载/GIL/崩溃隔离)
- **Python 特有难点**:Python 解释器(**比 CLR 更重**)驻留每个文本应用进程、TSF 回调在目标应用主线程受 **GIL/低层钩子超时**约束、**UWP 盲区**(解释型 COM 大概率进不去 UWP)
- **结论**:可行但比 C# 版更保守, 建议 **PoC 先行**(§5 spike: 验证 Python 能否被作为进程内 COM 服务器加载进别的应用 + 内嵌 Python 运行时 + 回调延迟)
- sync-dist 同步到 release/docs

---

## 2026-08-29 (wgime-py-pure: 检测到前台管理员窗口时托盘提示以管理员运行 wgime)

- **UIPI 限制**:前台为管理员(高完整性)窗口时, 普通权限的 wgime 被 Windows UIPI 阻止交互(钩子收不到输入/注入被拒), 连 Shift 切换/组字都不响应
- **提示**:`poll` 里节流(5s)检测 `前台提权 && 自身未提权`, 命中则托盘气泡提示"请以管理员身份运行 wgime"; 只提示一次(`_admin_hint_shown`)
- 真正解法是"以管理员身份运行 wgime"(与提权窗口同完整性级别, UIPI 不再拦截)

---

## 2026-08-29 (wgime-py-pure: 修复候选翻页后按空格上屏第一页第一个)

- **根因**:空格 `commit(ime.sel)`, 而 `sel` 是**页内偏移**(恒 0)——翻页后仍提交 `cands[0]`(第一页第一个), 而非当前页第一个
- **修复**:空格改 `commit(ime.page * 9 + ime.sel)`, 上屏**当前页第一个**候选, 与 C# 版 `Hook_OnSpaced`(`page*PageSize + choose`)对齐
- C# 版逻辑本就正确(`choose=0` → `page*PageSize`, 空格=当前页第一个), 无需改

---

## 2026-08-29 (docs: 把所有文档补上纯 Python 版说明)

- **README**:加「纯 Python 版(wgime-py-pure)」章节 + 文件表格/文件说明/项目演进
- **docs/使用说明**:开头加纯 Python 版小节(环境/单文件/数据目录/快捷键/与 C# 差异)
- **docs/技术文档**:加 §12 纯 Python 版架构(运行环境/模块职责/单文件形态/启动链)
- **docs/插件规范**:加 §8 纯 Python 版插件(双插件形态/步骤 DSL/[python] 块 JSON IPC/[csharp] sidecar/权限 manifest/插件管理)
- **docs/窗体设计语言**:加 §9 纯 Python 版 ui.py 实现(色板/字体/骨架/控件)
- **docs/CHAT_技术文档**:加 §7.4 纯 Python chat 插件(协议互通/ui.py 聊天窗/线程模型)+ §1 表格行
- **AGENTS**:§8 加纯 Python 版概况; 已 sync-dist 同步 docs/config/plugins 到 wg-all/release

---

## 2026-08-29 (wgime-py-pure: 移除昂贵的缓存 md5 校验, 修复启动/首次上屏迟钝)

- **根因**:之前加载 `dict-cache.pkl` 时对 95MB 的 data 全量 `pickle.dumps` 再算 md5 校验, 每次启动 ~1s+, 拖慢启动 → 首次上屏明显迟钝
- **修复**:移除该全量 md5 重算; 完整性改由 `sig`(码表 mtime/size) + `pickle` 加载异常保底; `_save_cache` 不再写 md5 字段

---

## 2026-08-29 (wgime-py-pure: 修复候选框超出屏幕)

- **根因**:固定/常驻(`follow=False`)模式下候选框宽度变化时位置未重算, 候选变宽后右/下边缘超出屏幕, 超出部分不可见("只见一点点/后面看不到")
- **修复**:`bar.show` 非跟随定位分支统一 clamp 到工作区(左/右/上/下), 确保候选框完全在屏幕内; 位置(winfo)异常时回退居中
- 候选条最大宽度 `720→880`、截断下限 `4→8`(候选更完整可读)

---

## 2026-08-29 (wgime-py-pure: 托盘选项即时生效 + 常驻候选窗优化)

- **托盘"选项"勾选态修复**:`_refresh()` 加 `icon.update_menu()`(`checked` 重求值); 原来只更新图标不重建菜单 → 切换后勾选态不变、看起来"点了没反应"(实际 CFG 已改)。验证 `pystray.Icon.update_menu()` 存在
- **切换即时反馈**:`toggle_followcaret`/`toggle_showcode` 切后调 `show_page()`, 立即用新设置重定位/刷新候选框(否则组字中无可见变化)
- **常驻候选窗优化**:`hideidle=0`(关空闲隐藏)时常驻框**固定屏幕右下角贴任务栏**, 不跟随; `toggle_hideidle` 切后直接 `show_page()`(之前空缓冲不刷新导致常驻框不出现); `bar.show` 加 `fixed` 参数(坐标 / `'bottom-right'` / `'bottom-center'`)
- 覆盖此前的"修复关掉空闲隐藏后常驻框不出现"(bef5903)、"常驻候选窗固定位置右下角"(9462009)两轮

---

## 2026-08-29 (wgime-py-pure: 托盘"选项"补全其余开关)

- **托盘"选项"子菜单补全**:整句输入(`sentence`)/联想(`assoc`)/空闲隐藏(`hideidle`)勾选开关(反查编码/繁体/跟随光标/主题已有)
- `main.py` 新增 `toggle_sentence()`/`toggle_assoc()`/`toggle_hideidle()` + api 对应 `get`/`toggle`(sentence 单独 api, assoc/hideidle 同理); 切换写回 `config.txt`, 组字中即时刷新
- `config.txt` 新增 `sentence`/`assoc` 注释项(`hideidle` 已有)

---

## 2026-08-29 (wgime-py-pure: 反查编码开关 + 托盘菜单项)

- **托盘"选项"子菜单新增"反查编码"开关**(勾选态), 切换即生效, 并写回 config.txt 的 `showcode`(候选上显示反查编码, 五笔用五笔码否则拼音)
- `main.py` 新增 `toggle_showcode()` + `api['toggleshowcode']`/`['get_showcode']`; 切换时若在组字则立即刷新候选(显示/隐藏编码)
- `config.txt` 已有 `showcode`(默认 1), 无需新增

---

## 2026-08-29 (wgime-py-pure: 候选框在 Win11 开始菜单被盖住)

- **根因**:Win11 开始菜单(`StartMenuExperienceHost`)是系统 Shell 层, 优先级高于普通 topmost, 候选框被盖住(隐约可见但选不了词)
- **修复**:① `win.py` 新增 `set_topmost()`, `bar.show()` 每次 `deiconify()` 后用 `SetWindowPos(HWND_TOPMOST, SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE)` 提到 topmost z-order 最顶(实测仍压不过开始菜单层); ② 开始菜单/搜索类进程(`startmenuexperiencehost`/`searchhost`/`shellexperiencehost`)时候选框**不跟随光标, 固定到屏幕右下角**(避开 Win11 开始菜单浮窗, 不遮挡中央视野), 配合置顶
- 请用户实测开始菜单搜索框候选框是否清晰可见

---

## 2026-08-29 (wgime-py-pure: 修复开始菜单/搜索类 UI 不能上屏)

- **根因**:开始菜单搜索框/相关 Shell 宿主(`StartMenuExperienceHost`/`SearchHost`/`ShellExperienceHost`)会吞掉 `SendInput` UNICODE 注入, 候选上屏不进去
- **修复**:新增 `_CLIP_FORCE` 集合, 这些前台进程时 `effective_paste_mode` 强制返回 `1`(剪贴板上屏); `APPMODES`(用户 pastemode.txt)显式设置仍优先
- 请用户实测:开始菜单搜索框/搜索面板输入是否能上屏; 若仍有不上的进程, 把该进程名补进 `_CLIP_FORCE`

---

## 2026-08-29 (wgime-py-pure: chat 插件 UI 参考窗体设计规范重做)

- **chat.py 的 ChatUI 改用 `ui.py` 设计系统**(原来是一坨裸 tkinter #F4F7FB/tk.Button/tk.Label, 风格不合规范):
  - `ui.make_window`(无边框圆角 + 自绘标题栏 + 浅蓝灰底色板)
  - 消息区 → **深色控制台** `ui.console_text`(#2E3040 底/Consolas)
  - 昵称/房间/密钥/输入 → **白卡圆角输入** `ui.rounded_entry`
  - Broker 选择 → **flat 按钮行**(选中 accent 高亮, `_pick_broker`); 加入/离开、发送 → `ui.flat_button`(primary)
  - 状态栏(status/online) → 主题色 Label
- **功能逻辑不变**(AES-256/MQTT/relay/收发/在线数), 只重做 UI 布局与控件; 删死代码 `quit()`, 新增 `_on_close`(断网)/`_pick_broker`; `join()` 改读 `_sel_broker`
- 验证: ChatUI 布局测试通过(深色控制台/圆角输入/flat 按钮高亮切换/控件齐全)

---

## 2026-08-29 (C# wgime.bat: 双拼 üe 映射修复, 与 python 版对齐)

- **SpSegment** 的 `Replace("üe","ue")` 改为仅 `Replace("ü","v")`:原 `üe->ue` 会撞码表 `lue`(蓼/庐等), 打不出 **略/虐**(lve/nve); 与 python 版 engine 的修复对齐(两版同源 bug 一并消除)
- **连锁动作**:重编译 wgime.bat 瘦 DLL(556KB, bat 3.3MB) + WgIme.ps1(含完整 DLL, 39MB) + WgTray 三版(wgtray.bat/WgTray.ps1/wgtray-nopayload.bat); 同步 release/ 与 wg-all/
- **修测试脚本 bug**:`tests\wgime-ps1.tests.ps1` 的 `$dllDir` 使用顺序错(第47行用、第48行才定义), 导致 Join-Path null 中断测试; 已修正
- **测试**:`wgime-ps1.tests.ps1` **15/15 PASS** (含 runtime smoke: 启动/解 DLL/无FATAL/缓存命中)

---

## 2026-08-29 (wgime-py-pure: 剩余低危 — pickle 校验 / z通配分桶 / 简拼顺序)

- **dict-cache pickle 完整性校验**:保存时写 `md5` 字段(对 data), 加载时校验 bytes 一致才用; 缓存被篡改/损坏时检测并重建(留痕日志), 不再静默崩/加载错; 顺带补 `engine.py` 的 `import sys`(此前日志用到却未导入)
- **五笔 z 通配改码长分桶索引**:新增 `_build_wb_len()` 构建 `wb_by_len`(按码长分桶), z 通配只扫等长桶, 替代原来 `for k in self.wk` 全表线性扫描; `_init_state`/`reload()` 均重建该索引
- **简拼候选去掉启动预排**:原来按 `self.freq` 预排 acro 列表(与候选排序键不一致), 现改为由 `candidates()` 的统一词频排序决定顺序, 消除不一致

---

## 2026-08-29 (wgime-py-pure: 低危清理 — 死代码/无 with/硬编码/常量/原子写)

- **main**:删冗余 `import importlib`;删死代码 `APPMODE_NAMES`;`load_appmodes`/config 读写改 `with`;抽 `_write_config`(config 原子+正则精确改写, 修 `startswith` 误匹配/BOM);硬编码路径 `C:\Tools\wgime` 改回 BASE;`[python]` 块子进程加 `CREATE_NO_WINDOW`(防闪控制台)
- **engine**:`learnk/recentk` 提为常量 `DEFAULT_LEARN_K/RECENT_K`(去双处重复);`load_config` docstring 补全;`trad.txt` 用 `with`+`utf-8-sig`+捕获 UnicodeError;`read_import_text` 先 getsize 预检+`with`;`_load_cache` 损坏时留痕日志;新增 `_atomic_write` 用于用户词保存(防写盘损坏)
- **win**:`get_caret_uia` 变量遮蔽改名(避免覆盖模块级 w)+去 `r and` 死代码;`screen_workarea` 去重复 `user32`;`get_pixel` CLR_INVALID 返回 `None`(不再误判为白色);`self_elevated` 删未用 `import`
- **tools**:`show_color.tick` 处理 `get_pixel` 返回 `None`

---

## 2026-08-29 (wgime-py-pure: 全面体检高危+中危修复)

- **main**:退出同步落盘词频(`quit_app` 调 `engine.save_freq`);数字键 0 候选 off-by-one 修复;`[python]` 块插件改后台线程执行(不再冻结主线程最长 60s)+子进程 IPC 中文乱码(UTF-8 配置);修 `commit()` is_dyn 在 reset 后判断的回归
- **engine**:词频保存线程竞争修复(用 RLock 状态锁, 锁内快照/锁外写盘, 不再抛 dictionary changed size);`reload()` 导入码表后重放用户词(不再丢已造词);双拼 üe 映射修正(`üe->ue` 错误会撞 lue 码, 改 `ü->v` 得 lve/nve, 打得出略/虐)
- **win**:`send_unicode`/`qtfix` 按 UTF-16 码元注入(支持 astral/emoji 代理对, 不再截断);剪贴板改 ctypes 原生实现(零子进程/零编码问题), `paste` 恢复加代际+读回校验防竞态覆盖;删死 import `subprocess` 与 `_ps_quote`
- **tools**:剪贴板轮询线程加启动守卫(防多开叠加);工具步骤后台线程执行(msgbox/confirm 线程安全, 不再阻塞输入法);取色轮询调度链保持(光标入窗不中断);导入码表对话框点 X 关窗=取消(不再误导入)
- **hook**:Shift 轻拍带修饰键(Ctrl/Alt/Win)不武装(修 Ctrl+Shift/Alt+Shift 误触发);F8 带修饰键透传(不劫持 Ctrl+F8/Shift+F8);数字键仅组字/联想时吞(裸数字透传, C# 对齐);放行所有注入键(不吞第三方宏/AHK/远程桌面);钩子回调异常保护;`start()` 重入守卫;删死代码 `_is_ime_key`/`_is_compose_key`
- **plugins**:`kill` 校验 image 名(修 shell 注入)+列表参数不 shell;`file-del` 盘根/UNC 根防护加固(去 glob 元字符后判);`reg-set`/`reg-del` 用 `with` 自动 CloseKey 防句柄泄漏;`[cmd]` 块结束标记修正
- **ui**:`font()` 用 `tkfont.families` 检测系统可用字体(修死代码);`_round_region` 补 ctypes 签名+失败时 `DeleteObject` 防句柄泄漏;`close()` finally destroy;标题栏文字可拖动

---

## 2026-08-29 (wgime-py-pure: 插件隔离熔断 + 统一 JSON IPC)

- **③ 隔离与超时熔断(中价值)**:`[python]` 块插件改为**子进程运行**(超时 60s, 崩溃/卡死只记日志, 不影响输入法打字);步骤 DSL 的 `run`/`shell` 超时 3600→120s、静默脚本块超时 3600→300s(可见交互块保留);`[csharp]` 保持 sidecar 独立进程
- **④ 统一 JSON IPC(中价值)**:`[python]` 块支持 `handle(ctx)->actions` JSON 契约(子进程 stdout `@wgime <json>` 行协议, stdin 不依赖;宿主动作 `msg`/`log` 已接入,可扩展 `commit` 上屏);跨语言/脚本插件可遵循此统一协议
- 文档:plugins/README 更新 `[python]` JSON IPC 契约与 manifest/权限说明

---

## 2026-08-29 (wgime-py-pure: 插件 Manifest 化 + 权限确认)

- **① 插件 Manifest(高价值)**:plugins/*.txt 头部新增 `version/author/requires/perm` 键;plugins/*.py 模块级 `VERSION/AUTHOR/REQUIRES/PERM` 属性;新增 `plugins.py plugin_meta()` 统一读取(兼容 .py 模块与 .txt Plugin 对象)
- **② 权限声明 + 破坏性确认(高价值)**:`perm` 支持 `low/network/run/registry/destructive`;声明非 `low` 权限的插件运行前弹"插件权限"确认(带版本/作者);步骤 DSL 的破坏性动词(`file-del`/`reg-set`/`reg-del`/`kill`)执行前强确认, 用户拒绝则跳过该步
- **插件管理 UI**:展示版本/作者/权限(⚠风险标记);`clean-bin.txt` 声明 `perm=destructive` 作示例,`calc.py` 补 manifest
- 旧插件无这些字段 → 默认 `perm=low`, 行为不变, 不弹确认

---

## 2026-08-29 (wgime-py-pure: 候选条宽度限制 — 不再铺满整屏)

- **候选条最大宽度**上限从"屏幕宽-24"(铺满整屏) 收紧为 `min(屏幕宽-24, 720px)`, 不再铺满屏
- **候选超宽时动态收紧截断**:候选总宽超上限, 逐步缩短每个候选(24→4 字符逐档), 全部候选仍可见/可数字键选; 到最小仍超则窗口封顶裁剪
- 修复: 长词候选(如整句/简拼长词)过多时候选条铺满整屏、视觉过长的问题

---

## 2026-08-29 (wgime-py-pure: 字频调整升级 — 默认/主动区分 + 近期热度 + 误学回滚 + K 可配)

- **① 默认/主动选择区分**:commit 只对"主动选择"(非默认第1位/非动态, 即数字键选中)做全量词频学习 + LastPick 置顶;空格确认默认词不再被误强化(靠语料先验), 减少"顺手空格就固化一个词"
- **④ 近期热度**:engine 新增 `freq_recent` 滑动窗口(RE_CAP=500, 上屏即计、溢出自动过期);候选排序 = `语料先验 + 学习词频×learn_k + 近期热度×recent_k`, 最近常打的词更靠前且会自然过期
- **② 误学回滚**:上屏词退格删除(联想态退格)时 `unlearn` 撤销最近一次主动学习(freq/freq_m/LastPick/近期窗口), 解决"选错一个词就粘住删不掉"
- **③ K 可配置**:config.txt 新增 `learnk`(默认5000, 全量学习词频权重)/`recentk`(默认200, 近期热度权重), 可自由调
- learn/save 逻辑(递增 `+1`/上限90000,30000/保存前20000/50次或5s flush)与 C# 版一致, 不变

---

## 2026-08-29 (wgime-py-pure: 字频[candidate 排序]延续 python 版更优逻辑)

- **对比 C# 版字频机制**:C# 候选排序只按学习词频 `fb[w]` 降序(语料词频 `WordFreq` 仅用于造句, 不参与候选排序);python 版用 `语料基础词频 + 学习词频×5000`,常见词天然靠前 + 用户常用词被顶上来
- **结论**:权衡后**保留 python 版**(结合语料先验, 更合理),不改成 C# 版纯学习词频排序;源码注释补充该决策说明
- 其余字频机制(学习递增 `+1`/上限 90000/30000、保存取前 20000、50 次或 5s flush、LastPick 置顶、简拼按综合词频排序)两端本已一致,无需改动

---

## 2026-08-29 (wgime-py-pure: 修复 Store 版 Python 把 %LOCALAPPDATA% 虚拟化导致数据目录不可见)

- **根因**:用户机器 `python` 命令命中 Microsoft Store 版 Python 3.13(运行在 AppContainer 沙箱), 它对 `%LOCALAPPDATA%` 的写入被 Windows **重定向(虚拟化)** 到 `Packages\...\LocalCache\Local\`, 导致真实 `C:\Users\<user>\AppData\Local\wgime-py` **不存在**、用户词库/配置/导入码表不可见也无法管理(资源管理器找不到)。C# 版无此问题(非 Store 应用)。
- **修复**:`main.py` 启动时用探针(在 `%LOCALAPPDATA%\wgime-py` 下建目录, 看 `realpath` 是否被重定向到 `\packages\` + `\localcache\`)检测 Store 版虚拟化; 若命中, 把 `DATA_DIR` 切到真实 `C:\Users\<user>\wgime-py`(USERPROFILE, 不被虚拟化), 并把虚拟化位置已有数据(userdict/词频/联想/导入码表/dict-cache/site)搬到新目录, 避免丢失
- 单文件 preamble(`_third_dir`)同样处理, thirdparty.zip 也落到真实位置; 非 Store 版 Python(python.org 官方安装) 走 `_appdata_virtualized=False` 分支, 仍用 `%LOCALAPPDATA%\wgime-py`, 行为不变
- 当前这台机器数据已自动迁移到 `C:\Users\watl\wgime-py`

---

## 2026-08-28 (wgime-py-pure: 托盘菜单分组 + 中英双语)

- **菜单分组**:托盘菜单按 C# 版结构分组——开关 / 模式 / 选项{繁体输出, 候选窗跟随光标, 主题} / 词库{造词, 导入码表} / 这个程序{改用剪贴板上屏, 标点吞字修复} / 退出,扁平项收进子菜单
- **双语**:所有标签中英双语,按系统 UI 语言(`GetUserDefaultUILanguage() & 0x3FF == 0x04`)自动选中文/英文,与 C# 版 `CultureInfo.CurrentUICulture` 判定一致;模式名补英文(Mixed/Pinyin/Wubi/Dict)
- **补造词入口**:词库子菜单加"造词 (Ctrl+Alt+C)",走新增的 `api['makeword']` → `makeword_clipboard()`

---

## 2026-08-28 (wgime-py-pure: 新记事本自动豁免 keyfix + 候选条长度限制 + 内嵌 pystray)

- **新记事本(UWP)上屏乱码修复**:keyfix 的 X+Back 自我中和只在 Win32 EDIT 成立,新记事本是 UWP 控件、不自我中和 → 全角标点后乱码。`effective_keyfix` 加内置白名单 `_KEYFIX_INCOMPATIBLE={'notepad'}`,自动关闭 keyfix;用户 pastemode.txt/托盘切换优先级更高,可显式覆盖
- **候选条长度限制**:候选显示截断(超长词 >24 字符 + `…`)+ 候选条宽度钳制到屏幕工作区,不再无限长
- **内嵌 pystray**:纯 Python 依赖内嵌列表加 pystray(托盘),单文件 ~487KB → ~525KB;PIL/cryptography 是二进制扩展(.pyd),无法 zip 内嵌,保持 pip 可选依赖

---

## 2026-08-28 (wgime-py-pure: 第三方库内嵌, 单文件零 pip 依赖)

- **背景**:现代应用(Edge/新记事本)光标跟随需要 UI Automation,纯 Python 侧用 `uiautomation`(纯 Python,基于 `comtypes`)
- **方案选型**:零第三方方案(ctypes 直调 `UIAutomationCore` COM)需手写 120+ 个 vtable 方法占位 + SAFEARRAY 处理,易错、难维护 → 放弃;改用**内嵌**
- **内嵌实现**:`build-wgime-pure.py` 在构建时收集 comtypes + uiautomation 的纯 Python 源码(71 个模块,排除 test),打包 zip 内嵌进单文件;运行时解压到 `%LOCALAPPDATA%\wgime-py\site\thirdparty.zip` 并 `zipimport`(标准 import 机制,包结构/相对导入天然正确)
- **效果**:单文件 ~148KB → ~487KB(zip 压缩后),目标机器零 pip 依赖;本机构建仍须 `pip install uiautomation`(构建脚本要从已装包读源码)
- **踩坑**:comtypes 的 `_post_coinit` 是"同名模块+包共存",收集时须用 `m.ispkg` 区分——包写 `__init__.py`、模块写 `.py`,否则 zipimport 报 "is not a package"

---

## 2026-08-28 (丢弃 pythonnet 双轨版本)

- 删除 `wgime-py/`（pythonnet + WinForms 双轨方案，已被纯 Python 版完全取代）
- `trad.txt`（简繁表）与 `pywfreq.txt`（语料词频表）移到仓库根——纯 Python 版 `build-package.ps1` 从仓库根取这两个文件

---

## 2026-08-27 (wgime-py-pure: 全部迁移 + 单文件化)

- 其余插件: clock(置顶时钟)/calc(安全计算器)/chat 纯 Python + tkinter
- 内置工具(tools.py, tkinter): 工具箱(tools.txt 步骤 DSL)/剪贴板历史/便签/取色器/网络工具
- 单文件化: build-wgime-pure.py -> dist/wgime-py.py(105KB), 模块+插件源内嵌 exec 进 sys.modules,
  插件注册 plug_*, 最后 main exec 进 __main__; 单文件验证 nihao->你好 + sk->时钟窗通过
- 坑: pprint 字母序排 dict 键破依赖序(改 repr); engine trad/pywfreq 改从 dict_dir 读(去 __file__)
- 启动器码: lt/sk/js/itools/jlb/bj/ys/net

---

## 2026-08-26 (wgime-py-pure: chat 插件纯 Python 迁移 + 互通)

- 插件 API: plugins/*.py 定义 CODE/NAME/run(); 主程序 load_py_plugins() 扫描加载
- wspy.py: 最小同步 WebSocket 客户端 (标准库 socket+ssl, RFC 6455), relay 文本帧 + MQTT 二进制帧
- chat.py: [csharp] 版重写为纯 Python (AES-256-CBC+HMAC via cryptography, relay/MQTT 二选一,
  join/online/leave/chat, auto-reconnect, tkinter 窗 + 网络后台线程 + 队列回主线程)
- 互操作验证: 与 Node 参考端同一 relay 房间互通, 插件正确解密显示, INTEROP PASS
- 踩坑: tkinter 变量不能跨线程读 (join 主线程固化配置)

---

## 2026-08-26 (wgime-py-pure 启动: 纯 Python 版, 零 .NET)

- 动机: 3.8 版本锁来自 pythonnet 轮子, 放弃 .NET 后任意新版 Python 可用 (Python 3.12 + ctypes + tkinter)
- 架构: hook.py (ctypes WH_KEYBOARD_LL 吞键+入队, MAGIC dwExtraInfo 放行自家注入) +
  win.py (SendInput UNICODE/光标跟随/剪贴板) + bar.py (tkinter 无边框 Canvas 候选条跟随光标) +
  main.py (状态机, 复用纯标准库 engine/plugins)
- 实机验证: zhongguo → tkinter 候选条 1.中国→空格上屏 中国 → 联想行
- 踩坑: ctypes 回调 CallNextHookEx 需声明 argtypes (64 位指针 32 位溢出); SendInput INPUT 指针宽
  dwExtraInfo; import tkinter.font as tkfont
- 待迁移: 插件系统改 Python API (chat/clock/calc 重写); 工具箱/剪贴板/便签/取色器/网络工具改 tkinter; 托盘

---

## 2026-08-26 (wgime-py 阶段 3 收尾: 取色器/网络工具/免安装单文件)

- 取色器(跟随光标放大镜, 点击复制 hex); 网络工具(ping/tracert/nslookup 深色控制台)
- 打包: build-wgime-py.ps1 生成 dist/wgime.py.bat (42.5MB 免安装单文件); 内嵌 Python embeddable +
  pythonnet + 码表; cmd 引导按标记 base64 解压到 %LOCALAPPDATA%\wgime-py\runtime (版本缓存);
  端到端验证 IME 启动
- 打包踩坑记录: PS 函数调用数组陷阱/LastIndexOf 标记/.NET Framework 无 bool Extract/
  8.3 短路径子串/单行+单引号

---

## 2026-08-26 (wgime-py 阶段 3 第一批: 插件系统/工具箱/剪贴板/便签)

- 插件系统: plugins/*.txt 解析 + [csharp] 运行时 CodeDom + 专用 STA 线程 (PluginHost),
  lt 选中 ▶聊天 弹出真实聊天窗 (验证); 步骤 DSL 执行器 (含 [shell]/[powershell] 块)
- 工具箱窗体 (tools.txt tab/按钮), 插件管理窗体 (启用/禁用), 剪贴板历史 (序列号轮询), 便签 (自动保存)
- 启动器 ▶ 候选合一 (app/插件/工具/内置 itools+plugins+jlb+bj)
- 修坑: 内置窗体统一调度到 PluginHost STA 线程; pythonnet 需 System.Action 显式包装

---

## 2026-08-26 (wgime-py 阶段 2 第三批: 上屏健壮性)

- 上屏方式路由: paste=auto/on/off/key + 每程序 pin (pastemode.txt 同格式); auto 检测提权窗口自动改剪贴板粘贴 (UIPI)
- PasteCommit 全套: 保存/恢复原剪贴板, 实测粘贴上屏后剪贴板原样恢复
- Qt stale-char keyfix (全角标点后 X+Back 吸收) + per-app pin
- 钩子注入过滤: 自家 SendInput 带 dwExtraInfo='WGIM' 标记直接放行, 修掉 Ctrl+V 被自家钩子误吞
- 托盘: 当前程序剪贴板/标点修复 pin 切换

---

## 2026-08-26 (wgime-py 阶段 2 第二批: config/双拼/vf 面板/造词/启动码)

- config.txt 全键加载 (fuzzy/showcode/shuangpin/trad/sentence/assoc/starton/app), 托盘重载即时生效
- 双拼三方案 (小鹤/自然码/微软, rime preedit_format 逐条移植; 微软 ; 作 ing 码)
- vf 符号面板两级 (5 分类含 emoji); 五笔 z 通配; Ctrl+Alt+C 剪贴板造词 + 单字连打自动造词
  (拼音五笔双注册, userwords.txt 与 C# 同格式); config app= 启动码 (▶候选)
- 托盘菜单: 开关/模式直选/繁简/重载/数据目录/退出
- 验收: vf 两级面板/热键造词/自动造词/双拼单测全过

---

## 2026-08-26 (wgime-py 阶段 2 第一批: 造句/联想/动态候选/v 金额)

- 造句: 一元格架 (pywfreq.txt 7.1 万条词频), zhonghuarenmingongheguo → 中华人民共和国
- rq/sj/xq 动态候选置顶不学习; v+数字出千分位+大写金额 (UpperAmount/Thousands 逐行对齐)
- 联想行: 连续上屏学二元组, ↪联想 行数字选词, assoc.txt 与 C# 同格式; 简拼按词频重排
- 修坑: IsImeKey 漏数字 0; v 模式数字路由与 C# 完全一致 (含裸 v 有候选时数字选词的 quirk)
- 验收: 六场景 + 造句 + rq + 联想链实机全过

---

## 2026-08-25 (wgime-py 阶段 1: IME 核心对齐 C# WordBoard)

- 四模式(混合/拼音/五笔/词典) + Shift 轻拍开关 + Ctrl+\` 模式循环 + Ctrl+Shift+F 繁简(3602 对映射抽自 C# 内嵌表)
- 候选组装与 ShowCharatar 同序: 精确→前缀单字→简拼→模糊音→词频稳定排序(分模式桶)→lastpick 置顶; 五笔四码唯一自动上屏; [ ] 取首/末字
- 词频学习: userdict/lastpick 与 C# 版同格式可互换, 后台落盘
- 码表缓存: pickle + 签名失效, 启动 7.3s→1.35s
- 注入竞态修复: 注入前 30ms 沉降(吞键 keyup 排空), 连打 6/6 全落
- 验收 accept-test.ps1 实机六场景全过(混合/拼音/五笔自动上屏/词典/繁简/Shift 切换)

---

## 2026-08-25 (wgime-py 阶段 0: pythonnet 骨架实机打通)

- 新增 `wgime-py/`:方案 B 双轨骨架——`wgime.py`(状态机/托盘/单实例) + `bridge.cs`(C# 实时层,运行时 CodeDom 编译+md5 缓存) + `engine.py`(码表引擎)。环境:Python 3.8 embeddable + pythonnet 2.5.2 + .NET Framework 4.x(用户零依赖)
- 实机验证:记事本 zhongguo → 候选条(跟随光标/圆角/高亮) → 空格上屏"中国";字典加载 ~250ms
- 关键架构决策:**钩子实时层必须在 C# 侧**(激活态+键类白名单吞键+入队),Python 工作线程消费——实测跨 GIL 的钩子回调会被系统 LowLevelHooksTimeout 静默摘钩
- 踩坑记入 `docs\WGIME_Python重实现方案.md` §7:SendInput INPUT 结构必须 40 字节(x64)、WinForms 句柄必须在泵线程预建、pythonnet 需命名空间、embeddable Python 装 pip 的代理/解包技巧

---

## 2026-08-25 (评估: Python 重实现方案 + 可行性 spike)

- 新增 `docs\WGIME_Python重实现方案.md`:现状盘点(500KB C# 组件清单)、三选型对比(stdlib+tkinter / pythonnet+WinForms / PySide6)、四阶段迁移路线、风险清单
- 新增 `tests\python-spike\`:纯标准库可行性验证——ctypes 全局键盘钩子(坑:hMod 必须 NULL)、py.txt 169k 条 212ms 加载/微秒级查找、SendInput UNICODE 中文上屏,全部实测通过

---

## 2026-08-25 (chat 插件: 界面现代化重构)

- **聊天气泡**:消息列表改 OwnerDraw 自绘——自己的消息右侧 systemBlue 蓝底白字、对方左侧白卡描边、事件居中灰条;引用显示为气泡内首行小字 `↩`;文件消息气泡内含实时状态行(接收中 x/y → ✓ 双击保存/查看 → ✗ 接收失败)
- **连接区紧凑化**:字段标签全部改占位符(EM_SETCUEBANNER),昵称/房间+随机/密钥/加入一行,Broker+LAN+在线人数一行,状态/正在输入合并为一条状态条;消息区高度从 348 → 446
- 消息区画布用比白卡浅一档的 #F4F7FB,白气泡浮在上面
- 验证:`ui-screenshot.ps1 -Demo` 注入演示消息(事件/对方/自己/引用/文件)真实截屏核验气泡渲染;三模式互通回归 + 键盘输入回归全 PASS

---

## 2026-08-25 (chat 插件 M4: LAN-only 纯局域网模式)

- **LAN 模式**:勾选连接栏"LAN"后不连任何服务器——UDP 20003 持久监听(SO_REUSEADDR)+ 255.255.255.255 广播 + 224.0.0.251:5353 组播,与 PC/Android 的 LAN Only 互通
- **对端发现**:lan-beacon 2s 三路心跳(广播/组播/已知 peer 单播)+ 子网扫描 30s(≤512 主机/接口)+ lan-room-query 应答;beacon 来源的 LAN 房间进"活跃房间"列表(双击切换);解析容忍 Android 带 `itools/chat/` 前缀的 room
- **明文聊天**:lan-msg 按 room 过滤、id:ts 去重、支持 quote 引用;无 join/leave/typing(协议如此)
- **文件传输**:LAN 用 3000 字符块,file-start 连发 3 次抗丢包,无 file-end/resend(协议如此)
- **验证**:`tests\interop\` 三模式(relay/MQTT/LAN)× 6 项断言(聊天/引用/文件 sha256 × 双向)全部 PASS;期间修了参考端一个变量名 bug(lanId→docId 导致进程崩)
- 至此 §8.4 路线全部完成;M5(WebRTC P2P)按文档建议确认跳过(插件环境无 NuGet 装不了 WebRTC 库)

---

## 2026-08-25 (chat 插件: 修复输入失灵 + 随机昵称/房间)

- **修复昵称/房间/密钥/输入框无法输入**:上一版改 RoundedEdit 时遗留了一行 `f.Controls.Add(edNick…)`,把内嵌 TextBox 从圆角容器里扯出来直接挂到窗体上——白卡片成了空壳,点了没反应。新增 `tests\interop\ui-input-test.ps1` 真实键盘测试(SendKeys 逐字段验证),防再犯
- **随机昵称对齐 PC 端**:`User_` + 6 位 base36(原"用户_" + hex)
- **随机房间名**:房间名旁新增"随"按钮,生成 `word-word-3digits`(20 词表与 PC `chatRoomRandom`/Android `randomRoom` 一致)

---

## 2026-08-25 (chat 插件: UI 对齐窗体设计语言)

- **圆角**:补 `CreateRoundRectRgn`+`SetWindowRgn`(之前只画了圆角描边,窗口实际是直角)
- **拖动修复**:之前只有标题栏 Panel 响应拖动,标题文字 Label 把鼠标事件吃掉导致几乎拖不动;现在标题 Label 也挂拖动,并新增标题栏底边发丝线
- **FlatBtn 对齐规范**:先填父背景色(圆角外四角不再露出下层)、DoubleBuffered、悬停提亮/按下压暗/禁用置灰
- **输入框**:昵称/房间/密钥/消息输入改用 RoundedEdit 范式(圆角白卡+描边,聚焦 accent 2px)
- **字体**:F() 改用规范回退链 (Segoe UI Variable Display → Segoe UI → Microsoft YaHei UI, Point 单位)
- 表情符号改文字标记(📎🖼📄 在 ListBox/自绘按钮里出豆腐块 → "文件"/[图片]/[文件])
- 新增 `tests\interop\ui-screenshot.ps1`:真实弹窗 + CopyFromScreen 截屏 + 圆角/标题栏/卡片像素校验(规范 §9 的验证方式)

---

## 2026-08-25 (chat 插件 M3: quote 引用 + 文件/图片传输 + 消息历史)

- **quote 引用**:双击消息设置引用(输入框上方出现引用条,点击取消),发送时明文打包 `{"t":正文,"q":{nick,text,q?}}` 再加密(§3.5,嵌套 ≤4 层);接收侧解包后单行显示 `↩引用 ｜ 正文`
- **文件/图片传输**:📎 按钮发文件(内存路径,8000 base64 字符/块,file-start/chunk/end;无直连通道上限 2MB);接收侧 file-start/chunk 校验(sid/len/seq/idx 入槽)+ gap 检测发 file-resend(≤5 轮)+ 15s 超时;完成后双击消息保存文件/预览图片(图片弹窗预览 + 另存为)
- **消息持久化**:每房间最近 80 条存 `%LOCALAPPDATA%\wgime\chat-history.txt`(base64 文本,≤30 房间),加入房间时自动回放
- **验证**:`tests\interop\` 套件扩展为 6 项断言(聊天/引用/文件 × 双向,文件 sha256 逐字节比对),relay + MQTT(EMQX) 双模式全部 PASS
- 测试基建:driver 改用宽松委托绑定(`Delegate.CreateDelegate`)适配插件私有嵌套类型;参考端周期性重发消息消除 relay 时序抖动

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
