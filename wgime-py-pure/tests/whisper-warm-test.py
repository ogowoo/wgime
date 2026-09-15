# -*- coding: utf-8 -*-
"""whisper-warm-test.py — 本地常驻 whisper 助手 (第六十三轮) 的纯桩回归。

不装 faster-whisper、不载模型、不起真进程、不联网: 把 `voice.subprocess.Popen` 换成**照抄真管道语义**的
假进程, 然后驱动 `voice._WhisperSrv` 整套状态机 (起进程 / READY / 一问一答 / 超时 / 崩溃重试 / 重启)。

桩不能比真的更宽容 (§43 ④ 的教训: 第五十三轮那个假 icon `return True`, 比真 pystray 宽松, 于是漏掉了真回归):
  * 假 stdout 绝不能"没数据就立刻 StopIteration" —— **真管道会一直阻塞**, 这正是 `request()` 里
    "等 0.5s / 查 poll()" 那套逻辑存在的理由;
  * 进程被 kill 之后, 假 stdin 的 `write()` 必须抛异常 (真的会 BrokenPipeError/ValueError);
  * 只有 kill()/end() 之后 stdout 才 EOF;
  * 假 Popen 收 `env=` 时**不合并** os.environ —— 真 Popen 收到 env 也是整份替换, 所以 voice.py 必须
    自己 `dict(os.environ)` 复制 (漏了的话 PATH 没了, 子进程起不来)。

跑: python wgime-py-pure\\tests\\whisper-warm-test.py      (应输出 ALL OK)
"""
import io
import json
import os
import queue
import sys
import threading
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
_MOD = os.path.dirname(_HERE)                       # wgime-py-pure/
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


# ---------------- 假进程 (照抄真管道语义) ----------------
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
    """假的 stdin: 进程死了再写就报错 (真的会 BrokenPipeError/ValueError)。"""

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
    def __init__(self, argv, kw):
        self.argv = list(argv)
        self.kw = dict(kw)
        self.env = dict(kw.get('env') or {})
        self.pid = id(self) % 100000
        self.rc = None
        self.killed = False
        self.stdin = _FakeIn(self)
        self.stdout = _FakeOut(self)
        self.stderr = _FakeOut(self, ended=True)     # 真进程 stderr 关掉后也是 EOF
        self.written = self.stdin.lines
        self.on_write = None                         # 测试可挂回调, 替代"子进程回答"

    def emit(self, obj):
        self.stdout.push(json.dumps(obj) + '\n')

    def emit_raw(self, s):
        self.stdout.push(s)

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
BOOM = [None]                                        # 非空 = 让下一次 Popen 抛这个异常


def fake_popen(argv, **kw):
    if BOOM[0] is not None:
        raise BOOM[0]
    p = FakeProc(argv, kw)
    PROCS.append(p)
    return p


def last():
    return PROCS[-1] if PROCS else None


def fresh():
    """每个用例一组干净状态 (换掉 _WSRV 单例)。"""
    del PROCS[:]
    voice._WSRV = voice._WhisperSrv()
    return voice._WSRV


voice.subprocess.Popen = fake_popen                 # 就地换成假 Popen

CFG = {'voice_engine': 'whisper', 'stt_model': 'small', 'stt_device': 'cpu',
       'stt_compute': 'int8', 'stt_lang': 'zh', 'stt_prompt': u'\u4ee5\u4e0b\u662f\u666e\u901a\u8bdd\u3002',
       'stt_beam': 5}
WAV = r'C:\tmp\a.wav'


def ask(p, cfg, wav=WAV, resp=None, wait=5.0, nth=1):
    """在后台线程里调 recognize (真的调用就是会阻塞), 主线程按需喂回包。

    返回 (result, 线程是否还活着)。
    """
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


print('0) 桩自检 (先证明桩真的像管道, 否则下面全是空转)')
p0 = FakeProc(['x'], {})
t0 = time.time()
it = iter(p0.stdout)
got = [False]


def _reader():
    for _ln in it:
        got[0] = True


threading.Thread(target=_reader, daemon=True).start()
time.sleep(0.15)
ck('0a 没数据时迭代会阻塞 (不是立刻结束)', not got[0])
p0.emit({'a': 1})
time.sleep(0.15)
ck('0b 来了数据就能读到', got[0])
p0.kill()
ck('0c kill 之后 poll() 非 None', p0.poll() is not None)
try:
    p0.stdin.write('x')
    ck('0d 进程死了再写 stdin 必须报错', False)
except ValueError:
    ck('0d 进程死了再写 stdin 必须报错', True)

print('\nA) 起进程 / 预热 (warm 不能阻塞)')
fresh()
t0 = time.time()
r = voice.warm(CFG)
dt = (time.time() - t0) * 1000
p = last()
ck('A1 warm() 返回 True', r is True)
ck('A2 warm() 立刻返回, 不等 READY', dt < 500 and voice._WSRV.ready is False, '(%.0f ms)' % dt)
ck('A3 真的起了进程', p is not None and p.poll() is None)
ck('A4 命令行只有引导脚本 (源码不进命令行)', p.argv[1:] == ['-u', '-c', voice._WSRV_BOOTSTRAP]
   and len(p.argv[3]) < 400 and 'faster_whisper' not in p.argv[3])
ck('A5 源码走环境变量, 且与内嵌的一致', p.env.get(voice._WSRV_SRC_ENV) == voice._WSRV_SRC)
ck('A6 选项走环境变量 JSON', json.loads(p.env[voice._WSRV_OPTS_ENV])
   == {'model': 'small', 'device': 'cpu', 'compute': 'int8'})
ck('A7 env 是复制过的 (没丢掉宿主环境)',
   p.env is not os.environ and 'PATH' in p.env and 'PATH' in os.environ)
ck('A8 用了 CREATE_NO_WINDOW (不弹黑框)', p.kw.get('creationflags') == voice.CREATE_NO_WINDOW)
t0 = time.time()
ck('A9 同 key 再 warm 不重启', voice.warm(CFG) is True and last() is p
   and (time.time() - t0) < 0.5)
for eng in ('system', 'cmd', 'http', ''):
    ck('A10 warm() 对 %r 不动手' % eng, voice.warm(dict(CFG, voice_engine=eng)) is False)
voice._WSRV.started = 0.0
r = voice._WSRV.ensure(dict(CFG, stt_lang='en'))          # 语言不进 key -> 不该重启
ck('A11 换 stt_lang 不重启 (语言是每次请求带的)', r is True and last() is p)
voice._WSRV.started = 0.0
r = voice._WSRV.ensure(dict(CFG, stt_model='base'))       # 模型进 key -> 必须重启
ck('A12 换 stt_model 必须重启', r is True and last() is not p and p.poll() is not None)
voice._WSRV.started = 0.0
q_before = voice._WSRV.q
r = voice._WSRV.ensure(dict(CFG, stt_model='base'))       # 同 key 且进程活着
ck('A13 同 key 复用不换队列', r is True and voice._WSRV.q is q_before)

print('\nB) READY / 初始化失败')
fresh()
voice.warm(CFG)
p = last()
p.emit({'ready': True, 'model': 'small', 'boot_ms': 1234})
res, alive = ask(p, CFG, resp={'ok': True, 'text': u'\u4f60\u597d', 'ms': 9, 'segs': 1})
ck('B1 READY 之后正常识别', res == (u'\u4f60\u597d', None), repr(res))
ck('B2 boot_ms 被记下', voice._WSRV.boot_ms == 1234)
ck('B3 ready 置位', voice._WSRV.ready is True)
fresh()
voice.warm(CFG)
p = last()
p.emit({'ready': False, 'error': 'faster_whisper \u4e0d\u53ef\u7528 (ImportError: no module)'})
res, alive = ask(p, CFG, wait=3.0)
ck('B4 初始化失败要报助手给的原因', res and res[1] and 'faster_whisper' in res[1], repr(res))
ck('B5 初始化失败带配置提示', res and res[1] and 'stt_python' in res[1])
ck('B6 初始化失败计一次失败', voice._WSRV.fail == 1)
ck('B7 失败后进程被收掉 (不留半死进程)', p.poll() is not None)

print('\nC) 一问一答的边角')
fresh()
voice.warm(CFG)
p = last()
p.emit({'ready': True, 'model': 'small', 'boot_ms': 1})
res, _ = ask(p, CFG, resp={'ok': True, 'text': u'', 'ms': 1, 'segs': 0})
ck('C1 空文本不是错误', res == (u'', None), repr(res))
req = json.loads(p.written[0])
ck('C2 请求字段齐', req['wav'] == WAV and req['lang'] == 'zh' and req['beam'] == 5,
   repr(req))
ck('C3 中文 prompt 在协议里是 ASCII 转义 (不受子进程代码页影响)',
   '\\u' in p.written[0] and all(ord(ch) < 128 for ch in p.written[0]), repr(p.written[0][:80]))
ck('C4 请求以换行结尾 (JSONL)', p.written[0].endswith('\n'))
# 串包: 先回一个 id 不对的, 再回正确的那条
box = {}
th = threading.Thread(target=lambda: box.update(r=voice.recognize(WAV, CFG)), daemon=True)
th.start()
while not p.written[1:2]:
    time.sleep(0.005)
rid = json.loads(p.written[1])['id']
p.emit({'id': rid + 99, 'ok': True, 'text': u'\u4e32\u5305', 'ms': 1})
time.sleep(0.1)
ck('C5 id 不符的回包被丢掉 (还没返回)', th.is_alive())
p.emit({'id': rid, 'ok': True, 'text': u'\u6b63\u786e', 'ms': 2, 'segs': 1})
th.join(3)
ck('C6 拿到自己那条', box.get('r') == (u'\u6b63\u786e', None), repr(box.get('r')))
# 助手中途崩溃 (识别进行中被杀): 要报"退出", 不能静默成空结果
box = {}
th = threading.Thread(target=lambda: box.update(r=voice.recognize(WAV, CFG)), daemon=True)
th.start()
while not p.written[2:3]:
    time.sleep(0.005)
p.kill()
th.join(3)
ck('C7 助手在识别中崩溃要报错 (不是空结果)',
   box.get('r') and box['r'][1] and u'\u9000\u51fa' in box['r'][1], repr(box.get('r')))
ck('C8 崩溃计一次失败', voice._WSRV.fail == 1, 'fail=%d' % voice._WSRV.fail)

print('\nD) 超时')
fresh()
voice.warm(CFG)
p = last()
p.emit({'ready': True, 'model': 'small', 'boot_ms': 1})
_old = voice.WSRV_TIMEOUT
_oldc = voice.WSRV_TIMEOUT_COLD
voice.WSRV_TIMEOUT = 0.4
# 注意: READY 是**排在队列里**等 request() 去消费的, 所以此刻 self.ready 还是 False
# (= 这一次仍按"冷启动"给的宽松上限)。这是有意的保守: 真机上载模型确实可能还没完。
voice.WSRV_TIMEOUT_COLD = 0.4
t0 = time.time()
res, _ = ask(p, CFG, wait=3.0)
voice.WSRV_TIMEOUT = _old
voice.WSRV_TIMEOUT_COLD = _oldc
ck('D1 超时要报超时 (不无限等)', res and res[1] and u'\u8d85\u65f6' in res[1], repr(res))
ck('D2 真的按时返回了 (0.4s 量级)', (time.time() - t0) < 2.0, '%.2fs' % (time.time() - t0))

print('\nE) 连续失败 3 次就停手 (别每次按键起一个 python)')
fresh()
BOOM[0] = FileNotFoundError(2, 'The system cannot find the file specified')
errs = []
for _i in range(3):
    voice._WSRV.started = 0.0
    _t, err = voice.recognize(WAV, dict(CFG, stt_python=r'C:\no\python.exe'))
    errs.append(err)
ck('E1 每次都能报出"启动失败"', all(e and u'\u542f\u52a8\u672c\u5730 whisper' in e for e in errs),
   repr(errs[-1]))
ck('E2 失败计数累到 3', voice._WSRV.fail == 3, 'fail=%d' % voice._WSRV.fail)
BOOM[0] = None
voice._WSRV.started = 0.0
ck('E3 三次之后不再 spawn', voice._WSRV.ensure(CFG) is False and not PROCS)
_t, err = voice.recognize(WAV, CFG)
ck('E4 报的是"连续起不来"而不是静默', err and u'\u8fde\u7eed' in err, repr(err))

print('\nF) 陈旧错误: 1 秒内换参数重试, 报的必须是**这一次**的错 (守卫1)')
fresh()
BOOM[0] = FileNotFoundError(2, 'The system cannot find the file specified')
voice._WSRV.started = 0.0
_t, errA = voice.recognize(WAV, dict(CFG, stt_python=r'C:\no-A\python.exe'))
_t, errB = voice.recognize(WAV, dict(CFG, stt_python=r'C:\no-B\python.exe'))   # 同 1 秒内 -> 限流
BOOM[0] = None
ck('F1 第一次报"启动失败"', errA and u'\u542f\u52a8\u672c\u5730 whisper' in errA, repr(errA))
ck('F2 第二次不原样重复上一条 (陈旧错误已清)',
   errB != errA and u'\u542f\u52a8\u672c\u5730 whisper' not in (errB or ''), repr(errB))

print('\nG) 重启助手时, 旧读取线程的 EOF 不能落进新队列 (守卫2)')
fresh()
voice.warm(CFG)
pA = last()
pA.emit({'ready': True, 'model': 'small', 'boot_ms': 1})
time.sleep(0.15)
old_q = voice._WSRV.q
voice._WSRV.started = 0.0
ck('G1 换了 key 起了新进程', voice._WSRV.ensure(dict(CFG, stt_model='base')) is True
   and last() is not pA and pA.poll() is not None)
ck('G2 队列换成了新的', voice._WSRV.q is not old_q)
time.sleep(0.3)
newq = list(voice._WSRV.q.queue)
oldq = list(old_q.queue)
ck('G3 新队列里没有 EOF (新助手没被误判成"已退出")',
   not any(o.get('eof') for o in newq), repr(newq))
ck('G4 旧队列确实收到 EOF (证明 G3 不空转)', any(o.get('eof') for o in oldq), repr(oldq))

print('\nH) shutdown')
fresh()
voice.warm(CFG)
p = last()
voice.shutdown()
ck('H1 进程被 kill', p.killed and p.poll() is not None)
ck('H2 状态清空', voice._WSRV.proc is None and voice._WSRV.ready is False)
# 1 秒内不重复 spawn 是**有意**的防风暴限制 (助手秒退时否则每次按键起一个 python)
ck('H3 1 秒内 shutdown 后立刻 warm 会被限流挡住', voice.warm(CFG) is False)
voice._WSRV.started = 0.0
ck('H4 过了 1 秒就重新起得来', voice.warm(CFG) is True and last() is not p)
voice.shutdown()

print('\nI) prewarm_bg (启动预热)')
fresh()
ck('I1 stt_prewarm=0 不预热', voice.prewarm_bg(dict(CFG, stt_prewarm=False)) is False)
ck('I2 非 whisper 引擎不预热', voice.prewarm_bg(dict(CFG, voice_engine='system')) is False)
t0 = time.time()
ck('I3 whisper 引擎会排一个后台预热', voice.prewarm_bg(dict(CFG, stt_prewarm=True), delay=0.05) is True)
ck('I4 排预热本身不阻塞 (<300ms)', (time.time() - t0) < 0.3)
time.sleep(0.4)
ck('I5 后台预热真的把进程起来了', last() is not None)
voice.shutdown()

print('\nJ) recognize() 分派表 (别把 cmd/system/http 弄丢)')
fresh()
seen = []
for nm in ('_system_recognize', '_http_recognize', '_cmd_recognize', '_whisper_recognize'):
    setattr(voice, nm, (lambda n: (lambda w, c: (seen.append(n), (n, None))[1]))(nm))
voice.recognize(WAV, {'voice_engine': 'whisper'})
voice.recognize(WAV, {'voice_engine': 'local'})
voice.recognize(WAV, {'voice_engine': 'faster-whisper'})
voice.recognize(WAV, {'voice_engine': 'warm'})
voice.recognize(WAV, {'voice_engine': 'cmd'})
voice.recognize(WAV, {'voice_engine': 'command'})
voice.recognize(WAV, {'voice_engine': 'http'})
voice.recognize(WAV, {'voice_engine': 'system'})
voice.recognize(WAV, {})
ck('J1 五个别名都走常驻 whisper', seen[:4] == ['_whisper_recognize'] * 4, repr(seen))
ck('J2 cmd/command 仍走外部命令', seen[4:6] == ['_cmd_recognize'] * 2, repr(seen))
ck('J3 http 仍走云端', seen[6] == '_http_recognize')
ck('J4 system/缺省 仍走系统引擎', seen[7:] == ['_system_recognize'] * 2, repr(seen))

print('\nJ5) _wsrv_beam / _wsrv_opts / _wsrv_python 的取值 (手写 cfg 也要吃得下)')
ck('J5a beam 缺省 5', voice._wsrv_beam({}) == 5)
ck('J5b beam 字符串也行', voice._wsrv_beam({'stt_beam': '3'}) == 3)
ck('J5c beam 越界钳住', voice._wsrv_beam({'stt_beam': 99}) == 10 and voice._wsrv_beam({'stt_beam': 0}) == 1)
ck('J5d beam 垃圾值回缺省', voice._wsrv_beam({'stt_beam': 'x'}) == 5 and voice._wsrv_beam({'stt_beam': None}) == 5)
ck('J5e 空模型/设备/精度有缺省', voice._wsrv_opts({}) == {'model': 'small', 'device': 'cpu', 'compute': 'int8'})
ck('J5f stt_python 空 -> 宿主解释器', voice._wsrv_python({}) == sys.executable)
ck('J5g stt_python 指到别的解释器', voice._wsrv_python({'stt_python': r'C:\py\python.exe'})
   == r'C:\py\python.exe')

print('\n%s' % ('ALL OK (%d \u9879)' % N[0] if not FAILS
                else 'FAILED %d/%d: %s' % (len(FAILS), N[0], FAILS)))
sys.exit(1 if FAILS else 0)
