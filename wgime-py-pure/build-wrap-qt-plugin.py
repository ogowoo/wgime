# -*- coding: utf-8 -*-
r"""build-wrap-qt-plugin.py — 把「多文件源码合并成的单文件 Qt 程序」包成 **wgime 双模插件**（单文件）。

为什么需要它（详见 docs\WGIME_插件规范.md §8.9 与 AGENTS §5 规则 53）:
  Qt 单文件程序常在**模块级**就 `import PySide6.*`、还带模块级依赖自举(`ensure_deps()` + `SystemExit`),
  直接当 `plugins\*.py` 会被装载器在**输入法启动时** exec —— 拖慢启动、缺包时当场联网 pip 装、
  装不上插件还**静默消失**；Qt 与宿主的 Tk 也不能共用主线程事件循环。
  本脚本把整个程序体**缩进进一个函数** `_app_main()`: 模块体只剩「清单 + 几个小函数」,
  装载时零重依赖、零副作用; Qt 界面只在**被调用时**才构建。

生成物同时满足:
  · **插件**: `CODE/NAME/...` 清单 + `STANDALONE = True` + 可调用的 `run()` —— 它把**本文件自己**
    作为独立进程拉起(`pythonw` + `CREATE_NO_WINDOW`), 立刻返回, 不阻塞 Tk 主线程;
  · **独立运行**: `python <输出>.py` 就是原程序; `python <输出>.py --check-deps` 只报依赖不出界面。

用法:
    python build-wrap-qt-plugin.py <原始单文件.py> <输出插件.py> [CODE] [NAME] [DESC]
例:
    python wgime-py-pure\build-wrap-qt-plugin.py "C:\Explorer\pyshot\PyShot.py" wgime-py-pure\plugins\PyShot.py pyshot 截图标注

⚠ 输出名别与输入同名(Windows 大小写不敏感); 也别把包装写成与载荷只差大小写的另一个名字 ——
   第八十九轮真踩过(写 `pyshot.py` 覆盖了用户的 `PyShot.py`), 见 AGENTS §5 规则 53。
"""
import ast
import os
import sys
import textwrap

HEADER = '''# -*- coding: utf-8 -*-
r"""{name} —— wgime 双模插件（由 `build-wrap-qt-plugin.py` 从原始单文件**整体包进** `_app_main()` 而来）。

本文件 = 原程序 + 薄包装。**为什么不能直接当普通插件**（三个硬约束）:
  ① PySide6 是巨型 C 扩展, 内嵌不进 wgime 的单文件发行版（规范 §12）;
  ② 原程序在**模块级**就 `import PySide6.*`, 还有模块级依赖自举（缺包自己 pip 装、装不上 `SystemExit`）
     —— 被装载器在**输入法启动时** exec 的话: 拖慢启动、可能当场联网装包、缺依赖时插件静默消失;
  ③ Qt 与宿主的 Tk **不能共用主线程事件循环** ⇒ 界面必须在**独立进程**里跑。
所以模块级只留「清单 / 查询 / 拉起自己」三件事, `_app_main()` 只在被调用时才构建 Qt 界面。

**双模**: `STANDALONE = True`。`python 本文件.py` = 原程序本身(它的
`if __name__ == '__main__':` 块被整体缩进进了 `_app_main()`, 独立运行时 `__name__` 照样是
`'__main__'`, 所以入口**仍然只有一个**); 尾块只负责测试钩子与 `STANDALONE-OK` 标记。
`--check-deps` 只报依赖不出界面。

**重新生成**（原程序改了之后）:
    python wgime-py-pure\\build-wrap-qt-plugin.py <原始单文件.py> wgime-py-pure\\plugins\\PyShot.py {code} {name}
⚠ 别把本文件再复制成只差大小写的另一个名字(Windows 大小写不敏感, 会互相覆盖, 见 AGENTS §5 规则 53)。
"""
# ---- 双模式 (1/3): 独立运行时先把宿主目录(上级)插进 sys.path —— 必须在第一个宿主 import 之前 ----
if __name__ == '__main__':
    import os as _os, sys as _sys
    _sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))

import os
import subprocess
import sys

CODE = {code!r}
NAME = {name!r}
DESC = {desc!r}
VERSION = '1.0'
AUTHOR = 'ogowoo'
PERM = 'low'                       # 只把「跟插件一起分发的自家程序」拉起来; 程序自身权限另算(规范 §16)
STANDALONE = True                  # 双模式 (2/3) 标记: 插件管理器据此显示"双模"

SELF = os.path.abspath(__file__)
CREATE_NO_WINDOW = 0x08000000
PAYLOAD_VERSION = {ver!r}          # 打包时从原程序里抠的版本(便于 `app_version()` 兜底)


def app_version():
    """原程序版本: 先扫文件里的 `APP_VERSION = `, 扫不到用打包时抠的那个。**不 import 原程序**。"""
    try:
        with open(SELF, encoding='utf-8', errors='replace') as f:
            for _ in range(2000):
                ln = f.readline()
                if not ln:
                    break
                s = ln.strip()
                if s.startswith('APP_VERSION'):
                    return s.split('=', 1)[1].strip().strip('"\\'')
    except OSError:
        pass
    return PAYLOAD_VERSION


def private_site_dirs():
    """wgime 的私有依赖目录(依赖自检把包装在这儿) —— 子进程要能看见它们。"""
    la = os.environ.get('LOCALAPPDATA') or ''
    bases = ([os.path.join(la, 'wgime-py')] if la else []) + [os.path.join(os.path.expanduser('~'), 'wgime-py')]
    out = []
    for b in bases:
        for sub in ('site', os.path.join('site', 'pip')):
            d = os.path.join(b, sub)
            if os.path.isdir(d) and d not in out:
                out.append(d)
    return out


def pyside_available():
    """给**子进程**看的判据: 本解释器里没有、但 wgime 私有目录里有, 也算有。"""
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
    env = dict(os.environ)
    extra = private_site_dirs()
    if extra:
        old = env.get('PYTHONPATH') or ''
        env['PYTHONPATH'] = os.pathsep.join(extra + ([old] if old else []))
    if skip_deps:                   # 自动化: 别让原程序自己联网装包/弹模态框
        env['PYSHOT_SKIP_DEPS'] = '1'
        env['PYSHOT_NO_ALERT'] = '1'
    return env


def spawn_argv(extra_args=None):
    """子进程命令行 = **本文件自己**(优先 pythonw, 不弹黑框)。"""
    exe = sys.executable or 'python'
    cand = os.path.join(os.path.dirname(exe), 'pythonw.exe')
    if os.path.exists(cand):
        exe = cand
    return [exe, '-X', 'utf8', SELF] + list(extra_args or [])


def spawn(extra_args=None, popen=None, skip_deps=False):
    """把本文件作为独立进程拉起(不等待)。返回 pid; 失败抛 RuntimeError。"""
    if not os.path.isfile(SELF):
        raise RuntimeError('自己不见了: %s' % SELF)
    runner = popen or subprocess.Popen
    flags = CREATE_NO_WINDOW if sys.platform == 'win32' else 0
    p = runner(spawn_argv(extra_args), env=child_env(skip_deps=skip_deps), cwd=os.path.dirname(SELF),
               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
               close_fds=True, creationflags=flags)
    return getattr(p, 'pid', 0)


def missing_hint():
    """缺 PySide6 时给人话(**不自动装** —— 200MB 的东西不该悄悄装)。"""
    return ('%s 需要 PySide6(约 200MB)。\\n'
            '装法: 打启动编码 `deps` 打开依赖自检 → 勾选 PySide6 → 安装所选;'
            '或命令行 `pip install PySide6`。' % NAME)


def _tip(text):
    """走宿主的托盘气泡; 不在宿主里(独立跑/无 tools)就退回 stdout。"""
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
    """宿主入口(Tk 主线程里同步调, **必须立刻返回**): 把本文件作为独立进程拉起。

    被装载器 load 进来时 `__name__` 是 `wgime_ext_...`, 独立运行时是 `'__main__'` —— 两条路都只是
    「拉起自己」, 所以不需要区分(也不能复用 `_standalone.py` 那套 Tk 看守: 本程序不是 Tk 程序)。
    """
    if not pyside_available():
        _tip(missing_hint())
        return False
    try:
        spawn()
    except Exception as ex:
        _tip('启动失败: %r' % (ex,))
        return False
    v = app_version()
    _tip('已启动(托盘常驻) %s\\n截图/滚动截图走它的托盘菜单或默认热键。' % (('PyShot ' + v) if v else NAME))
    return True


def _app_main():
    """原程序体(由 build-wrap-qt-plugin.py 整体缩进进来)。**只在被调用时才有副作用**。"""
'''

TAIL = '''

# ---- 双模式 (3/3): 独立运行 = 直接跑原程序(原程序的 `__main__` 块就在 `_app_main()` 里) ----
if __name__ == '__main__':
    _auto = os.environ.get('WGIME_STANDALONE_AUTOEXIT_MS')      # 回归测试钩子: 不出界面
    if _auto:
        os.environ.setdefault('PYSHOT_SKIP_DEPS', '1')          # 别联网装包
        os.environ.setdefault('PYSHOT_NO_ALERT', '1')           # 别弹模态框
        if '--check-deps' not in sys.argv:
            sys.argv.append('--check-deps')                     # 只报依赖就退
    try:
        _app_main()
    except ImportError as _ex:                                  # 缺 PySide6: 自动化里当"跳过"而不是红
        if not _auto:
            raise
        print('STANDALONE-SKIP-DEPS %s' % _ex, flush=True)
    finally:
        if _auto:
            print('STANDALONE-OK', flush=True)
'''


def _first_version(text):
    for ln in text.split('\n')[:2000]:
        s = ln.strip()
        if s.startswith('APP_VERSION'):
            return s.split('=', 1)[1].strip().strip('"\'')
    return ''


def wrap(text, code, name, desc):
    """返回 (包装后的源码, 摘要 dict)。纯函数, 便于测试/复用。"""
    tree = ast.parse(text)
    globs = sorted({n for node in ast.walk(tree)
                    if isinstance(node, ast.Global) for n in node.names})
    ver = _first_version(text)
    head = HEADER.format(name=name, code=code, desc=desc, ver=ver)
    # `global` 序言: 原程序里那些 `global x` 指向的模块级缓存, 现在是 `_app_main` 的函数作用域 ——
    # 不声明的话 `_app_main` 的赋值会变成**局部名**, 与嵌套函数里的 `global x` 成了两个变量(缓存静默失效)。
    prologue = ('    global ' + ', '.join(globs) + '\n') if globs else ''
    out = head + prologue + textwrap.indent(text.rstrip('\n'), '    ') + TAIL
    return out.replace('\r\n', '\n'), {'globals': globs, 'version': ver}


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    src, out = argv[0], argv[1]
    code = argv[2] if len(argv) > 2 else 'pyshot'
    name = argv[3] if len(argv) > 3 else '截图标注'
    desc = argv[4] if len(argv) > 4 else None
    if os.path.normcase(os.path.abspath(src)) == os.path.normcase(os.path.abspath(out)):
        print('输入与输出不能是同一个文件(Windows 大小写不敏感)')
        return 2
    with open(src, encoding='utf-8') as f:
        text = f.read()
    if desc is None:
        v = _first_version(text)
        desc = '%s %s —— 截图/滚动截图/标注编辑/贴图(独立进程, 需 PySide6)' % (name, v or '')
    payload, info = wrap(text, code, name, desc)
    ast.parse(payload)                                  # 生成物必须能编译(缩进/引号错了当场炸)
    g2 = sorted({n for node in ast.walk(ast.parse(payload))
                 if isinstance(node, ast.Global) for n in node.names})
    assert g2 == info['globals'] or len(g2) >= len(info['globals']), (g2, info['globals'])
    with open(out, 'wb') as f:
        f.write(payload.encode('utf-8'))
    print('wrapped %s (%d B, %d 行) -> %s (%d B, %d 行)  code=%s  global=%s  ver=%s'
          % (os.path.basename(src), os.path.getsize(src), text.count('\n') + 1,
             out, os.path.getsize(out), payload.count('\n') + 1,
             code, ','.join(info['globals']) or '-', info['version'] or '-'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
