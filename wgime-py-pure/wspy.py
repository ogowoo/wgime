# -*- coding: utf-8 -*-
"""wspy.py — 最小同步 WebSocket 客户端 (标准库 socket+ssl, RFC 6455). 用于 relay 文本帧 / MQTT-over-WS 二进制帧."""
import base64
import os
import socket
import ssl
import struct
from urllib.parse import urlparse

OP_CONT = 0x0
OP_TEXT = 0x1
OP_BIN = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA


class WS:
    def __init__(self):
        self.sock = None
        self.subprotocol = None
        self._buf = b''        # 读缓冲: 握手响应后面紧跟的帧字节不能丢 (见 _read_headers)
        self._mid_frame = False   # 是否正读到一帧的中间 (帧中间中断不能当"暂时没数据")

    def connect(self, url, subprotocol=None, timeout=10):
        u = urlparse(url)
        host = u.hostname
        port = u.port or (443 if u.scheme == 'wss' else 80)
        path = u.path or '/'
        if u.query:
            path += '?' + u.query
        if u.scheme == 'wss':
            ctx = ssl.create_default_context()
            self.sock = ctx.wrap_socket(socket.create_connection((host, port), timeout=timeout), server_hostname=host)
        else:
            self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(30)
        key = base64.b64encode(os.urandom(16)).decode()
        # RFC 6455 §4.1: Host 必须带端口 (非默认端口时) —— 少了端口, 反代/虚拟主机可能路由错
        default_port = 443 if u.scheme == 'wss' else 80
        host_hdr = host if port == default_port else '%s:%d' % (host, port)
        req = ('GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
               'Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n' % (path, host_hdr, key))
        if subprotocol:
            req += 'Sec-WebSocket-Protocol: %s\r\n' % subprotocol
        req += '\r\n'
        self.sock.sendall(req.encode())
        head = self._read_headers()
        status = head.split('\r\n', 1)[0]
        if ' 101 ' not in status:
            raise RuntimeError('handshake failed: ' + status)
        self.subprotocol = self._header(head, 'Sec-WebSocket-Protocol') or subprotocol

    def _read_headers(self):
        buf = self._buf                      # 续用已有缓冲 (正常情况下为空)
        while b'\r\n\r\n' not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError('connection closed during handshake')
            buf += chunk
        head, _, rest = buf.partition(b'\r\n\r\n')
        # 关键: 服务端常常把 101 响应和**第一条消息帧**写在同一个 TCP 段里;
        # 这里读到的余下字节必须留在缓冲里, 不能丢 (丢了首帧就整条流错位)。
        self._buf = rest
        return head.decode('utf-8', errors='replace')

    @staticmethod
    def _header(head, name):
        for line in head.split('\r\n'):
            if line.lower().startswith(name.lower() + ':'):
                return line.split(':', 1)[1].strip()
        return None

    # ---------- frames ----------
    def _send_frame(self, payload, opcode):
        mask = os.urandom(4)
        head = bytearray()
        head.append(0x80 | opcode)
        n = len(payload)
        if n < 126:
            head.append(0x80 | n)
        elif n < 0x10000:
            head.append(0x80 | 126)
            head += struct.pack('>H', n)
        else:
            head.append(0x80 | 127)
            head += struct.pack('>Q', n)
        head += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(head) + masked)

    def send_text(self, s):
        self._send_frame(s.encode('utf-8'), OP_TEXT)

    def send_bin(self, b):
        self._send_frame(b, OP_BIN)

    def _recv_frame(self):
        """读一帧, 返回 (fin, opcode, payload)."""
        self._mid_frame = False
        h = self._readexact(2)               # 还没吃掉帧头 -> 这里的超时是"暂时没数据", 可安全重试
        self._mid_frame = True               # 帧头之后任何中断都意味着"这帧只读了一半"
        fin = (h[0] & 0x80) != 0
        opcode = h[0] & 0x0F
        masked = (h[1] & 0x80) != 0
        n = h[1] & 0x7F
        if n == 126:
            n = struct.unpack('>H', self._readexact(2))[0]
        elif n == 127:
            n = struct.unpack('>Q', self._readexact(8))[0]
        mask = self._readexact(4) if masked else None
        payload = self._readexact(n)
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self._mid_frame = False
        return fin, opcode, payload

    def _readexact(self, n):
        buf = self._buf                      # 先吃握手/上一次读进来的余量
        while len(buf) < n:
            try:
                chunk = self.sock.recv(max(4096, n - len(buf)))
            except Exception as e:
                # 超时/中断: 已经读到的字节必须留在缓冲里, 否则下一轮从帧中间开始解析 -> 整条流错位。
                self._buf = buf
                if self._mid_frame:
                    # 帧只读了一半就断了: 流已错位, 不能当成"暂时没数据"继续等,
                    # 必须当断线处理 (chat 的 _recv_loop 只对帧间的 socket.timeout 宽容)。
                    raise RuntimeError('frame interrupted (%s)' % (e,))
                raise
            if not chunk:
                self._buf = buf
                raise RuntimeError('connection closed')
            buf += chunk
        self._buf = buf[n:]
        return buf[:n]

    def _recv_data(self):
        """读到下一个数据帧 (TEXT/BIN/CONT); 途中的 PING/PONG 就地处理, 不计入消息体."""
        while True:
            fin, opcode, payload = self._recv_frame()
            if opcode == OP_PING:
                self._send_frame(payload, OP_PONG)
                continue
            if opcode == OP_PONG:
                continue
            return fin, opcode, payload

    def _read_message(self):
        """拼一个完整消息 (按 RFC 6455 处理分片), 返回 (opcode, payload).

        必须看 **FIN 位**: 首帧 FIN=0 说明这是分片消息的第一片, 后面跟若干 OP_CONT 片,
        直到某片 FIN=1 才算收完。原来忽略 FIN, 会把第一片当成完整消息返回,
        剩下的片变成下一条"消息" —— relay 那边就是半截 JSON, 整条消息作废。
        控制帧 (PING/PONG) 允许插在分片中间, 必须就地处理且不结束消息。
        """
        fin, opcode, payload = self._recv_data()
        if opcode == OP_CLOSE:
            return opcode, payload
        while not fin:
            fin2, op2, pw = self._recv_data()
            if op2 == OP_CLOSE:
                return op2, pw
            payload += pw
            fin = fin2
        return opcode, payload

    def recv_message(self):
        return self._read_message()

    def ping(self, payload=b''):
        """发一个 PING (保活用; 对端应回 PONG, 由 _recv_data 自动消费)."""
        self._send_frame(payload, OP_PING)

    def close(self):
        try:
            self._send_frame(b'', OP_CLOSE)
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass
