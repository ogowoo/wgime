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
import subprocess
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
from engine import (Engine, dynamic_candidates, vmode_candidates, is_all_cjk,
                    load_config, shuangpin_expand, SYM_CAT_NAMES, SYM_CATS)

engine = Engine(DICT_DIR, DATA_DIR)
cand_form = CandForm()
_h = cand_form.Handle   # 主线程上强制建句柄: 之后 BeginInvoke 都正确封送到主线程泵

CFG = {'sentence': True, 'assoc': True, 'trad': False, 'starton': True, 'shuangpin': 0, 'apps': {}, 'hideidle': True, 'showcode': False}


def apply_config():
    global CFG
    CFG = load_config(os.path.join(DICT_DIR, 'config.txt'))
    ImeBus.SemiAsCode = (CFG['shuangpin'] == 3)
    ime.trad = CFG['trad']
    import engine as _eng
    _eng.FUZZY_PAIRS = tuple(tuple(p) for p in CFG['fuzzy'])   # 配置可覆盖模糊音对


VK = dict(F8=0x77, SPACE=0x20, BACK=0x08, ESC=0x1B, ENTER=0x0D, MINUS=0xBD, EQUALS=0xBB,
          LBRACKET=0xDB, RBRACKET=0xDD, TAP=0xF8, MODE=0xF9, TRAD=0xFA, MAKEWORD=0xFB, SEMI=0xBA)
MODE_NAMES = ('混合', '拼音', '五笔', '词典')


class Ime:
    active = False
    mode = 0                    # 0=混合 1=拼音 2=五笔 3=词典
    trad = False
    buf = ''
    cands = []
    sel = 0
    page = 0
    dyn_set = set()             # 动态候选 (rq/sj/xq/v 金额), 不学习
    assoc_showing = False
    last_commit = None
    sym_cat = 0                 # vf 符号面板分类 (0=根)
    recent = []                 # 连续单字上屏 (自动造词)
    app_cand = None             # 当前应用启动候选 (▶...)


ime = Ime()
apply_config()


def show_page():
    header = '[%s] ' % MODE_NAMES[ime.mode] + ('繁 ' if ime.trad else '')
    page_c = ime.cands[ime.page * 9:(ime.page + 1) * 9]
    if ime.assoc_showing:
        cand_form.ShowCands(header + '↪联想', '', System.Array[str](page_c), 0)
    elif ime.buf and page_c:
        cand_form.ShowCands(header, ime.buf, System.Array[str](page_c), ime.sel)
    else:
        cand_form.HideBar()


def refresh():
    ime.page = 0
    ime.sel = 0
    if not ime.buf:
        cand_form.HideBar()
        return
    # vf 符号面板 (双拼下 vf 是真实音节, 禁用)
    if CFG['shuangpin'] == 0 and ime.buf == 'vf':
        ime.cands = list(SYM_CAT_NAMES) if ime.sym_cat == 0 else SYM_CATS[ime.sym_cat - 1].split(' ')
        show_page()
        return
    # 双拼: 查 py 侧用展开后的全拼
    py = shuangpin_expand(ime.buf, CFG['shuangpin']) if (CFG['shuangpin'] > 0 and ime.mode < 2) else ime.buf
    cands, exact_wubi, extendable = engine.candidates(ime.buf, ime.mode, py)
    # 造句 (一元格架): 拼音模式, 或混合模式且全拼长度>4
    if CFG['sentence'] and (ime.mode == 1 or (ime.mode == 0 and len(py) > 4)):
        sent = engine.best_sentence(py.replace("'", ''))
        if sent and len(sent) > 1 and sent not in cands:
            cands.insert(0, sent)
    # 动态候选 (rq/sj/xq) + v 模式金额: 置顶, 不学习
    ime.dyn_set = set()
    if ime.mode < 3:
        for s in reversed(dynamic_candidates(ime.buf)):
            if s not in cands:
                cands.insert(0, s)
                ime.dyn_set.add(s)
        for s in reversed(vmode_candidates(ime.buf)):       # [大写, 千分位] -> 大写在最前
            if s not in cands:
                cands.insert(0, s)
                ime.dyn_set.add(s)
    # 应用启动码 (config.txt app=): 精确匹配置顶
    ime.app_cand = None
    app = CFG['apps'].get(ime.buf)
    if app:
        cand = '▶' + app[0]
        if cand in cands:
            cands.remove(cand)
        cands.insert(0, cand)
        ime.app_cand = cand
    ime.cands = cands
    # 五笔约定: 唯一四码自动上屏 (仅纯五笔模式)
    if ime.mode == 2 and exact_wubi and not extendable and len(ime.buf) >= 4 and cands:
        commit(0)
        return
    show_page()


def clear_assoc():
    ime.assoc_showing = False
    ime.last_commit = None


def reset():
    ime.buf = ''
    ime.cands = []
    ime.page = 0
    ime.sel = 0
    ime.dyn_set = set()
    ime.assoc_showing = False
    ime.sym_cat = 0
    ime.app_cand = None
    cand_form.HideBar()


def show_assoc():
    if ime.last_commit and ime.mode < 3:
        lst = engine.get_assoc(ime.last_commit)
        if lst:
            ime.assoc_showing = True
            ime.cands = lst
            ime.page = 0
            show_page()
            return
    ime.assoc_showing = False


def begin_assoc(w):
    ime.last_commit = w if (w and len(w) <= 8 and is_all_cjk(w)) else None
    show_assoc()


def pick_assoc(i):
    if not (0 <= i < len(ime.cands)):
        clear_assoc()
        cand_form.HideBar()
        return
    apick = ime.cands[i]
    prev = ime.last_commit
    engine.learn_assoc(prev, apick)
    inject(apick)
    ime.last_commit = apick
    show_assoc()


def inject(text):
    text = engine.to_trad(text, ime.trad)
    time.sleep(0.03)                             # 让被吞按键的 keyup 先排空, 避免注入事件与在途消息交叠丢失
    n = Injector.Text(text)
    dbg('inject %s sent=%s fg=%s' % (text, n, Injector.ForegroundInfo()))


def record_commit(w, code):
    """连续单字上屏 (90s 内, 码可验证) 2-4 字自动造词 (C# RecordCommit)"""
    now = time.time()
    if not w or len(w) > 4 or not is_all_cjk(w):
        ime.recent = []
        return
    ime.recent.append((w, code, now))
    if len(ime.recent) > 6:
        ime.recent.pop(0)
    if len(w) != 1:
        return
    run = 0
    for word, cd, ts in reversed(ime.recent):
        if len(word) == 1 and now - ts <= 90 and cd in (engine.char_py.get(word) or []):
            run += 1
        else:
            break
    if run < 2:
        return
    run = min(run, 4)
    tail = ime.recent[-run:]
    nw = ''.join(w for w, _, _ in tail)
    nc = ''.join(c for _, c, _ in tail)
    ime.recent = []
    if engine.add_user_word(nw, nc):
        tray.ShowBalloonTip(2000, '造词', '已造词: %s (%s)' % (nw, nc), WF.ToolTipIcon.Info)


def commit(i):
    if 0 <= i < len(ime.cands):
        text = ime.cands[i]
        if text == ime.app_cand:                 # 应用启动码: 启动, 不上屏不学习
            launch_app(ime.buf)
            reset()
            return
        learn_word = text if text not in ime.dyn_set else None
        code = ime.buf
        prev = ime.last_commit
        inject(text)
        reset()
        if learn_word:
            engine.learn(code, learn_word, ime.mode)
            if prev and len(learn_word) <= 8 and is_all_cjk(learn_word):
                engine.learn_assoc(prev, learn_word)      # 连续上屏词对 -> 联想二元组
            record_commit(learn_word, code)
            begin_assoc(learn_word)


def launch_app(code):
    app = CFG['apps'].get(code)
    if not app:
        return
    name, cmd, args = app
    try:
        if '://' in cmd:
            os.startfile(cmd)
        elif args:
            subprocess.Popen('"%s" %s' % (cmd, args), shell=True)
        else:
            os.startfile(cmd)
        dbg('launch %s -> %s' % (code, cmd))
    except Exception as ex:
        tray.ShowBalloonTip(2000, '启动失败', '%s: %s' % (name, ex), WF.ToolTipIcon.Error)


def digit_as_code():                             # v 模式: v 开头后数字续码
    return ime.mode < 2 and ime.buf.startswith('v') and (ime.buf[1:].isdigit() if len(ime.buf) > 1 else len(ime.cands) == 0)


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
    dbg('vk=%02x active=%s buf=%s' % (vk, ime.active, ime.buf))
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
    if vk == VK['MAKEWORD']:                     # Ctrl+Alt+C: 剪贴板造词
        t = (Injector.ClipboardText() or '').strip()
        if 2 <= len(t) <= 8 and is_all_cjk(t):
            code = engine.code_for(t)
            if code and engine.add_user_word(t, code):
                tray.ShowBalloonTip(2000, '造词', '已造词: %s (%s)' % (t, code), WF.ToolTipIcon.Info)
            else:
                tray.ShowBalloonTip(2000, '造词', '已存在或缺码: %s' % t, WF.ToolTipIcon.Warning)
        else:
            tray.ShowBalloonTip(2000, '造词', '先复制 2-8 个汉字，再按 Ctrl+Alt+C', WF.ToolTipIcon.Warning)
        return
    if not ime.active:
        return
    # vf 符号面板路由
    if CFG['shuangpin'] == 0 and ime.buf == 'vf':
        if 0x31 <= vk <= 0x39:                   # 数字: 根=选分类, 分类内=选符号
            d = vk - 0x30
            if ime.sym_cat == 0:
                if 1 <= d <= len(SYM_CAT_NAMES):
                    ime.sym_cat = d
                    refresh()
            else:
                idx = ime.page * 9 + d - 1
                if 0 <= idx < len(ime.cands):
                    inject(ime.cands[idx])
                    reset()
                    ime.sym_cat = 0
            return
        if vk == VK['SPACE'] and ime.sym_cat > 0:
            if ime.cands:
                inject(ime.cands[ime.page * 9])
                reset()
                ime.sym_cat = 0
            return
        if vk == VK['BACK']:
            if ime.sym_cat > 0:
                ime.sym_cat = 0
                refresh()
            else:
                ime.buf = 'v'                      # 面板根退格 -> 回到 v
                refresh()
            return
        if vk == VK['ESC']:
            reset()
            ime.sym_cat = 0
            return
        if vk in (VK['MINUS'], VK['EQUALS']):    # 面板内翻页
            tp = (len(ime.cands) + 8) // 9
            if tp > 0:
                ime.page = (ime.page + (1 if vk == VK['EQUALS'] else -1) + tp) % tp
                show_page()
            return
        if vk == VK['ENTER']:
            reset()
            ime.sym_cat = 0
            return
        return                                   # 其它键忽略 (字母不进 vf)
    if vk == VK['SEMI'] and CFG['shuangpin'] == 3:   # 微软双拼 ing 键
        if ime.assoc_showing:
            clear_assoc()
        ime.buf += ';'
        refresh()
        return
    if 0x41 <= vk <= 0x5A:                       # A-Z
        if ime.assoc_showing:
            clear_assoc()
        ime.buf += chr(vk + 32)
        if len(ime.buf) > 32:
            ime.buf = ime.buf[:32]
        refresh()
    elif vk == VK['SPACE']:
        if ime.assoc_showing and not ime.buf:    # 联想行: 空格 = 真空格
            clear_assoc()
            cand_form.HideBar()
            Injector.Text(' ')
        elif ime.buf:
            commit(ime.sel)
    elif 0x30 <= vk <= 0x39:                     # 0-9
        d = vk - 0x30
        if d == 0 and not ime.buf and not ime.assoc_showing:
            Injector.Text('0')                   # 无缓冲: 0 原样上屏
        elif ime.assoc_showing and not ime.buf:
            pick_assoc(ime.page * 9 + d - 1)
        elif digit_as_code():                    # v 模式续码
            ime.buf += str(d)
            refresh()
        elif ime.buf:
            idx = ime.page * 9 + (d - 1)
            if 0 <= idx < len(ime.cands):
                commit(idx)
            elif (ime.mode < 2 and ime.buf[0] == 'v' and (len(ime.buf) == 1 or ime.buf[1:].isdigit())):
                ime.buf += str(d)                # v 模式: 超出候选数的数字续码 (对齐 C# Hook_OnSpaced 回退)
                refresh()
        else:
            Injector.Text(str(d))                # 无缓冲: 数字原样上屏
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


def set_mode(m):
    ime.mode = m
    reset()
    update_tray()


mi_toggle = WF.ToolStripMenuItem('启用/禁用 (Shift 轻拍)')
mi_toggle.Click += lambda s, e: set_active(not ime.active)
menu.Items.Add(mi_toggle)
mi_modes = WF.ToolStripMenuItem('模式')
for _m in range(4):
    mi_modes.DropDownItems.Add(WF.ToolStripMenuItem(MODE_NAMES[_m], None, (lambda s, e, m=_m: set_mode(m))))
menu.Items.Add(mi_modes)
mi_trad = WF.ToolStripMenuItem('繁体输出 (Ctrl+Shift+F)')
mi_trad.Click += lambda s, e: setattr(ime, 'trad', not ime.trad)
menu.Items.Add(mi_trad)
mi_reload = WF.ToolStripMenuItem('重载配置')
mi_reload.Click += lambda s, e: apply_config()
menu.Items.Add(mi_reload)
mi_open = WF.ToolStripMenuItem('打开数据目录')
mi_open.Click += lambda s, e: os.startfile(DATA_DIR)
menu.Items.Add(mi_open)
mi_quit = WF.ToolStripMenuItem('退出')
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
