# -*- coding: utf-8 -*-
"""voice-vad-test.py — 语音录音 VAD 回归 (第六十一轮修的真 bug，纯桩、不碰麦克风).

为什么要有它
------------
用户报"按了 Ctrl+Alt+V, 说不到 2 秒就自动停止录音"。真因在自适应阈值:
第五十八轮把阈值写成 `clamp(floor*3.5, 180, 1200)`(floor = 见过的**最小** RMS), 于是

  * "按住热键就说话" —— 开头压根没有一个静音块, floor 是从**说话声**里取的(比如 600),
    thr_abs 被顶到上限 **1200**;
  * 麦克风增益偏热时同理。

而正常说话只有几百~一千出头 —— 于是**说话声自己**被当成"静音", 攒够 silence_ms(默认
1.2s) 就自动收尾。停止时刻 = MIN_MS(400) + 1200 ≈ **1.2~1.6 秒**, 与用户描述完全吻合。

修法: 阈值取**两者较小** —— thr_abs 与 `thr_rel = clamp(peak*0.25, 180, 600)`(peak = 最近
听过的最响块, 每块 ×0.9 慢衰减)。相对项**只会把阈值往下拉**, 所以句子内部换气/弱音节不会
被当成"说完了"; 真静音(接近 0)仍远低于两者, 该停还是停。

跑法:  python wgime-py-pure\\tests\\voice-vad-test.py
"""
import os
import struct
import sys
import threading
import time
import types

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE)

# voice.stop() 的 always-on 诊断会 `import win` —— 换成假的, 既不发日志也不依赖真实 win.py
class FakeWin(types.ModuleType):
    def __init__(self):
        super().__init__('win')
        self.logs = []

    def dfn_always(self, s):
        self.logs.append(s)

    def _dlog(self, s):
        pass

    def __getattr__(self, n):
        return lambda *a, **k: None


WIN = FakeWin()
sys.modules['win'] = WIN

import voice                                                          # noqa: E402

PASS = [0]
FAIL = [0]


def ok(cond, label):
    if cond:
        PASS[0] += 1
        print('  OK   %s' % label)
    else:
        FAIL[0] += 1
        print('  ** FAIL ** %s' % label)


def section(t):
    print('\n--- %s ---' % t)


# ---------------------------------------------------------------- 工具
def pcm(rms, ms=None):
    """造一段 RMS **恰好** 为 rms 的 16bit PCM (±rms 交替 -> RMS = rms, 整数精确)."""
    n = (voice.RATE * (ms or voice.BUF_MS) // 1000) // 2 * 2
    return struct.pack('<%dh' % n, *([rms, -rms] * (n // 2)))


def feed(seq, silence=1.2, max_ms=voice.MAX_MS_DEFAULT):
    """把每块 200ms 的 RMS 序列喂给真的 `Recorder._vad_block`.

    返回 (rec, 触发自动停的块下标 or None, 停止时刻 ms or 总时长).
    """
    r = voice.Recorder(silence=silence, max_ms=max_ms)
    for i, rms in enumerate(seq):
        elapsed = (i + 1) * voice.BUF_MS
        if r._vad_block(rms, elapsed):
            return r, i, elapsed
    return r, None, len(seq) * voice.BUF_MS


print('voice-vad-test: 语音 VAD 回归 (纯桩, 不碰麦克风)')

# ---------------------------------------------------------------- 0 自检
section('0. 测试自检: 造的 PCM 的 RMS 必须精确')
ok(voice._rms(pcm(800)) == 800, '0a pcm(800) 的 RMS 恰为 800')
ok(voice._rms(pcm(0)) == 0, '0b pcm(0) 的 RMS 恰为 0')
ok(voice.peak(pcm(0)) == 0, '0c 全 0 的峰值是 0 (第五十八轮的"纯数字静音"诊断)')

# ---------------------------------------------------------------- A 用户报的场景
section('A. 按住就说话(开头没有静音块) + 句子内部有强弱起伏 -> 绝不能自动停')
# 一个响音节(1400) + 后面都是一千出头的正常说话: 旧公式 thr 顶到 1200 会把它们全判成静音
speech = [1400] + [700, 800, 600, 900, 750] * 4
r, stop_i, t = feed(speech)
ok(stop_i is None, 'A1 全程说话不自动停 (旧公式会在 ~1.2s 停, 停在块 %s)' % stop_i)
ok(r.spoke is True, 'A2 确实被判成"说了话"')
ok(r._thr <= max(180, r._peak // 2),
   'A3 ★ 阈值不变量: 听过说话后 thr(%s) 不得超过峰值(%s)的一半' % (r._thr, r._peak))

section('A2. 变化更剧烈一些的说话(模拟正常中文语调)')
speech2 = [2200, 500, 1200, 400, 1800, 600, 900, 1500, 550, 700] * 3
r, stop_i, t = feed(speech2)
ok(stop_i is None, 'A4 语调起伏大也不自动停 (旧公式必停)')
ok(r._thr <= max(180, r._peak // 2), 'A5 阈值仍满足不变量')

# ---------------------------------------------------------------- B 真静音要停
section('B. 说完话之后真的静下来 -> 该停还是要停')
r, stop_i, t = feed([1400, 900, 900] + [20] * 12)
ok(stop_i is not None, 'B1 触发自动停')
ok(t == 3 * voice.BUF_MS + r.silence_ms,
   'B2 停的时刻 = 说话 600ms + 静音 %dms = %dms (实测 %dms)' % (r.silence_ms, 3 * voice.BUF_MS + r.silence_ms, t))
ok(r.auto_stopped is False, 'B3 _vad_block 本身不改 auto_stopped (由 _on_data 置)')

section('B2. 静音但"没说过话" -> 不能停(否则一按就停)')
r, stop_i, t = feed([20] * 40)
ok(stop_i is None, 'B4 纯静音不自动停(没说过话)')
ok(r.spoke is False, 'B5 spoke 保持 False')

# ---------------------------------------------------------------- C 句内换气
section('C. 句子内部的换气/停顿不能当成"说完了"')
r, stop_i, t = feed([1200, 800, 200, 200, 800, 1200, 900, 300, 900] * 3)
ok(stop_i is None, 'C1 句内 400ms 停顿不触发自动停')

# ---------------------------------------------------------------- D 爆音
section('D. 麦克风开启那一下的爆音, 不能把后面的说话判成静音')
r, stop_i, t = feed([20000, 800, 700, 900, 600, 800, 700, 900, 800, 700])
ok(stop_i is None, 'D1 爆音后正常说话不自动停 (旧公式必停)')
ok(r._thr <= 600, 'D2 爆音也没把阈值抬过 600 (相对项封顶)')

# ---------------------------------------------------------------- E 热麦/噪声
section('E. 麦克风增益偏热(底噪大)时, 说话仍要被判成"说了"')
r, stop_i, t = feed([500] * 40)
ok(r.spoke is True, 'E1 电平 500 在底噪 500 时仍算说话 (旧公式判成静音 -> spoke=False)')
ok(r._thr < 500, 'E2 阈值(%s)必须低于说话电平 500' % r._thr)

section('E2. 很轻的说话也不能丢')
r, stop_i, t = feed([60] + [220] * 20)
ok(r.spoke is True, 'E3 电平 220 / 底噪 60 算说话')
ok(stop_i is None, 'E4 一直在轻轻说话就不该停')

# ---------------------------------------------------------------- F 旋钮
section('F. 配置旋钮')
r, stop_i, t = feed([1400] + [20] * 60, silence=0)
ok(stop_i is None, 'F1 voice_silence=0 -> 只手动结束, 永不自动停')
r, stop_i, t = feed([900] * 10, max_ms=1000)
ok(stop_i == 4 and t == 1000, 'F2 voice_max 到点必停 (块 %s, %sms)' % (stop_i, t))
r, stop_i, t = feed([1400] + [20] * 20, silence=2.0)
ok(t == voice.BUF_MS + 2000, 'F3 voice_silence=2.0 时停得更晚 (%dms)' % t)

# ---------------------------------------------------------------- G 真回调集成
section('G. 走真 `_on_data` 回调(假 winmm): 该收尾时回调 on_auto_stop, 且不再塞缓冲')
class FakeMM(object):
    def __init__(self):
        self.added = 0

    def waveInAddBuffer(self, *a):
        self.added += 1
        return 0

    def __getattr__(self, n):
        return lambda *a, **k: 0


MM = FakeMM()
_orig_mm = voice._mm
voice._mm = lambda: MM
try:
    hits = []
    r = voice.Recorder(silence=1.2, on_auto_stop=lambda: hits.append(1))
    r._lock = threading.RLock()
    buf = pcm(1400)
    hdr = voice.WAVEHDR(ctypes.cast(buf, ctypes.c_void_p), len(buf), len(buf), None, 0, 0, None, None) \
        if False else None
    import ctypes as _ct
    cbuf = _ct.create_string_buffer(pcm(1400), len(pcm(1400)))
    hdr = voice.WAVEHDR(_ct.cast(cbuf, _ct.c_void_p), len(pcm(1400)), len(pcm(1400)), None, 0, 0, None, None)
    hp = _ct.pointer(hdr)
    # 1 块说话 + 6 块静音(1200ms) -> 第 7 次回调应触发收尾
    seq = [1400] + [20] * 6
    for i, rms in enumerate(seq):
        cb2 = _ct.create_string_buffer(pcm(rms), len(pcm(rms)))
        hdr.lpData = _ct.cast(cb2, _ct.c_void_p)
        hdr.dwBytesRecorded = len(pcm(rms))
        r.t0 = time.time() - (i + 1) * voice.BUF_MS / 1000.0
        r._on_data(None, voice.WIM_DATA, None, hp, None)
    ok(r.auto_stopped is True, 'G1 真回调路径上 auto_stopped 被置位')
    ok(len(hits) == 1, 'G2 on_auto_stop 正好被调用一次 (实测 %d)' % len(hits))
    ok(MM.added == len(seq) - 1, 'G3 收尾之后不再把缓冲塞回去 (塞回 %d 次 / 共 %d 块)' % (MM.added, len(seq)))
    ok(len(r.pcm) == len(pcm(1400)) * len(seq), 'G4 PCM 一直累积(不丢音频)')

    section('G2. 全程说话时真回调不该收尾')
    MM2 = FakeMM()
    voice._mm = lambda: MM2
    hits2 = []
    r2 = voice.Recorder(silence=1.2, on_auto_stop=lambda: hits2.append(1))
    r2._lock = threading.RLock()
    seq2 = [1400] + [700, 800, 600, 900, 750] * 4
    for i, rms in enumerate(seq2):
        cb3 = _ct.create_string_buffer(pcm(rms), len(pcm(rms)))
        hdr.lpData = _ct.cast(cb3, _ct.c_void_p)
        hdr.dwBytesRecorded = len(pcm(rms))
        r2.t0 = time.time() - (i + 1) * voice.BUF_MS / 1000.0
        r2._on_data(None, voice.WIM_DATA, None, hp, None)
    ok(hits2 == [], 'G5 一直在说话 -> 不触发收尾 (旧公式这里会触发)')
    ok(MM2.added == len(seq2), 'G6 每块都正常塞回缓冲')
finally:
    voice._mm = _orig_mm

# ---------------------------------------------------------------- H 诊断日志
section('H. 每次录音留一行 always-on 诊断(现场排障靠它)')
r = voice.Recorder(silence=1.2)
r.pcm = pcm(800) * 8
r._floor, r._thr, r._peak, r._blocks, r.spoke = 20, 180, 800, 8, True
r.stop()
line = WIN.logs[-1] if WIN.logs else ''
ok('voice: rec' in line and 'thr=' in line and 'floor=' in line and 'peak=' in line,
   'H1 诊断行含 rec/thr/floor/peak: %s' % line[:90])
ok(str(r._quiet_ms) in line, 'H2 诊断行含静音计数')

# ---------------------------------------------------------------- 汇总
print('\n' + '=' * 60)
print('voice-vad-test: %d 通过, %d 失败 (共 %d 项)' % (PASS[0], FAIL[0], PASS[0] + FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
