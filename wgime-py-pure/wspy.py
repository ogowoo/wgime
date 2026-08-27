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
        req = ('GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
               'Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n' % (path, host, key))
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
        buf = b''
        while b'\r\n\r\n' not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError('connection closed during handshake')
            buf += chunk
        return buf.decode('utf-8', errors='replace')

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
        h = self._readexact(2)
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
        return opcode, payload

    def _readexact(self, n):
        buf = b''
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError('connection closed')
            buf += chunk
        return buf

    def _read_message(self):
        """拼一个完整消息 (聚合分片), 返回 (opcode, payload)."""
        opcode, payload = self._recv_frame()
        data = payload
        fin_opcode = opcode
        while opcode == OP_CONT or (opcode in (OP_PING, OP_PONG)):
            if opcode == OP_PING:
                self._send_frame(payload, OP_PONG)
            elif opcode == OP_PONG:
                pass
            else:
                po, pw = self._recv_frame()
                data += pw
                opcode = po
                break
            opcode, payload = self._recv_frame()
            if opcode != OP_CONT:
                break
        return fin_opcode, data

    def recv_message(self):
        return self._read_message()

    def close(self):
        try:
            self._send_frame(b'', OP_CLOSE)
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass
