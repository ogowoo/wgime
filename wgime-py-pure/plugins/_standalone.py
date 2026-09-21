# -*- coding: utf-8 -*-
"""_standalone.py — 让 plugins/*.py 也能 `python xxx.py` **独立运行**的共享引导层 (第七十九轮).

**名字以 `_` 开头是故意的**: `main.load_py_plugins()` 跳过 `_` 开头的文件, 所以它不会被当成插件装载;
但它跟插件**同目录**, 插件文件尾的 `import _standalone` 能找到它 (standalone 时 sys.path[0] 就是本目录)。

**插件要支持双模式, 文件里加三块**(约定俗成, 全部都有才算数):
  1. **文件头**(在第一个宿主 import 之前 —— `import ui` 等在模块级, 不先修 sys.path 就 ImportError):
         if __name__ == '__main__':
             import os as _os, sys as _sys
             _sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))
  2. **清单**: `STANDALONE = True` (识别标记: 插件管理器据此显示"双模")
  3. **文件尾**:
         if __name__ == '__main__':
             import _standalone
             _standalone.standalone(run, NAME)

宿主装载时 `__name__` 是合成的模块名(不是 '__main__'), 三块都不执行, 与装载行为零冲突。
"""
import os
import sys


def _add_embedded_zip():
    """把宿主单文件内嵌的第三方 zip 挂进 sys.path (standalone 时宿主没解过包, 自己找).

    单文件运行时 build-wgime-pure 的 preamble 把它解到 `%LOCALAPPDATA%/wgime-py/site/thirdparty.zip`
    (Store Python 虚拟化则落到 `~/wgime-py/site/`); 都找不到就不管 —— 插件自己懒 import 时会报人话。
    """
    la = os.environ.get('LOCALAPPDATA', '')
    cands = []
    if la:
        cands.append(os.path.join(la, 'wgime-py', 'site', 'thirdparty.zip'))
    cands.append(os.path.join(os.path.expanduser('~'), 'wgime-py', 'site', 'thirdparty.zip'))
    for zp in cands:
        if os.path.isfile(zp) and zp not in sys.path:
            sys.path.insert(0, zp)
            return


def standalone(run, title=None):
    """插件 run() 的独立运行入口。返回进程退出码 (测试靠这个 + 那行标记判断成功)。

    步骤: 补 sys.path(宿主目录 = 本文件上级) -> 挂内嵌第三方 zip -> 建隐藏 Tk root ->
    run() 建窗口 -> 窗口被关就退出。`WGIME_STANDALONE_AUTOEXIT_MS=<毫秒>` 是**测试钩子**:
    到点自动关窗退出, 免得回归测试挂住。
    """
    here = os.path.dirname(os.path.abspath(__file__))          # plugins/
    host = os.path.dirname(here)                               # wgime-py-pure/
    for p in (host, here):
        if p not in sys.path:
            sys.path.insert(0, p)
    _add_embedded_zip()

    import tkinter as tk
    root = tk.Tk()
    root.withdraw()

    win = None
    try:
        win = run()
    except Exception as ex:
        import traceback
        traceback.print_exc()
        try:
            from tkinter import messagebox
            messagebox.showerror('WgIme 插件独立运行', '启动失败: %r' % (ex,))
        except Exception:
            pass
        return 1

    # run() 建出窗口就算"起来了" —— 打印机器可读的标记行 (回归测试断言它)
    print('STANDALONE-OK', getattr(run, '__module__', ''), flush=True)
    if win is None:
        return 0

    autoexit = 0
    try:
        autoexit = int(os.environ.get('WGIME_STANDALONE_AUTOEXIT_MS') or 0)
    except ValueError:
        autoexit = 0
    if autoexit > 0:
        root.after(autoexit, lambda: _force_quit(root, win))

    def _watch():
        try:
            if not win.winfo_exists():
                root.quit()
                return
        except Exception:
            root.quit()
            return
        root.after(200, _watch)

    root.after(200, _watch)
    root.mainloop()
    return 0


def _force_quit(root, win):
    """测试钩子: 先毁插件窗再退 mainloop (免得插件的 on_close 逻辑把退出搅乱)。"""
    try:
        if win is not None and win.winfo_exists():
            win.destroy()
    except Exception:
        pass
    root.quit()
