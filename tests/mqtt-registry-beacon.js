// Stands in as a SECOND chat client: subscribes to the room-registry topic and
// keeps publishing room-beacons (every 8s) so a real chat client can see a
// "foreign" room appear in its Active Rooms list. Run a few minutes, then stop.
// Usage: node mqtt-registry-beacon.js <broker-url> <room> <minutes>
const url = process.argv[2] || 'wss://broker.hivemq.com:8884/mqtt';
const room = process.argv[3] || 'probe-room';
const minutes = parseInt(process.argv[4] || '5', 10);
const REG = 'itools/registry/rooms';
const cid = 'vpeer-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);

function encodeRemain(len) {
  const out = [];
  do { let b = len % 128; len = Math.floor(len / 128); if (len > 0) b |= 0x80; out.push(b); } while (len > 0);
  return out;
}
function packet(type, flags, body) {
  const rem = encodeRemain(body.length);
  return Buffer.from([(type << 4) | flags, ...rem, ...body]);
}
function str(s) { const b = Buffer.from(s, 'utf8'); return Buffer.concat([Buffer.from([(b.length >> 8) & 0xff, b.length & 0xff]), b]); }

const connectBody = Buffer.concat([str('MQTT'), Buffer.from([4, 0x02, 0, 30]), str(cid)]);
const connectPkt = packet(1, 0, connectBody);
const subBody = Buffer.concat([Buffer.from([0, 1]), str(REG), Buffer.from([0])]);
const subPkt = packet(8, 2, subBody);

let opened = false, sent = 0;
const ws = new WebSocket(url);
ws.binaryType = 'arraybuffer';

function beacon() {
  if (!opened) return;
  const b = JSON.stringify({ type: 'room-beacon', room: room, nick: 'probe', id: 'vpeer-' + Date.now().toString(36), ts: Date.now() });
  const pubBody = Buffer.concat([str(REG), Buffer.from([0]), Buffer.from(b, 'utf8')]);
  ws.send(packet(3, 0, pubBody));
  sent++;
  console.log('[' + new Date().toISOString() + '] beacon #' + sent + ' room=' + room + ' -> ' + url);
}

ws.onopen = () => { opened = true; ws.send(connectPkt); console.log('[' + new Date().toISOString() + '] connected ' + url + ' as ' + cid); };
ws.onmessage = (ev) => {
  const buf = Buffer.from(ev.data);
  if (buf.length < 2) return;
  const type = buf[0] >> 4;
  if (type === 2) { console.log('[' + new Date().toISOString() + '] CONNACK, subscribing ' + REG); ws.send(subPkt); beacon(); setInterval(beacon, 8000); }
  else if (type === 3) { console.log('[' + new Date().toISOString() + '] recv other beacon'); }
  else if (type === 9) { console.log('[' + new Date().toISOString() + '] SUBACK - now beacons every 8s for ' + minutes + 'min'); }
};
ws.onerror = (e) => console.log('[' + new Date().toISOString() + '] WS error', e && e.message || e);
ws.onclose = (e) => { console.log('[' + new Date().toISOString() + '] closed', e && e.code); process.exit(0); };
setInterval(() => { if (opened) ws.send(packet(12, 0, Buffer.from([0, 1]))); }, 25000);
setTimeout(() => { console.log('=== done, sent ' + sent + ' beacons ==='); try { ws.close(); } catch (e) {} process.exit(0); }, minutes * 60000);
