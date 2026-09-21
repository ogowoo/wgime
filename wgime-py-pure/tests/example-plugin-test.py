# -*- coding: utf-8 -*-
r"""示例插件模板回归 (第八十一轮).

`plugins\_example-plugin.py` 是「普通单文件 Python 应用 → wgime 插件」的**可跑模板**(规范 §8.8)。
它文件名以 `_` 开头, 所以 `main.load_py_plugins()` **不会**把它当插件装载 —— 本测试既钉住这条约定
(文件命名 + 宿主实现两头都查), 又验证模板本身真的能用:

  1. 文件卫生: 存在 / LF(无 CRLF) / UTF-8 无 BOM
  2. 双模式三块齐(文件头 sys.path 在第一个宿主 import 之前 / STANDALONE / 文件尾共享引导层)
  3. 清单六键齐(CODE/NAME/DESC/VERSION/AUTHOR/PERM)
  4. 装载契约: 按 load_py_plugins 同一套判据装载 —— CODE 非空 + run 可调用 + STANDALONE 真
  5. `_` 前缀不被装载: 用宿主**同一谓词**遍历 plugins/ (模板被排除、pdf.py 被包含), 并断言宿主源码
     里确实写着这条谓词 —— 不靠"我记得是这样"
  6. run() 真建出窗口(有桌面才跑, 否则 SKIP)
  7. 独立运行: 子进程 + WGIME_STANDALONE_AUTOEXIT_MS, 断言 STANDALONE-OK + rc 0
  8. 文档一致性: 规范 §8.8 存在、指向本模板、写明了 .py/.txt 插件目录差异

跑法: python wgime-py-pure\tests\example-plugin-test.py
"""
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
PLUG = os.path.join(PURE, 'plugins')
EX = os.path.join(PLUG, '_example-plugin.py')
MAIN = os.path.join(PURE, 'main.py')
SPEC = os.path.join(os.path.dirname(PURE), 'docs', 'WGIME_插件规范.md')

fails = []
n = [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-56s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


def has_desktop():
    try:
        import tkinter as tk
        r = tk.Tk()
        r.destroy()
        return True
    except Exception:
        return False


def main():
    print('example = %s' % EX)
    check('模板文件存在', os.path.isfile(EX))
    if not os.path.isfile(EX):
        return 1
    raw = open(EX, 'rb').read()
    txt = raw.decode('utf-8')

    check('行尾 LF (0 个 CRLF)', raw.count(b'\r\n') == 0, 'CRLF=%d' % raw.count(b'\r\n'))
    check('UTF-8 无 BOM', not raw.startswith(b'\xef\xbb\xbf'))

    # ---- 双模式三块 ----
    head = txt.find("if __name__ == '__main__':")
    hosts = [i for i in (txt.find('\nimport ui'), txt.find('\nimport tkinter')) if i >= 0]
    first_host = min(hosts) if hosts else -1
    check('文件头在第一个宿主 import 之前', 0 <= head < first_host, 'head=%d host=%d' % (head, first_host))
    check('文件头补 sys.path', 'sys.path.insert' in txt[:first_host + 1])
    check('STANDALONE = True 标记', re.search(r'(?m)^STANDALONE\s*=\s*True\b', txt) is not None)
    check('文件尾走共享引导层', '_standalone.standalone(run, NAME)' in txt)

    # ---- 清单 ----
    for k in ('CODE', 'NAME', 'DESC', 'VERSION', 'AUTHOR', 'PERM'):
        check('清单键 %s' % k, re.search(r'(?m)^%s\s*=\s*\S' % k, txt) is not None)

    # ---- 装载契约 (与 load_py_plugins 同一套判据) ----
    if PURE not in sys.path:
        sys.path.insert(0, PURE)
    spec = importlib.util.spec_from_file_location('wg_ext_example_under_test', EX)
    mod = importlib.util.module_from_spec(spec)
    sys.modules['wg_ext_example_under_test'] = mod
    spec.loader.exec_module(mod)
    check('CODE 非空且为 str', isinstance(getattr(mod, 'CODE', None), str) and bool(mod.CODE),
          repr(getattr(mod, 'CODE', None)))
    check('run() 可调用', callable(getattr(mod, 'run', None)))
    check('STANDALONE 为真 (双模)', getattr(mod, 'STANDALONE', None) is True)

    # ---- `_` 前缀 = 不被装载: 命名约定 + 宿主实现两头都查 ----
    allpy = sorted(f for f in os.listdir(PLUG) if f.lower().endswith('.py'))
    loaded = [f for f in allpy if not f.startswith('_')]          # 宿主谓词的等价复现
    check('模板被宿主谓词排除', os.path.basename(EX) not in loaded)
    check('真插件仍被包含 (pdf.py)', 'pdf.py' in loaded)
    msrc = open(MAIN, 'rb').read().decode('utf-8')
    check("宿主源码确有该谓词 fn.startswith('_')", "fn.startswith('_')" in msrc)

    # ---- run() 真建窗 + 独立运行 (要桌面) ----
    if not has_desktop():
        print('  SKIP: 没有可用桌面/Tk —— run() 建窗与独立运行两项跳过')
    else:
        import tkinter as tk
        root = tk.Tk()
        root.withdraw()
        try:
            win = mod.run()
            win.update_idletasks()
            ww = max(win.winfo_width(), win.winfo_reqwidth())
            check('run() 真建出窗口', win.winfo_exists() and ww >= 300, 'w=%s' % ww)
            win.destroy()
        except Exception as ex:
            check('run() 真建出窗口', False, repr(ex))
        finally:
            root.destroy()

        tmp = tempfile.mkdtemp(prefix='wg-example-')
        try:
            env = dict(os.environ)
            env['WGIME_STANDALONE_AUTOEXIT_MS'] = '2500'    # 测试钩子: 窗口自己关
            env['LOCALAPPDATA'] = tmp                       # 数据目录隔离, 绝不碰用户数据
            env['PYTHONIOENCODING'] = 'utf-8'
            try:
                r = subprocess.run([sys.executable, '-X', 'utf8', EX],
                                   capture_output=True, timeout=45, env=env)
                out = (r.stdout or b'').decode('utf-8', 'replace')
                err = (r.stderr or b'').decode('utf-8', 'replace')
                check('独立运行: STANDALONE-OK + rc 0',
                      r.returncode == 0 and 'STANDALONE-OK' in out,
                      'rc=%s out=%r err=%r' % (r.returncode, out[-100:], err[-200:]))
            except subprocess.TimeoutExpired:
                check('独立运行: STANDALONE-OK + rc 0', False, 'timeout (窗口没自己关?)')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    # ---- 文档一致性 ----
    doc = rd(SPEC) if os.path.isfile(SPEC) else ''
    check('规范有 §8.8', '### 8.8' in doc)
    check('§8.8 指向本模板文件', '_example-plugin.py' in doc)
    check('§8.8 写明 .py/.txt 目录差异',
          'load_py_plugins' in doc and 'reload_plugins' in doc and 'APP_DIR\\plugins' in doc)

    print('')
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        return 1
    print('全部通过 (%d 项)' % n[0])
    return 0


def rd(path):
    return open(path, 'rb').read().decode('utf-8')


if __name__ == '__main__':
    sys.exit(main())
