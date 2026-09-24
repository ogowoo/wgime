# -*- coding: utf-8 -*-
"""pyshot.py — 把单文件的 PyShot（Qt 截图/标注工具）接成 wgime 插件（第八十九轮）。

**为什么是「薄包装 + 下划线载荷」，而不是直接把它当插件**：
  ① PyShot 是 **PySide6(Qt)** 程序 —— PySide6 是巨型 C 扩展，**内嵌不进**单文件发行版（§12）；
  ② 它的**模块级**就有 `import PySide6.*` 和一句依赖自举 `if not ensure_deps(): raise SystemExit(1)`
     （缺依赖会自己 pip 装、装不上直接退出）—— 直接放 `plugins\\` 当插件，会被装载器在**输入法启动时**
     exec：拖慢启动，而且缺 PySide6 时整个插件**静默消失**（§8.8 陷阱①）；
  ③ Qt 与宿主的 Tk **不能共用主线程事件循环** ⇒ 必须独立进程（照 `wgpet.py` 的 detached 子进程套路）。
所以：载荷放 `_pyshot_app.py`（**`_` 开头 = 装载器跳过**，§D29/§8.8），本文件只做三件事 ——
声明清单 / 检查 PySide6 / 把它拉进独立进程。

独立运行：`python pyshot.py`（= 直接跑载荷）；`python pyshot.py --check-deps` 只报依赖、不出界面。
若用 wgime 的依赖自检（启动编码 `deps`）装过 PySide6，它落在 `%LOCALAPPDATA%\\wgime-py\\site\\pip`，
本文件会把这个目录塞进子进程的 `PYTHONPATH`，所以子进程也看得见。

⚠ **别再把本文件写成 `PyShot.py`**：Windows 文件名大小写不敏感，那样会**覆盖**载荷（载荷现在的名字
`_pyshot_app.py` 就是为了避开这一点；`tests\\pyshot-plugin-test.py` 有一条断言守着两文件共存且大小悬殊）。
"""
# ---- 双模式 (1/3): 独立运行时先把宿主目录(上级)插进 sys.path —— 必须在第一个宿主 import 之前 ----
if __name__ == '__main__':
    import os as _os, sys as _sys
    _sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))

import os
import subprocess
import sys

CODE = 'pyshot'
NAME = '截图标注'
DESC = 'PyShot —— 截图/滚动截图/标注编辑/贴图（独立进程，需 PySide6）'
VERSION = '1.0'
AUTHOR = 'ogowoo'
PERM = 'low'                       # 只拉起跟插件一起分发的自家工具(同 wgpet); 工具自身权限另算
STANDALONE = True                  # 双模式 (2/3) 标记

HERE = os.path.dirname(os.path.abspath(__file__))
PAYLOAD = os.path.join(HERE, '_pyshot_app.py')       # 下划线开头: 装载器不当它是插件
CREATE_NO_WINDOW = 0x08000000


def payload_version():
    """从载荷里抠 `APP_VERSION` —— **不 import 它**（一 import 就会自装依赖/起 Qt）。"""
    try:
        with open(PAYLOAD, encoding='utf-8', errors='replace') as f:
            for _ in range(1500):                    # 版本号在文件中部, 扫前 1500 行足够
                ln = f.readline()
                if not ln:
                    break
                s = ln.strip()
                if s.startswith('APP_VERSION'):
                    return s.split('=', 1)[1].strip().strip('"\'')
    except OSError:
        pass
    return ''


def private_site_dirs():
    """wgime 的私有依赖目录（依赖自检把包装在这儿）—— 子进程要能看见它。"""
    la = os.environ.get('LOCALAPPDATA') or ''
    bases = ([os.path.join(la, 'wgime-py')] if la else []) + [os.path.join(os.path.expanduser('~'), 'wgime-py')]
    out = []
    for b in bases:
        d = os.path.join(b, 'site')
        if os.path.isdir(d) and d not in out:
            out.append(d)
        d = os.path.join(b, 'site', 'pip')
        if os.path.isdir(d) and d not in out:
            out.append(d)
    return out


def pyside_available():
    """给**子进程**看的判据: 宿主解释器里没有、但私有目录里有, 也算有。"""
    import importlib.util
    try:
        if importlib.util.find_spec('PySide6') is not None:
            return True
    except Exception:
        pass
    for d in private_site_dirs():
        if os.path.isdir(os.path.join(d, 'PySide6')):
            return True
    return False


def child_env(skip_deps=False):
    """子进程环境: 把私有依赖目录挂进 `PYTHONPATH`（携带原有值）。"""
    env = dict(os.environ)
    extra = private_site_dirs()
    if extra:
        old = env.get('PYTHONPATH') or ''
        env['PYTHONPATH'] = os.pathsep.join(extra + ([old] if old else []))
    if skip_deps:                       # 自动化场景: 别让载荷自己去 pip 装/弹模态框(它自带这两个开关)
        env['PYSHOT_SKIP_DEPS'] = '1'
        env['PYSHOT_NO_ALERT'] = '1'
    return env


def spawn_argv(extra_args=None):
    """子进程命令行（优先 `pythonw.exe`，不弹黑框）。"""
    exe = sys.executable or 'python'
    cand = os.path.join(os.path.dirname(exe), 'pythonw.exe')
    if os.path.exists(cand):
        exe = cand
    return [exe, '-X', 'utf8', PAYLOAD] + list(extra_args or [])


def spawn(extra_args=None, popen=None, skip_deps=False):
    """拉起 PyShot 独立进程（不等待）。返回 pid；失败抛 RuntimeError（带人话）。"""
    if not os.path.isfile(PAYLOAD):
        raise RuntimeError('载荷不见了: %s' % PAYLOAD)
    runner = popen or subprocess.Popen
    flags = CREATE_NO_WINDOW if sys.platform == 'win32' else 0
    p = runner(spawn_argv(extra_args), env=child_env(skip_deps=skip_deps), cwd=HERE,
               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
               close_fds=True, creationflags=flags)
    return getattr(p, 'pid', 0)


def missing_hint():
    """缺 PySide6 时给用户的话（**不自动装** —— 200MB 的东西不该悄悄装）。"""
    return ('%s 需要 PySide6（约 200MB）。\n'
            '装法: 打启动编码 `deps` 打开依赖自检 → 勾选 PySide6 → 安装所选；'
            '或命令行 `pip install PySide6`。' % NAME)


def _tip(text):
    """走宿主气泡（无托盘时 tools 会退回弹窗）；独立运行时没有宿主就打印。"""
    try:
        import tools as _tools
        _tools._tip(NAME + ' (' + CODE + ')', text)
        return
    except Exception:
        pass
    try:
        print('[%s] %s' % (CODE, text), flush=True)
    except Exception:
        pass


def run():
    """宿主入口（Tk 主线程里同步调，**必须立刻返回**）：只负责把 Qt 进程拉起来。"""
    if not pyside_available():
        _tip(missing_hint())
        return False
    try:
        spawn()
    except Exception as ex:
        _tip('启动失败: %r' % (ex,))
        return False
    v = payload_version()
    _tip('已启动（托盘常驻）%s\n截图/滚动截图走它的托盘菜单或默认热键。'
         % (('PyShot ' + v) if v else 'PyShot'))
    return True


# ---- 双模式 (3/3): 独立运行 = 直接跑载荷（它自带 Qt 事件循环，用不上 _standalone 那套 Tk 看守） ----
if __name__ == '__main__':
    auto = os.environ.get('WGIME_STANDALONE_AUTOEXIT_MS')      # 回归测试钩子: 不真起界面
    if '--check-deps' in sys.argv or auto:
        rc = subprocess.call(spawn_argv(['--check-deps']), env=child_env(skip_deps=True))
        if rc == 0:
            print('STANDALONE-OK', flush=True)
        sys.exit(rc)
    sys.exit(subprocess.call(spawn_argv(sys.argv[1:]), env=child_env()))
