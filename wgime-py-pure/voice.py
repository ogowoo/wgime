# -*- coding: utf-8 -*-
"""voice.py — 语音输入 (第四十七轮): 录音 + 识别, 四条后端共用一个入口。

分工:
  * **录音**: Windows `winmm` 的 waveIn (纯 ctypes, 零依赖), 16kHz/单声道/16bit;
    边录边算 RMS 做**静音自动停**(VAD) 与"安静时长的上限", 主线程只负责开始/收尾。
  * **识别**: `recognize(wav, cfg)` 按 `voice_engine` 分派 ——
      - `system`: **系统自带离线引擎** (System.Speech, 走 powershell -EncodedCommand 内联脚本,
        不落任何文件; 按 `voice_lang` 选识别引擎, 没装对应语言包会明确报错);
      - `http`:   云端/自建 STT (OpenAI Whisper 兼容的 multipart POST, 配 `stt_url`/`stt_key`);
      - `whisper`: **常驻本地 faster-whisper 助手** (第六十三轮): 模型只载一次, 之后每句
        3~5s; 源码经环境变量交给子进程, JSONL 走 stdin/stdout (见本文件"识别后端 4");
      - `cmd`:    外部命令 (如 whisper.cpp 的 whisper-cli): `stt_cmd` 里用 `{wav}` 占位, 取 stdout。
  * 四条后端共用录音/上屏, 以后换引擎只改 recognize() 里那一个分支 (接口预留)。

不依赖第三方库: 只用 stdlib (ctypes/wave/subprocess/urllib/base64/json/threading/queue)。
`whisper` 后端是唯一例外 —— 它**在子进程里**用宿主的 `faster_whisper`, 本模块自己不 import 它。
"""
import base64
import collections
import ctypes
import json
import locale
import os
import queue
import struct
import subprocess
import sys
import threading
import time
import urllib.error            # 识别后端 2 用 (模块级导入: except 子句里要能直接引用 urllib.error)
import urllib.request
import wave
from ctypes import wintypes

# ---------------- winmm: 录音 ----------------
WAVE_MAPPER = 0xFFFFFFFF                    # (UINT)-1: 用系统默认输入设备
CALLBACK_FUNCTION = 0x00030000
WAVE_FORMAT_PCM = 1
WIM_DATA = 0x03C0                           # MM_WIM_DATA
WIM_OPEN, WIM_CLOSE = 0x03BE, 0x03BF
MMSYSERR_NOERROR = 0
CREATE_NO_WINDOW = 0x08000000

RATE = 16000                                # 语音识别够用 (16k 单声道, 1 秒 = 32KB)
BITS = 16
CHANNELS = 1
BUF_MS = 200                                # 每块 200ms
NBUF = 8                                    # 8 块轮转 (1.6s 缓冲), 回调里取走再塞回去
MIN_MS = 400                                # 短于这个时长不当一次有效录音
MAX_MS_DEFAULT = 20000


class WAVEFORMATEX(ctypes.Structure):
    _fields_ = [('wFormatTag', wintypes.WORD), ('nChannels', wintypes.WORD),
                ('nSamplesPerSec', wintypes.DWORD), ('nAvgBytesPerSec', wintypes.DWORD),
                ('nBlockAlign', wintypes.WORD), ('wBitsPerSample', wintypes.WORD),
                ('cbSize', wintypes.WORD)]


class WAVEHDR(ctypes.Structure):
    _fields_ = [('lpData', ctypes.c_void_p), ('dwBufferLength', wintypes.DWORD),
                ('dwBytesRecorded', wintypes.DWORD), ('dwUser', ctypes.c_void_p),
                ('dwFlags', wintypes.DWORD), ('dwLoops', wintypes.DWORD),
                ('lpNext', ctypes.c_void_p), ('reserved', ctypes.c_void_p)]


_WAVEINPROC = ctypes.WINFUNCTYPE(None, ctypes.c_void_p, wintypes.UINT, ctypes.c_void_p,
                                 ctypes.POINTER(WAVEHDR), ctypes.c_void_p)

_winmm = None


def _mm():
    global _winmm
    if _winmm is None:
        _winmm = ctypes.WinDLL('winmm')
        _winmm.waveInGetNumDevs.restype = wintypes.UINT
        _winmm.waveInOpen.argtypes = [ctypes.POINTER(ctypes.c_void_p), wintypes.UINT,
                                      ctypes.POINTER(WAVEFORMATEX), ctypes.c_void_p,
                                      ctypes.c_void_p, wintypes.DWORD]
        _winmm.waveInPrepareHeader.argtypes = [ctypes.c_void_p, ctypes.POINTER(WAVEHDR), wintypes.UINT]
        _winmm.waveInUnprepareHeader.argtypes = [ctypes.c_void_p, ctypes.POINTER(WAVEHDR), wintypes.UINT]
        _winmm.waveInAddBuffer.argtypes = [ctypes.c_void_p, ctypes.POINTER(WAVEHDR), wintypes.UINT]
        for _f in ('waveInStart', 'waveInStop', 'waveInReset', 'waveInClose'):
            getattr(_winmm, _f).argtypes = [ctypes.c_void_p]
    return _winmm


def available():
    """有没有输入设备 (没有就把 voice 功能报错掉, 别静默失败)."""
    try:
        return _mm().waveInGetNumDevs() > 0
    except Exception:
        return False


def mic_consent():
    """Windows 麦克风隐私开关: 'Deny'/'Allow'/(None=读不到).

    这个和"设备在不在"是两件事: 设备在、但隐私开关是 Deny 时, waveInOpen 会直接失败
    (rc=1)。用户看到的往往是"明明有麦克风却说打不开", 所以单独读出来告诉他去开哪一项。
    """
    try:
        import winreg
        k = r'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
        for root in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
            try:
                with winreg.OpenKey(root, k) as h:
                    v = winreg.QueryValueEx(h, 'Value')[0]
                    if v:
                        return str(v)
            except OSError:
                continue
    except Exception:
        pass
    return None


def mic_hint():
    """打不开麦克风时给一句能照做的话."""
    c = mic_consent()
    if c and c.lower() == 'deny':
        return ('Windows 麦克风隐私开关是"拒绝" —— 打开 设置→隐私和安全性→麦克风→'
                '"允许桌面应用访问麦克风" 后重试')
    return ('检查: ① 有没有麦克风 ② 设置→隐私和安全性→麦克风→允许桌面应用访问麦克风 '
            '③ 是否被别的程序独占')


def _rms(pcm):
    """一段 16bit PCM 的 RMS (不用 audioop: 3.13 起已移除)."""
    n = len(pcm) // 2
    if n <= 0:
        return 0
    import array
    a = array.array('h')
    a.frombytes(pcm[:n * 2])
    s = 0
    for v in a:
        s += v * v
    return int((s / n) ** 0.5)


def peak(pcm):
    """一段 16bit PCM 的峰值 (0 = 设备给的是**纯数字静音**, 第五十八轮诊断用).

    RMS 会被"整体偏小但确实有波形"和"整段全 0"两种情况混在一起; 峰值能一眼分开:
    全 0 -> 输入设备被静音/选错设备 (不是用户说话太轻)。
    """
    n = len(pcm) // 2
    if n <= 0:
        return 0
    import array
    a = array.array('h')
    a.frombytes(pcm[:n * 2])
    try:
        return max(max(a), -min(a))
    except ValueError:
        return 0


class Recorder(object):
    """一次录音会话. 用法: r = Recorder(...); r.start(); ...; pcm = r.stop()"""

    def __init__(self, silence=1.2, max_ms=MAX_MS_DEFAULT, on_auto_stop=None):
        self.silence_ms = int(max(0.0, silence) * 1000)     # 连续静音多久自动停 (0=不自动停)
        self.max_ms = int(max_ms or MAX_MS_DEFAULT)
        self.on_auto_stop = on_auto_stop                    # 由录音线程调用的"请收尾"通知 (只置标志)
        self.err = None
        self.pcm = b''
        self.t0 = time.time()
        self.auto_stopped = False                           # VAD/超时触发
        self.spoke = False                                  # VAD 认为有人说话 (主线程读, 判定"没说就丢")
        self._h = None
        self._cb = None
        self._hdrs = []
        self._bufs = []
        self._lock = None
        self._running = False
        self._spoke = False
        self._quiet_ms = 0
        self._noise = []
        self._floor = None                                  # 自适应底噪 (第五十八轮, 见 _vad_block)
        self._peak = 0                                      # 最近听过的最响块 (慢衰减, 第六十一轮修)
        self._thr = 0
        self._blocks = 0

    # -- 内部: 单块 VAD 判决 (第六十一轮拆出来, 便于 headless 回归) --
    def _vad_block(self, r, elapsed):
        """吃一个块的 RMS, 更新阈值/静音计数; 返回 True = "该收尾了".

        阈值取**两者较小**:
          thr_abs = clamp(floor * 3.5, 180, 1200)     floor = 见过的最小 RMS (min 跟踪)
          thr_rel = clamp(peak  * 0.25, 180, 600)     peak  = 最近听过的最响块 (每块 ×0.9 慢衰减)
          thr     = min(thr_abs, thr_rel)

        **为什么必须取 min（第六十一轮修的真 bug）**: 第五十八轮只留了 thr_abs, 于是
          - "按住热键就说话"(开头压根没有一个静音块) -> floor 是从**说话声**里取的
            (比如 400) -> thr_abs 被顶到上限 **1200**;
          - 麦克风增益偏热时同理。
        而正常说话只有几百~一千出头, 于是**说话声自己**被判成"静音", 攒够 silence_ms
        (默认 1.2s) 就自动收尾 —— 用户实测"按了 Ctrl+Alt+V, 说不到 2 秒就自动停"
        (MIN_MS 400 + 1200 ≈ 1.2~1.6s, 与现象吻合)。
        相对项**只会把阈值往下拉**(取 min, 且上限 600), 所以:
          - 句子内部的换气/弱音节不会再被当成"说完了";
          - 真静音(接近 0)仍远低于两者 -> 该停还是停;
          - 反过来"噪声大的房间"里噪声会被当成说话 -> **不会**自动停(宁可不停:
            用户本来就是松开热键结束, 而 voice_silence=0 可以彻底关掉自动停)。
        峰值用"×0.9 慢衰减"是为了让麦克风开启那一下的爆音(峰值可能上万)不会长期抬高阈值;
        再叠上 600 的上限, 爆音也压不垮说话声。

        别改回"只留 thr_abs": 那是第五十八轮那版, 会把说话判成静音。
        """
        self._blocks += 1
        if self._floor is None or r < self._floor:
            self._floor = r
        self._peak = r if r > self._peak else int(self._peak * 0.9)
        thr_abs = min(1200, max(180, int(self._floor * 3.5)))
        thr_rel = min(600, max(180, int(self._peak * 0.25)))
        thr = min(thr_abs, thr_rel)
        self._thr = thr
        if r >= thr:
            self.spoke = True
            self._spoke = True
            self._quiet_ms = 0
        else:
            self._quiet_ms += BUF_MS
        if elapsed >= self.max_ms:
            return True
        return bool(self.silence_ms and self._spoke and elapsed >= MIN_MS
                    and self._quiet_ms >= self.silence_ms)

    # -- 内部: 音频回调 (winmm 自己的线程) --
    def _on_data(self, hwi, msg, inst, hdr_p, reserved):
        try:
            if msg != WIM_DATA:
                return
            hdr = hdr_p.contents
            n = int(hdr.dwBytesRecorded)
            if n <= 0:
                return
            data = ctypes.string_at(hdr.lpData, n)
            with self._lock:
                self.pcm += data
                elapsed = (time.time() - self.t0) * 1000.0
                want = self._vad_block(_rms(data), elapsed)
                if want and not self.auto_stopped:
                    self.auto_stopped = True
                    if self.on_auto_stop:
                        try:
                            self.on_auto_stop()
                        except Exception:
                            pass
            if not self.auto_stopped:
                _mm().waveInAddBuffer(self._h, hdr_p, ctypes.sizeof(WAVEHDR))   # 塞回去继续录
        except Exception:
            pass

    def start(self):
        """开始录音; 失败返回 False 并把原因写进 self.err."""
        if not available():
            self.err = '没有找到录音设备 (' + mic_hint() + ')'
            return False
        try:
            self._lock = __import__('threading').RLock()
            fmt = WAVEFORMATEX(WAVE_FORMAT_PCM, CHANNELS, RATE, RATE * CHANNELS * BITS // 8,
                               CHANNELS * BITS // 8, BITS, 0)
            h = ctypes.c_void_p()
            cb = _WAVEINPROC(self._on_data)        # 必须保活: 否则回调指针被回收 -> 崩
            self._cb = cb
            # 回调必须按 C 函数指针传 (ctypes 不会把 WINFUNCTYPE 自动转成 c_void_p)
            rc = _mm().waveInOpen(ctypes.byref(h), WAVE_MAPPER, ctypes.byref(fmt),
                                  ctypes.cast(cb, ctypes.c_void_p), None, CALLBACK_FUNCTION)
            if rc != MMSYSERR_NOERROR:
                # 回调方式打不开时退一步: 先试 CALLBACK_NULL (只为把"设备真能用吗"和
                # "回调传错了吗"区分开), 再把原因写清楚
                h2 = ctypes.c_void_p()
                rc2 = _mm().waveInOpen(ctypes.byref(h2), WAVE_MAPPER, ctypes.byref(fmt),
                                       None, None, 0)
                if rc2 == MMSYSERR_NOERROR:
                    _mm().waveInClose(h2)
                    self.err = 'waveInOpen(回调) 失败 rc=%s, 但设备本身可用 (回调注册问题)' % rc
                else:
                    self.err = ('waveInOpen 失败 (rc=%s, 直连也 rc=%s): %s' % (rc, rc2, mic_hint()))
                return False
            self._h = h
            per = RATE * CHANNELS * BITS // 8 * BUF_MS // 1000
            for _ in range(NBUF):
                buf = ctypes.create_string_buffer(per)
                hdr = WAVEHDR(ctypes.cast(buf, ctypes.c_void_p), per, 0, None, 0, 0, None, None)
                if _mm().waveInPrepareHeader(h, ctypes.byref(hdr), ctypes.sizeof(WAVEHDR)) != 0:
                    self.err = 'waveInPrepareHeader 失败'
                    self.close()
                    return False
                self._bufs.append(buf)
                self._hdrs.append(hdr)
                _mm().waveInAddBuffer(h, ctypes.byref(hdr), ctypes.sizeof(WAVEHDR))
            if _mm().waveInStart(h) != 0:
                self.err = 'waveInStart 失败'
                self.close()
                return False
            self.t0 = time.time()
            self._running = True
            return True
        except Exception as e:
            self.err = '录音异常: %r' % (e,)
            self.close()
            return False

    def elapsed_ms(self):
        return int((time.time() - self.t0) * 1000) if self._running or self.pcm else 0

    def stop(self):
        """停止并返回 PCM (调用后对象不可再用)."""
        h = self._h
        if h:
            try:
                _mm().waveInStop(h)
                _mm().waveInReset(h)               # Reset 会把剩余缓冲通过回调吐回来
                time.sleep(0.06)
            except Exception:
                pass
        self._running = False
        pcm = self.pcm
        # 第六十一轮: 每次录音留一行 **always-on** 诊断 —— 音量/阈值/静音计数是"说不到两秒就自动停"
        # 这类问题的唯一线索(用户机器上没法复现, 只能靠现场的数字)。**不含任何音频内容**。
        try:
            import win as _w
            _w.dfn_always('voice: rec %dms blocks=%d spoke=%s auto_stop=%s floor=%s thr=%s '
                          'peak=%s quiet=%dms silence=%dms'
                          % (int(len(pcm) / float(RATE * CHANNELS * BITS // 8) * 1000), self._blocks,
                             self.spoke, self.auto_stopped, self._floor, self._thr,
                             self._peak, self._quiet_ms, self.silence_ms))
        except Exception:
            pass
        self.close()
        self.pcm = pcm
        return pcm

    def close(self):
        h = self._h
        self._h = None
        if not h:
            return
        for hdr in self._hdrs:
            try:
                _mm().waveInUnprepareHeader(h, ctypes.byref(hdr), ctypes.sizeof(WAVEHDR))
            except Exception:
                pass
        try:
            _mm().waveInClose(h)
        except Exception:
            pass
        self._hdrs = []
        self._bufs = []
        self._cb = None


def write_wav(path, pcm, rate=RATE):
    """把 PCM 写成 16bit/单声道 WAV (识别后端都吃 WAV)."""
    w = wave.open(path, 'wb')
    try:
        w.setnchannels(CHANNELS)
        w.setsampwidth(BITS // 8)
        w.setframerate(rate)
        w.writeframes(pcm)
    finally:
        w.close()
    return path


# ---------------- 识别后端 1: 系统自带离线引擎 ----------------
# 内联 PowerShell (经 -EncodedCommand 传, **不落盘任何文件**); 结果用 base64 回传, 免得
# 控制台代码页把中文搞成乱码 (PowerShell 重定向 stdout 用的是 OEM 代码页, 不是 UTF-8)。
_SYS_PS = r'''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
function Out-B64([string]$tag, [string]$s) {
  $b = [System.Text.Encoding]::UTF8.GetBytes($s)
  Write-Output ($tag + ':' + [Convert]::ToBase64String($b))
}
$culture = '__LANG__'
try {
  if ($culture -ne '') {
    $ci = [System.Globalization.CultureInfo]::GetCultureInfo($culture)
    $rec = New-Object System.Speech.Recognition.SpeechRecognitionEngine($ci)
  } else {
    $rec = New-Object System.Speech.Recognition.SpeechRecognitionEngine
  }
} catch {
  Out-B64 'ERRB64' ('no speech engine for [' + $culture + ']: ' + $_.Exception.Message)
  exit 3
}
try {
  $rec.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
  $rec.InitialSilenceTimeout = [TimeSpan]::FromSeconds(6)
  $rec.BabbleTimeout = [TimeSpan]::FromSeconds(4)
  $rec.EndSilenceTimeout = [TimeSpan]::FromSeconds(0.6)
  $rec.SetInputToWaveFile('__WAV__')
  # 第六十二轮: **必须循环取到 null 为止**。`Recognize()` 一次只返回**一段** —— 引擎会按停顿把
  # 一段话切成多段, 以前只取第一段, 于是长句只出来前半截(实测 33 字的话只回 16 字、覆盖率 18%),
  # 用户感受就是"识别率太低"。上限 50 只是防呆(流读完 Recognize 会回 null, 本来就该退出)。
  $parts = New-Object System.Collections.Generic.List[string]
  # 注意: 流读完之后再调 Recognize() **不是返回 $null, 而是抛 "No audio input is supplied"**
  # (实测), 所以循环内必须自己 try 住并 break —— 否则异常冒到外层 catch, 前面收到的几段全丢。
  # 只有**第一次**就抛才是真错误, 留着报出去; 后面抛就是正常的"读完了"。
  $firstErr = $null
  for ($i = 0; $i -lt 50; $i++) {
    try { $r = $rec.Recognize() } catch { if ($i -eq 0) { $firstErr = $_.Exception.Message }; break }
    if (-not $r) { break }
    if ($r.Text) { $parts.Add($r.Text) }
  }
  $sep = if ($culture -like 'zh*' -or $culture -like 'ja*' -or $culture -like 'ko*') { '' } else { ' ' }
  if ($parts.Count -gt 0) {
    Out-B64 'NSEG' ([string]$parts.Count)                 # 段数: 只在 debug 日志里用
    Out-B64 'OKB64' ([string]::Join($sep, $parts))
  } elseif ($firstErr) { Out-B64 'ERRB64' $firstErr } else { Out-B64 'ERRB64' 'no-speech' }
} catch {
  Out-B64 'ERRB64' $_.Exception.Message
  exit 4
} finally {
  if ($rec) { $rec.Dispose() }
}
'''


def _ps_quote(p):
    return p.replace("'", "''")


def _system_recognize(wav, cfg):
    """系统离线引擎 (System.Speech). 返回 (text, err); heard-nothing 时 text='' 且 err=None."""
    lang = (cfg.get('voice_lang') or '').strip()
    script = _SYS_PS.replace('__LANG__', _ps_quote(lang)).replace('__WAV__', _ps_quote(wav))
    enc = base64.b64encode(script.encode('utf-16-le')).decode('ascii')
    if sys.platform != 'win32':
        return None, '系统引擎只在 Windows 上可用'
    exe = 'powershell'
    try:
        p = subprocess.run([exe, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                            '-EncodedCommand', enc],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           creationflags=CREATE_NO_WINDOW, timeout=60)
    except FileNotFoundError:
        return None, '找不到 powershell.exe (系统引擎不可用)'
    except subprocess.TimeoutExpired:
        return None, '系统引擎识别超时'
    except Exception as e:
        return None, '系统引擎调用失败: %r' % (e,)
    out = (p.stdout or b'').decode('utf-8', 'replace')
    errs = (p.stderr or b'').decode('utf-8', 'replace').strip()
    nseg = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith('NSEG:'):                       # 第六十二轮: 段数(只为日志)
            try:
                nseg = int(base64.b64decode(line[5:]).decode('utf-8', 'replace').strip())
            except Exception:
                nseg = None
            continue
        if line.startswith('OKB64:'):
            try:
                txt = base64.b64decode(line[6:]).decode('utf-8', 'replace').strip()
            except Exception:
                return None, '系统引擎返回无法解码'
            try:
                import win as _w
                _w.dfn_always('voice: sys-rec segs=%s chars=%d' % (nseg, len(txt)))
            except Exception:
                pass
            return txt, None
        if line.startswith('ERRB64:'):
            try:
                msg = base64.b64decode(line[7:]).decode('utf-8', 'replace').strip()
            except Exception:
                msg = line[7:]
            if msg == 'no-speech':
                return '', None
            if msg.startswith('no speech engine'):
                return None, ('系统里没有 %s 的语音识别引擎 —— 装一下语言包: '
                              '设置→时间和语言→语言和区域→中文(简体)→语言选项→语音, '
                              '或管理员跑 Add-WindowsCapability -Online -Name '
                              'Language.Speech~~~%s~0.0.1.0' % (lang or '当前语言', lang or 'zh-CN'))
            return None, '系统引擎: ' + msg
    tail = (errs or out or '(无输出)').strip().splitlines()
    return None, '系统引擎无结果: ' + (tail[-1] if tail else '(无输出)')


# ---------------- 识别后端 2: HTTP (云端/自建, OpenAI Whisper 兼容) ----------------
HTTP_TIMEOUT = 30          # 单次尝试超时(秒)的**兜底值**; 实际用 config `stt_timeout` (默认 15)。
                           # 录音只有几十~几百 KB, 识别几秒就好; 这个值就是"代理是黑洞时"回退直连的等待上限
_prefer_direct = [None]    # 自动模式下**记住哪条路是通的** (True=直连 / False=系统代理)
                           # 第六十五轮实测: 本机注册表里那个死代理会**每次都白等 3×timeout**,
                           # 记住之后第二次起直接走通的那条 (第1次 100s -> 之后 2s 级)


def _vlog(msg):
    """always-on 诊断 (与 tray.py 同一套: pythonw 下没有 stderr, 只能写 debug.log)."""
    try:
        import win as _w
        _w.dfn_always(msg)
    except Exception:
        pass


def _http_post(url, body, headers, cfg):
    """发 POST 并返回响应文本; **代理连不上时回退直连** (第五十九轮).

    本机常见坑: 注册表 Internet 设置里留着**已经关掉的本地代理** (Clash/v2ray 的
    `http://127.0.0.1:10808`, 程序关了但设置没清)。`urllib` 默认会读它 -> 每次都
    `ConnectionRefusedError`, 云端识别**永远**失败, 而目标站点其实直连就通
    (实测同一台机器: 直连 -> HTTP 401 "Token is invalid."; 走默认代理 -> 10061 拒绝连接)。
    所以 `auto`(默认) 会先按系统/环境代理试一次, **连不上就换直连重试一次**; 服务端只要
    回过话(401/429/500…)就不再重发, 免得白花一次额度。config `stt_proxy` 可强制:
    `direct`=只用直连 / `http://host:port`=只用这个代理 / 空或 `auto`=先代理后直连。
    全部失败时把**每一条路的原因**一起报出来 (用户一眼能看出是代理挂了还是直连不通)。

    **连接层失败要在同一条路上重试** (第六十五轮; config `stt_retry`, 默认 3 次, 1~8):
    本机到 `api.siliconflow.cn` 实测 **10 次里只有 3 次握手成功** —— 其余是
    `SSLV3_ALERT_BAD_RECORD_MAC` / `EOF occurred in violation of protocol` (中间设备在改 TLS 记录),
    这种**同一秒再试一次就可能成功**, 而"服务端回话"的错误(401/429)重试毫无意义还会白花额度。
    所以判据是: **只重试连接层异常**(URLError/SSLError/OSError/RemoteDisconnected…),
    每次间隔 0.4s; 重试过程写 always-on 日志, 最后报错带上"共试 N 次"。

    **每换一条路都要重建 `Request`** (参数里只收 url/body/headers 的原因): 走代理时
    `OpenerDirector` 会调 `req.set_proxy()` **就地改写 req.host** —— 拿同一个 req 去试直连,
    它会照样连到那个死代理上(实测: 回退那次的错误还是 10061), 等于白回退。
    """
    import urllib.request
    mode = (cfg.get('stt_proxy') or '').strip()
    low = mode.lower()
    if low in ('direct', 'none', 'off'):
        plans = [('直连', False)]
    elif mode and low not in ('auto', 'system'):
        plans = [('指定代理 %s' % mode, {'http': mode, 'https': mode})]
    else:
        plans = [('系统代理', None), ('直连', False)]
        if _prefer_direct[0] is True:                    # 上次直连通了 -> 这次先直连 (省掉代理那段的等待)
            plans.reverse()
        elif _prefer_direct[0] is False:                 # 上次只有代理通 -> 先代理
            pass
    try:
        tries = max(1, min(8, int(cfg.get('stt_retry') or 3)))
    except Exception:
        tries = 3
    try:
        timeout = max(5, min(60, int(cfg.get('stt_timeout') or 15)))
    except Exception:
        timeout = 15
    fails = []
    for label, proxies in plans:
        if proxies is None:
            opener = urllib.request.build_opener()                 # 环境/注册表里那套
        elif proxies is False:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        else:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies))
        for attempt in range(1, tries + 1):
            req = urllib.request.Request(url, data=body, method='POST')   # 每次一个干净请求
            for k, v in headers:
                req.add_header(k, v)
            try:
                with opener.open(req, timeout=timeout) as resp:
                    if fails or attempt > 1:               # 之前失败过 -> 留一条现场证据
                        _vlog('voice: STT ok via %s (第 %d 次尝试; 之前: %s)'
                              % (label, attempt, '; '.join(fails) or '同路重试'))
                    if len(plans) > 1:                     # 自动模式: 记住通的那条, 下次别再白等另一条
                        want = (label == '直连')
                        if _prefer_direct[0] is not want:
                            _prefer_direct[0] = want
                            _vlog('voice: STT 记住可用路径 = %s (下次优先)' % label)
                    return resp.read().decode('utf-8', 'replace')
            except urllib.error.HTTPError:
                raise                                  # 服务端回话了 -> 换路/重试都没意义
            except Exception as e:
                if attempt < tries:
                    _vlog('voice: STT %s 第 %d/%d 次连接失败 (%s), 0.4s 后重试'
                          % (label, attempt, tries, type(e).__name__))
                    time.sleep(0.4)
                    continue
                fails.append('%s (共试 %d 次): %s' % (label, tries, e))
                break
    _vlog('voice: STT all paths failed -> %s' % '; '.join(fails))
    raise RuntimeError('；'.join(fails) or 'STT 请求失败')


def _http_recognize(wav, cfg):
    url = (cfg.get('stt_url') or '').strip()
    if not url:
        return None, 'voice_engine=http 但 config.txt 里没配 stt_url'
    try:
        with open(wav, 'rb') as f:
            data = f.read()
    except OSError as e:
        return None, '读不到录音文件: %r' % (e,)
    boundary = '----wgimevoice%d' % int(time.time() * 1000)
    parts = []

    def field(name, value):
        parts.append(('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n'
                      % (boundary, name, value)).encode('utf-8'))

    parts.append(('--%s\r\nContent-Disposition: form-data; name="file"; filename="voice.wav"\r\n'
                  'Content-Type: audio/wav\r\n\r\n' % boundary).encode('ascii'))
    parts.append(data)
    parts.append(b'\r\n')
    for key, val in (('model', (cfg.get('stt_model') or 'whisper-1')),
                     ('language', (cfg.get('stt_lang') or '')),
                     ('response_format', 'json')):
        if val:
            field(key, val)
    body = b''.join(parts) + ('--%s--\r\n' % boundary).encode('ascii')
    headers = [('Content-Type', 'multipart/form-data; boundary=%s' % boundary)]
    if cfg.get('stt_key'):
        headers.append(('Authorization', 'Bearer ' + cfg['stt_key']))
    try:
        raw = _http_post(url, body, headers, cfg)
    except urllib.error.HTTPError as e:
        # 服务端回话了: 把状态码和响应体一起报出来 (配错 key 时是 "Token is invalid.",
        # 额度用完是 429 ...) —— 以前这里只 `%r` 一下, 用户看到一坨 <HTTPError 401> 没法判断
        try:
            detail = e.read().decode('utf-8', 'replace').strip()[:200]
        except Exception:
            detail = ''
        return None, 'STT 接口返回 HTTP %s: %s' % (e.code, detail or e.reason)
    except Exception as e:
        return None, 'STT 请求失败: %s' % (e,)
    try:
        js = json.loads(raw)
    except Exception:
        return raw.strip(), None                 # 有的自建服务直接返回纯文本
    for path in (('text',), ('result',), ('data', 'text'), ('results', 0, 'text')):
        cur = js
        ok = True
        for k in path:
            try:
                cur = cur[k]
            except Exception:
                ok = False
                break
        if ok and isinstance(cur, str):
            return cur.strip(), None
    return None, 'STT 返回里找不到 text 字段: ' + raw[:200]


# ---------------- 识别后端 3: 外部命令 (本地 whisper 等) ----------------
def _decode_console(b):
    """把子进程输出解成文本。

    第五十二轮: 以前固定 `decode('utf-8')` —— 而**控制台程序按 OEM 代码页输出**(中文机是 936/GBK,
    本模块 305 行给 system 后端走 base64 回传就是为了绕开这件事), 于是中文识别结果全变 `????` /
    `\\ufffd` 而且还当成功上屏。现在: 先试 UTF-8(现代工具/whisper.cpp 都按 UTF-8 输出), 失败后在
    (OEM / ANSI / GBK) 里挑"最像正常文本"的那个 —— cp437 硬解 GBK 会得到一堆 `─║╔╩` 框线字符,
    而按 GBK 解出的是汉字, 用"含多少 CJK、含多少框线"打分即可稳定选对(中文机 OEM=ANSI=936, 三者等价)。
    """
    b = b or b''
    try:
        return b.decode('utf-8')
    except (UnicodeDecodeError, LookupError):
        pass
    cands = []
    for enc in ('oem', 'mbcs', 'gbk'):
        try:
            cands.append(b.decode(enc))
        except (UnicodeDecodeError, LookupError):
            continue

    def score(t):
        cjk = sum(1 for ch in t if u'\u4e00' <= ch <= u'\u9fff')
        box = sum(1 for ch in t if ch in u'\u2500\u2502\u250c\u2510\u2551\u2554\u2569\u2560')
        return (cjk, -box)

    if cands:
        cands.sort(key=score, reverse=True)
        return cands[0]
    return b.decode('utf-8', 'replace')


def _cmd_recognize(wav, cfg):
    cmd = (cfg.get('stt_cmd') or '').strip()
    if not cmd:
        return None, 'voice_engine=cmd 但 config.txt 里没配 stt_cmd (用 {wav} 占位)'
    if '{wav}' not in cmd:
        # 忘写占位时以前会把命令自己的输出当识别结果(**静默成功**), 明确报错更靠谱
        return None, 'stt_cmd 里缺 {wav} 占位 (写成 `你的命令 {wav}`)'
    line = cmd.replace('{wav}', '"%s"' % wav)
    try:
        p = subprocess.run(line, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           creationflags=CREATE_NO_WINDOW, timeout=180)
    except subprocess.TimeoutExpired:
        return None, '外部识别命令超时 (180s)'
    except Exception as e:
        return None, '外部识别命令失败: %r' % (e,)
    out = _decode_console(p.stdout)
    if p.returncode != 0:
        err = _decode_console(p.stderr).strip().splitlines()
        return None, '外部识别命令退出码 %s: %s' % (p.returncode, err[-1] if err else '(无 stderr)')
    for ln in out.splitlines():
        if ln.strip():
            txt = ln.strip().strip('"').strip()      # 有的命令/包装会带一层引号
            if txt:
                return txt, None
    return '', None


# ---------------- 识别后端 4: 常驻 faster-whisper 助手 (本地离线, 第六十三轮) ----------------
# 为什么必须"常驻": 每句新起一个进程跑 whisper, 每次都要重付 **导入 faster_whisper(实测 6.5s)
# + 载模型(实测 9s)** —— 单句 21~22s (见第六十三轮实测); 模型载进一个常驻子进程后, 每句只剩
# 转写本身 (small/int8: 3.0~4.6s), 快 5~7 倍。
#
# 做法完全照 §17 光标跟随 helper 的那套 (别再发明第二种):
#   * 子进程源码经**环境变量** `WGIME_WHISPER_SRC` 传递 —— 不落盘 .py, 也不进进程命令行
#     (命令行只留 ~230 字符的引导), 免得 EDR/任务管理器里挂一条几 KB 的怪异 `-c`;
#   * 引导脚本同样先剥掉 `sys.path` 里的 `''`/`.`/cwd (标准库不被历史残留目录抢占);
#   * stdio 走 **JSONL**: 请求 `{id,wav,lang,prompt,beam}`, 回包 `{id,ok,text,ms}`;
#     文本一律 `ensure_ascii=True` 的 JSON —— 子进程 stdout 的代码页在中文机上会把汉字写成 `?`,
#     JSON 转义成 `\uXXXX` 就完全绕开了代码页 (比 base64 好读, 也比裸 UTF-8 稳);
#   * **父进程一退出(stdin 关闭)子进程自己就结束** —— `quit_app()` 用的是 `os._exit(0)`,
#     不会跑 atexit, 靠的就是这条 EOF 语义, 所以不会留下一个占着几百 MB 的孤儿 python。
#
# 两个锁 (别合成一个): `lock` 只管"起/杀进程"(主线程预热时只碰它, 纳秒级), `rlock` 管一问一答
# (识别线程会持着它等 3~5s, 甚至首句等十几秒的载模型)。合成一个锁的话, 预热调用就会把 Tk 主线程
# 卡在识别期间 —— 打字停摆。
_WSRV_SRC_ENV = 'WGIME_WHISPER_SRC'
_WSRV_OPTS_ENV = 'WGIME_WHISPER_OPTS'
_WSRV_BOOTSTRAP = ("import os,sys\n"
                   "sys.path[:]=[p for p in sys.path if p not in ('','.',os.getcwd())]\n"
                   "exec(compile(os.environ.pop('%s'),'<wgime-whisper-helper>','exec'))\n"
                   % _WSRV_SRC_ENV)
WSRV_TIMEOUT = 120.0            # 已就绪: 单句识别的等待上限(秒)
WSRV_TIMEOUT_COLD = 300.0       # 还没就绪: 要把"载模型"一起等进来
WSRV_MAX_FAIL = 3               # 连续起不来 3 次就不再 spawn (同 §17 helper)
# 认这几个值 = 本地常驻 whisper (与 main._LOCAL_WHISPER_ENGINES 保持一致)
WSRV_ENGINES = ('whisper', 'local', 'faster-whisper', 'faster_whisper', 'warm')
_WSRV_HINT = ('\n本地 whisper 后端需要宿主装了 faster-whisper: `pip install faster-whisper`; '
              '装在了别的解释器上就把 config.txt 的 stt_python 指向它')

# 子进程源码 (经环境变量传; 只 import 标准库 + 宿主的 faster_whisper)
_WSRV_SRC = r'''
import json, os, sys, time

try:
    sys.stdin.reconfigure(encoding='utf-8', errors='replace')
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=True, separators=(',', ':')) + '\n')
    sys.stdout.flush()


def log(msg):
    sys.stderr.write('[whisper-helper] %s\n' % msg)
    sys.stderr.flush()


try:
    opts = json.loads(os.environ.pop('WGIME_WHISPER_OPTS', '{}'))
except Exception:
    opts = {}
if not isinstance(opts, dict):
    opts = {}

try:
    from faster_whisper import WhisperModel
except Exception as exc:
    emit({'ready': False, 'error': 'faster_whisper 不可用 (%s: %s)' % (type(exc).__name__, exc)})
    raise SystemExit(2)

t0 = time.time()
try:
    model = WhisperModel(opts.get('model') or 'small',
                         device=opts.get('device') or 'cpu',
                         compute_type=opts.get('compute') or 'int8')
except Exception as exc:
    emit({'ready': False,
          'error': '载入 whisper 模型失败 (%s: %s)' % (type(exc).__name__, exc)})
    raise SystemExit(3)
emit({'ready': True, 'model': opts.get('model') or 'small',
      'boot_ms': int((time.time() - t0) * 1000)})
log('ready %s in %dms' % (opts.get('model'), int((time.time() - t0) * 1000)))

for line in sys.stdin:                       # 父进程退出 -> EOF -> 这里结束 -> 进程退出
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except Exception:
        continue
    cmd = req.get('cmd')
    if cmd == 'exit':
        break
    if cmd == 'ping':
        emit({'id': req.get('id'), 'ok': True, 'text': '', 'ms': 0})
        continue
    rid = req.get('id')
    path = req.get('wav') or ''
    lang = (req.get('lang') or '').strip() or None
    prompt = (req.get('prompt') or '').strip() or None
    try:
        beam = max(1, min(10, int(req.get('beam') or 5)))
    except Exception:
        beam = 5
    t1 = time.time()
    try:
        segs, info = model.transcribe(path, language=lang, initial_prompt=prompt,
                                      beam_size=beam, condition_on_previous_text=False)
        parts = [s.text for s in segs]
        # CJK 逐段拼接不要空格 (中文没有词间空格); 其它语言补空格
        text = ''.join(parts) if (lang or '').lower() in ('zh', 'ja', 'ko', 'yue') \
            else ' '.join(p.strip() for p in parts)
        emit({'id': rid, 'ok': True, 'text': text.strip(),
              'ms': int((time.time() - t1) * 1000), 'segs': len(parts)})
    except Exception as exc:
        emit({'id': rid, 'ok': False, 'error': '%s: %s' % (type(exc).__name__, exc)})
'''


def _wsrv_opts(cfg):
    """模型/设备/精度 —— 改了这三个键就重启助手 (语言/提示词/beam 是每次请求带的, 不用重启)."""
    return {'model': (cfg.get('stt_model') or '').strip() or 'small',
            'device': (cfg.get('stt_device') or '').strip() or 'cpu',
            'compute': (cfg.get('stt_compute') or '').strip() or 'int8'}


def _wsrv_python(cfg):
    """用哪个解释器跑助手: 缺省就是宿主自己 (单文件分发时 = 用户的 python).

    用户机器上 faster-whisper 常常装在另一个解释器里 -> 用 `stt_python` 指过去。
    """
    return (cfg.get('stt_python') or '').strip() or (sys.executable or 'python')


def _wsrv_beam(cfg):
    # 注意 engine.load_config 已经把 stt_beam 归一成 int 了, 但手写的 cfg(探针/测试)可能是 str/None
    try:
        return max(1, min(10, int(float(cfg.get('stt_beam', 5)))))
    except (TypeError, ValueError):
        return 5


class _WhisperSrv(object):
    """常驻 whisper 助手的父进程侧: 起进程 / 收 READY / 一问一答 / 连续失败计数。"""

    def __init__(self):
        self.lock = threading.Lock()        # 只管起/杀
        self.rlock = threading.Lock()       # 只管一问一答 (串行化并发请求)
        self.proc = None
        self.q = None
        self.errbuf = None
        self.key = None
        self.ready = False
        self.boot_ms = 0
        self.fail = 0
        self.started = 0.0
        self.rid = 0
        self.last_err = ''

    # ---- 进程生命周期 ----
    def _tail_err(self):
        if not self.errbuf:
            return ''
        tail = [t for t in list(self.errbuf)[-3:] if t]
        return (' | stderr: ' + ' / '.join(tail)) if tail else ''

    def _kill_locked(self):
        p, self.proc = self.proc, None
        self.ready = False
        if p is None:
            return
        try:
            if p.poll() is None:
                try:
                    if p.stdin:
                        p.stdin.write('{"cmd":"exit"}\n')
                        p.stdin.flush()
                except Exception:
                    pass
                p.kill()
        except Exception:
            pass

    def shutdown(self):
        with self.lock:
            self._kill_locked()

    def ensure(self, cfg):
        """起进程 (或复用)。**不等待 READY** —— 预热路径要能在主线程上调。"""
        key = (_wsrv_python(cfg),) + tuple(sorted(_wsrv_opts(cfg).items()))
        with self.lock:
            if self.proc is not None and self.proc.poll() is None and self.key == key:
                return True
            if self.fail >= WSRV_MAX_FAIL:
                return False
            if self.key != key:
                # 参数变了 = 这是**新的一次**尝试: 必须把上一次的错清掉, 否则用户改完配置再试,
                # 报的还是改动前那条错误 (实测: 先试了坏 stt_python, 1 秒内再试 cuda, 报出来的
                # 还是 FileNotFoundError —— 用户会以为自己的修改没用)。
                self.last_err = ''
            now = time.monotonic()
            if now - self.started < 1.0:        # 起得太密: 挡一下 (助手秒退时的重试风暴)
                return False
            self._kill_locked()
            self.started = now
            self.key = key
            self.ready = False
            self.boot_ms = 0
            self.last_err = ''
            q = queue.Queue()
            errbuf = collections.deque(maxlen=30)
            self.q = q
            self.errbuf = errbuf
            env = dict(os.environ)
            env[_WSRV_SRC_ENV] = _WSRV_SRC
            env[_WSRV_OPTS_ENV] = json.dumps(_wsrv_opts(cfg), ensure_ascii=True)
            try:
                p = subprocess.Popen([_wsrv_python(cfg), '-u', '-c', _WSRV_BOOTSTRAP],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, encoding='utf-8',
                                     errors='replace', bufsize=1,
                                     creationflags=CREATE_NO_WINDOW, env=env)
            except Exception as e:
                self.last_err = '启动本地 whisper 助手失败: %r' % (e,)
                self.fail += 1
                return False
            self.proc = p
            threading.Thread(target=self._reader, args=(p, q), name='wgime-whisper-out',
                             daemon=True).start()
            threading.Thread(target=self._err_reader, args=(p, errbuf), name='wgime-whisper-err',
                             daemon=True).start()
            _vlog('voice: whisper helper started pid=%d (env-passed source, %d-char cmdline, '
                  'py=%s, model=%s)' % (p.pid, len(_WSRV_BOOTSTRAP), _wsrv_python(cfg),
                                        _wsrv_opts(cfg)['model']))
            return True

    def _reader(self, p, q):
        """收子进程每一行 JSON。**q 必须是参数** —— 重启时 self.q 会被换成新队列,
        用 self.q 会让旧线程的 EOF 落到新队列里 (把刚起的助手误判成"已退出")。"""
        try:
            for line in p.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    q.put(json.loads(line))
                except ValueError:
                    continue
        except Exception:
            pass
        finally:
            try:
                q.put({'eof': True})
            except Exception:
                pass

    def _err_reader(self, p, buf):
        try:
            for line in p.stderr:
                buf.append(line.rstrip()[:300])
        except Exception:
            pass

    def _died(self, why, rc=None):
        self.fail += 1
        with self.lock:
            self._kill_locked()
        return None, '%s%s%s' % (why, (' (rc=%s)' % rc) if rc is not None else '', self._tail_err())

    # ---- 一问一答 ----
    def request(self, cfg, wav):
        """识一句。返回 (text, err)。**只能在识别后台线程里调** (会阻塞数秒)。"""
        cold = not self.ready
        if not self.ensure(cfg):
            if self.fail >= WSRV_MAX_FAIL:
                # 已经不再重试了, 但**真实原因**比"起不来"有用得多, 两条都要给 (别只报"连续失败")
                return None, ('本地 whisper 助手连续 %d 次起不来, 已停止重试'
                              '(改完 config.txt 要重启 WgIme 才重新试)%s%s'
                              % (self.fail,
                                 ('; 上次的错误: ' + self.last_err) if self.last_err else '',
                                 _WSRV_HINT))
            if self.last_err:
                return None, self.last_err + _WSRV_HINT
            return None, '本地 whisper 助手还没就绪, 请再说一次'
        with self.rlock:
            p = self.proc
            q = self.q
            if p is None or p.poll() is not None:
                return self._died('本地 whisper 助手已退出', p.poll() if p else None)
            self.rid += 1
            rid = self.rid
            req = {'id': rid, 'wav': wav,
                   'lang': (cfg.get('stt_lang') or '').strip(),
                   'prompt': (cfg.get('stt_prompt') or '').strip(),
                   'beam': _wsrv_beam(cfg)}
            try:
                p.stdin.write(json.dumps(req, ensure_ascii=True) + '\n')
                p.stdin.flush()
            except Exception as e:
                return self._died('给本地 whisper 助手发请求失败: %r' % (e,))
            limit = WSRV_TIMEOUT_COLD if cold else WSRV_TIMEOUT
            deadline = time.monotonic() + limit
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    return None, ('本地 whisper 识别超时 (%.0fs%s)'
                                  % (limit, ', 首次要把模型载进来' if cold else ''))
                try:
                    o = q.get(timeout=min(left, 0.5))
                except queue.Empty:
                    if p.poll() is not None:
                        return self._died('本地 whisper 助手退出', p.poll())
                    continue
                if o.get('eof'):
                    return self._died('本地 whisper 助手退出', p.poll())
                if o.get('ready') is False:
                    self.fail += 1
                    with self.lock:
                        self._kill_locked()
                    return None, str(o.get('error') or '本地 whisper 助手初始化失败') + _WSRV_HINT
                if o.get('ready'):
                    self.ready = True
                    self.boot_ms = int(o.get('boot_ms') or 0)
                    cold = False
                    self.fail = 0
                    _vlog('voice: whisper helper ready in %dms (model=%s)'
                          % (self.boot_ms, o.get('model')))
                    continue
                if int(o.get('id') or 0) != rid:
                    continue                     # 串包/过期回包: 丢掉继续等自己那条
                if not o.get('ok'):
                    return None, '本地 whisper 识别失败: %s' % (o.get('error') or '?')
                self.fail = 0
                _vlog('voice: whisper %sms segs=%s chars=%d'
                      % (o.get('ms'), o.get('segs'), len(o.get('text') or '')))
                return (o.get('text') or ''), None


_WSRV = _WhisperSrv()


def _whisper_recognize(wav, cfg):
    return _WSRV.request(cfg, wav)


def warm(cfg):
    """预热: 现在就把模型载进来 (异步, 不阻塞调用方)。非本地 whisper 引擎返回 False。"""
    eng = (cfg.get('voice_engine') or '').strip().lower()
    if eng not in WSRV_ENGINES:
        return False
    # 已经起来了/失败太多就什么都不做
    return _WSRV.ensure(cfg)


def prewarm_bg(cfg, delay=4.0):
    """启动时后台预热 (让第一次说话不用先白等载模型)。

    `stt_prewarm = 0` 关掉它: 载 small/int8 要 ~2.3s CPU 与几百 MB 内存, 不是所有机器都想常占。
    `delay` 是为了让启动那几段收尾动作 (插件/托盘/tools) 先跑完再抢 CPU。
    """
    if not cfg.get('stt_prewarm', True):
        return False
    if (cfg.get('voice_engine') or '').strip().lower() not in WSRV_ENGINES:
        return False

    def _bg():
        try:
            time.sleep(max(0.0, float(delay)))
            _WSRV.ensure(cfg)
        except Exception as e:
            _vlog('voice: prewarm failed: %r' % (e,))

    threading.Thread(target=_bg, name='wgime-voice-warm', daemon=True).start()
    return True


def shutdown():
    """退出收尾 (父进程退出时 stdin 关闭也会让助手自己结束, 这里是显式一点)。"""
    try:
        _WSRV.shutdown()
    except Exception:
        pass


def recognize(wav, cfg):
    """(text, err). text='' 表示"听到了但没识别出内容"(不是错误); err 非空表示出错."""
    eng = (cfg.get('voice_engine') or 'system').strip().lower()
    if eng in ('http', 'cloud', 'api'):
        return _http_recognize(wav, cfg)
    if eng in WSRV_ENGINES:                    # 常驻本地 whisper (第六十三轮)
        return _whisper_recognize(wav, cfg)
    if eng in ('cmd', 'command'):
        return _cmd_recognize(wav, cfg)
    return _system_recognize(wav, cfg)
