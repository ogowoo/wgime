# -*- coding: utf-8 -*-
"""tests/pure-state-harness.py — 纯 Python 版「状态机 + 上屏路径」headless 回归。

做法: 真跑 `wgime-py-pure\\main.py` 的前缀(真 engine + 真状态机, 截止到主循环标记之前),
只把**有副作用**的出口打桩 —— 不装键盘钩子、不建托盘图标、不注入按键、不写用户数据:
  - `win.send_unicode / send_unicode_qtfix / paste_text / send_key_backspace`  -> 记录
  - `bar.show / bar.hide`                                                       -> 空操作
  - `engine.learn / learn_assoc / touch_recent / add_user_word / save_freq`      -> 记录
  - `run_launcher / find_launcher / _notify / _dfn`                              -> 记录
数据隔离: 进程内把 `LOCALAPPDATA` 指到临时目录(用完删), 词库目录(`WGIME_DICT_DIR`)默认指向
`wgime-py-pure\\package\\dicts`(无则仓库根) —— 用户真实的 `%LOCALAPPDATA%\\wgime-py` 绝不被读写。

用法 (在仓库根目录执行):
  python tests\\pure-state-harness.py              # 跑工作区源码
  python tests\\pure-state-harness.py --ref HEAD   # 跑某个 git 版本的 main.py(对照/回归)
退出码: 0 = 全部通过; 1 = 有用例失败; 2 = 环境不可用(缺词库/无桌面/Tk 起不来)。
注: 隔离目录里没有词库缓存, 首次运行会看到一条 `[wgime] dict-cache load failed`, 属正常现象。
"""
import argparse
import io
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PURE = os.path.join(REPO, 'wgime-py-pure')
MAIN = os.path.join(PURE, 'main.py')
MARK = '# ---------- 主循环: 轮询钩子事件 ----------'

if hasattr(sys.stdout, 'buffer'):
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')


def load_source(ref):
    if not ref:
        with open(MAIN, encoding='utf-8') as f:
            return f.read()
    r = subprocess.run(['git', '-C', REPO, 'show', ref + ':wgime-py-pure/main.py'],
                       capture_output=True)
    if r.returncode != 0:
        print('无法从 git 取 %s:wgime-py-pure/main.py -> %s' % (ref, r.stderr.decode('utf-8', 'replace')))
        sys.exit(2)
    return r.stdout.decode('utf-8')


def pick_dict_dir():
    env = os.environ.get('WGIME_DICT_DIR')
    if env and os.path.exists(os.path.join(env, 'py.txt')):
        return env
    for cand in (os.path.join(PURE, 'package', 'dicts'), REPO):
        if os.path.exists(os.path.join(cand, 'py.txt')):
            return cand
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ref', default=None, help='git ref (如 HEAD, HEAD~1): 跑那个版本的 main.py')
    args = ap.parse_args()

    dict_dir = pick_dict_dir()
    if not dict_dir:
        print('找不到词库目录 (py.txt); 先跑 wgime-py-pure\\build-package.ps1 或用 WGIME_DICT_DIR 指定')
        return 2

    tmp = tempfile.mkdtemp(prefix='wgime-harness-')
    os.environ['LOCALAPPDATA'] = tmp                       # 数据目录隔离(用完删)
    os.environ['WGIME_DICT_DIR'] = dict_dir
    os.environ['WGIME_NO_SINGLETON'] = '1'                 # 跳过单实例锁
    os.environ['WGIME_RELAUNCHED'] = '1'                   # 禁止 _relaunch_if_console_python 自我重启
    os.environ.pop('WGIME_DEBUG', None)

    print('词库目录 = %s' % dict_dir)
    print('临时数据目录 = %s' % tmp)
    print('源码 = %s' % (('git ' + args.ref) if args.ref else MAIN))
    src = load_source(args.ref)
    cut = src.index(MARK)
    ns = {'__name__': '__main__', '__file__': MAIN}
    sys.path.insert(0, PURE)
    try:
        exec(compile(src[:cut], 'main.py(prefix)', 'exec'), ns)
    except Exception as ex:
        print('载入 main 前缀失败(无桌面/Tk 起不来?): %r' % (ex,))
        shutil.rmtree(tmp, ignore_errors=True)
        return 2

    data_dir = ns['DATA_DIR']
    if not os.path.abspath(data_dir).lower().startswith(os.path.abspath(tmp).lower()):
        print('!! 数据目录未隔离 (DATA_DIR=%s), 拒绝继续' % data_dir)
        ns['root'].destroy()
        shutil.rmtree(tmp, ignore_errors=True)
        return 2

    log = []
    win, bar, eng = ns['win'], ns['bar'], ns['engine']
    win.send_unicode = lambda t, *a, **k: (log.append(('send', t)), len(t))[1]
    win.send_unicode_qtfix = lambda t, *a, **k: (log.append(('send_qtfix', t)), len(t))[1]
    win.paste_text = lambda t, *a, **k: (log.append(('paste', t)), len(t))[1]
    win.send_key_backspace = lambda: log.append(('backspace',))
    bar.show = lambda *a, **k: None
    bar.hide = lambda *a, **k: None
    eng.learn = lambda *a, **k: log.append(('learn',) + a)
    eng.learn_assoc = lambda *a, **k: log.append(('learn_assoc',) + a)
    eng.touch_recent = lambda *a, **k: log.append(('touch_recent',) + a)
    eng.add_user_word = lambda w, c: (log.append(('ADD_USER_WORD', w, c)), True)[1]
    eng.save_freq = lambda *a, **k: None
    ns['run_launcher'] = lambda l: log.append(('run_launcher', l[0]))
    ns['find_launcher'] = lambda code: ('记事本', 'builtin', 'toolbox')
    ns['_notify'] = lambda t, x: log.append(('notify', t))
    ns['_dfn'] = lambda m: None

    ime = ns['ime']
    pairs = []
    for ch, codes in eng.char_py.items():
        if len(ch) == 1 and codes and all(c.isalpha() and c.isascii() for c in codes):
            pairs.append((ch, codes[0]))
        if len(pairs) >= 2:
            break
    if len(pairs) < 2:
        print('!! 词库里找不到两对可用 (字, 全拼码)')
        ns['root'].destroy()
        shutil.rmtree(tmp, ignore_errors=True)
        return 2
    (c1, k1), (c2, k2) = pairs[0], pairs[1]
    print('用例用字 = %r / %r' % ((c1, k1), (c2, k2)))

    fails = []

    def setup(buf, cands, dyn=(), app=None, last=None, recent=()):
        del log[:]
        ime.buf = buf
        ime.cands = list(cands)
        ime.dyn_set = set(dyn)
        ime.app_cand = app
        ime.page = 0
        ime.sel = 0
        ime.assoc_showing = False
        ime.sym_cat = 0
        ime.last_commit = last
        ime.recent = list(recent)
        ime.active = True

    def calls(*names):
        return [c for c in log if c[0] in names]

    def check(name, cond, extra=''):
        print('  %-42s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
        if not cond:
            fails.append(name)

    print('--- 空格逐字上屏: 进自动造词链, 但不强化词频 (AGENTS §14) ---')
    setup(k1, [c1])
    ns['handle'](0x20)
    check('空格上屏首候选', any(c[0] in ('send', 'send_qtfix', 'paste') and c[1] == c1 for c in log), repr(log))
    check('空格: 不进 recent 链才是 bug', [r[0] for r in ime.recent] == [c1], repr(ime.recent))
    check('空格: 不调用 engine.learn', calls('learn') == [], repr(calls('learn')))
    check('空格: _last_learn 保持 None', ns['_last_learn'] is None)

    print('--- 连续两个空格逐字确认 -> 自动造词 ---')
    setup(k1, [c1])
    ns['handle'](0x20)
    carry, lastc = list(ime.recent), ime.last_commit
    setup(k2, [c2], last=lastc, recent=carry)
    ns['handle'](0x20)
    check('自动造词 add_user_word 触发', ('ADD_USER_WORD', c1 + c2, k1 + k2) in log, repr(calls('ADD_USER_WORD')))

    print('--- 数字选候选 (主动选择): 学词频 + 记链 ---')
    setup(k1, [c1, c2])
    ns['handle'](0x32)                       # 数字 2 -> commit(1)
    check('数字: engine.learn 被调用', calls('learn') != [], repr(log))
    check('数字: _last_learn 已设置', bool(ns['_last_learn']))
    check('数字: 记入 recent 链', [r[0] for r in ime.recent] == [c2], repr(ime.recent))

    print('--- 标点自动上屏首候选: 记链、不强化词频 ---')
    setup(k1, [c1], last=c2)
    ns['handle_punct'](0xBC, False)
    check('标点: 先上屏首候选', any(c[0] in ('send', 'send_qtfix', 'paste') and c[1] == c1 for c in log), repr(log))
    check('标点: 记入 recent 链', [r[0] for r in ime.recent] == [c1], repr(ime.recent))
    check('标点: 不强化词频', calls('learn') == [], repr(calls('learn')))
    check('标点: 标点本身也上屏', any(c[0] in ('send', 'send_qtfix', 'paste') and c[1] == '，' for c in log), repr(log))

    print('--- 动态候选 / 启动器候选 / vf 面板: 不学不记 ---')
    setup(k1, ['动态候选'], dyn=('动态候选',))
    ns['handle'](0x20)
    check('动态候选: 无 learn 无造词', calls('learn') == [] and ime.recent == [], repr(log))
    setup('jsq', ['▶ 记事本'], app='▶ 记事本')
    ns['handle'](0x20)
    check('启动器: 只启动不学不记', calls('run_launcher') != [] and calls('learn') == [] and ime.recent == [], repr(log))
    setup('vf', ['℃'])
    ns['handle_punct'](0xBC, False)
    check('vf 面板: 不自动上屏候选', not any(c[0] == 'send' and c[1] == '℃' for c in log), repr(log))

    print('--- 退格: 删组字缓冲 (不泄漏给应用) ---')
    setup(k1 + k1, [c1])
    ns['handle'](0x08)
    check('退格: 缓冲少一个字符', ime.buf == k1, repr(ime.buf))

    ns['root'].destroy()
    shutil.rmtree(tmp, ignore_errors=True)
    if fails:
        print('\n%d 项失败: %s' % (len(fails), ', '.join(fails)))
        return 1
    print('\n全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
