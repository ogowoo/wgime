# -*- coding: utf-8 -*-
"""wgime-py phase-0 skeleton: tray + keyboard hook + candidate bar + pinyin typing.

架构: C# bridge 拥有实时层 (钩子吞键判定纯 C#, 不跨 GIL, 防 LowLevelHooksTimeout 摘钩);
      Python 工作线程从 ImeBus 队列消费按键事件, 驱动状态机/候选条/注入。
Toggle IME: F8. Letters buffer, Space/1-9 pick, Enter commits raw,
Backspace edits, Esc clears, -/= page. Tray: 启用/禁用 + 退出.
"""
import clr  # noqa: F401  (pythonnet 2.5.2 / .NET Framework 4.x)
import hashlib
import os
import sys
import threading
import time

BASE = os.path.dirname(os.path.abspath(__file__))
DICT_DIR = os.environ.get('WGIME_DICT_DIR', r'C:\Tools\wgime')
DATA_DIR = os.path.join(os.environ['LOCALAPPDATA'], 'wgime-py')
os.makedirs(DATA_DIR, exist_ok=True)


def dbg(m):
    try:
        with open(os.path.join(DATA_DIR, 'debug.log'), 'a', encoding='utf-8') as f:
            f.write('%.3f %s\n' % (time.time(), m))
    except Exception:
        pass


# ---------- compile / load bridge ----------
def load_bridge_dll():
    src_path = os.path.join(BASE, 'bridge.cs')
    with open(src_path, 'rb') as f:
        raw = f.read()
    md5 = hashlib.md5(raw).hexdigest()[:8]
    dll = os.path.join(DATA_DIR, 'bridge.%s.dll' % md5)
    if os.path.exists(dll):
        return dll
    clr.AddReference('Microsoft.CSharp')
    from Microsoft.CSharp import CSharpCodeProvider
    from System.CodeDom.Compiler import CompilerParameters
    par = CompilerParameters()
    par.GenerateInMemory = False
    par.OutputAssembly = dll
    par.GenerateExecutable = False
    for r in ('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll'):
        par.ReferencedAssemblies.Add(r)
    res = CSharpCodeProvider().CompileAssemblyFromSource(par, raw.decode('utf-8'))
    if res.Errors.Count > 0:
        raise RuntimeError('bridge compile: ' + res.Errors[0].ErrorText)
    return dll


clr.AddReference(load_bridge_dll())
clr.AddReference('System.Windows.Forms')
clr.AddReference('System.Drawing')
import System
import System.Windows.Forms as WF
from WgBridge import KeyHook, CandForm, Injector, ImeBus

sys.path.insert(0, BASE)
from engine import Engine

engine = Engine(DICT_DIR)
cand_form = CandForm()
_h = cand_form.Handle   # 主线程上强制建句柄: 之后 BeginInvoke 都正确封送到主线程泵

VK = dict(F8=0x77, SPACE=0x20, BACK=0x08, ESC=0x1B, ENTER=0x0D, MINUS=0xBD, EQUALS=0xBB)


class Ime:
    active = False
    buf = ''
    cands = []
    sel = 0
    page = 0


ime = Ime()


def show_page():
    all_c = engine.py.get(ime.buf) or []
    ime.cands = all_c[ime.page * 9:(ime.page + 1) * 9]
    if ime.buf and ime.cands:
        cand_form.ShowCands(ime.buf, System.Array[str](ime.cands), ime.sel)
    else:
        cand_form.HideBar()


def refresh():
    ime.page = 0
    ime.sel = 0
    show_page()


def reset():
    ime.buf = ''
    ime.cands = []
    ime.page = 0
    ime.sel = 0
    cand_form.HideBar()


def commit(i):
    if 0 <= i < len(ime.cands):
        text = ime.cands[i]
        n = Injector.Text(text)
        dbg('commit %s sent=%s fg=%s' % (text, n, Injector.ForegroundInfo()))
    reset()


def set_active(on):
    ime.active = on
    ImeBus.Active = on
    reset()
    update_tray()
    dbg('active=%s' % on)


def handle(vk):
    """工作线程上的按键状态机。"""
    if vk == VK['F8']:
        set_active(not ime.active)
        return
    if not ime.active:
        return
    if 0x41 <= vk <= 0x5A:                       # A-Z
        ime.buf += chr(vk + 32)
        refresh()
    elif vk == VK['SPACE']:
        if ime.buf:
            commit(ime.sel)
    elif 0x31 <= vk <= 0x39:                     # 1-9
        if ime.buf and vk - 0x31 < len(ime.cands):
            commit(vk - 0x31)
        elif not ime.buf:
            Injector.Text(str(vk - 0x30))        # 无缓冲: 数字原样上屏
    elif vk == VK['BACK']:
        if ime.buf:
            ime.buf = ime.buf[:-1]
            refresh()
    elif vk == VK['ESC']:
        reset()
    elif vk == VK['ENTER']:
        if ime.buf:
            Injector.Text(ime.buf)
        reset()
    elif vk in (VK['MINUS'], VK['EQUALS']):      # 翻页
        total = len(engine.py.get(ime.buf) or [])
        if vk == VK['EQUALS'] and (ime.page + 1) * 9 < total:
            ime.page += 1
            show_page()
        elif vk == VK['MINUS'] and ime.page > 0:
            ime.page -= 1
            show_page()


def worker_loop():
    while True:
        try:
            while True:
                e = ImeBus.Next()
                if e is None:
                    break
                handle(e.Vk)
        except Exception as ex:
            dbg('worker err %r' % ex)
        time.sleep(0.002)


# ---------- tray ----------
tray = WF.NotifyIcon()
tray.Icon = System.Drawing.SystemIcons.Application
menu = WF.ContextMenuStrip()
mi_toggle = WF.ToolStripMenuItem('启用/禁用 (F8)')
mi_toggle.Click += lambda s, e: set_active(not ime.active)
mi_quit = WF.ToolStripMenuItem('退出')
menu.Items.Add(mi_toggle)
menu.Items.Add(mi_quit)
tray.ContextMenuStrip = menu


def update_tray():
    tray.Text = 'WgIme-Py (%s)' % ('已启用' if ime.active else '已禁用')


def on_quit(s, e):
    cand_form.HideBar()
    tray.Visible = False
    WF.Application.Exit()


mi_quit.Click += on_quit

# ---------- single instance ----------
mutex = System.Threading.Mutex(True, 'WgImePy.SingleInstance')
if not mutex.WaitOne(0):
    WF.MessageBox.Show('WgIme-Py 已在运行')
    sys.exit(0)

# ---------- hook thread (C# realtime layer) ----------
hook = KeyHook()
hook_thread = threading.Thread(target=lambda: (hook.Install(), KeyHook.Pump()), daemon=True)
hook_thread.start()

threading.Thread(target=worker_loop, daemon=True).start()

update_tray()
tray.Visible = True
tray.ShowBalloonTip(2000, 'WgIme-Py', '阶段0骨架已启动 (字典加载 %.0fms), F8 开关' % engine.load_ms, WF.ToolTipIcon.Info)
dbg('started, dict %.0fms' % engine.load_ms)
WF.Application.Run()
