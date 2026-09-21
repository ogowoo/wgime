# -*- coding: utf-8 -*-
r"""可选依赖自检/安装回归 (第八十二轮, 纯逻辑, **不联网**).

`deps.py` 的两件危险事 —— 探测与安装 —— 都被设计成**可注入**：
`probe(finder=...)` 与 `install(runner=...)`。本测试全程用假的 finder/runner，所以
**不会装任何东西、不会碰网络、不会碰用户数据**（临时目录用完就删）。

钉住的规矩：
  1. 清单形态（key 唯一 / 必填字段 / 哪些可装、哪些只报告）
  2. 探测分类（present/missing、installable/report_only、人话清单）
  3. **装到私有目录**：`pip_argv` 必须是 `--target <DATA_DIR>/site/pip`，**不能出现 `--user`**
  4. install 的成功/失败/异常路径都从返回值出来（**绝不抛**），失败要翻译成人话
  5. 状态文件：首启只问一次；按 '\n' 切行后先 rstrip('\r')（AGENTS §39；否则值里带 \r 比较静默失效）
  6. `ensure_site_on_path` 幂等，且装了新包能被 `probe` 立刻发现（invalidate_caches）
  7. **单文件内嵌清单里有 `deps`** —— 防"加了模块忘了重建 dist"

跑法: python wgime-py-pure\tests\deps-test.py
"""
import importlib
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
DIST = os.path.join(PURE, 'dist', 'wgime-py.py')
sys.path.insert(0, PURE)

import deps                                     # noqa: E402

fails = []
n = [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-58s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


def make_runner(rc=0, lines=('Collecting x', 'Successfully installed x-1.0'), boom=None):
    seen = {}

    def runner(cmd, on_line, timeout):
        seen['cmd'] = cmd
        seen['timeout'] = timeout
        if boom is not None:
            raise boom
        for ln in lines:
            if on_line:
                on_line(ln)
        return rc, '\n'.join(lines)

    return runner, seen


def has_desktop():
    try:
        import tkinter as tk
        r = tk.Tk()
        r.destroy()
        return True
    except Exception:
        return False


def _descendants(wid):
    out = []
    try:
        kids = wid.winfo_children()
    except Exception:
        return out
    for c in kids:
        out.append(c)
        out.extend(_descendants(c))
    return out


def main():
    tmp = tempfile.mkdtemp(prefix='wg-deps-')
    path_before = list(sys.path)
    try:
        # ---- 1) 清单形态 ----
        keys = [s['key'] for s in deps.SPECS]
        check('SPECS: key 唯一', len(keys) == len(set(keys)), repr(keys))
        check('SPECS: 必填字段齐',
              all(all(k in s for k in ('key', 'mod', 'pkg', 'label', 'why', 'inst')) for s in deps.SPECS))
        manual = sorted(s['key'] for s in deps.SPECS if not s['inst'])
        check('SPECS: 只报告的是语音两项', manual == ['faster_whisper', 'sherpa_onnx'], repr(manual))
        check('SPECS: 可装项含 psutil/cryptography/argostranslate',
              {'psutil', 'cryptography', 'argostranslate'} <=
              {s['key'] for s in deps.SPECS if s['inst']})

        # ---- 2) 探测分类（假 finder：只认 pypdf 与 psutil） ----
        have = {'pypdf', 'psutil'}
        items = deps.probe(specs=deps.SPECS, finder=lambda m: m in have)
        by = {i['key']: i for i in items}
        check('probe: 有 = present', by['pypdf']['present'] and not by['pypdf']['missing'])
        check('probe: 无 = missing', by['cryptography']['missing'] and not by['cryptography']['present'])
        check('probe: 保留 inst 字段', by['argostranslate']['inst'] is True
              and by['sherpa_onnx']['inst'] is False)
        check('probe: 长度 = 清单长度', len(items) == len(deps.SPECS))
        check('installable(): 只含可装且缺的',
              sorted(deps.installable(items)) == ['argostranslate', 'cryptography'],
              repr(deps.installable(items)))
        check('report_only(): 语音两项', sorted(i['key'] for i in deps.report_only(items)) ==
              ['faster_whisper', 'sherpa_onnx'])
        rep = deps.text_report(items)
        check('text_report: 含缺项名与 pip 包', ('argostranslate' in rep) and ('聊天加密' in rep))
        check('text_report: 语音标为「只报告」', '只报告' in rep)
        check('text_report: 不含已装的 pypdf', 'PDF 工具' not in rep)

        def boom_finder(mod):
            raise RuntimeError('finder 炸了')

        check('probe: finder 抛异常算「缺」（不炸整个探测）',
              all(i['missing'] for i in deps.probe(specs=[deps.SPECS[0]], finder=boom_finder)))

        # ---- 3) 命令行必须是 --target 私有目录 ----
        target = deps.site_dir(tmp)
        check('site_dir: 在 DATA_DIR/site/pip',
              os.path.normpath(target) == os.path.normpath(os.path.join(tmp, 'site', 'pip')), target)
        argv = deps.pip_argv(target, ['psutil'])
        check('pip_argv: 含 --target 与目标目录', '--target' in argv and target in argv)
        check('pip_argv: 含 -m pip install', argv[1:4] == ['-m', 'pip', 'install'], repr(argv[:4]))
        check('pip_argv: **不含 --user**（不污染用户 Python）', '--user' not in argv)
        check('pip_argv: 包名在最后', argv[-1] == 'psutil')
        sc = deps.shell_command(r'C:\a b\pip', ['psutil'])
        check('shell_command: 带空格路径加引号', '"C:\\a b\\pip"' in sc, sc)

        # ---- 4) install 的各条路径 ----
        runner, seen = make_runner()
        got = []
        r = deps.install(['psutil'], tmp, on_line=got.append, runner=runner)
        check('install: 成功 -> ok=True/rc=0', r['ok'] and r['code'] == 0, repr(r.get('error')))
        check('install: 真建了安装目录', os.path.isdir(target))
        check('install: runner 收到 --target 私有目录', seen['cmd'] is not None and target in seen['cmd'])
        check('install: 逐行回调收到全部输出', got == ['Collecting x', 'Successfully installed x-1.0'], repr(got))
        check('install: 透传 timeout', 'timeout' in seen)
        check('install: 成功后立刻把私有目录挂上 sys.path', deps.site_dir(tmp) in sys.path)

        runner, _ = make_runner(rc=1, lines=['ERROR: No module named pip'])
        r = deps.install(['psutil'], tmp, runner=runner)
        check('install: 缺 pip -> 提示 ensurepip', (not r['ok']) and ('ensurepip' in r['error']), repr(r['error']))

        runner, _ = make_runner(rc=1, lines=['ERROR: Could not find a version that satisfies',
                                             'Failed to establish a new connection'])
        r = deps.install(['psutil'], tmp, runner=runner)
        check('install: 网络失败 -> 人话提示', (not r['ok']) and ('网络' in r['error']), repr(r['error']))

        runner, _ = make_runner(rc=2, lines=['something else'])
        r = deps.install(['psutil'], tmp, runner=runner)
        check('install: 其它失败 -> 带返回码', (not r['ok']) and ('2' in r['error']), repr(r['error']))

        runner, _ = make_runner(boom=OSError('spawn 失败'))
        r = deps.install(['psutil'], tmp, runner=runner)
        check('install: runner 抛异常 -> 返回错误而不抛', (not r['ok']) and bool(r['error']), repr(r))

        r = deps.install([], tmp, runner=make_runner()[0])
        check('install: 空包列表 -> ok=False', not r['ok'])

        # ---- 5) 状态文件 ----
        check('read_state: 空目录 = {}', deps.read_state(tmp) == {})
        deps.write_state(tmp, asked=1, installed='psutil')
        st = deps.read_state(tmp)
        check('write/read 往返', st.get('asked') == '1' and st.get('installed') == 'psutil', repr(st))
        check('should_ask: 问过就 False', deps.should_ask(tmp) is False)
        check('write_state: 合并保留既有键', deps.write_state(tmp, note='x') and
              deps.read_state(tmp).get('installed') == 'psutil')
        sf = deps.state_file(tmp)
        raw = open(sf, 'rb').read()
        check('状态文件: LF（不是 CRLF）', b'\r\n' not in raw)
        with open(sf, 'wb') as f:                       # 手工塞一个 CRLF 的文件
            f.write(b'asked=1\r\ninstalled=a\r\n')
        st = deps.read_state(tmp)
        check("read_state: 值里不带 '\\r'（§39）",
              st.get('installed') == 'a' and not any('\r' in v for v in st.values()), repr(st))

        tmp2 = tempfile.mkdtemp(prefix='wg-deps2-')
        try:
            check('should_ask: 首启 True', deps.should_ask(tmp2) is True)
            deps.note_installed(tmp2, ['pypdf'])
            deps.note_installed(tmp2, ['pypdf', 'psutil'])
            check('note_installed: 累加去重',
                  deps.read_state(tmp2).get('installed') == 'pypdf,psutil',
                  repr(deps.read_state(tmp2)))
            deps.mark_asked(tmp2, result='declined')
            st2 = deps.read_state(tmp2)
            check('mark_asked: 记 asked/at/result',
                  st2.get('asked') == '1' and bool(st2.get('at')) and st2.get('result') == 'declined', repr(st2))
        finally:
            shutil.rmtree(tmp2, ignore_errors=True)

        # ---- 6) 私有目录挂 sys.path（幂等 + 立刻可被发现） ----
        empty = tempfile.mkdtemp(prefix='wg-deps3-')       # 目录还不存在
        fresh = tempfile.mkdtemp(prefix='wg-deps4-')       # 目录存在但还没挂过
        os.makedirs(os.path.join(fresh, 'site', 'pip'), exist_ok=True)
        try:
            check('ensure_site_on_path: 目录不存在 -> False', deps.ensure_site_on_path(empty) is False)
            check('ensure_site_on_path: 不存在就不进 sys.path',
                  deps.site_dir(empty) not in sys.path)
            check('ensure_site_on_path: 有目录 -> True', deps.ensure_site_on_path(fresh) is True)
            check('ensure_site_on_path: 幂等（第二次 False）', deps.ensure_site_on_path(fresh) is False)
            check('ensure_site_on_path: sys.path 里只出现一次', sys.path.count(deps.site_dir(fresh)) == 1)
        finally:
            shutil.rmtree(empty, ignore_errors=True)
            shutil.rmtree(fresh, ignore_errors=True)

        pkgdir = os.path.join(target, 'wg_dep_probe_pkg')
        os.makedirs(pkgdir, exist_ok=True)
        open(os.path.join(pkgdir, '__init__.py'), 'w', encoding='utf-8').write('VALUE = 1\n')
        importlib.invalidate_caches()
        spec = {'key': 'probe', 'mod': 'wg_dep_probe_pkg', 'pkg': 'x', 'inst': True,
                'label': 'x', 'why': 'x'}
        got2 = deps.probe(data_dir=tmp, specs=[spec])
        check('probe: 装进私有目录的包能被发现（invalidate_caches）', got2[0]['present'], repr(got2[0]))

        # ---- 6b) 依赖窗口真建出来 + 不越界（§42 的教训: 手工排版的窗必须几何审计, 别靠肉眼） ----
        if not has_desktop():
            print('  SKIP: 没有可用桌面/Tk —— 依赖窗口的几何审计跳过')
        else:
            import tkinter as tk
            try:
                import tools as toolsmod
                root = tk.Tk()
                root.withdraw()
                try:
                    fake = deps.probe(specs=deps.SPECS, finder=lambda m: m == 'pypdf')
                    win = toolsmod.show_depcheck(fake, tmp,
                                                 on_install=lambda p, log, done: log('fake %s' % p),
                                                 on_reprobe=lambda: fake)
                    root.update_idletasks()
                    check('依赖窗口: 建出来了', bool(win.winfo_exists()))

                    def abs_box(wid):
                        """子控件在**窗口内**的绝对位置: 一路加父偏移, 到 win 为止
                        (走到 root 会把窗口在屏幕上的位置也算进来 -> 假红)。"""
                        x = y = 0
                        w = wid
                        while w is not None and w is not win:
                            x += w.winfo_x()
                            y += w.winfo_y()
                            w = w.master
                        return x, y, wid.winfo_width(), wid.winfo_height()

                    W, H = win.winfo_width(), win.winfo_height()
                    boxes = [abs_box(c) for c in _descendants(win)]
                    right = max([b[0] + b[2] for b in boxes] or [0])
                    bottom = max([b[1] + b[3] for b in boxes] or [0])
                    check('依赖窗口: 没有控件越出右边界', right <= W + 2, 'right=%s W=%s' % (right, W))
                    check('依赖窗口: 没有控件越出下边界（底部按钮/日志不被裁）', bottom <= H + 2,
                          'bottom=%s H=%s' % (bottom, H))
                    check('依赖窗口: 有日志框(Console)',
                          any(isinstance(c, tk.Text) for c in _descendants(win)))
                    win.destroy()
                finally:
                    root.destroy()
            except Exception as ex:
                check('依赖窗口: 建出来了', False, repr(ex))

        # ---- 7) 分发单文件必须内嵌本模块 ----
        if os.path.isfile(DIST):
            dsrc = open(DIST, 'rb').read().decode('utf-8', 'replace')
            m = re.search(r"(?m)^MODULES = \{.*", dsrc)      # 一行超长的 dict 字面量
            line = m.group(0) if m else ''
            check("dist 内嵌清单含 'deps'（忘了重建 dist 就会红）",
                  "'deps':" in line, (line[:80] if line else 'no MODULES line'))
        else:
            print('  SKIP: 没有 dist\\wgime-py.py')

        print('')
        if fails:
            print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
            return 1
        print('全部通过 (%d 项)' % n[0])
        return 0
    finally:
        sys.path[:] = path_before
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
