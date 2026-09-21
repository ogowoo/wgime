# -*- coding: utf-8 -*-
r"""双模式插件回归 (第七十九轮): plugins/*.py 必须**既能被宿主装载, 也能 `python xxx.py` 独立运行**.

机制 (plugins/_standalone.py): 插件**文件头**一段 `if __name__ == '__main__':` 先把宿主目录(上级)
插进 sys.path —— 因为 `import ui` 等宿主模块在模块级, 不先修 sys.path 独立跑直接 ImportError;
**文件尾**一段 `if __name__ == '__main__': import _standalone; _standalone.standalone(run, NAME)`
建隐藏 Tk root -> run() 建窗 -> mainloop, 窗口关了自动退出。清单里 `STANDALONE = True` 是识别标记
(插件管理器据此显示"双模")。宿主装载时 `__name__` 是合成模块名, 三块都不执行。

本测试**真把每个插件当独立程序跑**: 子进程 + `WGIME_STANDALONE_AUTOEXIT_MS=2500` 让窗口自己关,
断言子进程打印 `STANDALONE-OK` 且退出码 0。没桌面(起不了 Tk)就整体 SKIP。子进程里把
`LOCALAPPDATA` 指到临时目录 (跟 harness 一样, 绝不碰用户数据)。

跑法: python wgime-py-pure\tests\standalone-plugin-test.py
"""
import os
import subprocess
import sys
import tempfile
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
PLUG = os.path.join(PURE, 'plugins')

fails = []
n = [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-52s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


def main():
    print('plugins = %s' % PLUG)
    plugins = sorted(f for f in os.listdir(PLUG)
                     if f.endswith('.py') and not f.startswith('_'))
    print('双模式候选: %s' % ', '.join(plugins))

    # 没桌面就跑不了 Tk —— 先探一下, 起不了就整体 SKIP (跟 dot-mouse-test 一个规矩)
    try:
        import tkinter as tk
        r = tk.Tk()
        r.destroy()
    except Exception as ex:
        print('SKIP: 没有可用桌面/Tk (%r)' % (ex,))
        return 0

    tmp = tempfile.mkdtemp(prefix='wg-standalone-')
    try:
        for fn in plugins:
            path = os.path.join(PLUG, fn)
            env = dict(os.environ)
            env['WGIME_STANDALONE_AUTOEXIT_MS'] = '2500'   # 测试钩子: 窗口自己关
            env['LOCALAPPDATA'] = tmp                       # 数据目录隔离 (绝不碰用户数据)
            env['PYTHONIOENCODING'] = 'utf-8'
            try:
                r = subprocess.run([sys.executable, '-X', 'utf8', path],
                                   capture_output=True, timeout=45, env=env)
                out = (r.stdout or b'').decode('utf-8', 'replace')
                err = (r.stderr or b'').decode('utf-8', 'replace')
                ok = r.returncode == 0 and 'STANDALONE-OK' in out
                check('%s 独立运行' % fn, ok,
                      'rc=%s out=%r err=%r' % (r.returncode, out[-120:], err[-200:]))
            except subprocess.TimeoutExpired:
                check('%s 独立运行' % fn, False, 'timeout (窗口没在 2.5s 后自己关?)')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print('')
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        return 1
    print('全部通过 (%d 项)' % n[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
