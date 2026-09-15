# -*- coding: utf-8 -*-
"""voice.py — 语音输入 (第四十七轮): 录音 + 识别, 三条后端共用一个入口。

分工:
  * **录音**: Windows `winmm` 的 waveIn (纯 ctypes, 零依赖), 16kHz/单声道/16bit;
    边录边算 RMS 做**静音自动停**(VAD) 与"安静时长的上限", 主线程只负责开始/收尾。
  * **识别**: `recognize(wav, cfg)` 按 `voice_engine` 分派 ——
      - `system`: **系统自带离线引擎** (System.Speech, 走 powershell -EncodedCommand 内联脚本,
        不落任何文件; 按 `voice_lang` 选识别引擎, 没装对应语言包会明确报错);
      - `http`:   云端/自建 STT (OpenAI Whisper 兼容的 multipart POST, 配 `stt_url`/`stt_key`);
      - `cmd`:    外部命令 (如本地 whisper.cpp/faster-whisper): `stt_cmd` 里用 `{wav}` 占位, 取 stdout。
  * 三条后端共用录音/上屏, 以后换引擎只改 recognize() 里那一个分支 (接口预留)。

不依赖第三方库: 只用 stdlib (ctypes/wave/subprocess/urllib/base64/json)。
"""
import base64
import ctypes
import json
import locale
import os
import struct
import subprocess
import sys
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
  $r = $rec.Recognize()
  if ($r) { Out-B64 'OKB64' $r.Text } else { Out-B64 'ERRB64' 'no-speech' }
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
    for line in out.splitlines():
        line = line.strip()
        if line.startswith('OKB64:'):
            try:
                return base64.b64decode(line[6:]).decode('utf-8', 'replace').strip(), None
            except Exception:
                return None, '系统引擎返回无法解码'
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
HTTP_TIMEOUT = 30          # 单次尝试的超时(秒). 录音只有几十~几百 KB, 识别几秒就好;
                           # 走代理时若代理是"不拒绝也不响应"的黑洞, 这个值就是回退直连的等待上限


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
    不在这里循环重试: 语音是交互操作, 再按一次热键就是最自然的重试。

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
    fails = []
    for label, proxies in plans:
        if proxies is None:
            opener = urllib.request.build_opener()                 # 环境/注册表里那套
        elif proxies is False:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        else:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies))
        req = urllib.request.Request(url, data=body, method='POST')   # 每条路一个干净请求
        for k, v in headers:
            req.add_header(k, v)
        try:
            with opener.open(req, timeout=HTTP_TIMEOUT) as resp:
                if fails:                          # 上一次失败过 -> 留一条现场证据
                    _vlog('voice: STT ok via %s (earlier path failed: %s)' % (label, fails[-1]))
                return resp.read().decode('utf-8', 'replace')
        except urllib.error.HTTPError:
            raise                                  # 服务端回话了 -> 换路也没意义
        except Exception as e:
            fails.append('%s: %s' % (label, e))
            continue
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


def recognize(wav, cfg):
    """(text, err). text='' 表示"听到了但没识别出内容"(不是错误); err 非空表示出错."""
    eng = (cfg.get('voice_engine') or 'system').strip().lower()
    if eng in ('http', 'cloud', 'api'):
        return _http_recognize(wav, cfg)
    if eng in ('cmd', 'command', 'whisper', 'local'):
        return _cmd_recognize(wav, cfg)
    return _system_recognize(wav, cfg)
