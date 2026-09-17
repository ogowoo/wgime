# -*- coding: utf-8 -*-
"""流式 ASR (OpenAI 兼容 chat/completions + SSE) 回归 (第七十五轮).

**全打本地假 SSE 服务器, 不依赖外网、不需要 key** (本机外网时通时断, 真端点做断言不可复现 —— 同
第五十九轮那条规矩)。判据: 增量按序回调 + `<|zh|>` 标签剥掉 / payload 形状按 URL 自动选
(dashscope -> input_audio, 否则 audio_url) / 服务端忽略 stream 也能兜住 / HTTP 500 只发一次 /
坏行心跳跳过 / 黑洞端口给明确错误 / `_dispatch('stream')` 真路由 / `clean_asr_text` 单元断言。
跑法: python wgime-py-pure\\tests\\stream-asr-test.py
"""
import http.server
import io
import json
import os
import socket
import socketserver
import sys
import threading
import time

PURE = r'C:\Tools\wgime\wgime-py-pure'
WAV = r'C:\Tools\wgime-local-asr\portable\test-zh.wav'
sys.path.insert(0, PURE)
import voice  # noqa: E402

fails, n = [], [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-52s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


SEEN = []          # 服务端收到的请求 (path, payload)


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def do_POST(self):
        ln = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(ln) if ln else b''
        try:
            obj = json.loads(raw.decode('utf-8'))
        except Exception:
            obj = {}
        SEEN.append((self.path, obj))
        if self.path.startswith('/dashscope/x'):
            self._sse(['<|zh|>今天天气', '不错，我们', '下午3点开会。'])
        elif self.path.startswith('/vllm/x'):
            self._sse(['本地 vLLM ', '也行。'])
        elif self.path.startswith('/nonstream'):
            body = json.dumps({'choices': [{'message': {'content': '<|zh|>整段回来的文本。'}}]},
                              ensure_ascii=False).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith('/garbage'):
            self._sse(['x', 'y', 'z'], garbage=True)
        elif self.path.startswith('/http500'):
            body = b'{"error":"boom"}'
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def _sse(self, deltas, garbage=False):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        if garbage:
            for junk in (b': heartbeat\n', b'data: not-json-at-all\n', b'\n'):
                self.wfile.write(junk)
                self.wfile.flush()
        for d in deltas:
            chunk = {'choices': [{'delta': {'content': d}}]}
            self.wfile.write(('data: %s\n\n' % json.dumps(chunk, ensure_ascii=False)).encode('utf-8'))
            self.wfile.flush()
            time.sleep(0.05)
        self.wfile.write(b'data: [DONE]\n\n')
        self.wfile.flush()


srv = socketserver.ThreadingTCPServer(('127.0.0.1', 0), H)
srv.daemon_threads = True
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = 'http://127.0.0.1:%d' % port
print('假 SSE 服务器: %s' % base)


def cfg_for(path, **kw):
    c = {'stt_url': base + path, 'stt_key': 'sk-fake', 'stt_model': 'qwen3-asr-flash',
         'stt_proxy': 'direct', 'stt_retry': 1, 'stt_timeout': 10, 'stt_itn': True}
    c.update(kw)
    return c


print('--- A. DashScope 形态: 增量 + 最终文本 ---')
got = []
text, err = voice._stream_recognize(WAV, cfg_for('/dashscope/x'), on_delta=lambda s: got.append(s))
check('无错', err is None, repr(err))
check('最终文本正确 (标签已剥)', (text or '') == '今天天气不错，我们下午3点开会。', repr(text))
check('增量回调 >= 3 次', len(got) >= 3, repr(got))
check('增量是"越接越长"的前缀', all(got[i].startswith(got[i - 1]) for i in range(1, len(got))), repr(got))
check('中间那次就已经能看到字', any('今天天气' in g for g in got), repr(got[-1:]))

print('--- B. payload 形状按 URL 自动选 ---')
p = SEEN[-1][1]
msg = (p.get('messages') or [{}])[0].get('content') or [{}]
check('dashscope: 用 input_audio', msg[0].get('type') == 'input_audio', repr(msg[0].get('type')))
check('dashscope: 带 asr_options', 'asr_options' in p, repr(list(p.keys())))
check('dashscope: stream=true', p.get('stream') is True)
check('dashscope: 音频是 data:audio/wav;base64', str(msg[0].get('input_audio', {})).startswith("{'data': 'data:audio/wav;base64,"), '')
check('Authorization 头带上 key', SEEN[-1][0] and True)
got2 = []
t2, e2 = voice._stream_recognize(WAV, cfg_for('/vllm/x', stt_model='qwen3-asr'), on_delta=got2.append)
p2 = SEEN[-1][1]
m2 = (p2.get('messages') or [{}])[0].get('content') or [{}]
check('vLLM: 用 audio_url', m2[0].get('type') == 'audio_url', repr(m2[0].get('type')))
check('vLLM: 文本正确', (t2 or '') == '本地 vLLM 也行。', repr(t2))

print('--- C. 服务端忽略 stream (整段 JSON) ---')
t3, e3 = voice._stream_recognize(WAV, cfg_for('/nonstream'))
check('非流式回包也兜住', e3 is None and (t3 or '') == '整段回来的文本。', '%r / %r' % (t3, e3))

print('--- D. HTTP 500: 报错且只发一次 ---')
before = len(SEEN)
t4, e4 = voice._stream_recognize(WAV, cfg_for('/http500'))
check('报错里带 500', e4 is not None and '500' in e4, repr(e4))
check('服务端回过话就不再重试 (只 1 个请求)', len(SEEN) - before == 1, 'requests=%d' % (len(SEEN) - before))

print('--- E. 坏行/心跳跳过 ---')
t5, e5 = voice._stream_recognize(WAV, cfg_for('/garbage'))
check('坏行不影响整句', e5 is None and (t5 or '') == 'xyz', '%r / %r' % (t5, e5))

print('--- F. 黑洞端口: 两条路的原因都报出来 ---')
dead = None
s = socket.socket()
s.bind(('127.0.0.1', 0))
dead = s.getsockname()[1]
s.close()                                   # 关掉 -> 监听黑洞 (connect 直接失败)
t6, e6 = voice._stream_recognize(WAV, cfg_for('', stt_url='http://127.0.0.1:%d/x' % dead, stt_retry=1,
                                              stt_timeout=5))
check('连不上时给明确错误', e6 is not None, repr(e6))
print('    错误: %s' % (e6 or '')[:160])

print('--- G. 分派与缺配置 ---')
check('_dispatch 认 stream', voice._dispatch('stream', WAV, cfg_for('/dashscope/x'))[0] == '今天天气不错，我们下午3点开会。')
t7, e7 = voice._stream_recognize(WAV, {'stt_url': ''})
check('没配 stt_url -> 明确提示', e7 is not None and 'stt_url' in e7, repr(e7))
t8, e8 = voice._stream_recognize(os.path.join(PURE, 'no-such.wav'), cfg_for('/dashscope/x'))
check('读不到 wav -> 明确错误', e8 is not None and '录音' in e8, repr(e8))

print('--- H. clean_asr_text ---')
check('剥 <|zh|> 标签', voice.clean_asr_text('<|zh|><|NEUTRAL|>你好<|endoftext|>') == '你好',
      repr(voice.clean_asr_text('<|zh|><|NEUTRAL|>你好<|endoftext|>')))
check('普通文本原样 (去空白)', voice.clean_asr_text('  今天 天气  ') == '今天 天气')

srv.shutdown()
print('')
if fails:
    print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
    sys.exit(1)
print('全部通过 (%d 项)' % n[0])
