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
# 第五十二轮补全 manifest: 没有 PERM 时 plugin_meta 默认 'low' -> 运行"聊天"**不弹联网确认**
# (AGENTS §16 的权限模型对它失效), 插件管理器的"版本"列也一直空着。
VERSION = '2.0.0'
AUTHOR = 'Walt Liang'
PERM = 'network'

BROKERS = ['wss://chat.seee.uno', 'wss://broker.hivemq.com:8884', 'wss://broker.emqx.io:8084',
           'wss://test.mosquitto.org:8081', 'ws://broker.hivemq.com:8000']
TOPIC = 'itools/chat/'
HEALTHY_SEC = 20          # 一次会话稳稳跑过这么久 = 这次真连上了 -> 重连预算清零 (见 _net_loop)
IDLE_DEAD_SEC = 90        # 既没收到数据、保活也没成功过这么久才判"真断开" (见 _recv_loop; 保活 15s 一次)


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
        # 第五十二轮: gen=会话代次(重连期间"离开→加入"会作废旧线程); last_ka=最近一次保活成功时间;
        # joined=本会话是否已完成 CONNACK 握手 (必须每会话复位, 否则重连时收到任意包就算"连上了")
        self.state = {'running': False, 'ws': None, 'manual': False, 'tries': 0,
                      'gen': 0, 'last_ka': 0.0, 'joined': False}
        self.docid = 'py-' + os.urandom(5).hex()
        self.last_ts = {}
        self._sel_broker = BROKERS[0]
        self._broker_btns = []

    def _on_close(self):
        """断网(不销毁窗口, 由 make_window 的 close 负责 destroy)."""
        self.state['running'] = False
        self.state['manual'] = True          # 关窗 = 主动离开: 不重连
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
        self.state['manual'] = False                 # 不是"用户主动离开" -> 掉线可以重连
        self.state['tries'] = 0
        self.state['gen'] = self.state.get('gen', 0) + 1   # 作废上一轮可能还在 sleep 的 _net_loop
        self.state['last_ka'] = 0.0
        self.btn.config(text='离开')
        self.docid = 'py-' + os.urandom(5).hex()
        # 主线程固化配置 (tkinter 变量跨线程读不安全)
        self.state['nick'] = self.nick.get().strip() or 'User'
        self.state['room'] = self.room.get().strip() or 'T_Fuck'
        self.state['key'] = self.key.get().strip()
        self.state['broker'] = self._sel_broker
        self._cfg_enabled(False)                     # 连接期间禁用 昵称/房间/密钥 (对齐 C# Enabled=false)
        threading.Thread(target=self._net_loop, args=(self.state['gen'],), daemon=True).start()

    def _cfg_enabled(self, on):
        """连接期间禁用/恢复 昵称/房间/密钥 三个输入框 (C# chat 连上后把三个框 Enabled=false)。

        不禁用的话: send() 用实时控件值、会话用 join 快照 —— 把房间框清空再发消息, 自己显示正常,
        对端全是 [encrypted] (密钥不一致)。
        """
        st = 'normal' if on else 'disabled'
        for w in (getattr(self, 'nick', None), getattr(self, 'room', None), getattr(self, 'key', None)):
            try:
                w.configure(state=st)
            except Exception:
                pass

    def leave(self):
        # 先发 leave 再关连接 (对齐 C# `if (!lanOnly) SendLeave();`) —— 否则对端"在线 N"永不减少、
        # 也没有"xx 离开了"。
        try:
            if self.state.get('ws') is not None and self.state.get('running'):
                self._send_json(self.state['ws'], {'type': 'leave', 'nick': self.state.get('nick') or '',
                                                   'ts': int(time.time() * 1000), 'id': self.docid})
        except Exception:
            pass
        self.state['running'] = False
        self.state['manual'] = True                  # 主动离开: 不重连 (对齐 C# manualLeave)
        self.state['gen'] = self.state.get('gen', 0) + 1   # 让在飞的 _net_loop 立刻收工
        try:
            if self.state['ws']:
                self.state['ws'].close()
        except Exception:
            pass
        self._cfg_enabled(True)
        self.btn.config(text='加入')
        self.ui(lambda: self.set_status('未连接'))

    def _broker_info(self):
        url = self.state.get('broker', BROKERS[0])
        relay = 'chat.seee.uno' in url
        return url, relay

    def _net_loop(self, gen=None):
        """一次会话 + 掉线重连 (对齐 C# chat 的 OnDisconnected):
        掉线 -> 每 6 秒重试一次, 最多 3 次 ("已断开, 6 秒后重连 (N/3)…"), 用尽则"重连失败, 已断开";
        **连接失败**直接结束 (C# 同理: ConnectWorker 非 auto 分支失败即 UiJoinFailed, 不进重连);
        用户点"离开"/关窗 (manual) 一律不重连。
        重连计数只在"这次会话稳稳跑过 HEALTHY_SEC"后才清零 —— C# 是在 JoinComplete 里清零的,
        那等于"连上就清零", 于是"连上后立刻掉"会无限重试、"重连失败"永远到不了;
        这里改成按会话存活时长清零, 预算才有意义。

        **第五十二轮**: 加会话代次 `gen` —— 在这 6 秒等待期里点"离开"再点"加入"会起第二个 _net_loop,
        而睡着的旧线程醒来时 manual 已被 join() 置回 False, 于是继续 _session(): 两个 WS 会话并存,
        消息显示两遍、对端看到两次"加入"(实测并发峰值 2)。现在代次变了就立刻收工。
        """
        expired = lambda: self.state.get('manual') or (gen is not None and gen != self.state.get('gen'))
        if gen is None:
            gen = self.state.get('gen', 0)       # 直接调用(探针/兼容路径)时以"进入时的代次"为准
        tries = self.state.get('tries', 0)
        while True:
            if expired():
                return
            t0 = time.time()
            ok = self._session()
            lived = time.time() - t0
            if expired():
                return
            if not ok:
                self.ui(lambda: self.btn.config(text='加入'))
                self._cfg_enabled(True)              # 连不上 -> 把 昵称/房间/密钥 放回可编辑
                self.state['running'] = False
                return
            if lived >= HEALTHY_SEC:
                tries = 0                       # 稳定跑过一段 -> 重连预算重置
            self.ui(lambda: self.add_msg('· 连接已断开'))
            if tries >= 3:
                self.ui(lambda: self.set_status('重连失败, 已断开'))
                self.ui(lambda: self.btn.config(text='加入'))
                self._cfg_enabled(True)
                self.state['running'] = False
                return
            tries += 1
            self.state['tries'] = tries
            self.ui(lambda t=tries: self.set_status('已断开, 6 秒后重连 (%d/3)…' % t))
            time.sleep(6)
            if expired():
                return

    def _session(self):
        """建一次连接并跑接收循环. 连上过(跑过接收循环)返回 True, 连接/握手失败返回 False."""
        url, relay = self._broker_info()
        room = self.state['room']
        nick = self.state['nick']
        crypto = Crypto(room, self.state['key'])
        # 第五十二轮: 每个新会话都必须重新等 CONNACK —— joined 不复位时, 第二次会话收到**任意**一个包
        # 就被 _mqtt_handshake 当成"已连上"返回, 而 SUBSCRIBE/join 只在 CONNACK 分支里发 ->
        # UI 显示"已连接 (MQTT)"却既没订阅也没加入, 收不到消息、对端也看不到你。
        self.state['joined'] = False
        self.ui(lambda: self.set_status('连接中…'))
        try:
            if relay:
                ws = wspy.WS()
                ws.connect(url.rstrip('/') + '/room/' + room, subprotocol=None)
            else:
                ws = wspy.WS()
                ws.connect(url.rstrip('/') + '/mqtt', subprotocol='mqtt')
                ws.send_bin(_mq_connect(self.docid))
            self.state['ws'] = ws
            threading.Thread(target=self._keepalive_loop, args=(ws, relay), daemon=True).start()
            if relay:
                self._send_json(ws, {'type': 'join', 'nick': nick, 'ts': int(time.time() * 1000), 'id': self.docid})
                self.ui(lambda: self.set_status('已连接 (中继)'))
                self._recv_loop(ws, relay, room, nick, crypto)
            else:
                self._mqtt_handshake(ws, room, nick, crypto)
                self._recv_loop(ws, relay, room, nick, crypto)
            return True                              # 连上过 -> 这次是"掉线"而非"连不上"
        except Exception as e:
            self.ui(lambda: self.set_status('连接失败: %s' % e))
            return False

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

    def _keepalive_loop(self, ws, relay):
        """保活: MQTT 的 keepalive 是 30s (见 _mq_connect), broker 45s 收不到包就踢;
        而 wspy 的 socket 读超时同样是 30s —— 空闲的聊天窗原本每次都会在 30 秒后"已断开"。
        MQTT 通道发 PINGREQ(0xC0 0x00), relay 通道发 WS PING (对端 PONG 由 wspy 自动吃掉)。
        15s = keepalive 的一半, 留足抖动余量; 连接一换/退出就自行结束。"""
        while self.state.get('running') and self.state.get('ws') is ws:
            time.sleep(15)
            if not self.state.get('running') or self.state.get('ws') is not ws:
                return
            try:
                if relay:
                    ws.ping()
                else:
                    ws.send_bin(b'\xc0\x00')          # MQTT PINGREQ
                self.state['last_ka'] = time.time()   # 保活成功 -> 链路还活着 (给 _recv_loop 判活用)
            except Exception:
                return

    def _recv_loop(self, ws, relay, room, nick, crypto):
        last_rx = time.time()
        while self.state['running']:
            try:
                op, payload = ws.recv_message()
                last_rx = time.time()
            except socket.timeout:
                # "这段时间没有数据"不等于断线 (保活线程每 15s 在发 PING/PINGREQ)。
                # 第五十二轮: 原来按"连续两次读超时(≈60s)"判死 —— 而 relay 通道的 PONG 被 wspy 就地
                # 吃掉、不会让 recv_message 返回, 于是**空闲房间每 ~60s 被判死重连**(对端反复看到
                # "xx 加入了"; lived>=HEALTHY_SEC 还会清零重连预算 -> 可以无限循环)。
                # 现在按"最后一次收到数据或最后一次保活成功"的时间差判死: 只有 90s 两样都没有才 break。
                if time.time() - max(last_rx, self.state.get('last_ka', 0.0)) > IDLE_DEAD_SEC:
                    break
                continue
            except Exception:
                break
            if relay:
                if op == wspy.OP_TEXT:
                    self._handle_json(ws, payload.decode('utf-8'), relay, room, nick, crypto)
            else:
                self._mq_handle_packet(ws, op, payload, room, nick, crypto)
        # 退出即"断线"或"用户离开"; 状态/按钮收尾与是否重连都交给 _net_loop, 这里不碰 UI

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
        """发一条 JSON; 返回是否真的发出去了 (第五十二轮: 以前失败/无连接都静默 return)。"""
        s = json_dumps(obj)
        if ws is None:
            return False
        try:
            if 'chat.seee.uno' in self.state.get('broker', ''):
                ws.send_text(s)
            else:
                ws.send_bin(_mq_publish(TOPIC + self.state.get('room', ''), s.encode('utf-8')))
            return True
        except Exception as ex:
            self.ui(lambda: self.set_status('发送失败: %s' % ex))
            return False

    def send(self, _ev=None):
        text = self.input.get()
        if not text.strip():
            return
        # 第五十二轮: 先看连接状态 (对齐 C# `if (t.Length == 0 || !running) return;`) ——
        # 以前未连接/已离开时回车会把输入框清空、本地回显一条"像发出去了"的消息, 对端永远收不到。
        if not self.state.get('running') or self.state.get('ws') is None:
            self.set_status('未连接: 先点「加入」')
            return
        nick = self.state.get('nick') or (self.nick.get().strip() or 'User')
        # 房间/密钥用 join 时的快照 (连接期间输入框已禁用, 这里再兜一层)
        crypto = Crypto(self.state.get('room') or '', self.state.get('key') or '')
        enc = crypto.enc(text)
        if not self._send_json(self.state['ws'], {'type': 'chat', 'nick': nick, 'text': enc, 'enc': True,
                                                  'ts': int(time.time() * 1000), 'id': self.docid}):
            return
        self.input.delete(0, 'end')                 # 真发出去了才清输入框
        self.add_msg('%s  %s' % (nick, text))

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
