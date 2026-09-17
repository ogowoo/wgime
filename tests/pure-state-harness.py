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

    print('--- lastpick_*.txt: CRLF 的行尾 \\r 不进值, LastPick 仍置顶 (第五十轮) ---')
    # 现场形状: C# 写 CRLF; 老 python 版本把行尾 \r 当成词的一部分, 每轮 载入/存盘 又长一个 \r
    # (`bm 出\r\r\r...`) -> candidates() 里 `lp in cands` 永远不等, 置顶静默失效。
    eng.lastpick_m[0] = {}
    base = eng.candidates(k1, 0)[0]
    lp_word = base[1] if len(base) > 1 else ''            # 故意选非首位的词: 只有置顶生效才会跑到第一
    with open(os.path.join(data_dir, 'lastpick_mix.txt'), 'wb') as f:
        f.write((k1 + ' ' + lp_word + '\r' * 3 + '\r\n').encode('utf-8'))
    eng._load_freq()
    check('lastpick 值不带 \\r', eng.lastpick_m[0].get(k1) == lp_word, repr(eng.lastpick_m[0].get(k1)))
    cands1 = eng.candidates(k1, 0)[0]
    check('lastpick 仍置顶', bool(lp_word) and cands1[0] == lp_word, repr(cands1[:5]))

    print('--- config.txt 写回: 行尾跟原文件走 + 写失败要告诉用户 (第五十一轮) ---')
    # ⚠ APP_DIR 在 harness 里指向**仓库源码目录**(main.py 所在处), 碰 _write_config 前必须先改到临时目录
    real_app_dir = ns['APP_DIR']
    cfg_dir = os.path.join(tmp, 'appdir')
    os.makedirs(cfg_dir, exist_ok=True)
    ns['APP_DIR'] = cfg_dir
    assert os.path.abspath(cfg_dir).startswith(os.path.abspath(tmp)), cfg_dir
    cfg_path = os.path.join(cfg_dir, 'config.txt')
    with open(cfg_path, 'wb') as f:
        f.write(b'fuzzy = none\ntrad = 0\n')             # 出厂模板 config.txt 就是 LF
    ns['_write_config']('trad', '1')
    raw = open(cfg_path, 'rb').read()
    check('LF 配置写回后仍是 LF', b'\r' not in raw and b'trad = 1' in raw, repr(raw))
    with open(cfg_path, 'wb') as f:
        f.write(b'fuzzy = none\r\ntrad = 0\r\n')
    ns['_write_config']('trad', '1')
    raw = open(cfg_path, 'rb').read()
    check('CRLF 配置写回后仍是 CRLF', raw.count(b'\r\n') == 2 and b'trad = 1' in raw, repr(raw))
    blocked = os.path.join(tmp, 'blocked')
    with open(blocked, 'wb') as f:                       # 同名文件挡路 -> 写一定失败
        f.write(b'x')
    ns['APP_DIR'] = os.path.join(blocked, 'sub')
    del log[:]
    saved = ns['_save_cfg']('trad', '1', '繁体输出')
    check('写失败时 _save_cfg 返回 False', saved is False, repr(saved))
    check('写失败时通知用户', ('notify', '设置未保存') in log, repr(log))
    ns['APP_DIR'] = real_app_dir

    # ⚠ 注意: 这里断言的是**代码默认值**, 不能拿 `ns['CFG']` 断言 —— harness 的 APP_DIR 其实是
    # `wgime-py-pure\package`(main.py: `APP_DIR = dirname(DICT_DIR)`, 而 WGIME_DICT_DIR 指向
    # `package\dicts`), 所以 `ns['CFG']` 读的是 `package\config.txt` —— **那是用户可编辑的活文件**
    # (实测它里面 followcaret/statedot 都是 1, 于是两条"默认关"断言凭空变红)。第六十九轮补充发现。
    _engmod = sys.modules['engine']          # 模块本体(main.py 里 `engine` 这个名字被 Engine 实例占了)
    _defaults = _engmod.load_config(os.path.join(tmp, 'no-such-config.txt'))
    print('--- followcaret 默认 0 + 冻结功能 (第六十八轮: 代码全保留, 只默认关) ---')
    check('代码默认 followcaret 关', _defaults.get('followcaret') is False,
          repr(_defaults.get('followcaret')))
    ns['CFG']['followcaret'] = False
    check('_caret_follow() 关着时为假', ns['_caret_follow']() is False)
    ns['CFG']['followcaret'] = True
    check('打开后 _caret_follow() 为真 (能开回来)', ns['_caret_follow']() is True)
    # 冻结 != 删除: 托盘开关/写 config 这条链必须还在 (关着时点一下要能开、并落盘 followcaret = 1)
    fc_dir = os.path.join(tmp, 'appdir-fc')
    os.makedirs(fc_dir, exist_ok=True)
    ns['APP_DIR'] = fc_dir
    with open(os.path.join(fc_dir, 'config.txt'), 'wb') as f:
        f.write(b'followcaret = 1\n')
    ns['toggle_followcaret']()                       # 1 -> 0
    raw = open(os.path.join(fc_dir, 'config.txt'), 'rb').read()
    check('托盘开关能关掉并落盘 0', ns['CFG']['followcaret'] is False and b'followcaret = 0' in raw, repr(raw))
    ns['toggle_followcaret']()                       # 0 -> 1
    raw = open(os.path.join(fc_dir, 'config.txt'), 'rb').read()
    check('托盘开关能再开回来并落盘 1', ns['CFG']['followcaret'] is True and b'followcaret = 1' in raw, repr(raw))
    ns['APP_DIR'] = real_app_dir
    ns['CFG']['followcaret'] = False

    print('--- 状态提示点 (第六十九轮补充: **代码默认关** / tray 不建窗 / 按住鼠标键时隐藏 / 真 tick 能显出来) ---')
    check('代码默认 statedot 关', _defaults.get('statedot') is False, repr(_defaults.get('statedot')))
    ns['CFG']['statedot'] = False
    check('_statedot_on() 关着时为假', ns['_statedot_on']() is False)
    ns['CFG']['statedot'] = False
    ns['_dot_tick']()
    check('关掉时不建窗口', ns['_DOT'][0] is None)
    ns['CFG']['statedot'] = True
    ns['CFG']['mode'] = 'tray'
    ns['_dot_tick']()
    check('tray 模式不建窗口 (没有输入法开关状态)', ns['_DOT'][0] is None, repr(ns['_DOT'][0]))
    ns['CFG']['mode'] = 'ime'
    ns['_dot_tick']()
    check('ime 模式 tick 后圆点已显示', ns['_DOT'][0] is not None and ns['_DOT'][0].is_shown(),
          repr(ns['_DOT'][0]))
    # 第六十九轮补充: 光标没动就不该再摆窗; 状态变了(颜色)才重画; 按住鼠标键时隐藏
    dot_obj = ns['_DOT'][0]
    calls = []
    real_update = dot_obj.update
    dot_obj.update = lambda x, y, c: (calls.append((x, y, c)), real_update(x, y, c))[1]
    ns['_dot_tick']()
    n1 = len(calls)
    ns['_dot_tick']()
    check('光标没动、状态没变 -> 不再摆窗', len(calls) == n1, '%d -> %d' % (n1, len(calls)))
    ns['ime'].mode = 1
    ns['_dot_tick']()
    check('状态变了(模式) -> 重新上色', len(calls) > n1, repr(calls[-1:]))
    ns['ime'].mode = 0
    _real_mbd = ns['win'].mouse_buttons_down
    ns['win'].mouse_buttons_down = lambda: True
    ns['_dot_tick']()
    check('按住鼠标键(拖动中) -> 隐藏', dot_obj.is_shown() is False)
    ns['win'].mouse_buttons_down = _real_mbd
    ns['_dot_tick']()
    check('松开之后 -> 自动回来', dot_obj.is_shown() is True)
    dot_obj.update = real_update
    dot_obj.destroy()
    ns['_DOT'][0] = None

    print('--- 语音"点击落点" (第七十四轮: 只进剪贴板 + 等用户点目标输入框再自动粘贴) ---')
    shown, clip, watch = [], [], [0, 0]
    bar.show = lambda *a, **k: shown.append(a)
    win.clipboard_set = lambda txt: clip.append(txt)
    win.click_watch_start = lambda cb: (watch.__setitem__(0, watch[0] + 1), True)[1]
    win.click_watch_stop = lambda: watch.__setitem__(1, watch[1] + 1)
    ns['CFG']['voice_click'] = True
    ns['CFG']['voice_auto'] = False
    ime.active = True
    ime.mode = 0
    ns['VOICE_Q'].put(('ok', '点击落点文本', None, None))
    del log[:]
    ns['_voice_drain']()
    check('点击落点: 文本先落剪贴板', clip == ['点击落点文本'], repr(clip))
    check('点击落点: 进入等待态', ns['_VOICE']['click'] is True)
    check('点击落点: 装了鼠标左键钩子', watch[0] == 1, repr(watch))
    check('点击落点: 候选条提示"点目标输入框粘贴"',
          any('点目标输入框粘贴' in str(a) for a in shown), repr(shown[-1:]))
    ns['_voice_click_hit']()                       # 模拟"用户点了一下"
    check('命中: 立刻收钩', watch[1] >= 1, repr(watch))
    ns['_voice_click_paste']()
    check('命中: 上屏一次且内容正确',
          any(c[0] in ('send', 'send_qtfix', 'paste') and c[1] == '点击落点文本' for c in log), repr(log))
    check('命中: 退出等待态并清空待确认文本',
          ns['_VOICE']['click'] is False and ns['_VOICE']['text'] is None)
    # 取消路径: 再等一次, 然后 Esc 取消 -> 必须收钩 (别把全局鼠标钩子留系统里)
    ns['VOICE_Q'].put(('ok', '第二句', None, None))
    del clip[:]
    ns['_voice_drain']()
    was = watch[1]
    ns['voice_cancel']()
    check('取消: 收钩 + 退出等待态', ns['_VOICE']['click'] is False and watch[1] > was, repr(watch))
    check('取消路径也把文本放进了剪贴板', clip == ['第二句'], repr(clip))
    # 关掉这个开关就不该再装钩子 (回归默认行为)
    ns['CFG']['voice_click'] = False
    watch_before = watch[0]
    ns['VOICE_Q'].put(('ok', '第三句', None, None))
    ns['_voice_drain']()
    check('voice_click=0: 不装钩子 (还是老的空格确认)', watch[0] == watch_before and ns['_VOICE']['click'] is False)
    ns['voice_cancel']()
    bar.show = lambda *a, **k: None
    win.clipboard_set = lambda txt: None

    print('--- 语音流式: 增量实时进候选条 (第七十五轮) ---')
    shown2 = []
    bar.show = lambda *a, **k: shown2.append(a)
    ns['_VOICE']['busy'] = True
    ns['_VOICE']['partial'] = None
    ns['VOICE_Q'].put(('partial', '今天天气'))
    ns['_voice_drain']()
    check('流式增量: 状态已更新', ns['_VOICE']['partial'] == '今天天气', repr(ns['_VOICE']['partial']))
    check('流式增量: 候选条显示实时文本', any('今天天气' in str(a) for a in shown2), repr(shown2[-1:]))
    ns['VOICE_Q'].put(('done', '今天天气不错。', None, None))
    del log[:]
    ns['_voice_drain']()
    check('流式定稿: 清 partial + 文本进待确认',
          ns['_VOICE']['partial'] is None and ns['_VOICE']['text'] == '今天天气不错。',
          repr((ns['_VOICE']['partial'], ns['_VOICE']['text'])))
    ns['voice_cancel']()
    ns['_VOICE']['busy'] = False
    bar.show = lambda *a, **k: None

    print('--- [csharp] 插件 txt 用宽松解码读 (第五十一轮: ANSI/GBK 另存不能崩线程) ---')
    gbk_plugin = os.path.join(tmp, 'gbk-plugin.txt')
    with open(gbk_plugin, 'wb') as f:
        f.write('code = gbk1\nname = 插件\n'.encode('gbk'))      # 无 [csharp] 块: 读完即返回, 不会真编译
    payload = type('P', (), {'name': 'gbk1', 'path': gbk_plugin})()
    err = ''
    try:
        ns['_run_csharp_plugin'](payload)
    except Exception as ex:
        err = repr(ex)
    check('GBK 插件 txt 不再抛异常', err == '', err)

    ns['root'].destroy()
    shutil.rmtree(tmp, ignore_errors=True)
    if fails:
        print('\n%d 项失败: %s' % (len(fails), ', '.join(fails)))
        return 1
    print('\n全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
