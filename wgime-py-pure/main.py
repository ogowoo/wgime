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
import ctypes

# DPI 感知: tkinter 与 Win32 物理坐标一致 (否则高分屏光标跟随错位)
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)      # PER_MONITOR_DPI_AWARE
except Exception:
    try:
        ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass

BASE = os.path.dirname(os.path.abspath(__file__))


def _find_dict_dir():
    """词库目录: WGIME_DICT_DIR 环境变量 > 单文件/脚本旁的 dicts 目录 > 仓库默认."""
    env = os.environ.get('WGIME_DICT_DIR')
    if env and os.path.exists(os.path.join(env, 'py.txt')):
        return env
    candidates = [BASE]
    try:
        candidates.insert(0, os.path.dirname(os.path.abspath(sys.argv[0])))
    except Exception:
        pass
    for b in candidates:
        d = os.path.join(b, 'dicts')
        if os.path.exists(os.path.join(d, 'py.txt')):
            return d
    return r'C:\Tools\wgime'


DICT_DIR = _find_dict_dir()
# 应用根(配置/插件/工具箱/run-csharp-plugin.ps1): 单文件版 = dicts 的父目录(package 根),
# 开发版 = DICT_DIR 本身(仓库根, 码表与 config/tools/plugins 平级)。
APP_DIR = os.path.dirname(DICT_DIR) if os.path.basename(DICT_DIR).lower() == 'dicts' else DICT_DIR


def _appdata_virtualized(path):
    """Store 版 Python (Microsoft Store, AppContainer 沙箱) 会把 %LOCALAPPDATA% 的写
    重定向(虚拟化)到 Packages\\...\\LocalCache\\Local\\, 导致真实路径不存在, 用户无法
    管理词库/配置/导入码表. 用探针(在 path 下建目录, 看 realpath 是否被重定向)检测."""
    try:
        os.makedirs(path, exist_ok=True)
        rep = os.path.realpath(path).lower()
        return '\\packages\\' in rep and '\\localcache\\' in rep
    except Exception:
        return False


_DATA_LA = os.path.join(os.environ['LOCALAPPDATA'], 'wgime-py')
if _appdata_virtualized(_DATA_LA):
    # Store 版 python: %LOCALAPPDATA% 被虚拟化 -> 把数据目录切到真实 USERPROFILE\\wgime-py,
    # 并把虚拟化位置(A 目录, 可读)里的旧用户数据搬过来, 避免词库/配置/导入码表丢失.
    import shutil
    DATA_DIR = os.path.join(os.path.expanduser('~'), 'wgime-py')
    os.makedirs(DATA_DIR, exist_ok=True)
    for _n in os.listdir(_DATA_LA):
        _src = os.path.join(_DATA_LA, _n)
        _dst = os.path.join(DATA_DIR, _n)
        if not os.path.exists(_dst):
            try:
                if os.path.isdir(_src):
                    shutil.copytree(_src, _dst)
                else:
                    shutil.copy2(_src, _dst)
            except Exception:
                pass
else:
    DATA_DIR = _DATA_LA
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
    CFG = load_config(os.path.join(APP_DIR, 'config.txt'))
    engine.FUZZY_PAIRS = tuple(tuple(p) for p in CFG['fuzzy'])
    ime.trad = CFG['trad']
    engine.learn_k = CFG.get('learnk', 5000)   # 全量学习词频排序权重 (config learnk)
    engine.recent_k = CFG.get('recentk', 200)  # 近期热度排序权重 (config recentk)


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
bar.set_theme(CFG.get('theme', 'dark'))

try:
    import tray as _tray_mod
    TRAY = _tray_mod.Tray(root, {
        'toggle': lambda: set_active(not ime.active),
        'set_mode': lambda m: (setattr(ime, 'mode', m), reset()),
        'trad': lambda: (setattr(ime, 'trad', not ime.trad), reset()),
        'quit': lambda: quit_app(),
        'is_active': lambda: ime.active,
        'get_mode': lambda: ime.mode,
        'apppaste': lambda: toggle_app_paste(),
        'appkeyfix': lambda: toggle_app_keyfix(),
        'followcaret': lambda: toggle_followcaret(),
        'get_followcaret': lambda: CFG.get('followcaret', True),
        'set_theme': lambda name: set_theme(name),
        'get_theme': lambda: CFG.get('theme', 'dark'),
        'import_table': lambda: tools.show_import(engine, DICT_DIR),
        'makeword': lambda: makeword_clipboard(),
    })
except Exception as e:
    _dfn('tray start err %r' % e)
    TRAY = None

PLUGINS = []
STEP_PLUGINS = []
TOOLS = []


def reload_plugins():
    global STEP_PLUGINS, TOOLS
    STEP_PLUGINS, _ = plugmod.load_plugins(os.path.join(APP_DIR, 'plugins'), DATA_DIR)
    TOOLS = plugmod.load_tools(os.path.join(APP_DIR, 'tools.txt'))


def load_py_plugins():
    global PLUGINS
    PLUGINS = []
    try:
        disabled = set(l.strip() for l in open(os.path.join(DATA_DIR, 'plugins-disabled.txt'), encoding='utf-8') if l.strip())
    except OSError:
        disabled = set()
    if '_EMBEDDED_PLUGINS' in globals():                    # 单文件版: 用内嵌插件模块
        for key in _EMBEDDED_PLUGINS:
            m = _EMBEDDED_PLUGINS[key]
            if getattr(m, 'CODE', None) not in disabled:
                PLUGINS.append(m)
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
            if hasattr(m, 'CODE') and hasattr(m, 'run') and m.CODE not in disabled:
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
    for p in STEP_PLUGINS:                                  # plugins/*.txt (步骤 DSL / [python] / [csharp])
        if getattr(p, 'enabled', True) and p.code == code:
            if p.kind == 'csharp':
                return (p.name, 'csharp', p)                # [csharp]: sidecar PowerShell 编译运行
            return (p.name, 'python' if p.kind == 'python' else 'step', p)
    b = {'itools': ('工具箱', 'toolbox'), 'tools': ('工具箱', 'toolbox'),
         'jlb': ('剪贴板历史', 'clipboard'), 'clip': ('剪贴板历史', 'clipboard'),
         'bj': ('便签', 'notes'), 'notes': ('便签', 'notes'),
         'ys': ('取色器', 'color'), 'color': ('取色器', 'color'),
         'net': ('网络工具', 'nettools'), 'wlgj': ('网络工具', 'nettools'),
         'plugins': ('插件管理', 'pluginmgr'), 'cjgl': ('插件管理', 'pluginmgr')}
    if code in b:
        return (b[code][0], 'builtin', b[code][1])
    return None


# ---------- 显示 ----------
def show_page():
    header = '[%s] ' % MODE_NAMES[ime.mode] + ('繁 ' if ime.trad else '')
    page_c = ime.cands[ime.page * 9:(ime.page + 1) * 9]
    total = (len(ime.cands) + 8) // 9
    follow = CFG.get('followcaret', True)
    # showcode: 候选上显示反查编码 (仅显示, 不改变上屏)
    if CFG.get('showcode'):
        page_c = [_with_code(w) for w in page_c]
    if ime.assoc_showing:
        bar.show(header + '↪联想', '', page_c, 0, ime.page, total, follow)
    elif ime.buf:
        # 缓冲非空即显示 (即使无候选) —— 无候选时也能看到已输入的编码, 不会"消失"
        bar.show(header, ime.buf, page_c, ime.sel, ime.page, total, follow)
    elif not CFG.get('hideidle', True):
        # hideidle=0: 常驻候选窗 (空闲也显示, 只显示模式状态)
        bar.show(header.rstrip(), '', [], 0, 0, 1, follow)
    else:
        bar.hide()


def _with_code(w):
    """候选 + 反查编码 (五笔模式用五笔码, 否则拼音)."""
    try:
        if ime.mode == 2:
            c = engine.wubi_code_for(w)
        else:
            c = engine.code_for(w)
        return '%s (%s)' % (w, c) if c else w
    except Exception:
        return w


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
    # 自定义短语 (config phrase=): 精确匹配置顶
    ph = CFG.get('phrases', {}).get(ime.buf)
    if ph:
        if ph in cands:
            cands.remove(ph)
        cands.insert(0, ph)
    ime.cands = cands
    hook.COMPOSING[0] = bool(ime.buf or ime.assoc_showing or ime.sym_cat)
    _dfn('refresh buf=%s cands=%s' % (ime.buf, [repr(c) for c in cands[:4]]))
    if ime.mode == 2 and exact_wubi and not extendable and len(ime.buf) >= 4 and cands:
        commit(0)
        return
    show_page()


def clear_assoc():
    global _last_learn
    ime.assoc_showing = False
    ime.last_commit = None
    _last_learn = None
    hook.COMPOSING[0] = bool(ime.buf)
    bar.hide()


def reset():
    global _last_learn
    ime.buf = ''
    ime.cands = []
    ime.page = 0
    ime.sel = 0
    ime.dyn_set = set()
    ime.assoc_showing = False
    ime.sym_cat = 0
    ime.app_cand = None
    _last_learn = None
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
    engine.touch_recent(ime.mode, apick)   # ④ 联想候选上屏也计入近期热度
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


def save_appmodes():
    names = {1: 'clipboard', 2: 'sendkeys', 3: 'key', 4: 'keyfix', 5: 'keyplain'}
    try:
        with open(os.path.join(DATA_DIR, 'pastemode.txt'), 'w', encoding='utf-8') as f:
            for k, v in APPMODES.items():
                f.write('%s=%s\n' % (k, names.get(v, 'key')))
    except OSError:
        pass


def toggle_app_paste():
    name = win.foreground_process_name()
    if not name:
        return
    if APPMODES.get(name) == 1:
        del APPMODES[name]
    else:
        APPMODES[name] = 1
    save_appmodes()


def toggle_app_keyfix():
    name = win.foreground_process_name()
    if not name:
        return
    if APPMODES.get(name) in (4, 5):
        del APPMODES[name]
    else:
        APPMODES[name] = 5 if CFG.get('keyfix', True) else 4
    save_appmodes()


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


# keyfix 的 X+Back 自我中和只在"符合规范的应用"(Win32 EDIT)里成立;
# 已知不兼容的程序(新记事本 UWP 等)自动关闭 keyfix, 避免上屏乱码。
# APPMODES(用户 pastemode.txt / 托盘)优先级更高, 可显式 keyfix 覆盖此白名单。
_KEYFIX_INCOMPATIBLE = {'notepad'}


def effective_keyfix():
    name = win.foreground_process_name()
    o = APPMODES.get(name)
    if o == 4:
        return True
    if o == 5:
        return False
    if name in _KEYFIX_INCOMPATIBLE:
        return False
    return CFG.get('keyfix', True)


def inject(text):
    text = engine.to_trad(text, ime.trad)
    m = effective_paste_mode()
    if m == 1:                                       # 剪贴板粘贴 (提权/UIPI 回退)
        win.paste_text(text)
        _dfn('paste %r' % text)
        return
    if m == 2:                                       # SendKeys 兜底: 无 .NET, 退回 key 注入
        pass
    time.sleep(0.03)                                 # 让被吞按键的 keyup 先排空
    fix = effective_keyfix()
    if fix and not win.self_elevated() and win.foreground_elevated():
        win.paste_text(text)                          # UIPI 回退: SendInput 注入不了提权窗口(与 C# auto/keyfix 一致)
        _dfn('paste(uipi) %r' % text)
        return
    if fix:
        n = win.send_unicode_qtfix(text)              # Qt 吞字修复: 全角标点后 X+Back
    else:
        n = win.send_unicode(text)
    _dfn('inject %r sent=%s' % (text, n))


# ---------- 状态机 ----------
def toggle_followcaret():
    CFG['followcaret'] = not CFG.get('followcaret', True)
    _dfn('followcaret=%s' % CFG['followcaret'])
    # 写回 config.txt (followcaret 行)
    try:
        path = os.path.join(APP_DIR, 'config.txt')
        lines = open(path, encoding='utf-8').read().split('\n')
        found = False
        for i, l in enumerate(lines):
            if l.strip().lower().startswith('followcaret'):
                lines[i] = 'followcaret = %s' % ('1' if CFG['followcaret'] else '0')
                found = True
                break
        if not found:
            lines.append('followcaret = %s' % ('1' if CFG['followcaret'] else '0'))
        open(path, 'w', encoding='utf-8').write('\n'.join(lines))
    except OSError:
        pass


def set_theme(name):
    CFG['theme'] = name
    bar.set_theme(name)
    _dfn('theme=%s' % name)
    # 写回 config.txt (theme 行)
    try:
        path = os.path.join(APP_DIR, 'config.txt')
        lines = open(path, encoding='utf-8').read().split('\n')
        found = False
        for i, l in enumerate(lines):
            if l.strip().lower().startswith('theme'):
                lines[i] = 'theme = %s' % name
                found = True
                break
        if not found:
            lines.append('theme = %s' % name)
        open(path, 'w', encoding='utf-8').write('\n'.join(lines))
    except OSError:
        pass


def quit_app():
    try:
        if 'TRAY' in globals() and TRAY and getattr(TRAY, 'icon', None):
            TRAY.icon.stop()                            # 停 pystray 循环 (其线程非 daemon)
    except Exception:
        pass
    try:
        engine.save_freq()                              # 同步落盘词频/LastPick/联想 (等价 C# SaveFreqSync)
    except Exception:
        pass
    try:
        root.destroy()
    except Exception:
        pass
    os._exit(0)                                         # 强制结束进程 (quit 场景)


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


_last_learn = None   # 最近一次"主动学习" (word, code, mode): 供退格误学回滚; 默认确认/动态候选为 None


def _rollback_last_learn():
    """误学回滚: 撤销最近一次主动学习 (词频 + LastPick + 近期窗口)."""
    global _last_learn
    if not _last_learn:
        return
    w, code, mode = _last_learn
    _last_learn = None
    try:
        engine.unlearn(w, code, mode)
        _dfn('unlearn %r %s' % (w, code))
    except Exception:
        pass


def commit(i):
    global _last_learn
    if 0 <= i < len(ime.cands):
        text = ime.cands[i]
        if text == ime.app_cand:
            lch = find_launcher(ime.buf)
            if lch:
                run_launcher(lch)
            reset()
            return
        code = ime.buf
        prev = ime.last_commit
        is_dyn = text in ime.dyn_set     # 必须在 reset() 前捕获: reset() 会清空 dyn_set
        inject(text)
        reset()
        if is_dyn:
            _last_learn = None
            return
        # 联想: 无论默认/主动都触发 (保留联想体验)
        if prev and len(text) <= 8 and is_all_cjk(text):
            engine.learn_assoc(prev, text)
        begin_assoc(text)
        # 近期热度: 所有上屏都计入 (反映最近使用习惯, 滑动窗口自动过期) —— 功能④
        engine.touch_recent(ime.mode, text)
        # ① 字频学习只对"主动选择"(非默认第1位/非动态)生效, 避免空格确认默认词被误强化
        if i > 0:
            engine.learn(code, text, ime.mode)
            record_commit(text, code)
            _last_learn = (text, code, ime.mode)
        else:
            _last_learn = None


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


def _refresh_tray():
    if 'TRAY' in globals() and TRAY:
        try:
            TRAY._refresh()
        except Exception:
            pass


def set_active(on):
    ime.active = on
    hook.set_active(on)
    reset()
    _refresh_tray()
    _dfn('active=%s' % on)


def run_steps_bg(body):
    """步骤 DSL 插件后台执行; msgbox/confirm marshal 回主线程 (tkinter 线程安全)."""
    from tkinter import messagebox as _mb

    def _msg(title, text):
        root.after(0, lambda: _mb.showinfo(title, text))

    def _confirm(text):
        ev = threading.Event()
        result = [False]

        def ask():
            try:
                result[0] = _mb.askyesno('确认', text)
            except Exception:
                pass
            ev.set()
        root.after(0, ask)
        ev.wait()
        return result[0]

    def work():
        try:
            fails = plugmod.run_steps(body, lambda m: _dfn('step %s' % m), _msg, _confirm)
            if fails:
                _dfn('steps fails %d' % fails)
        except Exception as ex:
            _dfn('steps err %r' % ex)
    threading.Thread(target=work, daemon=True).start()


_PY_RUNNER = '''import sys, json
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass
_ctxs = """__CTX__"""
ctx = json.loads(_ctxs) if _ctxs else {}
def _emit(obj):
    sys.stdout.write("@wgime " + json.dumps(obj, ensure_ascii=False) + "\\n")
    sys.stdout.flush()
__CODE__
if callable(globals().get("handle")):
    try:
        _emit({"ok": True, "actions": handle(ctx) or []})
    except Exception as e:
        _emit({"ok": False, "error": repr(e)})
elif callable(globals().get("run")):
    try:
        run()
        _emit({"ok": True})
    except Exception as e:
        _emit({"ok": False, "error": repr(e)})
else:
    _emit({"ok": True})
'''


def _run_python_block(body, code, name, ctx, timeout=60):
    """④ [python] 块子进程运行(隔离+超时熔断), 支持 JSON IPC 契约(handle(ctx)->actions).
    返回解析到的动作 dict 列表; 崩溃/超时只记日志, 不影响输入法."""
    import subprocess, tempfile, json, sys
    runner = (_PY_RUNNER
              .replace('__CTX__', json.dumps(ctx, ensure_ascii=False))
              .replace('__CODE__', body))
    fd, tmp = tempfile.mkstemp(suffix='.py', prefix='wgplug-')
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(runner)
    actions = []
    try:
        r = subprocess.run([sys.executable, tmp], timeout=timeout, capture_output=True,
                           text=True, encoding='utf-8', errors='replace')
        for line in r.stdout.splitlines():
            if line.startswith('@wgime '):
                try:
                    obj = json.loads(line[7:])
                except ValueError:
                    continue
                if isinstance(obj, dict):
                    actions += obj.get('actions', []) or []
                    if obj.get('error'):
                        _dfn('python-block err %r' % obj['error'])
    except subprocess.TimeoutExpired:
        _dfn('python-block timeout (%ss) [%s]' % (timeout, name))
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass
    return actions


def _run_python_plugin_actions(payload, ctx):
    """后台线程: 跑 [python] 块子进程 + 执行返回动作; msg/log 经 root.after marshal 回主线程."""
    from tkinter import messagebox as _mb
    try:
        actions = _run_python_block(payload.body, payload.code, payload.name, ctx)
    except Exception as e:
        _dfn('py-plugin err %r' % e)
        return
    for a in actions:
        if not isinstance(a, dict):
            continue
        act = a.get('action')
        if act == 'msg':
            try:
                root.after(0, lambda a=a: _mb.showinfo(payload.name or '插件', str(a.get('text', ''))))
            except Exception:
                pass
        elif act == 'log':
            _dfn('plugin-log %s' % a.get('text'))


def _confirm_plugin(payload):
    """② 插件权限确认: 声明了高权限(联网/执行命令/注册表/破坏性)的插件, 运行前弹确认."""
    meta = plugmod.plugin_meta(payload)
    if not plugmod.is_high_perm(meta):
        return True
    from tkinter import messagebox as _mb
    risk = plugmod.PERM_LABEL.get(meta['perm'], meta['perm'])
    v = str(meta.get('version') or ''); a = str(meta.get('author') or '')
    extra = (' [v%s %s]' % (v, a)).strip() if (v or a) else ''
    return _mb.askyesno('插件权限', '插件「%s」需要权限: %s%s\n确定运行?' % (meta['name'], risk, extra))


def run_launcher(l):
    name, kind, payload = l
    # ② 高权限插件运行前确认 (联网/执行命令/注册表/破坏性)
    if kind in ('plugin', 'step', 'python', 'csharp') and not _confirm_plugin(payload):
        _dfn('plugin perm denied %s' % name)
        return
    if kind == 'plugin':
        try:
            payload.run()
        except Exception as ex:
            _dfn('plugin run err %r' % ex)
        return
    if kind == 'step':                                     # 步骤 DSL 插件 (plugins/*.txt)
        run_steps_bg(payload.body)
        return
    if kind == 'python':                                   # [python] 块插件: 子进程+超时熔断 + JSON IPC; 后台线程跑, 不阻塞主线程打字
        ctx = {'code': payload.code, 'name': payload.name, 'buff': ime.buf, 'mode': ime.mode}
        threading.Thread(target=_run_python_plugin_actions, args=(payload, ctx), daemon=True).start()
        return
    if kind == 'csharp':                                   # [csharp] 插件: sidecar PowerShell + CodeDom
        runner = os.path.join(BASE, 'run-csharp-plugin.ps1')
        if not os.path.exists(runner):
            runner = os.path.join(APP_DIR, 'run-csharp-plugin.ps1')
        try:
            import subprocess
            subprocess.Popen(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                              '-File', runner, payload.path], creationflags=0x08000000)
        except Exception as ex:
            _dfn('csharp plugin err %r' % ex)
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
            tools.show_toolbox(TOOLS, APP_DIR)
        elif kind == 'clipboard':
            tools.show_clipboard()
        elif kind == 'notes':
            tools.show_notes(DATA_DIR)
        elif kind == 'color':
            tools.show_color()
        elif kind == 'nettools':
            tools.show_nettools()
        elif kind == 'pluginmgr':
            tools.show_plugin_mgr(PLUGINS, DATA_DIR, load_py_plugins)
    except Exception as ex:
        _dfn('builtin err %s %r' % (kind, ex))


def makeword_clipboard():
    t = (win.clipboard_text() or '').strip()
    prefill = t if 2 <= len(t) <= 8 and is_all_cjk(t) else ''
    tools.show_makeword(DATA_DIR, engine, prefill)


def handle(vk):
    _dfn('kb %02x active=%s buf=%s' % (vk, ime.active, ime.buf))
    if vk == VK['QUIT']:
        quit_app()
        return
    if vk == VK['TAP'] or vk == VK['F8']:
        set_active(not ime.active)
        return
    if vk == VK['MODE']:
        ime.mode = (ime.mode + 1) % 4
        reset()
        _refresh_tray()
        return
    if vk == VK['TRAD']:
        ime.trad = not ime.trad
        reset()
        _refresh_tray()
        return
    if vk == VK['MAKEWORD']:
        makeword_clipboard()
        return
    if not ime.active:
        return
    # vf 符号面板 (字母键不拦截, 继续组字 -> 退出面板)
    if CFG['shuangpin'] == 0 and ime.buf == 'vf' and not (0x41 <= vk <= 0x5A):
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
        if d == 0:
            # 0 不参与候选选择(候选是 1-9): 修复原 d-1 越界 / 多页按0误选上一页末位
            if ime.buf and digit_as_code():
                ime.buf += '0'
                refresh()
            elif ime.assoc_showing:
                clear_assoc()                                   # 0 非联想候选选择, 结束联想并上屏 0
                win.send_unicode('0')
            elif not ime.buf:
                win.send_unicode('0')
            # 组字中(非 v 模式)按 0: 忽略, 不打乱组字
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
        if ime.assoc_showing and not ime.buf:
            _rollback_last_learn()                   # ② 误学回滚: 刚上屏的词被退格删除, 撤销上次主动学习
            clear_assoc()                            # 联想态退格: 退出联想
            win.send_key_backspace()                 # 并把退格交给应用 (删刚上屏的字)
        elif ime.buf:
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
try:
    if TRAY:
        TRAY.start()
except Exception as e:
    _dfn('tray start err %r' % e)


def poll():
    try:
        # 先排空托盘动作 (pystray 线程入队, 此处主线程执行)
        try:
            import tray as _traymod
            for _ in range(8):
                try:
                    a = _traymod.TRAY_Q.get_nowait()
                except Exception:
                    break
                a()
        except Exception:
            pass
        for _ in range(64):
            try:
                vk = hook.EVENTS.get_nowait()
            except Exception:
                break
            handle(vk)
    finally:
        hook.COMPOSING[0] = bool(ime.buf or ime.assoc_showing or ime.sym_cat)
        try:
            if root.winfo_exists():
                root.after(15, poll)
        except Exception:
            pass


root.after(15, poll)
hook.start()
set_active(CFG['starton'])
root.mainloop()
