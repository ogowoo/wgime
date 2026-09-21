# -*- coding: utf-8 -*-
r"""示例插件 —— 「普通单文件 Python 应用 → wgime 插件」的**可跑模板**（规范 §8.8）。

**它不会被自动装载**：文件名以 `_` 开头，`main.load_py_plugins()` 明确跳过下划线开头的文件
（所以插件管理器里看不到它、也不占任何启动编码）。拿它当模板：

  1. 复制/改名成 `插件目录\myplugin.py`（开发版 = `wgime-py-pure\plugins\`），**文件名不要以 `_` 开头**；
  2. 把 `CODE` 改成你自己的启动编码（小写 a-z，唯一；与内置冲突时插件优先）；
  3. 改 `NAME`/`DESC`，在 `run()` 里写你的逻辑。

独立运行（双模式三块齐，可直接跑）：
    python wgime-py-pure\plugins\_example-plugin.py

改造要点（全文见 docs\WGIME_插件规范.md §8.8）：
- 不要自己 `tk.Tk()` / `mainloop()` —— 宿主已经有 Tk root；窗口用 `ui.make_window()`；
- `run()` 跑在 Tk 主线程：慢活儿开 `threading.Thread(daemon=True)`，后台异常自己兜住；
- 模块级代码在**输入法启动时**就执行（即使用户从不点它）—— 重初始化放 `run()` 里；
- 读用户可改的文本用 `engine.read_text()`（GBK 容错）；
- 文件 UTF-8 无 BOM + **LF** 行尾。
"""
# ---- 双模式 (1/3): 独立运行时先把宿主目录(上级)插进 sys.path —— 必须在第一个宿主 import 之前 ----
if __name__ == '__main__':
    import os as _os, sys as _sys
    _sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))

import threading
import tkinter as tk

import ui

# ---- 清单: CODE/NAME 必填; 高权限(联网/执行命令/注册表/破坏性)按实声明 PERM, 运行前会弹确认 ----
CODE = 'demo'                # 启动编码: 小写 a-z, 唯一 —— 当插件用时改成你自己的
NAME = '示例插件'
DESC = '规范 §8.8 的可跑模板: 演示 ui 窗口 + 后台线程 + 双模式'
VERSION = '1.0'
AUTHOR = 'ogowoo'
PERM = 'low'                 # low | network | run | registry | destructive (可逗号多值)
STANDALONE = True            # 双模式 (2/3) 标记: 插件管理器据此显示"双模"


def run():
    """入口: 无参; 宿主在 Tk 主线程调用它(所以慢活儿要自己开线程)。"""
    win, content = ui.make_window(NAME, 420, 236)      # content 坐标原点 = 标题栏下方(y=38)

    tk.Label(content, text='输入一段文字, 点按钮在后台转成大写:',
             bg=ui.BG, fg=ui.SUB, font=ui.font(9)).place(x=16, y=12)
    ent = ui.rounded_entry(content, x=16, y=40, w=388, h=32, initial='hello wgime')
    out = tk.Label(content, text='(结果)', anchor='w', bg=ui.BG, fg=ui.TEXT, font=ui.font(12))
    out.place(x=16, y=132, width=388, height=28)

    def work():
        # 慢活儿(网络/大文件/子进程)必须离开主线程, 否则打字停摆;
        # 后台线程异常必须自己兜住 —— pythonw 下 sys.stdout/stderr 都是 None, 裸抛完全无声。
        try:
            text = ent.get().upper()
        except Exception as ex:
            text = '失败: %r' % (ex,)
        out.after(0, lambda: out.configure(text=text))  # 回主线程改控件

    ui.flat_button(content, '转大写', lambda: threading.Thread(target=work, daemon=True).start(),
                   primary=True, x=16, y=84, w=96, h=32)
    ui.flat_button(content, '关闭', win.destroy, x=326, y=84, w=78, h=32)
    return win                                          # 独立模式靠它判断"窗口起来了"


# ---- 双模式 (3/3): 独立运行时交给共享引导层(建隐藏 Tk root → run() → 关窗即退) ----
if __name__ == '__main__':
    import _standalone
    _standalone.standalone(run, NAME)
