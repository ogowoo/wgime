# -*- coding: utf-8 -*-
"""main.py — WgIme-Pure 主程序: Python 3.12 + ctypes + tkinter, 零 .NET.
状态机与 wgime-py (pythonnet 版) 对齐, UI/注入换成纯 Python.
"""
import os
import sys
import threading
import time
import tkinter as tk
import importlib
import importlib.util

BASE = os.path.dirname(os.path.abspath(__file__))
DICT_DIR = os.environ.get('WGIME_DICT_DIR', r'C:\Tools\wgime')
DATA_DIR = os.path.join(os.environ['LOCALAPPDATA'], 'wgime-py')
os.makedirs(DATA_DIR, exist_ok=True)


def _dfn(text):
    try:
        with open(os.path.join(DATA_DIR, 'debug.log'), 'a', encoding='utf-8') as f:
            f.write('%.3f %s\n' % (time.time(), text))
    except Exception:
        pass


sys.path.insert(0, BASE)
import win
import hook
import tools
from engine import (Engine, dynamic_candidates, vmode_candidates, is_all_cjk,
                    load_config, shuangpin_expand, SYM_CAT_NAMES, SYM_CATS)
import plugins as plugmod
from bar import CandBar

engine = Engine(DICT_DIR, DATA_DIR)

CFG = {'sentence': True, 'assoc': True, 'trad': False, 'starton': True, 'shuangpin': 0,
       'apps': {}, 'hideidle': True, 'showcode': False, 'paste': 3, 'keyfix': True}


def apply_config():
    global CFG
    CFG = load_config(os.path.join(DICT_DIR, 'config.txt'))
    engine.FUZZY_PAIRS = tuple(tuple(p) for p in CFG['fuzzy'])
    ime.trad = CFG['trad']


VK = dict(F8=0x77, SPACE=0x20, BACK=0x08, ESC=0x1B, ENTER=0x0D, MINUS=0xBD, EQUALS=0xBB,
          LBRACKET=0xDB, RBRACKET=0xDD, TAP=0xF8, MODE=0xF9, TRAD=0xFA, MAKEWORD=0xFB, SEMI=0xBA, QUIT=0xFC)
MODE_NAMES = ('混合', '拼音', '五笔', '词典')


class Ime:
    active = False
    mode = 0
    trad = False
    buf = ''
    cands = []
    sel = 0
    page = 0
    dyn_set = set()
    assoc_showing = False
    last_commit = None
    sym_cat = 0
    recent = []
    app_cand = None


ime = Ime()
apply_config()

root = tk.Tk()
root.withdraw()
bar = CandBar(root)

try:
    import tray as _tray_mod
    TRAY = _tray_mod.Tray(root, {
        'toggle': lambda: set_active(not ime.active),
        'set_mode': lambda m: (setattr(ime, 'mode', m), reset()),
        'trad': lambda: (setattr(ime, 'trad', not ime.trad), reset()),
        'quit': root.destroy,
        'is_active': lambda: ime.active,
        'get_mode': lambda: ime.mode,
    })
    TRAY.start()
except Exception as e:
    _dfn('tray start err %r' % e)
    TRAY = None

PLUGINS = []
TOOLS = []


def reload_plugins():
    global PLUGINS, TOOLS
    PLUGINS, _ = plugmod.load_plugins(os.path.join(DICT_DIR, 'plugins'), DATA_DIR)
    TOOLS = plugmod.load_tools(os.path.join(DICT_DIR, 'tools.txt'))


def load_py_plugins():
    global PLUGINS
    PLUGINS = []
    if '_EMBEDDED_PLUGINS' in globals():                    # 单文件版: 用内嵌插件模块
        for key in _EMBEDDED_PLUGINS:
            PLUGINS.append(_EMBEDDED_PLUGINS[key])
        return
    pdir = os.path.join(BASE, 'plugins')                    # 开发版: 扫描 plugins/*.py
    if not os.path.isdir(pdir):
        return
    for fn in sorted(os.listdir(pdir)):
        if not fn.endswith('.py'):
            continue
        modname = 'plug_' + fn[:-3]
        try:
            spec = importlib.util.spec_from_file_location(modname, os.path.join(pdir, fn))
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            if hasattr(m, 'CODE') and hasattr(m, 'run'):
                PLUGINS.append(m)
        except Exception as e:
            _dfn('plugin load err %s %r' % (fn, e))


def find_launcher(code):
    if code in CFG['apps']:
        name, cmd, args = CFG['apps'][code]
        return (name, 'app', (cmd, args))
    for m in PLUGINS:
        if getattr(m, 'CODE', None) == code:
            return (getattr(m, 'NAME', code), 'plugin', m)
    b = {'itools': ('工具箱', 'toolbox'), 'tools': ('工具箱', 'toolbox'),
         'jlb': ('剪贴板历史', 'clipboard'), 'clip': ('剪贴板历史', 'clipboard'),
         'bj': ('便签', 'notes'), 'notes': ('便签', 'notes'),
         'ys': ('取色器', 'color'), 'color': ('取色器', 'color'),
         'net': ('网络工具', 'nettools'), 'wlgj': ('网络工具', 'nettools')}
    if code in b:
        return (b[code][0], 'builtin', b[code][1])
    return None


# ---------- 显示 ----------
def show_page():
    header = '[%s] ' % MODE_NAMES[ime.mode] + ('繁 ' if ime.trad else '')
    page_c = ime.cands[ime.page * 9:(ime.page + 1) * 9]
    if ime.assoc_showing:
        bar.show(header + '↪联想', '', page_c, 0)
    elif ime.buf and page_c:
        bar.show(header, ime.buf, page_c, ime.sel)
    else:
        bar.hide()


def refresh():
    ime.page = 0
    ime.sel = 0
    if not ime.buf:
        bar.hide()
        return
    if CFG['shuangpin'] == 0 and ime.buf == 'vf':
        ime.cands = list(SYM_CAT_NAMES) if ime.sym_cat == 0 else SYM_CATS[ime.sym_cat - 1].split(' ')
        show_page()
        return
    py = shuangpin_expand(ime.buf, CFG['shuangpin']) if (CFG['shuangpin'] > 0 and ime.mode < 2) else ime.buf
    cands, exact_wubi, extendable = engine.candidates(ime.buf, ime.mode, py)
    if CFG['sentence'] and (ime.mode == 1 or (ime.mode == 0 and len(py) > 4)):
        sent = engine.best_sentence(py.replace("'", ''))
        if sent and len(sent) > 1 and sent not in cands:
            cands.insert(0, sent)
    ime.dyn_set = set()
    if ime.mode < 3:
        for s in reversed(dynamic_candidates(ime.buf)):
            if s not in cands:
                cands.insert(0, s)
                ime.dyn_set.add(s)
        for s in reversed(vmode_candidates(ime.buf)):
            if s not in cands:
                cands.insert(0, s)
                ime.dyn_set.add(s)
    ime.app_cand = None
    lch = find_launcher(ime.buf)
    if lch:
        cand = '▶' + lch[0]
        if cand in cands:
            cands.remove(cand)
        cands.insert(0, cand)
        ime.app_cand = cand
    ime.cands = cands
    hook.COMPOSING[0] = bool(ime.buf or ime.assoc_showing or ime.sym_cat)
    _dfn('refresh buf=%s cands=%s' % (ime.buf, [repr(c) for c in cands[:4]]))
    if ime.mode == 2 and exact_wubi and not extendable and len(ime.buf) >= 4 and cands:
        commit(0)
        return
    show_page()


def clear_assoc():
    ime.assoc_showing = False
    ime.last_commit = None
    hook.COMPOSING[0] = bool(ime.buf)


def reset():
    ime.buf = ''
    ime.cands = []
    ime.page = 0
    ime.sel = 0
    ime.dyn_set = set()
    ime.assoc_showing = False
    ime.sym_cat = 0
    ime.app_cand = None
    hook.COMPOSING[0] = False
    bar.hide()


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
        bar.hide()
        return
    apick = ime.cands[i]
    prev = ime.last_commit
    engine.learn_assoc(prev, apick)
    inject(apick)
    ime.last_commit = apick
    show_assoc()


# ---------- 注入 (paste/keyfix 路由) ----------
APPMODES = {}
APPMODE_NAMES = {1: 'clipboard', 2: 'sendkeys', 3: 'key', 4: 'keyfix', 5: 'keyplain'}


def load_appmodes():
    global APPMODES
    APPMODES = {}
    try:
        for raw in open(os.path.join(DATA_DIR, 'pastemode.txt'), encoding='utf-8'):
            t = raw.strip()
            if not t or t[0] == '#':
                continue
            sp = t.find('=')
            if sp < 1:
                continue
            name, mode = t[:sp].strip().lower(), t[sp + 1:].strip().lower()
            APPMODES[name] = {'clipboard': 1, 'on': 1, 'off': 2, 'sendkeys': 2, 'keyfix': 4, 'keyplain': 5}.get(mode, 3)
    except OSError:
        pass


def effective_paste_mode():
    name = win.foreground_process_name()
    if name in APPMODES and APPMODES[name] in (1, 2, 3):
        return APPMODES[name]
    m = CFG.get('paste', 3)
    if m == 0:
        if not win.self_elevated() and win.foreground_elevated():
            return 1
        return 3
    return m


def effective_keyfix():
    name = win.foreground_process_name()
    o = APPMODES.get(name)
    if o == 4:
        return True
    if o == 5:
        return False
    return CFG.get('keyfix', True)


def inject(text):
    text = engine.to_trad(text, ime.trad)
    time.sleep(0.03)
    n = win.send_unicode(text)
    _dfn('inject %r sent=%s' % (text, n))


# ---------- 状态机 ----------
def record_commit(w, code):
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
        _dfn('made word %s %s' % (nw, nc))


def commit(i):
    if 0 <= i < len(ime.cands):
        text = ime.cands[i]
        if text == ime.app_cand:
            lch = find_launcher(ime.buf)
            if lch:
                run_launcher(lch)
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
                engine.learn_assoc(prev, learn_word)
            record_commit(learn_word, code)
            begin_assoc(learn_word)


def digit_as_code():
    return ime.mode < 2 and ime.buf.startswith('v') and (ime.buf[1:].isdigit() if len(ime.buf) > 1 else len(ime.cands) == 0)


def commit_char(idx):
    if not ime.cands:
        return
    w = ime.cands[0]
    c = w if len(w) == 1 else (w[0] if idx == 0 else w[-1])
    engine.learn(ime.buf, c, ime.mode)
    inject(c)
    reset()


def set_active(on):
    ime.active = on
    hook.set_active(on)
    reset()
    if 'TRAY' in globals() and TRAY:
        try:
            TRAY._refresh()
        except Exception:
            pass
    _dfn('active=%s' % on)


def run_launcher(l):
    name, kind, payload = l
    if kind == 'plugin':
        try:
            payload.run()
        except Exception as ex:
            _dfn('plugin run err %r' % ex)
        return
    if kind == 'builtin':
        _show_builtin(payload)
        return
    if kind == 'app':
        cmd, args = payload
        try:
            if '://' in cmd:
                os.startfile(cmd)
            elif args:
                import subprocess
                subprocess.Popen('"%s" %s' % (cmd, args), shell=True)
            else:
                os.startfile(cmd)
        except Exception as ex:
            _dfn('launch err %r' % ex)


def _show_builtin(kind):
    try:
        if kind == 'toolbox':
            tools.show_toolbox(TOOLS, DICT_DIR)
        elif kind == 'clipboard':
            tools.show_clipboard()
        elif kind == 'notes':
            tools.show_notes(DATA_DIR)
        elif kind == 'color':
            tools.show_color()
        elif kind == 'nettools':
            tools.show_nettools()
    except Exception as ex:
        _dfn('builtin err %s %r' % (kind, ex))


def makeword_clipboard():
    t = win.clipboard_text()
    if not t:
        t = ''
    t = t.strip()
    if 2 <= len(t) <= 8 and is_all_cjk(t):
        code = engine.code_for(t)
        if code and engine.add_user_word(t, code):
            _dfn('made clipboard word %s %s' % (t, code))
    else:
        _dfn('makeword: clipboard not 2-8 hanzi')


def handle(vk):
    _dfn('kb %02x active=%s buf=%s' % (vk, ime.active, ime.buf))
    if vk == VK['QUIT']:
        root.after(50, root.destroy)
        return
    if vk == VK['TAP'] or vk == VK['F8']:
        set_active(not ime.active)
        return
    if vk == VK['MODE']:
        ime.mode = (ime.mode + 1) % 4
        reset()
        return
    if vk == VK['TRAD']:
        ime.trad = not ime.trad
        reset()
        return
    if vk == VK['MAKEWORD']:
        makeword_clipboard()
        return
    if not ime.active:
        return
    # vf 符号面板
    if CFG['shuangpin'] == 0 and ime.buf == 'vf':
        if 0x31 <= vk <= 0x39:
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
                ime.buf = 'v'
                refresh()
            return
        if vk == VK['ESC']:
            reset()
            ime.sym_cat = 0
            return
        if vk in (VK['MINUS'], VK['EQUALS']):
            tp = (len(ime.cands) + 8) // 9
            if tp > 0:
                ime.page = (ime.page + (1 if vk == VK['EQUALS'] else -1) + tp) % tp
                show_page()
            return
        if vk == VK['ENTER']:
            reset()
            ime.sym_cat = 0
            return
        return
    if vk == VK['SEMI'] and CFG['shuangpin'] == 3:
        if ime.assoc_showing:
            clear_assoc()
        ime.buf += ';'
        refresh()
        return
    if 0x41 <= vk <= 0x5A:
        if ime.assoc_showing:
            clear_assoc()
        ime.buf += chr(vk + 32)
        if len(ime.buf) > 32:
            ime.buf = ime.buf[:32]
        refresh()
    elif vk == VK['SPACE']:
        if ime.assoc_showing and not ime.buf:
            clear_assoc()
            bar.hide()
            win.send_unicode(' ')
        elif ime.buf:
            commit(ime.sel)
    elif 0x30 <= vk <= 0x39:
        d = vk - 0x30
        if d == 0 and not ime.buf and not ime.assoc_showing:
            win.send_unicode('0')
        elif ime.assoc_showing and not ime.buf:
            pick_assoc(ime.page * 9 + d - 1)
        elif digit_as_code():
            ime.buf += str(d)
            refresh()
        elif ime.buf:
            idx = ime.page * 9 + (d - 1)
            if 0 <= idx < len(ime.cands):
                commit(idx)
            elif (ime.mode < 2 and ime.buf[0] == 'v' and (len(ime.buf) == 1 or ime.buf[1:].isdigit())):
                ime.buf += str(d)
                refresh()
        else:
            win.send_unicode(str(d))
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
    elif vk in (VK['MINUS'], VK['EQUALS']):
        tp = (len(ime.cands) + 8) // 9
        if tp > 0:
            ime.page = (ime.page + (1 if vk == VK['EQUALS'] else -1) + tp) % tp
            show_page()


# ---------- 主循环: 轮询钩子事件 ----------
reload_plugins()
load_py_plugins()
load_appmodes()


def poll():
    try:
        for _ in range(64):
            try:
                vk = hook.EVENTS.get_nowait()
            except Exception:
                break
            handle(vk)
    finally:
        hook.COMPOSING[0] = bool(ime.buf or ime.assoc_showing or ime.sym_cat)
        if root.winfo_exists():
            root.after(15, poll)


root.after(15, poll)
hook.start()
set_active(CFG['starton'])
root.mainloop()
