# wgime-py-pure — 纯 Python 版（零 .NET / 零 pip 依赖）

`wgime.bat`/`WgIme.ps1` 之外的第二实现：**纯 Python 3.12+ 重写**（ctypes + tkinter），
不调 csc / 不依赖 .NET，规避 EDR 对 `csc.exe` 的告警与 PowerShell GPO 转录日志问题。
功能与 C# 版基本对齐（四模式 / 词频 / 简拼 / 双拼 / 造词 / 码表导入固化 / 启动器 / 工具箱 / 插件 /
候选窗 / 托盘 / 反查 / 简繁 / 整句 / 联想 / 空闲隐藏）。

## 目录结构

```
wgime-py-pure/
├── main.py                 # 入口（全功能单文件主程序）
├── win.py / hook.py / bar.py / engine.py / plugins.py / ui.py
│                           # 模块：原生 Win32 / 键盘钩子 / 候选窗 / 输入引擎 / 插件加载 / UI 设计系统
├── tray.py / tools.py / wspy.py
│                           # 托盘 / 工具箱 / 候选窗协助
├── plugins/
│   ├── calc.py             # 计算器      (js)
│   ├── chat.py             # 聊天中继    (lt)
│   ├── clock.py            # 悬浮时钟    (sz)
│   ├── wgime-qr.py         # 二维码      (qrcode)
│   └── wgtranslate.py      # 剪贴板翻译  (fy, perm=network)
│                           # 纯 Python 插件契约：模块级 CODE/NAME/DESC/VERSION/AUTHOR/PERM + run()
│                           # 窗口一律用 ui.py 设计系统（make_window/flat_button/...），不建 tk.Tk()
├── build-wgime-pure.py     # 收集模块 + 第三方 zip(pystray/uiautomation/comtypes) → 单文件 dist\
├── build-package.ps1       # 重建 dist\ + 组装 package\（含码表 dicts\、config/tools、plugins 平级拷贝）
├── run-csharp-plugin.ps1   # [csharp] sidecar 回退（PowerShell + CodeDom）；默认直调 csc.exe 缓存编译
├── dist\wgime-py.py        # 单文件发布（内嵌全部模块；不内嵌插件，插件从外部目录加载）
├── package\                # 可拷贝分发目录（build 产物，不入库；插件 = 步骤DSL txt(见下) + 本目录 plugins\*.py）
└── testing\                # 个人迭代实验（untracked，不入库；含 caret-helper 系列参考实现）
```

## 构建

```
powershell -NoProfile -File build-package.ps1     # 重建 dist\wgime-py.py 并刷新 package\
```

- `dist\wgime-py.py`：单文件（模块内嵌 + 第三方 zip 内嵌），可直接 `python dist\wgime-py.py`
- `package\`：可整体拷贝的生产目录——`wgime-py.py` + `dicts\`(码表) + `config.txt`/`tools.txt` +
  `plugins\`（构建时从仓库根 `plugins\` 只拷贝**步骤 DSL** 类 `*.txt`，如 clean-bin/qping/README；
  含完整 `[csharp]` 插件块的 txt 已被同功能 `.py` 取代、不再进入 python 分发；纯 Python 插件
  `*.py` 来自本目录 `plugins\`）+
  `run-csharp-plugin.ps1`
- 本机构建需要已 `pip install uiautomation`（读源码打包），**分发文件零 pip 依赖**

## 数据目录

`%LOCALAPPDATA%\wgime-py`（词频 / 联想 / 词库缓存 / runtime）。Microsoft Store 版 Python 会
虚拟化 `%LOCALAPPDATA%`，程序自动探测并切到 `~\wgime-py`（见 AGENTS.md §13）。

## 插件

- `plugins\*.py`：纯 Python 插件（本目录源码；构建时拷入 `package\plugins\`，`load_py_plugins`
  扫描 APP_DIR/plugins）。manifest：模块级 `CODE/NAME/DESC/VERSION/AUTHOR/PERM`；`run()` 建 UI。
- `plugins\*.py`（本目录）：纯 Python 插件。manifest：模块级 `CODE/NAME/DESC/VERSION/AUTHOR/PERM`；
  `run()` 建 UI。构建时拷入 `package\plugins\`（`load_py_plugins` 扫 APP_DIR/plugins）。
- `plugins\*.txt`（仓库根，仅步骤 DSL）：步骤 DSL / `[python]` 块由 `run_steps` 执行；
  含 `[csharp]` 插件块的 txt 属于 C# 版共享源（wgime.bat 分发用），**不进入 python 分发**——
  python 侧有同功能 `.py`（calc/chat/clock/wgtranslate/qr 均已 1:1 移植）。如确有需在 python 版
  运行遗留 C# txt 插件，`_run_csharp_plugin`/`run-csharp-plugin.ps1` sidecar 仍可用（直调 csc.exe，
  md5 缓存到 `%LOCALAPPDATA%\wgime-py\runtime\csc\`）。
- `.py` 与 `.txt` 同名 CODE 时，`.py` 优先（`load_py_plugins` 先于步骤插件注册）。
## 重要约定（改动前必读 AGENTS.md）

- 光标跟随 = 独立 Caret Helper 子进程（纯 ctypes vtable），主进程绝不初始化 COM/UIA（AGENTS.md §17）
- 候选条宽度上限 `min(工作区宽-24, 720)`，超宽动态截断候选（AGENTS.md §15）
- 词频排序 = 语料先验 + 学习词频 + 近期热度，是有意保留的升级（AGENTS.md §14）
- 改数据目录逻辑必须同步 `main.py`(DATA_DIR) 与 `build-wgime-pure.py`(preamble `_third_dir`)
- 插件权限模型：`perm=network/run/registry/destructive` 运行前确认（AGENTS.md §16）

## 运行

```
python wgime-py-pure\package\wgime-py.py     # 生产（推荐，插件目录齐全）
python wgime-py-pure\dist\wgime-py.py        # 单文件（插件需放到 %LOCALAPPDATA%\wgime-py\plugins）
```

`WGIME_DEBUG=1` 保留控制台看错误；托盘菜单「这个程序 → 重载配置」可热重载 config/tools/插件。

## 可配置快捷键（与 C# 版同一套键名 / 缺省值）

`config.txt` 里的 `hotkey_*`（全局快捷键，修饰键 `ctrl/alt/shift/win` 用 `+` 连接）与 `key_*`
（候选操作键，单个键名）两版通用；写 `none` 禁用，写错则忽略该行、保持缺省：

```ini
hotkey_toggle   = shift_tap      ; 开关输入法 (shift_tap = 轻点 Shift; 也可写 ctrl+alt+t 之类)
hotkey_mode     = ctrl+grave     ; 模式循环
hotkey_makeword = ctrl+alt+c     ; 造词
hotkey_trad     = ctrl+shift+f   ; 简繁切换
key_first       = space          ; 上屏当前候选
key_pageup      = minus          ; 上一页  (PgUp/PgDn 在组字中恒可用)
key_pagedown    = plus           ; 下一页
key_back        = backspace      ; 删编码
key_cancel      = esc            ; 取消组字
key_raw         = enter          ; 原样上屏编码
key_pickfirst   = lbracket       ; 以词定字 (首字)
key_picklast    = rbracket       ; 以词定字 (末字)
```

键名可用：`space enter esc backspace tab pgup pgdn home end left right up down grave minus plus
lbracket rbracket semicolon quote comma period slash backslash f1`~`f12`，以及单个字母/数字。
纯 Python 版另外自带 `F8`（硬开关）与 `Ctrl+Alt+Q`（退出）两个 C# 没有的键；
`hotkey_toggle` 配成非 `shift_tap` 时，Shift 轻拍随之停用（与 C# 一致）。

另：纯 Python 版启动时会取命名互斥体 `WgImePySingleInstance` 做**单实例**保护（C# 版是
`WgImeSingleInstance`，两者互不干扰），重复启动会提示「已在运行」并退出；测试脚本可用
环境变量 `WGIME_NO_SINGLETON=1` 跳过该检查。

## 运行模式（ime / tray）

`config.txt` 的 `mode` 键定义启动形态（与 C# 版合并 wgtray 方案对齐）：

- `mode = ime`（默认）：输入法 + 托盘菜单 —— 只含输入法控制项
  （开关/模式/选项/词库/这个程序），**不含** tray 的工具菜单；工具箱等工具在 ime
  模式仍可用输入码 `itools`/`net`/`clip`/`bj`/`ys` 唤起
- `mode = tray`：纯托盘工具箱 —— **不启动键盘 hook / 不建候选窗**，只出托盘
  图标（"工"字）+ 工具菜单（工具箱/内置工具/插件管理/config 应用/编辑配置），
  等价原 wgtray 行为

两模式的托盘菜单都含「运行模式 ▸ 输入法 (IME) / 托盘工具箱 (Tray)」子菜单：
点击会写回 `config.txt` 的 `mode=` 并**自动重启进程**生效（切换后状态干净）。

实现位置：`engine.load_config`(mode 键) → `main.is_tray_mode()`(分支) →
启动序尾部 `if is_tray_mode(): 不 hook.start()` → `main.switch_mode()`(写配置+重启) →
`tray.py`(按模式构建不同菜单 + `_tool_icon_img` 工字图标)。

## 内置工具（1:1 对齐 C# 版窗体）

`tools.py` 的内置工具按 C# 同名窗体逐个复刻（视觉按 `ui.py` 设计系统落地，功能与交互对齐）：

| C# 窗体 | python | 要点 |
|---|---|---|
| ToolsForm | `show_toolbox` | 560x470, `tools.txt` 标签页 + `[cols N]` 磁贴滚动, 底部日志控制台逐步打 `[ok]`/`[失败]`, 防重入, 单例 |
| NetToolsForm | `show_nettools` | 7 页签(独立日志缓冲), 手写 DNS, 子网全家桶(标准库 `ipaddress`), Ping/Tracert/端口/HTTP/本机 |
| ClipForm | `show_clipboard` | 去重+移置顶, 容量 200, 0.3s 轮询, 单击即复制 |
| NoteForm | `show_notes` | 多便签(≤9), 800ms 防抖自动保存, 6 色主题, 旧 `notes.txt` 迁移 |
| ColorForm | `show_color` | 全局鼠标钩子点取+锁定, HEX/rgb/HSV, 右键取消 |
| PluginMgrForm | `show_plugin_mgr` | 列表 + 重载/启停/打开目录/编辑/删除/新建模板/运行 |
| UserWordsDialog | `show_user_words` | 用户词表: 多选 + 全选/全不选/删除选中 → 落盘 `userwords.txt` 后后台重建词库 |
| ConfirmWordsDialog | `show_batch_makeword` | 批量造词: 选词表文件(每行一词) → 2-8 汉字去重 → 确认 → 一次性造词 |
| ImportDialog | `show_import` | 导入码表: 选文件 → 检测格式 → 目标词库确认 → 写 `import_*.txt` + 热重载 |
| BakeDialog | 无（不适用） | python 版码表就是 `py/wb/ec.txt` + `import_*.txt`（恒为持久叠加层），导入即固化，无需烘焙回单文件 |

**`code = xxx` 启动编码**（tools.txt 按钮行）：与 C# 一致注册成启动器候选。输入该编码上屏即
等价点击该按钮（无窗体，结果走**托盘气泡**汇总）；冲突优先级对齐 C#（后注册者胜）：
插件 > `tools.txt` 的 `code=` > `config.txt` 的 `app=` > 内置别名（`itools`/`net`/`clip`/`bj`/`ys`/`plugins`）。
`msg` 步骤同样走托盘气泡（无托盘时自动退回弹窗）。
