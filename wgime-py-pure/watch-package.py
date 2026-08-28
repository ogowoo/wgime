# -*- coding: utf-8 -*-
"""watch-package.py — 监视源文件变化, 自动重建单文件 + 刷新 package 目录.
轮询 (无依赖). 跑一次即常驻: python watch-package.py
"""
import glob
import os
import subprocess
import time

BASE = os.path.dirname(os.path.abspath(__file__))
SOURCES = [os.path.join(BASE, n) for n in
           ['win.py', 'hook.py', 'bar.py', 'wspy.py', 'engine.py', 'plugins.py',
            'ui.py', 'tools.py', 'tray.py', 'main.py', 'build-wgime-pure.py']]
SOURCES += sorted(glob.glob(os.path.join(BASE, 'plugins', '*.py')))

_last = {}


def _mtimes():
    out = {}
    for f in SOURCES:
        try:
            out[f] = os.path.getmtime(f)
        except OSError:
            pass
    return out


def main():
    global _last
    _last = _mtimes()
    print('watching %d source files (Ctrl+C 退出)...' % len(SOURCES))
    while True:
        time.sleep(2)
        now = _mtimes()
        if now != _last:
            _last = now
            print('[%s] 变化, 重建...' % time.strftime('%H:%M:%S'))
            try:
                subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                '-File', os.path.join(BASE, 'build-package.ps1')], check=False)
                print('[%s] 已重建+刷包' % time.strftime('%H:%M:%S'))
            except Exception as ex:
                print('rebuild err: %s' % ex)


if __name__ == '__main__':
    main()
