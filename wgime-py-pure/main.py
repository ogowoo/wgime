# -*- coding: utf-8 -*-
"""main.py — WgIme-Pure 主程序: Python 3.12 + ctypes + tkinter, 零 .NET.
状态机与 wgime-py (pythonnet 版) 对齐, UI/注入换成纯 Python.
"""
import os
import sys
import threading
import time
import tkinter as tk
import importlib.util
import ctypes
import re


def _relaunch_if_console_python():
    """无黑窗口引导: 若被控制台版 python.exe 启动(会弹一个黑色控制台窗口),
    立刻用 pythonw.exe(无控制台)重启自身并退出当前进程.
    - 仅在 win32 且当前解释器是 console 版时触发; pythonw/其他解释器跳过.
    - 环境变量 WGIME_DEBUG=1 时不自动跳走(保留控制台以看清错误).
    - WGIME_RELAUNCHED=1 防循环(避免个别环境下 pythonw 仍报 python.exe 造成二次重启).
    - 重启用同一套 sys.argv 传递(支持 argparse/文件路径), 不丢失参数.
    """
    if sys.platform != 'win32':
        return
    if os.environ.get('WGIME_DEBUG'):
        return
    if os.environ.get('WGIME_RELAUNCHED'):
        return                       # 已重启过一次, 停止(防循环)
    try:
        exe = (sys.executable or '').lower()
        if exe.endswith('pythonw.exe'):
            return                   # 已经是无控制台版, 无需重启
        if not (exe.endswith('python.exe') or exe.endswith('python3.exe')):
            return                   # 非标准解释器(如 venv/py launcher), 交给外层处理
        pw = os.path.join(os.path.dirname(sys.executable), 'pythonw.exe')
        if not os.path.exists(pw):
            return                   # 找不到 pythonw, 只能保留控制台
        import subprocess
        os.environ['WGIME_RELAUNCHED'] = '1'
        # STARTUPINFO 隐藏窗口 + 不弹出控制台; 继承当前 cwd 与参数.
        si = subprocess.STARTUPINFO()
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        si.wShowWindow = 0  # SW_HIDE
        subprocess.Popen([pw] + sys.argv, cwd=os.getcwd(),
                         startupinfo=si, creationflags=0x08000000)  # CREATE_NO_WINDOW
        os._exit(0)
    except Exception:
        return                       # 重启失败则不阻塞主流程, 保留当前进程(可能仍弹控制台)


_relaunch_if_console_python()


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
    """词库目录: WGIME_DICT_DIR > 单文件/脚本旁的 dicts 目录 > 上级 package/dicts > 上级目录(仓库根) > BASE.

    最后两级是给**开发布局**兜底的: `python wgime-py-pure\\dist\\wgime-py.py` 时码表其实在
    `..\\package\\dicts`(打包产物)或仓库根, 而 dist 目录里没有码表 —— 以前会静默退化成
    "空词库"(没有候选)并把空索引写进缓存, 让问题看起来像"缓存有问题"。
    """
    env = os.environ.get('WGIME_DICT_DIR')
    if env and os.path.exists(os.path.join(env, 'py.txt')):
        return env
    cands = []
    try:
        cands.append(os.path.dirname(os.path.abspath(sys.argv[0])))
    except Exception:
        pass
    cands.append(BASE)
    for b in list(cands):                      # 再往上一级找 (dist -> package / 仓库根)
        up = os.path.dirname(b)
        if up and up != b:
            cands.append(os.path.join(up, 'package'))
            cands.append(up)
    seen = set()
    for b in cands:
        if not b or b in seen:
            continue
        seen.add(b)
        for d in (os.path.join(b, 'dicts'), b):
            if os.path.exists(os.path.join(d, 'py.txt')):
                return d
    return BASE   # 找不到时退回脚本目录(而非写死开发机路径), 由后续词库加载提示


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


_DFN_ON = bool(os.environ.get('WGIME_DEBUG'))   # 与 win._dlog 同开关: 不设环境变量时不写盘


def _dfn(text):
    if not _DFN_ON:                              # 每键都打日志; 门控掉避免逐键 open/write/close debug.log
        return
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
                    load_config, shuangpin_expand, SYM_CAT_NAMES, SYM_CATS, read_text)
import plugins as plugmod
from bar import CandBar

# 单实例 (对齐 C# 的 WgImeSingleInstance 互斥体): 双开会导致钩子互相吞键/两个托盘图标.
# 名字带 Py 后缀, 与 C# 版互不干扰 (两种实现可以并存运行). WGIME_NO_SINGLETON=1 供测试脚本跳过.
_SINGLETON = [None]
if not os.environ.get('WGIME_NO_SINGLETON'):
    _SINGLETON[0] = win.single_instance('WgImePySingleInstance')
    if _SINGLETON[0] is None:
        win.message_box('WgIme (Python 版) 已在运行。\n请先从托盘退出正在运行的实例再启动。', 'WgIme', 0x30)
        sys.exit(0)

def _dict_cache_stale():
    """本次启动会不会重建索引 —— 与 `Engine._load_cache` **同源**判定 (都走 engine.cache_is_reusable):
    缓存缺失 / 版本不符 / **词库目录不同** / 任一码表 (含 import_*.txt) 的 size 或 mtime 变了 -> 要重建。
    用侧车 `dict-cache.pkl.sig`(小 JSON) 判断, 不反序列化 95MB 的缓存本体。
    """
    try:
        import engine as _eng
        return not _eng.cache_is_reusable(DICT_DIR, DATA_DIR)
    except Exception:
        return False


# 建表在下面同步进行; 冷启动 10s+ 期间总得给点反馈 (对齐 C# 候选条的"(词库加载中...)"提示)
root = tk.Tk()
root.withdraw()
_splash = None
if _dict_cache_stale():
    try:
        _splash = tk.Toplevel(root)
        _splash.overrideredirect(True)
        _splash.attributes('-topmost', True)
        _splash.configure(bg='#3B3836')
        tk.Label(_splash, text='WgIme 正在加载词库…', bg='#3B3836', fg='#FFFFFF',
                 font=('Microsoft YaHei UI', 11)).place(x=0, y=12, width=320, height=26)
        tk.Label(_splash, text='首次启动需建立索引, 请稍候 (之后走缓存, 秒开)', bg='#3B3836', fg='#B0ACA8',
                 font=('Microsoft YaHei UI', 8)).place(x=0, y=40, width=320, height=20)
        try:
            _sw, _sh = 320, 72
            _wa = win.screen_workarea()
            _splash.geometry('%dx%d+%d+%d' % (_sw, _sh, _wa.left + (_wa.right - _wa.left - _sw) // 2,
                                              _wa.bottom - _sh - 120))
        except Exception:
            _splash.geometry('320x72+100+100')
        _splash.update()                      # 立刻画出来(不等 mainloop)
    except Exception:
        _splash = None

_DICTS_MISSING = not os.path.exists(os.path.join(DICT_DIR, 'py.txt'))
if _DICTS_MISSING:
    print('[wgime] 没有找到码表 py.txt: 词库目录 = %s\n'
          '        请把 py.txt/wb.txt/ec.txt (以及 import_*.txt) 放进该目录, 或用 WGIME_DICT_DIR 指定。\n'
          '        现在会以"空词库"运行 —— 候选里不会有任何字词, 也不会写索引缓存。' % DICT_DIR,
          file=sys.stderr)

engine = Engine(DICT_DIR, DATA_DIR)
_dfn('startup: engine load=%.0fms (对齐 C# 的启动计时日志)' % engine.load_ms)
if _splash is not None:
    try:
        _splash.destroy()
    except Exception:
        pass
    _splash = None

CFG = {'sentence': True, 'assoc': True, 'trad': False, 'starton': True, 'shuangpin': 0,
       'apps': {}, 'hideidle': True, 'showcode': False, 'paste': 3, 'keyfix': True}


def apply_config():
    global CFG
    CFG = load_config(os.path.join(APP_DIR, 'config.txt'))
    engine.FUZZY_PAIRS = tuple(tuple(p) for p in CFG['fuzzy'])
    ime.trad = CFG['trad']
    engine.learn_k = CFG.get('learnk', 5000)   # 全量学习词频排序权重 (config learnk)
    engine.recent_k = CFG.get('recentk', 200)  # 近期热度排序权重 (config recentk)
    engine.assoc_enabled = CFG.get('assoc', True)   # config assoc=0 / 托盘关闭: 不学习也不显示联想 (对齐 C# AssocEnabled)
    hook.set_punct(CFG.get('cnpunct', True))   # 全角标点开关同步给钩子线程
    hook.configure(CFG.get('hotkeys'), CFG.get('ckeys'))   # hotkey_* / key_* -> 钩子线程 (对齐 C# LoadConfig)


def is_tray_mode():
    """运行模式: config mode=tray = 纯托盘工具箱 (对齐 wgtray, 无键盘 hook/候选窗).
    缺省 ime(输入法); mode 键由 engine.load_config 归一化为 'ime'/'tray'."""
    try:
        return CFG.get('mode', 'ime') == 'tray'
    except Exception:
        return False


def reload_config():
    """重载配置 + 工具箱 + 插件 + pastemode (对齐 C# ReloadConfig).
    改完 config.txt / tools.txt / plugins / pastemode.txt 后不必重启,
    托盘菜单'重载配置'或 Ctrl+` 重新生效."""
    global CFG
    apply_config()                                  # 重新读 config.txt -> CFG
    try:
        bar.set_theme(CFG.get('theme', 'dark'))     # 主题即时生效
    except Exception:
        pass
    reload_plugins()                                # 重读 plugins/*.txt + tools.txt -> TOOLS
    load_py_plugins()                               # 重扫 plugins/*.py
    load_appmodes()                                 # 重读 pastemode.txt
    try:
        _refresh_tray()                             # 托盘勾选/图标按新配置刷新
        if TRAY and getattr(TRAY, 'rebuild', None):
            TRAY.rebuild()                          # 插件/应用子菜单随配置重载重建
    except Exception:
        pass
    _dfn('reload config ok (theme=%s, tools=%d, plugins=%d)' %
         (CFG.get('theme'), len(TOOLS), len(PLUGINS)))


def open_config_file():
    """用默认编辑器打开 config.txt (对齐 C# OpenConfigFile)."""
    try:
        cfg = os.path.join(APP_DIR, 'config.txt')
        if not os.path.exists(cfg):
            with open(cfg, 'w', encoding='utf-8') as f:
                f.write('')                          # 缺失时先建空文件再打开
        os.startfile(cfg)
    except Exception as e:
        _dfn('open config err %r' % e)


def open_data_dir():
    """打开数据目录 (词频/用户词/码表缓存/便签; 对齐 C# OpenDataDir)."""
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        os.startfile(DATA_DIR)
    except Exception as e:
        _dfn('open data dir err %r' % e)


VK = dict(F8=0x77, SPACE=0x20, BACK=0x08, ESC=0x1B, ENTER=0x0D, MINUS=0xBD, EQUALS=0xBB,
          LBRACKET=0xDB, RBRACKET=0xDD, TAP=0xF8, MODE=0xF9, TRAD=0xFA, MAKEWORD=0xFB, SEMI=0xBA, QUIT=0xFC,
          PUNCT=0xFD)
MODE_NAMES = ('混合', '拼音', '五笔', '词典')


# 中文标点映射 (对齐 C# MapPunct; vk | 0x200 = Shift 按住, hook 编码)
_sq_open = [False]   # 单引号开闭交替状态
_dq_open = [False]   # 双引号开闭交替状态


def map_punct(vk, sh):
    if vk == 0xBC:
        return '《' if sh else '，'
    if vk == 0xBE:
        return '》' if sh else '。'
    if vk == 0xBA:
        return '：' if sh else '；'
    if vk == 0xBF:
        return '？' if sh else None          # 裸 / 透传
    if vk == 0xDC:
        return None if sh else '、'          # Shift+\ 透传 |
    if vk == 0xDB:
        return None if sh else '【'
    if vk == 0xDD:
        return None if sh else '】'
    if vk == 0x34:
        return '¥' if sh else None           # Shift+4
    if vk == 0xDE:                           # 引号开闭交替
        if sh:
            _dq_open[0] = not _dq_open[0]
            return '“' if _dq_open[0] else '”'
        _sq_open[0] = not _sq_open[0]
        return '‘' if _sq_open[0] else '’'
    return None


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

# root 已在建表前创建(用于冷启动加载窗), 这里直接用它建候选条
bar = CandBar(root, DATA_DIR)             # data_dir 用于位置持久化 (C# 同款 DataDir\pos.txt)
bar.set_theme(CFG.get('theme', 'dark'))

try:
    import tray as _tray_mod
    TRAY = _tray_mod.Tray(root, {
        'toggle': lambda: set_active(not ime.active),
        'set_mode': lambda m: (setattr(ime, 'mode', m), reset()),
        'trad': lambda: toggle_trad(),
        'get_trad': lambda: bool(ime.trad),               # 托盘「繁体输出」勾选态 (对齐 C# miTrad.Checked = Trad)
        'quit': lambda: quit_app(),
        'is_active': lambda: ime.active,
        'get_mode': lambda: ime.mode,
        'apppaste': lambda: toggle_app_paste(),
        # 托盘「这个程序」两项的勾选态 (对齐 C# RefreshMenuChecks: AppModes[前台] == 1 / EffectiveKeyfix())
        'get_apppaste': lambda: APPMODES.get(win.foreground_process_name(), 0) == 1,
        'get_appkeyfix': lambda: bool(effective_keyfix()),
        'appkeyfix': lambda: toggle_app_keyfix(),
        'followcaret': lambda: toggle_followcaret(),
        'get_followcaret': lambda: CFG.get('followcaret', True),
        'toggleshowcode': lambda: toggle_showcode(),
        'get_showcode': lambda: CFG.get('showcode', False),
        'togglesentence': lambda: toggle_sentence(),
        'get_sentence': lambda: CFG.get('sentence', True),
        'toggleassoc': lambda: toggle_assoc(),
        'get_assoc': lambda: CFG.get('assoc', True),
        'togglecnpunct': lambda: toggle_cnpunct(),
        'get_cnpunct': lambda: CFG.get('cnpunct', True),
        'togglehideidle': lambda: toggle_hideidle(),
        'get_hideidle': lambda: CFG.get('hideidle', True),
        'set_theme': lambda name: set_theme(name),
        'get_theme': lambda: CFG.get('theme', 'dark'),
        'import_table': lambda: tools.show_import(engine, DICT_DIR),
        'makeword': lambda: makeword_clipboard(),
        'batchmakeword': lambda: tools.show_batch_makeword(engine, DATA_DIR),
        'userwords': lambda: tools.show_user_words(engine),
        'reload': lambda: reload_config(),
        'open_config': lambda: open_config_file(),
        'open_datadir': lambda: open_data_dir(),
        # --- 运行模式 (ime/tray 双模式, 对齐 wgtray 合并方案) ---
        'get_runmode': lambda: CFG.get('mode', 'ime'),
        'switch_runmode': lambda m: switch_mode(m),
        # --- tray 模式工具入口 (等价 wgtray 托盘菜单; ime 模式亦可用) ---
        'toolbox': lambda: tools.show_toolbox(TOOLS, APP_DIR),
        'nettools': lambda: tools.show_nettools(),
        'clipboard': lambda: tools.show_clipboard(),
        'notes': lambda: tools.show_notes(DATA_DIR),
        'color': lambda: tools.show_color(),
        'pluginmgr': lambda: tools.show_plugin_mgr(PLUGINS, DATA_DIR, _reload_all_plugins,
                                                   run_file_fn=_run_plugin_file, list_files_fn=_list_plugin_files,
                                                   plugin_dir_fn=_plugin_dir),
        'run_app': lambda code: _run_app_by_code(code),
        'apps': lambda: list(sorted((CFG.get('apps') or {}).items())),
        # --- 插件 (托盘菜单列出 + 运行; 插件管理器复用) ---
        'list_plugins': lambda: _list_plugin_files(),
        'run_plugin_file': lambda path: _run_plugin_file(path),
        'plugin_dir': lambda: _plugin_dir(),
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
    tools.set_tools_cache(TOOLS)                     # code= 启动编码: 缓存工具数据供 find_launcher 查询


def load_py_plugins():
    """Load embedded and external .py plugins together.

    The old single-file branch returned immediately after embedded plugins, making
    plugins/*.py such as qr_code.py impossible to load.
    """
    global PLUGINS
    PLUGINS=[]
    try:
        disabled=set(l.strip().lower() for l in read_text(os.path.join(DATA_DIR,'plugins-disabled.txt')).split('\n') if l.strip())   # 禁用名单 = 小写文件名 (对齐 C#)
    except OSError:
        disabled=set()
    seen=set()
    if '_EMBEDDED_PLUGINS' in globals():
        for key,m in _EMBEDDED_PLUGINS.items():
            code=getattr(m,'CODE',None)
            # 内嵌插件没有磁盘文件, 管理器只能按 code 禁 (生产分发不内嵌插件, 此分支仅供自定义构建)
            if code and code.lower() not in disabled and code not in seen:
                PLUGINS.append(m);seen.add(code)
    # Search script-side and application-side plugin directories. Do not stop after
    # embedded modules. External plugins override an embedded plugin with same CODE.
    pdirs=[]
    for root in (BASE,APP_DIR):
        pdir=os.path.join(root,'plugins')
        if pdir not in pdirs:pdirs.append(pdir)
    for pdir in pdirs:
        if not os.path.isdir(pdir):continue
        if pdir not in sys.path:sys.path.insert(0,pdir)
        for fn in sorted(os.listdir(pdir)):
            if not fn.lower().endswith('.py') or fn.startswith('_'):continue
            path=os.path.join(pdir,fn);modname='wgime_ext_'+str(abs(hash(os.path.abspath(path))))+'_'+fn[:-3]
            try:
                spec=importlib.util.spec_from_file_location(modname,path)
                if spec is None or spec.loader is None:raise ImportError('no module spec')
                m=importlib.util.module_from_spec(spec);sys.modules[modname]=m
                spec.loader.exec_module(m)
                code=getattr(m,'CODE',None)
                if not code or not callable(getattr(m,'run',None)):
                    raise ValueError('plugin must define CODE and callable run()')
                if fn.lower() in disabled:continue                     # 按文件名禁用 (对齐 C#; 管理器写的就是文件名)
                # External plugin wins over built-in with the same launch code.
                PLUGINS[:]=[x for x in PLUGINS if getattr(x,'CODE',None)!=code]
                PLUGINS.append(m);seen.add(code)
                _dfn('plugin loaded %s code=%s'%(path,code))
            except Exception as e:
                sys.modules.pop(modname,None)
                _dfn('plugin load err %s %r'%(path,e))


# 插件编码别名 (对齐 C# `LoadPlugins` 之后那行: Apps["calc"] = Apps["jsq"])
PLUGIN_CODE_ALIASES = {'calc': 'jsq'}


def find_launcher(code):
    """启动编码 -> 启动器. 冲突优先级对齐 C# (后注册者胜): 插件 > tools.txt code= > config app= > 内置别名."""
    # 插件别名: C# LoadPlugins 之后 `if (Apps.TryGetValue("jsq", out cp)) Apps["calc"] = cp;`
    # (计算器已从内置迁出为 plugins\calc.txt 插件, 但 jsq/calc 两个编码都能唤出; 别名是**盲复制**,
    #  jsq 解析出什么, calc 就是什么 —— 所以这里直接转发, 不加额外条件)
    _tgt = PLUGIN_CODE_ALIASES.get(code)
    if _tgt:
        _r = find_launcher(_tgt)
        if _r is not None:
            return _r
    for m in PLUGINS:
        if getattr(m, 'CODE', None) == code:
            return (getattr(m, 'NAME', code), 'plugin', m)
    for p in STEP_PLUGINS:                                  # plugins/*.txt (步骤 DSL / [python] / [csharp])
        if getattr(p, 'enabled', True) and p.code == code:
            if p.kind == 'csharp':
                return (p.name, 'csharp', p)                # [csharp]: sidecar PowerShell 编译运行
            return (p.name, 'python' if p.kind == 'python' else 'step', p)
    for t in TOOLS:                                         # tools.txt 按钮 code= (对齐 C# Apps["tool:"+code])
        for btn in t.get('buttons', []):
            if btn.get('code') == code:
                return ('工具: ' + btn.get('name', code), 'tool', code)
    if code in CFG['apps']:
        name, cmd, args = CFG['apps'][code]
        return (name, 'app', (cmd, args))
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
    header = '[%s|开] ' % MODE_NAMES[ime.mode] + ('繁 ' if ime.trad else '')   # 对齐 C#: [模式|开] 头
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
        # hideidle=0: 常驻候选窗, 固定屏幕右下角(贴任务栏), 不跟随; 显示 C# 同款空闲提示 (对齐 RefreshLabel)
        bar.show(header.rstrip(), '(Shift开关 Ctrl+` 模式 vf符号)', [], 0, 0, 1, False, 'bottom-right')
    else:
        bar.hide()


def _with_code(w):
    """候选 + 反查编码: 五笔模式显**拼音**码, 其余模式显**五笔**码 (对齐 C# CodeHint/RevWb).
    注意别搞反 —— 反查的意义是显示"另一种码", 把刚打的码再显示一遍没有意义."""
    try:
        if ime.mode == 2:
            c = engine.code_for(w)
        else:
            c = engine.rev_wb_code(w)
        return '%s (%s)' % (w, c) if c else w
    except Exception:
        return w


def refresh():
    ime.page = 0
    ime.sel = 0
    if not ime.buf:
        bar.hide()
        return
    # 安全复位 (对齐 C# ShowCharatar 顶部): 离开 vf 或开了双拼 -> 退出符号面板状态
    if ime.sym_cat and ime.buf != 'vf':
        ime.sym_cat = 0
    if CFG['shuangpin'] > 0 and ime.sym_cat:
        ime.sym_cat = 0
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
    ime.app_cand = None
    # 双拼下不挂 rq/sj/xq 动态候选 / v 金额 / 启动器候选 (对齐 C# `if (Shuangpin == 0)`: 两键即音节, 会撞码)
    if ime.mode < 3 and CFG['shuangpin'] == 0:
        for s in reversed(dynamic_candidates(ime.buf)):
            if s not in cands:
                cands.insert(0, s)
                ime.dyn_set.add(s)
        for s in reversed(vmode_candidates(ime.buf)):
            if s not in cands:
                cands.insert(0, s)
                ime.dyn_set.add(s)
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
    # 五笔唯一四码自动上屏; 但首位是启动器候选时不自动上屏 (对齐 C# !appSet.Contains(cands[0]): 否则会变成自动启动程序)
    if (ime.mode == 2 and exact_wubi and not extendable and len(ime.buf) >= 4 and cands
            and cands[0] != ime.app_cand):
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
    if not CFG.get('assoc', True):                   # 联想关闭: 不出联想候选 (对齐 C# ShowAssoc)
        ime.assoc_showing = False
        return
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


def load_appmodes():
    global APPMODES
    APPMODES = {}
    try:
        for raw in read_text(os.path.join(DATA_DIR, 'pastemode.txt')).split('\n'):
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
        _notify('切换失败', '无法获取当前程序')            # 对齐 C# TrayTip(切换失败)
        return
    if APPMODES.get(name) == 1:
        del APPMODES[name]
        msg = name + ' 已恢复默认上屏'
    else:
        APPMODES[name] = 1
        msg = name + ' 改用剪贴板上屏'
    save_appmodes()
    _notify('上屏方式', msg)                            # 对齐 C# TrayTip(上屏方式, name + …)


def toggle_app_keyfix():
    name = win.foreground_process_name()
    if not name:
        _notify('切换失败', '无法获取当前程序')            # 对齐 C# TrayTip(切换失败)
        return
    if APPMODES.get(name) in (4, 5):
        del APPMODES[name]
        msg = name + ' 已恢复全局默认'
    else:
        APPMODES[name] = 5 if CFG.get('keyfix', True) else 4
        msg = name + (' 已单独关闭' if CFG.get('keyfix', True) else ' 已单独开启')
    save_appmodes()
    _notify('标点吞字修复', msg)                        # 对齐 C# TrayTip(标点吞字修复, name + …)


# 开始菜单/搜索/Shell 宿主: SendInput UNICODE 注入会被这类 UI 吞掉(候选上屏不进去), 强制剪贴板上屏
_CLIP_FORCE = {'startmenuexperiencehost', 'searchhost', 'shellexperiencehost'}


def effective_paste_mode():
    name = win.foreground_process_name()
    # Modern Windows Notepad may render KEYEVENTF_UNICODE as tofu boxes. Use CF_UNICODETEXT paste.
    if name in ('notepad', 'notepad.exe'):
        return 1
    if name in APPMODES and APPMODES[name] in (1, 2, 3):
        return APPMODES[name]
    if name in _CLIP_FORCE:
        return 1        # 开始菜单/搜索/Shell UI: 强制剪贴板上屏
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
    if m == 2:                                       # paste=off: C# 走 SendKeys(不套 keyfix); 无 .NET 时退回普通 key 注入
        time.sleep(0.03)
        n = win.send_unicode(text)
        _dfn('inject(sendkeys-fallback) %r sent=%s' % (text, n))
        return
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
def _write_config(key, value):
    """原子改写 config.txt 的一行 key (保留行尾, utf-8-sig 兼容 BOM, 正则精确匹配)."""
    try:
        path = os.path.join(APP_DIR, 'config.txt')
        with open(path, encoding='utf-8-sig') as f:
            text = f.read()
        lines = text.split('\n')
        found = False
        for i, l in enumerate(lines):
            if re.match(r'^\s*%s\s*=' % re.escape(key), l):
                lines[i] = '%s = %s' % (key, value)
                found = True
                break
        if not found:
            lines.append('%s = %s' % (key, value))
        with open(path, 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines))
    except OSError:
        pass


def toggle_trad():
    """简繁输出切换 (Ctrl+Shift+F / 托盘): 立即生效 + 写回 config.txt (对齐 C# Hook_OnToggleTrad 的持久化)."""
    ime.trad = not ime.trad
    _dfn('trad=%s' % ime.trad)
    _write_config('trad', '1' if ime.trad else '0')
    reset()
    _refresh_tray()


def toggle_followcaret():
    CFG['followcaret'] = not CFG.get('followcaret', True)
    _dfn('followcaret=%s' % CFG['followcaret'])
    _write_config('followcaret', '1' if CFG['followcaret'] else '0')   # 写回 config.txt
    show_page()   # 立即用新 followcaret 重定位候选框(组字/常驻), 否则"点了没反应"


def toggle_showcode():
    """反查编码开关: 候选上显示反查编码(五笔用五笔码, 否则拼音)."""
    CFG['showcode'] = not CFG.get('showcode', False)
    _dfn('showcode=%s' % CFG['showcode'])
    _write_config('showcode', '1' if CFG['showcode'] else '0')   # 写回 config.txt
    show_page()   # 立即按新 showcode 刷新候选(显示/隐藏编码)


def toggle_hideidle():
    """空闲隐藏开关: 空闲时隐藏候选窗(0=常驻). 切后直接 show_page(按 hideidle 立即常驻/隐藏)."""
    CFG['hideidle'] = not CFG.get('hideidle', True)
    _dfn('hideidle=%s' % CFG['hideidle'])
    _write_config('hideidle', '1' if CFG['hideidle'] else '0')
    show_page()


def toggle_sentence():
    """整句输入开关: 全拼连打按词频搜最佳路径."""
    CFG['sentence'] = not CFG.get('sentence', True)
    _dfn('sentence=%s' % CFG['sentence'])
    _write_config('sentence', '1' if CFG['sentence'] else '0')
    if ime.buf:
        refresh()


def toggle_assoc():
    """联想开关: 上屏后出联想候选."""
    CFG['assoc'] = not CFG.get('assoc', True)
    _dfn('assoc=%s' % CFG['assoc'])
    _write_config('assoc', '1' if CFG['assoc'] else '0')


def toggle_cnpunct():
    """全/半角标点开关 (Ctrl+. 或托盘): 开=逗号句号等直接上屏全角中文标点."""
    CFG['cnpunct'] = not CFG.get('cnpunct', True)
    hook.set_punct(CFG['cnpunct'])
    _dfn('cnpunct=%s' % CFG['cnpunct'])
    _write_config('cnpunct', '1' if CFG['cnpunct'] else '0')
    _refresh_tray()


def set_theme(name):
    CFG['theme'] = name
    bar.set_theme(name)
    _dfn('theme=%s' % name)
    _write_config('theme', name)   # 写回 config.txt


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


def switch_mode(new_mode):
    """托盘「运行模式」切换: 写回 config mode=ime|tray, 然后重启进程生效.
    对齐 C# 侧设计: 切换不热改 hook/菜单, 重启后按新 mode 干净启动."""
    new_mode = 'ime' if new_mode == 'ime' else 'tray'
    _write_config('mode', new_mode)
    _dfn('switch mode -> %s' % new_mode)
    try:
        if 'TRAY' in globals() and TRAY and getattr(TRAY, 'icon', None):
            TRAY.icon.stop()
    except Exception:
        pass
    try:
        engine.save_freq()
    except Exception:
        pass
    try:
        root.destroy()
    except Exception:
        pass
    # 以无控制台方式重启自身 (WGIME_RELAUNCHED=1 防 _relaunch_if_console_python 二次跳转)
    try:
        import subprocess
        exe = (sys.executable or '').lower()
        launcher = sys.executable
        if exe.endswith('python.exe') or exe.endswith('python3.exe'):
            pw = os.path.join(os.path.dirname(sys.executable), 'pythonw.exe')
            if os.path.exists(pw):
                launcher = pw
        env = dict(os.environ)
        env['WGIME_RELAUNCHED'] = '1'
        si = subprocess.STARTUPINFO()
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        si.wShowWindow = 0
        subprocess.Popen([launcher] + sys.argv, cwd=os.getcwd(),
                         startupinfo=si, creationflags=0x08000000, env=env)
    except Exception as e:
        _dfn('switch_mode relaunch err %r' % e)
    os._exit(0)


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
        # ① 字频学习只对"主动选择"(非默认第1位/非动态)生效, 避免空格确认默认词被误强化 (python 有意保留)
        if i > 0:
            engine.learn(code, text, ime.mode)
            _last_learn = (text, code, ime.mode)
        else:
            _last_learn = None
        # 自动造词链 (对齐 C# RecordCommit: 每次上屏都记一笔 —— 空格/默认候选、五笔唯一四码自动上屏
        # 同样参与; 只有动态候选/面板符号不参与)。原来这一句被塞在 `if i > 0` 里, 于是"空格逐字确认"
        # 这种最常见的上屏路径永远不进 recent 链, 自动造词几乎不触发。
        record_commit(text, code)


def digit_as_code():
    """v 模式数字当编码 (对齐 C# DigitAsCode): 双拼下关闭; v 后全是数字时延长; 裸 v 只在无候选时延长"""
    return (CFG['shuangpin'] == 0 and ime.mode < 2 and ime.buf.startswith('v')
            and (ime.buf[1:].isdigit() if len(ime.buf) > 1 else len(ime.cands) == 0))


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


def run_steps_bg(body, name='插件'):
    """步骤 DSL 插件后台执行; msg 步骤走托盘气泡(对齐 C# ShowBalloonTip), confirm marshal 回主线程.
    开始/结果也走托盘气泡 (对齐 C# RunCodePlugin 的 开始执行…/结果提示)."""
    from tkinter import messagebox as _mb

    def _confirm(text, title='WgIme', buttons='yesno', default_no=True):
        """title/buttons/default_no 对齐 C# ExecToolStep confirm (缺省按钮 = "否")."""
        ev = threading.Event()
        result = [False]

        def ask():
            try:
                if buttons == 'okcancel':
                    result[0] = _mb.askokcancel(title, text,
                                                default=(_mb.CANCEL if default_no else _mb.OK))
                else:
                    result[0] = _mb.askyesno(title, text,
                                             default=(_mb.NO if default_no else _mb.YES))
            except Exception:
                pass
            ev.set()
        root.after(0, ask)
        ev.wait()
        return result[0]

    _notify(name, '开始执行…')

    def work():
        try:
            r = plugmod.run_steps(body, lambda m: _dfn('step %s' % m), _notify, _confirm)
            aborted = getattr(r, 'aborted', False)
            tail = '已取消' if aborted else ('完成' if r == 0 else '完成, %d 个步骤失败' % r)
            _notify(name, tail)
            if r:
                _dfn('steps fails %d' % r)
        except Exception as ex:
            _dfn('steps err %r' % ex)
            _notify(name, '执行出错: %s' % ex)
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


def _console_python():
    """子进程[python]块用 console 版解释器. 主程序可能用 pythonw(无黑窗口)启动,
    而 pythonw 的 stdout 不可靠 -> 子进程要抓 @wgime 行必须用 python.exe."""
    exe = sys.executable
    if exe and os.path.basename(exe).lower() == 'pythonw.exe':
        alt = os.path.join(os.path.dirname(exe), 'python.exe')
        if os.path.exists(alt):
            return alt
    return exe or 'python'


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
        r = subprocess.run([_console_python(), tmp], timeout=timeout, capture_output=True,
                           text=True, encoding='utf-8', errors='replace', creationflags=0x08000000)
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


# [csharp] 插件宿主: 追加在插件源码之后, 不能用 using (C# 要求 using 在 namespace 成员之前),
# 全限定名; [STAThread] 保持与旧 PowerShell sidecar 的 -STA 一致 (WinForms 需要).
_CSC_HOST = r'''
public static class WgPluginHost {
    [System.STAThread]
    static void Main() {
        foreach (var t in System.Reflection.Assembly.GetExecutingAssembly().GetTypes()) {
            var m = t.GetMethod("Run", System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static);
            if (m != null) {
                System.Windows.Forms.Application.EnableVisualStyles();
                m.Invoke(null, null);
                System.Windows.Forms.Application.Run();
                return;
            }
        }
    }
}
'''


def _find_csc():
    """找 .NET Framework 自带 csc.exe (系统组件, 无需安装)."""
    for root in (r'C:\Windows\Microsoft.NET\Framework64\v4.0.30319',
                 r'C:\Windows\Microsoft.NET\Framework\v4.0.30319'):
        p = os.path.join(root, 'csc.exe')
        if os.path.isfile(p):
            return p
    return None


def _run_csharp_plugin(payload):
    """[csharp] 插件: 直接调系统自带 csc.exe 编译成独立 exe 并运行 (不再经 PowerShell+CodeDom sidecar).
    产物按源码 md5 缓存在 DATA_DIR/runtime/csc/, 二次启动零编译. csc 缺失/编译失败回退 ps1 sidecar."""
    import subprocess
    text = open(payload.path, encoding='utf-8').read()
    m = re.search(r'(?s)\[csharp\]\s*(.*?)\[/csharp\]', text)
    if not m:
        _dfn('csharp plugin %s: no [csharp] block' % payload.name)
        return
    src = m.group(1)
    full = src + '\n' + _CSC_HOST
    csc = _find_csc()
    if not csc:
        _run_csharp_plugin_ps1(payload)
        return
    import hashlib
    h = hashlib.md5(full.encode('utf-8')).hexdigest()[:16]
    outdir = os.path.join(DATA_DIR, 'runtime', 'csc')
    try:
        os.makedirs(outdir, exist_ok=True)
    except Exception:
        pass
    cs = os.path.join(outdir, 'p_%s.cs' % h)
    exe = os.path.join(outdir, 'p_%s.exe' % h)
    if not os.path.isfile(exe):
        open(cs, 'w', encoding='utf-8').write(full)
        wpflib = os.path.join(os.path.dirname(csc), 'WPF')
        args = [csc, '/nologo', '/target:winexe', '/out:' + exe, cs,
                '/r:System.dll', '/r:System.Core.dll', '/r:System.Data.dll',
                '/r:System.Drawing.dll', '/r:System.Windows.Forms.dll',
                '/lib:' + wpflib,
                '/r:WindowsBase.dll', '/r:PresentationCore.dll', '/r:PresentationFramework.dll']
        r = subprocess.run(args, capture_output=True, text=True, encoding='utf-8', errors='replace',
                           creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        if r.returncode != 0 or not os.path.isfile(exe):
            _dfn('csharp compile fail %s: %s' % (payload.name, (r.stdout or r.stderr or '')[:400]))
            _notify('插件编译失败', '%s: %s' % (payload.name, (r.stdout or r.stderr or '').strip()[:160]))   # 对齐 C# TrayTip
            _run_csharp_plugin_ps1(payload)          # 编译失败回退 (理论上同一编译器也会失败, 但保底)
            return
    try:
        subprocess.Popen([exe], creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    except Exception as ex:
        _dfn('csharp launch err %r' % ex)
        _notify('插件运行出错', '%s: %s' % (payload.name, ex))        # 对齐 C# TrayTip(插件运行出错)


def _run_csharp_plugin_ps1(payload):
    """回退: 旧 sidecar PowerShell + CodeDom (csc.exe 不可用/直编失败时)."""
    runner = os.path.join(BASE, 'run-csharp-plugin.ps1')
    if not os.path.exists(runner):
        runner = os.path.join(APP_DIR, 'run-csharp-plugin.ps1')
    try:
        import subprocess
        subprocess.Popen(['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                          '-File', runner, payload.path], creationflags=0x08000000)
    except Exception as ex:
        _dfn('csharp plugin err %r' % ex)


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
        run_steps_bg(payload.body, payload.name)
        return
    if kind == 'python':                                   # [python] 块插件: 子进程+超时熔断 + JSON IPC; 后台线程跑, 不阻塞主线程打字
        ctx = {'code': payload.code, 'name': payload.name, 'buff': ime.buf, 'mode': ime.mode}
        threading.Thread(target=_run_python_plugin_actions, args=(payload, ctx), daemon=True).start()
        return
    if kind == 'csharp':                                   # [csharp] 插件: 直编 csc.exe+缓存 (后台线程, 不阻塞打字)
        threading.Thread(target=_run_csharp_plugin, args=(payload,), daemon=True).start()
        return
    if kind == 'builtin':
        _show_builtin(payload)
        return
    if kind == 'tool':                                     # tools.txt 按钮 code= (对齐 C# RunToolCode)
        threading.Thread(target=tools.run_tool_code, args=(payload, _notify), daemon=True).start()
        return
    if kind == 'app':
        cmd, args = payload
        try:
            # 对齐 C# LaunchApp: 相对路径(含 \ 或 / 且非绝对路径)按**程序目录**解析, 不是进程 CWD;
            # 用 ShellExecuteW 'open' + Arguments (同 C# UseShellExecute=true), 参数不过 cmd.exe
            if '://' not in cmd and ('\\' in cmd or '/' in cmd) and not os.path.isabs(cmd):
                cmd = os.path.join(APP_DIR, cmd)
            if not win.shell_execute(cmd, args):
                raise OSError('ShellExecute 失败: %s' % cmd)
        except Exception as ex:
            _dfn('launch err %r' % ex)
            _notify('启动失败', '%s: %s' % (name, ex))     # 对齐 C# TrayTip(启动失败)


def _notify(title, text):
    """托盘气泡提示 (对齐 C# ShowBalloonTip); 无托盘时退回弹窗."""
    try:
        if TRAY is not None and TRAY.notify(title, text):
            return
    except Exception:
        pass
    tools._msgbox(title, text)


tools.set_notifier(_notify)                            # 工具步骤 msg / 工具结果走托盘气泡


def _run_app_by_code(code):
    """托盘/工具箱按 config.txt 的 app= 编码启动程序 (对齐 wgtray LaunchApp)."""
    try:
        apps = CFG.get('apps') or {}
        if code not in apps:
            return
        name, cmd, args = apps[code]
        run_launcher((name, 'app', (cmd, args)))
    except Exception as ex:
        _dfn('run app err %r' % ex)


def _reload_all_plugins():
    """插件管理器/托盘用: 重扫 plugins (.py + .txt) + tools, 不动整体 config."""
    reload_plugins()                                # plugins/*.txt + tools.txt -> STEP_PLUGINS/TOOLS
    load_py_plugins()                               # plugins/*.py -> PLUGINS


# ---------- 插件列举/运行 (托盘菜单 + 插件管理器共用) ----------
def _plugin_dir():
    return os.path.join(APP_DIR, 'plugins')


def _list_plugin_files():
    """列举 plugins 目录下的插件文件: [{file, name, code, kind, enabled}].
    .py 取模块 manifest (CODE/NAME/PERM), .txt 取头部解析. 对齐 C# RefreshList."""
    out = []
    try:
        for fn in sorted(os.listdir(_plugin_dir())):
            low = fn.lower()
            if not (low.endswith('.txt') or low.endswith('.py')):
                continue
            if low == 'readme.txt' or fn.startswith('_'):
                continue
            path = os.path.join(_plugin_dir(), fn)
            if low.endswith('.py'):
                # .py 模块插件: 读属性(不 import, 用静态文本扫 manifest 行即可快速列清单)
                info = _py_plugin_meta_static(path)
                if not info:
                    continue
                # 状态列 (对齐 C# RefreshList 的"正常/编译失败"): 已成功装载的 .py 才算正常
                loaded = any(os.path.normpath(getattr(m, '__file__', '') or '') == os.path.normpath(path)
                             for m in PLUGINS)
                info['status'] = '正常' if loaded else '未加载'
                out.append(info)
            else:
                p = plugmod.parse_plugin(path)
                if p.error:
                    continue
                if p.kind == 'steps':
                    n_steps = plugmod.count_steps(p.body)
                    status = ('正常 (%d 步)' % n_steps) if n_steps else '解析失败'   # 对齐 C# "正常 (N 步)"/"解析失败"
                else:
                    status = '—'          # [csharp]/[python] 块: python 不预编译, 成败要到运行时才知道
                out.append({'file': path, 'name': p.name, 'code': p.code, 'kind': p.kind,
                            'enabled': getattr(p, 'enabled', True), 'version': getattr(p, 'version', ''),
                            'perm': getattr(p, 'perm', 'low'), 'desc': getattr(p, 'desc', ''),
                            'status': status})
    except OSError:
        pass
    return out


def _py_plugin_meta_static(path):
    """读 .py 插件的模块级 manifest(不 import, 正则扫 CODE/NAME/... 字面量)."""
    try:
        text = read_text(path)               # 宽松解码: 插件 .py 也是用户可写的 (GBK+coding 声明 python 能跑)
    except OSError:
        return None
    m = re.search(r'^\s*CODE\s*=\s*[\'"]([^\'"]+)[\'"]', text, re.M)
    if not m:
        return None
    def _get(k, d=''):
        mm = re.search(r'^\s*%s\s*=\s*[\'"]([^\'"]*)[\'"]' % k, text, re.M)
        return mm.group(1) if mm else d
    return {'file': path, 'name': _get('NAME', m.group(1)), 'code': m.group(1), 'kind': 'py',
            'enabled': os.path.basename(path).lower() not in _read_disabled(), 'version': _get('VERSION'),
            'perm': _get('PERM', 'low'), 'desc': _get('DESC')}


def _read_disabled():
    try:
        return set(l.strip().lower() for l in read_text(os.path.join(DATA_DIR, 'plugins-disabled.txt')).split('\n') if l.strip())
    except OSError:
        return set()


def _run_plugin_file(path):
    """按文件运行插件: .py 用已加载模块的 run() (无则即时加载); .txt 走 steps/[python]/[csharp]."""
    fn = os.path.basename(path)
    low = fn.lower()
    if low.endswith('.py'):
        # 已加载则复用模块, 否则按 load_py_plugins 同款即时加载并运行; 运行前权限确认
        for m in PLUGINS:
            if getattr(m, '__file__', None) and os.path.normpath(getattr(m, '__file__')) == os.path.normpath(path):
                if _confirm_plugin(m):
                    try:
                        m.run()
                    except Exception as ex:
                        _dfn('run py plugin err %r' % ex)
                return
        _run_py_file_once(path)
        return
    p = plugmod.parse_plugin(path)
    if p.error:
        _dfn('plugin parse err %s %s' % (path, p.error))
        return
    if not _confirm_plugin(p):
        return
    if p.kind == 'csharp':
        threading.Thread(target=_run_csharp_plugin, args=(p,), daemon=True).start()
    elif p.kind == 'python':
        ctx = {'code': p.code, 'name': p.name, 'buff': ime.buf, 'mode': ime.mode}
        threading.Thread(target=_run_python_plugin_actions, args=(p, ctx), daemon=True).start()
    else:
        run_steps_bg(p.body, p.name)


def _run_py_file_once(path):
    """未加载的 .py 插件即时加载并运行 run() (对齐 load_py_plugins 的加载方式)."""
    modname = 'wgime_ext_' + str(abs(hash(os.path.abspath(path)))) + '_' + os.path.basename(path)[:-3]
    try:
        spec = importlib.util.spec_from_file_location(modname, path)
        if spec is None or spec.loader is None:
            raise ImportError('no module spec')
        m = importlib.util.module_from_spec(spec)
        sys.modules[modname] = m
        spec.loader.exec_module(m)
        if not getattr(m, 'CODE', None) or not callable(getattr(m, 'run', None)):
            raise ValueError('plugin must define CODE and callable run()')
        if not _confirm_plugin(m):
            return
        m.run()
    except Exception as e:
        sys.modules.pop(modname, None)
        _dfn('run py file err %s %r' % (path, e))


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
            tools.show_plugin_mgr(PLUGINS, DATA_DIR, _reload_all_plugins,
                                  run_file_fn=_run_plugin_file, list_files_fn=_list_plugin_files,
                                  plugin_dir_fn=_plugin_dir)
    except Exception as ex:
        _dfn('builtin err %s %r' % (kind, ex))


def makeword_clipboard():
    t = (win.clipboard_text() or '').strip()
    prefill = t if 2 <= len(t) <= 8 and is_all_cjk(t) else ''
    if not prefill:
        # 剪贴板里没有 2-8 个汉字: C# 会弹警告气泡 (python 保留造词对话框可手输, 只是不给预填)
        _notify('造词', '剪贴板里没有 2-8 个汉字 (先复制汉字, 或在对话框里手输)')
    tools.show_makeword(DATA_DIR, engine, prefill)


# 半角原样映射 (cnpunct=0 时组字中被 _CTRL_KEYS 吞进来的 ; [ ] 等回退用)
_HALF_PUNCT = {
    (0xBC, False): ',', (0xBC, True): '<', (0xBE, False): '.', (0xBE, True): '>',
    (0xBA, False): ';', (0xBA, True): ':', (0xBF, False): '/', (0xBF, True): '?',
    (0xDC, False): '\\', (0xDC, True): '|', (0xDB, False): '[', (0xDB, True): '{',
    (0xDD, False): ']', (0xDD, True): '}', (0x34, False): '4', (0x34, True): '$',
    (0xDE, False): "'", (0xDE, True): '"',
}


def handle_punct(vk, sh):
    """中文标点键 (cnpunct=1 时 hook 吞标点键送到这里).
    组字中先把当前页首候选上屏再上屏标点 (对齐 C# Hook_OnPunct); 默认候选上屏不强化词频(与空格一致)."""
    # ; 微软双拼里是韵母 ing 编码键: 组字中当编码不当标点 (对齐 C# OnSemi, 要求 !sh)
    if vk == VK['SEMI'] and CFG['shuangpin'] == 3 and ime.buf and not sh:
        if ime.assoc_showing:
            clear_assoc()
        ime.buf += ';'
        refresh()
        return
    # [ ] 组字中以词定字 (取首候选首/末字), 空候选或空闲才是书名号 【】 (对齐 C# OnPickChar 优先级)
    # 键位按 config key_pickfirst/key_picklast (缺省 [ ]), 且只在还有候选时算"定字"
    _pk1, _pk2 = hook.KEYS.get('pickfirst', 0), hook.KEYS.get('picklast', 0)
    if vk in (_pk1, _pk2) and _pk1 != _pk2 and ime.buf and ime.cands:
        commit_char(0 if vk == _pk1 else 1)
        return
    if not CFG.get('cnpunct', True):
        s = _HALF_PUNCT.get((vk, sh))              # 半角模式: 原样上屏
    else:
        s = map_punct(vk, sh)
    if s is None:
        return                                     # 无映射的组合 (防御; hook 正常不会吞这些)
    if ime.buf and ime.cands and ime.buf != 'vf':
        # 组字中按标点: 首候选先上屏 (对齐 C# Hook_OnPunct: Send(cands[0]); 启动器 ▶ 候选除外, 只收标点)
        top = ime.cands[0]
        if top != ime.app_cand:
            inject(top)
            record_commit(top, ime.buf)     # 对齐 C# Hook_OnPunct 的 RecordCommit (自动造词链; 词频仍不强化)
    if ime.buf or ime.assoc_showing:
        reset()                                    # 清组字/联想/vf 符号面板, 再上屏标点
    inject(s)


def handle(vk):
    _dfn('kb %02x active=%s buf=%s' % (vk, ime.active, ime.buf))
    sh = bool(vk & 0x200)                            # hook 编码: 标点键 Shift 状态
    vk &= ~0x200
    K = hook.KEYS                                    # 候选操作键按 config key_* 解析 (0 = 该键已禁用, 永不匹配)
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
        toggle_trad()
        return
    if vk == VK['MAKEWORD']:
        makeword_clipboard()
        return
    if vk == VK['PUNCT']:                            # Ctrl+. 全/半角标点切换
        toggle_cnpunct()
        return
    if not ime.active:
        return
    # 中文标点 (cnpunct=1 时 hook 吞键): 组字中先上屏首候选再上屏标点
    if vk in (0xBC, 0xBE, 0xBA, 0xBF, 0xDC, 0xDB, 0xDD, 0xDE) or (vk == 0x34 and sh):
        handle_punct(vk, sh)
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
        if vk == K['first'] and ime.sym_cat > 0:
            if ime.cands:
                inject(ime.cands[ime.page * 9])
                reset()
                ime.sym_cat = 0
            return
        if vk == K['back']:
            if ime.sym_cat > 0:
                ime.sym_cat = 0
                refresh()
            else:
                ime.buf = 'v'
                refresh()
            return
        if vk == K['cancel']:
            reset()
            ime.sym_cat = 0
            return
        if vk in (K['pageup'], K['pagedown']) and K['pageup'] != K['pagedown']:
            tp = (len(ime.cands) + 8) // 9
            if tp > 0:
                ime.page = (ime.page + (1 if vk == K['pagedown'] else -1) + tp) % tp
                show_page()
            return
        if vk == K['raw']:
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
    elif vk == K['first']:
        if ime.assoc_showing and not ime.buf:
            clear_assoc()
            bar.hide()
            win.send_unicode(' ')
        elif ime.buf:
            commit(ime.page * 9 + ime.sel)   # 翻页后按空格上屏"当前页"第一个(sel 为页内偏移), 而非第一页
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
    elif vk in (K['pickfirst'], K['picklast']) and K['pickfirst'] != K['picklast']:
        commit_char(0 if vk == K['pickfirst'] else 1)
    elif vk == K['back']:
        if ime.assoc_showing and not ime.buf:
            _rollback_last_learn()                   # ② 误学回滚: 刚上屏的词被退格删除, 撤销上次主动学习
            clear_assoc()                            # 联想态退格: 退出联想
            win.send_key_backspace()                 # 并把退格交给应用 (删刚上屏的字)
        elif ime.buf:
            ime.buf = ime.buf[:-1]
            refresh()
    elif vk == K['cancel']:
        reset()
    elif vk == K['raw']:
        if ime.buf:
            inject(ime.buf)
        reset()
    elif vk in (K['pageup'], K['pagedown']) and K['pageup'] != K['pagedown']:
        tp = (len(ime.cands) + 8) // 9
        if tp > 0:
            ime.page = (ime.page + (1 if vk == K['pagedown'] else -1) + tp) % tp
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

if _DICTS_MISSING:                              # 空词库必须让用户看见 (pythonw 下没 stderr)
    try:
        if TRAY and getattr(TRAY, 'icon', None):
            TRAY.icon.notify('没有找到码表 py.txt: 词库目录 = %s\n'
                             '输入法现在以"空词库"运行, 候选里不会有任何字词。'
                             '请把 py.txt/wb.txt/ec.txt 放进该目录, 或用 WGIME_DICT_DIR 指定。' % DICT_DIR,
                             'WgIme')
    except Exception:
        pass


_admin_hint_shown = [False]
_admin_hint_last = [0.0]


def _maybe_admin_hint():
    """检测前台是管理员(高完整性)窗口且 wgime 未提权 -> 托盘气泡提示以管理员运行 wgime(节流, 一次)."""
    now = time.time()
    if _admin_hint_shown[0] or now - _admin_hint_last[0] < 5:
        return
    _admin_hint_last[0] = now
    try:
        if not win.self_elevated() and win.foreground_elevated():
            _admin_hint_shown[0] = True
            if TRAY and getattr(TRAY, 'icon', None):
                TRAY.icon.notify('当前前台窗口以管理员身份运行, wgime(普通权限)无法在其中输入。\n请右键以管理员身份运行 wgime 后重试。', 'WgIme')
    except Exception:
        pass


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
        _maybe_admin_hint()   # 提权前台 + 未提权 wgime: 托盘提示(节流一次)
    finally:
        hook.COMPOSING[0] = bool(ime.buf or ime.assoc_showing or ime.sym_cat)
        try:
            if root.winfo_exists():
                root.after(8, poll)                # 键盘事件轮询间隔: 15→8ms, 降每键等待 (空转仅 queue 探测, 开销可忽略)
        except Exception:
            pass


root.after(8, poll)
if is_tray_mode():
    _dfn('runmode=tray (no keyboard hook)')
else:
    if not hook.start():                     # 钩子装不上: 对齐 C# 的"钩子失败"错误气泡 (不再静默)
        _notify('WgIme (Python) 已启动', '键盘钩子安装失败 (err %s), 输入法按键将不工作。' % hook.last_error())
    set_active(CFG['starton'])
    try:
        win.ensure_caret_bg()
    except Exception:
        pass
root.mainloop()
