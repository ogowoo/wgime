// TCP MQTT 3.1.1 client - proves native (Paho tcp://) path to HiveMQ works with the
// itools protocol (join/chat encrypted/room-beacon on itools/registry/rooms).
// Usage: node mqtt-tcp-client.js <room> <seconds>
const net = require('net');
const crypto = require('crypto');
const room = process.argv[2] || 'native-tcp-test';
const secs = parseInt(process.argv[3] || '30', 10);
const cid = 'nat-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
const HOST = 'broker.hivemq.com', PORT = 1883;

function keyFrom(r, k) { return Buffer.from(crypto.createHash('sha256').update(r + ':' + (k || r)).digest('hex'), 'hex'); }
function enc(plain, key) { const iv = crypto.randomBytes(16); const c = crypto.createCipheriv('aes-256-cbc', key, iv); const ct = Buffer.concat([c.update(plain, 'utf8'), c.final()]); const ih = iv.toString('hex'), ch = ct.toString('hex'); return ih + ':' + ch + ':' + crypto.createHmac('sha256', key).update(ih + ':' + ch).digest('hex'); }
function dec(data, key) { try { const [ih, ch, h] = data.split(':'); const e = crypto.createHmac('sha256', key).update(ih + ':' + ch).digest('hex'); if (e !== h) return null; const d = crypto.createDecipheriv('aes-256-cbc', key, Buffer.from(ih, 'hex')); return Buffer.concat([d.update(Buffer.from(ch, 'hex')), d.final()]).toString('utf8'); } catch (e) { return null; } }

function str(s) { const b = Buffer.from(s, 'utf8'); return Buffer.concat([Buffer.from([b.length >> 8, b.length & 0xff]), b]); }
function rem(n) { const o = []; do { let b = n % 128; n = Math.floor(n / 128); if (n) b |= 0x80; o.push(b); } while (n); return o; }
function pkt(t, f, body) { return Buffer.concat([Buffer.from([(t << 4) | f, ...rem(body.length)]), body]); }

let buf = Buffer.alloc(0);
let connected = false, sent = 0;
const sock = net.connect({ host: HOST, port: PORT });
sock.on('connect', () => {
  const body = Buffer.concat([str('MQTT'), Buffer.from([4, 0x02, 0, 30]), str(cid)]);
  sock.write(pkt(1, 0, body));
  console.log('[' + new Date().toISOString() + '] TCP CONNECT ' + HOST + ':' + PORT + ' cid=' + cid);
});
sock.on('data', (d) => {
  buf = Buffer.concat([buf, d]);
  while (buf.length >= 2) {
    let i = 1; while (buf[i] & 0x80) i++;
    const rl = buf[1] & 0x7f; const total = i + 1 + rl;
    if (buf.length < total) break;
    const p = buf.subarray(0, total); buf = buf.subarray(total);
    const type = p[0] >> 4;
    if (type === 2) { // CONNACK
      console.log('[' + new Date().toISOString() + '] CONNACK ok - subscribe');
      const sub = Buffer.concat([Buffer.from([0, 1]), str('itools/chat/' + room), Buffer.from([0]), str('itools/registry/rooms'), Buffer.from([0])]);
      sock.write(pkt(8, 2, sub));
      // join
      const j = JSON.stringify({ type: 'join', nick: 'native-probe', ts: Date.now(), id: cid });
      sock.write(pkt(3, 0, Buffer.concat([str('itools/chat/' + room), Buffer.from([0]), Buffer.from(j)])));
      // encrypted chat
      const key = keyFrom(room, '');
      const encText = enc('hello from native tcp client', key);
      const c = JSON.stringify({ type: 'chat', nick: 'native-probe', text: encText, enc: true, ts: Date.now(), id: cid });
      setTimeout(() => sock.write(pkt(3, 0, Buffer.concat([str('itools/chat/' + room), Buffer.from([0]), Buffer.from(c)]))), 500);
      // registry beacon
      const b = JSON.stringify({ type: 'room-beacon', room, nick: 'native-probe', id: cid, ts: Date.now() });
      setTimeout(() => { sock.write(pkt(3, 0, Buffer.concat([str('itools/registry/rooms'), Buffer.from([0]), Buffer.from(b)]))); sent++; }, 800);
      setInterval(() => { if (sock.writable) { const bb = JSON.stringify({ type: 'room-beacon', room, nick: 'native-probe', id: cid, ts: Date.now() }); sock.write(pkt(3, 0, Buffer.concat([str('itools/registry/rooms'), Buffer.from([0]), Buffer.from(bb)]))); sent++; } }, 8000);
    } else if (type === 3) { // PUBLISH (QoS 0)
      let j2 = 1; while (p[j2] & 0x80) j2++; j2++;
      const tl = (p[j2] << 8) | p[j2 + 1]; j2 += 2;
      const topic = p.subarray(j2, j2 + tl).toString('utf8'); j2 += tl;
      const payload = p.subarray(j2).toString('utf8').trim();
      let d;
      try { d = JSON.parse(payload); } catch (e) { console.log('[' + new Date().toISOString() + '] RECV ' + topic + ' (non-json)'); continue; }
      if (d.type === 'chat' && d.enc && d.id !== cid) {
        const pt = dec(d.text, keyFrom(room, ''));
        console.log('[' + new Date().toISOString() + '] RECV chat from ' + d.nick + ': ' + pt);
      } else if (d.type === 'chat') {
        console.log('[' + new Date().toISOString() + '] RECV own chat echo (ok, filtered by id)');
      } else {
        console.log('[' + new Date().toISOString() + '] RECV ' + topic + ' ' + payload.slice(0, 120));
      }
    } else if (type === 9) { console.log('[' + new Date().toISOString() + '] SUBACK - joined room ' + room); connected = true; }
    else if (type === 13) {}
  }
});
sock.on('error', (e) => console.log('ERR:', e.message));
setInterval(() => { if (sock.writable) sock.write(pkt(12, 0, Buffer.from([0, 1]))); }, 25000); // ping
setTimeout(() => { console.log('=== done, sent ' + sent + ' beacons, connected=' + connected + ' ==='); sock.destroy(); process.exit(0); }, secs * 1000);
