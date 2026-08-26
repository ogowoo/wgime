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

engine = Engine(DICT_DIR, DATA_DIR)
cand_form = CandForm()
_h = cand_form.Handle   # 主线程上强制建句柄: 之后 BeginInvoke 都正确封送到主线程泵

VK = dict(F8=0x77, SPACE=0x20, BACK=0x08, ESC=0x1B, ENTER=0x0D, MINUS=0xBD, EQUALS=0xBB,
          LBRACKET=0xDB, RBRACKET=0xDD, TAP=0xF8, MODE=0xF9, TRAD=0xFA)
MODE_NAMES = ('混合', '拼音', '五笔', '词典')


class Ime:
    active = False
    mode = 0                    # 0=混合 1=拼音 2=五笔 3=词典
    trad = False
    buf = ''
    cands = []
    sel = 0
    page = 0


ime = Ime()


def show_page():
    header = '[%s] ' % MODE_NAMES[ime.mode] + ('繁 ' if ime.trad else '')
    page_c = ime.cands[ime.page * 9:(ime.page + 1) * 9]
    if ime.buf and page_c:
        cand_form.ShowCands(header, ime.buf, System.Array[str](page_c), ime.sel)
    else:
        cand_form.HideBar()


def refresh():
    ime.page = 0
    ime.sel = 0
    if not ime.buf:
        cand_form.HideBar()
        return
    cands, exact_wubi, extendable = engine.candidates(ime.buf, ime.mode)
    ime.cands = cands
    # 五笔约定: 唯一四码自动上屏 (仅纯五笔模式)
    if ime.mode == 2 and exact_wubi and not extendable and len(ime.buf) >= 4 and cands:
        commit(0)
        return
    show_page()


def reset():
    ime.buf = ''
    ime.cands = []
    ime.page = 0
    ime.sel = 0
    cand_form.HideBar()


def inject(text):
    text = engine.to_trad(text, ime.trad)
    time.sleep(0.03)                             # 让被吞按键的 keyup 先排空, 避免注入事件与在途消息交叠丢失
    n = Injector.Text(text)
    dbg('inject %s sent=%s fg=%s' % (text, n, Injector.ForegroundInfo()))


def commit(i):
    if 0 <= i < len(ime.cands):
        text = ime.cands[i]
        engine.learn(ime.buf, text, ime.mode)
        inject(text)
    reset()


def commit_char(idx):                            # [ = 首字, ] = 末字 (取首候选的单字)
    if not ime.cands:
        return
    w = ime.cands[0]
    c = w if len(w) == 1 else (w[0] if idx == 0 else w[-1])
    engine.learn(ime.buf, c, ime.mode)
    inject(c)
    reset()


def set_active(on):
    ime.active = on
    ImeBus.Active = on
    reset()
    update_tray()
    dbg('active=%s' % on)


def handle(vk):
    """工作线程上的按键状态机 (事件来自 C# 实时层队列)。"""
    if vk == VK['F8'] or vk == VK['TAP']:
        set_active(not ime.active)
        return
    if vk == VK['MODE']:
        ime.mode = (ime.mode + 1) % 4
        reset()
        dbg('mode=%s' % MODE_NAMES[ime.mode])
        return
    if vk == VK['TRAD']:
        ime.trad = not ime.trad
        dbg('trad=%s' % ime.trad)
        return
    if not ime.active:
        return
    if 0x41 <= vk <= 0x5A:                       # A-Z
        ime.buf += chr(vk + 32)
        if len(ime.buf) > 32:
            ime.buf = ime.buf[:32]
        refresh()
    elif vk == VK['SPACE']:
        if ime.buf:
            commit(ime.sel)
    elif 0x31 <= vk <= 0x39:                     # 1-9
        if ime.buf and vk - 0x31 < len(ime.cands):
            commit(ime.page * 9 + (vk - 0x31))
        elif not ime.buf:
            Injector.Text(str(vk - 0x30))        # 无缓冲: 数字原样上屏
    elif vk == VK['LBRACKET']:
        commit_char(0)
    elif vk == VK['RBRACKET']:
        commit_char(1)
    elif vk == VK['BACK']:
        if ime.buf:
            ime.buf = ime.buf[:-1]
            refresh()
    elif vk == VK['ESC']:
        reset()
    elif vk == VK['ENTER']:
        if ime.buf:
            inject(ime.buf)
        reset()
    elif vk in (VK['MINUS'], VK['EQUALS']):      # 翻页
        tp = (len(ime.cands) + 8) // 9
        if tp > 0:
            if vk == VK['EQUALS']:
                ime.page = (ime.page + 1) % tp
            else:
                ime.page = (ime.page - 1 + tp) % tp
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


def on_closing():                                # 退出前落盘词频
    try:
        engine.save_freq()
    except Exception:
        pass


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
    on_closing()
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
tray.ShowBalloonTip(2000, 'WgIme-Py', '阶段1已启动 (字典 %.0fms) — Shift 开关 / Ctrl+` 模式 / Ctrl+Shift+F 繁简' % engine.load_ms, WF.ToolTipIcon.Info)
dbg('started, dict %.0fms' % engine.load_ms)
WF.Application.Run()
