# -*- coding: utf-8 -*-
"""main.py — WgIme-Pure 主程序: Python 3.12 + ctypes + tkinter, 零 .NET.
状态机与 wgime-py (pythonnet 版) 对齐, UI/注入换成纯 Python.
"""
import os
import sys
import threading
import time
import queue
import importlib.util
import ctypes
import re

VERSION = '1.2.12-py'      # 单文件里唯一的版本标识: 写在启动 always-on 日志里, 方便确认"跑的是哪个文件"
                           # (第四十五轮: 用户机器上出现过"拿旧的 wgime-py.py 测新功能"的混乱)
# 注意: tkinter **不在这里** import (第四十轮). 首次 import tkinter ≈70ms, 而"单实例 -> 读 config ->
# 装键盘钩子"这一段完全用不到它; 挪到钩子装好之后 (见下面的"钩子之后才 import"段)。
# dist 里 bar/ui/tools/tray 也改成懒 exec, 所以这里的延迟 import 才是真的延迟。


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


def _dfn_always(text):
    """少数"排障必须"的诊断: 不看 WGIME_DEBUG 也写 debug.log.
    只用在启动时那几条托盘诊断上 (每条几十字节, 不涉及每键路径) —— 用户默认不开 debug,
    托盘图标出问题时没有它就只能靠猜 (第四十一轮: "个别机器看不到托盘图标")。"""
    try:
        with open(os.path.join(DATA_DIR, 'debug.log'), 'a', encoding='utf-8') as f:
            f.write('%.3f %s\n' % (time.time(), text))
    except Exception:
        pass


sys.path.insert(0, BASE)
import win
import hook
from engine import (Engine, dynamic_candidates, vmode_candidates, is_all_cjk,
                    load_config, shuangpin_expand, SYM_CAT_NAMES, SYM_CATS, read_text)

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


# ---------- 早装键盘钩子 (第三十八轮; 第三十九轮提到 Tk 之前) ----------
# 顺序很关键: 钩子必须**最先**就位。引擎读词库 ~1.0s、配置/候选条/托盘/插件 ~0.5s, 这段窗口里
# 按键原来根本没进输入法 —— 用户实测"启动后按 Shift 再打字, 还要 1-3 秒才上屏"就是打在这段窗口。
# 现在: 单实例检查 -> 读 config(1ms) -> hook.start() -> set_active -> 起 caret helper -> 才建 Tk/加载窗
#       (加载窗仍然盖住建表的 1s, 只是晚 ~0.2s 出现; 钩子早 ~1s 可用)。
# 语义不变: 未激活时按键照常透传给应用(与没装钩子时完全一样); 已激活时按键进 hook.EVENTS 队列,
# 等 poll() 起来后按顺序处理 —— 用户前几秒敲的字不丢、也不会漏成半截拼音。
# 这里只读一次 config (engine.load_config 不碰 Engine 实例, ~1ms); 最终 CFG 仍在引擎之后 apply_config()。
_EARLY_CFG = {}
try:
    _EARLY_CFG = load_config(os.path.join(APP_DIR, 'config.txt'))
except Exception as e:
    _dfn('early config read err %r' % e)
_EARLY_HOOK_OK = None
if _EARLY_CFG.get('mode', 'ime') != 'tray':
    try:
        hook.configure(_EARLY_CFG.get('hotkeys'), _EARLY_CFG.get('ckeys'))
        hook.set_punct(_EARLY_CFG.get('cnpunct', True))
    except Exception as e:
        _dfn('early hook configure err %r' % e)
    try:
        _EARLY_HOOK_OK = bool(hook.start())
        hook.set_active(bool(_EARLY_CFG.get('starton', True)))
        _dfn('early hook ok=%s (installed before Tk/dict load; ACTIVE=%s)'
             % (_EARLY_HOOK_OK, bool(_EARLY_CFG.get('starton', True))))
    except Exception as e:
        _EARLY_HOOK_OK = False
        _dfn('early hook start err %r' % e)
    try:
        # 跟随 helper 的 spawn 实测 ~90-100ms (Popen 一个 python 子进程). 它只是"起个后台进程",
        # 不碰 Tk/不碰主线程状态, 所以丢到自己的线程里去起 (第四十轮) —— 否则这 90ms 会挡在
        # 词库线程启动之前, 直接变成"上屏"又晚 90ms.
        # 第六十八轮: followcaret 默认 0 (冻结) -> 这个**只为跟随服务**的常驻 helper 就不起了
        # (省一个 python 子进程 + 一份 UIA). 代码全保留, config 里 followcaret = 1 照旧起。
        # 此刻 CFG 还没建好, 所以读 _EARLY_CFG。
        if _EARLY_CFG.get('followcaret', False):
            threading.Thread(target=win.ensure_caret_bg, name='wgime-caret-boot',
                             daemon=True).start()
    except Exception:
        pass

# ---------- 词库加载与 UI 并行 (第四十轮) ----------
# 读词库(热 ~1.0s / 冷 12-15s)原来**同步**排在 Tk/加载窗之后, 于是"能上屏"要等
#   钩子(~0.5s) + Tk root + 加载窗(~0.5s) + 读词库(~1.0s)。
# 现在把 Engine() 丢到后台线程(**钩子一装好就起**, 连 tkinter/tools 的 import 都与它并行), 主线程
# 同时建 Tk + 加载窗 —— 两边并行, 主循环(真正能上屏的时刻)实测提前 ~0.6s。
# Engine() 只读文件/建表, 不碰 Tk, 可以安全地在线程里跑; 结果在 join 之后交给主线程 (join 提供
# 可见性), 异常(含 MemoryError)带回主线程重抛, 不静默变成"没词库"。
_DICTS_MISSING = not os.path.exists(os.path.join(DICT_DIR, 'py.txt'))
if _DICTS_MISSING:
    print('[wgime] 没有找到码表 py.txt: 词库目录 = %s\n'
          '        请把 py.txt/wb.txt/ec.txt (以及 import_*.txt) 放进该目录, 或用 WGIME_DICT_DIR 指定。\n'
          '        现在会以"空词库"运行 —— 候选里不会有任何字词, 也不会写索引缓存。' % DICT_DIR,
          file=sys.stderr)

_engine_box = {}
_engine_err = []


def _load_engine_bg():
    try:
        _engine_box['engine'] = Engine(DICT_DIR, DATA_DIR)
    except BaseException as e:
        _engine_err.append(e)


_engine_th = None
try:
    _engine_th = threading.Thread(target=_load_engine_bg, name='wgime-dict-load', daemon=True)
    _engine_th.start()
except Exception as e:
    _dfn('engine thread start err %r' % e)
    _engine_th = None

# 下面这些只有 UI/工具箱/插件/候选条/托盘用到, 一律放在钩子之后、且**放在词库线程启动之后** import
# (第四十轮): 首次 import tkinter ≈35ms; import tools 连带 plugins/bar/ui ≈150ms; dist 单文件里
# bar/wspy/plugins/ui/tools/tray 还改成了"首次用到才 exec"(见 build-wgime-pure.py) —— 这些都被
# 上面的读词库盖住了, 不再把"钩子可用/主循环启动"往后推。
import tkinter as tk                               # noqa: E402
import tools                                       # noqa: E402
import plugins as plugmod                          # noqa: E402
from bar import CandBar                            # noqa: E402


# 建表在后台进行; 冷启动 10s+ 期间总得给点反馈 (对齐 C# 候选条的"(词库加载中...)"提示)
root = tk.Tk()
root.withdraw()
_splash = None
try:
    # 每次启动都给反馈, 不只在"要重建索引"时: 热启动也要同步读 44.6MB 核心缓存 + 装配置/托盘,
    # 到钩子装好约 2.3s (冷启动 12.4s); 这期间钩子还没装, 用户看不到任何痕迹就会以为
    # 没启动/打字没反应。(用户第三十四轮报的"每次启动头几秒打不出字"另一个根因是首键同步建
    # 反查表 ~1.3s, 已改后台建 —— 见 engine.rev_wb_code/warm_rev_wb。)
    _stale = _dict_cache_stale()
    _splash = tk.Toplevel(root)
    _splash.overrideredirect(True)
    _splash.attributes('-topmost', True)
    _splash.configure(bg='#3B3836')
    tk.Label(_splash, text='WgIme 正在加载词库…', bg='#3B3836', fg='#FFFFFF',
             font=('Microsoft YaHei UI', 11)).place(x=0, y=12, width=320, height=26)
    tk.Label(_splash, text=('首次启动需建立索引, 请稍候 (之后走缓存, 秒开)' if _stale
                            else '正在读取词库缓存, 几秒后即可输入'), bg='#3B3836', fg='#B0ACA8',
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

# ---------- 第五十三轮: 把托盘图标**提前**挂出来 ----------
# 词库加载是主线程 join 的 (热启动 ~1.5-1.9s, 冷启动从码表重建要十几秒), 而托盘原来排在 join 之后的
# `after(150, _deferred_tray)` 里 —— 于是"刚启动那几秒/十几秒托盘里根本没有图标"(用户报的
# "icon 加载不及时, 特别是刚启动后")。这里在等词库之前先把图标挂出来(最小菜单: 开关/退出),
# 词库读完后再由 `_deferred_tray` 换成完整菜单 + 真实状态。
# `import tray` 会顺带拉起 pystray(~130ms), 但那段时间词库线程本来就在跑, 不额外拖慢上屏。
TRAY = None
_TRAY_BOOT = [False]


def _boot_tray():
    """启动早期挂出托盘图标 (最小菜单)。失败就静默留给 _deferred_tray 重试并报错。"""
    global TRAY
    if TRAY is not None:
        return
    try:
        import tray as _tray_mod
        # 最小 api: 只给"建图标/刷图标"真正会立刻求值的那几个 (其余等 _deferred_tray 换完整 api)
        api0 = {'toggle': lambda: set_active(not ime.active),
                'is_active': lambda: ime.active,
                'get_mode': lambda: ime.mode,
                'quit': lambda: quit_app()}
        TRAY = _tray_mod.Tray(root, api0)
        if TRAY.start(boot=True):
            _TRAY_BOOT[0] = True
            _dfn_always('tray: boot icon shown BEFORE dict join (dict thread still running)')
        else:
            _dfn('tray boot start failed: %s' % ((getattr(TRAY, 'last_error', '') or '')[-200:],))
            TRAY = None
    except Exception as e:
        _dfn('tray boot err %r' % e)
        TRAY = None


_boot_tray()

if _engine_th is not None:
    _engine_th.join()                      # 等后台线程读完词库 (与上面的 Tk/加载窗并行)
if _engine_err:
    raise _engine_err[0]                   # 线程里的异常在主线程重抛 (别静默退化成"没词库")
engine = _engine_box.get('engine')
if engine is None:                         # 线程没起起来 (极端环境): 老实同步读一次
    engine = Engine(DICT_DIR, DATA_DIR)
_dfn('startup: engine load=%.0fms (对齐 C# 的启动计时日志)' % engine.load_ms)
if _splash is not None:
    try:
        # 第四十轮: 这里原来直接 destroy(), 实测要 ~90ms (销毁 Toplevel + 处理 Tk 事件), 而它正好
        # 卡在"词库已读完 -> poll 起来"之间, 等于又给上屏加 90ms。改成先 withdraw (隐藏, 快得多),
        # 真正的 destroy 丢给主循环的 after(120) —— 反正主循环马上就起来了。
        _splash.withdraw()
        # 第五十一轮: `root.after(120, _destroy_splash)` 会在**注册时**就对 `_destroy_splash` 求值, 而它
        # 定义在下面几行 —— NameError 被 except 吞掉, 于是隐藏的加载窗**永远不会被 destroy**(每进程漏一个
        # Toplevel, 与注释/AGENTS-DETAIL 的"主循环里再 destroy"不符)。用 lambda 把名字求值推迟到调用时。
        root.after(120, lambda: _destroy_splash())
    except Exception:
        pass


def _destroy_splash():
    global _splash
    try:
        if _splash is not None:
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
    hook.VOICE_ON[0] = bool(CFG.get('voice'))              # 语音功能开着时热键/松键才吞 (第四十七轮)
    hook.VOICE_MODE[0] = (ime.mode == MODE_VOICE)
    # 反查码表(rev_wb)不做启动预热: 那 1.2s 纯 Python 循环会抢 GIL, 把"装钩子"这一步推迟 1.4s。
    # 改成首次真正需要时在**后台线程**里建 (engine.rev_wb_code -> warm_rev_wb), 输入路径永不阻塞。


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
          PUNCT=0xFD, VOICE=0xF6, VOICE_UP=0xF7)
MODE_NAMES = ('混合', '拼音', '五笔', '词典', '语音')
MODE_VOICE = 4                     # 「语音」模式: 不组字 (按键透传), 候选条显示录音/识别状态 (第四十七轮)


# 中文标点映射 (标准输入法全角逻辑, 第七十八轮补全; vk | 0x200 = Shift 按住, hook 编码)
# 与 C# MapPunct 逐条一致 (表见 AGENTS-DETAIL §D17)。裸 / - = 无映射(透传半角)。
_sq_open = [False]   # 单引号开闭交替状态
_dq_open = [False]   # 双引号开闭交替状态

_SHIFT_DIGIT = ('）', '！', '＠', '＃', '￥', '％', '……', '＆', '＊', '（')
# 索引 = vk - 0x30: [0] 是 Shift+0=）, [1] 是 Shift+1=！, ..., [9] 是 Shift+9=（
# (物理键序: !@#$%^&*() 对应 1234567890; 别按 1..9,0 排 —— 那会把 Shift+1 错给成 ＠)


def map_punct(vk, sh):
    if vk == 0xC0:                           # ` ~ (VK_OEM_3)
        return '～' if sh else '·'
    if 0x30 <= vk <= 0x39:                   # Shift+数字行 (裸数字是组字键, 不会到这)
        return _SHIFT_DIGIT[vk - 0x30] if sh else None
    if vk == 0xBC:
        return '《' if sh else '，'
    if vk == 0xBE:
        return '》' if sh else '。'
    if vk == 0xBA:
        return '：' if sh else '；'
    if vk == 0xBF:
        return '？' if sh else None          # 裸 / 透传
    if vk == 0xDC:
        return '｜' if sh else '、'
    if vk == 0xDB:
        return '『' if sh else '【'
    if vk == 0xDD:
        return '』' if sh else '】'
    if vk == 0xBD:
        return '——' if sh else None          # Shift+- -> 破折号 (U+2014 x2); 裸 - 透传
    if vk == 0xBB:
        return '＋' if sh else None          # Shift+= -> ＋; 裸 = 透传
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

# ---- 状态提示点 (第六十九轮): 鼠标旁的 12px 圆点, 一眼看出输入法是开还是关 ----
# 来由: hideidle=1 时空闲不显示候选条 -> 没有可见反馈(第五十七轮的抱怨); 托盘图标还可能被 Windows
# 收进 ^。设计取 harold-lu-bit/IMEDot 的"置顶小圆点"形态, 但**有意跟鼠标** —— 候选条跟随已按用户
# 决定冻结(§17/§D10), 状态点跟鼠标不冲突(它不承载内容, 只是状态灯)。详见 dot.py 头部。
#
# **默认关**(statedot = 0): 第六十九轮默认开, 随后用户反馈"好像影响到鼠标移动"。实测查清(见 dot.py):
# 它**不抢事件**(WindowFromPoint 确认穿透、不盖光标), 但"每 32ms 挪一个置顶窗口"是真的有代价 ——
# 用户能感觉到就让默认值是"关", 想要的人一个托盘勾选/一行 config 就能开。
_DOT = [None]
_DOT_TICK = [0]
_DOT_AT = [None]         # 上一次 tick 时的鼠标位置 (没动就不做任何 Win32 调用)


def _statedot_on():
    """「状态提示点」是否启用 (config `statedot`, **默认关** —— 见上面那段实测说明)."""
    return bool(CFG.get('statedot', False))


def _dot():
    """懒创建 (配置关掉时一个窗口都不建)."""
    if _DOT[0] is None:
        import dot as _dotmod
        _DOT[0] = _dotmod.Dot(root)
    return _DOT[0]


def _dot_tick():
    """把圆点摆到鼠标旁并按当前状态上色 (poll 里每 ~32ms 调一次; 关掉/托盘模式则隐藏).

    三处"别让它碍事"的措施(第六十九轮补充, 用户反馈"影响到鼠标移动"):
      ① **鼠标键按住时隐藏** —— 拖动/框选/调窗口大小正是"光标旁挂个置顶小窗"最碍事的时候,
         而且那时系统每步都在重算; 松开后下一拍自动回来。
      ② **光标没动且颜色没变 -> 直接返回**, 一个 Win32 调用都不做(空转只花一次 `cursor_pos`)。
      ③ 挪窗走 `win.move_topmost`(SetWindowPos), 比 `Tk.geometry()` 便宜约 3 倍 —— 见 dot.py。
    """
    if is_tray_mode():
        if _DOT[0] is not None:
            _DOT[0].hide()          # tray 模式没有"输入法开关状态", 提示点无意义
        return
    if not _statedot_on():
        if _DOT[0] is not None:
            _DOT[0].hide()
        return
    import dot as _dotmod
    p = win.cursor_pos()
    d = _dot()
    if p is None:
        _DOT_AT[0] = None
        d.hide()
        return
    if win.mouse_buttons_down():
        _DOT_AT[0] = None
        d.hide()
        return
    color = _dotmod.dot_color(ime.active, ime.mode, _VOICE.get('rec') is not None)
    if _DOT_AT[0] == p and d.is_shown() and d.color() == color:
        return                      # 光标没动、状态也没变 -> 什么都不用做
    _DOT_AT[0] = p
    r = win.workarea_at(p[0], p[1])          # 光标所在显示器的工作区 (多屏正确)
    x, y = _dotmod.dot_pos(p[0], p[1], (r.left, r.top, r.right, r.bottom))
    d.update(x, y, color)




def _set_mode_from_tray(m):
    """托盘「模式」子菜单: 切模式 (钳一下防越界) —— 且切到「语音」时**顺手打开语音功能**.

    第五十一轮: 第四十九轮只给 Ctrl+` 那条路径补了 `_voice_set_on(True)`, 托盘这条入口漏了 ->
    从托盘切到「语音模式」后候选条写着"按住 ctrl+alt+v 说话", 但热键被 VOICE_ON 门控透传,
    按了毫无反应(用户报过的原症状)。
    """
    ime.mode = int(m) % 5
    reset()
    if ime.mode == MODE_VOICE:
        _voice_set_on(True, why='tray-mode')
    show_page()


def _tray_api():
    """托盘的 api 字典: 全是**延迟求值**的 lambda —— 所以启动早期(ime/CFG/bar 还没建)也能先把
    图标对象建起来, 真正被调用时那些名字早就有了 (第五十三轮拆出来给"早挂图标"复用)。"""
    return {
        'toggle': lambda: set_active(not ime.active),
        'set_mode': lambda m: _set_mode_from_tray(m),   # 5 模式: 钳一下防越界 (+ 切语音模式时开语音)
        'toggle_voice': lambda: toggle_voice(),                   # 「语音输入」开关 (第四十七轮)
        'get_voice': lambda: CFG.get('voice', False),
        'voice_state': lambda: _voice_state_text(),
        'trad': lambda: toggle_trad(),
        'get_trad': lambda: bool(ime.trad),           # 托盘「繁体输出」勾选态 (对齐 C# miTrad.Checked = Trad)
        'quit': lambda: quit_app(),
        'is_active': lambda: ime.active,
        'get_mode': lambda: ime.mode,
        'apppaste': lambda: toggle_app_paste(),
        # 托盘「这个程序」两项的勾选态 (对齐 C# RefreshMenuChecks: AppModes[前台] == 1 / EffectiveKeyfix())
        'get_apppaste': lambda: APPMODES.get(win.foreground_process_name(), 0) == 1,
        'get_appkeyfix': lambda: bool(effective_keyfix()),
        'appkeyfix': lambda: toggle_app_keyfix(),
        'followcaret': lambda: toggle_followcaret(),
        'get_followcaret': lambda: _caret_follow(),
        'toggleshowcode': lambda: toggle_showcode(),
        'get_showcode': lambda: CFG.get('showcode', False),
        'toggletrans': lambda: toggle_trans(),                    # 「译文」(原译模式, 第四十四轮)
        'get_trans': lambda: CFG.get('trans', True),
        'togglesentence': lambda: toggle_sentence(),
        'get_sentence': lambda: CFG.get('sentence', True),
        'toggleassoc': lambda: toggle_assoc(),
        'get_assoc': lambda: CFG.get('assoc', True),
        'togglecnpunct': lambda: toggle_cnpunct(),
        'get_cnpunct': lambda: CFG.get('cnpunct', True),
        'togglehideidle': lambda: toggle_hideidle(),
        'get_hideidle': lambda: CFG.get('hideidle', True),
        'toggledot': lambda: toggle_statedot(),          # 「状态提示点」(第六十九轮)
        'get_statedot': lambda: _statedot_on(),
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
    }


def _create_tray():
    """建托盘对象 (第四十轮: 从启动主路径挪进主循环).

    `import tray`(=pystray + PIL) 实测要 ~300ms (它连带 zipimport 第三方库), 以前排在
    `root.after(8, poll)` 之前 —— 而那会儿钩子早在收键排队了, 这 300ms 纯粹是"上屏"白等。
    现在由 _deferred_tray() 在主循环里调; **但若启动早期已经 `_boot_tray()` 挂过图标了,
    _deferred_tray 只补完整菜单** (见那里), 不会重复建。
    """
    global TRAY
    try:
        import tray as _tray_mod
        TRAY = _tray_mod.Tray(root, _tray_api())
    except Exception as e:
        _dfn('tray create err %r' % e)
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
            if fn.lower() in disabled:continue                # 第五十一轮: 禁用判断提到 exec **之前**
            try:                                              # (以前在 exec 之后 -> 被停用的插件
                spec=importlib.util.spec_from_file_location(modname,path)   # 每次启动仍会执行模块级代码/副作用)
                if spec is None or spec.loader is None:raise ImportError('no module spec')
                m=importlib.util.module_from_spec(spec);sys.modules[modname]=m
                spec.loader.exec_module(m)
                code=getattr(m,'CODE',None)
                if not code or not callable(getattr(m,'run',None)):
                    raise ValueError('plugin must define CODE and callable run()')
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
         'plugins': ('插件管理', 'pluginmgr'), 'cjgl': ('插件管理', 'pluginmgr'),
         'deps': ('依赖自检', 'depcheck'), 'yilai': ('依赖自检', 'depcheck')}
    if code in b:
        return (b[code][0], 'builtin', b[code][1])
    return None


def _caret_follow():
    """光标跟随是否启用 (第六十八轮: **默认 0 = 冻结**).

    用户的决定: 候选窗固定贴屏幕边缘, 不再跟随光标; 但**代码全部保留** —— `followcaret = 1`
    (config.txt 或托盘「候选窗跟随光标」)可随时开回来。所以这里只是一个**开关读取**, helper
    子进程/UIA 定位链一行没删。凡是要读这个开关的地方(起 helper、bar 定位、托盘勾选)都走它,
    免得将来又出现"有的地方默认 True、有的地方默认 False"这种自相矛盾。
    """
    return bool(CFG.get('followcaret', False))


# ---------- 显示 ----------
def show_page():
    follow = _caret_follow()      # 第六十八轮: 默认 0 (冻结); 打开时照旧跟随
    # 语音 (第四十七轮): ① 待确认结果 -> 占一行候选, 空格上屏 / Esc 丢弃;
    # ② 正在录/识别中/语音模式 -> 候选条当状态指示用 (显示"按住说话/正在听…")
    if _VOICE['text'] is not None and not _VOICE['busy']:
        if _VOICE['click']:
            # 点击落点: 文本已在剪贴板, 只等用户点目标输入框
            bar.show('[语音|开] ', '点目标输入框粘贴 / Esc 放弃', [_VOICE['text']], 0, 0, 1, follow)
        else:
            bar.show('[语音|开] ', '空格上屏 / Esc 丢弃', [_VOICE['text']], 0, 0, 1, follow)
        return
    if _VOICE['partial'] is not None and _VOICE['busy']:
        # 流式后端: 边说边出 (第七十五轮)
        bar.show('[语音|开] ', '识别中… (实时)', [_VOICE['partial']], 0, 0, 1, follow)
        return
    if _VOICE['busy'] or _VOICE['rec'] is not None or ime.mode == MODE_VOICE:
        bar.show('[语音|开] ', _voice_state_text(), [], 0, 0, 1, follow)
        return
    header = '[%s|开] ' % MODE_NAMES[ime.mode] + ('繁 ' if ime.trad else '')   # 对齐 C#: [模式|开] 头
    page_c = ime.cands[ime.page * 9:(ime.page + 1) * 9]
    total = (len(ime.cands) + 8) // 9
    # showcode/trans: 候选上挂反查编码 / 离线译文 (仅显示, 不改变上屏)
    # 传的是 (词, 全提示, 只译文提示) 三元组: bar 宽度不够时按 tier 丢提示而不是把提示切一半
    # (第四十五轮; 见 bar.show 的退化逻辑)
    if CFG.get('showcode') or CFG.get('trans'):
        page_c = [_cand_variants(w) for w in page_c]
    if ime.assoc_showing:
        bar.show(header + '↪联想', '', page_c, 0, ime.page, total, follow)
    elif ime.buf:
        # 缓冲非空即显示 (即使无候选) —— 无候选时也能看到已输入的编码, 不会"消失"
        bar.show(header, ime.buf, page_c, ime.sel, ime.page, total, follow)
    elif not CFG.get('hideidle', True):
        # hideidle=0: 常驻候选窗 (贴任务栏), 不跟随; 显示 C# 同款空闲提示 (对齐 RefreshLabel)。
        # 第五十二轮: **不再强制 bottom-right** —— 用户要求"让拖动生效": 原来每次刷新都传
        # fixed='bottom-right', 走 bar 的"直接 geometry"分支, 既不读 pos.txt 也不看拖动后的位置
        # (而 _drag_end 照样把位置写进 pos.txt), 表现为"拖走了下一次刷新又弹回右下角"。
        # 传 fixed=None 让 bar 的固定分支接管: 首次用 pos.txt/居中, 之后保持当前位置并只在
        # 越界时钳进工作区。
        bar.show(header.rstrip(), '(Shift开关 Ctrl+` 模式 vf符号)', [], 0, 0, 1, False, None)
    else:
        bar.hide()


def _cand_variants(w):
    """候选的 `(词, 全提示, 只译文提示)` —— 给 bar 按宽度逐级退化用 (第四十五轮).

    反查编码 (showcode): 五笔模式显**拼音**码, 其余模式显**五笔**码 (对齐 C# CodeHint/RevWb)。
    译文 (trans, 第四十四轮): 中文候选挂英文 (ce 反查表), 英文候选挂中文 (ec 表) —— 离线、秒出、
    查不到就不挂。两个开关互相独立。
    形态: `词 (码)→译` / `词→译` / `词`。bar 装不下就逐级丢提示, **不会**把 `测试 (imya)` 切成
    `测试 (imya…` 那种半截提示 (用户实测的 `不太妙`)。
    """
    try:
        code = ''
        if CFG.get('showcode'):
            c = engine.code_for(w) if ime.mode == 2 else engine.rev_wb_code(w)
            if c:
                code = ' (%s)' % c
        tr = ''
        # 词典模式(3)的候选本身就是译文, 不再挂 →英文 (第四十三轮的判断, 第四十六轮模式回来后保留)
        if CFG.get('trans') and ime.mode < 3:
            t = engine.translate_hint(w)
            if t:
                tr = '→%s' % t
        return (w, '%s%s' % (code, tr), tr)
    except Exception:
        return (w, '', '')


def refresh():
    # 语音模式 (第四十七轮): 不组字 —— 缓冲区永远为空, 候选条交给 show_page 画录音/识别状态
    if ime.mode == MODE_VOICE:
        ime.buf = ''
        ime.cands = []
        hook.COMPOSING[0] = _VOICE['text'] is not None
        hook.VOICE_MODE[0] = True
        show_page()
        return
    ime.page = 0
    ime.sel = 0
    if not ime.buf:
        if _VOICE['rec'] is not None or _VOICE['busy']:
            show_page()                    # 录音/识别中: 候选条当状态指示用 (第四十七轮)
        else:
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
    # 选项「译文」+ 本模式查不到任何候选 -> 补一次**离线词典查询** (原译模式的 EN->CN / CN->EN)。
    # 只在"没有候选"时补, 所以绝不会把真正的拼音候选顶掉 (对齐 §22 的教训: 拼音模式无条件查 ec
    # 会让打 no/shi 时串进"不/没有"; 这里 nihao 有拼音候选 -> 根本不查 ec)。
    # `not exact_wubi` 是额外保险: 五笔精确码命中时绝不掺词典词, 免得动到"唯一四码自动上屏"的判定。
    if CFG.get('trans') and not cands and not exact_wubi and ime.mode < 3:
        extra, _x, _y = engine.candidates(ime.buf, 3, py)
        if extra:
            cands = list(extra)
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
    hook.VOICE_MODE[0] = (ime.mode == MODE_VOICE)      # 语音模式: 钩子按键透传 (第四十七轮)
    bar.hide()


# ---------- 语音输入 (第四十七轮) ----------
# 录音在 voice.py (winmm 纯 ctypes); 识别三条后端 (系统离线引擎/HTTP/外部命令) 也在那里。
# 这里只负责: 热键、状态显示、结果进候选条(空格确认)或直接上屏。**识别走后台线程**, 主线程不卡。
_VOICE = {'rec': None, 't0': 0.0, 'toggle': False, 'busy': False, 'text': None, 'mod': None,
          'click': False,   # 第七十四轮: 语音"点击落点"等待态 (见 _voice_click_arm)
          'partial': None}  # 第七十五轮: 流式识别的**实时文本** (边说边出)
VOICE_Q = queue.Queue()
_VOICE_TICK = [0.0]        # 上次给"正在听…(Ns)"续秒的时间 (见 _voice_tick)
_VOICE_SEQ = [0]           # 录音文件序号 (每次一把独立文件名, 见 voice_finish; 第六十三轮)


def _voice_tick(now=None):
    """录音中给候选条的秒数续命 (poll 里 ~4Hz 调用)。

    第五十八轮: 以前录音期间**没有任何东西重画候选条** —— 条上那句 "正在听… (0s) 松开结束" 是
    按下那一刻的字符串, 秒数永远不动。用户看到"一直是 0s"就以为没在收音(其实录着), 也没法判断
    到底该什么时候松手。这里让秒数真的走起来 (show_page 是幂等的纯界面重画)。
    """
    if _VOICE['rec'] is None:
        return False
    now = time.time() if now is None else now
    if now - _VOICE_TICK[0] < 0.25:
        return False
    _VOICE_TICK[0] = now
    try:
        show_page()
    except Exception:
        pass
    return True


def _voicemod():
    """懒装载 voice.py (dist 里是懒模块: 不开语音就完全不付它的代价)."""
    if _VOICE['mod'] is None:
        import voice as _v
        _VOICE['mod'] = _v
    return _VOICE['mod']


def _voice_hotkey_text():
    try:
        return (CFG.get('hotkeys') or {}).get('voice') or 'ctrl+alt+v'
    except Exception:
        return 'ctrl+alt+v'


def _voice_state_text():
    """候选条第二段 / 托盘用的状态文本."""
    r = _VOICE['rec']
    if r is not None:                       # 正在录优先显示 (识别上一句的同时又开始录下一句)
        if _VOICE['toggle']:
            return '正在听… (%ds) 再按一次结束' % (r.elapsed_ms() // 1000)
        return '正在听… (%ds) 松开结束' % (r.elapsed_ms() // 1000)
    if _VOICE['busy']:
        return '识别中…'
    if _VOICE['text'] is not None:
        return '空格上屏 / Esc 丢弃'
    return '按住 %s 说话' % _voice_hotkey_text()


def _voice_ok():
    """能不能用; 不能就提示一次并返回 False."""
    if not CFG.get('voice'):
        _notify('语音输入', '语音输入没打开: 托盘「选项 → 语音输入」或 config.txt 里 voice = 1')
        return False
    if not _voicemod().available():
        _notify('语音输入', '找不到麦克风 (或系统不让桌面应用访问麦克风)')
        return False
    return True


def voice_down():
    """热键按下: 开始录音; 已经在录 (语音模式里点一下开始的那种) 就收尾识别."""
    if _VOICE['rec'] is not None:
        voice_finish()                      # 第二次点 = 结束并识别
        return
    if not _voice_ok():
        return
    v = _voicemod()
    try:
        v.warm(CFG)                         # 本地 whisper: 按下就开始载模型, 与"说话"这段时间重叠
    except Exception as e:                  # (第六十三轮; 非 whisper 引擎是空操作)
        _dfn('voice: warm failed: %r' % (e,))
    rec = v.Recorder(silence=float(CFG.get('voice_silence', 1.2) or 0),
                     max_ms=int(float(CFG.get('voice_max', 20) or 20) * 1000),
                     on_auto_stop=lambda: VOICE_Q.put(('auto',)))
    if not rec.start():
        _dfn_always('voice: start failed: %s' % (rec.err,))
        _notify('语音输入', rec.err or '录音打不开')
        return
    _VOICE['rec'] = rec
    _VOICE['t0'] = time.time()
    _VOICE_TICK[0] = 0.0                    # 立刻画一次 "正在听… (0s)" (见 _voice_tick)
    _VOICE['toggle'] = False
    _VOICE['text'] = None
    _VOICE['partial'] = None            # 新录一句: 上一句的实时文本作废 (第七十五轮)
    _voice_click_disarm()               # 新录一句: 上一句的"点击落点"等待态作废 (顺带收钩)
    hook.COMPOSING[0] = False
    _dfn('voice: recording (engine=%s lang=%s silence=%s)'
         % (CFG.get('voice_engine'), CFG.get('voice_lang'), CFG.get('voice_silence')))
    show_page()


def voice_up():
    """热键松开: 语音模式里"轻点"= 改成常录(再点结束), 否则松开即结束."""
    rec = _VOICE['rec']
    if rec is None:
        return
    if ime.mode == MODE_VOICE and (time.time() - _VOICE['t0']) < 0.35 and not _VOICE['toggle']:
        _VOICE['toggle'] = True             # 点一下开始, 静音自动停 / 再点一次结束
        _dfn('voice: toggle mode (keep recording)')
        show_page()
        return
    voice_finish()


def voice_finish():
    """停止录音 -> 写 WAV -> 后台识别 -> 结果经 VOICE_Q 回主线程."""
    rec = _VOICE['rec']
    if rec is None:
        return
    _VOICE['rec'] = None
    ms = rec.elapsed_ms()
    spoke = bool(getattr(rec, 'spoke', True))
    pcm = rec.stop()
    if not pcm:
        # 第五十八轮: 设备在、也打开成功, 却**一个字节都没回调** —— 以前只写 debug 日志后静默丢弃,
        # 用户只看到"按了没反应"。现在明确报出来 (静音/被独占/选错设备)。
        _dfn_always('voice: NO AUDIO DATA (%dms) - device busy/muted?' % ms)
        _notify('语音输入', '没收到任何音频数据 (麦克风被静音、被别的程序独占, 或选错了输入设备)')
        show_page()
        return
    if ms < 400:
        _dfn('voice: too short (%dms) - dropped' % ms)
        show_page()
        return
    if not spoke:
        # 有数据但音量一直压着阈值: 报一个能判断的数值, 而不是干巴巴一句"没听到说话声"。
        # 峰值 == 0 说明设备给的是**纯数字静音** -> 是"麦克风被静音/选错设备", 不是"说话太轻"。
        try:
            pk = _voicemod().peak(pcm)
            lvl = _voicemod()._rms(pcm)
        except Exception:
            pk = lvl = -1
        _dfn('voice: no speech detected (%dms, peak=%s rms=%s) - dropped' % (ms, pk, lvl))
        if pk == 0:
            _dfn_always('voice: MIC IS DIGITALLY SILENT (%dms, all-zero pcm)' % ms)
            _notify('语音输入', '麦克风给的是纯静音 (%.1fs 全 0): 输入设备被静音或者选错了设备 '
                                '(右键任务栏音量 → 声音设置 → 输入)' % (ms / 1000.0,))
        else:
            _notify('语音输入', '没听到说话声 (录了 %.1fs, 峰值≈%s 音量≈%s；一直这样就把麦克风音量调大, '
                                '或换个输入设备)' % (ms / 1000.0, pk, lvl))
        show_page()
        return
    v = _voicemod()
    # 每次一个独立文件名 (第六十三轮): 常驻 whisper 助手是**过几秒**才去读这个 wav 的, 用固定名会让
    # "上一句还在识别、这一句又录完"把文件覆盖掉 —— 结果是上一句识别出**这一句**的内容(张冠李戴,
    # 而且只会偶尔发生, 很难查)。所以按 序号 命名, 识别完各自删各自的。
    _VOICE_SEQ[0] += 1
    path = os.path.join(DATA_DIR, 'runtime', 'voice-%d-%d.wav' % (os.getpid(), _VOICE_SEQ[0]))
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        v.write_wav(path, pcm)
    except Exception as e:
        _notify('语音输入', '录音存盘失败: %r' % (e,))
        show_page()
        return
    _VOICE['busy'] = True
    _dfn('voice: recorded %dms -> recognize via %s' % (ms, CFG.get('voice_engine')))
    show_page()

    def _work():
        try:
            text, err = v.recognize(path, CFG, on_delta=lambda s: VOICE_Q.put(('partial', s)))
        except Exception as e:
            text, err = None, '识别异常: %r' % (e,)
        VOICE_Q.put(('done', text, err, path))

    threading.Thread(target=_work, name='wgime-voice-recog', daemon=True).start()


def voice_cancel():
    """丢弃待确认结果 / 取消正在录的这一次."""
    if _VOICE['rec'] is not None:
        try:
            _VOICE['rec'].stop()
        except Exception:
            pass
        _VOICE['rec'] = None
    _VOICE['text'] = None
    _voice_click_disarm()               # Esc/切模式取消: 收钩 (别让全局鼠标钩子挂着)
    hook.COMPOSING[0] = False
    show_page()


def voice_commit():
    """待确认结果上屏: 走现有 inject (剪贴板/keyfix/UIPI 全兼容); **不进词频学习/联想**."""
    text = _VOICE['text']
    _VOICE['text'] = None
    if text:
        inject(text)
        _dfn('voice: commit %r' % text)
    hook.COMPOSING[0] = False
    show_page()



def _voice_click_arm(text):
    """进入"点击落点"等待态: 文本已在剪贴板, 等用户点目标输入框 (见 _voice_drain 调用处).

    为什么要落剪贴板: ① 用户随时可以自己 Ctrl+V; ② 命中后我们发的也是粘贴, 内容一致。
    """
    _VOICE['click'] = True
    try:
        win.clipboard_set(text)
    except Exception as e:
        _dfn('voice: clipboard_set failed: %r' % (e,))
        _VOICE['click'] = False
        return
    _dfn_always('voice: click-to-paste armed (%d chars, 已进剪贴板)' % len(text))

    def _hit():
        try:
            root.after(0, _voice_click_hit)
        except Exception:
            pass
    try:
        win.click_watch_start(_hit)
    except Exception as e:
        _dfn('voice: click watch failed: %r (降级为空格确认)' % (e,))


def _voice_click_hit():
    """钩子回调 (已 marshal 回主线程): 目标窗口刚被点中 -> 稍等一下再粘贴."""
    if not _VOICE['click']:
        return
    win.click_watch_stop()
    _dfn('voice: click-to-paste hit (150ms 后粘贴)')
    try:
        root.after(150, _voice_click_paste)     # 让这一下点击(mouseup/焦点切换)先走完
    except Exception:
        _voice_click_paste()


def _voice_click_paste():
    """真正粘贴 (走现有 inject: 剪贴板/keyfix/UIPI 全兼容), 并退出等待态."""
    if not _VOICE['click']:
        return
    text = _VOICE['text']
    _VOICE['click'] = False
    _VOICE['text'] = None
    hook.COMPOSING[0] = False
    if text:
        inject(text)
        _dfn('voice: click-to-paste commit %r' % text)
    show_page()


def _voice_click_disarm():
    """退出等待态 (取消/重新录音/退出/切模式): **必须收钩**, 别让全局鼠标钩子挂在那儿."""
    _VOICE['click'] = False
    try:
        win.click_watch_stop()
    except Exception:
        pass


def _voice_drain():
    """主线程 (poll 里) 收识别结果与 VAD 自动停请求."""
    while True:
        try:
            item = VOICE_Q.get_nowait()
        except queue.Empty:
            break
        if item[0] == 'auto':
            if _VOICE['rec'] is not None:
                _dfn('voice: auto-stop (silence or max duration)')
                voice_finish()
            continue
        if item[0] == 'partial':
            # 流式后端: 增量文本 (第七十五轮) —— 只更新界面, 不碰状态机
            _VOICE['partial'] = item[1] if len(item) > 1 else None
            show_page()
            continue
        _kind, text, err, wav = (list(item) + [None, None, None])[:4]
        _VOICE['busy'] = False
        _VOICE['partial'] = None        # 定稿: 实时文本让位给最终结果 (第七十五轮)
        # 删这一次的 wav; 顺带清掉旧版本遗留的固定名 voice-last.wav (升级后第一次用语音时清掉)
        for _p in (wav, os.path.join(DATA_DIR, 'runtime', 'voice-last.wav')):
            if not _p:
                continue
            try:
                os.remove(_p)
            except OSError:
                pass
        if err:
            _dfn_always('voice: recognize failed: %s' % err)
            _notify('语音输入', err)
        elif not text:
            _notify('语音输入', '没听清, 再说一次?')
        else:
            _dfn_always('voice: recognized %r' % text)
            if CFG.get('voice_auto') or not ime.active:
                inject(text)                # 自动上屏 (输入法没激活时直接打进当前窗口)
            else:
                _VOICE['text'] = text
                hook.COMPOSING[0] = True    # 让空格/数字/Esc 被钩子吞进输入法 (同组字中的候选键)
                if CFG.get('voice_click'):
                    _voice_click_arm(text)  # 只进剪贴板 + 等点击 (第七十四轮)
        show_page()


def _voice_set_on(on, why=''):
    """把语音**功能**打开/关掉 (幂等). 托盘「选项→语音输入」和「语音」模式都用它, 免得两处状态打架。

    第四十九轮: 用户反馈"模式菜单里的语音点了没作用, 只有选项里的才开启" —— 因为模式那个只切了
    `ime.mode`, 没开 `voice`。现在**切到语音模式 = 顺手打开语音功能**, 两边表现一致。
    """
    want = bool(on)
    if CFG.get('voice', False) == want:
        return want
    CFG['voice'] = want
    _dfn('voice=%s (%s)' % (want, why or 'toggle'))
    _saved = _write_config('voice', '1' if want else '0')
    hook.VOICE_ON[0] = want
    if not _saved:
        _notify('语音输入', 'config.txt 写不进去 (%s), 这次的开关状态重启后会丢'
                % os.path.join(APP_DIR, 'config.txt'))
    if want:
        try:
            if not _voicemod().available():
                _notify('语音输入', '语音已打开, 但没找到麦克风 (设置→隐私和安全性→麦克风→允许桌面应用访问麦克风?)')
            else:
                _notify('语音输入', '语音已打开: 按住 %s 说话' % _voice_hotkey_text())
        except Exception as e:
            _notify('语音输入', '语音模块不可用: %r' % (e,))
    else:
        voice_cancel()
    return want


def toggle_voice():
    """托盘「选项 → 语音输入」: 语音功能总开关 (第四十七轮)."""
    on = _voice_set_on(not CFG.get('voice', False), why='tray-option')
    if not on and ime.mode == MODE_VOICE:
        # 关掉语音时别把人留在"语音模式"里干瞪眼: 自动切回混合模式
        ime.mode = 0
        reset()
    show_page()
    _refresh_tray()


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
    """原子改写 config.txt 的一行 key (保留行尾, utf-8-sig 兼容 BOM, 正则精确匹配).

    **返回 True/False** —— 第四十八轮修两个静默失败:
    ① 以前 `APP_DIR\\config.txt` **不存在就直接 open 失败被 `except OSError: pass` 吞掉**,
       于是"托盘开关点了 config.txt 没变"(python 版可以不带 config.txt 跑, 默认值全在代码里);
       现在文件不存在就**新建**一个;
    ② 写失败一定写 always-on 日志(并在调用处给用户气泡), 不再无声无息。
    """
    path = os.path.join(APP_DIR, 'config.txt')
    try:
        try:
            # 第五十一轮: 走 read_text 宽松解码 —— 用户把 config.txt 另存为 ANSI(GBK) 时, 严格 utf-8 抛的
            # UnicodeDecodeError **不是 OSError**, 会从 Tk 回调里冒出去(pythonw 下无声), 表现是
            # "所有写配置的开关点了都没反应、也不落盘" (§28)。read_text 是二进制读+解码, 不做行尾翻译,
            # 正好也是下面"行尾跟原文件走"需要的。
            text = read_text(path)
        except OSError:
            text = '; WgIme (Python) 配置 (托盘开关改动后自动创建; 完整模板见发行包里的 config.txt)\n'
        # 行尾**跟原文件走** (对齐 C# `SaveConfigKey` 的 `nl = t.Contains("\r\n") ? "\r\n" : "\n"`):
        # 出厂模板 config.txt 是 LF, 以前这里固定 '\n' 再交给 text 模式 -> 第一次翻托盘开关就把整份
        # LF 配置变成 CRLF (整文件变动, 也与 C# 写出来的不一致)。现在自己按原行尾拼, 并用 newline=''
        # 禁止再翻译; 每行先把残留的 \r 去掉 (C# 的 Split("\r\n","\n") 也是丢终止符)。
        nl = '\r\n' if '\r\n' in text else '\n'
        lines = [l[:-1] if l.endswith('\r') else l for l in text.split('\n')]
        found = False
        for i, l in enumerate(lines):
            if re.match(r'^\s*%s\s*=' % re.escape(key), l):
                lines[i] = '%s = %s' % (key, value)
                found = True
                break
        if not found:
            lines.append('%s = %s' % (key, value))
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(nl.join(lines))
        return True
    except OSError as e:
        _dfn_always('config: 写入 %s = %s 失败 (%s): %r' % (key, value, path, e))
        return False


def _save_cfg(key, value, label):
    """写回 config.txt, **失败要告诉用户** (第四十八轮只给语音加了提示, 其余开关会静默丢设置).

    第四十八轮的教训: 写失败只写日志时, 用户看到的是"开关点了没用 / 重启又变回来"。C# 的
    `SaveConfigKey` 是 `catch {}` 完全静默 —— 这里**有意做得比 C# 好**, 记在 AGENTS §27 的反向差异清单。
    """
    if _write_config(key, value):
        return True
    _notify('设置未保存', '%s 已生效, 但写 config.txt 失败 (目录只读?), 重启后会回到旧值: %s'
            % (label, os.path.join(APP_DIR, 'config.txt')))
    return False


def toggle_trad():
    """简繁输出切换 (Ctrl+Shift+F / 托盘): 立即生效 + 写回 config.txt (对齐 C# Hook_OnToggleTrad 的持久化)."""
    ime.trad = not ime.trad
    _dfn('trad=%s' % ime.trad)
    _save_cfg('trad', '1' if ime.trad else '0', '繁体输出')
    reset()
    _refresh_tray()


def toggle_followcaret():
    """托盘「候选窗跟随光标」开关.

    第六十八轮**冻结**: 默认值改成 0(候选窗固定贴屏幕边缘, 不再跟随光标), 但开关本身与整条
    跟随链(helper 子进程 + UIA + JSONL IPC + bar 定位 + 启动时不再起 helper)**一行没删** ——
    想开回来点一下托盘即可(config `followcaret = 1`)。
    """
    CFG['followcaret'] = not _caret_follow()
    _dfn('followcaret=%s' % CFG['followcaret'])
    _save_cfg('followcaret', '1' if CFG['followcaret'] else '0', '跟随光标')
    show_page()   # 立即用新 followcaret 重定位候选框(组字/常驻), 否则"点了没反应"


def toggle_showcode():
    """反查编码开关: 候选上显示反查编码(五笔用五笔码, 否则拼音)."""
    CFG['showcode'] = not CFG.get('showcode', False)
    _dfn('showcode=%s' % CFG['showcode'])
    _save_cfg('showcode', '1' if CFG['showcode'] else '0', '反查编码')
    if CFG['showcode']:
        try:
            engine.warm_rev_wb()      # 刚打开: 后台建反查表, 别让下一键卡 ~1.2s
        except Exception:
            pass
    show_page()   # 立即按新 showcode 刷新候选(显示/隐藏编码)


def toggle_trans():
    """「译文」开关 (第四十四轮, 原译/词典模式): 候选挂**离线词典译文**; 而且当本模式查不到任何
    候选时, 再补一次离线词典查询 (打英文 -> 出中文, 打拼音 -> 出英文)。
    离线词典表在后台加载, 打开时顺手预热, 不影响按键。

    第四十五轮: 打开/关闭都写一条 **always-on** 日志, 并报告词典表状态 —— 用户报过"只开译文
    看不到东西" (多半是跑着旧文件, 或词典表还没加载完), 有这条日志就能一眼看出来。"""
    CFG['trans'] = not CFG.get('trans', True)
    _dfn('trans=%s' % CFG['trans'])
    _save_cfg('trans', '1' if CFG['trans'] else '0', '译文')          # 写回 config.txt
    try:
        _ef = os.path.join(DICT_DIR, 'en-freq.txt')          # 诊断: 用**文件大小**判"常用词表部署了没",
        _ef_n = os.path.getsize(_ef) if os.path.exists(_ef) else 0   # 不看 _en_rank_n (吃缓存时是 0)
        _dfn_always('trans=%s showcode=%s ec_ready=%s ec_fail=%s en-freq=%sB'
                    % (CFG['trans'], CFG.get('showcode'), getattr(engine, '_ec_ready', None),
                       getattr(engine, '_ec_fail', None), _ef_n))
    except Exception:
        pass
    if CFG['trans']:
        _ready = bool(getattr(engine, '_ec_ready', False))
        _fail = bool(getattr(engine, '_ec_fail', False))
        if _fail:
            _notify('译文', '词典表 (ec.txt / import_ec.txt) 读不出来, 译文没法显示 (详见 debug.log)。')
        elif not _ready:
            _notify('译文', '词典表正在后台加载, 等几秒再打一次就出来了 (首次从码表重建要十几秒)。')
        try:
            engine.warm_ec()          # 译文要用词典表 (ce/ec): 顺手起后台加载
        except Exception:
            pass
    if ime.buf:
        refresh()                     # 立即按新开关刷新候选
    else:
        show_page()


def toggle_hideidle():
    """空闲隐藏开关: 空闲时隐藏候选窗(0=常驻). 切后直接 show_page(按 hideidle 立即常驻/隐藏)."""
    CFG['hideidle'] = not CFG.get('hideidle', True)
    _dfn('hideidle=%s' % CFG['hideidle'])
    _save_cfg('hideidle', '1' if CFG['hideidle'] else '0', '空闲隐藏')
    show_page()


def toggle_statedot():
    """托盘「状态提示点」开关 (第六十九轮): 立即显/隐 + 写回 config.txt."""
    CFG['statedot'] = not _statedot_on()
    _dfn('statedot=%s' % CFG['statedot'])
    _save_cfg('statedot', '1' if CFG['statedot'] else '0', '状态提示点')
    _dot_tick()          # 立即生效(别等下一次 tick), 关掉时也会把窗口隐掉


def toggle_sentence():
    """整句输入开关: 全拼连打按词频搜最佳路径."""
    CFG['sentence'] = not CFG.get('sentence', True)
    _dfn('sentence=%s' % CFG['sentence'])
    _save_cfg('sentence', '1' if CFG['sentence'] else '0', '整句输入')
    if ime.buf:
        refresh()


def toggle_assoc():
    """联想开关: 上屏后出联想候选."""
    CFG['assoc'] = not CFG.get('assoc', True)
    _dfn('assoc=%s' % CFG['assoc'])
    _save_cfg('assoc', '1' if CFG['assoc'] else '0', '联想')


def toggle_cnpunct():
    """全/半角标点开关 (Ctrl+. 或托盘): 开=逗号句号等直接上屏全角中文标点."""
    CFG['cnpunct'] = not CFG.get('cnpunct', True)
    hook.set_punct(CFG['cnpunct'])
    _dfn('cnpunct=%s' % CFG['cnpunct'])
    _save_cfg('cnpunct', '1' if CFG['cnpunct'] else '0', '全角标点')
    _refresh_tray()


def set_theme(name):
    CFG['theme'] = name
    bar.set_theme(name)
    # 第五十一轮: 候选条的颜色只在 show() 里取自 THEMES, 所以换主题后必须重绘 —— 以前只改 alpha,
    # 于是"切主题"看起来只是变半透明, 底色/文字要到下一次按键才变。
    if ime.buf:
        refresh()
    else:
        show_page()
    _dfn('theme=%s' % name)
    _save_cfg('theme', name, '主题')   # 写回 config.txt


def quit_app():
    _voice_click_disarm()               # 退出前收钩: 别把全局鼠标钩子留给下一个进程/系统
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
        if _VOICE.get('mod') is not None:
            _VOICE['mod'].shutdown()                     # 常驻 whisper 助手: 立刻收掉 (别留下占内存的子进程)
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
    if not _save_cfg('mode', new_mode, '运行模式'):
        return                       # 写不进去就别重启: 否则重启后还是旧模式, 用户看到的是"切换没生效"
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
    """以词定字 (`[` / `]`): 取首候选的首字/末字上屏 (对齐 C# `Hook_OnPickChar`).

    第五十一轮对齐 C# 三点: ① 学的是**整个候选词** `w`(送出去的是单字 `c`) —— 以前把单字当词学,
    于是多字词永远得不到这次提升/LastPick; ② 动态候选**不学**(C# `!dynSet.Contains(w)`, 与 §14 一致);
    ③ 定字后按 C# 调 `BeginAssoc(c)` 出联想 (以前 reset() 直接清掉, 定字后没有联想)。
    """
    if not ime.cands:
        return
    w = ime.cands[0]
    c = w if len(w) == 1 else (w[0] if idx == 0 else w[-1])
    if w not in ime.dyn_set:
        engine.learn(ime.buf, w, ime.mode)
    inject(c)
    reset()
    begin_assoc(c)


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


def _bg_plugin(fn, *args):
    """后台线程里跑插件/工具任务的统一入口: **异常必须报出来**。

    pythonw 下 `sys.stdout/stderr` 都是 None, 裸线程里抛异常是完全无声的 (threading.excepthook 自己
    也打不出东西) —— 用户看到的就是"点了插件没反应"。这里兜住并走气泡 (对齐 §25 的状态反馈) + 日志。
    """
    try:
        fn(*args)
    except Exception as ex:
        _dfn('%s err %r' % (getattr(fn, '__name__', 'task'), ex))
        try:
            name = getattr(args[0], 'name', '') if args else ''
            _notify('插件运行出错', '%s: %r' % (name, ex))
        except Exception:
            pass


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
    text = read_text(payload.path)            # 宽松解码 (§28): 用户可能把插件 txt 存成 ANSI/GBK
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
        threading.Thread(target=_bg_plugin, args=(_run_csharp_plugin, payload), daemon=True).start()
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


# 第四十轮: tools.set_notifier(_notify) 从模块级挪进 _deferred_tools() —— 它是 `import tools` 的
# 第一个属性访问, 也就是说这行原来会触发 tools 模块的懒装载(实测 ~150ms)并排在主循环之前。


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
            'perm': _get('PERM', 'low'), 'desc': _get('DESC'),
            'standalone': bool(re.search(r'^\s*STANDALONE\s*=\s*(True|1)\b', text, re.M))}


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
        threading.Thread(target=_bg_plugin, args=(_run_csharp_plugin, p), daemon=True).start()
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
        elif kind == 'depcheck':
            _deps_open_window()
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
    (0xDD, False): ']', (0xDD, True): '}', (0xC0, False): '`', (0xC0, True): '~',
    (0xBD, True): '_', (0xBB, True): '+',
    (0x31, True): '!', (0x32, True): '@', (0x33, True): '#', (0x34, True): '$',
    (0x35, True): '%', (0x36, True): '^', (0x37, True): '&', (0x38, True): '*',
    (0x39, True): '(', (0x30, True): ')',
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
    if vk in (_pk1, _pk2) and _pk1 != _pk2 and ime.buf:
        if ime.buf == 'vf' or not ime.cands:
            # C# Hook_OnPickChar 第一句: `if (cands.Count == 0 || keys == "vf") { Send(firstLast==0?"【":"】"); return; }`
            # 第五十一轮: 以前漏了 vf 门控 -> 符号面板里按 [ 会把分类名/符号当汉字上屏并学进词频。
            inject('【' if vk == _pk1 else '】')
            return
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
            # 第五十一轮: 对齐 C# `RecordCommit` 的第一句 `LearnAssoc(前词, w)` —— 标点这条路也要记
            # bigram 并推进前词, 否则下一次 commit 的联想前词会停留在更早的词上(联想错配)。
            if ime.last_commit and len(top) <= 8 and is_all_cjk(top):
                engine.learn_assoc(ime.last_commit, top)
            ime.last_commit = top if (len(top) <= 8 and is_all_cjk(top)) else None
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
        ime.mode = (ime.mode + 1) % 5             # 第四十七轮: 加了「语音」模式 (混合/拼音/五笔/词典/语音)
        if _VOICE['rec'] is not None or _VOICE['text'] is not None:
            voice_cancel()                        # 切模式时把没结束的录音/待确认结果丢掉
        reset()
        if ime.mode == MODE_VOICE:
            # 第四十九轮: 切到「语音」模式就**顺手把语音功能打开** —— 否则模式菜单里点了没反应
            # (用户反馈: "mode 里的变动没任何作用, option 里的才开启")
            _voice_set_on(True, why='enter-voice-mode')
        _refresh_tray()
        show_page()
        return
    if vk == VK['VOICE']:                         # 语音热键按下: 开始录 / 再按一次结束
        voice_down()
        return
    if vk == VK['VOICE_UP']:                      # 松开: 按住说话结束 (语音模式里轻点=常录)
        voice_up()
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
    # 语音识别结果待确认 (第四十七轮, voice_auto=0): 空格/回车/1 上屏, Esc 丢弃
    # (pending 时 hook.COMPOSING=True, 所以这些键才会被钩子吞进来)
    if _VOICE['text'] is not None:
        if vk in (K['first'], K['raw'], 0x31):
            voice_commit()
            return
        if vk == K['cancel']:
            voice_cancel()
            return
        return                                       # 其它键忽略: 别把待确认结果弄丢
    # 中文标点 (cnpunct=1 时 hook 吞键): 组字中先上屏首候选再上屏标点
    if (vk in (0xBC, 0xBE, 0xBA, 0xBF, 0xDC, 0xDB, 0xDD, 0xDE, 0xC0)
            or (sh and vk in (0xBD, 0xBB))
            or (sh and 0x30 <= vk <= 0x39)):
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


# ---------- 可选依赖自检 / 安装 (第八十二轮) ----------
# 宿主核心**零依赖**(单文件自带 pystray/pypdf): 缺的只是"某一项功能", 所以:
#   · 首启只问一次(默认「否」), 答案落 DATA_DIR\deps-state.txt; 想重跑走启动编码 `deps` / `yilai`;
#   · 装到 DATA_DIR\site\pip (`pip install --target`) + 挂 sys.path —— 不污染用户 Python、
#     绕开 Store Python 虚拟化、"卸载"就是删目录 (三条硬规矩全文见 deps.py 开头);
#   · 探测/安装都在后台线程, 异常只记日志+气泡 —— 绝不拖累打字 (AGENTS §40⑤)。
def _deps_probe():
    import deps as depmod
    return depmod.probe(DATA_DIR)


def _deps_install(pkgs, log, done=None):
    """后台装依赖 (依赖窗口的「安装所选」触发); 逐行回显 + 结果气泡 + 回主线程刷新状态。"""
    import deps as depmod

    def work():
        try:
            res = depmod.install(pkgs, DATA_DIR, on_line=log)
        except Exception as ex:                       # install 本身不抛, 这里只是最后一道兜底
            res = {'ok': False, 'error': '%r' % (ex,)}
        if res.get('ok'):
            depmod.note_installed(DATA_DIR, pkgs)
            log('[OK] 装好了: %s' % ', '.join(pkgs))
            log('     位置: %s' % res.get('target'))
            _dfn_always('deps: installed %s -> %s' % (','.join(pkgs), res.get('target')))
            _notify('依赖安装完成', '已装 %s；新功能可能要重启 WgIme 后生效' % ', '.join(pkgs))
        else:
            err = res.get('error') or ('pip 返回码 %s' % res.get('code'))
            log('[失败] %s' % err)
            _dfn_always('deps: install failed %s -> %s' % (','.join(pkgs), err))
            _notify('依赖安装失败', err)
        if done:
            try:
                done()
            except Exception:
                pass

    threading.Thread(target=work, daemon=True).start()


def _deps_open_window(items=None):
    """打开依赖自检窗口 (启动编码 `deps`/`yilai`, 或首启确认框里选「是」)。"""
    try:
        import deps as depmod
        items = items if items is not None else depmod.probe(DATA_DIR)
        tools.show_depcheck(items, DATA_DIR, _deps_install, _deps_probe)
    except Exception as ex:
        _dfn('deps window err %r' % (ex,))
        _notify('依赖自检', '打不开窗口: %r' % (ex,))


def _deps_prompt(items):
    """首启确认 (主线程调用): 默认「否」; 无论装还是跳过都记一笔, 之后不再打扰。"""
    from tkinter import messagebox as _mb
    import deps as depmod
    miss = [i for i in items if i.get('missing')]
    can = [i for i in miss if i.get('inst')]
    mark = {'result': 'error'}
    try:
        rep = depmod.text_report(items)
        if can:
            ok = _mb.askyesno('WgIme 依赖自检',
                              '首次启动自检：发现 %d 项可选依赖缺失。\n\n%s\n\n'
                              '这些都不影响输入法本身，只影响上面的对应功能。\n'
                              '是否现在打开安装窗口？\n（装到 %s，不污染系统 Python）'
                              % (len(miss), rep, depmod.site_dir(DATA_DIR)),
                              default=_mb.NO)
            mark = {'result': 'opened'} if ok else {'result': 'declined'}
            if ok:
                _deps_open_window(items)
        else:
            _mb.showinfo('WgIme 依赖自检',
                         '发现 %d 项可选依赖缺失（体积大，需手工安装）：\n\n%s\n\n'
                         '不影响输入法本身；装法见 AGENTS-DETAIL §D8.2。' % (len(miss), rep))
            mark = {'result': 'reported'}
    except Exception as ex:
        _dfn('deps prompt err %r' % (ex,))
    try:
        depmod.mark_asked(DATA_DIR, **mark)
    except Exception:
        pass


def _deferred_depcheck():
    """首启可选依赖自检 (2s 档, 排在 poll/托盘/tools 之后; 只问一次)。"""
    try:
        import deps as depmod
        if not depmod.should_ask(DATA_DIR):
            return
    except Exception as ex:
        _dfn('deps: state read err %r' % (ex,))
        return

    def work():
        try:
            items = depmod.probe(DATA_DIR)
        except Exception as ex:
            _dfn('deps: probe err %r' % (ex,))
            return
        miss = [i for i in items if i.get('missing')]
        _dfn_always('deps: first-run check, missing=%s'
                    % (','.join(i['key'] for i in miss) or '(none)'))
        if not miss:
            depmod.mark_asked(DATA_DIR, result='all-present')
            return
        try:
            root.after(0, lambda: _deps_prompt(items))
        except Exception:
            pass

    _bg_plugin(work)                                  # §40⑤: 后台异常有统一出口


# ---------- 主循环: 轮询钩子事件 ----------
# 第四十轮: 下面三段"启动收尾"从主循环**之前**挪到主循环**之后**, 且按 30/150/600ms 分三档错开 ——
#   ① 它们加起来实测 ~500ms (reload_plugins+load_py_plugins+load_appmodes ≈55ms、托盘 import ≈300ms、
#      tools 懒装载 ≈150ms), 原来一律排在 `root.after(8, poll)` 前面, 而钩子早就在收键排队了:
#      多等这 500ms 就是"启动后打字多 500ms 才上屏"(用户第三十八轮报的 1-3 秒延迟里就有这一段)。
#   ② 现在 poll 先跑 (8ms 就把排队的键全部上屏), 收尾工作在主循环里做; 错开三档是为了让
#      刚开始打字的那几秒尽量不被一次 500ms 的长回调堵住(每档自己都很短)。
#   打字本身不依赖这三段(只有"启动器候选/工具箱/插件管理/托盘菜单"要, 那也得用户先敲出 code 来)。
def _deferred_plugins():
    """plugins/*.txt + tools.txt + plugins/*.py + pastemode.txt (~55ms)."""
    try:
        reload_plugins()
        load_py_plugins()
        load_appmodes()
    except Exception as e:
        _dfn('deferred plugins err %r' % e)


def _tray_selfcheck(tries=0):
    """托盘图标自检 (第四十一轮): 个别机器"双击启动后哪里都看不到托盘图标"(控制台跑却正常) —— pystray
    不检查 Shell_NotifyIcon 的返回值, 而 pythonw 下 `sys.stderr is None`, 它的报错连显示的地方都没有。

    判定用**可靠信号**: ① pystray 实际发 NIM_ADD 的返回值 (tray.NIM['add_ok'], True=shell 收下了);
    ② Windows 11 按 exe 记的显示/隐藏设置 (`win.tray_promoted`)。Shell_NotifyIconGetRect 只当参考 ——
    实测 NIM_ADD=True 时它也可能回 E_FAIL, 拿它单独判"没登记"会误报。

    结论写 debug.log; 真出问题就**从别的线程**弹消息框/气泡 (主线程弹会卡住 poll=打字停摆)。
    """
    try:
        import tray as _t
    except Exception as e:
        _dfn('tray selfcheck: import tray err %r' % e)
        return
    add_ok = _t.NIM.get('add_ok')
    if add_ok is None and tries < 3:
        root.after(1500, lambda: _tray_selfcheck(tries + 1))     # pystray 线程还没走到 NIM_ADD
        return
    icon = getattr(TRAY, 'icon', None) if TRAY is not None else None
    hwnd = getattr(icon, '_hwnd', 0) if icon is not None else 0
    state, rect = ('visible', None)
    if icon is None:
        state = 'missing'
    elif hwnd:
        try:
            state, rect = TRAY.selfcheck()
        except Exception:
            state = 'unknown'
    promoted = win.tray_promoted()
    exe = sys.executable or ''
    console = 'yes' if sys.stdout is not None else 'no(pythonw)'
    plog = ' || '.join(_t.LOGS[-3:])[:300] or '-'
    _dfn_always('tray selfcheck: nim_add=%s(count=%s) promoted=%s getrect=%s hwnd=%s exe=%s console=%s pystray=%s'
         % (add_ok, _t.NIM.get('add_count'), promoted, state, hwnd, exe, console, plog))
    if _tray_hint_shown[0]:
        return
    # ① shell 明确拒收 -> 真没图标
    if add_ok is False or (icon is None and TRAY is not None):
        _tray_hint_shown[0] = True
        detail = ((getattr(TRAY, 'last_error', '') if TRAY is not None else '')
                  or (getattr(_t, 'IMPORT_ERR', '') or '') or '(pystray 没报错)')
        msg = ('托盘图标没能创建。\n\n'
               '输入法本身仍在运行, 只是没有托盘菜单。\n\n'
               'NIM_ADD: %s\n'
               'python: %s\n控制台: %s\n'
               '原因: %s\npystray: %s\n'
               '日志: %s\\debug.log\n\n请把这段信息发给作者。'
               % (add_ok, exe, console, detail.strip()[-400:], plog, DATA_DIR))
        _dfn_always('tray selfcheck FAILED add_ok=%s err=%s' % (add_ok, detail[-300:]))
        try:
            threading.Thread(target=win.message_box, args=(msg, 'WgIme 托盘图标', 0x30), daemon=True).start()
        except Exception:
            pass
        return
    # ② 登记上了, 但被 Windows 收进 ^ 隐藏区 (新机器/新 exe 默认就是这样) -> 提示怎么弄出来
    if promoted is False and state != 'visible':
        _tray_hint_shown[0] = True
        _notify('托盘图标被 Windows 收进了隐藏区',
                '任务栏右下角点 ^ 就能看到它。想让它常驻:\n设置 → 个性化 → 任务栏 → 其他系统托盘图标 → 打开 %s'
                % (os.path.basename(exe) or 'python'))


_tray_hint_shown = [False]


def _deferred_tray():
    """托盘对象 + 图标线程 (`import tray` = pystray+PIL ≈300ms).

    第五十三轮: 如果启动早期已经 `_boot_tray()` 挂过图标了 (`_TRAY_BOOT`), 这里**不重复建**,
    只把完整 api/菜单补上并刷新一次图标 (真实模式可能不是启动时那个"混合")。
    """
    global TRAY
    if _TRAY_BOOT[0] and TRAY is not None:
        try:
            TRAY.api = _tray_api()
            TRAY.rebuild()
            TRAY._refresh()
        except Exception as e:
            _dfn('tray late init err %r' % e)
        ok = True
    else:
        _create_tray()
        ok = False
        try:
            if TRAY:
                ok = bool(TRAY.start())
        except Exception as e:
            _dfn('tray start err %r' % e)
    _dfn_always('tray start ok=%s has_tray=%s exe=%s err=%s'
         % (ok, _tray_has(), sys.executable, (getattr(TRAY, 'last_error', '') or '')[-300:]))
    if not ok:
        # 起不来就别等 1.2s 的自检了, 直接报 (自检也查不出东西)
        try:
            root.after(50, _tray_selfcheck)
        except Exception:
            _tray_selfcheck()
    else:
        root.after(1200, _tray_selfcheck)       # 起得来也复核一次: 在不在可见区
    if _DICTS_MISSING:                          # 空词库必须让用户看见 (pythonw 下没 stderr)
        try:
            if TRAY and getattr(TRAY, 'icon', None):
                TRAY.icon.notify('没有找到码表 py.txt: 词库目录 = %s\n'
                                 '输入法现在以"空词库"运行, 候选里不会有任何字词。'
                                 '请把 py.txt/wb.txt/ec.txt 放进该目录, 或用 WGIME_DICT_DIR 指定。' % DICT_DIR,
                                 'WgIme')
        except Exception:
            pass


def _tray_has():
    try:
        import tray as _t
        return _t.HAS_TRAY
    except Exception:
        return None


def _deferred_tools():
    """tools 模块懒装载 + 通知回调注册 (~150ms; 首次访问 tools 属性才触发 exec)."""
    try:
        tools.set_notifier(_notify)             # 工具步骤 msg / 工具结果走托盘气泡
    except Exception as e:
        _dfn('deferred tools err %r' % e)


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
        # 语音: VAD 自动停 / 识别结果 (后台线程入队, 此处主线程执行) —— 第四十七轮
        try:
            _voice_drain()
        except Exception:
            pass
        try:
            _voice_tick()          # 录音中的 "(Ns)" 秒数要走 (第五十八轮; 见 _voice_tick)
        except Exception:
            pass
        # 状态提示点: 跟鼠标 + 按状态上色 (第六十九轮)。8ms poll 里每 4 拍做一次 (~32ms),
        # 一次 tick 只有一次 GetCursorPos; 颜色/位置没变时不碰窗口。
        try:
            _DOT_TICK[0] += 1
            if _DOT_TICK[0] % 4 == 0:
                _dot_tick()
        except Exception:
            pass
        # 先排空托盘动作 (pystray 线程入队, 此处主线程执行)
        try:
            if TRAY is not None:               # 第五十一轮: 托盘没起来时 TRAY_Q 必然是空的,
                import tray as _traymod        # 别在这里 `import tray`(实测 ~128ms) 去抢
                for _ in range(8):             # _deferred_tray 刻意安排到 150ms 那档的装载时间 ——
                    try:                       # 它原来排在本函数的开头, 把"排队的键"压在后面处理。
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
        hook.COMPOSING[0] = bool(ime.buf or ime.assoc_showing or ime.sym_cat
                                 or _VOICE.get('text') is not None)   # 语音待确认结果也要让钩子吞空格/Esc/数字
                                                                     # (第五十一轮: 以前这一拍就把 COMPOSING
                                                                     #  重算成 False, 识别结果永远收不回来)
        try:
            if root.winfo_exists():
                root.after(8, poll)                # 键盘事件轮询间隔: 15→8ms, 降每键等待 (空转仅 queue 探测, 开销可忽略)
        except Exception:
            pass


try:                                     # 第八十二轮: 私有依赖目录挂 sys.path ——
    import deps as _depsmod              # 必须在下面 30ms 的插件装载**之前** (插件模块级可能 import 可选件)
    if _depsmod.ensure_site_on_path(DATA_DIR):
        _dfn('deps: private site on sys.path = %s' % _depsmod.site_dir(DATA_DIR))
except Exception as _e:
    _dfn('deps: site path err %r' % (_e,))
root.after(8, poll)
root.after(30, _deferred_plugins)        # 30ms  : plugins/tools.txt/pastemode (~55ms)
root.after(150, _deferred_tray)          # 150ms : 托盘对象 + 图标线程 (~300ms)
root.after(600, _deferred_tools)         # 600ms : tools 懒装载 + 通知回调 (~150ms)
root.after(2000, _deferred_depcheck)     # 2s    : 首启可选依赖自检 (第八十二轮; 只问一次)
if is_tray_mode():
    _dfn('runmode=tray (no keyboard hook)')
else:
    if _EARLY_HOOK_OK is None:               # 早期没装(配置读不到/异常): 这里补装
        _EARLY_HOOK_OK = bool(hook.start())
    if not _EARLY_HOOK_OK:                   # 钩子装不上: 对齐 C# 的"钩子失败"错误气泡 (不再静默)
        _notify('WgIme (Python) 已启动', '键盘钩子安装失败 (err %s), 输入法按键将不工作。' % hook.last_error())
    set_active(CFG['starton'])
    try:
        engine.warm_ec()      # 钩子已装好(= 能打字了), 这会儿在后台把词典表(ec/ek/ev/ce)读进来:
                              # 「译文」默认开着, 到用户打第一个英文/查译时基本已就绪, 别"空候选几秒"
    except Exception:
        pass
    try:
        if _caret_follow():       # 第六十八轮: 默认关(冻结) 就不起 helper; 打开时行为不变
            win.ensure_caret_bg()
    except Exception:
        pass
    if CFG.get('voice'):
        try:
            # 本地 whisper (voice_engine=whisper) 的常驻助手: 启动后台把模型载进来, 免得
            # 第一次说话要先白等十几秒 (第六十三轮)。非 whisper 引擎 / stt_prewarm=0 时是空操作。
            # 拖到 mainloop 之前这一段才 import voice: 只给"真的开了语音"的用户付这个代价。
            import voice as _vmod
            _vmod.prewarm_bg(CFG)
        except Exception as e:
            _dfn('voice: prewarm setup failed: %r' % (e,))
_dfn('startup: mainloop start (poll every 8ms; 从这里开始排队按键上屏)')
_dfn_always('startup: WgIme-Pure %s; showcode=%s trans=%s cn=%s shuangpin=%s starton=%s dict=%s'
            % (VERSION, CFG.get('showcode'), CFG.get('trans'), CFG.get('cnpunct'),
               CFG.get('shuangpin'), CFG.get('starton'), DICT_DIR))
root.mainloop()
