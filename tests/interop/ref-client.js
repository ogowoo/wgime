// itools-chat reference peer (PC/Android wire-compatible) for interop testing.
// usage: node ref-client.js <relay|mqtt> <url> <room> <nick> <key> <listenMs> <sendText>
'use strict';
const crypto = require('crypto');
const [, , mode, baseUrl, room, nick, keyRaw, listenMsS, sendText] = process.argv;
const key = keyRaw === 'nokey' ? '' : keyRaw;
const listenMs = parseInt(listenMsS, 10);
const docId = 'node-' + Math.random().toString(36).slice(2, 10);
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

let ws = null;
function sendJson(obj) {
  if (!ws || ws.readyState !== 1) return;
  const s = JSON.stringify(obj);
  if (mode === 'relay') ws.send(s);
  else ws.send(mqPublish(TOPIC, s));
}
function handleJson(raw) {
  let d; try { d = JSON.parse(raw); } catch (e) { return; }
  if (d.type === 'join') {
    if (d.id !== docId) {
      log({ ev: 'join', nick: d.nick });
      sendJson({ type: 'online', nick, ts: Date.now(), id: docId });
    }
  } else if (d.type === 'leave') {
    log({ ev: 'leave', nick: d.nick });
  } else if (d.type === 'chat') {
    if (d.id === docId) return;
    const pt = d.enc ? dec(d.text) : d.text;
    log({ chat: d.nick, text: pt === null ? '[DECRYPT-FAIL]' : pt, ts: d.ts });
  } else if (d.type === 'online') {
    log({ ev: 'online', nick: d.nick });
  }
}
function handleMqtt(buf) {
  let pos = 0;
  while (pos + 2 <= buf.length) {
    const head = buf[pos]; const type = head & 0xf0;
    let i = pos + 1, rem = 0, shift = 0;
    for (;;) { const b = buf[i++]; rem |= (b & 0x7f) << shift; shift += 7; if (!(b & 0x80)) break; }
    if (i + rem > buf.length) return;
    if (type === 0x20) {
      if (buf[i + 1] === 0) { log({ ev: 'connack' }); ws.send(mqSubscribe(1, TOPIC)); ws.send(mqSubscribe(2, 'itools/registry/rooms')); sendJson({ type: 'join', nick, ts: Date.now(), id: docId }); log({ ev: 'joined' }); }
    } else if ((type & 0xf0) === 0x30) {
      const qos = (head >> 1) & 3;
      const tl = (buf[i] << 8) | buf[i + 1];
      let p = i + 2 + tl + (qos > 0 ? 2 : 0);
      handleJson(buf.slice(p, i + rem).toString('utf8'));
    }
    pos = i + rem;
  }
}

const url = mode === 'relay' ? baseUrl.replace(/\/+$/, '') + '/room/' + encodeURIComponent(room)
                             : baseUrl.replace(/\/+$/, '') + '/mqtt';
ws = mode === 'relay' ? new WebSocket(url) : new WebSocket(url, 'mqtt');
ws.binaryType = 'arraybuffer';

ws.addEventListener('open', () => {
  log({ ev: 'ws-open', url });
  if (mode === 'relay') {
    sendJson({ type: 'join', nick, ts: Date.now(), id: docId });
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

let sendN = 0;
const sendTimer = setInterval(() => {
  sendN++;
  const txt = sendN === 1 ? sendText : sendText + '#' + sendN;
  sendJson({ type: 'chat', nick, text: enc(txt), enc: true, ts: Date.now(), id: docId });
  log({ ev: 'sent', text: txt });
}, 5000);
setTimeout(() => { clearInterval(sendTimer); try { ws.close(); } catch (e) {} process.exit(0); }, listenMs);
