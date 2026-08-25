// itools-chat reference peer (PC/Android wire-compatible) for interop testing.
// usage: node ref-client.js <relay|mqtt|lan> <url> <room> <nick> <key|nokey> <listenMs> <sendText> [sendFilePath]
'use strict';
const crypto = require('crypto');
const fs = require('fs');
const [, , mode, baseUrl, room, nick, keyRaw, listenMsS, sendText, sendFilePath] = process.argv;
const key = keyRaw === 'nokey' ? '' : keyRaw;
const listenMs = parseInt(listenMsS, 10);
const isLan = mode === 'lan';
const docId = isLan ? 'lan-' + Date.now().toString(36) : 'node-' + Math.random().toString(36).slice(2, 10);
const TOPIC = 'itools/chat/' + room;

const aesKey = crypto.createHash('sha256').update(room + ':' + (key || room), 'utf8').digest();
function enc(plain) {
  const iv = crypto.randomBytes(16);
  const c = crypto.createCipheriv('aes-256-cbc', aesKey, iv);
  const ct = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
  const ivH = iv.toString('hex'), ctH = ct.toString('hex');
  const h = crypto.createHmac('sha256', aesKey).update(ivH + ':' + ctH, 'utf8').digest('hex');
  return ivH + ':' + ctH + ':' + h;
}
function dec(data) {
  const p = String(data).split(':');
  if (p.length < 3) return null;
  const expect = crypto.createHmac('sha256', aesKey).update(p[0] + ':' + p[1], 'utf8').digest('hex');
  if (expect !== p[2]) return null;
  try {
    const d = crypto.createDecipheriv('aes-256-cbc', aesKey, Buffer.from(p[0], 'hex'));
    return Buffer.concat([d.update(Buffer.from(p[1], 'hex')), d.final()]).toString('utf8');
  } catch (e) { return null; }
}
function unpack(pt) {
  try { const o = JSON.parse(pt); if (o && typeof o.t === 'string') return { t: o.t, q: o.q || null }; } catch (e) {}
  return { t: pt, q: null };
}
function log(o) { console.log(JSON.stringify(o)); }

// ---- minimal MQTT 3.1.1 framing (QoS0 only) ----
function mqStr(s) { const b = Buffer.from(s, 'utf8'); return Buffer.concat([Buffer.from([b.length >> 8, b.length & 0xff]), b]); }
function mqPkt(type, body) {
  const hdr = [type]; let rem = body.length;
  do { let b = rem % 128; rem = Math.floor(rem / 128); if (rem > 0) b |= 0x80; hdr.push(b); } while (rem > 0);
  return Buffer.concat([Buffer.from(hdr), body]);
}
function mqConnect(id) { return mqPkt(0x10, Buffer.concat([mqStr('MQTT'), Buffer.from([4, 2, 0, 30]), mqStr(id)])); }
function mqSubscribe(pid, topic) { return mqPkt(0x82, Buffer.concat([Buffer.from([pid >> 8, pid & 0xff]), mqStr(topic), Buffer.from([0])])); }
function mqPublish(topic, payload) { return mqPkt(0x30, Buffer.concat([mqStr(topic), Buffer.from(payload, 'utf8')])); }

// ---- transports ----
let ws = null;
let lanSock = null;
function sendObj(obj) {
  const s = JSON.stringify(obj);
  if (isLan) {
    if (!lanSock) return;
    const b = Buffer.from(s, 'utf8');
    try { lanSock.send(b, 20003, '255.255.255.255'); } catch (e) {}
    try { lanSock.send(b, 5353, '224.0.0.251'); } catch (e) {}
    return;
  }
  if (!ws || ws.readyState !== 1) return;
  if (mode === 'relay') ws.send(s);
  else ws.send(mqPublish(TOPIC, s));
}
function sendChatMsg(txt, quote) {
  if (isLan) {
    sendObj({ type: 'lan-msg', room, nick, text: txt, ts: Date.now(), id: docId, quote: quote || null });
  } else {
    const payload = quote ? JSON.stringify({ t: txt, q: quote }) : txt;
    sendObj({ type: 'chat', nick, text: enc(payload), enc: true, ts: Date.now(), id: docId });
  }
}

// ---- file receive state ----
const pendingFiles = {};
function handleFileStart(d) {
  if (d.sid === docId) return;
  pendingFiles[d.id] = { name: d.name, size: d.size, total: d.total, chunks: new Array(d.total).fill(null), received: 0 };
  log({ ev: 'file-start', name: d.name, total: d.total });
}
function handleFileChunk(d) {
  if (d.sid === docId) return;
  const pf = pendingFiles[d.id];
  if (!pf) return;
  if (typeof d.len === 'number' && String(d.data).length !== d.len) return;
  if (typeof d.seq === 'number' && d.seq !== d.idx) return;
  if (d.idx < 0 || d.idx >= pf.total) return;
  if (pf.chunks[d.idx] === null) pf.received++;
  pf.chunks[d.idx] = String(d.data);
  if (pf.received === pf.total) {
    if (pf.chunks.some(c => c === null)) { log({ ev: 'file-gap', id: d.id }); return; }
    const buf = Buffer.from(pf.chunks.join(''), 'base64');
    const sha = crypto.createHash('sha256').update(buf).digest('hex');
    log({ file: pf.name, len: buf.length, sha256: sha });
    delete pendingFiles[d.id];
  }
}
function sendFileNow(path) {
  const bytes = fs.readFileSync(path);
  const b64 = bytes.toString('base64');
  const name = path.split(/[\\/]/).pop();
  const fid = 'f' + Date.now().toString(36) + Math.floor(Math.random() * 99);
  const chunkSize = isLan ? 3000 : 8000;
  const total = Math.ceil(b64.length / chunkSize);
  const start = { type: 'file-start', nick, sid: docId, caption: '', name, size: bytes.length, id: fid, total };
  sendObj(start);
  if (isLan) { setTimeout(() => sendObj(start), 60); setTimeout(() => sendObj(start), 120); }
  let i = 0;
  const timer = setInterval(() => {
    if (i >= total) {
      clearInterval(timer);
      if (!isLan) sendObj({ type: 'file-end', id: fid, total, sid: docId });
      log({ ev: 'file-sent', name, total });
      return;
    }
    const cd = b64.slice(i * chunkSize, (i + 1) * chunkSize);
    sendObj({ type: 'file-chunk', id: fid, idx: i, seq: i, total, sid: docId, data: cd, len: cd.length });
    i++;
  }, 4);
}

function handleJson(raw) {
  let d; try { d = JSON.parse(raw); } catch (e) { return; }
  if (d.type === 'join') {
    if (d.id !== docId) {
      log({ ev: 'join', nick: d.nick });
      sendObj({ type: 'online', nick, ts: Date.now(), id: docId });
    }
  } else if (d.type === 'leave') {
    log({ ev: 'leave', nick: d.nick });
  } else if (d.type === 'chat') {
    if (d.id === docId) return;
    const pt = d.enc ? dec(d.text) : d.text;
    const u = pt === null ? { t: '[DECRYPT-FAIL]', q: null } : unpack(pt);
    log({ chat: d.nick, text: u.t, quote: !!u.q, ts: d.ts });
  } else if (d.type === 'online') {
    log({ ev: 'online', nick: d.nick });
  } else if (d.type === 'file-start') handleFileStart(d);
  else if (d.type === 'file-chunk') handleFileChunk(d);
}
function handleMqtt(buf) {
  let pos = 0;
  while (pos + 2 <= buf.length) {
    const head = buf[pos]; const type = head & 0xf0;
    let i = pos + 1, rem = 0, shift = 0;
    for (;;) { const b = buf[i++]; rem |= (b & 0x7f) << shift; shift += 7; if (!(b & 0x80)) break; }
    if (i + rem > buf.length) return;
    if (type === 0x20) {
      if (buf[i + 1] === 0) { log({ ev: 'connack' }); ws.send(mqSubscribe(1, TOPIC)); ws.send(mqSubscribe(2, 'itools/registry/rooms')); sendObj({ type: 'join', nick, ts: Date.now(), id: docId }); log({ ev: 'joined' }); }
    } else if ((type & 0xf0) === 0x30) {
      const qos = (head >> 1) & 3;
      const tl = (buf[i] << 8) | buf[i + 1];
      let p = i + 2 + tl + (qos > 0 ? 2 : 0);
      handleJson(buf.slice(p, i + rem).toString('utf8'));
    }
    pos = i + rem;
  }
}
function lanHandle(raw) {
  let d; try { d = JSON.parse(raw); } catch (e) { return; }
  if (d.type === 'lan-beacon') {
    if (d.id !== docId && String(d.id).indexOf('scan-') !== 0) log({ ev: 'beacon', nick: d.nick, room: d.room });
  } else if (d.type === 'lan-room-query') {
    sendObj({ type: 'lan-beacon', room, nick, id: docId });
  } else if (d.type === 'lan-msg') {
    if (d.id === docId || d.room !== room) return;
    log({ chat: d.nick, text: d.text, quote: !!d.quote, ts: d.ts });
  } else if (d.type === 'file-start') handleFileStart(d);
  else if (d.type === 'file-chunk') handleFileChunk(d);
}

if (isLan) {
  const dgram = require('dgram');
  lanSock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  lanSock.on('message', (buf, rinfo) => lanHandle(buf.toString('utf8')));
  lanSock.on('error', (e) => log({ ev: 'lan-error', msg: String(e) }));
  lanSock.bind(20003, () => {
    try { lanSock.setBroadcast(true); } catch (e) {}
    try { lanSock.addMembership('224.0.0.251'); } catch (e) {}
    log({ ev: 'lan-bound' });
    const bj = { type: 'lan-beacon', room, nick, id: docId };
    sendObj(bj);
    setInterval(() => sendObj(bj), 2000);
  });
} else {
  const url = mode === 'relay' ? baseUrl.replace(/\/+$/, '') + '/room/' + encodeURIComponent(room)
                               : baseUrl.replace(/\/+$/, '') + '/mqtt';
  ws = mode === 'relay' ? new WebSocket(url) : new WebSocket(url, 'mqtt');
  ws.binaryType = 'arraybuffer';
  ws.addEventListener('open', () => {
    log({ ev: 'ws-open', url });
    if (mode === 'relay') {
      sendObj({ type: 'join', nick, ts: Date.now(), id: docId });
      log({ ev: 'joined' });
    } else {
      ws.send(mqConnect(docId));
    }
  });
  ws.addEventListener('message', (ev) => {
    if (typeof ev.data === 'string') handleJson(ev.data);
    else handleMqtt(Buffer.from(ev.data));
  });
  ws.addEventListener('error', (e) => { log({ ev: 'ws-error', msg: String(e.message || e) }); });
  ws.addEventListener('close', (e) => { log({ ev: 'ws-close', code: e.code }); });
}

let sendN = 0;
const sendTimer = setInterval(() => {
  sendN++;
  const txt = sendN === 1 ? sendText : sendText + '#' + sendN;
  const quote = sendN === 2 ? { nick: 'QuotedNick', text: 'quoted original text' } : null;
  sendChatMsg(txt, quote);
  log({ ev: 'sent', text: txt, quoted: sendN === 2 });
  if (sendN === 2 && sendFilePath) sendFileNow(sendFilePath);
}, 5000);
setTimeout(() => {
  clearInterval(sendTimer);
  try { if (ws) ws.close(); } catch (e) {}
  try { if (lanSock) lanSock.close(); } catch (e) {}
  process.exit(0);
}, listenMs);
