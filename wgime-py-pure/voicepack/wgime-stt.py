# -*- coding: utf-8 -*-
r"""wgime-stt.py — 给 wgime 的本地离线语音识别后端 (sherpa-onnx + SenseVoice-Small / Paraformer)。

两种用法:

1) **一次性** (config.txt 里 `voice_engine = cmd`) —— 每句重付一次载模型 (~1.3s):
       stt_cmd = python C:\Tools\wgime-local-asr\wgime-stt.py {wav}

2) **常驻 / 服务模式** (config.txt 里 `voice_engine = sherpa`, 每句 0.1~0.2s):
       stt_script = C:\Tools\wgime-local-asr\wgime-stt.py
   由 wgime 自己起: `python -u wgime-stt.py --serve --itn=1 --threads=4 [--lang=zh]`
   * 启动即建识别器(载模型), 完成后在 **stdout** 打一行 JSON: `{"ready": true, "boot_ms": …, "model": …}`
     (建不起来则 `{"ready": false, "error": …}` 并以非 0 退出);
   * 之后每行 stdin 一个请求: `{"id": 7, "wav": "C:\\…\\rec.wav"}`;
     每行 stdout 一个回包: `{"id": 7, "ok": true, "text": "…", "ms": 123, "segs": 1}`
     或 `{"id": 7, "ok": false, "error": "…"}` (**单句失败不退出**, 继续服务下一句);
   * `{"cmd": "exit"}` 或 stdin EOF(= wgime 退出) -> 自己退出。
   协议对端: `wgime-py-pure\voice.py` 的 `_SherpaSrv`(spawn/request_obj) + `_WarmSrv.request()`,
   改这里必须同时看那边(**回包用 `ensure_ascii=True`**: 中文走 \uXXXX 转义, 别依赖对端编码)。

设计约束 (对齐 main/voice.py 的 `_cmd_recognize`):
* 一次性模式下 **stdout 只许打印识别文本** —— 它取"第一行非空输出"当结果, 别的日志一律走 stderr;
* 服务模式下 **stdout 只许打印协议 JSON**, 其它输出一律 stderr;
* 出错时 stdout 不输出(一次性)/打 error 回包(服务), stderr 说明原因, 一次性模式返回非 0;
* 输入是我们录音机写的 16 kHz 单声道 PCM16 WAV; 别的采样率(如 TTS 的 24k)这里自己线性重采样。

模型目录默认取脚本同级的 models/sense-voice (model.int8.onnx + tokens.txt)。
"""
import json
import os
import sys
import time
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MODEL_DIR = os.path.join(HERE, 'models', 'sense-voice')
TARGET_RATE = 16000


def log(msg):
    sys.stderr.write(str(msg) + '\n')


def emit(obj):
    """服务模式的协议回包: 一行一个 JSON (中文转义), 立刻 flush。"""
    sys.stdout.write(json.dumps(obj, ensure_ascii=True) + '\n')
    sys.stdout.flush()


def resample(samples, src_rate, dst_rate=TARGET_RATE):
    """线性重采样 (够用; 语音识别不挑插值质量)."""
    if src_rate == dst_rate or not samples:
        return samples
    n_out = int(len(samples) * dst_rate / float(src_rate))
    out = []
    step = float(src_rate) / dst_rate
    for i in range(n_out):
        pos = i * step
        i0 = int(pos)
        i1 = min(i0 + 1, len(samples) - 1)
        frac = pos - i0
        out.append(samples[i0] * (1.0 - frac) + samples[i1] * frac)
    return out


def read_wav(path):
    with wave.open(path, 'rb') as w:
        ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if sw != 2:
        raise RuntimeError('只支持 16bit WAV (这是 %d bit)' % (sw * 8))
    import array
    a = array.array('h')
    a.frombytes(raw[:len(raw) // 2 * 2])
    samples = list(a)
    if ch > 1:                                  # 多声道 -> 取第一声道
        samples = samples[::ch]
    return samples, sr


def parse_opts(argv):
    """`--k=v` 解析 + 位置参数; **`--serve` 这种无值开关也收进 opts**(值为 True)。"""
    opts, pos = {}, []
    for a in argv[1:]:
        if a.startswith('--'):
            if '=' in a:
                k, v = a[2:].split('=', 1)
                opts[k] = v
            else:
                opts[a[2:]] = True
        else:
            pos.append(a)
    return opts, pos


def _paths(opts):
    model_dir = opts.get('model-dir') or DEFAULT_MODEL_DIR
    model = os.path.join(model_dir, 'model.int8.onnx')
    tokens = os.path.join(model_dir, 'tokens.txt')
    if not os.path.isfile(model):
        raise RuntimeError('找不到模型: %s' % model)
    if not os.path.isfile(tokens):
        raise RuntimeError('找不到 tokens.txt: %s' % tokens)
    return model_dir, model, tokens


def _import_sherpa():
    try:
        import sherpa_onnx
    except Exception as e:
        raise RuntimeError('没装 sherpa-onnx: %r (pip install sherpa-onnx)' % (e,))
    return sherpa_onnx


def _itn_of(opts):
    return str(opts.get('itn', '1')).lower() not in ('0', 'off', 'false', 'no')


def _new_recognizer(sherpa_onnx, model, tokens, opts):
    lang = opts.get('lang') or 'zh'
    itn = _itn_of(opts)
    try:
        threads = max(1, int(opts.get('threads', '4')))
    except Exception:
        threads = 4
    return sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=model, tokens=tokens, num_threads=threads, use_itn=itn,
        language=lang, provider='cpu', debug=False)


def _decode_samples(rec, samples, sr):
    """识别已读进来的采样 (返回 text)。识别失败抛异常。"""
    if not samples:
        raise RuntimeError('空音频')
    if sr != TARGET_RATE:
        samples = resample(samples, sr)
    try:
        import numpy as np
        wave_in = np.array(samples, dtype=np.float32) / 32768.0
    except Exception:
        wave_in = [s / 32768.0 for s in samples]      # 没装 numpy 也能跑 (pybind11 收序列)
    stream = rec.create_stream()
    stream.accept_waveform(TARGET_RATE, wave_in)
    rec.decode_stream(stream)
    return (stream.result.text or '').strip()


def serve(opts):
    """常驻模式: 建一次识别器, 然后按 JSON 行协议一问一答 (见文件头 docstring)。"""
    t0 = time.monotonic()
    try:
        model_dir, model, tokens = _paths(opts)
        sherpa_onnx = _import_sherpa()
        rec = _new_recognizer(sherpa_onnx, model, tokens, opts)
    except Exception as e:
        log('serve: 初始化失败: %s' % (e,))
        emit({'ready': False, 'error': str(e)})
        return 5
    emit({'ready': True, 'boot_ms': int((time.monotonic() - t0) * 1000),
          'model': os.path.basename(model_dir),
          # itn/lang 是**建识别器**的参数 (改了要重启助手); 报出来便于对账 / 与 §D8.3 契约一致
          'itn': _itn_of(opts), 'lang': (opts.get('lang') or 'zh')})
    log('serve: ready (%s)' % model_dir)
    for line in sys.stdin:                    # 父进程退出 = EOF = 自己退
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            log('serve: 请求不是 JSON: %r' % (line[:200],))
            continue
        if not isinstance(req, dict):
            continue
        if req.get('cmd') == 'exit':
            break
        rid = req.get('id')
        if req.get('cmd') == 'ping':
            # 心跳: 助手立刻回一句 (客户端当前不发, 但契约里有 -> 以后拿它探活不用等一句识别)
            emit({'id': rid, 'ok': True, 'text': '', 'ms': 0})
            continue
        wav = req.get('wav')
        if not wav:
            emit({'id': rid, 'ok': False, 'error': '请求里没有 wav'})
            continue
        t1 = time.monotonic()
        try:
            samples, sr = read_wav(wav)
            audio_ms = int(len(samples) * 1000.0 / (sr or 1))
            text = _decode_samples(rec, samples, sr)
            emit({'id': rid, 'ok': True, 'text': text,
                  'ms': int((time.monotonic() - t1) * 1000), 'segs': 1,
                  'audio_ms': audio_ms})       # 报音频长度便于对账 (解码耗时应与它成正比)
        except Exception as e:                # **单句失败不退出**: 继续服务下一句
            log('serve: 识别失败: %s' % (e,))
            emit({'id': rid, 'ok': False, 'error': str(e)})
    return 0


def main(argv):
    opts, pos = parse_opts(argv)
    if opts.get('serve'):
        return serve(opts)
    if not pos and 'wav' not in opts:
        log('用法: wgime-stt.py <录音.wav> [--model-dir=…] [--lang=zh|auto] [--itn=0|1] [--threads=N]')
        log('      wgime-stt.py --serve [--model-dir=…] [--lang=…] [--itn=…] [--threads=…]   # 常驻')
        return 2
    wav = opts.get('wav') or pos[0]

    try:                                       # 返回码与旧版逐条对齐 (调用方只读 stderr, 但别乱改)
        _model_dir, model, tokens = _paths(opts)
    except Exception as e:
        log('%s' % (e,))
        return 3
    try:
        sherpa_onnx = _import_sherpa()
    except Exception as e:
        log('%s' % (e,))
        return 4
    try:
        rec = _new_recognizer(sherpa_onnx, model, tokens, opts)
    except Exception as e:
        log('加载模型失败: %r' % (e,))
        return 5
    try:
        samples, sr = read_wav(wav)
    except FileNotFoundError:
        log('找不到录音文件: %s' % wav)
        return 6
    except Exception as e:
        log('读 WAV 失败: %r' % (e,))
        return 6
    try:
        text = _decode_samples(rec, samples, sr)
    except Exception as e:
        log('识别失败: %r' % (e,))
        return 7
    sys.stdout.write(text + '\n')               # **只**打印文本
    sys.stdout.flush()
    return 0


if __name__ == '__main__':
    os.environ.setdefault('OMP_NUM_THREADS', '2')
    sys.exit(main(sys.argv))
