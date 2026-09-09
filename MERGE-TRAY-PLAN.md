# WgTray 模式合并方案（IME/Tray 双运行模式）

> 目标：把 wgtray（无输入法的托盘工具箱）收敛为 wgime 的一个**运行模式**（tray），
> 与输入法模式（ime）共存于同一程序。最终分发只保留三个版本：`wgime.bat`(bat 版) /
> `WgIme.ps1`(ps1 版) / python 版(`wgime-py.py`)，每个版本都内置 `mode = ime|tray`。
>
> 用户已确认三个决策：
> 1. **tray 语义** = wgtray 现有行为（无输入法 hook/候选窗，托盘工具菜单）
> 2. **旧独立 tray 文件退役**（wgtray.bat / WgTray.ps1 / wgtray-nopayload.bat 不再进分发）
> 3. **切换机制** = 托盘菜单写 config 的 `mode=` + 重启进程生效

---

## 一、现状梳理

### 1. 现在的两个 C# 程序（同源，靠构建脚本切分）

- **`wgime.bat`**（3.4MB）：WordBoard 类（IME：hook + 候选 + 组字/词库 + **托盘(NotifyIcon)**）
  + **内嵌全部工具代码**（ToolsForm/LaunchApp/NetTools/Clip/Note/Color/插件系统都在 wgime.bat 的 C# 里，
  wgtray 只是把工具部分"切片"出去）。即 wgime.bat 同时具备 IME + 托盘工具能力。
- **`wgtray.bat`**（361KB，无码表）：由 `build-wgtray.ps1` 从 wgime.bat C# **切片**出工具段 +
  `wgtray_glue.cs.txt`(TrayApp 外壳) 组装。TrayApp 复用 LaunchApp/ToolsForm/插件等，但**没有 WordBoard
  的 IME 窗体与键盘 hook**，托盘菜单 = 工具箱/内置工具/插件/config 应用/热键。
- 同理 ps1 版：`WgIme.ps1`（含完整 DLL+码表 trailer）/ `WgTray.ps1`。
- `wgtray-nopayload.bat`：bat 纯源码版（启动内存编译，杀软面小）。

### 2. python 版现状（wgime-py-pure，单文件 dist\wgime-py.py / package\）

- `main.py` 是**单一程序**：已含 hook(IME) + 托盘(TRAY) + 工具调用(输入码 itools 打开
  tools.show_toolbox / clipboard / notes / color / nettools / pluginmgr)。
- **没有独立 wgtray**：托盘菜单目前是 IME 控制菜单（开关/模式/选项/词库/这个程序/退出），
  "工具箱"只能靠输入码 itools 打开 —— tray 模式需给托盘菜单直接加工具入口。

### 3. 配置文件

- C# 版：`LoadConfig(dir)` 读 `config.txt`（同 wgtray 共用）；已有 starton/showcode/paste/... 键，
  **无 mode 键** → 加 `mode = ime|tray`（缺省 ime，向后兼容）。
- python 版：`engine.load_config` 同样格式 → 加 `mode` 键。

---

## 二、目标形态

```
config.txt:
  mode = ime          ; ime=输入法+tray工具(现状), tray=纯托盘工具箱(现 wgtray 行为)

启动: 读 mode 分支
  mode=ime  -> 现有 IME 主流程 (hook + 候选 + 托盘 IME 菜单 + 工具码)
  mode=tray -> 跳过键盘 hook / 不建候选窗; 托盘图标 + 工具菜单
               (工具箱/内置工具/插件/config 应用), 与现在 wgtray 行为一致
托盘菜单里加一项「运行模式」子菜单(ime/tray), 点击 -> 写回 config mode -> 重启进程
```

三版本最终形态：
| 版本 | 文件 | ime 模式 | tray 模式 |
|---|---|---|---|
| bat | `wgime.bat` | 现状 | 新增（托盘工具，无 IME） |
| ps1 | `WgIme.ps1` | 现状 | 新增（随 bat 自动） |
| py | `wgime-py.py` | 现状 | 新增 |

退役：`wgtray.bat`/`WgTray.ps1`/`wgtray-nopayload.bat` 不再作为分发物（构建脚本/切片保留可作参考，
但 sync-dist 与 release/wg-all 不再产出；AGENTS/docs 同步说明）。

---

## 三、C# 版（bat/ps1）实现要点 —— 风险高，需谨慎

> wgime.bat 是"源码真身 + bat 载荷"，C# 段（`$cs` here-string）约到 5850 行，之后是
> ###WGIME_DATA### 码表与 ###WGIME_DLL### 瘦 DLL。改 C# 段行数会牵动 build-wgtray.ps1 的
> **切片行号**（它按 anchor 从 wgime.bat 的行号切 wgtray 工具段）。

关键决策：**tray 模式与 ime 模式共用 WordBoard 的托盘 + 工具代码**（它们本来就在 wgime.bat C# 内），
差异只在"是否启动键盘 hook / 是否显示候选窗 / 托盘菜单是否含 IME 项"。

C# 实施步骤：
1. `LoadConfig` 读 `mode` 键 → 静态 `public static bool TrayMode;`（默认 false=ime）。
2. `WordBoard.RunApp(...)`：
   - ime：现状。
   - tray：`Hook` 不 Start（或 Start 后立即 IsLocked=true 且不装候选窗？）——
     更贴合 wgtray 语义：**不建 WordBoard 输入窗体**，直接建一个"托盘工具"路径：
     仍走 `Application.Run(form)` 但 form 只负责托盘与工具（参考 wgtray TrayApp 用的是隐藏 Ui()
     控件而非 Form）。
3. 托盘菜单构造：
   - tray 模式菜单 = wgtray 式：工具箱/插件/内置工具/应用(config.txt)/配置/热键/退出，
     并加「运行模式 ▸ 切到 ime」。
   - ime 模式菜单 = 现 WordBoard 托盘菜单 + 工具入口（工具原本由输入码触发；菜单里加
     「工具箱」项等价 LaunchApp("itools")）+「运行模式 ▸ 切到 tray」。
4. 切换动作：写 config `mode=` → 重启（bat 用 `Process.Start` 自身 + `Application.Exit`；
   ps1 由 bat 引导层同构）。重启后按新 mode 启动。
5. 分发行：sync-dist.ps1 / release / wg-all 移除 wgtray*；docs/AGENTS 更新。
   - 保留 build-wgtray.ps1 与 wgtray_glue.cs.txt 作为"切片参考/兼容回归"？→ 至少先不删 git 历史，
     暂停 sync-dist 产出即可。

风险：改 wgime.bat C# 段的行号会偏移 wgtray 切片 anchor → 若还跑 build-wgtray.ps1 会失败。
缓解：**先停用分发侧对 build-wgtray 的调用**，或在同一提交里同步更新 build-wgtray.ps1 的行号。
需要实测：改完 C# 后重编译瘦 DLL(tests\rebuild-wgime-bat-payload.ps1) + build-wgime-ps1.ps1。

---

## 四、python 版实现要点（本轮先做、可独立验证）

python 版已是"单程序 IME+tray+工具"，改动集中在 main.py / tray.py / engine.py：

1. `engine.load_config`：支持 `mode = ime|tray`（缺省 ime）。
2. `main.py` 启动序（约 1305-1370）：
   - 读 `CFG['mode']`。
   - `MODE_TRAY = (CFG.get('mode','ime')=='tray')`。
   - `MODE_TRAY` 时：**不 `hook.start()`**、不 `set_active`、不 ensure_caret_bg；
     `poll` 仍跑（托盘事件 + 收 hook 队列为空无害）。
3. 托盘菜单（tray.py）：
   - tray 模式下隐藏 IME 专属项（开关/模式/词库/选项里的输入法项），显示工具组：
     工具箱 / 网络工具 / 剪贴板 / 便签 / 取色 / 插件 / config 应用(CFG['apps'])。
   - 加「运行模式 ▸ 输入法模式 / 托盘工具模式」：写 config `mode=` → 重启进程。
4. 重启函数：参考 `_relaunch_if_console_python`；quit_app 前用 `os.execv`/`subprocess` 以
   `WGIME_RELAUNCHED=1` 重新拉起自身（无控制台跳转逻辑不变）。
5. dist\wgime-py.py 重建 + py_compile + 冒烟运行（GUI 环境可 start/quit）。

菜单差异最小化建议：pystray 菜单一次性构建，直接按 MODE_TRAY 走不同分支生成 Menu；
`_refresh()` 更新勾选态。

---

## 五、验收

- python：`mode=tray` 启动无键盘 hook（任务栏/键盘不受影响），托盘显示工具菜单，
  切换项写回 config 并重启为 ime 后可正常输入。
- bat/ps1：`wgime.bat` 正常 IME；config 改 mode=tray 后启动只出托盘工具；
  托盘菜单切回 ime 生效。
- 分发只剩三件套；`wgtray.bat`/`WgTray.ps1` 等不再进入 release/wg-all。

## 六、分步计划（轮次）

1. **[本轮]** python 版：config mode 键 + main/tray 分支 + 托盘工具菜单与切换项 → 验证 → 提交。
2. C# 版：wgime.bat C# 段加 TrayMode；托盘/重启逻辑；同步 build-wgtray.ps1 行号与重编译链 → 验证。
3. 分发收敛：sync-dist/release/wg-all 去掉 tray 文件；AGENTS/docs/CHANGELOG。
