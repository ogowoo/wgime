# -*- coding: utf-8 -*-
"""sherpa-warm-test.py — 常驻本地 sherpa-onnx 助手 (`voice_engine = sherpa`) 的纯桩回归。

不装 sherpa-onnx、不载模型、不起真进程、不联网: 把 `voice.subprocess.Popen` 换成**照抄真管道语义**的
假进程, 驱动 `voice._SherpaSrv` 整套状态机。

它和 `whisper-warm-test.py` 共用同一套父进程机制 (`voice._WarmSrv`), 所以这里的重点有两块:
  ① **sherpa 特有的差异**: 怎么起进程 (`wrapper --serve --itn= --threads= --lang=`)、
     什么进 `key`(改了要重启助手 —— itn/lang/threads/script 都是**建识别器**的参数, 与 whisper 相反)、
     请求里只带 `{id,wav}`、没配 `stt_script` 时的报错;
  ② **共用机制在 sherpa 这一侧同样成立** (超时/串包/崩溃/连续失败/陈旧错误/重启时的队列隔离) ——
     机制抽出来以后, 两边都得各自钉一遍, 否则"抽出来"就等于"少测一遍"。

桩的语义与兄弟文件一致 (不改宽): 没数据时 `for line in proc.stdout` 会**阻塞**; 进程死了写 stdin
会**抛 ValueError**; 只有 `kill()`/`end()` 之后才 EOF; 假 Popen 收 `env=` 时**不合并** os.environ。

跑: python wgime-py-pure\\tests\\sherpa-warm-test.py      (应输出 ALL OK)
"""
import json
import os
import queue
import sys
import threading
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
_MOD = os.path.dirname(_HERE)
if _MOD not in sys.path:
    sys.path.insert(0, _MOD)
import voice                                        # noqa: E402

FAILS = []
N = [0]


def ck(name, cond, extra=''):
    N[0] += 1
    if not cond:
        FAILS.append(name)
        print('  FAIL %s %s' % (name, extra))
    else:
        print('  ok   %s %s' % (name, extra))


# ---------------- 假进程 (与 whisper-warm-test.py 同一份语义) ----------------
class _FakeOut(object):
    """假的 stdout/stderr: `for line in proc.stdout` 会**阻塞**到有数据或进程结束。"""

    def __init__(self, p, ended=False):
        self.p = p
        self.q = queue.Queue()
        self.ended = threading.Event()
        if ended:
            self.ended.set()

    def __iter__(self):
        return self

    def __next__(self):
        while True:
            try:
                return self.q.get(timeout=0.02)
            except queue.Empty:
                if self.ended.is_set() or self.p.rc is not None:
                    raise StopIteration
                continue

    def push(self, s):
        self.q.put(s)

    def end(self):
        self.ended.set()


class _FakeIn(object):
    def __init__(self, p):
        self.p = p
        self.lines = []

    def write(self, s):
        if self.p.rc is not None:
            raise ValueError('I/O operation on closed file')
        self.lines.append(s)

    def flush(self):
        if self.p.rc is not None:
            raise ValueError('I/O operation on closed file')

    def close(self):
        self.p.rc = 0


class FakeProc(object):
    def __init__(self, argv, kw, dummy=False):
        self.argv = list(argv)
        self.kw = dict(kw)
        self.env = dict(kw.get('env') or {})
        self.pid = id(self) % 100000
        self.rc = None
        self.killed = False
        self.dummy = dummy                          # 起进程那一步失败时的空壳 (见 need_proc)
        self.stdin = _FakeIn(self)
        self.stdout = _FakeOut(self)
        self.stderr = _FakeOut(self, ended=True)
        self.written = self.stdin.lines

    def emit(self, obj):
        self.stdout.push(json.dumps(obj) + '\n')

    def end(self, rc=0):
        self.rc = rc
        self.stdout.end()

    def kill(self):
        self.killed = True
        self.end(-9)

    def poll(self):
        return self.rc

    def wait(self, timeout=None):
        return self.rc


PROCS = []
BOOM = [None]


def fake_popen(argv, **kw):
    if BOOM[0] is not None:
        raise BOOM[0]
    p = FakeProc(argv, kw)
    PROCS.append(p)
    return p


def last():
    return PROCS[-1] if PROCS else None


def need_proc(name):
    """取"刚起的那个进程", 并确认它**就是当前 `_SSRV` 实例上的**。

    起进程失败(或 warm 操作错了实例)时给一个**空壳**顶住: 后面的断言会照样记 FAIL,
    但测试不会崩在 `NoneType has no attribute` / `IndexError` 上 ——
    崩溃/挂死的测试比失败的测试难查得多。空壳尽量沿用最后一次真 spawn 的参数,
    这样 argv/env 那几条断言仍是在考"进程是怎么起的"。
    """
    p = last()
    ok = p is not None and voice._SSRV.proc is p
    ck(name, ok)
    if ok:
        return p
    return FakeProc(p.argv if p is not None else [], p.kw if p is not None else {}, dummy=True)


def wt(p, idx):
    """取第 idx 条写进 stdin 的请求 (没有就 None, 不抛)。"""
    return p.written[idx] if len(p.written) > idx else None


def fresh():
    """干净状态: 换一个 _SSRV 实例 (也顺手换掉 whisper 的, 免得两边互相干扰)。"""
    del PROCS[:]
    BOOM[0] = None
    voice._SSRV = voice._SherpaSrv()
    voice._WSRV = voice._WhisperSrv()
    return voice._SSRV


voice.subprocess.Popen = fake_popen

SCRIPT = r'C:\Tools\wgime-local-asr\wgime-stt.py'
CFG = {'voice_engine': 'sherpa', 'stt_script': SCRIPT, 'stt_lang': 'zh',
       'stt_itn': True, 'stt_threads': 4}
WAV = r'C:\tmp\a.wav'


def wait_written(p, idx, timeout=3.0):
    """等父进程把第 idx 条 (0 基) 请求写进假 stdin。**必须有上限** ——
    序号写错时不能变成死循环 (挂死的测试比失败的测试更糟: CI 上要等超时)。"""
    t0 = time.time()
    while len(p.written) <= idx:
        if time.time() - t0 > timeout:
            return False
        time.sleep(0.005)
    return True


def ask(p, cfg, wav=WAV, resp=None, wait=5.0, nth=1):
    if getattr(p, 'dummy', False):
        wait = 0.3                                  # 空壳: 别白等 (失败已经由 need_proc 记下了)
    box = {}
    th = threading.Thread(target=lambda: box.update(r=voice.recognize(wav, cfg)), daemon=True)
    th.start()
    t0 = time.time()
    while len(p.written) < nth and time.time() - t0 < wait:
        if not th.is_alive():
            break
        time.sleep(0.005)
    if resp is not None and len(p.written) >= nth:
        rid = json.loads(p.written[nth - 1])['id']
        p.emit(dict(resp, id=rid) if 'id' not in resp else resp)
    th.join(wait)
    return box.get('r'), th.is_alive()


print('A) 起进程: 命令行形状 / 环境 / 预热不阻塞')
fresh()
t0 = time.time()
r = voice.warm(CFG)
dt = (time.time() - t0) * 1000
p = last()
ck('A1 warm() 返回 True', r is True)
ck('A2 warm() 立刻返回, 不等 READY', dt < 500 and voice._SSRV.ready is False, '(%.0f ms)' % dt)
ck('A3 真的起了进程, 而且就是当前这个 _SSRV 上的',
   p is not None and p.poll() is None and voice._SSRV.proc is p,
   '(warm 若操作了别的实例, 这里就露馅 —— 见 _warm_srv 的"调用时取全局")')
ck('A4 命令行是 wrapper 的 --serve 模式', p.argv[1] == '-u' and p.argv[2] == SCRIPT
   and p.argv[3] == '--serve', repr(p.argv))
ck('A5 带上了 --itn / --threads / --lang', '--itn=1' in p.argv and '--threads=4' in p.argv
   and '--lang=zh' in p.argv, repr(p.argv))
ck('A6 没走 whisper 那套"源码进环境变量"', voice._WSRV_SRC_ENV not in p.env
   and voice._WSRV_OPTS_ENV not in p.env)
ck('A7 env 是复制过的 (没丢掉宿主环境)', p.env is not os.environ and 'PATH' in p.env)
ck('A8 用了 CREATE_NO_WINDOW', p.kw.get('creationflags') == voice.CREATE_NO_WINDOW)
t0 = time.time()
ck('A9 同 key 再 warm 不重启', voice.warm(CFG) is True and last() is p
   and (time.time() - t0) < 0.5)
for eng in ('system', 'cmd', 'http', 'whisper'):
    ck('A10 warm() 对 %r 不动手' % eng,
       voice.warm(dict(CFG, voice_engine=eng)) is False or eng == 'whisper')
ck('A11 命令行是 argv 列表 (shell=False, 路径带空格也不用引号)',
   isinstance(p.argv, list) and p.argv[0] == voice._wsrv_python(CFG))

print('\nB) 哪些参数进 key (sherpa 的 itn/lang/threads 是**建识别器**的参数 -> 改了必须重启)')
for field, val in (('stt_itn', False), ('stt_lang', 'en'), ('stt_threads', 8),
                   ('stt_script', r'C:\other\stt.py'), ('stt_python', r'C:\py\python.exe')):
    voice._SSRV.started = 0.0
    before = voice._SSRV.proc
    r = voice._SSRV.ensure(dict(CFG, **{field: val}))
    ck('B1 换 %-11s -> 重启' % field, r is True and before is not None
       and voice._SSRV.proc is not before and before.poll() is not None)
voice._SSRV.started = 0.0
voice._SSRV.ensure(dict(CFG))                     # 先回到 CFG (B1 最后一轮改的是 stt_python)
voice._SSRV.started = 0.0
before = voice._SSRV.proc
ck('B2 同一份配置 -> 复用不重启', voice._SSRV.ensure(dict(CFG)) is True
   and voice._SSRV.proc is before)
voice._SSRV.started = 0.0
before = voice._SSRV.proc
ck('B3 非 key 字段 (如 stt_prewarm) 不影响复用',
   voice._SSRV.ensure(dict(CFG, stt_prewarm=False)) is True and voice._SSRV.proc is before)

print('\nC) 没配 stt_script 时要明确报错 (不能静默)')
fresh()
ck('C1 ensure 返回 False', voice._SSRV.ensure({'voice_engine': 'sherpa'}) is False)
ck('C2 报的是"没配 stt_script"', 'stt_script' in (voice._SSRV.last_err or ''),
   repr(voice._SSRV.last_err))
t, e = voice.recognize(WAV, {'voice_engine': 'sherpa'})
ck('C3 recognize 也报错并给提示', e and 'stt_script' in e, repr(e))
ck('C4 没把"起不来"当成"没听清"', t is None)

print('\nD) READY / 一问一答 / 边角')
fresh()
voice.warm(CFG)
p = need_proc('D0 warm() 起了进程 (且属于当前 _SSRV 实例)')
p.emit({'ready': True, 'model': 'sense-voice', 'boot_ms': 1208})
res, _ = ask(p, CFG, resp={'ok': True, 'text': u'\u4f60\u597d', 'ms': 12, 'audio_ms': 300})
ck('D1 READY 后正常识别', res == (u'\u4f60\u597d', None), repr(res))
ck('D2 boot_ms 记下', voice._SSRV.boot_ms == 1208)
req_raw = wt(p, 0)
req = json.loads(req_raw) if req_raw else {}
ck('D3 请求只带 id/wav (itn/lang 是建识别器时的)', set(req.keys()) == {'id', 'wav'}, repr(req))
ck('D4 请求是 ASCII JSON + 换行',
   bool(req_raw) and req_raw.endswith('\n') and all(ord(c) < 128 for c in req_raw))
res, _ = ask(p, CFG, resp={'ok': True, 'text': u'', 'ms': 1}, nth=2)
ck('D5 空文本不是错误', res == (u'', None), repr(res))
res, _ = ask(p, CFG, resp={'ok': False, 'error': u'\u8bfb wav \u5931\u8d25'}, nth=3)
ck('D6 助手报错要透出来', res and res[1] and u'\u8bfb wav' in res[1], repr(res))
res, _ = ask(p, CFG, resp={'ok': True, 'text': u'\u540e\u9762\u8fd8\u80fd\u7528', 'ms': 3}, nth=4)
ck('D7 报错之后仍能继续问', res == (u'\u540e\u9762\u8fd8\u80fd\u7528', None), repr(res))
# 串包: 第 5 条请求 (下标 4)
box = {}
th = threading.Thread(target=lambda: box.update(r=voice.recognize(WAV, CFG)), daemon=True)
th.start()
ok5 = wait_written(p, 4)
ck('D8a 第 5 条请求已发出', ok5)
if ok5:
    rid = json.loads(p.written[4])['id']
    p.emit({'id': rid + 50, 'ok': True, 'text': u'\u4e32\u5305', 'ms': 1})
    time.sleep(0.1)
    ck('D8 id 不符的回包被丢掉', th.is_alive())
    p.emit({'id': rid, 'ok': True, 'text': u'\u6b63\u786e', 'ms': 2})
    th.join(3)
    ck('D9 拿到自己那条', box.get('r') == (u'\u6b63\u786e', None), repr(box.get('r')))
# 识别中被杀: 第 6 条请求 (下标 5)
box = {}
th = threading.Thread(target=lambda: box.update(r=voice.recognize(WAV, CFG)), daemon=True)
th.start()
ck('D10a 第 6 条请求已发出', wait_written(p, 5))
p.kill()
th.join(3)
ck('D10 助手在识别中崩溃要报错', box.get('r') and box['r'][1] and u'\u9000\u51fa' in box['r'][1],
   repr(box.get('r')))
ck('D11 崩溃计一次失败', voice._SSRV.fail == 1, 'fail=%d' % voice._SSRV.fail)

print('\nE) 初始化失败 / 超时')
fresh()
voice.warm(CFG)
p = need_proc('E0 warm() 起了进程 (且属于当前 _SSRV 实例)')
p.emit({'ready': False, 'error': u'sherpa_onnx \u4e0d\u53ef\u7528'})
t, e = voice.recognize(WAV, CFG)
ck('E1 初始化失败报助手给的原因', e and u'sherpa_onnx' in e, repr(e))
ck('E2 并附上 stt_script 提示', e and 'stt_script' in e)
ck('E3 失败后进程被收掉', p.poll() is not None)
fresh()
voice.warm(CFG)
p = need_proc('E4 前置: warm() 起了进程')
p.emit({'ready': True, 'model': 'sense-voice', 'boot_ms': 1})
_ot, _oc = voice.SSRV_TIMEOUT, voice.SSRV_TIMEOUT_COLD
voice.SSRV_TIMEOUT = voice.SSRV_TIMEOUT_COLD = 0.4
t0 = time.time()
res, _ = ask(p, CFG, wait=3.0)
voice.SSRV_TIMEOUT, voice.SSRV_TIMEOUT_COLD = _ot, _oc
ck('E4 超时要报超时', res and res[1] and u'\u8d85\u65f6' in res[1], repr(res))
ck('E5 真的按时返回', (time.time() - t0) < 2.0, '%.2fs' % (time.time() - t0))

print('\nF) 连续失败 / 陈旧错误 (共用机制在 sherpa 上也成立)')
fresh()
BOOM[0] = FileNotFoundError(2, 'The system cannot find the file specified')
errs = []
for _i in range(3):
    voice._SSRV.started = 0.0
    _t, err = voice.recognize(WAV, dict(CFG, stt_python=r'C:\no\python.exe'))
    errs.append(err)
ck('F1 每次报"启动失败"', all(e and u'\u542f\u52a8\u672c\u5730 sherpa' in e for e in errs),
   repr(errs[-1]))
ck('F2 失败计数到 3', voice._SSRV.fail == 3, 'fail=%d' % voice._SSRV.fail)
BOOM[0] = None
voice._SSRV.started = 0.0
ck('F3 三次之后不再 spawn', voice._SSRV.ensure(CFG) is False and not PROCS)
fresh()
BOOM[0] = FileNotFoundError(2, 'x')
voice._SSRV.started = 0.0
_t, errA = voice.recognize(WAV, dict(CFG, stt_python=r'C:\no-A\python.exe'))
_t, errB = voice.recognize(WAV, dict(CFG, stt_python=r'C:\no-B\python.exe'))
BOOM[0] = None
ck('F4 第二次不原样重复上一条 (陈旧错误已清)',
   errB != errA and u'\u542f\u52a8\u672c\u5730 sherpa' not in (errB or ''), repr(errB))

print('\nG) 重启助手时, 旧读取线程的 EOF 不能落进新队列')
fresh()
voice.warm(CFG)
pA = need_proc('G0 warm() 起了进程')
pA.emit({'ready': True, 'model': 'sense-voice', 'boot_ms': 1})
time.sleep(0.15)
old_q = voice._SSRV.q
voice._SSRV.started = 0.0
ck('G1 换了 key 起了新进程', voice._SSRV.ensure(dict(CFG, stt_threads=8)) is True
   and last() is not pA and pA.poll() is not None)
ck('G2 队列换成新的', old_q is None or voice._SSRV.q is not old_q)
time.sleep(0.3)
newq = list(voice._SSRV.q.queue) if voice._SSRV.q is not None else []
oldq = list(old_q.queue) if old_q is not None else []
ck('G3 新队列里没有 EOF', not any(o.get('eof') for o in newq), repr(newq))
ck('G4 旧队列确实收到 EOF (证明 G3 不空转)',
   bool(oldq) and any(o.get('eof') for o in oldq), repr(oldq))

print('\nH) shutdown / prewarm_bg')
fresh()
voice.warm(CFG)
p = need_proc('H0 warm() 起了进程')
voice._WSRV.proc = None                       # whisper 那侧不参与本测试
voice.shutdown()
ck('H1 sherpa 进程被 kill', p.killed and p.poll() is not None)
ck('H2 状态清空', voice._SSRV.proc is None and voice._SSRV.ready is False)
voice._SSRV.started = 0.0
ck('H3 关了还能重新起', voice._SSRV.ensure(CFG) is True and last() is not p)
fresh()
ck('H4 stt_prewarm=0 不预热', voice.prewarm_bg(dict(CFG, stt_prewarm=False)) is False)
ck('H5 非 sherpa 引擎不预热', voice.prewarm_bg({'voice_engine': 'cmd'}) is False)
t0 = time.time()
ck('H6 sherpa 会排后台预热', voice.prewarm_bg(CFG, delay=0.05) is True)
ck('H7 排预热本身不阻塞', (time.time() - t0) < 0.3)
time.sleep(0.4)
ck('H8 后台预热真的起进程', last() is not None)
voice.shutdown()

print('\nI) 分派表 (别把 whisper/cmd/system/http 弄丢)')
fresh()
seen = []
for nm in ('_system_recognize', '_http_recognize', '_cmd_recognize',
           '_whisper_recognize', '_sherpa_recognize'):
    setattr(voice, nm, (lambda n: (lambda w, c: (seen.append(n), (n, None))[1]))(nm))
for eng in ('sherpa', 'sensevoice', 'sense-voice', 'sherpa-onnx'):
    voice.recognize(WAV, {'voice_engine': eng})
for eng in ('whisper', 'local', 'faster-whisper', 'warm'):
    voice.recognize(WAV, {'voice_engine': eng})
for eng in ('cmd', 'command', 'http', 'system'):
    voice.recognize(WAV, {'voice_engine': eng})
voice.recognize(WAV, {})
ck('I1 四个 sherpa 别名都走 sherpa', seen[:4] == ['_sherpa_recognize'] * 4, repr(seen))
ck('I2 四个 whisper 别名仍走 whisper', seen[4:8] == ['_whisper_recognize'] * 4, repr(seen))
ck('I3 cmd/http/system 不变',
   seen[8:] == ['_cmd_recognize', '_cmd_recognize', '_http_recognize', '_system_recognize',
                '_system_recognize'], repr(seen))

print('\nJ) _ssrv_opts / _ssrv_threads 的取值 (手写 cfg 也要吃得下)')
ck('J1 缺省 itn 开 / threads 4', voice._ssrv_opts({})['itn'] == 1
   and voice._ssrv_opts({})['threads'] == 4)
ck('J2 itn=0 关', voice._ssrv_opts({'stt_itn': False})['itn'] == 0)
ck('J3 itn 写字符串 0/off 也算"关" (手写 cfg 不会反过来)',
   voice._ssrv_opts({'stt_itn': '0'})['itn'] == 0
   and voice._ssrv_opts({'stt_itn': 'off'})['itn'] == 0
   and voice._ssrv_opts({'stt_itn': '1'})['itn'] == 1)
ck('J4 threads 越界钳住', voice._ssrv_threads({'stt_threads': 99}) == 16
   and voice._ssrv_threads({'stt_threads': 0}) == 1)
ck('J5 threads 垃圾值回缺省', voice._ssrv_threads({'stt_threads': 'x'}) == 4
   and voice._ssrv_threads({'stt_threads': None}) == 4)
ck('J6 script 空 -> 空串 (spawn 时才报错)', voice._ssrv_opts({})['script'] == '')
ck('J7 _warm_srv 认引擎、不认别的', voice._warm_srv('sherpa') is voice._SSRV
   and voice._warm_srv('whisper') is voice._WSRV and voice._warm_srv('cmd') is None
   and voice._warm_srv('') is None)

print('\n%s' % ('ALL OK (%d \u9879)' % N[0] if not FAILS
                else 'FAILED %d/%d: %s' % (len(FAILS), N[0], FAILS)))
sys.exit(1 if FAILS else 0)
