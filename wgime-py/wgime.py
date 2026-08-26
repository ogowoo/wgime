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
import os
import subprocess
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
from System import Action as _Action
import System.Windows.Forms as WF
from WgBridge import KeyHook, CandForm, Injector, ImeBus, PluginHost

sys.path.insert(0, BASE)
from engine import (Engine, dynamic_candidates, vmode_candidates, is_all_cjk,
                    load_config, shuangpin_expand, SYM_CAT_NAMES, SYM_CATS)
import plugins as plugmod

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
PluginHost.Start()

# ---------- 插件 / 工具箱 ----------
PLUGINS = []
TOOLS = []


def reload_plugins():
    global PLUGINS, TOOLS
    PLUGINS, _ = plugmod.load_plugins(os.path.join(DICT_DIR, 'plugins'), DATA_DIR)
    TOOLS = plugmod.load_tools(os.path.join(DICT_DIR, 'tools.txt'))


def find_launcher(code):
    """返回 (显示名, kind, payload) 或 None。kind: app/plugin/tool/builtin"""
    if code in CFG['apps']:
        name, cmd, args = CFG['apps'][code]
        return (name, 'app', (cmd, args))
    for p in PLUGINS:
        if p.enabled and p.code == code:
            return (p.name, 'plugin', p)
    for tab in TOOLS:
        for b in tab['buttons']:
            if b['code'] == code:
                return ('工具:' + b['name'], 'tool', b)
    if code in ('itools', 'tools'):
        return ('工具箱', 'builtin', 'toolbox')
    if code in ('plugins', 'cjgl'):
        return ('插件管理', 'builtin', 'pluginmgr')
    if code in ('jlb', 'clip'):
        return ('剪贴板历史', 'builtin', 'clipboard')
    if code in ('bj', 'notes'):
        return ('便签', 'builtin', 'notes')
    if code in ('ys', 'color'):
        return ('颜色拾取', 'builtin', 'color')
    if code in ('net', 'wlgj'):
        return ('网络工具', 'builtin', 'nettools')
    return None


def _step_log(m):
    dbg('step: %s' % m)


def _step_msgbox(title, text):
    tray.ShowBalloonTip(2500, title, text, WF.ToolTipIcon.Info)


def _step_confirm(text):
    return WF.MessageBox.Show(text, '确认', WF.MessageBoxButtons.YesNo, WF.MessageBoxIcon.Question) == WF.DialogResult.Yes


def run_steps_bg(body):
    def work():
        try:
            fails = plugmod.run_steps(body, _step_log, _step_msgbox, _step_confirm)
            tray.ShowBalloonTip(2000, '工具箱', '执行完成' + ('' if fails == 0 else ' (%d 步失败)' % fails), WF.ToolTipIcon.Info)
        except Exception as ex:
            dbg('steps err %r' % ex)
    threading.Thread(target=work, daemon=True).start()


def run_launcher(l):
    name, kind, payload = l
    if kind == 'app':
        launch_app_payload(payload)
    elif kind == 'plugin':
        p = payload
        if p.kind == 'csharp':
            err = PluginHost.CompileAndRun(p.body, DATA_DIR, plugmod.hashlib.md5(p.body.encode('utf-8')).hexdigest()[:8])
            if err:
                tray.ShowBalloonTip(3000, '插件编译失败', err, WF.ToolTipIcon.Error)
        else:
            run_steps_bg(p.body)
    elif kind == 'tool':
        run_steps_bg('\n'.join(payload['steps']))
    elif kind == 'builtin':
        _builtin_post(payload)


def _builtin_post(payload):
    PluginHost.Post(_Action(lambda p=payload: _show_builtin(p)))


def _show_builtin(payload):
    if payload == 'toolbox':
        show_toolbox()
    elif payload == 'pluginmgr':
        show_plugin_mgr()
    elif payload == 'clipboard':
        show_clipboard()
    elif payload == 'notes':
        show_notes()
    elif payload == 'color':
        show_color()
    elif payload == 'nettools':
        show_nettools()


def launch_app_payload(payload):
    cmd, args = payload
    try:
        if '://' in cmd:
            os.startfile(cmd)
        elif args:
            subprocess.Popen('"%s" %s' % (cmd, args), shell=True)
        else:
            os.startfile(cmd)
    except Exception as ex:
        tray.ShowBalloonTip(2000, '启动失败', str(ex), WF.ToolTipIcon.Error)


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
    # 启动器 (config app= / 插件 / 工具 code): 精确匹配置顶
    ime.app_cand = None
    lch = find_launcher(ime.buf)
    if lch:
        cand = '▶' + lch[0]
        if cand in cands:
            cands.remove(cand)
        cands.insert(0, cand)
        ime.app_cand = cand
    # 短语 (config phrase=): 置顶
    ph = CFG.get('phrases', {}).get(ime.buf)
    if ph:
        if ph in cands:
            cands.remove(ph)
        cands.insert(0, ph)
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
    m = effective_paste_mode()
    if m == 1:
        Injector.Paste(text)
        dbg('paste %s fg=%s' % (text, Injector.ForegroundInfo()))
        return
    if m == 2:
        WF.SendKeys.Send(sanitize_sendkeys(text))
        return
    time.sleep(0.03)                             # 让被吞按键的 keyup 先排空, 避免注入事件与在途消息交叠丢失
    if effective_keyfix():
        n = Injector.TextQtFix(text)
    else:
        n = Injector.Text(text)
    dbg('inject %s sent=%s fg=%s' % (text, n, Injector.ForegroundInfo()))


def sanitize_sendkeys(s):
    out = []
    for ch in s:
        if ch in '+^%~(){}[]':
            out.append('{' + ch + '}')
        else:
            out.append(ch)
    return ''.join(out)


APPMODES = {}
APPMODE_NAMES = {1: 'clipboard', 2: 'sendkeys', 3: 'key', 4: 'keyfix', 5: 'keyplain'}


def load_appmodes():
    global APPMODES
    APPMODES = {}
    try:
        with open(os.path.join(DATA_DIR, 'pastemode.txt'), encoding='utf-8') as f:
            for raw in f:
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
    try:
        with open(os.path.join(DATA_DIR, 'pastemode.txt'), 'w', encoding='utf-8') as f:
            for k, v in APPMODES.items():
                f.write('%s=%s\n' % (k, APPMODE_NAMES.get(v, 'key')))
    except OSError:
        pass


def effective_paste_mode():
    name = Injector.ForegroundProcessName()
    if name in APPMODES and APPMODES[name] in (1, 2, 3):
        return APPMODES[name]
    m = CFG.get('paste', 3)
    if m == 0:                                   # auto: 提权窗口用剪贴板
        if not Injector.SelfElevated() and Injector.ForegroundElevated():
            return 1
        return 3
    return m


def effective_keyfix():
    name = Injector.ForegroundProcessName()
    o = APPMODES.get(name)
    if o == 4:
        return True
    if o == 5:
        return False
    return CFG.get('keyfix', True)


def toggle_app_paste():
    name = Injector.ForegroundProcessName()
    if not name:
        return
    if APPMODES.get(name) == 1:
        del APPMODES[name]
        tray.ShowBalloonTip(2000, '上屏方式', name + ' 已恢复默认上屏', WF.ToolTipIcon.Info)
    else:
        APPMODES[name] = 1
        tray.ShowBalloonTip(2000, '上屏方式', name + ' 改用剪贴板上屏', WF.ToolTipIcon.Info)
    save_appmodes()


def toggle_app_keyfix():
    name = Injector.ForegroundProcessName()
    if not name:
        return
    if APPMODES.get(name) in (4, 5):
        del APPMODES[name]
        tray.ShowBalloonTip(2000, '标点吞字修复', name + ' 已恢复全局默认', WF.ToolTipIcon.Info)
    else:
        APPMODES[name] = 5 if CFG.get('keyfix', True) else 4
        tray.ShowBalloonTip(2000, '标点吞字修复', name + (' 已单独关闭' if CFG.get('keyfix', True) else ' 已单独开启'), WF.ToolTipIcon.Info)
    save_appmodes()


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
        if text == ime.app_cand:                 # 启动器候选: 执行, 不上屏不学习
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


# ---------- 工具箱 / 插件管理 窗体 ----------
C_BG = System.Drawing.Color.FromArgb(255, 232, 237, 245)
C_SURFACE = System.Drawing.Color.White
C_ACCENT = System.Drawing.Color.FromArgb(255, 0, 122, 255)
C_TEXT = System.Drawing.Color.FromArgb(255, 29, 29, 31)


def show_toolbox():
    reload_plugins()
    f = WF.Form()
    f.Text = 'WgIme-Py 工具箱'
    f.BackColor = C_BG
    f.TopMost = True
    f.StartPosition = WF.FormStartPosition.CenterScreen
    tabs = WF.TabControl()
    tabs.Dock = WF.DockStyle.Fill
    for tab in TOOLS:
        page = WF.TabPage(tab['name'])
        fl = WF.FlowLayoutPanel()
        fl.Dock = WF.DockStyle.Fill
        fl.AutoScroll = True
        fl.BackColor = C_BG
        bw = 150 if tab['cols'] <= 2 else 90
        for b in tab['buttons']:
            btn = WF.Button()
            btn.Text = b['name']
            btn.Size = System.Drawing.Size(bw, 40)
            btn.BackColor = C_SURFACE
            btn.ForeColor = C_TEXT
            btn.FlatStyle = WF.FlatStyle.Flat
            steps = '\n'.join(b['steps'])
            btn.Click += (lambda s, e, body=steps: run_steps_bg(body))
            fl.Controls.Add(btn)
        page.Controls.Add(fl)
        tabs.TabPages.Add(page)
    f.Controls.Add(tabs)
    f.ClientSize = System.Drawing.Size(500, 420)
    f.Show()


def show_plugin_mgr():
    reload_plugins()
    f = WF.Form()
    f.Text = 'WgIme-Py 插件管理'
    f.BackColor = C_BG
    f.TopMost = True
    f.StartPosition = WF.FormStartPosition.CenterScreen
    f.ClientSize = System.Drawing.Size(420, 380)
    lst = WF.CheckedListBox()
    lst.Dock = WF.DockStyle.Fill
    lst.BackColor = C_SURFACE
    for p in PLUGINS:
        lst.Items.Add('%s (%s)  %s' % (p.name, p.code, os.path.basename(p.path)), p.enabled)
    f.Controls.Add(lst)
    bot = WF.Panel()
    bot.Dock = WF.DockStyle.Bottom
    bot.Height = 40
    bot.BackColor = C_BG

    def on_apply(s, e):
        disabled = set()
        for i in range(lst.Items.Count):
            if not lst.GetItemChecked(i):
                disabled.add(os.path.basename(PLUGINS[i].path))
        plugmod.save_disabled(DATA_DIR, disabled)
        reload_plugins()
        tray.ShowBalloonTip(1500, '插件管理', '已应用并重载', WF.ToolTipIcon.Info)
    ba = WF.Button()
    ba.Text = '应用'
    ba.Width = 80
    ba.Left = 12
    ba.Top = 7
    ba.Click += on_apply
    bot.Controls.Add(ba)
    bo = WF.Button()
    bo.Text = '打开目录'
    bo.Width = 90
    bo.Left = 104
    bo.Top = 7
    bo.Click += lambda s, e: os.startfile(os.path.join(DICT_DIR, 'plugins'))
    bot.Controls.Add(bo)
    f.Controls.Add(bot)
    f.Show()


# ---------- 剪贴板历史 / 便签 ----------
CLIP_HISTORY = []


def clip_poll():
    """1s 轮询剪贴板序列号, 变化时入历史"""
    from ctypes import windll, c_uint
    GetSeq = windll.user32.GetClipboardSequenceNumber
    act = GetSeq()
    while True:
        time.sleep(1)
        try:
            cur = GetSeq()
            if cur != act:
                act = cur
                t = (Injector.ClipboardText() or '').strip()
                if t and len(t) <= 5000 and (not CLIP_HISTORY or CLIP_HISTORY[0] != t):
                    CLIP_HISTORY.insert(0, t)
                    del CLIP_HISTORY[30:]
        except Exception:
            pass


clip_poll_thread = threading.Thread(target=clip_poll, daemon=True)
clip_poll_thread.start()


def show_clipboard():
    f = WF.Form()
    f.Text = 'WgIme-Py 剪贴板历史'
    f.BackColor = C_BG
    f.TopMost = True
    f.StartPosition = WF.FormStartPosition.CenterScreen
    f.ClientSize = System.Drawing.Size(420, 420)
    lst = WF.ListBox()
    lst.Dock = WF.DockStyle.Fill
    lst.BackColor = C_SURFACE
    for t in CLIP_HISTORY:
        lst.Items.Add(t.replace('\r', ' ').replace('\n', ' ')[:60])
    # 双击/按钮 = 复制回剪贴板
    def copy_selected(s, e):
        i = lst.SelectedIndex
        if 0 <= i < len(CLIP_HISTORY):
            Injector.SetClipboardText(CLIP_HISTORY[i])
    def paste_selected(s, e):
        i = lst.SelectedIndex
        if 0 <= i < len(CLIP_HISTORY):
            Injector.SetClipboardText(CLIP_HISTORY[i])
            time.sleep(0.15)
            Injector.Paste(CLIP_HISTORY[i])
    f.Controls.Add(lst)
    bot = WF.Panel()
    bot.Height = 40
    bot.Dock = WF.DockStyle.Bottom
    bot.BackColor = C_BG
    bc = WF.Button()
    bc.Text = '复制选中'
    bc.Width = 90
    bc.Left = 12
    bc.Top = 7
    bc.Click += copy_selected
    bot.Controls.Add(bc)
    bp = WF.Button()
    bp.Text = '粘贴上屏'
    bp.Width = 90
    bp.Left = 112
    bp.Top = 7
    bp.Click += paste_selected
    bot.Controls.Add(bp)
    f.Controls.Add(bot)
    f.Show()


def show_notes():
    f = WF.Form()
    f.Text = 'WgIme-Py 便签'
    f.BackColor = C_BG
    f.TopMost = True
    f.StartPosition = WF.FormStartPosition.CenterScreen
    f.ClientSize = System.Drawing.Size(420, 300)
    path = os.path.join(DATA_DIR, 'notes.txt')
    tb = WF.TextBox()
    tb.Multiline = True
    tb.Dock = WF.DockStyle.Fill
    tb.Font = System.Drawing.Font('Microsoft YaHei UI', 11)
    tb.BackColor = C_SURFACE
    tb.ForeColor = C_TEXT
    tb.ScrollBars = WF.ScrollBars.Vertical
    try:
        tb.Text = open(path, encoding='utf-8').read()
    except OSError:
        tb.Text = ''
    def on_close(s, e):
        try:
            open(path, 'w', encoding='utf-8').write(tb.Text)
        except OSError:
            pass
    f.FormClosed += on_close
    f.Controls.Add(tb)
    f.Show()


# ---------- 取色器 (跟随光标, 点击复制 hex) / 网络工具 ----------
def show_color():
    from ctypes import windll, Structure, byref, c_long

    class POINT(Structure):
        _fields_ = [('x', c_long), ('y', c_long)]

    f = WF.Form()
    f.FormBorderStyle = getattr(WF.FormBorderStyle, 'None')
    f.TopMost = True
    f.StartPosition = WF.FormStartPosition.CenterScreen
    f.ClientSize = System.Drawing.Size(180, 180)
    f.BackColor = System.Drawing.Color.Black
    lbl = WF.Label()
    lbl.Dock = WF.DockStyle.Bottom
    lbl.Height = 30
    lbl.TextAlign = WF.ContentAlignment.MiddleCenter
    lbl.ForeColor = System.Drawing.Color.White
    lbl.BackColor = System.Drawing.Color.Black
    f.Controls.Add(lbl)
    state = {'hex': '000000'}

    def tick():
        p = POINT()
        windll.user32.GetCursorPos(byref(p))
        if f.Bounds.Contains(p.x, p.y):
            return
        hdc = windll.user32.GetDC(0)
        px = windll.gdi32.GetPixel(hdc, p.x, p.y)
        windll.user32.ReleaseDC(0, hdc)
        r, g, b = px & 0xFF, (px >> 8) & 0xFF, (px >> 16) & 0xFF
        state['hex'] = '%02X%02X%02X' % (r, g, b)
        f.BackColor = System.Drawing.Color.FromArgb(r, g, b)
        lbl.Text = '#' + state['hex'] + '  (%d,%d)' % (p.x, p.y)

    def on_click(s, e):
        Injector.SetClipboardText('#' + state['hex'])
        tray.ShowBalloonTip(1500, '取色器', '已复制 #' + state['hex'], WF.ToolTipIcon.Info)
        f.Close()

    f.MouseClick += on_click
    tm = WF.Timer()
    tm.Interval = 60
    tm.Tick += lambda s, e: tick()
    f.Show()
    tm.Start()


def show_nettools():
    f = WF.Form()
    f.Text = 'WgIme-Py 网络工具'
    f.BackColor = C_BG
    f.TopMost = True
    f.StartPosition = WF.FormStartPosition.CenterScreen
    f.ClientSize = System.Drawing.Size(460, 340)
    tb = WF.TextBox()
    tb.Multiline = True
    tb.ReadOnly = True
    tb.Dock = WF.DockStyle.Fill
    tb.Font = System.Drawing.Font('Consolas', 9)
    tb.BackColor = System.Drawing.Color.FromArgb(255, 46, 48, 64)
    tb.ForeColor = System.Drawing.Color.FromArgb(255, 214, 217, 226)
    tb.ScrollBars = WF.ScrollBars.Vertical
    f.Controls.Add(tb)
    top = WF.Panel()
    top.Dock = WF.DockStyle.Top
    top.Height = 44
    top.BackColor = C_BG
    host = WF.TextBox()
    host.Text = 'www.baidu.com'
    host.Left = 12
    host.Top = 10
    host.Width = 160
    top.Controls.Add(host)

    def run_cmd(cmd):
        tb.Clear()
        def work():
            try:
                for line in subprocess.run(cmd, shell=True, capture_output=True, timeout=60).stdout.decode('utf-8', errors='replace').splitlines():
                    pass
                # stream-style: use Popen with line reads
            except Exception as ex:
                pass

        def work2():
            try:
                p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, encoding='utf-8', errors='replace')
                for line in iter(p.stdout.readline, ''):
                    tb.Invoke((lambda t=line: tb.AppendText(t)))
                p.stdout.close()
                p.wait()
            except Exception as ex:
                try:
                    tb.Invoke((lambda t=('ERR ' + str(ex) + '\r\n'): tb.AppendText(t)))
                except Exception:
                    pass
        threading.Thread(target=work2, daemon=True).start()

    def add_btn(text, x, cmd):
        b = WF.Button()
        b.Text = text
        b.Left = x
        b.Top = 9
        b.Width = 76
        b.Click += (lambda s, e, c=cmd: run_cmd(c))
        top.Controls.Add(b)
    add_btn('Ping', 184, 'ping -n 4 ' + host.Text)
    add_btn('Tracert', 268, 'tracert -d ' + host.Text)
    add_btn('NSLookup', 352, 'nslookup ' + host.Text)
    f.Controls.Add(top)
    f.Show()


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
mi_tools = WF.ToolStripMenuItem('工具箱')
mi_tools.Click += lambda s, e: show_toolbox()
menu.Items.Add(mi_tools)
mi_pm = WF.ToolStripMenuItem('插件管理')
mi_pm.Click += lambda s, e: show_plugin_mgr()
menu.Items.Add(mi_pm)
mi_reload = WF.ToolStripMenuItem('重载配置')
mi_reload.Click += lambda s, e: (apply_config(), reload_plugins())
menu.Items.Add(mi_reload)
mi_apppaste = WF.ToolStripMenuItem('当前程序: 剪贴板上屏切换')
mi_apppaste.Click += lambda s, e: toggle_app_paste()
menu.Items.Add(mi_apppaste)
mi_appfix = WF.ToolStripMenuItem('当前程序: 标点吞字修复切换')
mi_appfix.Click += lambda s, e: toggle_app_keyfix()
menu.Items.Add(mi_appfix)
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
load_appmodes()
reload_plugins()
hook_thread = threading.Thread(target=lambda: (hook.Install(), KeyHook.Pump()), daemon=True)
hook_thread.start()

threading.Thread(target=worker_loop, daemon=True).start()

update_tray()
tray.Visible = True
tray.ShowBalloonTip(2000, 'WgIme-Py', '阶段1已启动 (字典 %.0fms) — Shift 开关 / Ctrl+` 模式 / Ctrl+Shift+F 繁简' % engine.load_ms, WF.ToolTipIcon.Info)
dbg('started, dict %.0fms' % engine.load_ms)
WF.Application.Run()
