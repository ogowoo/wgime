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
