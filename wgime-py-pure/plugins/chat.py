# -*- coding: utf-8 -*-
"""纯 Python chat 插件 (relay + MQTT-over-WS, AES-256-CBC 加密, 与 itools-chat 互通).
CODE='lt', NAME='聊天'. run() 在 tkinter 主线程建窗口, 网络走后台线程, UI 经队列回主线程.
"""
import hashlib
import hmac
import os
import queue
import re
import socket
import ssl
import struct
import threading
import time
import tkinter as tk

import wspy

CODE = 'lt'
NAME = '聊天'
DESC = '与 itools-chat (PC/Android) 互通的在线聊天 (纯 Python)'

BROKERS = ['wss://chat.seee.uno', 'wss://broker.hivemq.com:8884', 'wss://broker.emqx.io:8084',
           'wss://test.mosquitto.org:8081', 'ws://broker.hivemq.com:8000']
TOPIC = 'itools/chat/'


# ---------- AES-256-CBC + HMAC-SHA256 (与 itools-chat 字节兼容) ----------
class Crypto:
    def __init__(self, room, key):
        raw = room + ':' + (key or room)
        self.k = hashlib.sha256(raw.encode('utf-8')).digest()

    def enc(self, plain):
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives import padding
        iv = os.urandom(16)
        pad = padding.PKCS7(128).padder()
        pt = pad.update(plain.encode('utf-8')) + pad.finalize()
        c = Cipher(algorithms.AES(self.k), modes.CBC(iv)).encryptor()
        ct = c.update(pt) + c.finalize()
        ivh, cth = iv.hex(), ct.hex()
        mac = hmac.new(self.k, (ivh + ':' + cth).encode('utf-8'), hashlib.sha256).hexdigest()
        return ivh + ':' + cth + ':' + mac

    def dec(self, data):
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives import padding
        try:
            p = data.split(':')
            if len(p) < 3:
                return None
            expect = hmac.new(self.k, (p[0] + ':' + p[1]).encode('utf-8'), hashlib.sha256).hexdigest()
            if expect != p[2]:
                return None
            iv, ct = bytes.fromhex(p[0]), bytes.fromhex(p[1])
            c = Cipher(algorithms.AES(self.k), modes.CBC(iv)).decryptor()
            unp = padding.PKCS7(128).unpadder()
            return (unp.update(c.update(ct) + c.finalize()) + unp.finalize()).decode('utf-8')
        except Exception:
            return None


# ---------- MQTT 3.1.1 framing (QoS0) ----------
def _mq_str(s):
    b = s.encode('utf-8')
    return struct.pack('>H', len(b)) + b


def _mq_frame(typ, body):
    rem = len(body)
    h = bytearray([typ])
    while True:
        b = rem % 128
        rem //= 128
        if rem > 0:
            b |= 0x80
        h.append(b)
        if rem == 0:
            break
    return bytes(h) + body


def _mq_connect(cid):
    return _mq_frame(0x10, _mq_str('MQTT') + bytes([4, 2, 0, 30]) + _mq_str(cid))


def _mq_subscribe(pid, topic):
    return _mq_frame(0x82, struct.pack('>H', pid) + _mq_str(topic) + b'\x00')


def _mq_publish(topic, payload):
    return _mq_frame(0x30, _mq_str(topic) + payload)


# ---------- 插件入口 ----------
_current = None


def run():
    global _current
    _current = ChatUI()
    _current.start()


class ChatUI:
    def __init__(self):
        self.win = None
        self.q = queue.Queue()
        self.state = {'running': False, 'ws': None}
        self.docid = 'py-' + os.urandom(5).hex()
        self.last_ts = {}
        self._sel_broker = BROKERS[0]
        self._broker_btns = []

    def _on_close(self):
        """断网(不销毁窗口, 由 make_window 的 close 负责 destroy)."""
        self.state['running'] = False
        try:
            if self.state['ws']:
                self.state['ws'].close()
        except Exception:
            pass

    def _pick_broker(self, i):
        import ui
        self._sel_broker = BROKERS[i]
        for j, b in enumerate(self._broker_btns):
            b.configure(bg=ui.ACCENT if j == i else ui.CARD, fg='white' if j == i else ui.TEXT)

    # ---- UI (规范风: 浅蓝灰底 + 白卡 + 深色控制台 + 圆角 + 自绘标题栏 + flat 按钮) ----
    def start(self):
        import ui
        w, content = ui.make_window('WgIme 聊天', 520, 460, on_close=self._on_close)   # 无边框圆角+自绘标题栏
        self.win = w
        BG, SUB, GREEN = ui.BG, ui.SUB, ui.GREEN
        # 消息区: 深色控制台
        self.msg = ui.console_text(content, 10, 8, 500, 240)
        # 配置行: 昵称 / 房间 / 密钥 (白卡圆角输入)
        for txt, x in (('昵称', 10), ('房间', 140), ('密钥', 270)):
            tk.Label(content, text=txt, bg=BG, fg=SUB, font=ui.font(8.5)).place(x=x, y=254)
        self.nick = ui.rounded_entry(content, 10, 272, 120, 32, initial='User_' + os.urandom(3).hex())
        self.room = ui.rounded_entry(content, 140, 272, 120, 32, initial='T_Fuck')
        self.key = ui.rounded_entry(content, 270, 272, 90, 32)
        # broker 选择: flat 按钮行 + 加入/离开
        for i, b in enumerate(BROKERS):
            nm = b.split('//')[-1].split(':')[0].split('.')[0]   # 中继/hivemq/emqx/mosquitto/broker
            self._broker_btns.append(
                ui.flat_button(content, nm, (lambda i=i: self._pick_broker(i)), x=10 + i * 84, y=312, w=80, h=30))
        self._pick_broker(0)
        self.btn = ui.flat_button(content, '加入', self.toggle, primary=True, x=410, y=312, w=92, h=30)
        # 输入行: 输入框 + 发送
        self.input = ui.rounded_entry(content, 10, 350, 420, 32)
        self.input.bind('<Return>', self.send)
        ui.flat_button(content, '发送', self.send, primary=True, x=436, y=350, w=74, h=32)
        # 状态栏
        self.status = tk.Label(content, text='未连接', bg=BG, fg=SUB, anchor='w', font=ui.font(8.5))
        self.status.place(x=10, y=390, width=220, height=20)
        self.online = tk.Label(content, text='在线 0', bg=BG, fg=GREEN, anchor='e', font=ui.font(8.5))
        self.online.place(x=390, y=390, width=120, height=20)
        self._poll_ui()
        self.users = set()

    def ui(self, fn):
        self.q.put(fn)

    def _poll_ui(self):
        try:
            while True:
                fn = self.q.get_nowait()
                fn()
        except Exception:
            pass
        if self.win.winfo_exists():
            self.win.after(50, self._poll_ui)

    def add_msg(self, text):
        self.msg.configure(state='normal')
        self.msg.insert('end', text + '\n')
        self.msg.configure(state='disabled')
        self.msg.see('end')

    def set_status(self, s):
        self.status.config(text=s)

    # ---- connect ----
    def toggle(self):
        if self.state['running']:
            self.leave()
        else:
            self.join()

    def join(self):
        self.state['running'] = True
        self.btn.config(text='离开')
        self.docid = 'py-' + os.urandom(5).hex()
        # 主线程固化配置 (tkinter 变量跨线程读不安全)
        self.state['nick'] = self.nick.get().strip() or 'User'
        self.state['room'] = self.room.get().strip() or 'T_Fuck'
        self.state['key'] = self.key.get().strip()
        self.state['broker'] = self._sel_broker
        threading.Thread(target=self._net_loop, daemon=True).start()

    def leave(self):
        self.state['running'] = False
        try:
            if self.state['ws']:
                self.state['ws'].close()
        except Exception:
            pass
        self.btn.config(text='加入')
        self.ui(lambda: self.set_status('未连接'))

    def _broker_info(self):
        url = self.state.get('broker', BROKERS[0])
        relay = 'chat.seee.uno' in url
        return url, relay

    def _net_loop(self):
        url, relay = self._broker_info()
        room = self.state['room']
        nick = self.state['nick']
        crypto = Crypto(room, self.state['key'])
        self.ui(lambda: self.set_status('连接中…'))
        try:
            full = url.replace('/', '', 1) if False else url
            if relay:
                ws = wspy.WS()
                ws.connect(url.rstrip('/') + '/room/' + room, subprotocol=None)
            else:
                ws = wspy.WS()
                ws.connect(url.rstrip('/') + '/mqtt', subprotocol='mqtt')
                ws.send_bin(_mq_connect(self.docid))
            self.state['ws'] = ws
            if relay:
                self._send_json(ws, {'type': 'join', 'nick': nick, 'ts': int(time.time() * 1000), 'id': self.docid})
                self.ui(lambda: self.set_status('已连接 (中继)'))
                self._recv_loop(ws, relay, room, nick, crypto)
            else:
                self._mqtt_handshake(ws, room, nick, crypto)
                self._recv_loop(ws, relay, room, nick, crypto)
        except Exception as e:
            self.ui(lambda: self.set_status('连接失败: %s' % e))
            self.ui(lambda: self.btn.config(text='加入'))
            self.state['running'] = False

    def _mqtt_handshake(self, ws, room, nick, crypto):
        # 等 CONNACK (0x20) 最多 8s
        deadline = time.time() + 8
        while time.time() < deadline:
            try:
                op, payload = ws.recv_message()
            except Exception:
                raise RuntimeError('no CONNACK')
            self._mq_handle_packet(ws, op, payload, room, nick, crypto, initial=True)
            if self.state.get('joined'):
                return
        raise RuntimeError('CONNACK timeout')

    def _recv_loop(self, ws, relay, room, nick, crypto):
        while self.state['running']:
            try:
                op, payload = ws.recv_message()
            except Exception:
                break
            if relay:
                if op == wspy.OP_TEXT:
                    self._handle_json(ws, payload.decode('utf-8'), relay, room, nick, crypto)
            else:
                self._mq_handle_packet(ws, op, payload, room, nick, crypto)
        if self.state['running']:
            self.ui(lambda: self.set_status('已断开'))
            self.ui(lambda: self.btn.config(text='加入'))
            self.state['running'] = False

    def _mq_handle_packet(self, ws, op, payload, room, nick, crypto, initial=False):
        if op != wspy.OP_BIN:
            return
        pos = 0
        while pos + 2 <= len(payload):
            head = payload[pos]
            typ = head & 0xF0
            i = pos + 1
            rem = 0
            shift = 0
            for _ in range(4):
                b = payload[i]
                rem |= (b & 0x7F) << shift
                shift += 7
                i += 1
                if not (b & 0x80):
                    break
            if i + rem > len(payload):
                break
            body = payload[i:i + rem]
            if typ == 0x20:                       # CONNACK
                if body[1] == 0:
                    self.state['joined'] = True
                    ws.send_bin(_mq_subscribe(1, TOPIC + room))
                    self._send_json(ws, {'type': 'join', 'nick': nick, 'ts': int(time.time() * 1000), 'id': self.docid})
                    self.ui(lambda: self.set_status('已连接 (MQTT)'))
            elif typ == 0x30:                     # PUBLISH
                tl = struct.unpack('>H', body[:2])[0]
                topic = body[2:2 + tl].decode('utf-8')
                self._handle_json(ws, body[2 + tl:].decode('utf-8'), False, room, nick, crypto)
            pos = i + rem

    # ---- helpers ----
    def _send_json(self, ws, obj):
        s = json_dumps(obj)
        if ws is None:
            return
        if 'chat.seee.uno' in self.state.get('broker', ''):
            ws.send_text(s)
        else:
            ws.send_bin(_mq_publish(TOPIC + self.state.get('room', ''), s.encode('utf-8')))

    def send(self, _ev=None):
        text = self.input.get()
        if not text.strip():
            return
        self.input.delete(0, 'end')
        nick = self.nick.get().strip() or 'User'
        self.add_msg('%s  %s' % (nick, text))
        crypto = Crypto(self.room.get().strip(), self.key.get().strip())
        enc = crypto.enc(text)
        self._send_json(self.state['ws'], {'type': 'chat', 'nick': nick, 'text': enc, 'enc': True,
                                           'ts': int(time.time() * 1000), 'id': self.docid})

    def _handle_json(self, ws, raw, relay, room, nick, crypto):
        try:
            d = json_loads(raw)
        except Exception:
            return
        t = d.get('type')
        rid = d.get('id')
        rnick = d.get('nick')
        if rid == self.docid:
            return
        if t == 'join':
            if rnick:
                self.users.add(rnick)
                self.ui(lambda: self.add_msg('· %s 加入了' % rnick))
                self.ui(self._update_online)
                self._send_json(ws, {'type': 'online', 'nick': nick, 'ts': int(time.time() * 1000), 'id': self.docid})
        elif t == 'leave':
            if rnick:
                self.users.discard(rnick)
                self.ui(lambda: self.add_msg('· %s 离开了' % rnick))
                self.ui(self._update_online)
        elif t == 'online':
            if rnick:
                self.users.add(rnick)
                self.ui(self._update_online)
        elif t == 'chat':
            text = crypto.dec(d.get('text', ''))
            if text is None:
                text = '[encrypted]'
            self.ui(lambda: self.add_msg('%s  %s' % (rnick or '?', text)))

    def _update_online(self):
        self.online.config(text='在线 %d' % len(self.users))


def json_dumps(obj):
    import json
    return json.dumps(obj, ensure_ascii=False)


def json_loads(s):
    import json
    return json.loads(s)
