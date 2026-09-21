---

## 2026-09-21 (第八十二轮补: 成品冒烟 + 应答分支验证 + 三个坑)

**真成品冒烟**（隔离 `LOCALAPPDATA` + `WGIME_DICT_DIR=仓库根` 跑 `dist\wgime-py.py`）: 日志里出现
`deps: first-run check, missing=argostranslate,faster_whisper`, 与进程内探针一致, 无 Traceback;
且**没有** `deps prompt err`、`deps-state.txt` 也没落盘 ⇒ 当时正停在模态确认框上(格式串有问题会被
`except` 抓成 `prompt err` 并写状态)。**应答后的分支**另用一次性探针 `%TEMP%\wg-r82-prompt.py`
(harness 同款: exec main 前缀 + 桩掉 `messagebox`/`_deps_open_window`)补验 **11/11**: 否→`declined`+`asked=1`;
是→`opened`+真开窗; 只有语音缺件→`reported`(走 `showinfo`); 弹框自己抛异常→`result=error` 但**仍记
`asked=1`**(不每次启动反复炸); 问过就不再问。

**坑①(我的, 代价最大)**: 成品会**自我重启成 pythonw** —— 第一次冒烟"已退出/无日志"是假象: 启动器把 IME
交给 pythonw 子进程后自己退出, 我杀的正是启动器。加上 `config.txt` 放错层级(应放 `DATA_DIR\wgime-py\`),
那两个实例按缺省 ime 模式跑、**装了键盘钩子**, 一度三个 wgime 并存。已按**启动时间**区分归属
(27 分钟前那个是用户自己的, 17:10 两个是我的), 只杀自己的, 复查只剩用户实例。
**规矩**: 冒烟脚本一律 `WGIME_RELAUNCHED=1`, 日志/data 看 `%LOCALAPPDATA%\wgime-py\`(不是 `%LOCALAPPDATA%\`)。

**坑②**: `git add -A -- wgime-py-pure` 会把 `wgime-py-pure\testing\`(永不入库的草稿目录)一起暂存 —— 已
`git restore --staged` 撤回。附带乌龙: `git grep -I -l --cached 'ghp_'`(`--cached` 写在模式**之后**)会让 git
报错, 那条 stderr 被 `Measure-Object` 数成"命中 1", 看着像泄露密钥; 正确写法是
`git grep -I -l --cached 'ghp_'`(空 = 干净)。

**坑③**: `docs\WGIME_使用说明.md`/`docs\WGIME_技术文档.md` 的 **blob 是 CRLF**, 我的生成脚本兜底
`t.replace('\r\n','\n')` 把整文件规整成 LF ⇒ 出现 376/347 的"整文件 diff"(忽略行尾只剩 29/26 = 真正新增)。
已按 blob 行尾写回(`%TEMP%\wg-r82-fixeol.py`)并重跑 `sync-dist`, diff 收敛。**§30 的老规矩适用于所有文本,
不只 txt; 且别用 PowerShell 按行拆分去数 \r\n —— 那样会把行尾证据弄丢。**

**记账**: `AGENTS.md` §5 第 44 条补"冒烟须设 `WGIME_RELAUNCHED=1`"、§7 新增「暂存纪律」;
`AGENTS-DETAIL.md` §D30 追加第 7~9 节(冒烟/应答分支/三个坑)。本轮无代码改动, 未重建 dist。

## 2026-09-21 (第八十二轮: 首次启动自动检查依赖 —— 可选件一键装到 wgime 私有目录)

**来由**: 用户要"增加一个首次启动时自动检查依赖并安装的功能"。先摸清"依赖"在本项目的真实形态:
宿主**核心零依赖**(单文件自带 pystray/pypdf), 缺的只是**某一项功能**。产品决定由用户拍板:
**首启弹一次确认框(默认「否」)** + **语音大件只报告不代装**。

**产出**:
1. **`wgime-py-pure\deps.py`**(新) —— 纯逻辑、不 import 宿主: 清单/探测/安装/状态文件。
2. **`tools.show_depcheck()`**(新窗口) —— 逐项状态 + 勾选 + pip 实时日志 + 全选/重新检测/复制命令。
3. **`main.py`** —— 启动编码 `deps`/`yilai`; 首启 2s 档后台探测(只问一次) + 确认框(默认否);
   `deps.ensure_site_on_path()` 挂在 **30ms 插件装载之前**; 失败只记日志+气泡, 绝不拖累打字。
4. **回归 `tests\deps-test.py`(51 项)**; `deps` 进单文件内嵌清单(12 个项目模块)。

**三条硬规矩**: ①**装到 `DATA_DIR\site\pip`**(`pip install --target`)+挂 `sys.path` —— 不污染用户 Python、
绕开 Store Python 的 `%LOCALAPPDATA%` 虚拟化、与内嵌 zip 同址、卸载=删目录; **不用 `--user`、不写系统
site-packages**(回归里有硬断言)。②**首启只问一次**(默认否), 状态 `DATA_DIR\deps-state.txt`(`asked=1`
之后不再打扰), 重跑走 `deps`/`yilai`。③探测/安装都在后台线程, 异常只记日志+气泡(§40⑤)。

**范围**: 可一键装 = `psutil`/`cryptography`/`argostranslate`(+源码目录缺的 `pypdf`);
只报告 = `faster-whisper`/`sherpa-onnx`(几百 MB 且要另外准备模型, 见 §D8.2)。

**接线里最容易错的一处**: `ensure_site_on_path` 必须在**插件装载之前**执行 —— 插件模块级的
`import psutil` 之类在 `load_py_plugins()` 里就跑掉了, 挂晚了插件看不见私有目录。

**测试怎么做到不联网**: `probe(finder=...)` / `install(runner=...)` 都可注入 ⇒ 全程假 runner, 只验
分类/命令行形态/失败翻译/状态文件/sys.path 幂等; 另有 4 项**窗口几何审计**(手工 `place()` 排版的窗,
遍历子孙算绝对坐标, 越界即红)。**守卫自检**: 故意把窗高 `+38` 改成 `+0`, 审计如期变红
(`bottom=506 H=480`), 还原后 51/51 —— 不会失败的测试等于没写(§43)。

**自查出的两个测试自身 bug**(都表现为假红, 记下来): ①几何审计的 walk 一路走到 `root`, 把窗口在屏幕上的
位置也算进去 ⇒ 改成走到 `win` 为止; ②`dist` 的 `MODULES` 是一行超长 dict 字面量, 正则窗口取 400 字符
只装得下第一个 value ⇒ 改成整行匹配 `'deps':`。

**本机实测(2026-09-21)**: present = `pypdf`/`psutil`/`cryptography`/`sherpa_onnx`;
missing = `argostranslate`(可一键装)、`faster_whisper`(只报告) —— 这条链在开发机上真的会弹一次确认框。

**验证链**: `py_compile -W error::SyntaxWarning` 0 / `undefined-globals.py` 24 文件 0 /
`deps-test.py` **51/51** / `pure-state-harness.py` 全部通过(67) / `example-plugin-test.py` 24/24 /
`standalone-plugin-test.py` 6/6 / `embedded-isolation-test.py` 14/14 / dist-sync
`project modules embedded=12, mismatches=0`、`main.py embedded match: True`。
重建 dist(1136.1 KB)+`build-package.ps1`(package 57.5 MB)后已跑 `%TEMP%\wg-runtime-cfg.py` 还原活配置。

**文档**: `docs\WGIME_使用说明.md` 新增 §12(用户视角: 表格/装到哪/怎么重跑/失败怎么办);
`docs\WGIME_技术文档.md` 新增 §12.4(设计契约表/接线/可测试性/实测); `AGENTS.md` §4 加测试行、
§5 新增第 44 条; `AGENTS-DETAIL.md` 新增 §D30。

## 2026-09-21 (第八十一轮: 「普通单文件 Python 应用 → wgime 插件」写成规范 §8.8 + 可跑模板 + 回归)

**来由**: 用户问"普通的 python 应用（单文件）要怎么改才能作为 wgime 的插件？"，随后说"写进去吧"。
答案原本散在 `main.load_py_plugins()`(`main.py:694`)、`run_launcher()`(`main.py:2091`)、
`_run_plugin_file()`(`main.py:2235`)与规范 §8.1/§8.7 里, 没有一处**面向"我有个现成单文件程序"**的成文指南。

**产出**:
1. **规范 §8.8**（`docs\WGIME_插件规范.md`）—— 装载契约表(位置/必需/装载方式/跳过/触发/线程)、**五步改造**、
   `ui` 可用 API、三条替代路线(txt+外部程序 / `[python]` 块 / 插件壳)、六条陷阱。
2. **可跑模板 `wgime-py-pure\plugins\_example-plugin.py`**（3.7 KB）—— 清单六键 + `ui.make_window` 窗口 +
   后台线程 + 双模式三块齐全, `python` 直接能跑。
3. **回归 `wgime-py-pure\tests\example-plugin-test.py`（24 项）**。
4. `AGENTS.md` §4 测试清单加一行; `AGENTS-DETAIL.md` 新增 **§D29**（本轮细节）。

**为什么模板以 `_` 开头**: `load_py_plugins()` 明确跳过下划线开头的文件(既有 `_standalone.py` 用的就是这条
约定) —— 所以模板**不会被自动装载**: 插件管理器里看不到、不占启动编码、不影响任何现有行为, 但确实躺在插件
目录里(独立运行 `import _standalone` 找得到)。要当插件用: 复制成 `myplugin.py` + 改 `CODE`。

**实测澄清的一处「不对称」（有意为之，不是 bug，别"修"）**: `.py` 插件 `BASE\plugins` 与 `APP_DIR\plugins`
**两个目录都扫**(`main.py:715-719`); `.txt` 插件**只**从 `APP_DIR\plugins` 读(`main.py:689`)。
开发版 `BASE=wgime-py-pure\`、`APP_DIR=`仓库根 ⇒ txt 插件放仓库根 `plugins\`; 分发版两者都是成品目录。
这个分工正对应两种插件的来源(txt 与 C# 版共用, .py 是纯 Python 版专有)。

**回归怎么钉住"不被装载"**: 光断言"文件名有下划线"是在测我自己写的谓词, 所以两头都查 ——
①用**宿主同一谓词**遍历真实目录(模板被排除、`pdf.py` 被包含); ②断言 `main.py` 源码里确实写着
`fn.startswith('_')`(谓词一改测试就红)。另有双模式三块、"文件头必须在第一个宿主 import **之前**"
(用位置比较而非子串包含)、清单六键、按 `load_py_plugins` 同一套判据装载、`run()` 真建出窗口
(`max(winfo_width, winfo_reqwidth) >= 300`)、独立运行(子进程 + 自动关窗钩子 + `LOCALAPPDATA` 隔离)、
文档一致性(§8.8 存在、指向模板、写明目录差异)。

**本轮自查出并修掉的一处真缺陷**: 模板的模块 docstring 原写成普通字符串, 里面的 `\myplugin.py`/`\plugins\`
触发 `SyntaxWarning: invalid escape sequence` —— 已改 `r"""`, 并用 `python -W error::SyntaxWarning -m py_compile`
复验两个新文件(rc=0, 零告警)。

**验证链**: py_compile(+`-W error::SyntaxWarning`) 0 / `undefined-globals.py` 23 文件 0 /
`example-plugin-test.py` **24/24** / `standalone-plugin-test.py` 6/6(模板按设计被排除) /
`pure-state-harness.py` 全部通过(67) / dist-sync `mismatches=0`、`main.py embedded match: True`。

**sync-dist 副产品（第七十六/三十轮的老坑，已按规矩处置）**: ①`release\plugins\wgtranslate.txt` 又被逐字节
拷贝翻成整文件 186/186 的 diff —— `--ignore-cr-at-eol` 证明**纯行尾差异**, 已 `git checkout` 还原;
②`release\docs\WGIME_插件规范.md` 顺带补上了**第七十九轮漏同步的 §8.7**（+84 行里 60 行是本轮 §8.8,
24 行是那次漂移）—— 属于修复, 保留。

**未动 C#**: 没碰 `wgime.bat`, 无需重建 bat/ps1 载荷。

## 2026-09-21 (第八十轮补: §5 改「结构化记法」—— 编号. 主题|硬规则, 一条一物理行)

**来由**: 用户问"文言文压缩实施了？或者直接用计算机能识别理解的编码来记录力求最小化"。
实情是上一轮只做了白话精简, 并未换文体。评估后确认: ①**纯二进制/编码不可行** —— `AGENTS.md` 是
原文注入上下文, base64/gzip 注入进去模型无法心算解压, 省字节但丢可用性; ②**结构化纯文本**才是
"机器可读"的正解。取样实测(§26, 现状 1007 B): 文言版 684 B(-32%) / 结构化记法 468 B(-54%)。

**做法**: §5 的 43 条全部改写为 `NN. 主题|硬规则` —— **一条一物理行**(便于 grep 与精确定位),
`|` 后为正文, 正文内用 `;` 与 `①` 分隔要点; 去掉全部 `**` 强调标记与续行缩进(实测这两项共 ~1.7 KB);
技术标识符/路径/命令一律**逐字原样**。文件头加了一行"§5 记法"说明, 免得后来者看不懂文体。

**保全校验(关键)**: 落盘脚本 `%TEMP%\wg-r80-sec5.py` 对每条做**标识符保全比对** —— 旧条目的每个
反引号片段与 ASCII 标识符(token)必须在新条目里出现。首轮报出 26 条缺失, 逐条复核后: 8 处是**真丢失**
(已补回: §10 主体 `wgime.bat`、§14 `config.txt`、§15 `199f0bd`、§16/17/19 的 `wgime-py-pure` 限定、
§17 `EDR/任务管理器`+CHANGELOG 指针、§26 主体 `tools.txt/插件 txt`、§27 `瘦 DLL+ps1+15 项测试`、
§30 `payload 与源码不一致`、§32 `run_steps`/`_run_verb`), 余 4 处是**格式等价**(`**msgbox` 少一层星号、
`yview() == (0.0, 1.0)` 多空格、`py/wb/ec/...` 拆成逐项、重排的短语)。

**数字**: `AGENTS.md` 50,001 → **42,763 B**(对 65,232 的余量 15.2 → **22.5 KB**);
§5 36,734 → 29,416 B。另把 §7 唯一一段纯历史("发布回验记录" v1.2.11~v1.2.14 的 id/SHA 比对)
搬进 `AGENTS-DETAIL.md` **§D28**, 正文只留回验规则。
校验: §5 的 1..43 条全在(43/43)、文件尾完整、行尾 LF(CRLF=0)、§D19~§D28 十节齐全。

**底线说明**: 本文件约 24% 是**逐字标识符**(不可压), 另有 ~20% 是文件名/英文词, 故极限约 30 KB;
再往下压就要动规则措辞本身, 风险大于收益, 到此为止。

## 2026-09-21 (第八十轮: 文档瘦身 —— AGENTS.md 压缩到 50KB, 叙事逐字搬进 AGENTS-DETAIL.md)

**来由**: `AGENTS.md` 是唯一被自动注入的文档, 注入预算 **65,232 B**, 此前已多次在尾部被截断(§8 被切掉)。
用户要求"再压缩一下, 压缩进 agents-detail.md"。本轮只动文档, **不动任何代码**。

**做法(零信息损失)**: 逐条把 §5 里最长的 10 条(§12 / §16 / §22 / §27 / §28 / §30 / §38 / §39 / §41 / §42)
改写成"**要照着做的规则 + 指针**", 而**压缩前的原文逐字**追加到 `AGENTS-DETAIL.md` 的
`§D19`~`§D27`(§D19 布局审计 / §D20 行尾与不可复现构建 / §D21 反向差异清单 / §D22 read_text 名单 /
§D23 英汉表 ec / §D24 插件 Manifest 权限隔离 / §D25 第三方内嵌 / §D26 窗口高度审计 / §D27 语音输入全文)。
AGENTS.md 里每条都留了 `原文见 §Dxx` 的指针, 所以**规则一条没删, 只是叙述搬家**。

**数字**: `AGENTS.md` 57,573 → **50,001 B**(对 65,232 的余量 5.7KB → **15.2KB**);
`AGENTS-DETAIL.md` 130,049 → 151,620 B(该文件不参与注入, 无上限压力)。
校验: §5 的 **1..43 条全在(43/43)**、文件尾完整、行尾仍是 **LF(CRLF=0)**。

**工具**: `%TEMP%\wg-agents-slim2.py` —— 按**行号区间**替换(自下而上, 避免行号漂移), 并在写盘前断言
①每条区间首行的条目号锚点、②新文本无行尾空格、③行内反引号配平、④行长 ≤122。备份 `%TEMP%\AGENTS.md.bak`。

**教训(已回滚重做)**: 第一版用 `textwrap` 自动折行, 结果把行内代码跨行切断(`STANDALONE = True` 被拆开)、
续行缩进错乱, 而且只省了 3.4KB —— 已 `Copy-Item` 回备份后用**手工折行**重做。

## 2026-09-20 (第七十九轮: plugins/*.py 双模式 —— 既能被宿主装载, 也能 `python xxx.py` 独立运行)

**来由**: 用户要"py 插件能同时作为插件和独立程序"。现状做不到: 插件的 `import ui`/`import engine`
等宿主模块在**模块级**, 独立跑直接 ImportError; 且 `run()` 依赖宿主已建好的 Tk root。

**机制 (三块都有才算双模式; 约定全文在 `docs/WGIME_插件规范.md` §8.7)**:
1. **文件头**(在第一个宿主 import 之前): `if __name__ == '__main__':` 把宿主目录(上级)插进 `sys.path`。
2. **清单识别标记**: 模块级 `STANDALONE = True` —— 插件管理器据此显示 `py·双模`;
   `main._py_plugin_meta_static` 用正则读它(不 import)。
3. **文件尾**: `if __name__ == '__main__': import _standalone; _standalone.standalone(run, NAME)`。

宿主装载时 `__name__` 是合成模块名(`wgime_ext_...`), 三块都不执行, 与装载零冲突。

**新增共享引导 `plugins/_standalone.py`**(**名字以 `_` 开头是故意的**: `load_py_plugins` 跳过 `_` 开头的
文件, 所以它不会被当成插件收, 但跟插件同目录, `import _standalone` 找得到): `standalone()` = 补 sys.path
(宿主目录) → 挂内嵌第三方 zip(`%LOCALAPPDATA%\wgime-py\site\thirdparty.zip`, 给 pypdf 这类用) → 建隐藏
Tk root → `run()` 建窗 → 窗口关即退出; 成功打印 `STANDALONE-OK`; 测试钩子 `WGIME_STANDALONE_AUTOEXIT_MS`
到点自动关窗(不然回归测试挂住)。

**6 个插件全部加齐三块** (calc/chat/clock/wgime-qr/wgtranslate/pdf); 插件管理器列表显示 `py·双模`。

**新回归 `wgime-py-pure/tests/standalone-plugin-test.py` (6 项)**: 真把每个插件当独立程序跑
(子进程 + 自动关窗钩子 + `LOCALAPPDATA` 隔离 —— 绝不碰用户数据), 断言打印 `STANDALONE-OK` 且退出码 0;
无桌面则 SKIP。

**全链**: compile 0 / undefined-globals 22 文件 0 / harness 67 / pdf 78 / standalone 6 / iso 14 / dist-sync OK。

## 2026-09-20 (第七十八轮: 中文标点全面补齐为标准输入法全角映射 —— 数字行符号 ！＠＃￥％……＆＊（）)

**来由**: 用户实测"上屏标点符号的时候还是有问题，比如数字键上面的符号没办法成为全角的符号，
麻烦全面检查一下，要符合标准输入法的逻辑"。旧的 `MapPunct`(C# 与 python 两处一致)只覆盖
`, . ; / \ [ ] '` 这一小撮 + `Shift+4→¥`(半角!) —— 数字行符号全部透传成 ASCII。

**标准映射表**(微软拼音/搜狗通用的全角逻辑, 两版逐条一致; 全表也在 `AGENTS-DETAIL.md` §D17):

| 键 | 裸 | Shift | | 键 | 裸 | Shift |
|---|---|---|---|---|---|---|
| `` ` `` | · | ～ | | `;` | ； | ： |
| `1..0` | (数字/候选) | **！ ＠ ＃ ￥ ％ …… ＆ ＊ （ ）** | | `'` | ‘’ 交替 | “” 交替 |
| `-` | 放行 | —— | | `,` | ， | 《 |
| `=` | 放行 | ＋ | | `.` | 。 | 》 |
| `[` `]` | 【 】 | 『 』 | | `/` | 放行 | ？ |
| `\` | 、 | ｜ | | | | |

**改动(两侧)**:
* python: `hook.py` 吞键集扩到 `, . ; ' \` + Shift 变体 + 任意 Shift 的 `\ [ ]` + Shift+`/`/`-`/`=` +
  **空闲时 Shift+数字行**(组字中数字仍被候选分支吞走选候选, 不变); `main.py` `map_punct` 全表 +
  `_HALF_PUNCT` 同步补(cnpunct=0 半角回退) + `handle()` 分派扩到 `0xC0`、Shift+`-`/`=`、Shift+数字。
* C#: `wgime.bat` `MapPunct` 同样补齐(数组 `ShiftDigitFull` + 8 个新 case); 走完整 §3 链:
  `rebuild-wgime-bat-payload`(瘦 DLL 559KB) → `build-wgime-ps1`(39.4MB) → `sync-dist` →
  `wgime-ps1.tests.ps1` **15/15**。
* **有意的行为变更**: `Shift+4` 由半角 `¥`(U+00A5)改为全角 `￥`(U+FFE5) —— 与整套全角表一致,
  也是标准输入法的输出。
* 决策点(别再来回改): Shift+8 给 `＊`(全角星, 与系列一致; 不是 `×`); Shift+6 `……`(U+2026×2);
  Shift+- `——`(U+2014×2); 裸 `/`、裸 `-`、裸 `=` 保持半角放行; 组字中 Shift+数字 = 选候选
  (数字分支先吞, 不带 shift 位); cnpunct=0 时全部透传半角(实测矩阵)。

**守卫(新增 harness 67 项里的 13 项)**:
* 映射表 6 项: 16 组非数字键 + Shift+1..0 全对 + **`Shift+4 是 ￥ 不是 ¥`** + 裸数字不受影响 +
  引号交替 + `Shift+1 给 ！`。
* hook 吞键矩阵 3 项(伪造 lParam + 假 `_key_state` 直调 `_proc`, 21 组按键吞/放 + cnpunct=0 透传 +
  未激活透传) —— 常驻化了以前只在探针里的判定矩阵。
* 上屏集成 4 项: 空闲 Shift+1 → `！`; 组字中先上屏首候选再上屏 `！`(recent 链照记);
  半角模式上屏 ASCII `!`。
* **C# 与 python 的表逐条交叉核对**(探针 `%TEMP%\wg-r78-punct-cross.py`, 7/7): 数字行数组逐字一致 +
  键集合一致 + 映射一致 + 两侧都不再出 `¥`。
* python 全链: compile 0 / undefined-globals 21 文件 0 / harness 67 全过 / pdf-test 78 / iso 14 / dist-sync OK。

**这轮抓到的两个"测试与代码同错"的坑**(第七十六轮那条规矩的又一例, 必须记):
① 数字行数组我第一版按 `1..9,0` 的键序排(`('！','＠',…)`)而索引用 `vk-0x30`(0=Shift+0) ——
**代码和测试用了同一个错 tuple, 循环断言全绿**, 是被独立写的 `Shift+4→￥` 单点断言抓出
`Shift+1→＠` 的; 现在表里加了物理键序注释, 测试里加了一条 `Shift+1→！` 的独立单点。
② 引号交替断言放在表循环后面时, 表循环已经把 `‘’` 消耗过一次 → 顺序不同结果不同;
现在交替断言前后都显式复位 `_sq_open/_dq_open`(测试要自足, 不许被前面的段污染)。

## 2026-09-20 (第七十七轮补: PDF 工具的两个用户实测问题 —— 默认选项文字消失 + 没有预览)

用户拿真窗口试 P2, 截图反馈两个问题:

1. **默认选项的文字会消失** ('90°' / 'PNG' / '自动' 三个预选项, hover 一次就变"白底白字"):
   根因是用 `ui.flat_button` + 事后 `.configure(bg=ACCENT, fg='white')` 做选中态, 而 flat_button 的
   Enter/Leave/Press/Release 处理器把 `bg` 恢复到**创建时**那一份(闭包绑死) —— 预选的按钮被划过
   就复位成 CARD 白底, 而 fg 还是白, 文字消失。修法: 换成插件内的 `_toggle_btn`, 颜色**每次重画都从
   当前状态现算**(hover/press 只调亮暗, 不动语义色)。**守卫**: `tests/pdf-test.py` UI 段新增
   "对全部 Label 模拟 Enter/Leave(光划过不点 —— 带上 Release 反而会被 flat_button 的
   先复位 bg→再触发 command→又把色配回来 的顺序盖住) 后, 断言没有'前景=背景'的控件",
   颜色用 `winfo_rgb` 解析再比('white' 与 '#ffffff' 才不会误判)。守卫自检: 旧代码 → **1/75 红**
   并打印 `('90°','white','#FFFFFF')` 三项, 修完 → 绿。**同类存量问题**: `plugins/chat.py:156`
   是同一种写法(标签页选中态), 同样会在 hover 后隐形, 记为待修(本轮不扩大范围)。
2. **没有预览**: 文件列表缩窄(616→420), 右侧加 188×86 预览框 —— 选中文件后**后台**走
   `preview_first_page()`(pypdf 读第 1 页 mediabox 算贴框缩放 → WinRT 渲染)出图,
   `win.after` 回主线程 `tk.PhotoImage` 显示(保引用防 GC; token 丢弃过期结果, 防"快速换选后旧图
   盖新图"; 临时目录用完即删)。预览依赖 WinRT 这条腿, 不可用就如实写"预览不可用", 不假装有图。

`tests/pdf-test.py` 75 → **78 项**(preview_first_page 贴框 + PNG 存在; UI 段预览真的渲进框)。
窗口 640×626, **40 个控件**: 越界/两两不重叠/hover 隐形文字/单例/线程日志 全绿。

## 2026-09-16 (第七十七轮: PDF 工具作为插件落地 —— 内嵌纯 Python pypdf + 51 项回归)

**来由**: 用户让"看看 itools 里的 PDF 功能怎么实现的" → 给出可行性方案 → 用户拍板三问:
①接受单文件变大 ②**要插件形态** ③WinRT 渲染那条线**并做**。本轮做了 P1(纯 pypdf 的结构操作),
P2(WinRT 常驻 helper: 转图片/扫描件压缩/OCR 取字) 留到下一轮。

**一件事的边界先划清楚**: itools 那套是 **WebView2 + pdf.js + pdf-lib**(浏览器栈, 依赖宿主装 Edge
Runtime), wgime 是纯 Python 单文件 + Tk, **一行都抄不过来**。能做的是另找两条腿:
**pypdf**(纯 Python, 能内嵌) 管页面结构, **Windows 自带的 `Windows.Data.Pdf`**(探针实测可用, 零安装)
管栅格化。本轮只落第一条腿。

**做了什么**:
1. **把 pypdf 6.19.0 收进内嵌第三方** (`build-wgime-pure.py`): roots 由 `['pystray']` 变成
   `['pystray','pypdf']`; 它是 60 个 `.py` / **0 个 `.pyd`**、BSD-3-Clause、`Requires-Python >=3.9`
   (classifier 列到 **3.14**)、唯一声明依赖 `typing_extensions` 只在 <3.11 且源码里有版本守卫 ——
   所以是"能内嵌"的那一类, 不是 Pillow/comtypes 那种 ABI 绑定的故事。
   实测代价: 源码 1,708,063 B → zip 380,633 B → 单文件 base64 **+507,511 字符**;
   **dist 605 KB → 1,110.4 KB**(1,137,049 B), 内嵌第三方模块 14 → **73** 个。
   构建机多一个**构建期**依赖: `python -m pip install pypdf`(用户机不需要, 单文件里已经有了)。
2. **新插件 `wgime-py-pure/plugins/pdf.py`** (CODE=`pdf`, PERM=`low`, 25.4 KB): 拆分 / 合并 / 旋转 /
   删页 / 提取文字 / 分析 六个操作 + 结构无损压缩(`compress_lossless`, 只在逻辑层暴露)。
   形态要点: 它是**进程内** `.py` 插件(`load_py_plugins` → exec_module → `run()` 跑在 **Tk 主线程**),
   所以能直接用宿主 `ui.make_window` 建同款窗口; 重活全丢后台线程, 只经 `win.after(0, …)` 回主线程
   改控件; 带取消(`_CANCEL` 检查在每页循环里)。**绝不覆盖原文件** —— 输出写同目录 `xxx_后缀`,
   重名自动 `-2`/`-3`。发现方式: 上屏打编码 `pdf`(`refresh()` 的 `find_launcher` 会给
   `▶PDF 工具` 候选), 插件管理器里也能直接运行。
3. **新回归 `wgime-py-pure/tests/pdf-test.py` (56 项)**: 从 **dist 成品**里解出 `THIRD_ZIP_B64`
   挂到 sys.path 最前面, 断言 `pypdf.__file__` **确实在解出来的那个 zip 里**(否则"构建机装了 pypdf"
   会把"内嵌漏了"糊过去 —— 同第六十九轮 six 的教训); fixture 全部**现造**(脚本里手写带正确 xref 的
   PDF, 可切 FlateDecode/空内容流), 然后 合并/拆分/每页一文件/取消/旋转/删页/取字/压缩/页号解析/
   不覆盖写/错误路径 全部真跑一遍; 最后 5 项是 **UI 层真建窗口**(无桌面则 SKIP): ① `run()` 建得出窗口
   ② 26 个控件没有一个越出窗口(§42 的裁切审计法) ③ **子线程 `win.after(0, …)` 能回主线程** ④ 后台预热的
   引擎日志真到达主线程 ⑤ 重复 `run()` 是单例。
   **这里踩到一个"测试自己会骗人"的坑**: 第一版探针用 `root.update()` 循环驱动事件, 子线程的 `after`
   直接被 `_tkinter` 以 `RuntimeError: main thread is not in main loop` 拒掉 —— 看着像"插件的日志路径坏了",
   其实只有 `mainloop()` 里的主线程才允许别的线程 `createcommand`。所以 UI 断言**必须真跑 mainloop**
   (用主线程里排的 `after(5000, …)` 收网再 `root.quit()`)。
4. **两个守卫跟着更新**: `embedded-isolation-test.py` 13 → **14 项**(内嵌清单断言改成
   **正好** `{pystray, six, pypdf}`; 新增"干净环境 pypdf 写空白页→读回"往返; 新增
   **内嵌 zip 里不许有 `__pycache__`/`.pyc`**); `tests/pure-state-harness.py` +4 项(插件
   **装载契约**、PERM=low、纯逻辑层可直接调用、**模块级不许 import pypdf**)。
5. **P2 —— WinRT 那条腿也落地了**(用户拍板"并做"): 新增常驻 **PowerShell 助手**
   (内嵌在插件里、源码走环境变量 `WGIME_PDFW32_SRC` + `iex`, **不落盘**), 三个新操作:
   **转图片**(PNG/JPG, 宽度可调) / **OCR 取字**(`Windows.Media.Ocr`) / **压缩(转图片)**
   (栅格化后由新增的 **纯 Python `build_pdf_from_jpegs`** 重拼 PDF —— 连 pdf-lib 都不需要,
   itools 那边这一步是靠 pdf-lib 的)。窗口加一行操作磁贴 + 一行参数(宽度/格式/OCR 语言),
   640×584 → **640×596**。
   助手机制照抄第六十三/六十四轮的 `_WarmSrv`: `lock` 管起杀、`rlock` 管一问一答(**两把锁别合并**)、
   `ensure_ascii` JSON 回包、父进程退出=stdin EOF=子进程自退(实测 rc=0/81ms)、连续 3 次起不来不再重试;
   差异只在协议(JSON 行 + `id` 配对 + `progress` 行)和**取消 = 杀掉助手**(单线程助手渲染途中读不到
   stdin, 所以只能杀; 下次调用自动重启, 回归里专门验了这条)。

**实测数字 (探针在 `%TEMP%\wg-pdf-feas\`, 结论抄进 `AGENTS-DETAIL.md` §D16)**:
* pypdf 隔离可用: `python -S -E` + 只挂内嵌 zip, 读/页数/元数据/拆分/合并/旋转/删页全通;
  **zipimport 冷启 865 ms**(普通目录 388 ms) → 所以插件里必须**懒 import**(harness 有守卫),
  窗口一开就后台预热。
* **结构压缩不承诺能压小**: 真实图片型 PDF 1900.6 KB → 1874.9 KB(**99%**); 小文字型 PDF
  1359 → 1452 B(**107%, 反而变大**)。能不能大幅缩小要看 P2 的栅格化。
* **取文字**: born-digital fixture 精确取到; 本机两份真实 PDF(`Microsoft: Print To PDF` 产物)
  **0 字符** —— 它们是图片型, 这时插件如实报"可能是扫描件", 不假装成功。
* **加密**: AES 打不开(要 `cryptography`, 已在 `_THIRD_SKIP`); **RC4-40/RC4-128 有纯 Python 回退, 能开**。
* **WinRT 那条腿已验证可用**(P2 的底气): `Windows.Data.Pdf` 加载 2 页 99 ms、渲染 1240 px
  宽 PNG 626 ms/146 KB、JPEG 110 KB、两页 JPEG 合计 196,268 B = **原件的 9.7%**;
  `WinRT PdfPage` **没有**取字 API; `Windows.Media.Ocr` 语言包含 **en-US + zh-Hans-CN**。
  两个 PS 5.1 的坑: WinRT 类型必须写 `,Windows.X,ContentType=WindowsRuntime`;
  `RenderToStreamAsync` 返回 **`IAsyncAction`**, 塞进泛型 `AsTask<T>` 会报 `__ComObject` 转换失败;
  `PdfPageRenderOptions` **没有 `JpegQuality`**(质量档要再用 System.Drawing 重编)。
* **P2 实测**(助手走环境变量 + `iex` 的真实路径): 命令行 **89 字符**(脚本 7.3 KB 不进命令行)、
  spawn 28 ms、**就绪(spawn→能用)1.2~1.8 s**、渲染 **~217 ms/页**@1240px、OCR 1 页 ~0.3 s;
  OCR 把我那个手写 fixture 读成 `'Page 1 ： HeIlo PDF WorId -- WgIme feasibility probe...'`
  (l/I 混淆, 内容全对); 取消后重启也验过。**fixture 只有 1.4 KB, 栅格化后 ratio 必然 >100%**
  (实测 11113%) —— 压缩率的意义在图片型 PDF 上, 别拿小文字 PDF 当证据。

**教训 (要照做)**:
* **插件要"跑在宿主进程里"才能开宿主风格的窗口** —— `plugins/*.txt` 的 `[python]` 块是
  `python.exe <临时脚本>` 子进程(还有 60s 熔断), **拿不到宿主的 sys.path**, import 不到内嵌的
  pypdf, 也开不了 `ui.make_window`。要带 UI 的插件就写成 `plugins/*.py`(exec 在宿主, `run()` 在 Tk 主线程)。
* `build-package.ps1` 第 48 行本来就会把 `plugins\*.py` 拷进 `package\plugins\` —— **但要在
  pdf.py 存在之后重跑一次**, 否则成品包里没有这个插件(本轮实测踩到)。
* 新增/删除内嵌依赖后**必须重跑 build-package + 两条守卫**; 内嵌清单断言是"正好等于", 改动必然会红一次。
* **`.ps1` 里的中文会要命**(§2 那条规矩的又一次实锤): 助手第一版带中文注释和中文报错, 用
  `powershell -File` 跑直接 **ParserError**(PS 5.1 按 ANSI 读 .ps1) —— 现在助手源码**纯 ASCII**,
  面向用户的中文提示全留在 Python 侧。走"环境变量 + `iex`"这条路时没有 ANSI 解码问题(环境块是 UTF-16),
  但**纯 ASCII 是更省心的选择**, 别留混编。
* **"越出窗口"的审计查不出"控件互相压住"**(用户当场发现): P2 把第 3 行操作磁贴放在 `y=270`, 而
  「页码范围 / 角度 / 每页一个文件」那行还在原来的 `y=272` —— 39 个控件**全都在窗口内**,
  越界审计 5 项全绿, 可两行控件正叠在一起。`tests/pdf-test.py` 现在多一条**两两不重叠**断言
  (直接子控件矩形**真相交**; 贴边不算 —— 控制台 Text 与它的滚动条本来就是贴着的), 并做了守卫
  自检: **先拿坏布局跑 → 1/74 红**并打印出重叠的两对矩形坐标, 修完布局 → **74/74**。
  布局最终值: 三行磁贴 194/232/270, 参数行 310/348, 日志 390(h=140), 底栏 540, 窗口 640×**626**。
  **别只防"出界", 还要防"互相压"** —— 这类窗口全是 `place()` 显式坐标, 没有布局管理器兜底。
* **助手"就绪要多久"要从父进程量**: 子进程自己报的 `boot_ms` 只算了"PS 起来之后脚本初始化"那一段
  (0.1 s), 而用户真等的是 powershell.exe 冷启 + WinRT 初始化(**1.2~1.8 s**) —— 少报会让 UI 那句
  "WinRT 就绪 (x.x s)" 变成假话。现在用 `spawn 时刻 → 收到 ready`。
* **push 卡住先怀疑凭据管理器的 UI 对话框, 不是网络**(本轮实测): `git push` 挂了 10 分钟没有任何输出;
  `GIT_TRACE=1` 一看, 卡点不是 TLS、不是传输, 而是 `run_command: 'git credential-manager get'`
  —— GCM 在等一个对话框(过往日志里就有 `fatal: User cancelled dialog.`)。
  抢修/排查的固定姿势: ① `GIT_TRACE=1 git -C <repo> push origin master` 看卡在哪一步;
  ② `GCM_INTERACTIVE=never` + `-c credential.interactive=false` 让它**快速失败**并给人话
  (`fatal: Cannot prompt because user interactivity has been disabled.`) 而不是挂住;
  ③ 远端 ref 用 `git ls-remote origin master` 核(公开仓库的读不需要认证, 所以 **GET 能通不代表能 push**)。
  **第七十八轮补充(更狠的现场)**: GCM 后来恶化到**连 `git credential fill` 都卡 30s+ 不返回**,
  7 个 git 进程全部 0 CPU / 0 I/O 挂几十分钟(不是慢, 是完全没开始传 —— 43MB 一度以为要 40 分钟)。
  **抢修办法(全速 25s 推完)**: 绕过 GCM —— 用 P/Invoke `CredRead('git:https://github.com')` 直接从
  Windows 凭据管理器读存量 PAT(脚本 `%TEMP%\wg-push-pat.ps1`), push 时
  `-c credential.helper=`(置空, 不让它问 GCM) + `-c "http.extraHeader=Authorization: Basic <b64>"`
  (**值里有空格, 参数要内嵌引号**, 否则 git 把 `Basic` 当成子命令)。`Start-Process` 只能按空格拼参数,
  含空格的值一律自己加引号。
  **另两个本轮踩到的脚本坑**: `Start-Process` **不继承 PowerShell 的 `cd`**(用的是 .NET CWD) ——
  免 CWD 依赖就写 `git -C <repo>`(再顺手加 `-WorkingDirectory`); 以及 `if (Func ...)` 会把函数写进
  输出流的诊断文本**当成布尔条件**(非空数组恒真), 于是出现"假成功" —— 诊断要用 `Write-Host`(host 流)
  或先落到变量里。**判定推送成不成只认 `git ls-remote origin master` 与本地 HEAD 是否相等**,
  别信任何脚本的"OK"(`git push` 在 Start-Process 下 rc 都拿不到)。

## 2026-09-16 (发布 v1.2.14 —— 顺带修掉一个发布事故: v1.2.13 的 python 包带着开发机私用 config 和一把 API key)

**发布**: release id **391874873**，tag `v1.2.14` = 本地 HEAD `d85a98e`；三个资产（bat/ps1/python）与
`.release-stage-v1214\` **SHA256 全同**、body 与本地 `wg-rel-body-v1.2.14.md` 逐字符一致（2079 字、**0 个 `?`**）、
线上 python 包内层 `wgime-py.py` **619381 B** 与本地 dist 逐字节一致。功能代码与 v1.2.13 **完全相同**
（本轮只动测试与文档，所以这是一次"打包修复 + 汇总"的发布）。

**事故（v1.2.13 的 python 资产）**: 那份 `wgime-v1.2.13-python.zip` 里混进了**开发机正在使用的 `config.txt`** ——
`voice = 1`、`voice_engine = sherpa`、`stt_script = C:\Tools\wgime-local-asr\wgime-stt.py`、`stt_threads = 8`，
并且**含一把硅基流动 API key**（自 2026-09-17T01:44Z 起随公开资产可见，**必须吊销/更换** —— 这件事只有用户能做）。
根因：`tests\build-release-assets.ps1` 是**逐字节打包** `wgime-py-pure\package\`，而那里的 `config.txt` 常常是
"本机在用的活配置"（`build-package.ps1` 本会用仓库根模板覆盖它，但只要之后改过配置/跑过本机脚本就又变回私用）。

**三件事**:
1. **修**: 重建 package（`build-package.ps1`）→ `package\config.txt` 重新等于仓库模板（12492 B）→ 再打 v1.2.14；
2. **补**: 新增永久守卫 `tests\release-assets-check.py`（**发版前必跑**，见 AGENTS.md §7）：断言三个 zip 的
   `config.txt` 与仓库模板**逐字节一致**、不含 `sk-` 私钥 / `C:\Users\` 私用路径 / **启用**的 `stt_key|stt_script|
   stt_python|stt_cmd` 行、python 包内层 `wgime-py.py` 与 dist 逐字节一致、条目分隔符都是 `/`。
   **守卫有效性自检**：拿**那份泄漏包**跑它 → `config.txt 与模板逐字节一致`、`没有 API key`、`没有启用的本机 stt_* 项`
   三条**红**（13 项里 5 项失败，另两条是那个目录里没有 bat/ps1 zip）；干净资产 **27/27 全绿**；报错输出里 key 打码；
3. **清**: 原 `wgime-v1.2.13-python.zip` 资产**已替换成同一份干净包**（25598416 → 25598298 B；v1.2.13 的 body
   追加了"已替换为干净包"的补记，tag 仍指 `56f7ffe`，bat/ps1 资产一字未动）。
   **历史资产核查**（顺手做的）：v1.2.12 / v1.2.11 的 python 包 `config.txt` 分别是 3303 / 2385 B，
   **0 个 `sk-` key、0 条启用的本机 `stt_*` 行** —— 泄漏只发生在这一个版本上。

**教训**: "把开发机的活配置打进发行包"这类事故**肉眼看不出**（zip 能解压、程序能跑），**只有校验能拦**。
所以判据固定成"`config.txt` 必须与仓库模板**逐字节相等**"，而不是"看起来像个模板"；
发布流程里也因此多了一道**本地**（不联网）的预检关。复盘/命令见 `AGENTS-DETAIL.md` §D15。

## 2026-09-16 (第七十六轮: 拉取第七十二~七十五轮后跑全量回归 —— 修两处"测试自己"的缺陷)

**来由**: 上一轮把远端进度拉下来（wrapper `--serve` + 协议漂移守卫、`voice_click`、`voice_engine = stream`、
v1.2.13）之后跑整套 python 回归, 发现 **两个红不是代码的错, 是测试自己的错** —— 而且都属于"看起来像功能坏了,
其实是环境/现场"的那一类, 会污染以后每一次回归。两条各修各的, 并都补了守卫有效性自检。

**① `stream-asr-test.py` 依赖机器上一个不存在的录音文件（第七十五轮留下的）**:
- 写死 `C:\Tools\wgime-local-asr\portable\test-zh.wav`（本机根本没有 `portable\` 这个目录）→ A/B 两组在
  "读不到录音文件"上全红; 更糟的是第 120 行 `p = SEEN[-1][1]` —— 服务端一条请求都没收到, **直接 IndexError
  traceback 崩掉**, 而不是干净地 FAIL（"测试要么 OK 要么 FAIL, 不能中途炸"）;
- `PURE` 也写死成 `C:\Tools\wgime\wgime-py-pure`（只有本机这个 checkout 才碰巧对, Windows 大小写不敏感才没炸）;
- **修**: ① 这条路只要"能从文件读出字节再 base64", 内容无关 —— 测试开头自己搓一个 0.2s / 16kHz / 单声道
  wav 到 `%TEMP%`; ② `PURE` 从 `__file__` 推（`<pure>\tests\` 的上两级）; ③ 加 `last_seen()` 空则返回 `{}`,
  所有取"最后一条请求"的地方走它; ④ 顺手把一条**恒真断言**改成真断言: 原来 `check('Authorization 头带上 key',
  SEEN[-1][0] and True)`（`SEEN[-1][0]` 是 path, 非空即真）永远 OK, 现在服务端把 `Authorization` 头记进 `SEEN`
  第三元, 断言它 **正好等于 `Bearer sk-fake`**。
- 结果: `22/22`（原来 3 FAIL + 1 crash）。

**② `tests\pure-state-harness.py` 的状态提示点那段会被"屏幕前的人"干扰**:
- 后台跑全量时**恰好红了 3 条**: `ime 模式 tick 后圆点已显示` / `状态变了(模式) -> 重新上色` / `松开之后 -> 自动回来`;
  前台单跑 4 次全绿。原因不是随机的: `_dot_tick`（第六十九轮）读的是**物理** `win.mouse_buttons_down()` 与
  **真实** `win.cursor_pos()` —— **按住左键时圆点本来就该隐藏**, 而当时正好有人在 Web GUI 里点鼠标。
  "光标没动就不摆窗"那条也是靠**真实光标恰好没动**才过的, 属于蒙对;
- **修**: 这一段把这两个真实输入**打桩**（存旧值、段尾还原; 按住/松开两种语义仍由显式打桩去测）, 并**补一条
  正向断言** `光标动了 -> 重新摆窗` —— 只测"没动就不动"是半个断言。
- **守卫有效性自检**（"一个不会失败的测试等于没写"）: 把 `_dot_tick` 的两处保护分别改坏跑一遍 ——
  去掉"光标没动才跳过" → **恰好 1 条红**（新断言 `光标动了 -> 重新摆窗`）; 去掉"按住鼠标键就隐藏" →
  **恰好 1 条红**（`按住鼠标键(拖动中) -> 隐藏`）; 还原后全绿。脚本留在 `%TEMP%\wg-mutate-dot.py`。
- 同一处 `voice-click-test.py` 的 `sys.path` 也改成从 `__file__` 推（原来同样写死机器路径）。

**文档**: `AGENTS.md` §4 新增一条硬规则（测试要**自足** + 读真实输入的断言必须**打桩**, 附本轮两条实证）,
harness 项数 33 → **51 项**（这条早就过期了）; 顺手压掉 §6/§8 两段重复的 `AGENTS-DETAIL` 指引与 §7 的历史回验
明细（文件从 **65624 → 65168 B**, 回到 64KB 注入预算内, 不再被截断）。细节见 `AGENTS-DETAIL.md` §D14 第 4 节。

**验证**: `pure-state-harness.py` 51/51、`stream-asr-test.py` 22/22、`voice-click-test.py` 7/7、
`voicepack-sync-test.py` 13/13、`dot-mouse-test.py` 24/24、`tray-swap-test.py` 42/42、`voice-vad-test.py` 31/31、
`whisper-warm-test.py` 67/67、`sherpa-warm-test.py` 74/74、`undefined-globals.py` 0、
`embedded-isolation-test.py` 10/10 —— 全绿（本轮没动任何产品代码, 只动测试与文档）。



## 2026-09-16 (第七十四轮: 语音"点击落点" —— 不猜目标窗口, 让用户点一下)

**来由（读参考实现得到的结论，见 §D14）**: 进程外工具**没法可靠知道**"用户想把文字放进哪个输入框"。
`xiuleitan/MouthWrite` 最后干脆把"自动粘贴到光标处"**撤掉**了 —— 改成"只进剪贴板 + 浮窗提示, 用户点
鼠标左键后才 Ctrl+V"(它的 `_finish_with_paste` 注释原话: "不再自动粘贴到输入框")。那条"免注册路线"里,
**"哪一下点击"本身就是最可靠的目标选择**。

**做法**（新配置键 `voice_click`, 默认 0, 只在 `voice_auto = 0` 时有效）:
1. 识别完**只把文本放进剪贴板**（`win.clipboard_set`），候选条提示「点目标输入框粘贴 / Esc 放弃」；
2. `win.click_watch_start()` 装一个**一次性 `WH_MOUSE_LL`**（第七十四轮新增原语）：只等**鼠标左键按下**，
   命中即**自动收钩**，并把回调 marshal 回 Tk 主线程；
3. **不吞这次点击**（`CallNextHookEx`）—— 这一下点击正是"聚焦目标输入框"的那一下；
4. 命中后等 **150ms**（让 mouseup/焦点切换先走完）再 `inject(text)`（走现有上屏链：剪贴板/keyfix/UIPI 全兼容）；
5. 取消路径全都要收钩：Esc / 新录一句 / 退出 / 切模式（**取色器那次"✕ 关窗没收钩, 之后鼠标左键被吞"
   的教训**）。

**顺带修掉两个"完全静默"的 Win32 坑**（都是先写探针才发现的）:
- `kernel32.GetModuleHandleW` 默认 restype 是 `c_int` → 64 位下 HMODULE(`0x7FF6…`) 被**截断成负数**,
  传给 `SetWindowsHookExW` 必然失败, 而且**返回 0 不报错** → 钩子根本没装上（探针 `wg-r74-hook-diag.py`
  实测: 截断装不上, NULL/真句柄都能装）;
- `CallNextHookEx` 没声明 argtypes → 第 4 个参数（LPARAM）按默认 `c_int` 转换 → 64 位大整数
  `OverflowError: int too long to convert` → 回调抛异常 → **用户那一下点击丢掉**（探针实测: 被点的窗口
  收不到 `<Button-1>`）。
  这两个坑在**取色器**（`tools.py` 的 `WH_MOUSE_LL`）里同样存在, 一并修了。

**验证**: `tests\pure-state-harness.py` 加 **10 项**（剪贴板落地 / 等待态 / 装钩 / 候选条提示 / 命中收钩 /
上屏一次且内容对 / 退出等待态 / 取消收钩 / `voice_click=0` 时完全不装钩）；
新 tracked 测试 `wgime-py-pure\tests\voice-click-test.py` **7/7**（真 `WH_MOUSE_LL`：装/重复装被拒/
真点一下回调被调/自动收钩/**那一下没被吞**（探针建了个 scratch 窗口接 `<Button-1>`）/stop 幂等；
安全做法: 先把光标挪到探针自己的窗口再点、结束还原光标）。

## 2026-09-16 (第七十五轮: 流式 ASR —— 边说边出字)

**来由**: 其它后端都是"整句识别完才出结果", 用户对着候选条只看到"识别中…"（云端坏网络时甚至是十几秒
的黑箱）。`MouthWrite` / `PhoneMic` 那种形态是**边说边出**, 观感差别很大。

**做法**（`voice_engine = stream`, 复用 `stt_url`/`stt_key`/`stt_model`）:
- POST 到 OpenAI 兼容的 `chat/completions`, `stream: true`, 音频按 `data:audio/wav;base64,` 塞进 messages:
  **两种 payload 按 URL 关键字自动选** —— 含 `dashscope`/`aliyuncs` → `input_audio` + `asr_options.enable_itn`
  （阿里云百炼 `qwen3-asr-flash`）；否则 `audio_url`（自建 vLLM / 其它兼容端点, Qwen3-ASR）；
- `voice._http_stream()` **照抄 `_http_post` 的网络语义**（代理顺序 / 连接层同路重试 / 服务端回过话不重发 /
  每条路重建 `Request` / 自动模式记住可用路径），只把"一次读完"换成"按行读 SSE";
- 每段 `choices[0].delta.content` 累积 → 经 `on_delta` 回主线程（`VOICE_Q.put(('partial', 文本))`）→ 候选条
  **实时显示**（`show_page` 在 busy 且 `_VOICE['partial']` 非空时显示实时文本）；定稿时清 `partial`;
- 健壮性: `data: [DONE]` 收尾、坏 JSON 行/心跳注释跳过（不丢整句）、**服务端忽略 stream 直接回整段 JSON
  也能兜住**、`<|zh|>` 这类标签剥掉（`clean_asr_text`）。

**验证**: 新 tracked 测试 `wgime-py-pure\tests\stream-asr-test.py` **22/22** —— **全打本地假 SSE 服务器,
不依赖外网、不需要 key**（本机外网时通时断, 真端点做断言不可复现, 同第五十九轮那条规矩）:
增量按序回调 + 越接越长 / 最终文本与标签处理 / 两种 payload 形状（`input_audio`+`asr_options` vs
`audio_url`）/ 非流式回包兜底 / HTTP 500 报错且**只发一次** / 坏行心跳跳过 / 黑洞端口给明确错误 /
`_dispatch('stream')` 真路由 / 没配 `stt_url` 与坏 wav 的明确错误 / `clean_asr_text` 单元断言。
`tests\pure-state-harness.py` 另加 **3 项**（增量进状态 / 候选条显示实时文本 / 定稿清 partial 并把文本
转成待确认）。

**没做的部分（要用户定）**: 没有真实服务商的 key, 所以**线上链路没跑过** —— 要用就把 `voice_engine = stream`
配上 `stt_url`（百炼 `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions` + `qwen3-asr-flash`,
或自建 vLLM 的 `/v1/chat/completions`）与 `stt_key`。本机默认仍是**常驻 sherpa**（离线、0.1~1.2s/句）。

## 2026-09-16 (第七十二轮: 补上 wrapper 的 `--serve` —— 常驻 sherpa 的"服务端"那一半)

**背景（同步远端时发现的集成缺口）**: 远端这一批把常驻 sherpa 做成了首选后端（客户端在仓库里:
`voice.py` 的 `_SherpaSrv` 会 `spawn('… wgime-stt.py --serve --itn= --threads=')`），
但 **wrapper 那一半在仓库外**（`C:\Tools\wgime-local-asr\wgime-stt.py`，第六十四轮的产物），
它当时只支持一次性模式 —— 也就是说本机一旦把 `voice_engine` 设成 `sherpa`，助手起不来。

**做法**: 给 wrapper 补 `--serve`（一次性模式一行没改，连退出码 3/4/5/6/7 都对旧版一致）:
- 启动即建识别器（载模型 1.3s），完成后 **stdout** 打 `{"ready": true, "boot_ms": …, "model": …}`；
- 之后每行 stdin `{"id": 7, "wav": "…"}` → 每行 stdout `{"id":7,"ok":true,"text":"…","ms":…,"segs":1}`
  或 `{"id":7,"ok":false,"error":"…"}`（**单句失败不退出**，继续服务）；
- `{"cmd":"exit"}` / stdin EOF 干净退出；**回包一律 `ensure_ascii=True`**（中文走 \uXXXX，不依赖对端编码）；
- 协议纯净: 服务模式 stdout **只**有 JSON 行，日志全走 stderr（对端按行 json.loads）。

**实测（本机，`test-zh.wav` 音频长 4.7s）**:
| 环节 | 实测 |
|---|---|
| 建识别器（载模型，只在启动付一次） | **1312 ~ 2375 ms** |
| 解码吞吐 | 约 **0.27 × 音频时长**（4.7s 音频 → 1060~1266 ms） |
| 走应用自己的 `voice.recognize()` 第一句 / 第二句 | **2.66s → 1.06s**（省下的是每句 ~1.3s 载模型） |
| 子进程 | 常驻一个（pid 不变），`shutdown()` 后干净退出 |

**顺手校正一处说法**: 文档里"常驻后每句 0.08~0.16s"只在**很短的口令**（约 0.3~0.5s 音频）成立；
它省掉的其实是**每句固定 ~1.3s 的载模型**，解码本身跟音频长度成正比（我们的录音是"按住说一句话"，
2~3 秒很常见 → 常驻后每句约 0.6~0.9s）。这样报数才不会让人以为"4 秒的话 0.1 秒就能出"。

**本机接法（已生效）**: `package\config.txt` 里
`voice_engine = sherpa` / `stt_script = C:\Tools\wgime-local-asr\wgime-stt.py` / `stt_itn = 1` /
`stt_threads = 4` / `voice_fallback =`（空 —— 主引擎已经是本地的，没必要每句再跑一次云端）；
`statedot = 0`（保持关，用户反馈过"影响到鼠标移动"）。云端那几行在新模板里本来就是注释状态，
所以 API key 现在**不在 config.txt 里**（要用 http 后端再解开注释填上）。
wrapper 同步到了便携包 `portable\wgime-stt.py`（同一份实现两处用）。

**验证**: wrapper 探针 `%TEMP%\wg-r72-wrapper-serve-probe.py` **21/21**（一次性协议纯净 / ready 字段 /
两句文本正确 / 坏路径不退出 / 第二次更快 / `exit` 与 EOF 都干净退出 / stdout 每行都是 JSON）；
应用路径探针 `%TEMP%\wg-r72-app-sherpa-probe.py` **14/14**（走真 `voice.recognize()`: 配置认得出、
助手是我们起的子进程且 ready、第二句明显更快、`shutdown()` 不留孤儿）。
**合并后的全链也全绿**: harness、`undefined-globals` 0、`embedded-isolation` 10、tray-swap 42、
voice-vad 31、whisper-warm 67、**sherpa-warm 74**、**dot-mouse 24**、`wgime-dist-sync-check` OK。

**注**: wrapper 与模型在仓库外（`C:\Tools\wgime-local-asr\`，按机器各装一份），协议对端在
`wgime-py-pure\voice.py` 的 `_SherpaSrv` —— 改任何一侧都要同时看另一侧（本次缺口就是这么来的）。

## 2026-09-16 (第六十九轮补充: 状态提示点默认关 —— 用户反馈"影响到鼠标移动")

用户："跟着鼠标跑的那个小圆点可以拿掉吗？好像影响到鼠标移动了。"

**先查清到底是什么在影响**（真窗口实测，探针 `%TEMP%\wg-dot-mouse-probe.py`）：

| 查什么 | 结果 |
|---|---|
| 外框扩展样式 | `0x080800A8` = `NOACTIVATE / LAYERED / TRANSPARENT / TOOLWINDOW / TOPMOST` **全都在** |
| `WindowFromPoint(圆点中心)` | 返回的是**底下的窗口** → 鼠标事件**确实穿透**，点击/悬停都没被它吃掉 |
| 落点 vs 算出来的位置 | 偏差 **0px**（没有 DPI 错位）；圆点矩形也**不含光标** |
| 每拍开销 | `Tk.geometry()` **1.95ms/次**；直接 `SetWindowPos` **0.68ms**（快 **2.9 倍**） |

→ 结论：**它不是"抢事件"，而是"每 32ms 挪一次置顶窗口"这份稳定开销** —— 一个 12px 的窗贴着光标
每秒挪 30 次、DWM 每次重新合成，在慢机器/远程桌面上就是"鼠标发涩"。用户的感觉是对的。

**改了三件事**（都为了"要么别开，开了也别碍事"）：
1. **默认关**（`engine.load_config` 缺省 `statedot=False`，`config.txt` 模板 `statedot = 0`）——
   用户要的就是拿掉。功能一行没删：托盘「选项 → 状态提示点」勾一下、或 config 里改成 1 就回来；
2. **挪窗改走 `win.move_topmost()`**（`SetWindowPos` + `NOSIZE|NOACTIVATE|NOSENDCHANGING|ASYNCWINDOWPOS`，
   目标 `HWND_TOPMOST` 顺带保住置顶）→ 每拍便宜约 3 倍，也少惊动别的窗口；
3. **按住鼠标键期间隐藏**（`win.mouse_buttons_down()`：拖动/框选/调窗口大小正是它最碍事的时候，松开
   下一拍自己回来），**光标没动且状态没变 → 一个 Win32 调用都不做**。

**顺手抓出两个真问题**：
- `dot.py` 的 docstring 里有 `\w`（写路径 `%TEMP%\wg-dot-...`）→ `SyntaxWarning`；改 raw docstring。
- **harness 的两条"默认值"断言其实在读用户那份 `package\config.txt`**：main.py 里
  `APP_DIR = dirname(DICT_DIR)`，而 harness 把 `WGIME_DICT_DIR` 指向 `package\dicts`，
  于是 `ns['CFG']` 来自一个**用户可编辑的活文件**（实测那份里 `followcaret`/`statedot` 都是 1）。
  这类断言会随用户配置变红/变绿 —— **测的不是代码默认值**。已改成用
  `engine.load_config(<不存在的路径>)` 取代码默认值来断言（并在 harness 里写明这个坑）。

**回归**：新增 `wgime-py-pure\tests\dot-mouse-test.py`（**24 项**）：

- A 组纯函数 10 项：颜色/录音优先/取模不越界、四边翻转、负坐标副屏、离谱坐标钳制，
  外加一条**遍历 5 种工作区 × 全部光标位置**的不变量 —— "**圆点永不盖住光标、永不越出工作区**"；
- B 组真窗口 14 项：样式**写在外框**上、`WindowFromPoint` 确认穿透、落点无 DPI 偏差、
  `move_topmost` 真的挪过去且样式没被重置、hide/再显示/颜色/destroy。**没有交互桌面则整组 SKIP**
  （退出码仍 0，免得在无桌面环境误报）。

harness 33 → **39 项**（新增：代码默认关、光标没动不重复摆窗、状态变了才重绘、按住鼠标键隐藏、
松开自动回来）。**本机配置**：`package\config.txt` 的 `statedot` 已改成 0（其余设置 —— 语音 sherpa、
跟随光标 1 —— 原样保留；构建用的是"先备份用户配置、构建后恢复再改这一行"）。

**全套**：harness 39/39、dot-mouse 24/24、undefined-globals 0、embedded-isolation 10/10、
tray-swap 42/42、voice-vad 31/31、whisper-warm 67/67、sherpa-warm 74/74；dist 重建（599843 B）。

---

## 2026-09-16 (第六十三轮补充: 常驻 sherpa —— 每句 1.5s 变 0.1s, 顺手把常驻机制抽成通用的)

用户："做"（上一轮结尾提的"还剩一块红利"：sherpa 的 1.5s/句里 1.31s 是每句重付的模型加载）。

**结果**：新增 `voice_engine = sherpa`（别名 `sensevoice` / `sense-voice` / `sherpa-onnx`），
**每句 0.08~0.15s**（首句 1.23s，那是在等助手把模型载完 `boot_ms=1003`）。

| 方式 | 每句 | 说明 |
|---|---|---|
| `cmd` 一次性（上一轮接的） | 1.48~1.57s | 每句新起进程, 重付 1.31s 载模型 |
| **`sherpa` 常驻（本轮）** | **0.08~0.15s** | 模型只载一次; 文本与一次性模式 **4/4 完全一致** |

**做法：把第六十三轮 whisper 那套常驻机制抽成通用的 `voice._WarmSrv`**，差异只剩三个钩子
（`key()` 决定"要不要重启"、`spawn()` 决定"怎么起"、`request_obj()` 决定"发什么"）：

- `_WhisperSrv`：源码走环境变量 + `-c` 引导（原样保留，类名不变 —— 现有 67 项回归直接复用）；
- `_SherpaSrv`：**直接起用户那份 wrapper 的 `--serve` 模式**。为什么不把 wrapper 的逻辑也塞进
  环境变量：wrapper 是"语音包"的一部分（和 228MB 模型一起搬），一份实现同时服务
  `cmd`(一次性) 与 `sherpa`(常驻)，复制进 `voice.py` 必然两处漂移。
- **`key` 的语义两边不同，这是本轮最容易写错的地方**：whisper 的 `lang/prompt/beam` 是**每次请求**带的
  （改了不用重启）；sherpa 的 `itn/lang/threads/script` 是**建识别器**的参数（改了必须重启，否则
  "配置改了却没生效"）。回归里 B 组专门钉这条。
- 共用机制（超时/限速/连续失败/串包/EOF/重启时的队列隔离）在 sherpa 这一侧**各自又钉了一遍** ——
  抽出来不等于少测一遍。

**wrapper 加了 `--serve`**（`wgime-stt.py`）：载一次模型 → 打印
`{"ready":true,"model":"sense-voice","boot_ms":1003,"itn":true,"lang":"zh"}` → 之后
`{"id":N,"wav":"..."}` → `{"id":N,"ok":true,"text":"...","ms":110,"audio_ms":4610}`；
`{"cmd":"exit"}` 或 **stdin 关闭（父进程退出）就自己结束**。顺带把一次性/常驻两条路共用的
`build()/decode()` 抽出来，并修掉 docstring 里的 `SyntaxWarning`（`\models\` → raw docstring）。
**契约要点**：serve 模式下 stdout **只有 JSON**（日志一律 stderr）。

**这一轮真踩到一个 bug（而且是被现有回归抓出来的）**：我一开始把"引擎名 → 助手实例"的映射
在**导入时**就固化成 dict，于是测试里 `voice._WSRV = voice._WhisperSrv()` 这种"换个干净实例做隔离"
就失效了 —— `warm()` 操作旧对象、`recognize()` 用新对象，两边状态对不上，whisper 回归 A11/A12 立刻红。
改成 `_warm_srv()` **调用时** `globals()[名字]` 取。顺手把两份回归的 A3 都加强为
"起了进程**而且就是当前这个实例上的**"，让这类"操作错对象"的缺陷有更直接的判据。

**回归**：新增 `wgime-py-pure\tests\sherpa-warm-test.py`（**74 项**，纯桩；与 whisper 那份同一套假
Popen 语义：没数据会阻塞、进程死了写 stdin 会抛、只有 kill 后才 EOF）。**守卫有效性自检**
（`%TEMP%\wg-sherpa-guard2.py`）把三处新守卫各改回旧写法跑一遍 —— itn 字符串 → `J3` 失败；
`_warm_srv` 导入时取全局 → `A3` 失败；去掉"没配 stt_script 要报错" → `C1/C2/C3` 失败；基线 0 失败。
顺手把测试里"起进程失败"的路径改成**优雅记 FAIL**（原来会崩在 `p.emit` / `p.written[i]` /
`old_q.queue` 上）—— **挂死或崩溃的测试比失败的测试难查得多**。
真进程端到端（`%TEMP%\wg-sherpa-warm-e2e.py`）：4 句 0.12~0.15s、坏 wav 只报错不弄死助手、
改 `stt_itn` 真的重启助手（pid 12812 → 12768、旧进程已退出）、`shutdown()` 后进程消失。

**配置**：`package\config.txt` 已切到 `voice_engine = sherpa` + `stt_script` + `stt_itn/stt_threads`
（解释器仍写绝对路径，同 §D8 的老坑）；whisper 那几行注释掉。根 `config.txt` 模板重写成
"**首选 sherpa（常驻，0.1s）/ 备选 cmd（一次性，1.5s，wrapper 不支持 --serve 时用）/ 再备选 whisper**"。

---

## 2026-09-16 (维护: 本机落地 sherpa 离线识别 —— 1.5s/句, 顺带把三种离线引擎实测对比)

**背景**：上一轮拉取后发现一件必须说清的事 —— 第六十四轮文档里的 `C:\Tools\wgime-local-asr\` +
`sherpa-onnx 1.13.8` + 228MB 模型是**跑那一轮那台机器**上的环境；**本机（Store Python 3.13 这台）
一样都没有**（目录不存在、`import sherpa_onnx` 为 False、`model.int8.onnx` 找不到，
`C:\Tools\wgime-asr-portable.zip` 也没有）。用户说"要"，于是本机从头装一遍。

**装了什么（都在仓库外，可整包搬走）**

| 项 | 值 |
|---|---|
| 运行时 | `pip install sherpa-onnx` → **1.13.8**（cp313 win_amd64 轮子 2.3 MB + core 16.9 MB，装在 Store Python 3.13 的用户 site-packages） |
| 模型 | `hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17` 的 `model.int8.onnx`（**239233841 B**，与文档一致）+ `tokens.txt`（315894 B）→ `C:\Tools\wgime-local-asr\models\sense-voice\` |
| wrapper | `C:\Tools\wgime-local-asr\wgime-stt.py`（按**自身位置**找模型；stdout 只打印文本，日志全走 stderr） |

下载本身很快（hf-mirror 实测 **13.4 MB/s**，17 秒下完 228MB；反倒是 pip 只有 123 kB/s）。

**wrapper 对齐了 §D8 那个接口**：`--itn=0|1` / `--lang=zh|auto` / `--threads=N`（两种写法
`--itn=0` 与 `--itn 0` 都认），也可用 `WGIME_STT_ITN` 等环境变量；**顺手修掉一个真缺陷**：
docstring 里的 `\models\` 触发 `SyntaxWarning: invalid escape sequence '\m'`（改成 raw docstring）。
坏输入一律"退出码非 0 + stderr 一行原因 + stdout 空"（`_cmd_recognize` 才不会把用法提示当识别结果）。

**耗时拆解**（4 句中文，系统 TTS `Microsoft Huihui Desktop` 合成 16k/单声道/16bit）：
空解释器 0.09s + **导入 sherpa_onnx 0.03s** + **建识别器(载模型) 1.31s** + 解码 0.20~0.24s
→ **每句 1.48~1.57s**。所以 1.5 秒几乎全是"每句重付的模型加载"，解码本身只要 0.2s。

**三种离线引擎同批音频实测**（字符级 LCS 覆盖，忽略标点；`%TEMP%\wg-asr-compare.py`）：

| 引擎 | 平均 | 最慢 | 平均覆盖 | 逐字全对 |
|---|---|---|---|---|
| **sherpa SenseVoice（`cmd`）** | **1.77s** | 1.86s | 95.0% | 1/4 |
| 常驻 faster-whisper（`whisper`） | 13.39s¹ | 46.48s¹ | 97.3% | 2/4 |
| 系统引擎（`system`） | 0.86s | 0.96s | **59.6%** | 0/4 |

¹ 这一列被"载模型那一次"拉高了，**重测过**（清掉磁盘缓存影响后的同一批音频）：
冷 **8.73s**（`boot_ms=1927`，说明载模型只要 1.9s，其余是 `import faster_whisper`）、
热 **2.34~2.42s**；那次 46.48s 是紧接在下载 228MB 之后（磁盘缓存被冲掉）+ 当轮第一次调用。

系统引擎 0.86s 但只有 59.6%（"这个输入法是我自己写的"→"这代收收发室我自己现在这些"），
与第六十二轮的结论一致：**它是老 SAPI5 引擎，不适合中文**。

**ITN 的 A/B**（同一批音频，`%TEMP%\wg-sherpa-itn-ab.py`）——**开不开差 4 个百分点，值得让用户知道**：

| 选项 | 覆盖 | 逐字全对 | 表现 |
|---|---|---|---|
| `--itn=1`（缺省） | 95.0% | 1/4 | 补标点（`，` `。`），但把 `三点`→`3点`、`三十七`→`37` |
| **`--itn=0`** | **99.2%** | **3/4** | **没有标点**，汉字原样保留 |
| `--lang=auto` | 96.0% | 1/4 | 更差（`三十七`→`第三7`）|

结论：**`--itn=1` 的"错"大半是它有意做的数字规范化，不是识别错**；真正两版都错的是
`五笔`→`无笔`/`舞笔`（TTS 读音歧义）。所以缺省保持 `--itn=1`（有标点更好用），
要"汉字最准、标点自己打"就把 config 里加 `--itn=0`。

**接法**（`package\config.txt`，未入库；`build-package.ps1` 会覆盖，重建后要重填）：
`voice = 1` / `voice_engine = cmd` /
`stt_cmd = "<装了 sherpa 的 python.exe 绝对路径>" "C:\Tools\wgime-local-asr\wgime-stt.py" --itn=1 {wav}`
（解释器写绝对路径 —— §D8 的老坑：`_cmd_recognize` 是 shell 跑一条命令行，没有便携相对路径可用）。
同时把 whisper 那几行（`stt_model/stt_lang/stt_prompt/stt_device/stt_compute/stt_prewarm`）**注释掉**，
避免"哪个键在生效"说不清。回验：`engine.load_config` + `voice.recognize` 走真实配置链路，
4 句 **1.48~1.57s** 全部无错。

**whisper 那次 46.48s 的冷启动值得记一笔**：重测（`%TEMP%\wg-whisper-cold-retest.py`）是
**冷 8.73s / 热 2.34~2.42s**，`boot_ms=1927` —— 也就是载模型只要 1.9s，冷启动那几秒几乎全是
`import faster_whisper`；46s 那次是紧接在下载 228MB 之后（磁盘缓存被冲掉）。**但真正的分水岭是**：
sherpa 每句固定 1.5s（其中 1.31s 是载模型，每句重付），whisper 要付一次十几秒的导入+载模型
才能到 2.3s，且常驻占几百 MB 内存。日常用 sherpa 更省心。

---

## 2026-09-16 (维护: 拉取第六十四~七十一轮 + 修 AGENTS.md 超预算被截断)

**拉取**：本地第六十三轮（`6b2cde7`）之后远端又推进了 13 个提交（第六十四~七十一轮），
本地是干净的 fast-forward，已 `git pull --ff-only` 到 `869cbca`。拉进来的东西里有三条与语音直接相关：
第六十四轮（`cmd` + sherpa-onnx/SenseVoice 本地离线识别）、第六十五轮（硅基流动**国内站** +
`stt_retry`/`stt_timeout`/记住可用路径）、第六十六轮（`voice_fallback` 双引擎赛跑，谁先成功用谁）。
**第六十三轮的常驻 whisper 后端完好**（`WSRV_ENGINES` 分派、预热、两个锁都在），
`whisper-warm-test.py` **67/67** 在合并后的代码上仍然全绿 —— 两轮工作没有互相破坏。

**修的真问题：`AGENTS.md` 超出 64KB 注入预算，被**静默截断**。**
拉下来时它是 **69134 B**（超 3598 B），harness 把它截到 65244 B —— 后果是每个会话读到的
`AGENTS.md` 都**缺了 §7 的尾部与整个 §8**（发布流程后两步、当前状态速览），而这两节正是"接手时要看的"。
这不是远端某一轮的错，是长期"只往里加、不往外挪"的累积。

- **修法**（按文件自己的契约：正文只留规则、细节进 `AGENTS-DETAIL.md`）：
  1. §38 里**第五十八~六十二轮的叙事原文**（VAD 三轮排查、代理坑、系统引擎分段）整体搬到
     **`AGENTS-DETAIL.md` §D12**，正文压成 6 条"要照做的规则" + 探针/测试名；
  2. 第六十四~六十六轮的实测数字压成规则（数字指向 CHANGELOG 与 §D7.1/§D8）；
  3. 顺手修一处文档与实际不符：`embedded-isolation-test.py` 写的是 9 项，**实际 10 项**（实测输出 `全部通过 (10 项)`）。
- **结果**：`AGENTS.md` 69134 → **63205 B**（余量 2331 B），`AGENTS-DETAIL.md` 85269 B（不受注入预算限制）。

**本机复核**（拉下来的代码，逐项真跑）：
`pure-state-harness` 33/33、`undefined-globals` 0、`embedded-isolation-test` 10/10、`tray-swap` 42/42、
`voice-vad` 31/31、`whisper-warm` 67/67；`dist` 与磁盘**逐字节一致**（11 个内嵌模块 + `main.py` 全部 match）。

**一处必须说清的事实**：第六十四轮文档里的 `C:\Tools\wgime-local-asr\wgime-stt.py` +
`sherpa-onnx 1.13.8` 是**跑那一轮的那台机器**上的环境；**本机现在没有它**
（目录不存在、`import sherpa_onnx` 为 False、也找不到 `model.int8.onnx`）。
所以本机可用的离线路径仍是第六十三轮的 `voice_engine = whisper`（实测冷 20s / 热 3.8~5.3s）。
`wgime-py-pure\package\config.txt` 已按本机实际改好（`voice=1` + `voice_engine=whisper` + 那几个键），
sherpa 那两行以注释形式留在旁边，装上 `sherpa-onnx` + 那份 228MB int8 模型后去掉注释即可（实测 ~1.7s/句）。

**顺带重建**：`package\` 已重建（单文件 **573.0 KB** —— 第七十一轮删掉 comtypes/uiautomation 的成果，
我这轮构建时是 586705 B，与远端发布的一致）；`dist` 的第三方 zip 保持 HEAD 基线不动（构建噪声已回退）。

---

## 2026-09-16 (第七十一轮: 纯 Python 依赖全部内嵌 + 删掉死重 comtypes/uiautomation)

**目标（用户定）**: 依赖能封进单文件的就都封进去; `comtypes`/`uiautomation` 已经没人用了, 删掉。

**结论先说清"能封到哪一步"**:
- **纯 Python 的依赖 100% 内嵌**(含**传递依赖**): 现在只剩 `pystray` 与它的硬依赖 `six`（14 个模块, 36.8 KB）;
- **C 扩展依赖内嵌不了** —— `.pyd` 与解释器 **ABI 绑定**。构建机是 cp312, 用户那台是
  `C:\Program Files\Python314`, 二进制塞进 zipimport 也加载不了。这类依赖一律走
  **"可用则用、不可用则明确降级"**: `Pillow`(托盘图标已构建期渲染成 ICO, 运行时根本不需要它)、
  `psutil`(回退 wmic)、`cryptography`(chat 插件加密, 缺了给提示)、`faster-whisper`/`argostranslate`
  (语音/翻译的可选后端, 由用户自己装)。

**改动**:
1. **删掉 comtypes + uiautomation**: 第四十四轮起光标跟随 helper 已是 `win.py` 里纯 ctypes 的源码字符串,
   全项目 0 处 import —— 单文件 **898.8 KB → 573.0 KB（-36%）**, 内嵌第三方模块 **85 → 14 个**
   （`thirdparty.zip` 281.2 KB → 36.8 KB）; 换机器构建时 pip 清单也能只剩 `pystray` + `pillow`。
2. **依赖收集改成传递闭包**（BFS）: 不再只收一层 —— 第六十九轮那个 bug 恰好只有一层（pystray→six）,
   多一层就会再漏; 并新增 `_THIRD_SKIP` **显式跳过表（每条写原因）**, 构建日志同时打印
   `third-party roots:` / `third-party to embed:` / 每个 `skip third-party <名字> <原因>` ——
   "哪些没内嵌、为什么"一眼可见, 不会再有"以为漏了"或"以为嵌了"。
3. **`plugins/chat.py` 的 cryptography 缺了不再静默崩**: 原来是"用到时才 import", 缺包会在 Tk 回调里抛
   ImportError（pythonw 下**完全无声**, 用户看到的就是"回车没反应、输入框还留着字"）。现在模块级探测
   `HAS_CRYPTO`, `Crypto.enc` 返回 `None`, 调用处提示
   `加密不可用 (需 cryptography): pip install cryptography —— 未发送` 并**保留输入内容**;
   **绝不退回明文发送**（房间里设了密钥却发明文是安全问题）。`dec` 返回 None 时走已有的 `[encrypted]` 兜底。
4. 构建期自检跟着收紧: `third-party isolation check: THIRD-ISOLATION-OK pystray,six`。

**验证**:
- `embedded-isolation-test.py` **10/10**（新增: 内嵌清单**正好** `{pystray, six}`、
  `comtypes/uiautomation` 已不在、`PIL` 不在; 老的"真 bug 形状" `pystray + six.moves.queue` 保留）;
- 新探针 `%TEMP%\wg-r71-optdep-probe.py`（干净环境 `-S -E`）: `PIL` 缺失 → `tray.HAS_PIL=False`
  但 `HAS_TRAY=True`; `cryptography` 缺失 → `HAS_CRYPTO=False` 且 `enc/dec` 返回 None;
  `psutil` 缺失 → `_list_procs_by_name` 返回 `[]` 不抛; `voice` 的 whisper 提示写清要装什么;
  `win/dot/engine/hook` 在无 comtypes/uiautomation 的干净环境照样 import —— **6 项全符合预期**;
- **干净环境实机**（`python -S -E` 跑真 dist）**5/5**: 托盘消息窗口出现、`tray start ok=True`、
  `tray selfcheck: nim_add=True(count=1)`、状态提示点也在;
- **`followcaret` A/B（删掉 uiautomation 之后）**: `0` → 四个采样点都是 0 个 helper 子进程;
  `1` → 稳定 1 个, 日志 `IPC helper started pid=… (167-char cmdline)` → **175ms 后 ready** ——
  纯 ctypes helper 与 comtypes/uiautomation 无关, 删得掉;
- 其余全绿: `undefined-globals` 0、harness 33、tray-swap 42、voice-vad 31、whisper-warm 67、dot 探针 70、
  `wgime-dist-sync-check` OK（dist 573.0 KB, package 56.9 MB）。

## 2026-09-16 (第七十轮: 修「托盘图标没能创建 (No module named 'six')」 —— 内嵌漏了依赖)

**用户机截图**（Python 3.14 + `pythonw.exe`，干净环境）:

```
托盘图标没能创建。      NIM_ADD: None
原因: File "site\thirdparty.zip\pystray\__init__.py", line 64, in <module>
        icon = backend().Icon
      ... ImportError: this platform is not supported: No module named 'six'
```

**这是个 shipped bug，而且我们本机永远复现不了**: `pystray/_base.py:24` 与 `_win32.py:22` 都有
`from six.moves import queue`（它的 METADATA 也写着 `Requires-Dist: six`），而
`collect_thirdparty(['comtypes','uiautomation','pystray'])` **只嵌了 pystray 自己，没嵌 six**
（内嵌 zip 里 `six` 条目 = 0）。单文件运行时的第三方 import 会**回退到宿主 site-packages**，于是
"构建机恰好装了 six"就把这个缺口盖住了 —— 干净机器上 `import pystray` 直接 ImportError，
**整个托盘菜单消失**（工具箱/插件管理/所有托盘开关都进不去），主程序本身还在跑。
和第四十二轮那个 Pillow 的坑是**同一类**（"宿主恰好装了 X，于是内嵌缺口测不出来"）。

**复现（关键）**: `python -S -E`（不加载 site-packages）跑一遍即现形:
```
python -S -E -c "import sys; sys.path.insert(0, r'%LOCALAPPDATA%\wgime-py\site\thirdparty.zip'); import pystray"
-> ImportError: this platform is not supported: No module named 'six'
```
修前/修后都用它当判据（修前 3/8 项失败，修后 9/9）。

**修法（不只补 six，而是堵住这一类）**:
1. `collect_thirdparty` 现在**自动把声明依赖一起收进来**（读 `importlib.metadata` 的
   `Requires-Dist`，只收**无条件**项；带 marker 的平台/extra 依赖不收），并打印
   `third-party to embed: comtypes, uiautomation, pystray, six`；`Pillow` 在**排除表**里
   （C 扩展 `_imaging.pyd` ABI 绑定，图标已在构建期渲染成 ICO 内嵌）；
2. 顶层条目按 `ispkg` 区分 —— `six` 是**单模块**（`six.py`），以前那行代码一律写
   `name/__init__.py`（对模块是"能 import 但形态错"）；
3. **构建期干净环境自检** `verify_thirdparty_isolation()`: 把刚打好的 zip 写到临时文件，用
   `python -S -E` + 只挂这个 zip 的 `sys.path` 把每个顶层名字 import 一遍，失败就
   `sys.exit(1)` **中止构建**（绝不产出坏单文件）。构建日志现在有
   `third-party isolation check: THIRD-ISOLATION-OK comtypes,pystray,six,uiautomation`；
4. **永久回归** `wgime-py-pure\tests\embedded-isolation-test.py`（9 项）: 从 dist 里解出
   `THIRD_ZIP_B64`，用同样的 `-S -E` 干净解释器逐个 import，并专门断言"真 bug 的形状"
   （`import pystray` + `from six.moves import queue`）。**它在修复前的 dist 上如实报 3 项失败**。
5. 顺带修构建脚本自身的坑: 被 `powershell -File` 调用时 stdout 是 **cp1252**，我新加的中文提示
   直接把构建 `UnicodeEncodeError` 打死（而且 `build-package.ps1` 会**沿用旧产物**还报 build=0）——
   现在构建脚本开头把 stdout/stderr 切成 `utf-8+replace`。

**验证**:
- 构建期自检 `THIRD-ISOLATION-OK`（内嵌 85 个第三方模块，zip 289.5 KB，dist 909.9 KB）；
- `embedded-isolation-test.py` **9/9**（修复前 3 项失败）；
- **干净环境实机** `%TEMP%\wg-r70-clean-live.py` **5/5**: 用 `python -S -E` 跑真 `dist\wgime-py.py`，
  托盘消息窗口（`WgIme-Pure<pid>SystemTrayIcon`）与状态提示点都出现，日志
  `tray start ok=True` / `tray selfcheck: nim_add=True(count=1)`，且没有 `six`/ImportError；
- 其余全绿: `undefined-globals` 0、harness 33、tray-swap 42、dot 探针 70、`wgime-dist-sync-check` OK。

**已发布版本都受影响**（v1.2.x 的内嵌方式相同）—— 干净环境（没装 six）的用户会没有托盘菜单。
**临时绕过（给用户的）**: 用启动它的那个解释器装一次 six 即可，例如
`"C:\Program Files\Python314\python.exe" -m pip install --user six`；或换本轮之后重新构建的分发文件。
另注: 第六十九轮新加的状态提示点**不依赖托盘**（`dot.py` 自带窗口），所以即便托盘挂了，
"输入法是开还是关"仍然看得见。

## 2026-09-16 (第六十九轮: 鼠标旁的状态提示点 —— 一眼看出输入法是开还是关)

**来由**: `hideidle = 1`(默认) 时空闲不显示候选条, 用户**看不出输入法是开还是关** ——
第五十七轮那次真实抱怨("托盘图标都不会变了 / 混合的模式切换不过去") 就是这么来的: 空闲隐藏下
候选条不显示, 而托盘图标还可能被 Windows 收进 `^`(见 §36 的 `tray_promoted`), 于是"切模式"
**没有任何可见反馈**。托盘菜单里我们能给的所有开关都齐了, 缺的是"状态本身"的显示。

**做法**(形态取自 [harold-lu-bit/IMEDot](https://github.com/harold-lu-bit/IMEDot), Ubuntu/PyQt6 的
"置顶小圆点"): 新模块 `dot.py` = 一个 **12px 的置顶圆点**, 跟在鼠标右上方, 颜色 = 当前状态:

| 颜色 | 含义 | | 颜色 | 含义 |
|---|---|---|---|---|
| `#6B6B6B` 灰 | 输入法**未激活** | | `#40C8E0` 青 | 词典模式 |
| `#FF9F0A` 橙 | 混合模式 | | `#30D158` 绿 | 语音模式 |
| `#0A84FF` 蓝 | 拼音模式 | | `#FF3B30` 红 | **正在录音**(优先于模式色) |
| `#BF5AF2` 紫 | 五笔模式 | | | |

- **未激活时显灰点**(而不是隐藏): 用户要的就是"看得出开没开" —— 有灰点才能区分"关着" vs
  "程序没跑 / 提示点被关了";
- **不抢焦点 / 鼠标穿透 / 不进任务栏**: `win.set_overlay_styles()` 新加的 Win32 原语
  (`WS_EX_NOACTIVATE` + `WS_EX_LAYERED|WS_EX_TRANSPARENT` + `WS_EX_TOOLWINDOW`)。只有
  `overrideredirect`+`-topmost` 是不够的: 不设 NOACTIVATE 会把输入框的焦点夺走, 不设穿透会挡住
  光标附近的点击(12px 也一样挡);
- **跟鼠标、不跟文本光标**: 候选条的"跟随光标"仍按用户决定**冻结在默认 0**(§17/§D10)。状态点跟鼠标
  不冲突 —— 它不承载内容, 只是状态灯, 没有"离正文太远"的问题。参考实现 IMEDot 跟的其实也是鼠标
  (Linux 上没有统一可查的 caret API), 这条"免注册路线"在桌面上真正能落地的形态就是"跟鼠标"。
- 位置由 `main.poll` 每 4 拍驱动 (~32ms 一次), 一次 tick 只有一次 `GetCursorPos`; 颜色/位置没变时
  不碰窗口; `dot_pos()` 会贴边翻转 + 钳进**光标所在显示器**的工作区(多屏正确); tray 模式不建窗口
  (没有"输入法开关状态"可言)；配置 `statedot = 0` 时**一个窗口都不建**。

**接线**: 新配置键 `statedot`(白名单, 默认**开**) + 托盘「选项 → 状态提示点」开关(勾选态读
`get_statedot`, 切换立即生效并落盘) + `dist` 内嵌模块 10 → **11 个**(`MODULES` 加 `dot`)。

**验证**: `%TEMP%\wg-r69-dot-probe.py` **67/67** ——
A 颜色映射(含录音优先/模式取模); B 位置数学 10 例(四边翻转 + 多屏 + 极小工作区);
C **真 Tk 窗口**: 读回 Win32 扩展样式断言 `NOACTIVATE|TRANSPARENT|LAYERED|TOOLWINDOW` 都在、
显隐/移动/上色/销毁(`IsWindow` 归零)全对; D `load_config` 的 6 组取值;
E 接线(AST 抽 `_statedot_on`/`toggle_statedot` 真跑: 开→关→开 + 落盘 + 立即 tick; api/菜单项/poll tick);
F 文件卫生(dot 进 MODULES、三份 config.txt、全部 LF)。
`tests\pure-state-harness.py` 加 5 项永久回归(28 → **33 项**, 含"真 tick 能把圆点显示出来");
`undefined-globals` 0、tray-swap 42、voice-vad 31、whisper-warm 67、`wgime-dist-sync-check` OK。

**实机复核抓出一个真 bug(只有跑真成品才会暴露)**: 源码探针 70/70 全绿, 但拿真 `dist\wgime-py.py`
启动、用 `EnumWindows` dump 该进程的窗口时发现: 圆点窗口确实出现、位置**逐像素等于** `dot_pos()` 期望值,
可它的扩展样式只有 `0x80088`(Tk 自己设的 `LAYERED|TOOLWINDOW|TOPMOST`), 我写的
`NOACTIVATE|TRANSPARENT` **不见了**, 圆心也不是灰的(采样是白)。
**根因: Tk 的 Toplevel 有"两层" HWND** —— `winfo_id()` 返回的是 **`TkChild`**(Tk 的画布子窗口),
真正的顶层外框是它的父窗口(`TkTopLevel` = `GetParent` = `GetAncestor(GA_ROOT)`); **窗口管理器只看外框**。
`SetWindowLong` 写到 `TkChild` 上, `GetWindowLong` 读得回来(所以源码探针假通过), 但
"不抢焦点/鼠标穿透/透明"**全都等于没设** —— 用户看到的是"圆点跟着鼠标跑, 但它会抢焦点、挡住点击、渲染成一块白"。
**修法**: 新增 `win.top_level_hwnd(hwnd)`(GA_ROOT + 回退), `Dot.hwnd()` 改为返回外框,
`_apply_styles` 加**外框守卫**(外框还没建出来时**不写**、也不置 `_styles_done`, 免得把样式写到子窗口上还宣布完成;
`deiconify()` 之后补一次 `update_idletasks()` 让外框当场就位, 否则用户会看见白块闪一下)。
**bar.py 的两处 `win.set_topmost(self.top.winfo_id())` 同一个 bug** —— 也改成写外框(那两处原来等于没生效,
候选条其实一直是靠 Tk 的 `-topmost` 在扛)。
探针跟着修: 源码探针新增 3 条(**`hwnd()` 是 `TkTopLevel`** / **`hwnd() != winfo_id()`** /
**`TkChild` 上确实没有 `NOACTIVATE`**), 实机探针去掉 `GetPixel` 取色(分层窗口读到的是它自己的像素,
微探针里 `#6B6B6B` 的圆点读回来是 `#000000`/`#FFFFFF`, 判不了颜色 —— 颜色改由源码探针读 canvas 的 item fill)。

**顺手记下一条环境事实(踩了一次)**: `WS_EX_TOPMOST`(0x8) 在本机**读不回来** —— 微探针
`%TEMP%\wg-r69-topmost-micro.py` 实测: 显式 `SetWindowPos(hwnd, HWND_TOPMOST, …)` 之后
`GetWindowLongPtrW(hwnd, GWL_EXSTYLE)` 依然没有 0x8(Tk 层 `attributes('-topmost')` 才是 1)。
所以 `set_overlay_styles` **不再 OR 这个位**(设了也没用), 置顶一律走 `win.set_topmost()`
(= `SetWindowPos`, 与 bar.py 同款); 探针也不再拿它当"置顶证据"。
这条已写成**可执行断言**(哪天 Windows 改了会失败, 提醒更新文档)。

## 2026-09-15 (第六十八轮: 光标跟随默认 0 并**冻结功能** —— 代码全留, 随时能开回)

用户: "我做个决定, 把光标跟随的功能去掉了，但是屏幕边缘粘贴的保留。…改成默认0吧，先改成这个并冻结功能，代码不删。"

**决定**: 候选窗**默认固定贴屏幕边缘**(可鼠标拖动、位置自动记忆), 不再跟随文本光标; 但跟随的
**整条实现一行不删** —— 独立 Caret Helper 子进程(UIA 定位 + JSONL IPC)、`bar.show(follow=…)` 的定位链、
托盘「候选窗跟随光标」开关、`followcaret` 配置键全部保留: `followcaret = 1`(或托盘勾一下)立刻恢复
第三十八～四十四轮那套跟随行为。**冻结 = 默认关, 不是删除。**

**改了什么**（只有"默认值 / 开关读取点", 没有删功能）:
- `engine.py` 缺省 `followcaret=False`（白名单语义不变: `1/on/true`=开、其它=关, 与 C# `LoadConfig` 一致）;
- `main.py` 新增 `_caret_follow()` 作为**唯一**开关读取点 —— 以前有的地方默认 True、有的地方默认 False,
  这种自相矛盾正是将来出 bug 的种子; 默认 False;
- **默认不再起那个常驻 helper 子进程**: 两个 spawn 调用点都门控（启动早期那条 helper 线程读 `_EARLY_CFG`,
  启动收尾那条读 `_caret_follow()`）—— 省一个常驻 python 子进程 + 一份 UIA;
- `show_page()` / `get_followcaret()` / `toggle_followcaret()` 全部走 `_caret_follow()`;
- `config.txt`（根模板 / release 模板 / 运行时 `package\config.txt`）: `followcaret = 0` + 注释改为
  "默认 0 并冻结(想用改 1 或点托盘)";
- 文档跟着改: `WGIME_使用说明.md`（"默认就是固定的"）、`WGIME_技术文档.md`（C# 代码缺省仍是开、
  Python 版缺省关; 两者出厂 config.txt 都是 0）。

**验证**: `%TEMP%\wg-r68-followcaret-probe.py` **29/29** ——
A `engine.load_config` 缺省/`1`/`on`/`true`/`0`/`off`/非法值共 7 组;
B `_caret_follow()` 三分支; C **AST 判定** `ensure_caret_bg` 的 2 处引用都在 followcaret 门控里;
D 把这两条门控语句**从源码节点编译出来真跑一遍**（关着 0 次调用 / 开着 1 次, 不是看字面）;
E `toggle_followcaret()` 仍能 0→1→0 并落盘; F 三份 config.txt 都是 `followcaret = 0` 且行尾未被翻成 CRLF。
永久回归: `tests\pure-state-harness.py` 加 5 项（23 → **28 项**, 含"托盘开关能开回来并落盘"）。
其余全绿: `undefined-globals` 0、tray-swap 42、voice-vad 31、whisper-warm 67、`wgime-dist-sync-check` OK
（dist/package 已重建, 内嵌 main.py 与磁盘逐字节一致）。
**实机 A/B（跑的是真成品单文件 `dist\wgime-py.py`, 不是源码目录）**: 同一份 dist, 只改 config 的
`followcaret`, 数"测试实例自己的 python 子进程"(按 ParentProcessId 归属, 只看自己那棵树):
- `followcaret = 0`（默认）: **1.5 / 3 / 6 / 10s 四个采样点全是 0 个**, 日志里 0 行 caret/helper 记录 ——
  那个常驻 helper 子进程确实没起来;
- `followcaret = 1`（开回来）: 1.5s 起就稳定有 **1 个** 子进程, 日志 `IPC helper started pid=… (167-char cmdline)`
  → 65ms 后 `IPC recv {'type':'ready','mode':'stable-focus-cooldown'}` —— 代码一行没删, 开关一翻就恢复。
**装置本身踩了两个坑（下次做实机验证别再踩）**: ① 一开始用 `mode = tray` —— 而早期 helper 那段**本来就被
`if mode != 'tray'` 包着**（main.py:210）, 于是两组都"没 helper", 分不出区别; ② 用 `WGIME_DICT_DIR` 指仓库词库
—— 而 `APP_DIR = dirname(DICT_DIR)`, 于是程序**读的是 `package\config.txt`**（本轮刚改成 0）, 我写进临时目录的
config 根本没被读。正确装置: 临时目录里给 `dicts` 建目录联接（`mklink /J`）、**不设** `WGIME_DICT_DIR` ⇒
`DICT_DIR=<临时>\dicts` ⇒ `APP_DIR=<临时>` ⇒ 读的是自己写的 config; 再配 `mode = ime` + `starton = 0`
（钩子装了但不激活 ⇒ 按键全部透传, 不抢用户键盘）+ `hotkey_* = none`（测试实例无法被激活）+
`LOCALAPPDATA` 指到临时目录（不碰用户数据）。另外 `win._dlog` 的开关是 **`WGIME_DEBUG=1`**（不是 `WGIME_DEBUG_CARET`）。


## 2026-09-15 (第六十七轮: 修"联想时打标点显示一个 X" —— keyfix 的牺牲字符改成不可见)

用户: "我有时候输入完成在有联想的情况下输入标点符号会显示 X"

**真因: X 是我们自己塞进去的"牺牲字符"。** `keyfix`（标点吞字修复）为绕开 Qt 类应用
（微信 4.x）"全角标点后把**下一个注入字符**错认成该标点"的毛病，会在标点后插一个字符让它吸收、
再发一个退格擦掉 —— 而这个牺牲字符原来是**可见的 `X`**（`win.send_unicode_qtfix` 里 `ord('X')`）。
退格那一下一旦没生效（应用正忙 / 把退格也当成要吸收的字符 —— 刚上屏完、联想正显示时最容易踩到），
`X` 就留在文档里。**"有联想时"只是"刚上屏、应用正忙"这个时序的表象，不是联想本身的错。**

**修法**：牺牲字符改成 **`U+200B` 零宽空格**（`win.QT_FIX_SENTINEL`）：
- 退格生效 → 和以前一样干净；
- 退格没生效 → 留下的是**看不见**的字符，用户不会再看到 X。
汉字/ASCII/emoji(代理对) 的判定完全不变（与 C# 一致：代理对不算 trigger）。
C# 版仍是 `'X'` —— 记进 AGENTS §27 的"python 有意分歧"清单（**要动 C# 得按 §3 走整条链**）。

**附带诊断**：这条修复路径**依赖目标应用的行为**，所以加了一次性 always-on 日志
（`keyfix: 标点吞字修复在 <程序名> 上启用 …`，每个前台程序只记一次，`win.qtfix_note_app()`）——
万一某个程序里还是出现多余字符/吞字，一眼就知道是它，可以用托盘
「这个程序 → 标点吞字修复」单独关掉（或写 `pastemode.txt`）。

**验证**：`%TEMP%\wg-r67-qtfix-probe.py` **16/16** ——
A 拦截 `SendInput` 检查真实事件序列：`[，down/up][U+200B down/up][VK 0x08 down/up]`，
**序列里没有 `0x58`（'X'）**；B 汉字/ASCII/emoji 不插哨兵；C `send_key_backspace` 不变；
D 只有真插过哨兵才记日志；E 用真 `main.py` 前缀构造"上屏完成 + 联想显示"再按句号 ——
**只注入一次、注入的是标点本身、走 qtfix 路径、联想被清掉**。
其余全绿：harness 23、`undefined-globals` 0、voice-vad 31、whisper-warm、tray-swap 42、
r59 30/30、r58 18/18、r52 24/24、r53 30/30、r57 28/28+21/21；dist/package 重建同步（**903191 B**）。

---

---

## 2026-09-15 (第六十六轮: 双引擎赛跑 —— 云端 + 本地 SenseVoice 同时开跑, 谁先成功用谁)

用户: "加上吧。"（上一轮末尾我提的"http 失败就自动回退本地"）

**为什么不是"失败再回退"**：`voice_fallback` 第一版做的是"主引擎报错 -> 改用第二引擎"，
串行。本机实测：云端要**十几秒**才报错（连接超时 × 重试），于是每句变成 **24~38s** 才轮到本地
（4/4 都对，但慢得没法用）。

**改成赛跑**（`voice._race_engines`）：两个引擎**同时开跑**，**谁先成功用谁**，另一个的结果直接丢弃
（daemon 线程，不阻塞退出）；两个都失败才报错，且错误里带两边原因。
实测同一份配置（云端网络照样烂）：**4/4 全对，平均 2.80s** —— 三次是本地 SenseVoice 在 ~3.5s 赢、
一次是**云端 0.73s 赢**（网络恰好通）。也就是说：云端好就走云端（0.6s），云端坏就有本地兜着（~3.5s），
用户无感、也不会再出现"整句识别不出来"。

**配置**：`voice_fallback = cmd`（第二个引擎名；留空=只用一个，默认）。
`http` 主引擎配了它时，`stt_retry`/`stt_timeout` 会被**收紧成 2 次 × 10s** —— 反正有本地兜底，
没必要让后台那个云端线程占几十秒。命中第二个引擎写一行 always-on：
`voice: 赛跑 http vs cmd -> cmd 先成功 (text=14 字)`；不弹气泡、不改文本。
**代价**：每句都会跑一次本地引擎（桌面机上可接受；不想白跑就别配 `voice_fallback`）。

**验证**：`%TEMP%\wg-r59-stt-proxy-probe.py` **30/30**，H 段 6 项全是赛跑语义：
两个都成功->谁先返回用谁 / 主引擎失败->第二个顶上来且最多试 2 次 / 两个都失败->错误里两边原因都在 /
`voice_fallback` 与主引擎同名->忽略(防自环) / 空文本(没听清)算成功不傻等。
`voice_fallback` 解析: `cmd`/`CMD  `/空 三组; 其余全绿（voice-vad 31、whisper-warm、tray-swap 42、
harness 23、undefined-globals 0、r58 18/18、r52 24/24、r53 30/30、r57 28/28+21/21）；
dist/package 重建同步（**901318 B**）。

---

---

## 2026-09-15 (第六十五轮: 接上硅基流动国内站 + 给 http 后端加坏网络三件套)

用户: "先给我用 siliconflow 的吧" + 一把新 key。

**先判站点 (两站 key 不通用, 见第六十轮)**: 同一把 key, pi.siliconflow.com -> **401
Token is invalid**; pi.siliconflow.cn 的 GET /v1/models -> **200**(列出模型) —— 所以这是
**国内站**的 key, stt_url 必须用 .cn。(用户之前那把国际站的 key 在 .cn 回 30014, 这次反过来。)

**新发现: 这台机器到 pi.siliconflow.cn 的连接层极不稳定** (与 key 无关):
GET /v1/models 十次只有 **3 次**成功, 6 次 SSLV3_ALERT_BAD_RECORD_MAC、1 次 RemoteDisconnected;
语音请求一段时间 3/5 成功 (**成功时只要 0.6~0.85s**), 过一会儿又 1/6 (大量
The read/write operation timed out)。同一份配置、同一个 key, 波动完全来自网络路径 (中间设备在改 TLS 记录),
这也解释了本机 git push 老失败、curl 回 000。

**代码改动 (oice.py / engine.py, 都是给 http 后端兜底)**
1. **stt_retry (默认 3, 1~8)**: 连接层失败**同一条路重试**, 间隔 0.4s; 判据是只有连接层异常才重试
   —— 服务端回过话的 HTTPError(401/429)**绝不重试**, 免得白花额度; 每次重试写 always-on 日志,
   最终报错带"共试 N 次"。
2. **stt_timeout (默认 15s, 5~60)**: 取代写死的 30s。录音才几十~几百 KB, 15s 足够;
   代理是黑洞时这个值决定回退直连前白等多久。
3. **记住可用路径** (_prefer_direct): 自动模式下哪条路通了就**下次优先**它。本机注册表里那个本地代理
   现在是**黑洞**(连上但不响应), auto 每句要白等 3×timeout(实测第一句 100s); 记住直连后回到 0.6s 级。
4. 本机运行配置: oice_engine = http + .cn + FunAudioLLM/SenseVoiceSmall +
   **stt_proxy = direct**(直接绕开那个黑洞代理) + stt_retry = 3 + stt_timeout = 10。

**验证**
- %TEMP%\wg-r59-stt-proxy-probe.py **23/23**, 其中新增 G2: 假服务器**先把连接掐掉一次** ->
  重试后成功且服务端**确实收到 2 次请求**; stt_retry = 1 时不重试、只发 1 次、错误里写"共试 1 次"。
- stt_retry/stt_timeout 解析: 越界钳位(8 / 60)、非法值保持缺省(3 / 15)—— 各 3 组用例。
- 其余全绿: oice-vad-test 31、whisper-warm-test、	ray-swap-test 42、harness 23 项、
  undefined-globals 0、r58 18/18、r52 24/24、r53 30/30、r57 28/28 + 21/21;
  dist/package 重建同步 (**897754 B**)。
- 真实 API: 成功时返回 今天天气不错，我们下午3点开会。(**0.6~0.85s**)。

**结论**: 配置本身是对的、可用; **本机网络太烂时**建议用离线 cmd+SenseVoice(1.7s, 100% 本地,
见第六十四轮/§D8) 或 whisper; 换到网络正常的设备上, http 是最省事的方案(零安装, 每句 0.5~1s),
正好适合"拿去其它设备"。

---

# 更新记录 (Changelog)

> 本文件记录 WgIme 的每次代码更新。以后任何更新都追加到本文件顶部(新版本在最上)。

---

## 2026-09-15 (第六十三轮: 本地 whisper 后端 `voice_engine = whisper` —— 常驻子进程, 每句 20s → 4s)

用户："方案B试一下。"（第六十二轮的结论里建议换后端：`http` 要国内站 key、`cmd` + 本地 whisper 太慢）

- **先把 `cmd` 这条路测出来**（`faster-whisper` 1.2.1 + `small`/`int8`，本机已有模型与缓存，**不用下载**）：
  **准确率确实好**（TTS 合成中文喂真识别路径：17 字 100%、33 字 88%，无繁体字），**但延迟不可用**：

  | | 每句耗时 |
  |---|---|
  | 真转写本身 | 2.2 ~ 4.6 s |
  | `import faster_whisper` | 6.5 s |
  | 载模型 (`small`/int8) | 2.2 s（冷文件缓存时 ~9 s） |
  | **`cmd` 现状：每句都新起一个 python** | **21 ~ 22 s** |
  | 常驻进程（模型只载一次） | **3.0 ~ 5.3 s** |

  即 20 秒里有 **16 秒是"每句话都在重付的导入 + 载模型"**。探针 `%TEMP%\wg-r63-timing.py`、
  `%TEMP%\wg-r63-warm-probe.py`（冷/热对照，同一批 WAV）。
- **新增后端 `voice_engine = whisper`**（第六十三条后端；`local`/`faster-whisper`/`warm` 是别名）：
  照 §17 光标跟随 helper 的**同一套**做法 —— 源码经**环境变量**交给子进程（不落盘 `.py`、不进进程命令行），
  `stdin/stdout` 走 **JSONL**，文本用 `ensure_ascii=True` 回传（绕开子进程 stdout 代码页 —— 中文机
  直接写裸 UTF-8 会变 `?`）；**父进程退出 → stdin EOF → 子进程自己结束**（`quit_app()` 是 `os._exit(0)`，
  不会跑 atexit，靠的就是这条，不留孤儿进程）。
- **配置键**（都只影响这个后端）：`stt_model`（默认 `small`）/ `stt_lang` / `stt_prompt`（给"以下是普通话的
  句子。"能明显减少繁体字）/ `stt_device` / `stt_compute`（默认 `int8`）/ `stt_beam`（1=贪心最快, 5=默认）/
  `stt_python`（faster-whisper 装在别的解释器上时指过去）/ `stt_prewarm`（启动后台预热，默认 1）。
- **两处预热**：① 启动后 4s 起一个后台线程把模型载进来（`prewarm_bg`，`stt_prewarm=0` 可关）；
  ② 按下语音热键的**那一刻**再 ensure 一次（载模型与"用户正在说话"这段时间重叠）。`warm()` 本身
  只 spawn、**不等 READY**（实测 75~100ms，绝不卡 Tk 主线程）。
- **两个锁别合成一个**：`lock` 只管起/杀进程（预热路径只碰它），`rlock` 只管一问一答（识别线程会持着它
  等 3~5s、首句还要等载模型）。合成一个锁的话，预热调用就会把主线程卡在识别期间 = 打字停摆。
- **同轮修掉的两个真 bug**（都是"只在特定顺序下才复现"的那种）：
  1. **录音文件固定名 `voice-last.wav` → 每次一个独立文件名**。常驻助手是**过几秒**才去读这个 wav 的，
     固定名会让"上一句还在识别、这一句又录完"把文件覆盖掉 —— 上一句识别出**这一句**的内容（张冠李戴，
     偶发、极难查）。现在按 `voice-<pid>-<序号>.wav` 命名，识别完各自删各自的（顺带清掉旧版遗留的固定名文件）。
  2. **`ensure()` 里"换了参数"必须清掉上一条错误**。实测：先试了坏的 `stt_python`（FileNotFoundError），
     1 秒内再换 `stt_device=cuda` 试 —— 报出来的还是 FileNotFoundError，用户会以为自己的修改**没生效**。
     现在 `key` 变了就清 `last_err`；真的连续 3 次起不来时，报"已停止重试(重启 WgIme 才重新试)"**并且**
     附上上次的真实原因（只说"起不来"等于没说）。
- **回归**：新增 `wgime-py-pure\tests\whisper-warm-test.py`（**67 项**，纯桩：把 `subprocess.Popen` 换成
  照抄真管道语义的假进程 —— 没数据时 stdout 迭代会**阻塞**、进程死了写 stdin 会**抛异常**、只有 kill 后才 EOF；
  先有一组"桩自检"证明桩真的像管道，否则后面全是空转）。覆盖：预热不阻塞 / `env` 是复制过的 /
  源码不进命令行 / READY 与初始化失败 / 串包丢弃 / 中途崩溃 / 超时 / 连续 3 次停手 / 陈旧错误 /
  重启时旧读取线程的 EOF 不得落进新队列 / shutdown / `prewarm_bg` / 9 个引擎别名的分派表。
- **守卫有效性自检**（`%TEMP%\wg-r63-guard-check.py`）：把两处守卫**改回旧写法**各跑一遍 ——
  `last_err` 那条 → `I2` 失败；`_reader(p, q)` 改用 `self.q` → `H3`/`H4` 失败。基线 0 失败。
- **真进程端到端**（`%TEMP%\wg-r63-warm-engine-probe.py`，24 项，真子进程真模型）：冷 20.0s（含载模型
  2.8s + 导入）/ 热 **4.0s**、并发两句不串包（9.1s / 各 3~5s）、`shutdown()` 后进程真的退出、
  坏 `stt_python`/坏 `stt_device` 都报真原因、1 秒内换参数不报陈旧错误。
- 回归：`pure-state-harness` 23/23、`undefined-globals` 0、`tray-swap-test` 42/42、`voice-vad-test` 31/31、
  `whisper-warm-test` 67/67；dist 重建。文档：`config.txt` 模板加 `whisper` 段落，
  `docs\WGIME_使用说明.md` 引擎表加一行 + "本地 whisper 怎么配"，AGENTS §38 补第六十三轮。

---

## 2026-09-15 (第六十二轮: 系统引擎中文识别率低 —— `Recognize()` 只取了第一段, 长句后半截被丢)

用户："这个中文识别率太低了，感觉不如直接用系统自带的功能。"

- **先分清事实**：`voice_engine = system` 走的是 `System.Speech`
  （`Microsoft Speech Recognizer **8.0** for Windows`，SAPI5 老桌面引擎），跟 Win+H「语音输入」用的神经引擎
  **不是同一套**，天花板本来就低。但这里确实还有**我们自己的一个真 bug**。
- **真 bug**：`_SYS_PS` 里只调了**一次** `$rec.Recognize()` —— 它**一次只返回一段**（引擎按停顿把一句话切成多段），
  于是**长句只出来前半截，后半句整段丢掉**。
- **实测**（用系统 TTS `Microsoft Huihui Desktop` 合成中文再喂我们自己的识别路径；探针
  `%TEMP%\wg-r62-sysrec-probe.py`，**不需要麦克风也不需要联网**）：

  | 原文 | 修前 | 修后 |
  |---|---|---|
  | 你好 | 你好（100%） | 你好（100%） |
  | 今天天气不错，我们一起出去走走吧。（17 字） | 今天天气不错国内一起出去走走吧（76%） | 同左（76%） |
  | 这个输入法是我自己写的，支持拼音五笔还有语音输入，用起来挺方便的。（33 字） | **只 16 字 / 覆盖 18%** | **27 字 / 39%**（`segs=2`） |

- **修法**：循环 `Recognize()` 收齐所有段再拼接（CJK 用 `''` 拼、其它语言用 `' '`）。
- **踩到的坑**：WAV 流读完之后**再调 `Recognize()` 不是返回 `$null`，而是抛 "No audio input is supplied"**（实测）——
  第一版循环没在内部 try 住，异常冒到外层 catch，**已经收到的段全被丢掉**（表现为"完全没结果"）。
  现在循环内自己 try 并 break，只有**第一次**就抛才当错误上报。
- **诊断**：每次识别另记一行 always-on —— `voice: sys-rec segs=<段数> chars=<字数>`。
- **结论 / 建议**：剩下的差距是引擎本身，改配置就能换后端（都不用改代码）——
  `voice_engine = http` + 硅基流动**国内站** `SenseVoiceSmall`（中文强），或 `voice_engine = cmd` + 本地 whisper.cpp；
  `system` 只适合"完全不想配置、且能接受老引擎准确率"的场景。
- 回归：`pure-state-harness` 23/23、`undefined-globals` 0、`tray-swap-test` 42/42、`voice-vad-test` 31/31；
  dist 重建（875561 B）。文档：AGENTS §38 补第六十二轮。

---

## 2026-09-15 (第六十一轮: 修"语音输入说不到 2 秒就自动停" —— VAD 阈值被说话声自己顶高)

用户报"按了 Ctrl+Alt+V, 才说不到 2 秒就自动停止录音了"。

- **真因**：VAD 阈值只看了**绝对底噪**：`thr = clamp(floor*3.5, 180, 1200)`，而 `floor` 是"见过的**最小** RMS"。
  于是 —— **"按住热键就说话"**（开头压根没有一个静音块）或**麦克风增益偏热**时，`floor` 是从**说话声**
  里取的值（比如 600）→ `thr` 被顶到上限 **1200**；而正常说话只有几百~一千出头 → **说话声自己**被判成
  "静音" → 攒够 `voice_silence`（默认 1.2s）就收尾。
- **数字对得上**：停止时刻 = `MIN_MS(400) + silence(1200) ≈ 1.2~1.6s`，正是用户说的"不到 2 秒"。
  回归测试里把旧公式装回去，A1 直接复现：**"停在块 6"= 1.2 秒**。
- **修法**：阈值取**两者较小** ——
  `thr = min(clamp(floor*3.5,180,1200), clamp(peak*0.25,180,600))`，
  `peak` = 最近听过的最响块（每块 ×0.9 慢衰减，防麦克风开启那一下的爆音长期抬高阈值；再叠 600 上限）。
  相对项**只会把阈值往下拉**，所以句内换气/弱音节不再被当成"说完了"；真静音（接近 0）仍远低于两者，该停还是停。
- **代价（有意选择）**：噪声大的房间里噪声会被当成说话 → **不会**自动停。宁可不停 —— 用户本来松开热键就结束，
  要彻底关掉自动停就 `voice_silence = 0`。
- **加了一行 always-on 诊断**（每次录音一行，不含音频内容）：
  `voice: rec <ms> blocks=… spoke=… auto_stop=… floor=… thr=… peak=… quiet=…ms silence=…ms`
  —— 这类"用户机器上才复现"的问题只能靠现场数字定位。
- **可测性**：判据拆成 `Recorder._vad_block(r, elapsed)`，新增
  `wgime-py-pure\tests\voice-vad-test.py`（**31 项**，纯桩不碰麦克风）。
- **守卫有效性自检**：把阈值改回旧的"只留 thr_abs"写法 → 测试 **10 条失败**（A1 复现 1.2 秒自动停、
  A3/E2 抓住"阈值高于说话电平"）；还原后 **31/31 通过**，`voice.py` 与提交版本逐字节一致。
- 回归：`pure-state-harness` 23/23、`undefined-globals` 0、`tray-swap-test` 42/42、`voice-vad-test` 31/31；
  dist 重建（872710 B）。
- 文档：AGENTS §38 补第六十一轮 + §4 测试清单加这一条。

---

## 2026-09-15 (补回缺失的托盘换图回归 `tray-swap-test.py`)

第五十六/五十七轮那套托盘换图状态机的说明里写着"改这块**必须**跑
`python wgime-py-pure\tests\tray-swap-test.py`（26 项）"，但**这个文件根本没进仓库**（第五十七轮写完文档忘了提交）。
追 GitHub 更新时发现，补上。

- 新增 `wgime-py-pure\tests\tray-swap-test.py`：**42 项**，纯桩、**不碰真托盘**（不建真 pystray icon、不写注册表/配置、
  不联网），跑一次不到一秒。
- **假 icon 严格照抄真 pystray 的语义：`_message()` 返回 `None`** —— 这正是它能抓住第五十七轮那个回归的关键。
  第五十三轮探针的假 icon `return True`，比现实宽松，所以漏了这次回归：**桩不能比真的更宽容**。
- 覆盖范围：
  - **A** 图标还没登记（`visible=False`）时绝不换图：不发 NIM_MODIFY / 不销毁句柄 / 不推进 `_cur_key` /
    安排一次 150ms 重试且不重复安排 / 仍刷菜单（8 项）
  - **B** 换图成功后 `_cur_key`、`_shown_key`、`_shown_handle` 与 hIcon 一致，且 **`_message()` 返回 None 也照样推进**
    （证明判据是 `NIM['modify_ok']` 而非返回值）（7 项）
  - **C** 同一张图重复刷新：不发 NIM_MODIFY、不重建 HICON、只刷菜单（3 项）
  - **D** shell 拒收时不谎报、不销毁旧句柄，下次用**同一句柄**补发，接受后才销毁旧 `_shown_handle`（12 项）
  - **E** 模式来回切（混合→语音→混合）**每次都换图** —— 就是用户报的"图标都不会变了"那个场景（3 项）
  - **F** GDI 句柄不泄漏：5 次换图销毁 4 个、当前句柄未被销毁；shell 全程拒收时一个都不销毁（4 项）
  - **G** 边界：`icon=None`、`visible` 读取抛异常（按"未登记"处理）（2 项）
  - **H** key 映射：语音模式是 `4a`（防 `% 4` 退化成 `0a`）、未激活是 `i` 后缀、tray 模式是 `tool`（3 项）
- **守卫有效性自检**（一个不会失败的测试等于没写）：把 `_notify_icon` 临时改回第五十六轮那种
  `bool(icon._message(...))` 写法 → 测试 **11 条失败**（含 B7「返回 None 而状态仍推进」）；
  还原后 **42/42 通过**，且 `tray.py` 与提交版本**逐字节一致**（自检没留下任何改动）。
- 文档：AGENTS §4 与 §43④ 的项数 **26 → 42**，并记下这次"守卫有效性"自检。
## 2026-09-14 (第六十四轮: 落地本地离线语音识别 —— sherpa-onnx + SenseVoice-Small int8, 实测可用)
> 轮次号说明: 这轮原文记的是"第六十一轮", 但合并时远端并行会话已占用第六十一~六十三轮
> （VAD 阈值/系统引擎分段/本地 whisper 常驻），故改号为第六十四轮；内容未变。

用户选了这个方案，本轮把它在这台机器上装好、接通、验证。**仓库内只改文档/配置模板，代码零改动**
（用的是 `voice_engine = cmd` 这个既有后端）。

**装了什么（都在仓库外，见 `C:\Tools\wgime-local-asr\README.md`）**
- 运行时：`pip install sherpa-onnx` → **1.13.8**（core 16.9 MB + 轮子 2.2 MB，装在 Store Python 的
  用户 site-packages，跟双击运行 wgime 的解释器是同一个）。
- 模型：**SenseVoice-Small int8** —— `model.int8.onnx` **228 MB**（`239233841` B）+ `tokens.txt`（315894 B），
  放 `C:\Tools\wgime-local-asr\models\sense-voice\`。
- 下载源：**`hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17`**（**必须带浏览器 UA**，
  否则 403；HuggingFace 直连不通、GitHub 上那份 tar.bz2 是 **999 MB** 的 fp32+int8 合集，没必要下）。
- 入口：`C:\Tools\wgime-local-asr\wgime-stt.py`（wrapper）+ `wg-dl.py`（带断点续传的下载器）。

**接法（`package\config.txt`，未入库）**
```
voice = 1
voice_engine = cmd
stt_cmd = python C:\Tools\wgime-local-asr\wgime-stt.py {wav}
```
注意 `_cmd_recognize` 取 **stdout 第一行非空输出**当结果 —— 所以 wrapper **只往 stdout 打印识别文本**，
其它日志（含 sherpa-onnx 自己的）一律 stderr；出错时 stdout 不输出、stderr 说明原因并返回非 0。

**验证（用 CosyVoice2 合成的音频当"人声"测的，本机麦克风是纯数字静音）**
- 中文：期望"今天天气不错，我们下午三点开会。" → 识别 **`今天天气不错，我们下午3点开会。`**
  （`use_itn=True` 会把中文数字转成阿拉伯数字；wrapper 支持 `--itn=0` 保留"三点"）。
- 英文：`The weather is nice today; Let us have a meeting at three in the afternoon.` 全对。
- 端到端（`engine.load_config` 读真配置 → `voice.recognize`，等价于按热键那条路）：
  中文 **2.83s**、英文 **2.90s**。
- 耗时构成：**建会话 1.5s + 解码 0.24s**（`--threads=4`；2 线程是 2.4s + 0.41s）。
  每句重建会话是唯一慢点，要更快得做常驻进程（模型只加载一次，之后 ~0.25s/句），按需再加。

**顺带查清的坑（省得下次再踩）**：ModelScope 的 `iic/SenseVoiceSmall-onnx`（`model_quant.onnx` 230 MB）
是 **FunASR 格式**，配 `funasr-onnx`；但那个包 **只支持 Paraformer、不含 SenseVoice**，所以它跟 sherpa-onnx
不通用 —— 用 sherpa-onnx 就得拿 sherpa-onnx 转换过的模型（hf-mirror 那份）。

---

## 2026-09-14 (第六十轮: 硅基流动"国际站 vs 国内站"两套账号 —— 排查云端识别必须先对站点)

无代码改动，纯**实测结论 + 配置模板说明**（避免以后又把"站点选错"当成"key 错"来回折腾）。

用户在国际站（`siliconflow.com`）注册，我一开始给的 `stt_url` 写的是国内站 `api.siliconflow.cn`，
于是一直回 `HTTP 401 {"code":30014,"message":"Token is invalid."}` —— **看起来像 key 错，其实是站点错**。
用**同一把 key + 真实中文语音 WAV**（用 CosyVoice2 现场合成的"今天天气不错，我们下午三点开会。"，
149934 B）走我们自己的 `voice.recognize`，四组结果：

| 端点 | 模型 | 结果 |
|---|---|---|
| `api.siliconflow.com/v1/models` | — | **200**（key 有效；共 79 个模型） |
| `api.siliconflow.com/v1/audio/transcriptions` | `FunAudioLLM/SenseVoiceSmall` | **403** `{"code":30003,"message":"Model disabled."}` |
| `api.siliconflow.com/v1/audio/transcriptions` | `TeleAI/TeleSpeechASR` | **400** `{"code":20012,"message":"Model does not exist."}` |
| `api.siliconflow.cn/v1/...`（任意） | 任意 | **401** `{"code":30014,"message":"Token is invalid."}` |

结论：**两站是两套账号/密钥，互不通用；而且国际站的模型表里没有任何可用的语音识别模型** ——
音频类只有**合成（TTS）**：`FunAudioLLM/CosyVoice2-0.5B`、`IndexTeam/IndexTTS-2`、`fishaudio/fish-speech-1.5`
（实测 CosyVoice2 TTS 可用，合成出中文 WAV；但**TTS ≠ 识别**，接不到 `/v1/audio/transcriptions` 上）。
要中文识别只有三条路：①国内站账号（`cloud.siliconflow.cn`，需国内手机号 + 实名）用 `SenseVoiceSmall`；
②本地离线 `voice_engine = cmd`（sherpa-onnx/SenseVoice 或 whisper.cpp）；③任何 OpenAI 兼容的识别服务。
已把这段写进 `config.txt` 模板注释（含两种错误码的判别），运行配置里的 `stt_url` 也已指到用户账号所在的
**国际站**。附带确认：上一轮的代理回退在真实请求里生效（`.log` 里是 `STT ok via 直连 (earlier path failed: 系统代理: …)`）。

---

## 2026-09-14 (第五十九轮: 云端语音识别的"死代理"坑 —— 加了代理回退 + 能看懂的报错)

背景: 用户问"哪个语音 API 免费且中文还行", 选定**硅基流动**（`FunAudioLLM/SenseVoiceSmall`，OpenAI 兼容
`/v1/audio/transcriptions`）后在本机实测，发现云端后端**一次都连不上**。

**真因: 注册表 Internet 设置里留着已经关掉的本地代理。** 本机 `urllib.request.getproxies()` 返回
`http://127.0.0.1:10808`（Clash/v2ray 那类工具留下的，程序没开、设置没清），于是每次请求都先连这个
死端口 → `ConnectionRefusedError(10061)`；而目标站点**直连本来是通的**（实测拿到过干净的
`HTTP 401 {"code":30014,"message":"Token is invalid."}` —— 说明端点、鉴权头、multipart 形状都对，
只差一个有效 key）。`voice.py` 的 http 后端原来完全没有处理这件事。

**修法（`voice.py`）**：`_http_post(url, body, headers, cfg)` 按 config `stt_proxy` 决定尝试顺序 ——
空/`auto`（默认）= 先系统/环境代理、**连不上就换直连再试一次**；`direct` = 只直连；`http://host:port` =
只用指定代理。**服务端只要回过话（401/429/500…）就不再换路**，免得白花一次额度；全部失败时把
**每一条路各自的原因**一起报出来（"系统代理: 10061；直连: SSL…"），用户一眼能看出是代理挂了还是直连不通。
配套：`engine.py` 增 `stt_proxy` 键，`config.txt` 模板加说明与硅基流动的完整示例。
**写这段时踩到的第二层坑（一并修掉）**：最初把构造好的 `Request` 传进来复用，而走代理时
`OpenerDirector` 会调 `req.set_proxy()` **就地改写 `req.host`** —— 拿同一个 req 去试直连，它会照样连到
那个死代理上，**回退等于白回退**（探针里两次尝试都是 10061）。现在每条路都重建 `Request`。
另外 HTTP 错误不再 `%r` 一坨 `<HTTPError 401>`，改成 `STT 接口返回 HTTP 401: {服务端原话}`。

**验证**：`%TEMP%\wg-r59-stt-proxy-probe.py` **18/18**，全部打**本地假服务器**（本机外网时通时断，
拿真端点做断言不可复现）：A 直连正常（且服务端确实收到 `file`/`model`/`Authorization: Bearer`/multipart）；
B **环境里挂个死代理 -> auto 自动回退直连成功**（且"失败那次"根本没到服务器，hits=1）；C `direct` 无视死代理；
D 指定代理对"不在本地绕过名单里的域名"确实生效（错误是连代理 10061，而 direct 是 DNS 失败，两者可区分）；
E 401 报状态码+服务端原话；F 非 JSON（纯文本）响应可用；G 配置键与模板都在。
回归: r58 语音收音 18/18、r52 hook/win 24/24、r53 托盘 30/30、r57 换图 28/28、模式循环 21/21、
`tray-swap-test` 26 项、harness 23 项全过、`undefined-globals` 0、dist/package 逐字节同步（**870631 B**）。
**本机现状提醒**：修完后再打真端点，报错变成"系统代理 10061；直连 SSL BAD_RECORD_MAC" —— 直连的 TLS
在这台机器上**时好时坏**（早先成功过一次 401），属于环境/中间设备问题，不是代码问题；真机上若持续如此，
建议改用离线后端（`cmd` + sherpa-onnx/whisper.cpp）。

---

## 2026-09-14 (第五十八轮: 修"语音输入收不了音 / 一直卡在 正在听…(0s)")

用户（截图：候选条 `[语音|开] 正在听… (0s) 松开结束`）："这是我在测试语音输入时发现的一个问题。
感觉是没办法完成收音，我已经给了 python microphone 的权限了。"

**真因 ①（决定性）：按住热键时的"自动重复"被当成了"第二次按"。**
Windows 对按住的键会每 ~33ms 补发一次 `WM_KEYDOWN`（低层钩子的 `KBDLLHOOKSTRUCT` 里**没有**重复标志，
只能靠自己的"键还按着"状态分辨）。`hook._proc` 以前对每一次重复都入队一个 `VK_VOICE`，而 `main.voice_down()`
见到"已经在录"就走"第二次点 = 结束"那条分支 `voice_finish()`；紧接着的下一次重复又开一段**全新**录音
（`Recorder.t0` 归零）——于是按住说话的整段时间就在 start/finish 之间抖：说话被切成一地碎片、
候选条永远停在 **(0s)**、松开时已经没有 `rec` 可收尾 → 识别永远不会发生。探针实测：按住 1 次 = 6 个
`VK_VOICE` → `ops = START/stop/START/stop/START/stop`。
**修法**（`hook.py`）：`if VOICE_DOWN[0]: return 1`（自动重复直接丢弃，不再入队）；并补一条"修饰键已松开
的 V 按下 -> 清 `VOICE_DOWN[0]`"，防止松键事件丢失（切窗口/钩子重装）之后语音热键被永久卡死。

**真因 ②：录音期间候选条根本不重画 → "(0s)" 是按下瞬间的死字符串。**
只有 `voice_down()` 画一次，之后全靠事件驱动；用户看到秒数不动，自然以为没在收音、也不知道何时松手。
**修法**：新增 `main._voice_tick()`（录音中 ~4Hz 重画，`show_page()` 是幂等纯界面操作），由 `poll()` 调用，
`voice_down()` 开始时把 `_VOICE_TICK[0]` 归零。现在秒数真的会走。

**真因 ③（顺带）：VAD 阈值几乎从不生效，且失败提示无法判断。**
`_on_data` 原来是"头 500ms 取中位数定阈值，凑不够 2 块就退回写死的 300"——块本身是 **200ms**，再叠上
`waveInOpen/waveInStart` 的启动延迟（本机实测 100~300ms），那个窗口里经常只落进 1 块，于是阈值永远是
兜底的 300（本机探针实测 `_thr=0`）。底噪偏大或麦克风偏轻的机器就"怎么喊都听不到说话声"。
**修法**：改成**自适应底噪** `_floor = min(_floor, r)`、`thr = clamp(_floor*3.5, 180, 1200)` ——
第一块样本就能定阈值，之后遇到更安静的块只会把阈值往下修（自然停顿处即修正），上限 1200 防噪声环境顶天。
提示也改成能判断的：全 0 PCM（新增 `voice.peak()`）报"**麦克风给的是纯静音**: 输入设备被静音或选错了设备"，
否则报"录了 X.Xs，峰值≈N 音量≈M"；"一个字节都没回调"单独报一条。

**验证**：`%TEMP%\wg-r58-voice-hold-probe.py` **18/18** —— A 假造 6 次自动重复喂**真 `hook._proc`**（只出
1 个 `VK_VOICE` + 1 个 `VK_VOICE_UP`）；B 把这串事件喂**真 `handle()`**（只 START 一次、按住期间不被掐断、
松键后 stop+写 WAV、识别结果回主线程、`voice_auto` 关时不自动上屏）；C 录音中界面续秒（文本从 `(0s)` 到 `(1s)`，
没录音时不重画）；D 纯静音 PCM 报"纯静音"；E **真 `_on_data`** 的 VAD 单元测试（第一块就定阈值 180、
说话 `spoke=True`、静音 400ms 后自动停并回调）；F `peak()` 行为。
回归：r52 hook/win 探针 **24/24**、r53 托盘 **30/30**、r57 托盘换图 **28/28**、模式循环 **21/21**、
harness **23 项全过**、`undefined-globals` **0**、dist/package 逐字节同步（**866442 B**）。
**本机麦克风实测**（`%TEMP%\wg-r58-mic-probe.py`）：设备在、权限 Allow、2.3s 收到 73732 字节，但 RMS≈0~1
——这台机器的输入设备给的是纯数字静音，所以"识别质量"只能在用户机器上验证。

---

## 2026-09-14 (第五十七轮: 修"托盘图标都不会变了"/"混合的模式切换不过去" —— 第五十六轮自己引入的回归)

用户反馈（合并 v1.2.12 后的新成品）："现在托盘图标都不会变了。。。。" +
"mixed 的模式切换不过去（ctrl+` 的快捷键）"。

**真因：把 `icon._message()` 的返回值当判据 —— 而它根本没有返回值。**
第五十六轮换图时写的是 `ok = bool(self.icon._message(1, 0x2, hIcon=h))`，可 pystray 的
`_win32._message()` 内部只是调 `Shell_NotifyIcon(...)`，**没有 return**，所以 `bool(None)` 恒为 False。
后果有两个：
① `_cur_key`（第五十六轮新加的"当前这张图"状态）**永不推进** → 新加的"同 key 就只刷菜单勾选态、
   不惊动 shell"这条分支会拿**旧状态**当"图标已经是新的" → 从「语音/词典…」切回**混合**、或按开关把
   输入法打开时（key 回到 `0a`）**图标纹丝不动**；
② 旧句柄永不销毁 → 每刷一次漏一个 **HICON（GDI 句柄泄漏）**。
**"模式切换不过去"是同一个 bug 的另一面**：日常 空闲隐藏 打开时没有候选条，切模式**唯一**的反馈就是托盘
图标；图标冻住 → 看起来"模式没切过去"（模式循环本身没问题，见下面探针）。

修法（`tray.py`）：把换图抽成 `_notify_icon(h, key, old)`，**只信 tray.py 顶层那个 spy 记的
`NIM['modify_ok']`**（它只看 `NIM_MODIFY|NIF_ICON`），并把状态拆成两个："pystray 当前句柄对应的 key"
（`_cur_key`）与"shell **确认接受**过的 key/句柄"（`_shown_key`/`_shown_handle`）：
- 注入新句柄后 `_cur_key` 立刻推进（pystray 侧事实），**只有 shell 确认**（`modify_ok is True`）才
  `DestroyIcon` 掉 `_shown_handle`（先销毁再换会让 shell 引用已销毁句柄 → 空白图标，见第五十六轮）；
- shell **拒收**时不谎报（`_shown_key` 不推进、旧句柄留着给 shell 用），下次刷新用**同一个句柄**补发
  `NIM_MODIFY`，不再重建 HICON（既不漏句柄也不重复分配）；
- `start()` 注入启动图标时同步设好 `_shown_key`/`_shown_handle`（`NIM_ADD` 带的就是那个句柄）。

**验证**：
- **真环境**（真 pystray + 真 shell + 真内嵌 ICO，`%TEMP%\wg-r57-tray-live.py`）：`_cur_key` 轨迹
  `0a → 0i → 0a → 1a → 3a → 0i`（每一步都真的换图），每次 `NIM_MODIFY` 都被 shell 接受（True），
  且**每次换图恰好销毁上一个句柄**（启动的 `h0` 在第一次成功换图后被销毁）—— 之前这里是
  `destroyed=[]`（既没换成功判定、也从不回收）。
- **回归测试**（新，进仓库）：`python wgime-py-pure\tests\tray-swap-test.py` **26/26** —— 它的假 icon
  **照抄真 pystray 的 `_message` 返回值 (None)**；第五十三轮那个探针的假 icon `return True`，
  比现实宽松，所以没抓到这个回归（这正是教训：**假的桩不能比真的更宽容**）。
- `%TEMP%\wg-r57-tray-swap-probe.py` **28/28**（含 A~G：启动不换图 / 补刷 / 开关来回 / 模式往返 /
  拒收后补发不重建不漏）、`wg-r53-trayicon-probe.py` **30/30**、`wg-r52-hookwin-probe.py` **24/24**。
- **模式循环本身没问题**（`%TEMP%\wg-r57-mode-cycle-probe.py` **21/21**，跑真 `main.py` 前缀 + 真 `handle()`）：
  `Ctrl+`` 依次 `混合→拼音→五笔→词典→语音→混合`（第 5 次回到混合），从任意模式出发 ≤5 次必到混合；
  5 个模式的开态图标 key 互不相同（`0a/1a/2a/3a/4a`）；托盘菜单「模式」5 项从任何模式都能切。
- harness **23 项全过**、`undefined-globals` **0**、dist/package 逐字节同步（**861283 B**）。

---

## 2026-09-14 (第五十六轮: 修"刚启动时托盘图标显示奇怪/加载不及时" —— 两个真因)

> 轮次号说明: 远端并行会话已用过第五十三~五十五轮（工具箱磁贴/滚动条/窗口高度），
> 本轮托盘图标的修复接在其后，故记为第五十六轮；`15b8513` 的提交信息里写的是旧号。

用户反馈："现在的托盘图标显示很奇怪，icon 加载不及时，特别是刚启动后。"

**真因 ①（第五十一轮我自己引入的回归）：启动瞬间销毁了 shell 正在用的句柄。**
`Tray.start()` 先把 HICON `h0` 注入 pystray、再 `run_detached()`（**setup 线程**稍后才发 `NIM_ADD`），
紧接着主线程就调 `_refresh()` —— 第五十一轮为了让"不可见时也回收旧句柄"改成了**无条件 `_release_icon()`**：
此时 `visible` 往往还是 False（setup 线程没跑完），于是 `h0` 被 `DestroyIcon`、`h1` 被注入却**不发 NIM_MODIFY**
（没登记上也没法发）。结果 shell 记住的是**已销毁的句柄** → 刚启动那一下托盘图标空白/乱，过一会儿或点一下才正常。

修法（`tray.py`）:① **图标还没登记上时绝不换图**（只安排一次 `after(150)` 的补刷），既不销毁也没白建句柄；
② 换图**先注入新句柄 → 发 NIM_MODIFY → shell 接受之后才 `DestroyIcon` 旧句柄**（新增 `win.destroy_icon()`，
因为 pystray 的 `_release_icon()` 销毁的是"当前"句柄，不是被换下来的那个）；
③ 同一张图（key 相同）重复刷新只更新菜单勾选态，不再每次重建 HICON、惊动 shell。

**真因 ②：托盘图标排在"词库加载"之后才创建。**
词库加载是**主线程 join** 的（热启动 ~1.5-1.9s，冷启动从码表重建 **7.8s**，见下面的实测），而
`root.after(150, _deferred_tray)` 是在 join **之后**才注册的 —— 于是这段时间托盘里**根本没有图标**。
修法:新增 `_boot_tray()`，在等词库**之前**先把图标挂出来（最小菜单：开关/退出），词库读完后再由
`_deferred_tray` 换成完整菜单 + 真实状态（`Tray.api = _tray_api(); rebuild(); _refresh()`，不重复建、不换进程）。
配套:`tray.start(boot=True)`（最小菜单、默认图标、不做 `_refresh`）+ `_boot_items()`；把托盘 api 字典抽成
`_tray_api()` 供两处复用。`import tray` 的 ~130ms 花在等词库期间，词库线程本来就在跑，不额外拖慢上屏。

**实测（跑的是**真成品**单文件，冷启动、空数据目录，`WGIME_DEBUG=1`）**：

```
1789383218.761 tray: boot icon shown BEFORE dict join (dict thread still running)
1789383223.188 startup: engine load=7792ms        <- 托盘图标比词库读完早了 4.43s
1789383223.198 startup: mainloop start (poll every 8ms; …)
1789383223.398 tray start ok=True has_tray=True … <- 完整菜单/真实状态补齐
```
即"托盘图标出现时间"从 **≈8.2s（词库读完 + 150ms）** 提前到 **≈0.3s**。

**验证**：`%TEMP%\wg-r53-trayicon-probe.py` **30/30**：A 启动瞬间不销毁 h0/不发 modify/不白建句柄且安排了补刷；
B 登记后同 key 补刷只刷菜单；B2 若启动期间切了模式则补刷换图且**销毁发生在 NIM_MODIFY 之后**；
C 同 key 重复刷新零动作；D 切模式换图顺序正确；E 模式表 5 项（语音 `4a`/`4i` 不再退化成 `0`）；
F 真 ICO `LoadImage` + `DestroyIcon` 可用；G `_boot_tray()` 调用点确实在 `_engine_th.join()` 之前；
H `start(boot=True)` 建最小菜单（开关/分隔线/退出）、注入默认句柄、设好 `_cur_key`、**不调 `_refresh`**。
回归：harness **23 项全过**（前缀现在包含 `_boot_tray()`，源码布局无内嵌图标时它静默失败、留给 `_deferred_tray`）、
`undefined-globals` **0**、dist/package 逐字节同步（853916 B）。
---

## 2026-09-14 (发布 v1.2.12)

**release id 388497981** → https://github.com/ogowoo/wgime/releases/tag/v1.2.12 ，tag `v1.2.12` 指向 `e1934bb`（= 本地 HEAD）。

- **内容** = v1.2.11 之后的 **19 个提交**（第四十四～五十五轮）：语音输入（`Ctrl+Alt+V` + 「语音」模式 + 三条识别后端）、
  「译文」选项 + 词典模式回归 + 英语常用词表（`en-freq.txt`）、托盘图标"看不见"的真因（宿主没装 Pillow）、
  `lastpick_*.txt` 的 `\r` 累积、托盘开关"点了不落盘"、全量审计修掉 20 + 23 项、工具箱磁贴不可见、
  5 个窗口底部被裁 + 滚动条按需、caret-helper 不落盘/不进进程命令行。
- **三个资产**：`wgime-v1.2.12-bat.zip`（1.64 MB）/ `-ps1.zip`（25.99 MB）/ `-python.zip`（24.61 MB）。
- **发版回验（AGENTS §7，全过）**：body **2385 字、0 个 `?`**、含中文；三个 zip 的 SHA256 与 `.release-stage-v1212\`
  **全部一致**（bat `4F9C04D1…` / ps1 `7DD902A8…` / python `72C96996…`）；**下载线上 python zip 逐字节比对**：
  与 stage 一致、内层 `wgime-py.py` **853398 B / `E2B88F4A…`** 与本地 dist 一致、含 `dicts/`；
  `target_commitish` = 本地 HEAD `e1934bb`。
- 发版前先 `build-package.ps1` 重建，并**把 `THIRD_ZIP_B64` 还原成 HEAD 基线**（否则构建机重新生成的
  `comtypes/gen/` 4 个文件会混进发布包，与本仓库提交的 dist 不一致）。

---

## 2026-09-14 (第五十五轮: 窗口高度漏算标题栏 —— 一次修掉 5 个窗口的底部被裁 + 便签滚动条按需)

用户截图报「插件管理器 / 取色器的按钮位置异常、便签默认显示滚动条」。一查是**同一个根因**，而且不止那两个窗口。

- **根因**：`ui.make_window` 的 `content` 只占 **`h-38`**（标题栏那 38px 不算），但这些窗口的 y/高度全是按
  "可用区"排的，窗口高度却按"可用区"给 → **底部控件被窗口边缘裁掉**。
- **写了个自动审计**（建出窗口、遍历子孙算绝对 `(x+w, y+h)` 与窗口宽高比，超出的就是被裁），一次抓出全部：
  | 窗口 | 高度 | 被裁的东西 |
  |---|---|---|
  | 剪贴板历史 | 380 → **452** | 4 个按钮（底边 378 > 内容 342）|
  | 取色器 | 210 → **246** | 「拾取(点屏幕)」「复制 HEX」（198 > 172）|
  | 造词 | 200 → **232** | 「造词」「取消」（184 > 162）|
  | 用户词表 | 342 → **378** | 「全选/全不选/删除选中/关闭」（330 > 304）|
  | 插件管理 | 420 → **452** | 「关闭」（404 > 382）|
- **同一轮另修两处**：① 插件管理顶部按钮条总宽 `494+7*8=542 > bar 的 540` —— 最右「运行」被右边缘切 2px
  → 起点改 0、间距 8→6（530）；② 剪贴板那句提示不限定宽度又放在 `x=390`，文字 216px 宽 → 右边缘冲到 606
  （窗口才 520）→ 挪到按钮下方单独一行 + 显式 `width`。
- **便签滚动条改成按需**：原来是**无条件** `place`，空白便签也挂一条（用户："不优雅"）。现在靠 Text 的
  `yscrollcommand` 判断 `yview() == (0.0, 1.0)`（装得下）就 `place_forget`，溢出才显示；正文宽度保持不变，
  免得滚动条出现/消失时文字左右重排。
- **验证**：自动审计 10 个内置工具窗口 **全部 OK**（便签滚动条 `winfo_ismapped()==0`）；
  四个窗口**逐个截图肉眼确认**（插件管理 7 个按钮 + 关闭完整、取色器两按钮完整、剪贴板提示完整、便签无滚动条）。
- 回归：`pure-state-harness.py` **23/23**、`undefined-globals.py` **0**；dist 重建（853398 B，第三方 zip 还原 HEAD 基线）。
- 文档：AGENTS 新增 **§42**（窗口高度 = 内容需要的高度 + 38；审计方法；便签滚动条按需）。

---

## 2026-09-14 (第五十四轮: 工具箱收尾 —— 滚动条按需出现 + 底部日志不再被裁 + 控制台补滚动条)

用户看图后又提了两点，都是真问题：

- **磁贴没几个也挂着滚动条**：`vsb` 原来是**无条件** `place` 的。改成 `need_sb = inner_h > BODY_H` 才放；
  磁贴宽度两种情况下都用 `inner_w`，所以滚动条出现/消失时栅格不会跳。
- **底部日志被窗口切掉**：布局把控件挂在 `content`（标题栏下方，`ui.make_window` 里 `y=38, height=h-38`）上，
  却按**整窗高**算 `y=H-118` —— 日志框底边落到 456、超出内容区 432 **整整 24px**，最后几行被窗口边缘裁掉。
  统一改按内容区高 `CH=H-38` 推算：`LOG_H=132`（顺便加高）、`BODY_H=CH-46-LOG_H-GAP-4=240`（仍够放 4 行磁贴）。
- **控制台补滚动条**：`ui.console_text` 以前是光秃秃一个 `Text` + `wrap='none'` + 调用方 `see('end')`，
  输出一多就只剩最后几行、还没法往回翻。补**垂直滚动条 + 滚轮**（工具箱日志 / 网络工具控制台 / 聊天窗三处共用）。
- **几何实测（修后）**：content `560x432`；body `540x240`；Canvas `528x240`；Text `528x132 @ content(10,290)`
  → 底边 422 ≤ 432；Scrollbar `12x132 @ (538,290)`；**磁贴区无滚动条**（两页 `inner_h` 分别 70 / 126，均 ≤ 240）。
- 回归：`tests\pure-state-harness.py` **23/23**（exit 0）、`undefined-globals.py` **0**；
  dist 重建（851551 B；第三方 zip 还原 HEAD 基线）。
- 文档：AGENTS **§41 扩写**（滚动条按需 + `content` 相对坐标 + `console_text` 滚动条）。

---

## 2026-09-14 (第五十三轮: 修「WgIme 工具箱」按钮磁贴全部不可见 —— place() 不撑大父容器)

用户报"tools 工具箱里的配置都无法显示了"（确认是 `tools` 拉起的「WgIme 工具箱」窗口，不是 tray 菜单）。

- **现象**：窗口能开、标签页（办公/系统）都在，但**磁贴按钮一个都看不见**。
- **根因**：磁贴区是 `Canvas + create_window(inner)`，而磁贴由 `ui.flat_button` 用 **`place()`** 摆放 ——
  **`place()` 不参与父容器的 requested size**，于是 `inner` 只有 **1x1**。实测：
  `canvas.bbox('all') = (0,0,1,1)`、window item `winsize=('0','0')`，而磁贴本身**已经正确建出**
  （`245x46 @ 14,14` / `269,14`）—— 尺寸、坐标全对，纯粹被 Canvas 裁掉。
- **修复**：按磁贴行列算出真实尺寸，`inner.configure(width,height)` + `create_window(..., width, height)`
  + `canvas.configure(scrollregion=(0,0,w,h))` —— **三件都要做**（只设 scrollregion 不解决裁剪）。
- **修复后实测**：显示中的标签页 `inner` = **528x70**、`bbox('all')` = `(0,0,528,70)`、scrollregion = `0 0 528 70`；
  另一页（4 个按钮）= `0 0 528 126`（= `14 + 2*56`，与排布公式吻合）。
- **来源（不是我这次改出来的）**：这段 Canvas 代码由 **2026-09-10 的 `7d3a5f8`（"内置工具 1:1 收尾 - 工具箱 ToolsForm"）**
  引入，随前几次同步带进本机；修前 `tools.py` 与 `d344bc9` **逐字节相同**。
- 回归：`tests\pure-state-harness.py` **23/23**（exit 0）、`undefined-globals.py` **0**；
  dist 重建（830.8KB；第三方 zip 仍还原 HEAD 基线，只有 `tools` 模块变化）。
- 文档：AGENTS 新增 **§41**（place() 不撑大父容器 / Canvas 滚动区的判据与三件套修法）。

---

## 2026-09-14 (第四十四轮: caret-helper 源码改走环境变量 —— 不再出现在进程命令行里)

承接第四十三轮（helper 不再落盘，改成 `python -c` 内联源码）。用户接着问"能不能再合并掉、别在命令行里带 7KB 代码"。
第四十三轮虽然不落盘了，但 7200 字符的源码整段进 `-c`，于是**进程创建命令行**变成 7427 字符一条的怪异 `-c`
—— 而 EDR / 任务管理器 / 进程创建遥测记录的正是这条。

**改法**：源码经环境变量 `WGIME_CARET_HELPER_SRC` 交给子进程，命令行上只留一段 ~250 字符的引导
`_HELPER_BOOTSTRAP`（先剥 `sys.path` 里的 cwd，再 `os.environ.pop` 取源码执行）。**仍然不落盘、仍然是独立子进程**
（崩溃隔离这条不动）。

- **实测（本机，真实单文件路径）**：helper 的 OS CommandLine **7427 → 287 字符**；子进程收到的源码
  **sha256 逐字节一致**（7200 字符）；`ready` + 请求往返照常；`_ipc_proc` 存活、`_helper_fail=0`。
- **环境块容量**：当前继承环境块仅 5.4KB，加上 7.2KB 源码 = 12.6KB；探针实测塞到 **100KB 仍能创建进程**，余量充足。
- **隔离照旧**：`-c` 下 `sys.path[0]` 是**当前工作目录**，引导脚本先把它剥掉（保持第三十八轮那条"pythonnet 残留
  的 `.pyd`/`.py` 不得抢占标准库"的隔离）；源码用 `os.environ.pop` 取走后不留在 helper 自己的环境块里。
- **遗留清理保留**：`ensure_caret_bg()` 仍 best-effort 删掉第三十八轮之前落盘的那个 helper `.py`。
- dist 重建（829.9KB，10 个内嵌模块含 `voice.py`）；**第三方 zip 还原 HEAD 基线**（构建机重新生成的
  `comtypes/gen/` 4 个文件与基线不同，与本改动无关，不该混进这次提交）。
- 回归：`tests\pure-state-harness.py` **23/23 通过**（exit 0）、`wgime-py-pure\tests\undefined-globals.py` **0**；
  文档同步 AGENTS §17 + `docs\WGIME_技术文档.md`（+release 副本）。

---

## 2026-09-14 (第五十二轮: 把第五十一轮审计剩下的 23 项全部修完 + 语音真机验收)

用户："36项继续修 / 1) 让拖动生效 2) 保持现状 / 语音隐私已经 allow，可以测试了 / 再接着做 D5 清单吧"。

第五十一轮审计共 56 条候选、当时修了 20 项，剩下 23 项（`AGENTS-DETAIL.md` §D5 的"未修"清单）本轮**全部修完**，
并按用户决定处理了两条产品决策。每项都有可复跑探针（`%TEMP%\wg-r52-*.py`）。

**A. tools（4 项）**

- **用户词表"第二次删除删错词"**：`do_del` 用开窗时的 `items` 快照配 Listbox 现已变化的行号 → 第二次删除删的是别的词、
  被选中的词留在 `userwords.txt` 里永远删不掉（状态栏还谎报"已删除 1 个词"）。改成每次从 **Listbox 当前内容**重新取
  `(词, 编码)`（`_cur_items()`）。探针用真 Tk 窗口驱动：删 cc → 再删 dd，验证 dd 真被删掉（旧逻辑会又删 cc）。
- **取色器 / 插件管理器没有单例**：开两个窗后关掉任一个就把共享状态置空，另一个半死（取色器还会重复装 WH_MOUSE_LL 钩子）。
  新增 `_SINGLETON_WINS` + `_reuse_win()`（同名窗还开着就 deiconify/lift 并返回），与剪贴板窗（第五十一轮修的）一致。
- **中文 Windows 的 Ping/Tracert**：`ping_rtt` 原来只认 `time=`，中文回显 `时间=13ms` 全落到兜底分支 → **时延恒显示 0ms**；
  `hop_once` 只认 `ttl expired`/`ttl 过期`，中文实际是 `TTL 传输中过期` → **每跳都报 timeout**。改成正则同时认中英文，
  并优先从行里提取 IPv4 作为中转地址。探针打桩中英文回显：`时间=13ms -> 13`、`time<1ms -> 1`、中文过期行 -> `2  192.168.1.1`。
- **工具箱防重入粒度**：整窗一个 `running[0]`，跑 A 时点 B 完全没反应也没提示（C# 只禁用被点的那个按钮）。
  改成按按钮记（`running = set()`），不同按钮可并发、同按钮重复点击仍被挡。

**B. chat（7 项）**

- **重连等待期内"离开→加入"产生两个并发会话**（实测并发峰值 2、消息显示两遍）：加**会话代次**（`state['gen']`，
  `join()`/`leave()` 各自 +1），`_net_loop(gen)` 每轮和睡醒后都校验。探针 A/B：旧代码被作废的线程仍继续跑会话（stale=3→4），
  新代码 stale=1 且不再复活。
- **relay 空闲房间每 ~60s 被判死重连**（PONG 被 wspy 就地吃掉，`idle` 单调涨到 2）：改成按"最后收到数据或最后一次保活成功"
  的时间差判死（`IDLE_DEAD_SEC=90`，保活 15s 一次）。探针用可控时钟验证：保活成功时空闲 300s 仍不退出、两样都停 90s 后退出。
- **`send()` 不看连接状态**：未连接/已离开时回车会清空输入框并本地回显一条"像发出去了"的消息。改成先判 `running`/`ws`，
  不满足就给状态提示且**不清输入框**；`_send_json` 返回成败，只有真发出去才清框 + 回显（对齐 C# `if (t.Length==0 || !running) return;`）。
- **`state['joined']` 跨会话不复位**：第二次会话收到任意包就算"握手成功"，而 SUBSCRIBE/join 只在 CONNACK 分支里发
  → UI 显示"已连接 (MQTT)"却收不到消息、对端也看不到你。改成 `_session` 开头复位。
- **离开不发 leave**：对端"在线 N"永不减少、也没有"xx 离开了"。`leave()` 先发 `type=leave` 再关连接。
- **连接期间不禁用 昵称/房间/密钥**：`send()` 用实时控件值、会话用 join 快照，房间框被清空后密钥不一致 → 对端全是
  `[encrypted]`。`join()` 置 `disabled`、`leave()`/失败时恢复，`send()` 改用会话快照。
- **缺 `PERM='network'`**：`plugin_meta` 默认 `low` → 运行"聊天"**不弹联网确认**（§16 权限模型对它失效），版本列也空。
  补 `PERM/VERSION/AUTHOR`。

**C. hook / win / voice（6 项）**

- **语音热键的松键无条件被吞**：语音开着时普通 `V`、`Ctrl+V` 的 keyup 也被吞 → 应用收到 keydown 没有 keyup（V 卡住）。
  新增 `VOICE_DOWN` 只在"按下那次真被我们吞了"时才吞松键（探针伪造 lParam 验证四种情形）。
- **`_focus_edit_rect` 用线程本地的 `GetFocus()`**：拿到的要么是 NULL、要么是**自己窗口**（实测前台 msedge 时返回本进程
  隐藏窗坐标 (12,12)，候选条锚到自己身上）。改成用 `get_caret_pos()` 已算出的 GUITI `hwndFocus`（C# 从不用 GetFocus）。
- **`voice._cmd_recognize` 固定 utf-8 解子进程输出**：控制台程序按 OEM 代码页输出（中文机 GBK），中文识别结果变
  `????`/`\ufffd` 还当成功上屏。新增 `_decode_console()`：先 UTF-8，失败后在 OEM/ANSI/GBK 里挑"含 CJK 最多、含框线字符最少"
  的那个（cp437 硬解 GBK 会得到一堆 `─║╔`，GBK 解得汉字 —— 打分即可稳定选对）；顺带 `stt_cmd` 忘写 `{wav}` 现在直接报错
  （以前会把命令自己的输出当识别结果，静默成功）。
- **`hook.last_error()` 恒 0**：`ctypes.windll.user32` 不维护 ctypes 私有 last-error。`start()` 改用
  `WinDLL('user32', use_last_error=True)` 装钩子，并在别的 win32 调用之前取值（探针实测：windll=0 / 专用 WinDLL=87）。
- **`clipboard_set` 没有失败信号**：`paste_text` 不看结果就按 Ctrl+V → 剪贴板被占用时粘出**上一份内容**（静默上屏错字）。
  现在 `clipboard_set` 检查 `OpenClipboard`/`EmptyClipboard`/`SetClipboardData` 并返回 bool（失败时 `GlobalFree`，修了句柄泄漏），
  `paste_text` 写不进去就退回 `send_unicode`。
- **死状态/无界增长**：`_sys` 在 import 之前就被 `tray_promoted` 用（潜伏 NameError）→ 提到文件头；删掉恒 False 的
  `_uia_disabled`、只写不读的 `_ipc_started`；`_ipc_req_hwnd` 超过 64 条时回收已回包的条目（helper 卡住时原来只增不减）。

**D. clock / qr / calc（4 项）**

- **主时钟窗关掉后闹钟管理窗每次操作都抛 TclError**（`changed()` 指向已销毁控件）→ 包 try/except（与同文件另一处一致）。
- **二维码窗固定 884px 高**：1366×768/1280×800 小屏上底部四个按钮落在屏幕外，而 overrideredirect 窗不能缩放也不能滚动
  → 插件没法用。抽出 `calc_layout(screen_h)`：按可用屏高收缩窗口、下半部分上移、按钮贴底、卡片高度由"状态栏之上还剩多少"
  倒推（保证不压状态栏）。探针验 1080/900/864/800/768/600 六档：按钮底一律 ≤ 屏高、状态栏始终在卡片下方、大屏仍是原设计值。
- **「复制图片」的 CF_DIB 第 4 字节全 0**：32bpp BI_RGB 的 CF_DIB 在按 alpha 混合的应用（Word/PPT/浏览器）里会被当成
  **全透明** → 粘出来空白。写 CF_DIB 前统一置 `0xFF`（保存 PNG 那条路转 RGB8，不受影响）。
- **`calc._to_long` 与 C# 不同**：按用户"保持现状"，只在 docstring 写明是**有意差异**（csc unchecked 让 C# 的 `(long)` 对
  NaN/越界给 long.MinValue，`99999999999999999999 % 3` 在 C# 里是 -2 这种垃圾值；python 报 Err 更合理）——同时登记到 AGENTS §27。

**E. 两条产品决策（按用户要求）**

- **`hideidle=0`（候选条常驻）现在"拖动生效"**：`show_page` 原来每次刷新都传 `fixed='bottom-right'`，走"直接 geometry"
  分支，既不读 `pos.txt` 也不看拖动后的位置（而 `_drag_end` 照旧写 `pos.txt`）→ 拖走了下一次刷新弹回右下角。
  改成传 `fixed=None`，交给 bar 的"保持当前位置 + 越界才钳"分支（首次仍用 `pos.txt`/底部居中）。
- **hook 的两处差异保持现状**（Shift 轻拍的修饰键/0.4s 门控、字母键判定在空格之后），连同"python 有意比 C# 好的几处"
  一起写进 `AGENTS.md` §27 的反向差异清单，避免下一轮又被当 bug "对齐"掉。

**F. 语音真机验收（用户已把麦克风隐私改成 Allow）**

`%TEMP%\wg-r52-voice-probe.py` **7/7**：`mic_consent()='Allow'`、`waveInOpen` 成功、**真录 2 秒**（58452 B / 1.83s /
16k 单声道 16bit 的合法 WAV）、`system` 后端（System.Speech）真跑识别无异常、`recognize()` 正确派发。
本机是英文 Windows Server（无 zh-CN 语音包），录的是环境音所以识别结果为空 —— **中文识别质量仍需在中文机上验收**，
但"录音 → WAV → 引擎 → 回调"这条路已经实机打通（第五十一轮之前的 `waveInOpen rc=1` 是隐私开关导致，现已解决）。

**验证汇总**：`wg-r52-tools-probe.py` **11/11**（含真 Tk 窗驱动的删除用例）、`wg-r52-chat-probe.py` **13/13**
（同一探针跑 `HEAD` 版 chat.py 时 11 项 FAIL，A/B 对照成立）、`wg-r52-hookwin-probe.py` **24/24**、
`wg-r52-dprobe.py` **17/17**、`wg-r52-voice-probe.py` **7/7**；回归：`tests\pure-state-harness.py` **23 项全过**、
`undefined-globals.py` **0**、dist/package 逐字节同步、`wg-r50-lastpick 11/11`、`wg-r51-invariants 30/30`、
`wg-r51-cfg 16/16`、`wg-r51-plugins 12/12`、`wg-r50-package 3/3`。
**下一轮可做**：中文机上的语音识别质量验收、C# 侧的语音输入（需走 §3 的瘦 DLL + ps1 + 15 项测试链）。

---

## 2026-09-14 (第五十一轮: 全量功能/逻辑审计 —— 7 路并行审计 + 修掉 20 项确认缺陷)

用户要求："再 review 一下所有的功能、逻辑吧，我担心还有别的漏洞。"

做法：把 `wgime-py-pure` 的 10 个模块 + 5 个插件分成 7 份，各起一个只读审计 subagent（每份都要求
"精确到 `文件:行号` + 可复跑证据 + 区分'有意设计'与真 bug"，禁止改文件/启动真输入法/碰真实用户数据），
同时我自己跑横切检查（AST 结构体检、不变量探针）。**共 56 条候选，逐条复核后本轮修掉 20 项**（其余
按"低危/需产品决策/无法本机验证"记在 AGENTS-DETAIL §D5，留待后续）。

**A. 数据/内容类（会静默丢东西，最要紧）**

1. **`lastpick` 的 `\r` 累积已在第五十轮修掉**（本轮审计复核：`read_text` 的消费点全部干净）。
2. **用户词重启后丢五笔/简拼注册**（engine.py `_merge_user_words`）：只并了拼音表 + 重建 pk/pv，没并
   `wb`、没重建 `acro`。C# 的顺序是 `MergeUserWords(py) → MergeUserWordsWb(wb,CharWb) → BuildAcro(py)`。
   症状：造词「你好世界」→ 重启/导入码表后全拼能出、**简拼 nhsj 和五笔 wval 都查不到**。
   修法：按 C# 顺序补五笔注册 + 重建简拼，并把 `_init_state` 里"三张派生表"的构建提到合并用户词**之前**
   （合并要 `char_wb` 算构词码）。证据：审计探针由 `acro=[]/wb 无` → `acro=['nhsj']/wb 有/candidates('nhsj')=['你好世界']`。
3. **`clock.cfg` 读取失败被当成"没有闹钟"，下一次保存覆盖用户整份闹钟**（clock.py，**高危数据丢失**）：
   原来开头 `ALARMS.clear()` 再读，读失败（文件被独占/杀软扫描/GBK 另存/读到 C# 写一半的文件）就只剩"空"，
   而 `save_cfg` 是无条件落盘的 → 打开时钟点一下"新增/删除"就把闹钟全清。修法：**先读完再清空**，
   读不到就保持现状；回退解码改成 utf-8-sig→gbk→replace（docstring 早就承诺能读 GBK，实现却没做）。
4. **删除用户词的"幽灵词"**（engine.py 缓存签名）：`reload()` 会把已合并用户词的 py/wb 写进 `dict-cache.pkl`，
   而缓存签名原来只看码表（C# 的 md5 含 `uwF`）→ 删掉 `userwords.txt` 里的词后仍命中缓存，删不掉的词永远在候选里。
   修法：`cache_sig(dict_dir, data_dir)` 把 `userwords.txt` 的 (size, mtime) 也算进签名。
5. **`_write_config` 用严格 utf-8 读 config.txt**（main.py，**GBK 配置下所有开关一起炸**）：用户把 config.txt
   另存为 ANSI 后，任何写配置的开关都抛 `UnicodeDecodeError`（不是 OSError，`except OSError` 抓不到、pythonw
   下无声），值翻转了却不落盘、也轮不到第四十八轮加的失败气泡。修法：读改走 `read_text()`（同时保留"行尾跟
   原文件走"需要的原始 `\r\n`）。**顺带**：`_write_config` 现在保持文件原有行尾（对齐 C# `SaveConfigKey` 的 `nl`），
   出厂模板是 LF，以前翻一次开关就把整份配置改成 CRLF。
6. **`pywfreq.txt` 严格 utf-8 读且只 `except OSError`**：用户把语料另存成 ANSI → `UnicodeDecodeError` 穿到
   `Engine.__init__` → **启动直接崩**。修法：走 `read_text()`。
7. **`unlearn` 无条件 `lastpick.pop(code)`**：回滚旧学习会抹掉之后学的新词置顶。修法：只在
   `lb.get(code) == w` 时 pop。
8. **剪贴板历史窗口开着时不再实时刷新**（tools.py `_clip_poll`）：`after(0, _clip_refresh)` 传的是 **list**
   （刷新函数在 `[0]`），Tk 回调期抛 `TypeError` 且那个 try/except 在别的线程里抓不到。修法：取 `[0]` 再传。
   顺带给剪贴板窗口加**单例**（对齐 C# `ShowClip`）：以前开两个窗、关掉任一个就把 `_clip_win[0]` 清空，
   另一个还开着的窗从此完全不收集。
9. **多权限插件绕过确认框**（plugins.py `is_high_perm`，**权限模型失效**）：内置「剪贴板翻译」写的是
   `PERM = "network,run"`，而 `is_high_perm` 用整串 `in HIGH_PERM` 比对 → 判成低权限、**运行时不弹确认**
   （AGENTS-DETAIL §D3 明写它要弹）。修法：按 `[,\s|/+]+` 拆成集合求交。

**B. 卡死/资源类**

10. **Caret Helper 的 stdin 写入会永久冻死主线程**（win.py `request_caret_refresh`，**最严重**）：helper 是串行
    处理 stdin 的（一次 UIA 查询卡住就不读下一行），管道只有 ~4KB；`p.stdin.write(...)` 在第 45-65 个请求后
    阻塞并被 Tk 主线程调用（每键 `bar.show`）→ 输入法整体卡死、按键被吞没人处理、不可自愈。
    修法：**非阻塞写裸 fd**（`os.set_blocking(fd, False)` + `os.write`），管道满就丢掉这次刷新
    （光标跟随本就是 best-effort，下一键还会再来）。
11. **`_destroy_splash` 永远不会被调用**（main.py）：`root.after(120, _destroy_splash)` 在**注册时**就对
    5 行之后才定义的函数求值 → NameError 被 `except` 吞掉，隐藏的加载窗每进程漏一个 Toplevel。
    修法：`lambda: _destroy_splash()`（延迟求值）。
12. **`_bg_plugin` 兜底 + `[csharp]` 插件 txt 宽松读**（main.py）：`_run_csharp_plugin` 原来用严格 utf-8 读
    用户可写的插件 txt（§28 违规）→ ANSI 另存的插件"点了没反应"（裸线程里抛 UnicodeDecodeError，pythonw
    下 stdout/stderr 都是 None，什么也看不到）。修法：`read_text()` + 给后台插件线程加统一兜底（异常 → 气泡 + 日志）。
13. **反查表后台构建被重复并发启动**（engine.py `_invalidate_rev_wb` 顺手清 `_rev_thread`）：实测并发峰值 2。
    修法：失效不清 `_rev_thread`，worker 收尾只清自己那一格。**缓存写失败留下 ~95MB `.tmp`** 也在同一处修掉。
14. **`_save_cache` 失败不删 tmp**；**`_ipc_req_hwnd` 无界增长**（helper 不回包时）；**托盘换图失败没有任何
    always-on 记录**（`modify_ok` 只进 debug 日志）→ 新增 `win.dfn_always()`，换图失败写 always-on 日志。
15. **托盘 `_on` 包装没有 try/finally**：动作抛异常时 `_refresh()` 不执行、异常被 poll 的宽 except 吞掉
    （"点了没反应"且日志里查不到）。修法：try/except/finally + always-on 记录。

**C. 行为/一致类**

16. **托盘「模式→语音模式」没开语音**（main.py `set_mode`，第四十九轮只修了 Ctrl+` 那条路径）→ 候选条写着
    "按住 ctrl+alt+v 说话"但热键完全不响应。修法：抽 `_set_mode_from_tray()`，切到语音模式时 `_voice_set_on(True)`。
17. **语音待确认结果被 `poll()` 的 finally 立刻清掉 COMPOSING** → 识别完按空格只是给应用打个空格、
    Esc 无效、再按热键静默丢弃（表现为"时灵时不灵"）。修法：COMPOSING 的表达式加上 `_VOICE['text'] is not None`。
18. **`vf` 符号面板里按 `[`/`]` 把分类名/符号当汉字上屏并学词频**（C# 此时发 【/】）：补 `keys == "vf"` 门控。
19. **以词定字 (`[`/`]`) 三处与 C# 不一致**：学了单字而不是整词、没有动态候选门控、定字后没有联想。
    修法：学整词 + `dyn_set` 门控 + `begin_assoc(c)`。
20. **标点自动上屏不学联想 bigram、不推进 `last_commit`** → 下一次联想的"前词"错配（C# `RecordCommit`
    第一句就是 `LearnAssoc`）。修法：标点路径补 `learn_assoc(前词, top)` 并推进 `last_commit`。

**D. 其他同批修掉的（低危但都是真缺陷）**

- 托盘图标索引写死 `% 4`（模式表有 5 项）→「语音模式」的图标与「混合」一模一样；构建脚本预渲的 `'4a'/'4i'` 是 `'0a'/'0i'` 的复制品。改 `% len(MODE_CHARS)`。
- 候选条退化到最小截断（8 字）仍超宽时窗口被硬钳、尾部候选被裁掉；把截断下限放到 4 字（§15 的"全部候选可见"在词典长候选下更接近成立）。
- 非跟随模式用**主屏**工作区钳制 → 拖到副屏的候选条被拉回主屏；改用 `win.workarea_at(候选条中心)`。
- 换主题只改 alpha 不重绘（底色/文字要等下一次按键）；`ui.font()` 每次枚举全系统字体（实测 0.8ms/次）；`plugin_dir`/`voice_state` 是没人用的 api 项。
- 插件：`[csharp]`/`[python]` 标签不锚定行（注释里写一对标签就能把插件类型从 steps 改成 csharp 并执行标签间的文字）；闭标签大小写敏感（`[PS]…[/PS]` 整块被跳过）；`load_tools` 不记多行块状态（块内 `[CmdletBinding()]` 变假按钮、`code=` 被吞、注释丢失）；动词只按空格切（tab 行整行当动词）；`kill` 无 psutil 回退时对不存在的进程也报 `killed 1`；`reg-del` 删不存在的键记失败（C# 静默成功）。
- 工具：DNS 名解析的自指压缩指针死循环（守护线程 100% CPU 永不返回）；造词手填编码不过 `valid_code`（`a b` 会污染 userwords.txt）；子网"地址类型"看网络地址而非输入地址（`192.168.1.1/8` 判成"公网"）；时钟"分"输入接受 nan/inf/1e999 → tick 每 100ms 抛异常被吞、秒表/番茄一起冻结。
- main：`poll()` 第一拍就 `import tray`（~128ms），抢在刻意推迟到 150ms 的托盘装载之前 → 启动首键被压；被"停用"的 .py 插件在判断禁用**之前**就 `exec_module`（模块级副作用照跑）；`_with_code`、`_HALF_PUNCT[(0x34, False)]` 死代码；`_save_assoc` 是死代码（联想落盘只有 `save_freq` 一处）。

**验证**（全部真跑，隔离 `LOCALAPPDATA`）：

- `%TEMP%\wg-r50-lastpick-probe.py` **11/11**、`wg-r51-invariants-probe.py` **30/30**（托盘写的 11 个
  config 键都被 load_config 认、模板 35 键全认、tray 引用的 48 个 api 键全存在、5 张模式表长度一致、
  22 个键真跑"改了确实生效"）、`wg-r51-cfg-probe.py` **16/16**（LF/CRLF 行尾保持、写失败返回 False +
  bubble、9 个 toggle 都处理写失败）、`wg-r51-plugins-probe.py` **12/12**、`wg-r50-package-probe.py` **3/3**
  （直接从成品单文件里内嵌的 engine 源码跑）、`wg-r51-f1-ab.py`（HEAD 抛 UnicodeDecodeError / 修后正常 +
  `_bg_plugin` 把线程异常转成气泡）。
- 审计方自己的探针复跑：engine（用户词五笔/简拼、缓存签名、GBK pywfreq、unlearn、rev_wb 并发）、
  tray 图标 `%4`、bar 宽度、plugins perm/标签/块、tools 剪贴板/DNS、clock 覆盖/nan。
- `tests\pure-state-harness.py` **23 项全过**（新增 5 项：LF/CRLF 配置写回、写失败要通知、GBK 插件 txt 不抛、
  lastpick 的 2 项）、`undefined-globals.py` = **0**、dist/package 逐字节同步 OK。

**本轮未修（已记录，见 AGENTS-DETAIL §D5）**：用户词表二次删除下标错位、取色器/插件管理器单例、
中文 Windows 的 ping RTT/tracert 文案、chat 的 6 项（重连并发/空闲超时/send 门控/joined 复位/离开不通知/
输入框不禁用）、calc `_to_long` 的 unchecked 语义、hook 语音 keyup 无条件吞、`_focus_edit_rect` 用 `GetFocus`、
`voice._cmd_recognize` 的 OEM 解码、hook `last_error()` 恒 0、clipboard_set 无失败信号。

---

## 2026-09-14 (第五十轮: 修 `lastpick_*.txt` 的 `\r` 累积 —— "上次选的词置顶"一直在静默失效)

用户反馈："`lastpick_mix.txt` 这个文件好像有点诡异哦。"

实测现场文件（`%LOCALAPPDATA%\wgime-py\lastpick_mix.txt`，1375 B / 68 条）：`bm 出\r\r\r\r\r\r\r\r\r\r\r\r`
—— 每个词后面挂着一串**裸 CR**（最老的 12 个，新的 3~11 个递减），而 C# 侧同名文件字节干净
（`bm 出\r\n`，293 行 / 3302 B）。

**根因**：`engine._load_freq` 读 lastpick 用 `read_text(p).split('\n')` 切行，值只 `rstrip('\n')`。
但 `read_text` 是**二进制读 + 解码**（为兼容记事本"另存 ANSI"，AGENTS §28），**不做 universal newlines**，
于是 CRLF 的行尾 `\r` 原样进了值；写盘时 `open(...,'w')` 又把 `\n` 翻成 `\r\n` ——
**每轮"载入/存盘"就长一个 `\r`**（探针实测 17 → 19 字节/轮，与文件里 3~12 个递减的 CR 完全吻合）。

**真危害不是文件难看**：`candidates()` 的 LastPick 置顶是
`lp = self.lastpick_m[mode].get(keys); if lp and lp in cands` 的**字符串比较** —— 值带 `\r` 时永远不相等，
"上次选的词置顶"（§14 的 learn/LastPick 机制）**静默失效**；同时 python/C# 的 lastpick "同格式可互换"被破坏。

**修法**（`engine.py`）：`_load_freq` 的两个解析点都先 `line = line.rstrip('\r')` 再找分隔符
（userdict 那处原来是**无效的** `line.rstrip('\n')`，因为行已经按 `\n` 切过了，一并纠正）。
写盘仍保持 CRLF（与 C# `File.WriteAllLines` 一致），只是值里不再夹 `\r`；
**用户已有的脏文件会在下次载入/存盘时自动痊愈**（载入时值就干净了，存盘会重写整份文件）。

**验证**：`%TEMP%\wg-r50-lastpick-probe.py`（修前 **5 通过 / 4 失败** → 修后 **11/11**）：

- A 载入 C# 风格 CRLF 时键、值都不带 `\r`（修前 `bm -> '出\r'`）；
- B 一轮往返字节数不变（修后 15→15；修前 17→19，值 `'出\r'`→`'出\r\r'`）；
- C 值带 `\r` 时置顶失效 / 干净值置顶生效（`['办','出']` vs `['出','办']`）；
- D 对照组：userdict（值是 int）本来就不受影响；
- E 现场那种 12 个 CR 的脏文件，载入后值 = `出`，存盘后 = `bm 出\r\n`（痊愈）。

**永久回归**：`tests\pure-state-harness.py` 新增 2 项（16 项 → **18 项**）：CRLF 的
`lastpick_mix.txt` 载入后值不带 `\r`，且**非首位**的"上次选的词"仍被置顶（故意挑第 2 个候选，只有置顶生效才会跑到第一）。
回归：`undefined-globals` **0**、dist/package 同步 **OK**（10 模块 + main.py 逐字节一致）。

---

## 2026-09-12 (第四十九轮: 「语音」模式与「语音输入」选项不再打架 —— 切模式就等于开启)

用户反馈："你这是搞了两个菜单啊？**mode 里的变动没任何作用，option 菜单里的才开启**"。

原因很清楚：托盘「模式」子菜单里的那项只切了 `ime.mode = 4`（语音模式），**没开 `voice`**；真正打开语音功能的是
「选项」里的「语音输入」。于是切到语音模式后按热键，得到的是"语音输入没打开"的气泡 —— 看起来就是"点了没用"。

**修法（让两处一致 + 名字区分开）**：

- **切到「语音」模式 = 顺手把语音功能打开**（幂等；托盘「模式→语音模式」和 `Ctrl+`` 切过去都算），
  并给一条气泡「语音已打开: 按住 ctrl+alt+v 说话」；没麦克风时给可照做的提示。
- **离开语音模式不关功能**（热键在任何模式下都能用，这是第四十七轮定的）；再去切语音模式是幂等的，不会重复提示。
- **「选项→语音输入」关掉语音时**，如果正处在语音模式就**自动切回混合模式**，不把人留在"语音模式"里干瞪眼；
  打开时只开功能、**不动当前模式**。
- **菜单名字区分**：模式子菜单里显示「**语音模式**」（内部名/候选条仍是「语音」，与 C# 模式名一致），
  选项里显示「**语音输入 (总开关, Ctrl+Alt+V 按住说话)**」——不再两个都叫"语音"。
- 实现上抽了 `_voice_set_on(on, why)`: 托盘选项、模式切换、幂等检查都走它，状态不会再各说各话。

**验证**：`%TEMP%\wg-r49-menu-probe.py`（真实 dist，**14/14**）：

- 模式子菜单第 5 项 = 「语音模式」、内部 `MODE_NAMES[4]` 仍 = 「语音」；
- `Ctrl+`` 切到语音模式 → `CFG.voice=True` + `hook.VOICE_ON=True` + **落盘 `voice = 1`** + 有气泡；
- 离开模式后功能仍开着；重复打开是幂等的（不重复提示）；
- 选项关掉 → `voice=False` + **自动切回混合模式** + 落盘 `voice = 0`；选项打开 → 只开功能、模式不变。
- 回归：harness 16/16、r48 23/23、r47 A15/15+B20/20、r46 11/11。

---

## 2026-09-12 (第四十八轮: 修"托盘开关点了 config.txt 不变" —— `_write_config` 静默失败 + 热键门控)

用户实测反馈：托盘「语音输入」切不动、**切换后 `config.txt` 没变**；同时按 Ctrl+Alt+V 弹出"语音输入没打开"的气泡。

**根因 ①（影响所有托盘开关，不只语音）**：`_write_config()` 里 `APP_DIR\config.txt` **不存在**时 `open()` 直接抛
`FileNotFoundError`，而 `except OSError: pass` 把错误**静默吞掉** —— python 版可以**不带 config.txt** 跑
（默认值都在代码里），于是这种部署里每个托盘开关都"点了不落盘"。修法：文件不存在就**新建**一个；
`_write_config` 返回 `True/False`；写失败写 **always-on 日志**，语音开关还会弹气泡告知 `config.txt` 的完整路径。

**根因 ②**：hook 里 Ctrl+Alt+V 的**按下**没看 `VOICE_ON` —— 语音没开时也吞键并弹"没打开"气泡（就是截图那个）。
修法：**语音没开时这条热键完全不拦**（透传给应用），开着时才吞、才报松键。

**改动**：`main.py`（`_write_config` 新建 + 返回值 + 日志；`toggle_voice` 写入失败要给气泡）、
`hook.py`（voice 热键按 `VOICE_ON` 门控）。

**验证**：`%TEMP%\wg-r48-traytoggle-probe.py` **23/23** ——

- 伪造 lParam 直接调 `hook._proc` 的判定矩阵：语音关 → `Ctrl+Alt+V` **透传且不产生事件**；语音开 → **吞 + `VK_VOICE`**；松键 → `VK_VOICE_UP`；语音关时松键也不吞；
- `toggle_voice()` 三处状态一致（`CFG` / `hook.VOICE_ON` / `config.txt`），并有"已打开…(已写入 config.txt)"气泡；
- **把 `config.txt` 挪走后 `_write_config` 仍返回 True 并自动建文件**（这条正是用户踩的坑）；
- 托盘 `TRAY_Q` 路径（点击 → 队列 → 主线程执行）确实会执行开关。
- 回归：harness 16/16、r47 **A 15/15 + B 20/20**、r46 11/11、r45 40/40、r45-onlytrans 12/12、r44 40/40、
  r43-e2e 4/4、r40 35/35、warmec 40、QR 78、`undefined-globals` 0、dist 自检逐字节一致。

> 提示：python 版的配置**就在 `wgime-py.py` 旁边**（`APP_DIR\config.txt`，`APP_DIR` 由 `dicts\` 的位置推出来）；
> 仓库根目录那份 `config.txt` 只是**模板**，改它不影响正在跑的实例。

---

## 2026-09-12 (第四十七轮: 语音输入 —— 按住 Ctrl+Alt+V 说话, 三条识别后端 + 新增「语音」模式)

用户问"有没有机会加语音输入"，定了：**先打通系统自带离线引擎 + 预留云端/本地 whisper 插槽**，
**热键和语音模式都要**。

### 形态

- **热键** `hotkey_voice = ctrl+alt+v`：**按住说话**（松键在 hook 里收 `WM_KEYUP` → `VK_VOICE_UP`），松开即识别。
- **「语音」模式**（`Ctrl+`` 切到第 5 个，托盘图标紫色「语」）：**不组字**（按键一律透传给应用），候选条当状态灯用；
  该模式下热键变成「轻点开始 / 再点结束」（常录），说话停顿 `voice_silence` 秒也会自动停。
- 识别结果默认**进候选条等空格确认**（`1.<文本>`；空格/回车/1 上屏，Esc 丢弃）；`voice_auto = 1` 时直接上屏。
  上屏走现有 `inject()`（剪贴板/keyfix/UIPI/简繁全兼容），**不进词频学习/联想**（整句不该被当词学）。
- 没麦克风/没装语音包/识别失败 → **托盘气泡**说清（含"去开哪一项"）；状态显示在候选条第 2 段（`正在听… (3s) 松开结束` / `识别中…`）。

### 录音 + 识别（`voice.py`，新模块）

- **录音**：`winmm` waveIn，**纯 ctypes**，16kHz/单声道/16bit，8 块 200ms 轮转；回调里算 RMS 做 **VAD 静音自动停**
  （头 500ms 估环境噪声 → 自适应阈值）与单次上限（`voice_max`）；不用 `audioop`（3.13 起已移除，用 `array` 自己算）。
- **`system`**（默认）：系统自带离线引擎（System.Speech），经 `powershell -EncodedCommand` **内联脚本**调用
  （**不落盘任何文件** —— 照第四十三轮 caret-helper 的规矩），结果用 **base64** 回传（绕开控制台代码页乱码）；
  `voice_lang` 选识别引擎，没装对应语言包时给**可照做的安装提示**。
- **`http`**：OpenAI Whisper 兼容的 multipart POST（`stt_url` / `stt_key` / `stt_model` / `stt_lang`）。
- **`cmd`**：`stt_cmd` 里用 `{wav}` 占位，取 stdout 第一行（本地 whisper.cpp / faster-whisper 等）。
- 换后端只改 `voice_engine` 一个键：录音/上屏/交互完全共用，`recognize()` 里一个分支的事。

### 改动清单

`voice.py`（新）· `hook.py`（`hotkey_voice` + `WM_KEYUP` 松键 + `VOICE_ON`/`VOICE_MODE` 标志 + 语音模式按键透传）·
`main.py`（`_VOICE` 状态机 + `voice_down/up/finish/cancel/commit` + 后台识别线程 + `VOICE_Q` 主线程派发 +
`show_page` 状态/待确认 + `handle` 分支 + 模式 5 个 + 托盘 api）· `engine.py`（config 键）·
`tray.py`（5 模式 + 「语音输入」选项）· `build-wgime-pure.py`（MODULES 加 voice；图标按 `MODE_CHARS` 走 = **11 个**）·
`config.txt`（`voice*` / `stt*` 说明）。

### 验证（本机 Windows Server 2025：只有 en-US 引擎，且麦克风隐私开关 = **Deny** —— 反倒把错误路径验透了）

- `%TEMP%\wg-r47-voice-probe.py`（**A 15/15 + B 20/20**）：
  - **真端到端识别**：系统 TTS 生成 "hello world this is a voice test" 的 WAV → `system` 后端识别回来**逐字符一致**，0.7–0.8s；
  - 没装 zh-CN 时报出「装一下语言包 + `Add-WindowsCapability -Online -Name Language.Speech~~~zh-CN~0.0.1.0`」；
  - 隐私开关 Deny 时 `waveInOpen` 失败 → 错误信息**直指 设置→隐私和安全性→麦克风→允许桌面应用访问麦克风**；
  - `cmd` / `http` 后端的成功与"没配某键"两条路径；WAV 头 / RMS 数值正确；
  - dist 集成：模式 5 个、内嵌图标 11 个、**按住说话**与**轻点常录**两种交互、待确认→空格上屏、`voice_auto` 直接上屏、报错不崩。
- 回归：harness 16/16、`undefined-globals` 0、dist 自检逐字节一致、r45 40/40、r45-onlytrans 12/12、r46 11/11、
  r44 40/40、r43-e2e 4/4、r40 35/35、warmec 40、缓存 14、QR 78、wgtranslate 62。
- **本机没法真录中文**（麦克风被隐私开关挡着，且只有 en-US 引擎）。你那边要先做两件事：
  ① 允许桌面应用访问麦克风；② 装中文语音包（`Add-WindowsCapability -Online -Name Language.Speech~~~zh-CN~0.0.1.0`，
  或 设置→时间和语言→语言和区域→中文(简体)→语言选项→语音）。装好后 `voice_lang = zh-CN` 即可说中文。

---

## 2026-09-12 (第四十六轮: 「词典/译」模式加回来 —— 英中查询还是这个模式顺手)

用户反馈："译模式看来还要加回来，因为有些查询还是译模式更加方便(英中)"。**加回**，同时**保留**第四十四轮的
「译文」选项 —— 两套东西各管一段，互不冲突：

- 模式循环回到 **4 个**：`混合 / 拼音 / 五笔 / 词典`（`MODE_NAMES`、`% 4`、托盘模式子菜单 `range(4)`、
  托盘图标 `MODE_CHARS/MODE_COLORS` 4 项、构建时预渲染 ICO 回到 **9 个**）。
- 词典模式（3）里**打英文出中文**（`ec` 精确 + 前缀）、**打拼音出英文**（`ce` 反查）：想逐条翻看中文释义就切到它；
  日常打字仍用「译文」选项挂提示/兜底，不必为查一个词切模式。
- 词典模式**不再叠挂 `→英文`**（候选本身就是译文，第四十三轮的判断继续生效）；**反查编码在词典模式照旧显示**
  （对齐 C#：其余模式显五笔码）。
- 第四十五轮的译文质量改进（英语常用词表排序/过滤）与候选条逐级退化全部保留 —— 词典模式里的 `ce` 反查因此也更干净。

### 验证

`%TEMP%\wg-r46-dictmode-probe.py`（真实 dist，**11/11**）：MODE_NAMES 4 个、`Ctrl+`` 循环 `1,2,3,0,1`、
内嵌托盘图标 9 个、词典模式 `hello→嘿/您好/哈罗…`、`test→…测试…`、`nihao→你好（中文拼音）/hola…`、
词典模式不挂 `→英文` 但 `(码)` 照旧、拼音模式 `你好→hola` 与"零候选兜底"不变。
回归：r45 探针 39/39、r45-onlytrans 12/12、r44 40/40、harness 16/16、`undefined-globals` 0、
dist 自检逐字节一致、r40 35/35、warmec 40、缓存 14、QR 78、wgtranslate 62、r43-e2e 4/4。

---

## 2026-09-12 (第四十五轮: 译文质量 —— 装英语常用词表重排反查；候选条不再把提示切一半)

用户看完第四十四轮的实测截图说"**不太妙**"，并选了"**换一个可靠的离线中英词库再挂**"，同时报了一个
"**单开译文出不来，必须同时开反查才行**"。三件事都查清并修了。

### ① 候选条 `测试 (imya…` 的真相：提示被均匀切了一半（不是译文造成的）

按 9 个候选/页、真实字体实测（`max_w=880`）：

| 配置 | 需要宽度 | 实际显示 |
|---|---|---|
| showcode=0 | 676px | `测试 测度 清风亮节 …` ✓ |
| **showcode=1（出厂默认）** | **1099px > 880** | **`测试 (imya…` `清风亮节 (im…`** |
| showcode=1 + 译文 | 1099px | 与上一行**完全相同**（译文被切掉了，等于没开） |

旧裁剪是"整串按 24→8 字符均匀砍 + 省略号"，于是**提示横跨一刀**：编码剩半截、译文一个字看不见。
**修法**（`bar.py` + `main._cand_variants`）：候选改成 `(词, 全提示, 只译文提示)` 三元组，裁剪时
**逐级丢提示、绝不切半截**：tier0 每条都挂 `词 (码)→译` → tier1 **只给当前选中那条挂**（其余只显示词）
→ tier2 每条只挂译文 → tier3 只剩词；只有"词"本身太长才截词。实测（同一页 9 个候选）：

- `imya` + 反查 + 译文 → `1.测试 (imya)→test  2.测度  3.清风亮节 …`（译文看得见、无半截提示）
- `imya` + 只反查 → `1.测试 (imya)  2.测度 …`（选中那条的编码保住了）
- `wq` + 只反查 → **与以前完全一样**（`1.你 (wq) 2.像 (wqj) …`，这页装得下就不动）

### ② 反查译文的数据源：词典里"字母序第一个"全是生僻词

`ce` 由 `ec.txt`（65.7 万条 EN->CN，混着缩写/人名/技术词）反建，旧代码取字母序第一个，实测：
`测试→dvdram`、`你好→alohas`、`中国→cathay`、`我们→kinghan`、`老师→dorina`、`电脑→autoinstall`。
**修法**：装一份 **MIT 的英语常用词表**（`en-freq.txt` = Hermit Dave FrequencyWords `en_50k`
5 万词 + 频次，622KB，随分发目录一起发）——反建时 ① 按**英语常用度**排序；② **不常用的候选直接丢**，
一个中文词只有在"至少有一个常用英语词"时才进 `ce`（查不到就不挂，免得又冒 `whiches`/`cujus`/`kiped`）。
实测（常用中文词样本）：

- 译文质量：常用英语词命中率 **30.6% → 66.1%**（前 3000 个常用词），`测试→test`、`中国→china`、
  `我们→we`、`老师→teacher`、`电脑→computer`、`谢谢→thank`、`问题→problem`、`数据→data`、`电影→movie`；
- `时候→whens`、`这个→whiches`、`测度→meterages`、`手机→handphone`（都不在常用表里）→ **宁可不挂**；
- 英→中方向（打英文出中文：`test→测试`、`hello→嘿`）不受影响，仍然是可靠的那一半。

### ③ "单开译文出不来"——复现不了，多半是跑着旧文件

端到端复现（真实 dist，四种开关组合 × 5 组输入）：**只开译文（showcode=0）时译文正常显示**
（`nihao→你好→hola`、`hello→嘿` 兜底也在）；托盘点开「译文」也一样。反查与译文从第四十四轮起就是
**两个独立开关**，不存在"必须先开反查"。为免再出现"拿旧单文件测新功能"，本轮加了：
**`VERSION`**（单文件唯一版本标识，写进启动 always-on 日志）+ 打开/关闭「译文」时记录
`ec_ready/ec_fail/en_rank`，词典表没就绪/读不出来时**弹托盘气泡**说明（而不是静默什么都不显示）。

### 改动清单

- `en-freq.txt`（新，622KB，MIT，见 `docs\WGIME_使用说明.md` 的版权说明）+ `sync-dist.ps1` /
  `build-package.ps1` 纳入同步与打包。
- `engine.py`：`load_en_rank()`（读不到就退回旧行为，并在 stderr 说明）、`build_reverse(ec, ranks)`
  （排序 + 过滤，`EN_HINT_MAX_RANK=50000` 可调）、`build_reverse_legacy()`（对照探针用）、
  `en-freq.txt` 进 `CACHE_FILES`（换词表 -> `ce` 自动重排）。
- `main.py`：`_cand_variants()` 三元组（`_with_code` 仍是完整串，对外不变）、`show_page()` 传三元组、
  `VERSION` + 启动日志、`toggle_trans()` 的诊断气泡/日志。
- `bar.py`：四级退化裁剪（去掉只给部分候选用的 `clip()` 局部函数）。

### 验证

- `%TEMP%\wg-r45-verify-probe.py`（**39/39**，真词库 + 真 Tk 字体）：18 组译文样本（含"必须不挂"的
  6 组）、`en-freq.txt` 5 万词、`_cand_variants` 形态、5 组渲染用例**逐字符对照"bar 允许画出的所有形态"**
  （证明无半截提示）+ 候选条宽 ≤ 880。
- `%TEMP%\wg-r45-onlytrans-probe.py`（真实 dist，**12/12**）：四种开关组合下译文/兜底的显示；
  只开译文（含托盘 `toggle_trans`）能看到 `→译文`。
- 回归：harness 16/16、`undefined-globals` 0、dist 自检 9 模块 + main.py 逐字节一致、r40 自检 35/35、
  warmec 40、缓存 14、QR 78、wgtranslate 62、r44 40/40、r43-e2e 4/4。
- **一次性代价**：`en-freq.txt` 进了缓存签名 -> 老缓存失效，升级后**第一次启动**要重建索引
  （实测本机 10-12s，之后回到热启动 1s 级）。

---

## 2026-09-12 (第四十四轮: 取消「译/词典」模式 —— 译文改成「译文」选项，顺手给输入法用户查译)

用户提出：译模式（mode 3，菜单里叫「词典」）要 Ctrl+` 连切 3 下才到、只认词典固定词条，对**输入法用户**太别扭
（"正常打字的人根本不会为查个词去切模式"）；问能不能把译文**并进候选显示**、再像「繁体输出」那样做成一个选项。**采纳**。

### 方案：模式回到 3 个，"译文"独立成选项

1. **模式循环 4 → 3**：只剩 `混合 / 拼音 / 五笔`（`MODE_NAMES`、`ime.mode = (ime.mode + 1) % 3`、托盘模式子菜单
   `range(3)`、托盘图标 `MODE_CHARS/MODE_COLORS` 3 项、构建时预渲染 ICO 9 → **7 个**）。C# 的第 4 个模式
   `3=词典` python 侧不再对外暴露（`engine.candidates(mode=3)` 的词典管线**保留**，改由下面的选项调用）。
2. **新增选项「译文」**（托盘「选项」菜单，紧挨「繁体输出」；`config.txt` 键 `trans`，白名单语义同
   `showcode`/`trad`，**出厂默认开**）。打开后管两件事，都是**纯离线**（现成的 70 万词条 `ec`/`ce` 表，零联网）：

   | 打字 | 做的事 | 例子 |
   |---|---|---|
   | 有候选 | 每个候选后面挂**词典译文**（中文→英文 `ce`，英文→中文 `ec`） | `nihao` → `你好 (wqvb)→alohas` |
   | **一个候选都没有** | 补一次词典查询兜底，**打英文直接出中文** | `hello` → `嘿` |

   兜底只在"本模式零候选"时触发 —— 所以**绝不会顶掉真正的拼音候选**（AGENTS §22 的教训：拼音模式无条件查 `ec`
   会让打 `no`/`shi` 串进"不/没有"；这里 `nihao` 有拼音候选 → 根本不查 `ec`）。
3. **反查编码 (`showcode`) 与译文 (`trans`) 是两个互不干扰的开关**，只影响显示，都开时叠成 `词 (码)→译文`。

| showcode | trans | `_with_code('你好')` |
|---|---|---|
| 0 | 0 | `你好` |
| 1 | 0 | `你好 (wqvb)` |
| 0 | 1 | `你好→alohas` |
| 1 | 1 | `你好 (wqvb)→alohas` |

- 查不到就不挂（`translate_hint` 返回 `None`）；**单字不挂**（防噪音）；词典表没就绪（后台还在加载）返回 `None`，
  **绝不阻塞输入路径**。

### 改动

- `engine.py`：新增 `Engine.translate_hint(w)`（中文词 ≥2 字 → `ce`，英文词 ≥2 字母 → `ec`，取第一个义项）；
  `load_config` 新增 `trans` 键（缺省 True，白名单 `1/on/true`，与 C# 的 `v == "1" || …` 大小写敏感逐字对齐）。
- `main.py`：`_with_code(w)` 按两个开关独立叠加；`show_page()` 的门控改成 `showcode or trans`；
  `refresh()` 加"零候选才补词典"的兜底（`not cands and not exact_wubi` —— 五笔精确码命中时绝不掺词典词，
  免得动到"唯一四码自动上屏"的判定）；`toggle_trans()` 写回 config + 预热词典表；托盘 api 加
  `toggletrans`/`get_trans`（成对，勾选态是活状态）。
- `tray.py`：模式表 4 → 3 项（含 `% 4` → `% 3` 三处、图标 key）；「选项」菜单新增「译文 / Translation」。
- `config.txt`：`showcode = 1` 下面加一行 `; trans: …` + `trans = 1`（C# 版 `LoadConfig` 忽略未知键、
  `SaveConfigKey` 保留其它键与注释，所以两版共用同一份 config.txt 不冲突）。
- `build-wgime-pure.py`：托盘 ICO 预渲染 `range(4)` → `range(3)`（内嵌 **7 个** ICO / 3.7 KB base64）。
- **本轮只改 python 版**（C# 版仍保留 `3=词典` 模式；按 AGENTS §27，要往 C# 补需用户明确要求）。

### 验证

- `%TEMP%\wg-r44-trans-probe.py`（**40/40**，A 段源码级 + B 段真实 dist 端到端）：
  `trans` 配置 14 组取值（缺省/无空格/键名大小写/值大小写敏感/非法值判关）、模式循环 `1,2,0,1`（无第 4 模式）、
  词典表未就绪 → `None`、`你好→alohas` / `hello→嘿` / 单字与查不到 → `None`、
  `_with_code` 四种组合逐字符相等、拼音候选不被顶掉（`nihao` 首候选 `你好`；`no` 首候选仍是拼音字，无"不/没有"）、
  `hello` 兜底出候选且候选条带 `→嘿`、`trans=0` 时兜底不生效、`toggle_trans` 翻转 + 落盘（保留其它键）、
  托盘 `get_trans` 存在。
- 回归全绿：`tests\pure-state-harness.py` 16/16、`undefined-globals.py` 0 处、dist 自检（9 模块 + main.py 逐字节一致）、
  r40 自检 35/35、split-cache 40、缓存 14、QR 78、wgtranslate 62、r43 两个探针照旧通过。

---

## 2026-09-11 (第四十三轮: caret-helper 不再落盘 —— 改用 `python -c` 内联源码)

用户反馈：跟随 helper 会在磁盘上生成一个 `caret-helper` 文件，能不能合并掉、不要"产生新的 caret-helper"。

**改法（保留独立子进程做崩溃隔离，只去掉落盘）**：`win.py` 的 helper 源码（`_EMBEDDED_CARET_HELPER`，7200 字符）
不再写进 `%LOCALAPPDATA%\wgime-py\runtime\caret-helper\wgime-caret-helper-v3-stable-embedded.py`，
改成 `subprocess.Popen([sys.executable,'-u','-c',src])` **内联**传给子进程 —— 磁盘上不再产生任何 caret-helper 文件，
UIA 仍在子进程里（provider 崩溃拖不垮键盘钩子这条不动）。

- **容量/可行性**：7200 字符 << Windows 命令行上限 32767；helper 不引用 `__file__`/`sys.argv`/`sys.path`，
  `if __name__=='__main__'` 在 `-c` 下成立。
- **隔离要保住**：`-c` 下 `sys.path[0]` 是**当前工作目录**（不再是脚本目录），所以源码开头加 `_HELPER_PATH_SANITIZE`
  把 `''`/`.`/cwd 从 `sys.path` 剥掉 —— 维持第三十八轮那条"标准库不被 pythonnet 残留抢占"的隔离（helper 只用标准库）。
- **遗留清理**：`ensure_caret_bg()` 启动时 best-effort 删掉旧版落盘的那个 .py（只删这一个确切文件名，失败无妨）。
- **实测**：内联 `-c` spawn → **137ms** 出 `ready`，请求往返 **33ms**，进程稳定存活、stderr 干净；
  端到端（隔离 `LOCALAPPDATA`）：旧文件被清掉、helper 存活、数据目录下 **0 个 .py 产物**。
- **回归**：`tests\pure-state-harness.py` **16/16 全通过**（exit 0）、`wgime-py-pure\tests\undefined-globals.py` **0**；
  `dist\wgime-py.py` 重建（752.0 KB，内嵌 84 个第三方模块），已核对旧 `path=_helper_path()` 路径彻底消失。
- 文档同步：AGENTS §17、`docs\WGIME_技术文档.md`（+release 副本）。

---

## 2026-09-11 (第四十二轮: 托盘图标"个别机器"的真凶 —— 宿主没装 Pillow；单文件改为内嵌预渲染图标)

第四十一轮加的自检直接把答案报了出来（用户那台机器的弹框 + `debug.log`）：

```
NIM_ADD: None
python: C:\Users\WALLIANG\AppData\Local\Programs\Python\Python314\pythonw.exe
控制台: no(pythonw)
原因: pystray/PIL 导入失败:
      File "tray.py", line 31, in <module>
      ModuleNotFoundError: No module named 'PIL'
```

**根因**：python 版的托盘图标是**运行时用 Pillow 现画**的（`from PIL import Image, ImageDraw, ImageFont`），
而**单文件只内嵌了 comtypes/uiautomation/pystray，没有内嵌 Pillow**（Pillow 带编译扩展 `_imaging.pyd`，
按 Python ABI 绑定，内嵌源码也跨版本用不了）。所以：

* 机器上装了 Pillow → 有托盘图标（我们开发机就是这样，一路没发现）；
* 机器上只有官方 Python、没装 Pillow → `import PIL` 失败 → **整个托盘没了**；
* 而"`python wgime-py.py` 却正常"是因为 PATH 上那个 `python` 恰好是装了 Pillow 的另一个版本 ——
  与双击用的 Python 3.14 不是同一个解释器。**"只有个别机器"= 只有没装 Pillow 的机器**。

**修法（第四十二轮）**：把托盘图标**在构建时**用 Pillow 画好，存成 9 个 ICO（4 模式 × 开/关 + 工具模式，
共 5.2 KB base64）内嵌进单文件；运行时只把 ICO 写进 `%LOCALAPPDATA%\wgime-py\runtime\icons\` 再
`LoadImage` 成 HICON，**完全不再需要宿主装 Pillow**：

* `build-wgime-pure.py`：构建时调 `tray._icon_img/_tool_icon_img` 渲染 → `TRAY_ICONS`（base64 ICO 字典）写进单文件；
* `win.py`：新增 `icon_from_ico_bytes()`（写文件 + `LoadImageW(IMAGE_ICON, LR_LOADFROMFILE)`）；
* `tray.py`：`HAS_PIL` 变成**可选**（`import pystray` 本身不需要 PIL，只有"设图像"那一步才要 ——
  我们直接把 HICON 塞给 pystray，绕过它的 PIL 序列化），图标切换走 `NIM_MODIFY | NIF_ICON`；
  没有内嵌图标（源码布局运行）时才回退到 PIL；两者都没有才报"缺 Pillow"并弹框。

**顺带修掉一个自己引入的错**：切模式换图标那段日志里用了未定义的 `key`（NameError 被
`except Exception: pass` 吞掉，所以"换了图但没日志"，看起来像没换）。现在换成内联 key，
`tests\undefined-globals.py` 也复查过 0 处。

### 验证（都用真实 `pythonw.exe` + DETACHED、无控制台、与双击同条件）

| 场景 | 结果 |
|---|---|
| 内嵌图标 + **假 PIL**（PYTHONPATH 放一个 import 就抛 ImportError 的 `PIL.py`，复现用户机器） | `tray start ok=True`、`tray selfcheck: nim_add=True`、不弹框 |
| 内嵌图标 + 假 PIL + 切模式 | `tray _refresh embedded mode=1 … hicon=True visible=True` → `tray icon swap -> 1i modified=True`（shell 接受了换图） |
| 拔掉内嵌图标 + 有 Pillow | 回退 PIL 路径，`ok=True`、`nim_add=True` |
| 真实 Python 3.14 无 Pillow（用户机器，装新单文件后） | 同上 —— 待用户复测 |

探针：`%TEMP%\wg-nopil-tray-probe.py`（A/B 两条路径）、`%TEMP%\wg-nopil-switch-probe.py`（切模式换图标）。
回归全绿：harness 16/16、split-cache 40、缓存 14、QR 78、wgtranslate 62、钩子顺序 10 全 DIFFS=0、
dist 自检 35/35（懒装载 vs eager DIFFS=0）、dist 内嵌 9 模块逐字节一致、`undefined-globals.py` 0 处。
单文件 756 767 → **767 991 B**（+11 KB，就是那 9 个图标）。

---

用户反馈：**个别机器**双击 `wgime-py.py` 后**哪里都看不到托盘图标**，而在同目录用 `python wgime-py.py`
跑就正常；两边的进程都是 pythonw.exe。这类问题以前**完全静默**：pystray 不检查 `Shell_NotifyIcon`
的返回值，它的报错只走 `logging` → `sys.stderr`，而 pythonw 下 `sys.stderr is None`，连报错都没地方显示。

### 先排除掉的（避免以后再走一遍弯路）

| 假设 | 结论 | 证据 |
|---|---|---|
| pythonw 下 `print(..., file=sys.stderr)` 抛 AttributeError 把进程打死 | **否** | 用 bootstrap 把 `sys.stdout/stderr` 置成 None 再跑 dist：冷缓存路径（会走 `engine._load_cache` 的 print）照样活到建表 —— CPython 的 `print` 遇 None 是静默返回 |
| 无控制台时 shell 不接受托盘图标 | **否** | `%TEMP%\wg-shellnotify-probe.py`：自建窗口 + `Shell_NotifyIcon(NIM_ADD)`，console 与 pythonw+DETACHED **都返回 True**，`Shell_NotifyIconGetRect` 都回 S_OK 并给出通知区坐标 |
| 双击与控制台跑的是不同解释器（python.exe vs pythonw.exe） | 用户已确认**都是 pythonw.exe** | —— |

### 查明的两件事

1. **`Shell_NotifyIconGetRect` 不能用来判断"登记上没有"**：实测我们自己的进程里 pystray 的
   `NIM_ADD` 返回 **True**（shell 收下了），同一 (hwnd, uID) 的 `GetRect` 却回 **E_FAIL** —— 它只反映
   "在不在**可见区**"。第一版自检拿它当"没登记"判据，于是好机器也被误报成 missing（本轮自己踩到并修掉）。
   正确信号有两个：① 直接抓 pystray 的 `NIM_ADD` 返回值；② Windows 11/Server 2025 按 exe 记的
   `HKCU\Control Panel\NotifyIconSettings\<hash>\IsPromoted`（1=显示在托盘区，缺省/0=被收进 `^` 隐藏溢出区
   —— **新机器/新 exe 的默认就是隐藏**，机器之间不一样，正对"只有个别机器看不到"）。
2. **`GetRect` 的 uID 必须是 pystray 用的那个**：pystray `_win32._message()` 里是 `hID=id(self.icon)`，
   不是常量 1（传错就一路 E_FAIL，看起来像"图标没登记"）。

### 改动

- **`tray.py`**：① 给 `logging.getLogger('pystray')` 接一个 handler，把 pystray 自己的报错收进 `tray.LOGS`
  并写进 `debug.log`（pythonw 下本来全丢）；② 包一层 `Shell_NotifyIcon` 记录 `NIM_ADD` 的返回值
  （`tray.NIM`）；③ `import` 失败时保留 traceback（`IMPORT_ERR`）；④ `start()` 失败会带回 `last_error`
  （以前 `not HAS_TRAY` 直接 `return False`，外面什么都不知道）；⑤ `selfcheck()` 用正确的 uID 反查。
- **`win.py`**：新增 `notify_icon_rect()`（GetRect，含 uID 兜底）与 `tray_promoted()`（读按 exe 的显示/隐藏设置，
  `pythonw.exe` 与商店版 `pythonw3.12.exe` 这类主干名也匹配）。
- **`main.py`**：`_tray_selfcheck()`（带重试，等 pystray 线程发出 NIM_ADD）把结论写成 **2 行 always-on 日志**
  （不需要 `WGIME_DEBUG`，用户默认也有得查）；真失败就**从后台线程**弹消息框说明（含 NIM_ADD/解释器/控制台/
  原因/日志路径；从后台线程弹是为了不卡住主线程的 poll 也就是不卡打字）；若图标只是被 Windows 收进 `^`，
  发气泡告诉用户怎么让它常驻。`_dfn_always()` 只用于这几条托盘诊断（不是每键路径）。

### 验证

- `%TEMP%\wg-tray-selfcheck-probe.py`（用真实 **pythonw.exe + DETACHED_PROCESS**、无控制台跑 dist）：
  正常构建 → `tray start ok=True`、`tray selfcheck: nim_add=True(count=1) promoted=True getrect=missing`
  且**不误报不弹框**；把 `start()` 改成强制失败 → `ok=False` + `nim_add=None(count=0)` + 弹框文本 322 字
  （内容含 NIM_ADD/python/控制台/原因/日志路径）。
- `%TEMP%\wg-shellnotify-probe.py`：console 与无控制台两种进程里 `NIM_ADD=True`、`GetRect=S_OK`（如上表）。
- 回归全绿：`tests\pure-state-harness.py` 16/16、split-cache/派生表 40 项、缓存生命周期 14 项、QR 78 项、
  wgtranslate 62 项、钩子顺序 10 项 全部 DIFFS=0、`wg-r40-selftest.py` 35/35（懒装载 vs eager DIFFS=0）、
  dist 内嵌 9 模块逐字节一致、`tests\undefined-globals.py` 0 处。

---

接第三十八/三十九轮继续压"启动后按 Shift 打字要等 1-3 秒才上屏"。第三十九轮把**键盘钩子**提到最前，
但"上屏"要到 `root.mainloop()` 里 `poll()` 跑起来才发生 —— 这一轮压的就是**到主循环的距离**：
实测 HEAD 到主循环 **2694ms**，本轮 **1954ms**（−713ms）。

### 一、两个真 bug：`win.py` 的全局量被写进行尾注释（跟随 helper 一直没工作）

```python
_helper_t0=[0.0]; _helper_fail=[0]   # helper 启动时刻 / 连续秒退计数 (见 _start_helper/_ipc_reader); _ipc_req_hwnd={}; _last_fg=[0]
```

`_ipc_req_hwnd` 与 `_last_fg` **从未真正定义**（`7c02673` 移植 testing v3 caret-helper IPC 时写进注释的），
后果（都在运行期被吞成一行 debug.log，所以一直没被发现）：

* `request_caret_refresh()` 里 `_ipc_req_hwnd[rid]=hwnd` → `NameError` → 被自己的 `except Exception` 吞掉 →
  **`p.kill()` 把跟随 helper 杀掉**。也就是**每打一个字都在杀/重启一个 python 子进程**（还受 1s 限流保护才
  没把机器打满），UIA 精确跟随完全失效，`_helper_fail` 三次后干脆不再起 helper（第三十八轮看到的"helper 秒退"
  有一部分其实是这个，而不只是 `runtime\` 里的 python38 残留）。
* `get_caret_pos()` 第一行 `if _last_fg[0]!=fg_now:` → `NameError` 直接抛出去 → 首次候选窗定位失败。

新增探针 `%TEMP%\wg-caret-global-probe.py`（独立装载真 `win.py`，`LOCALAPPDATA` 指向隔离目录，起真 helper）：
**修复前 4/12 通过**（`_ipc_req_hwnd`/`_last_fg` 不存在、`request_caret_refresh` 返回 0、30 次刷新后 helper 已死
pid 9756→None、`_helper_fail=[1]`、`get_caret_pos` 抛 NameError）→ **修复后 12/12**（rid>0、pid 不变、
`_helper_fail` 保持 0、`get_caret_pos` 不抛）。修复即把两个量真正定义出来（注释里那半行删掉）。

**并加了防呆**：`wgime-py-pure\tests\undefined-globals.py`（symtable 写的 mini-pyflakes，扫"引用了不存在的
全局量"）。在**修复前的 `win.py`** 上跑会报 3 处（`_ipc_req_hwnd`×2、`_last_fg`×1），修复后 0；全项目 17 个 .py
文件现在 0。这类"名字被写进注释"的错误 C# 侧有编译器兜（用不存在的字段直接 CS0103），python 侧原来完全靠运气。

### 二、启动路径：能省的时间都在"到主循环"这一段

1. **dist 单文件模块懒装载**（`build-wgime-pure.py`）：原来 9 个内嵌模块一律启动即 `exec`，实测
   合计 **~490ms**（tray 121 / tools 107 / win 51 / plugins 48 / bar 46 / wspy 40 / engine 34 / hook 12 / ui 6），
   其中 **367ms 花在钩子根本用不到的 UI/插件/托盘模块上**（它们还连带 `import tkinter` / PIL / pystray）。
   现在只有 **`win`/`hook`/`engine`** 预装，其余用 PEP 562 模块级 `__getattr__` 做成"首次属性访问才 `exec`"
   （RLock 保护，可重入 —— 模块 exec 期间可能再触发别的懒模块）。钩子因此提前 **~294ms** 可用。
2. **`Engine()` 挪进后台线程**（`main.py`）：读词库（热 ~1.0s，冷 12-15s）原来同步排在 Tk/加载窗之后，
   现在**钩子一装好就起线程**，主线程同时 `import tkinter` + 建 Tk + 加载窗，两边并行；`join` 之后才用结果
   （异常含 `MemoryError` 带回主线程重抛；线程起不来则老实同步读一次）。加载窗仍然盖住建表的 1s，只是
   它和读词库同时在跑。
3. **跟随 helper 的 spawn 也进线程**（原来 `Popen` 一个 python 要 ~90-100ms，正卡在词库线程启动之前）。
4. **启动收尾从主循环之前挪进主循环**：`reload_plugins` + `load_py_plugins` + `load_appmodes` + 托盘对象/图标
   (`import tray` = pystray+PIL) + `tools` 懒装载（`tools.set_notifier` 是第一次访问 tools 属性）实测合计
   **~500ms**，原来全排在 `root.after(8, poll)` 前面 —— 钩子早在收键排队了，这 500ms 纯粹是"上屏"白等。
   现在 `poll` 先跑（8ms 就把排队的键全部上屏），三段收尾按 **30 / 150 / 600ms** 错开在主循环里做
   （`_deferred_plugins` / `_deferred_tray` / `_deferred_tools`），每档自己都很短，不把刚开始打字那几秒堵住。
   打字本身不依赖它们（只有"启动器候选/工具箱/插件管理/托盘菜单"要，那也得用户先敲出 code 来）。
5. **加载窗销毁**从 `destroy()`（实测 ~90ms，正卡在"读完词库 → poll 起来"之间）改成 `withdraw()` + 主循环里
   `after(120)` 再 `destroy`。
6. 新增一行启动日志 `startup: mainloop start ...`（`WGIME_DEBUG=1` 时写 `debug.log`），A/B 与用户排障都用得上。

### 三、A/B 实测（真实单文件 dist，同一隔离数据目录 + 同一份码表，`git show HEAD:` 取上一版，各跑 2 遍）

| 构建 | 钩子装好 | 主循环起来（=排队按键真正上屏） |
|---|---|---|
| HEAD（第三十九轮） | 860 / 710 ms | 2694 / 2590 ms |
| **本轮** | **498 / 416 ms** | **1954 / 1877 ms** |
| Δ | **−294 ms** | **−713 ms** |

内部里程碑探针（`%TEMP%\wg-r40-timeline.py`，把每个里程碑插桩后跑真实 dist）：钩子 **+181ms**、
词库线程起 +276ms、Tk root +741ms、词库读完 +1546ms、`poll` +1611ms（HEAD 同一探针口径下 `poll` 是 +2303ms）。
剩下的固定开销：解释器启动+解析 727KB 单文件 **~300ms**、第三方 zip 的 base64/md5 18ms、三个必装模块 93ms。

### 四、验证

* **dist 自检**（`%TEMP%\wg-r40-selftest.py`，把内嵌 main.py 的 `root.mainloop()` 换成自检块，用真实 dist 跑）：
  **35/35 通过**，且**懒装载版与"全量 eager"版逐项 DIFFS=0** —— 懒装载没有改变任何行为。自检覆盖：
  9 个模块首次属性访问都真的装载、**排队的键在收尾三段之前就能上屏**（打 `ni` 出候选、空格上屏汉字）、
  三段收尾确实建起 PLUGINS/TOOLS/托盘图标、engine 词典非空、钩子装上、加载窗已隐藏。
* `tests\pure-state-harness.py` **16/16**；回归探针 split-cache/派生表 **40 项**、缓存生命周期 **14 项**、
  QR **78 项**、wgtranslate **62 项**、钩子顺序 **10 项** 全部 DIFFS=0；dist 内嵌 9 模块与磁盘逐字节相同
  （`%TEMP%\wgime-dist-sync-check.py` → OK）；`tests\undefined-globals.py` 0 处。
* 冷启动不受影响（仍 14s 级，要重建索引）。

---

接第三十八轮继续压"启动后前几秒打字没反应"：上轮把钩子放到**读词库之前**，但它前面还排着
`tk.Tk()`/加载窗 与 `import tools`（连带 `plugins`/`bar`/`ui`）。

- **改动**: 启动顺序再前移 —— `单实例检查` → `load_config`(1ms) → `hook.configure/start/set_active` →
  `win.ensure_caret_bg()` → **然后才** `root = tk.Tk()` + 加载窗 → `import tools/plugins/bar` → `Engine()`(词库)
  → 配置/候选条/托盘/插件/工具 → `poll` → `mainloop`。
  两个"等不起"的点：① Tk root + 加载窗 ≈150ms；② `import tools` 会连带 `plugins`/`bar`/`ui`（实测
  真机边际成本 **155ms**）。这两块原来都排在钩子前面，现在排在后面 —— 加载窗仍然盖住建表的 1 秒，
  只是晚 ~0.2s 出现，而**按键可用时间提前 ~0.5s**。
- **A/B 实测**（同一隔离数据目录、同一份码表，`git show HEAD:` 取上一版 dist 对比，各跑两遍）：

  | 构建 | 钩子装好 | 引擎读完 | 启动收尾(`active=`) |
  |---|---|---|---|
  | HEAD（第三十八轮） | +1397 / +1419 ms | +2540 / +2501 ms | +2828 / +2758 ms |
  | 本轮 | **+985 / +824 ms** | +2767 / +2396 ms | +3032 / +2666 ms |

  即本轮再提前 **~0.45-0.57s**；相对第三十八轮之前（钩子排在插件之后，**+2650ms**）累计提前 **~1.8s**。
- **探针**: `%TEMP%\wg-hookorder-probe.py` 扩到 **10 项 0 失败**（钩子早于 Tk、早于重 import、
  重 import 仍早于建表、钩子 <900ms），并打印 `hook_start / tk_root / import_tools / engine_begin/end` 时间线。
  实测（把 `hook.start` 打桩，不抢用户键盘）：**hook +48ms**、tk +157ms、import_tools +156ms、engine +662ms。
- **探针卫生（本轮踩到，记进 AGENTS §6）**: 跑真实 dist 探针时 `APP_DIR` 是**由 DICT_DIR 推出来的**
  （`WGIME_DICT_DIR` 指到 `package\dicts` → APP_DIR = `package`），所以放在临时目录里的
  `config.txt (mode=tray)` **不会生效** —— 我原来的"托盘模式以免抢键盘"其实是**真的装了键盘钩子**
  （好在那份 `package\config.txt` 是 `starton=0`，未激活时按键照常透传，没有吞键）。要真的强制 tray：
  把码表复制到 `<stage>\dicts` 并把 `WGIME_DICT_DIR` 指过去。
- **验证**: `tests\pure-state-harness.py` **16/16**；回归探针 split-cache/派生表 **40 项**、缓存生命周期 **14 项**、
  QR **78 项**、wgtranslate **62 项**、钩子顺序 **10 项** 全部 DIFFS=0；dist 内嵌 9 模块与磁盘逐字节相同、
  dist==package（SHA256 `9C7AE9B9…`）；冷启动 14.8s（不变）。

---

## 2026-09-11 (第三十八轮: 启动后前几秒打字"1-3 秒才上屏" — 钩子提前装 + 跟随 helper 秒退修复)

用户反馈: "整体加载速度还是比较慢；启动后按 Shift 激活再打字，大概还要 1-3 秒才能上屏。"

**先量清楚**（用**真实单文件 dist** 在隔离数据目录里跑，`mode=tray` 不装键盘钩子以免抢用户的键盘）:

| 里程碑 (warm) | 修复前 | 修复后 |
|---|---|---|
| helper 起 / ready | +2751ms / +2979ms（且用户机器上**秒退**） | **+1449ms / +1698ms（与读词库并行）** |
| **键盘钩子装好** | **+2650ms（在引擎/插件之后）** | **+1.45s（在读词库之前）** |
| 引擎读完 | +2394ms（load=1007ms） | +2465ms（load=1011ms） |
| 插件加载完 / active= | +2527ms / +2650ms | +2617ms / +2711ms |

也就是说：**"上屏慢 1-3 秒"不是上屏慢，是钩子还没装** —— 用户"启动后按 Shift 再打字"正好打在这段
2.6 秒的窗口里，那几秒的按键根本没进输入法。冷启动（要重建索引）14.1–14.9s 才是"整体加载慢"的主因；
用户 15:17 那次冷启动是前几轮改 `CACHE_VER`/重建 package 让缓存失效造成的。

- **修复 1: 键盘钩子提前到「读词库」之前装**（`main.py`）。新顺序：
  Tk/加载窗 → **读 config(1ms) + `hook.start()` + `set_active()` + 起 caret helper** → `Engine()`(词库) →
  配置/候选条/托盘/插件/工具 → `poll` → `mainloop`。语义不变：
  未激活时按键**照常透传**给应用（与没装钩子时完全一样，`starton=0` 的行为不变）；
  已激活时按键进 `hook.EVENTS` 队列，等 `poll()` 起来后按顺序处理 —— 用户前几秒敲的字**不丢、
  也不会漏成半截拼音**。尾巴上的 `hook.start()` 变成幂等（已装则 0ms），失败才弹"钩子失败"气泡；
  另加 `_dfn('early hook ok=…')` 落进 `debug.log`，以后能直接从日志确认。
  实测（探针把 `hook.start` 打桩，避免探针自己抢用户键盘）：hook 在 **+544ms** 装好（此前必须等引擎读完：
  热 2.6s / 冷 14s）。
- **修复 2: 光标跟随 helper 在用户机器上"起来就死"**（`win.py`）。用户 `debug.log` 实测：几次启动里
  `[win] IPC helper started` 之后 **0.15–0.19 秒**就 `exited`（5 次启动 4 次立即退出），于是 UIA 跟随
  静默失效、而且每次按键都可能白白 spawn 一个 python。根因：helper 落在
  `%LOCALAPPDATA%\wgime-py\runtime\`，而该目录里残留 pythonnet 时代的 **python38 整包**
  （`_ctypes.pyd`/`pyexpat.pyd`/`select.pyd`/`python38.dll`/`Lib`…），helper 以脚本目录为 `sys.path[0]`，
  这些 `.pyd` 抢占标准库 import → 秒退。
  **修复**：helper 落到专用子目录 **`runtime\caret-helper\`**（与残留隔离；子目录建不出来时退回原目录），
  且**连续秒退 3 次就不再重试**（避免每按一键起一个 python）。
  **A/B 证据**（隔离目录、同一份 helper）：放在带残留的 `runtime\` → **起不来**（exit 1 + traceback，
  复现用户日志）；放在 `runtime\caret-helper\` → **ready（249ms）**。
- **验证**: 新探针 `%TEMP%\wg-hookorder-probe.py` **9 项 0 失败**（钩子早于 Engine、落在 pre-engine 阶段、
  helper 残留 A/B、`_helper_path()` 指向新子目录）；回归：`tests\pure-state-harness.py` **16/16**、
  split-cache/派生表 **40 项**、缓存生命周期 **14 项**、QR **78 项**、wgtranslate **62 项** 全部 DIFFS=0；
  dist 内嵌 9 模块与磁盘逐字节相同、dist==package（SHA256 `43CFF6AE…`）；真实 dist 复测见上表。

---

## 2026-09-11 (第三十七轮审计: wgime-qr 二维码编码器 — 用独立解码器整链验证 + 容量提示差一)

维度: `wgime-py-pure\plugins\wgime-qr.py`（v2.5，AGENTS 原写"二维码 qrcode，Nayuki 算法已逐位对齐参考实现"）。
仓库里 C# 侧**没有**对应插件源（`plugins\*.txt` 里没有 qr），所以这轮不是 C#↔python 对照，而是**对规范/参考算法做独立验证**。

- **方法**: 新写一个**独立解码器**（不复用插件的任何表/GF 代码）——ISO/IEC 18004 M 级 v1..10 块结构表、
  对齐图形位置表、功能图形分布图、格式/版本信息 BCH、Z 字形码字读取、反交织，以及
  **Reed-Solomon 校验子**（GF(256)/0x11D 独立实现）。校验子全 0 等价于"码字块是合法的 RS 码字"。
- **结果（78 项检查，0 失败）**:
  - 12 组输入（ASCII / URL / 纯数字 / 各版本容量边界 / 中文 / 日文+emoji / 带变音符拉丁字母）**全部可解**：
    格式信息与自身 mask 一致、版本信息（v≥7 的两处副本）与独立 BCH 一致、**每个 RS 块校验子全 0**、
    反交织后解析出 `ECI 26 + 字节模式` 且 payload 与输入 UTF-8 **逐字节相同**。
  - 插件内表与规范逐项相同：每版本总码字数 / 每块 ECC 码字数 / 块数（含 v8 `2×38+2×39`、
    v9 `3×36+2×37`、v10 `4×43+1×44`）、对齐图形中心（v2..v10）。
  - 容量边界：13/14/25/26/41/42/61/62/83/84/105/106/121/122/151/152/**179/180**/212 字节各自选到
    **最小可用版本**；剩余位（remainder bits）v2..v6 = 7、其余 0。
  - mask 选择 = 独立实现的罚分函数（N1..N4 含 finder-like 图案）在 8 个 mask 中的**最小值**。
  - PNG 写出（手工 zlib/struct）：签名 / IHDR（8bit、色彩类型 2 = RGB）/ 块顺序 / **全部块 CRC** /
    每行 filter=0 / 解压后长度 `h*(1+w*3)` / BGRX→RGB 像素顺序逐点正确。
- **修 1 处真差异（用户可见）**: `qr_encode` 超长时抛的 ValueError 写"最多支持约 **213** 个 UTF-8 字节"，
  真实容量是 **212** —— v10/M 有 216 个数据码字 = 1728 位，减去 ECI 12 + 字节模式 4 + 计数 16 = 32 位，
  1696/8 = **212** 字节。已把文案改成 212（探针里同时断言"213 抛异常且文案里的数字 = 212"）。
- **探针**: `%TEMP%\wg-qr-probe.py`（78 项，可重复跑；不联网、不碰用户数据）。
- 顺带确认 **`build-package.ps1` 的不可复现性**又出现一次（只改插件也会让 `dist\wgime-py.py` 因第三方 zip
  时间戳变脏）→ 按 AGENTS §30 的规则 `git checkout --` 回退，并确认 dist 仍与磁盘 9 模块逐字节一致。

---

## 2026-09-11 (第三十六轮审计: wgtranslate 插件 — C# 请求体转义 bug + python 语言表缺项 + 文档纠偏)

维度: C# `plugins\wgtranslate.txt`（`code = fy`，`[csharp]` 编译型插件）vs python
`wgime-py-pure\plugins\wgtranslate.py`（v2.2.0 重写版）。

- **修 C# 侧真 bug（本轮新发现，带编译级证据）**: `GoogleCloud` 构造请求体那一行**多了一层转义** ——
  源码写的是 `"{\\\"q\\\":\\\""`，C# 编译后的运行期字符串是 `{\"q\":\"…`（每组引号前多一个反斜杠），
  **不是合法 JSON**，所以「Google Cloud（API Key）」通道**从来不可能成功**（服务端一律 400）。
  同一个文件里紧挨着的 `Libre` 那行写法是对的（`"{\"q\":\""`），只有 Cloud 这行多了一级。
  **证据**：用 `csc` 把该行**原样**编译成 exe 再运行、打印运行期 body ——
  修前 `{\"q\":\"hello world\",…}` → `json.loads` 失败；修后 `{"q":"hello world","source":"zh-CN",…}` → 通过
  （`Libre` 修前修后都合法）。改动：该行 16 处 `\\\"` → `\"`，`plugins\wgtranslate.txt` 与
  `release\plugins\wgtranslate.txt` **各 1 行** diff，已跑 `sync-dist.ps1` 同步 release。
- **修 python 侧缺项**: C# `LANG_NAMES`/`LANG_CODES` 有 **33 项**（含 `保加利亚语`/`bg`），python 的
  `LANGUAGES` 漏了它 —— 保加利亚语在 python 版**根本选不到**。已按 C# 表的位置补上。
- **文档纠偏**: AGENTS §8 原写「已从 C# 1:1 移植 … `wgtranslate.py`」，实际 python 侧是**另一份重写**
  （v2.2.0），不是逐行移植。差异已逐条写进 AGENTS §8，要点：python 通道是**超集**
  （多 SimplyTranslate / Argos 离线）、多「保留格式」开关、按**句子边界**分段（430B；C# 是纯字节切 450B）、
  统一 `html.unescape`、MyMemory 校验 `responseStatus`（C# 会把"今日免费额度用尽"那句警告**当译文显示**）、
  Libre 的 zh-TW 用 `zt`（C# 一律 `zh`）、auto 方向按**主导文字**判定（C# 只要有一个汉字就当中文）、
  `PERM = network,run`（运行前弹确认）；标签 `自动判断` vs C# `自动检测`、python 没有 `自动中英互译`
  菜单项（默认 源=自动判断/目标=简体中文 时自动翻转方向，效果等价）。
- **顺带记两条仓库卫生规律**（已写进 AGENTS §5/§30）:
  ① 根 `plugins\*.txt` 这类 txt 的 **blob 是 LF、工作区却是 CRLF**（`core.autocrlf=false` 且无属性），
  用字节改写会整文件报改动 → 改完要按**各自 blob 的行尾**写（根 txt 写 LF；`release\plugins\wgtranslate.txt`
  的 blob 是 CRLF，就写 CRLF），再用 `git diff --numstat` 校验只剩目标行；
  ② `build-package.ps1` 内嵌的第三方 zip 用当前时间戳，**源码没改也会让 `dist\wgime-py.py` 变脏**；
  dist 只内嵌 9 个项目模块 + `main.py`（**不含插件**），所以只改插件时应 `git checkout -- dist\wgime-py.py`。
- **验证**: 新探针 `%TEMP%\wg-wgtranslate-probe.py` **62 项 DIFFS=0**（C# 33 项语言表逐项对齐、
  各通道语言码映射与 C# oracle 逐值比对、`chunks()` 7 组样例无损且不超 430B、`layout_units()` 重建等于原文
  且保留缩进/项目符号/尾空格/空行、`detect_source()` 13 例、自动容错回退顺序与失败文案、显式通道失败不回落）
  + `csc` 编译运行证据（BEFORE 失败 / AFTER 通过，release 侧同样通过，见 `%TEMP%\wg-csbody-evidence.py`）
  + `tests\pure-state-harness.py` **16/16**；dist 未变且仍与磁盘 9 模块逐字节一致。

---

## 2026-09-11 (第三十五轮: 启动再快 0.4s — 三张"每次重算"的派生表进缓存)

接着第三十四轮继续压"启动头几秒"（钩子装好前打字没反应的那段窗口）。

- **发现**: `Engine._init_state()` 里三张**只由码表派生**的表原来**每次启动**都重算 ——
  `char_wb`（单字→最长五笔码，21,781 键）、`wb_by_len`（五笔码按码长分桶，z 通配查询用）、
  `word_freq`（`pywfreq.txt` 语料词频，71,580 词）。直接计时：`char_wb` **707ms** +
  `wb_by_len` **61ms**（其中 `sorted(wb)` 23ms）+ `pywfreq.txt` **155ms** ≈ **0.92s**，
  全在这段窗口里。
- **A/B 实测**（同一个探针、同一份词库、各自隔离的 DATA_DIR；旧版 `engine.py` 从 `a216772` 取出单独跑）：
  | | 旧 (CACHE_VER=4) | 新 (CACHE_VER=5) |
  |---|---|---|
  | 热启动 Engine() 构造 | **1401ms** | **998ms** |
  | 冷启动 Engine() 构造 | 12915ms | 12128ms |
  | 缓存 | 90.6MB | 93.1MB |
  三张表内容逐项相同（`char_wb` 21781 / `wb_by_len` 5 桶 / `word_freq` 71580 + total 相同），
  冷启动无回退。
- **做法**: 新增 `_build_core_extra()`（三张表一起算），`_build()` 里调一次（冷建），
  并把它们**并进缓存第一段**（`CACHE_VER = 5`）；`_init_state()` 改成
  `if not self._core_extra_ready: self._build_core_extra()` —— 热启动直接从缓存拿。
  三张表启动后只读（运行时不改），所以缓存是安全的。
- **签名必须跟着走**: `pywfreq.txt` 加进 `CACHE_FILES`（现在 8 个文件）。不加的话改语料不会让缓存失效，
  `word_freq` 会一直是旧的（探针里专门验了"改 pywfreq.txt → 签名变化"）。
- **代价**: 缓存 90.6 → **93.1MB**（第一段 44.6 → 47.0MB），多 ~50ms 反序列化，换掉每次启动 ~0.4s。
- `reload()`（导入码表后热重载）里那句 `_build_wb_len()` 去掉了 —— `_build()` 现在已含
  `_build_core_extra()`，重复调用白算 61ms。
- **端到端（热启动，启动时间线探针）**: `main` 前缀/装钩子 **2.29s → 1.98s**
  （第三十四轮之前是 3.70s）；首键 60ms、第 2 键 41ms；词典表后台加载期间每键 3–40ms。
- **验证**: 探针扩到 **40 项 DIFFS=0**（新增: 三张表冷/热逐项相同、mode 2 的 z 通配键进对照集
  以真正走 `wb_by_len`、`pywfreq.txt` 在签名里且改动会改变签名、截断第二段时第一段派生表仍可用）；
  缓存生命周期 **14 项**、`tests\pure-state-harness.py` **16/16** 全绿；
  dist 内嵌 9 模块与磁盘逐字节相同、dist==package（SHA256 `D67A0122…`）。

---

## 2026-09-11 (第三十四轮: 每次启动头几秒"打不出字" — 根因是首键同步建反查表 + 启动整份读缓存)

用户报告: **每次**启动后头几秒打字没反应/很卡。查下来是**两个**独立的阻塞点，都在"钩子还没装好/首键正忙"这条路上。

- **根因 ①（首键卡 ~1.3s，就是用户说的"开始那几秒打不出字"）**: `config.txt` 里 `showcode = 1` 是**出厂默认值**，
  于是**每次启动的第一下按键**都要在按键处理路径里**同步**建「词→五笔码」反查表（30.2 万码 / 143.8 万词条，
  纯 Python `str.split` 循环）—— 实测 **1326ms**。反查表本来就是**惰性**建的（对齐 C# `EnsureRevWb`），
  C# 里那次建表是编译过的 .NET 代码（几十 ms）所以没暴露，python 是 1.3s。
  **修复**: `rev_wb_code()` **绝不再同步建表** —— 起后台线程 (`warm_rev_wb`/`_rev_wb_worker`)，没建好就返回 `None`
  （候选上暂时不显示反查码，建好后自动生效）；`build_rev_wb` 每 4000 码让出一次 GIL（分片参数 `chunk`/`pause`，
  `chunk=0` 关闭供 oracle 用）；码表变了用**代数** `_rev_gen` 让在飞的构建结果作废（对齐 `_invalidate_rev_wb`）。
  实测首键 **1326ms → 68ms**（后台建表并行时）/ 20ms（空闲时）。
- **根因 ②（钩子晚装 ~1.1s）**: 启动时同步 `pickle.load` **整份 90.6MB 缓存**（实测 2050–2611ms），而其中**一半
  (46MB: `ec`/`ek`/`ev`/`ce`) 只有「词典」模式(3)用得到**。这段时间钩子还没装，打字完全没反应。
  **修复**: 缓存改**两段 pickle**（`CACHE_VER = 4`）—— 第一段=核心表(`py/pk/pv/wb/wk/wv/char_py/acro`，44.6MB)，
  第二段=词典那半张表；启动只同步读第一段（实测 2050→**864ms**，`main` 前缀 3.70→**2.29s**）。
  第二段由 `ensure_ec()` 在**后台线程**里加载，读取器是 `_YieldingReader`（每次 `read` 之间 sleep 0.2ms，
  让 `_pickle` 的反序列化**周期性**交还 GIL）—— 实测加载期间每键延迟 **18–36ms**（不让出的话首键能到 200ms+）。
- **预热**: `main` 在 `hook.start()` + `set_active()` **之后**调 `engine.warm_ec()`（钩子装好=能打字了再预热）。
  **不要**改到 `apply_config()` 里去预热：试过，那 1.2s 纯 Python 循环抢 GIL 会把 `hook.start()` 从 +2.29s 推到
  +3.70s（键反而更晚可用）。打开托盘「反查编码」开关时也立刻 `warm_rev_wb()`，别让下一键去等。
- **两个 pickle 段必须打在两段里、但四个部件要打成一段**: 拆成 4 个 pickle 会丢 pickle 的字符串去重
  （四张表的键大量重复），缓存从 **90.6MB 涨到 121.9MB**；`pickle.dump((ec,ek,ev,ce), f)` 一段就没有这个问题。
- **兜底（新增探针覆盖）**: 第二段损坏/截断（`.sig` 侧车仍匹配、缓存"看起来可用"）→ 后台线程里**直接从码表重建**
  (`_build_ec`)；两条路都失败才置 `_ec_fail` 打住 —— 否则「词典」模式**每按一键就起一个读 24MB 码表的重建线程**。
- **启动反馈窗改成每次启动都显示**: 热启动也要读 95MB 缓存（~1s+ 建表 + 装钩子），原来只在"缓存过期要重建"时才
  显示提示窗，热启动那两三秒毫无反馈；现在固定显示（第二行按 `_dict_cache_stale()` 区分"首次启动需建立索引"/
  "正在读取词库缓存"）。
- **实测汇总（隔离数据目录，热启动）**: 引擎加载 **2050→864ms**、`main` 前缀 **3.70→2.29s**、首键 **1326→68ms**、
  缓存仍 **90.6MB**（95006769 字节）、词典表后台就绪 ~4.6s 且**期间每键 1–36ms**；冷启动 12.4s（不变）。
- **验证**: 新增探针 **26 项全对（DIFFS=0）** —— 冷建/热启动两段缓存往返、**模式 0/1/2 热启动候选与冷建逐项相同**、
  模式 3 就绪后与冷建逐项相同（不再出现"空候选几秒"以外的异常）、截断第二段走后台重建兜底且结果仍与冷建相同、
  两条路都失败时**只重建一次**且 `candidates` 仍返回三元组（曾经 `return []` 破坏契约让 `refresh()` 抛
  `ValueError: not enough values to unpack`）。回归: 缓存生命周期 **14 项**、`tests\pure-state-harness.py` **16/16**、
  启动时间线冷+热复测无崩溃。

---

## 2026-09-11 (第三十三轮: 候选条位置持久化 — 重启后仍在原处/仍贴着那条边)

按用户要求: 候选条拖到哪儿, 下次启动还在那儿 (C# 早有 `LoadPos`/`SavePos`, python 一直没有)。

- **位置落盘**: 对齐 C# —— `DataDir\pos.txt`, 内容就是 `"x,y"` (`File.WriteAllText(Left + "," + Top)`),
  **松手时**(`<ButtonRelease-1>`)才写, 拖动过程中不写盘。python 数据目录是 `%LOCALAPPDATA%\wgime-py`,
  所以与 C# 版的 `%LOCALAPPDATA%\wgime\pos.txt` 各存各的, 不会互相打架。
- **启动恢复**: `CandBar.__init__` 读回上次位置, 首次 `show()` 的"固定位置"分支用它 (跟随光标模式照旧
  跟随光标, 不受影响)。**粘附边会重新推断**: 存下来的是贴着左边缘的坐标, 重启后按当前候选条尺寸
  重新贴齐那条边, 所以之后候选变宽/变窄也不会从边上漂开。
- **容错**: `pos.txt` 内容坏了(非数字/段数不对/空/GBK 全角数字/超屏坐标)一律**不崩**、退回默认位置,
  再交给原有的 clamp; 读文件走宽松解码(AGENTS §28)。
- **不影响测试**: `CandBar(root)` 不传 `data_dir` 时完全不碰文件(探针/单测行为与以前一致)。
- **验证**: 位置持久化探针 **15 项全对** —— 松手才落盘且内容字节 = `"x,y"`; 新实例(模拟重启)首次 show
  回到原位; 粘左边缘后重启仍贴左边、变窄也不漂、且重新推出了粘附方向; 5 种坏 `pos.txt` 都能容错;
  `data_dir=None` 时文件一个字节都没被碰。另回归: 候选条粘附 17 项、导入 oracle 58 项、`parse_dict` 4 项、
  缓存 14 项、`tests\pure-state-harness.py` 16/16 全绿。

---

## 2026-09-11 (第三十二轮审计: 码表导入/解析路径 — 宽松读 + 写出行尾)

换维度: C# `ImportCodeTable` + 转换函数(wgime.bat 4538-4670) vs python `engine.py` 转换段 + `tools.show_import`。

- **核对一致(未改)**: 按 C# 源码独立重写 oracle, **58 项 0 差异** —— `is_pure_ascii`/`is_all_digits`/
  `valid_code`(15 个码)/`skip_line`(17 例: 空行/`#`/`;`/`//`/`---`/`...`/yaml 头/`k:v` vs `k: v`)/
  `detect_format`(10 组语料)/`convert_file`(**fmt=1 与 fmt=2 各 14 组**: 词在前(Rime)/码在前/EN+释义/
  尾权重/内空格/非法码/引号码/CRLF/制表符/300 词截断/50 万码截断/去重)/`suggest_target`(23 个文件名)/
  `load_import_base`(含重导入幂等)。
- **修复 ①: `write_import_file` 写成了 CRLF**。C# 是 `File.WriteAllText(..., UTF8Encoding(false))` +
  `sb.Append('\n')` —— **裸 LF**; python 的 `open(..., 'w', encoding='utf-8')` 在 Windows 上会把
  `'\n'` 翻成 CRLF, 于是同一份导入在两种实现下产出**不同字节**。而 `import_py/wb/ec.txt` 是
  **入库跟踪**的文件, 行尾被搅乱就是整文件 diff。现在显式 `newline='\n'` (探针已按字节比对 C# 写出的内容)。
- **修复 ②(高危): 用户把码表"另存为 ANSI(GBK)"会让启动直接崩**。`parse_dict` 原来用严格
  `open(..., encoding='utf-8')` 且只接 `OSError` → GBK 码表抛 `UnicodeDecodeError`, 异常从
  `Engine._build()` 一路冒到启动流程(报一句看不懂的解码错误); 另外严格 utf-8 **不处理 BOM**,
  带 BOM 的码表**第一行读不进来**(key 变成 `'\ufeffxxx'`, 而 C# 的 `File.ReadAllLines` 会吃掉 BOM)。
  现在快路径用 `utf-8-sig`(顺手吃 BOM, 性能不变), 解码失败才退回 `read_text` 宽松解码
  (utf-8-sig → gbk → utf-8+replace, 对齐 C# 的替换式解码); 行解析抽成 `_add_dict_line` 共用。
- **修复 ③: `load_import_base` 同样是严格 utf-8**(且 `except OSError` 接不住解码异常) →
  用户手改过的 `import_*.txt` 会让导入对话框直接报解码错误、什么都导不进去。改用 `read_text`,
  行切分与 `ReadAllLines` 对齐(`\r\n|\r|\n`)。
- **修复 ④: `_py_plugin_meta_static` 严格 utf-8**。用户写 `# -*- coding: gbk -*-` 的插件
  python 能正常 import, 但插件管理器列举 manifest 时会抛 `UnicodeDecodeError` 把列表打崩 → 改用 `read_text`。
- **对齐 ⑤**: 导入写盘成功但热重载失败时, C# 提示"导入完成但刷新失败/重启后生效: …"、
  python 原来混在"导入失败"里(会让人以为没导进去)。现在分开提示。
- **有意差异(记录)**: C# 在"没有新增词条"时**静默返回**, python 会弹一句"没有新增词条"(更清楚, 保留)。
- **验证**: ① 导入 oracle 58 项 0 差异(含**写出字节与 C# 完全一致**); ② `parse_dict` 探针 before/after:
  GBK 码表改前 `UnicodeDecodeError` 把 `Engine` 构建打崩、改后正常; BOM 码表改前第一行 key 带 `\ufeff`、
  改后正常; ③ import 读写探针 before/after: GBK 文件改前抛异常、改后读得到且中文正确, 写出由 CRLF 变 LF;
  ④ 插件 manifest 探针 before/after: GBK 插件改前抛 `UnicodeDecodeError`、改后正确列出;
  ⑤ `tests\pure-state-harness.py` 16/16; ⑥ 既有回归探针(计算器 73 例/时钟 187 例/wspy 20 项/
  候选条 17 项/chat 重连 16 项/保活 11 项/缓存 14 项)全绿。

---

## 2026-09-11 (第三十一轮: 候选条靠边粘附 + 索引缓存只在词库变化时重建)

按用户要求做的两件事 (其中第二件顺带查出两个真 bug)。

- **候选条靠边粘附 (用户要求)**：候选条可以拖动, 现在拖到离**工作区边缘 24px 内**会自动
  贴齐那条边; 水平/垂直**各判一次**(所以四个角也能贴); 往外拖超过阈值就自动脱开。
  粘附状态会被记住, 候选变多/变少导致条子变宽变高后**仍然贴着当初粘的那条边**
  (新增 `bar.snap_to_edge()` + `SNAP_PX`, 保持逻辑在 `CandBar._apply_edge_snap`),
  不会再像以前那样"变宽后慢慢漂离边缘/飘出屏幕"。
  探针(真建窗 + 合成拖动事件) **17 项全对**: 贴左/右/上/下、左下角双向吸附、拖到中间自动脱开、
  粘左后变宽再变窄仍贴左边、粘下后行数变化仍贴下边、阈值边界(恰好 24px 内贴/26px 外不贴)。

- **索引缓存只在词库变化时重建 (用户要求)**。原来有两处会让"缓存"这件事不可靠:
  - **真 bug ①: 在"没有码表的目录"里会把"空索引"写进缓存**。实测用户机器
    `%LOCALAPPDATA%\wgime-py\dict-cache.pkl` 只有 **75 字节**, 里面 `sig=[None]*7`、
    `data` 全是空容器 —— 因为那次运行的词库目录里一个码表都没有 (典型来源: 直接跑
    `wgime-py-pure\dist\wgime-py.py`, 而 dist 目录里没有 dicts)。更糟的是这个"空缓存"
    **签名自洽**: 之后每次启动都直接命中它, 于是**词库凭空为空、候选里一个字都没有、还没有任何提示**;
    而一旦换成有码表的目录, 签名又永远对不上 → 每次启动都重建。
    现在: ① **一个码表都没读到就不写缓存**, 并在 stderr 打印明确原因;
    ② 缓存里是空索引时**拒绝命中**、重建并提示; ③ `_save_cache` 失败不再静默吞掉(会打印原因)。
  - **真 bug ②: 签名里没有"词库目录"** → 同一个 DATA_DIR 下换词库目录会误命中旧缓存。
    现在签名 = `版本 + 绝对词库目录 + 每个码表的 (size, mtime)` (`CACHE_VER` 1→2)。
  - **新增侧车 `dict-cache.pkl.sig`** (小 JSON, 就是上面那份签名): 启动时"要不要显示
    *正在加载词库…*"的判断与引擎 `_load_cache` 的判定**共用同一份签名** (`engine.cache_is_reusable`),
    不再用"缓存文件 mtime 粗略比一下" —— 所以**只有码表真的变了才会重建**, 热启动不会再被误判成冷启动。
  - **dist 布局词库目录兜底**: `_find_dict_dir()` 现在会向上找 `..\package\dicts` / 上级目录(仓库根),
    所以 `python wgime-py-pure\dist\wgime-py.py` 也能正常加载码表; 实在找不到就 **stderr + 托盘气泡**
    明确告知"空词库", 不再静默退化。
  - 实测(隔离数据目录): 冷启动 **11.5–12.7s**(建索引 + 写 95MB 缓存 + 侧车), 热启动 **2.0–2.2s**,
    且**热启动完全不重写缓存文件**(mtime 不变)。探针 **14 项全对**: 冷启动写缓存+侧车 / 热启动不重建不重写 /
    换词库目录才重建(换回旧目录不再命中) / 空词库目录不写缓存 / 再换回真词库正常建缓存并可复用。

---

## 2026-09-11 (第三十轮: chat 掉线重连 — 之前一断线就再也不连了)

换维度: python chat 插件与 C# `chat.txt` 的**断线处理**对比。

- **问题**: C# `OnDisconnected` 会 "6 秒后重连 (N/3)"(最多 3 次, `JoinComplete` 里把
  `reconnectTries` 清零), 连接失败直接 `UiJoinFailed`, 用户主动离开 (`manualLeave`) 不重连;
  而 python 版**完全没有重连** —— `_recv_loop` 一断就把状态改成"已断开"、按钮改回"加入",
  网络恢复后必须手动再点一次。现在补齐: `_net_loop` 循环跑 `_session()`(一次连接 + 接收循环),
  掉线 → `已断开, 6 秒后重连 (N/3)…` → 6 秒后重试; 预算用尽 → `重连失败, 已断开`;
  **连接失败不重试**(对齐 C# `ConnectWorker` 非 auto 分支); 用户点"离开"/关窗 (`state['manual']`)
  一律不重连; 面板日志补一条 `· 连接已断开`。
- **写探针时发现的真问题(已修)**: 如果照 C# 那样"连上就清零", 那么"连上后立刻掉"会
  无限重试、`(N/3)` 与"重连失败"永远到不了(预算形同虚设, 探针因此死循环才暴露出来)。
  现在 **只有这次会话稳稳跑过 `HEALTHY_SEC`(20s) 才清零** —— 短促掉线累计 3 次就放弃,
  稳定连过一次就重新给满预算, 标签和代码语义一致。
- **验证**: 探针(假 WS + 假时钟) **16 项全对**: 立刻掉 → 建连 4 次(1 初始 + 3 重连)、
  每次 sleep 6 秒、提示 `(1/3)(2/3)(3/3)` → `重连失败, 已断开`; 稳跑 25s 的话连续 5 次都不放弃且每次从
  `(1/3)` 起算; 连接失败只尝试 1 次; 用户离开后不再建连; 帧间连续超时判死后走同一条重连路径。
  另回归: `wspy` 探针 20 项、保活探针 11 项(按新契约: 接收循环只负责退出、重连判定在 `_net_loop`)仍全对。

---

## 2026-09-11 (第二十九轮审计: WebSocket 客户端 wspy.py — 握手残留字节/分片重组/保活)

换维度: 纯 Python 版自带的 WebSocket 客户端 `wspy.py`(chat 插件的传输层, 之前没审过)。
用**假 socket 按 RFC 6455 脚本化喂字节**的探针(不需要网络)跑了 20 项, 改前 **8 项不符**。

- **修复 ①: 握手响应后面紧跟的第一帧字节被丢掉 (整条流错位)**。
  `_read_headers` 一读到 `\r\n\r\n` 就 return, 而 `recv(4096)` 多读进来的字节被直接丢弃 ——
  服务端却常常把 `101 Switching Protocols` 和**第一条消息帧**写在同一个 TCP 段里。
  现象: 连接看似成功, 首帧消失, 之后整条流从帧中间开始解析(错位/卡死)。
  现在用 `WS._buf` 读缓冲保留余量, `_readexact` 先吃缓冲再收 socket。

- **修复 ②: 不看 FIN 位, 分片消息被拆成多条"消息"**。
  `_read_message` 原来完全忽略 FIN: `TEXT(FIN=0) + CONT(FIN=1)` 会把第一片当完整消息返回,
  剩下的片变成下一条消息 —— relay 通道就是半截 JSON(`{"a":` 之后才 `1}`)整条作废。
  现在按 RFC 6455 重组: 数据帧 FIN=0 时继续收 `OP_CONT` 直到 FIN=1;
  PING/PONG 允许插在分片中间(就地处理、不结束消息、自动回 PONG)。

- **修复 ③: 首帧是 PING 时, ping 载荷被当成消息交给上层**。
  原来 `_read_message` 以 PING 开头时直接 `return (PING, payload)` —— chat 侧 relay 会把
  ping 载荷丢给 `json.loads`。现在 `_recv_data` 专门跳过并处理控制帧, 只把数据帧交给上层。

- **修复 ④: 握手 Host 头缺端口** (RFC 6455 §4.1)。`ws://host:8083/mqtt` 原来只发
  `Host: host` —— 反代/虚拟主机按 Host 路由时会出错。现在非默认端口带端口。

- **修复 ⑤: 读超时语义**。`settimeout(30)` 下, 帧头**之前**的超时是"暂时没数据"
  (可安全重试, 已读字节留在缓冲里), 帧**中间**的中断则意味着流已错位 —— 现在后者抛
  `RuntimeError` 当断线, 不再被上层当成"没数据"继续解析半截帧。

- **修复 ⑥: chat 空闲 30 秒必掉线 (没有保活、也没有 MQTT PINGREQ)**。
  `_mq_connect` 的 MQTT keepalive=30s(broker 约 45s 收不到包就踢), wspy 的读超时同样是 30s,
  而 `_recv_loop` 对任何异常都直接 `break` —— 聊天窗放着不动, 30 秒后必显示"已断开"。
  现在 `chat.py` 增加 `_keepalive_loop`(每 15s: MQTT 通道发 `PINGREQ 0xC0 0x00`, relay 通道发
  WS PING), 并让 `_recv_loop` 只对**帧间**的 `socket.timeout` 宽容(连续两轮≈60s 无任何数据才判死;
  EOF/流错位仍立即断开)。

- **验证**: ① wspy 假 socket 探针 **20 项全对**(改前 8 项不符): 握手残留首帧、分片重组、
  分片+中间 PING、首帧 PING、长度编码 125/126/65535/65536(收/发)、请求帧掩码、逐字节到达、
  CLOSE、帧中间超时当断线、帧间超时后重试; ② chat 探针 **11 项全对**(改前 6 项不符):
  PINGREQ 间隔与内容、relay WS PING、换连接/退出后保活线程自行结束、单次超时不断线、
  连续两次超时才判死、EOF 立即断开; ③ `py_compile` 全模块; ④ 重建后 dist==package(SHA256)
  且 dist 内嵌 9 个模块源码与磁盘逐字节相同; ⑤ `tests\pure-state-harness.py` 16/16。

- **未改但记录**: `wspy.connect()` 不校验 `Sec-WebSocket-Accept`(RFC 要求客户端校验),
  对可信端点无实际影响, 保持现状; python chat 仍**没有自动重连**(C# 版是 6s×3),
  本轮只修"空闲必掉线", 重连策略要做需单独一轮。

---

## 2026-09-11 (第二十八轮审计: 计算器插件 — 求值语义/结果格式/启动编码全错)

换维度: C# 插件 `plugins/calc.txt`(219 行) vs python `wgime-py-pure/plugins/calc.py`。
**计算器是"看着像、算出来完全不是一回事"的典型**: 用按 C# 源码独立重写的 oracle 跑 73 个表达式,
**51 个不一致**。

- **修复 ①: `%` 是整数取余, 不是百分号 (最严重, 会给出静默错误答案)**。
  C# 的求值**不是** eval, 是自写的递归下降解析器(`Calc`, calc.txt 79-106), 其中
  `%` 与 `* /` 同优先级、做的是 `(long)v % (long)x` —— 即**取余**; 而 python 原来是
  `eval(expr.replace('%', '/100'))`, 把 `%` 当百分号。于是 python 点 `1 0 % 3 =` 得到
  `0.009970089730807577`(把 `10%3` 拼成了 `10/1003`), **既不报错也不是用户要的答案**;
  C# 得到 `1`。同类: `7%2` C#=`1`/py=`0.00698…`、`100%7` C#=`2`/py=`0.0993…`、
  `5%2%2` C#=`1`/py=`4.98e-06`、`-5%3` C#=`-2`/py=`-0.00498…`(C# 的 long 取余符号跟**被除数**)。
  现在改为逐字移植 C# 的 `ParseExpr`/`ParseTerm`/`ParseFac` + `_cs_mod`(C# 风格取余, 不能直接用
  python 的 `a % b`) + `_to_long`(对齐 `(long)double` 的向零截断与越界抛异常) —— 连 `50%`=Err
  (缺右操作数)、`2%0`=Err(除零)、`0.5%0.3`=Err(两个操作数都截成 0) 都一致。

- **修复 ②: 结果格式与错误串**。C# `Calc` 末尾: 整数值且 |v|<1e15 → `((long)v).ToString()`,
  否则 `v.ToString("G10")`(十位有效数字); 失败一律 `"Err"`。python 原来是 `str(eval(...))`,
  于是 `4/2` C#=`2`/py=`2.0`、`1/3` C#=`0.3333333333`/py=`0.3333333333333333`、
  `0.1+0.2` C#=`0.3`/py=`0.30000000000000004`、`22/7` C#=`3.142857143`/py=`3.142857142857143`、
  `1234567890123.456` C#=`1.23456789E+12`/py=`1234567890123.456`; 错误提示 C# 是 `Err`
  (显示在大字行), python 是 `错误`/`仅支持数字+(),%` 两种中文串。另 C# 先**去掉全部空格**,
  所以 `1 2`=`12`; python 直接 SyntaxError。现在全部对齐(C# 的 `08`/`007` 也合法 = `8`/`7`,
  python 的 `eval` 反而因"前导 0"报错)。

- **修复 ③: 启动编码 `js` → `jsq`, 并补 `calc` 别名**。C# 插件头部是 `code = jsq`, 而
  `LoadPlugins` 之后还有一行 `if (Apps.TryGetValue("jsq", out cp)) Apps["calc"] = cp;`
  (wgime.bat 1751) —— 文档(README/使用说明/插件规范)写的都是 **`jsq`/`calc`**。python 插件却叫
  `js`, 所以照文档打 `jsq`/`calc` 在 python 版**什么都唤不出来**。现在 `CODE = 'jsq'`,
  并在 `main.find_launcher` 加了同款**盲转发**别名(`PLUGIN_CODE_ALIASES = {'calc': 'jsq'}`:
  jsq 解析出什么 calc 就是什么, 与 C# 直接复制 Apps 条目等价; 目标不存在时不产生映射, 所以
  用户自己的 `app = calc …` 不会被吞掉)。探针: 改前 `jsq`→None、`calc`→None; 改后两者都→`计算器`,
  而旧的 `js` 不再解析(C# 里本来就没有这个编码)。

- **修复 ④: 键位/显示/键盘直输 1:1**。C# 键位是 4x5 `C <- ( )` / `7 8 9 /` / `4 5 6 *` /
  `1 2 3 -` / `0 . = +`(**没有 `%` 键**, `%` 靠键盘直输; C# 有 `<-` 退格键), python 原来第一行是
  `( ) % C`(少了 `<-`、多了 `%`)。C# 显示是**两行**: 小字 `表达式 =` + 大字(当前输入/结果/`Err`,
  空串显 `0`), python 只有一行大字。现在卡片(客户区 (12,42) 240x58)、键位(12+c*62, 110+r*46, 54x38)、
  字号(8/17)、配色(C 红、运算符 accent、`=` primary)全部对齐, 并补上 C# 的**键盘直输**
  (`0123456789.+-*/%()` + 回车求值 + 退格删字符 + Esc 关闭 + 点完按钮还焦点回窗口) ——
  否则 python 版根本没法输入 `%`(取余)。

- **验证**: ① 独立 oracle **73 例 0 差异**(改前 51 差异); ② UI 端到端(真建窗 + 按坐标找键 + 点按)
  12 组按键序列全对、**几何 0 处不符**、键盘直输 `10%3` 回车得 `1`、0 个回调异常;
  ③ 启动编码探针(jq/calc 别名)前后对照; ④ `py_compile` 全模块; ⑤ `build-package.ps1` 重建后
  `dist\wgime-py.py` 与 `package\wgime-py.py` SHA256 相同、dist 内嵌 9 个模块源码与磁盘逐字节相同;
  ⑥ `tests\pure-state-harness.py` 16/16。

---

## 2026-09-11 (第二十七轮审计: 悬浮时钟插件 — 守护缺跨进程单例 + 配置宽松读 + 输入框崩溃)

换维度: C# 插件 `plugins/clock.txt`(818 行) vs python `wgime-py-pure/plugins/clock.py`。

- **修复 ①: 报时/闹钟守护缺跨进程单例 (对齐 C# `StartChimeWatcher` 的命名互斥体)**。
  C# 用 `new Mutex(true, "WgImeClockChime", out createdNew)` 保证全机只有一个报时/闹钟守护;
  python 只有模块级 `_watch_started[0]` 布尔, 于是有两种真实重复:
  - C# 形态与 python 形态**同时运行** (两者共用同一份 `%LOCALAPPDATA%\wgime\clock.cfg`) →
    同一闹钟弹两次窗、整点响两声;
  - 托盘"重载插件/config" 会 `load_py_plugins()` 重新 exec 出**新的模块对象**(`_watch_started=[False]`),
    而旧守护线程仍在跑, 再打开一次时钟窗就起第二个线程 —— 探针实测 `ClockChime` 线程由 1 变 2。
  现在 `_start_watcher` 先取 `win.single_instance('WgImeClockChime')` (与 C# **同名**), 已有守护在跑就不起
  (对齐 `if (!createdNew) return;`), 句柄存 `_watch_mx` 保活到进程结束。探针: 重载后线程数 1 (修前 2);
  子进程按同名互斥体探测得到"已存在" (修前"新创建")。

- **修复 ②: `clock.cfg` / `pomodoro.txt` 必须宽松读 (AGENTS §28)**。
  python 原来用严格 `open(..., encoding='utf-8-sig')`, 而 C# 是 `File.ReadAllLines(path, Encoding.UTF8)`
  (**替换式**解码, 永不抛)。用户把配置"另存为 ANSI(GBK)"后: `load_cfg` 是在 `ALARMS.clear()` **之后**才读
  文件, `UnicodeDecodeError` 被 `except Exception` 静默吞掉 → **整份闹钟凭空消失**, 随后任意一次保存
  (新增/删除/仅一次闹钟触发) 就把 clock.cfg 覆盖成只剩那一条, 属真数据丢失; 番茄统计同理整块空掉。
  改用 `_read_text()` (优先宿主 `engine.read_text`: utf-8-sig→gbk→utf-8+replace, 不可用才退回旧行为)。
  探针: GBK 配置修前 `alarms=0`, 修后 3 条全在且中文名/提醒语正确。

- **修复 ③: 时间输入框输 `²34` 会把按钮回调打崩**。
  `normalize()` 原来用 `d.isdigit()` 判 3-4 位数字, 但 `'²'.isdigit()` 为 True 而 `int('²')` 抛
  `ValueError` —— 该异常从 `ui.flat_button` 的回调里抛出(那里没有 try/except), 于是点"新增"直接报错、
  提示文字不更新。C# `int.TryParse` 只认 ASCII 数字, 从不抛。改用 `d.isdecimal()`。
  探针: 修前捕获到 `ValueError`(note 不更新), 修后正常提示 "时间格式错误，请输入 00:00–23:59"。

- **对齐 ④(小)**: "5分钟后提醒" 的 `threading.Timer` 触发后从 `_snooze_timers` 移除
  (对齐 C# `later.Dispose(); snoozeTimers.Remove(later)`), 不再随每次稍后提醒持续累积。

- **本轮核对一致(未改代码)**: 按 C# 源码独立重写 oracle, **187 例 0 差异** ——
  `RepeatMatches` 98 例(8 种重复 × 7 个星期 + 边界值)、`FmtCd`/`FmtSw`/`FmtMinutes` 59 例(含 1 小时/
  1 分钟进位点、毫秒截断、`TotalHours>=1` 分支)、`ValidAlarmTime` 16 例(`7:30`/`24:00`/全角/阿拉伯数字)、
  `EscapeCfg`/`UnescapeCfg` 14 例(按 `Uri.EscapeDataString` 的 unreserved 集逐字节复算); 另有
  Save→Load 往返(含 `|`/换行/emoji 的闹钟名)与 UI 文案+坐标逐项核对: 主窗 4 个 page、闹钟弹窗、闹钟管理窗
  的全部控件坐标与 C# **逐个一致**(含 38px 自绘标题栏偏移), C# 75 个含中文字面量里 python 只差
  `WgIme 休息提醒`(全屏窗在 python 用 `overrideredirect` Toplevel, 无窗口标题) —— **有意差异**。

- **验证**: `py_compile` 全模块 + 插件通过; `build-package.ps1` 重建 → `dist\wgime-py.py` 与
  `package\wgime-py.py` SHA256 相同; dist 内嵌的 9 个项目模块源码与磁盘**逐字节相同**(含 `main.py`),
  内嵌插件数 0 (插件不进 dist, 只有 `package\plugins\clock.py` 跟着更新);
  `tests\pure-state-harness.py` 16/16 通过。(dist 文件本轮仍随构建刷新: 内嵌第三方 zip 的时间戳每次
  构建都不同, 这是既有现象, 与插件无关。)

---

## 2026-09-10 (第二十六轮审计: 网络工具的纯计算部分 — 逐项核对一致, 未改代码)

换维度: C# `IpType`/`IpClass`/`SubnetCalc`/`SubnetSplit`/`RangeToCidr`/`MaskTable`/`TestPort`(2768-2909)
vs python `_ip_type`/`_ip_class`/`subnet_calc`/`subnet_split`/`range_to_cidr`/`mask_table`/`test_port`。

- **核对一致(未改代码)**: 用按 C# 源码**独立重写**的 oracle 逐项比对 ——
  - `IpType` / `IpClass` 各 **20 个边界地址**(0.0.0.0 / 127.x / 10.x / 172.15-16-31-32 / 192.168 /
    169.254 / 100.63-64-127-128 / 223 / 224 / 239 / 240 / 255.255.255.255 / 公网)
  - `SubnetCalc` **10 组**(/0 /8 /20 /24 /30 /31 /32、点分掩码、`/24` 带斜杠写法)+ 3 个报错用例
    (非连续掩码 `255.0.255.0`、前缀 `33`、非法掩码) 两边都抛
  - `SubnetSplit` **7 组**(count 0/1/2/3/8、/8 拆 4、/30 拆 2 → 两边都报"拆得太碎了 (主机数不足)")
  - `RangeToCidr` **6 组**(相邻、单地址、反向 `a>b`、`0.0.0.0-255.255.255.255`、整段对齐、跨网段)
  - `MaskTable` 逐行一致(含 `/8` + `PadRight` 的对齐格式)
  - `TestPort` 结果串格式与 C# 逐字相同: `open  Xms`(两个空格)、`closed (timeout Xms)`
- **有意差异(记录)**: 连接被**拒绝**时 C# 的串是 `closed (SocketException)`, python 是
  `closed (<Python 异常类名>)`(如 `ConnectionRefusedError`) —— 两边的异常类型体系不同, 保留(别去"对齐"类名)
- **环境观察(不是差异)**: 本机对**未监听的回环端口**连接不返回 RST, 而是 `WSAEWOULDBLOCK`(10035) 直到超时,
  所以 `test_port` 会报 `closed (timeout ...)`; C# 用 `BeginConnect + WaitOne(timeoutMs)` 在同一台机器上
  同样走超时分支 → 两版表现一致
- **验证**: 独立 oracle 比对 **0 差异**; `tests\pure-state-harness.py` 16/16 通过(本轮无产品代码改动,
  dist 未重建)

---

## 2026-09-10 (第二十五轮审计: `app =` 启动器 — 相对路径解析 + ShellExecute 启动)

换维度: C# `AddAppCand`/`LaunchApp`(2009-2040) vs python `find_launcher`/`run_launcher` 的 `app` 分支。

- **补齐(真差异)**:
  1. **相对路径解析**: C# 在 `LaunchApp` 里对"不含 `://`、含 `\` 或 `/`、且**非绝对路径**"的目标做
     `Path.Combine(BatDir, target)` —— 相对路径按**程序目录**解析; python 原来直接交给 `os.startfile`/
     `subprocess`, 于是 `app = xx  名称  bin\tool.exe` 会按**进程 CWD** 解析(双击启动/计划任务时 CWD
     可能是 `C:\Windows\System32` 之类) → **启动失败**。已按 C# 加上(含正斜杠形式、UNC 绝对路径不join)
  2. **启动方式**: C# 是 `ProcessStartInfo { UseShellExecute = true }` + `Arguments`; python 原来
     `args` 非空时用 `subprocess.Popen('"%s" %s' % (cmd, args), shell=True)` —— **过 cmd.exe**,
     参数里的 `&`/`^`/`%` 会被 shell 解释(注入/错参风险)。新增 `win.shell_execute()`(ctypes `ShellExecuteW`
     `'open'` + `args`/`cwd`, 返回是否成功)并在 `run_launcher` 里使用, 与 C# 同一条 ShellExecute 路径
- **核对一致(未改)**: 启动器候选 = `'▶' + 名称`、先去重再插到**最前**、记入 `ime.app_cand`(`appSet`),
  且"五笔唯一四码自动上屏"排除该候选; 候选插入顺序 dynamic → vmode → **启动器** → 自定义短语(短语最后插入
  所以居首); 冲突优先级 插件 > 步骤插件 > tools `code=` > `config app=` > 内置别名; 失败时托盘气泡
  "启动失败: 名称: 原因"(同 C# `TrayTip`); `builtin:tools/nettools/clip/note/color/pluginmgr` 分派
- **验证**: `win.shell_execute(不存在的路径)` 真调用返回 `False` 不抛; 用"真 main 前缀 + 桩 `shell_execute`"
  跑 11 项断言 **0 差异** —— 相对路径(`bin\np.exe`、`sub/dir/tool.bat`)解析到 `APP_DIR`、参数原样、
  绝对路径/裸 exe 名/URL/UNC 不变、失败给"启动失败"气泡、含 `&` 的参数原样传递(不过 shell);
  `tests\pure-state-harness.py` 16/16 通过; dist 内嵌 `win.py`/`main.py` 与磁盘逐字节相同、
  `dist==package` SHA256 相同(`AB9C805D…`)

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
