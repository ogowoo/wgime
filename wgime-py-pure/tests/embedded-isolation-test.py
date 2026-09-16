# -*- coding: utf-8 -*-
"""内嵌第三方"自足性"回归 (第六十九轮, 用户机真 bug).

**背景**: 单文件里的第三方源码是从构建机**已安装的包**读出来内嵌的。但运行时的 import 会
**回退到宿主 site-packages** —— 于是"构建机恰好装了某个依赖"就会掩盖"内嵌漏了它"。
现实案例: pystray 的 `_base.py`/`_win32.py` 需要 `six`(`from six.moves import queue`),
而我们当时只嵌了 pystray 自己 -> 干净机器(官方 Python 3.14, 没装 six)上 `import pystray`
直接 ImportError -> **整个托盘消失**(用户截图: "托盘图标没能创建", NIM_ADD=None, 原因
`No module named 'six'`)。

**判据**: 把 dist 单文件里的 `THIRD_ZIP_B64` 解出来, 用 `python -S -E`(不加载 site-packages、
不读 PYTHON* 环境变量)起一个**干净解释器**, 只把这个 zip 挂到 sys.path, 把 zip 里每个顶层
名字 import 一遍。任何失败 = 干净机器上必崩, 测试失败。

跑法: python wgime-py-pure\tests\embedded-isolation-test.py
      (可选 `--dist <路径>`, 默认 wgime-py-pure\dist\wgime-py.py)
"""
import argparse
import base64
import io
import os
import re
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
DEFAULT_DIST = os.path.join(PURE, 'dist', 'wgime-py.py')

fails = []
n = [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-52s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dist', default=DEFAULT_DIST)
    args = ap.parse_args()
    dist = args.dist
    print('dist = %s' % dist)
    check('dist 存在', os.path.exists(dist), dist)
    if not os.path.exists(dist):
        return 1

    txt = io.open(dist, encoding='utf-8', errors='replace').read()
    m = re.search(r"THIRD_ZIP_B64 = '(.*?)'\n", txt, re.S) or re.search(r'THIRD_ZIP_B64 = "(.*?)"\n', txt, re.S)
    check('单文件里有 THIRD_ZIP_B64', m is not None)
    if not m:
        return 1
    blob = base64.b64decode(m.group(1))
    z = zipfile.ZipFile(io.BytesIO(blob))
    tops = sorted({nm.split('/')[0].replace('.py', '') for nm in z.namelist()})
    print('  内嵌顶层条目: %s (%.1f KB)' % (tops, len(blob) / 1024.0))
    check("内嵌里有 'six' (pystray 的硬依赖, 第六十九轮那个 bug)", 'six' in tops, repr(tops))
    check("内嵌里有 'pystray'", 'pystray' in tops, repr(tops))

    # 干净环境: -S 不加载 site-packages, -E 忽略 PYTHON* 环境变量
    import tempfile
    tmp = tempfile.mkdtemp(prefix='wg-embed-iso-')
    zp = os.path.join(tmp, 'thirdparty.zip')
    try:
        with open(zp, 'wb') as f:
            f.write(blob)
        for name in tops:
            code = ('import sys; sys.path.insert(0, %r)\n'
                    'import %s\n'
                    'print("OK")' % (zp, name))
            r = subprocess.run([sys.executable, '-S', '-E', '-c', code],
                               capture_output=True, encoding='utf-8', errors='replace')
            ok = r.returncode == 0 and 'OK' in (r.stdout or '')
            check('干净环境 import %s' % name, ok, ((r.stderr or '') + (r.stdout or '')).strip()[-300:])
        # 关键组合: pystray 自己会去 import six (six.moves.queue)
        code = ('import sys; sys.path.insert(0, %r)\n'
                'import pystray\n'
                'from six.moves import queue\n'
                'print("COMBO-OK")' % zp)
        r = subprocess.run([sys.executable, '-S', '-E', '-c', code],
                           capture_output=True, encoding='utf-8', errors='replace')
        check('干净环境 pystray + six.moves.queue (真 bug 的形状)',
              r.returncode == 0 and 'COMBO-OK' in (r.stdout or ''),
              ((r.stderr or '') + (r.stdout or '')).strip()[-400:])
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

    print('')
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        return 1
    print('全部通过 (%d 项)' % n[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
