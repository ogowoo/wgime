// Minimal MQTT 3.1.1 client over WebSocket (Node 18+ global WebSocket) to probe
// the chat room-registry topic on public brokers. Usage:
//   node mqtt-registry-probe.js <broker-url> [seconds] [publish-beacon-room]
//   e.g. node mqtt-registry-probe.js wss://broker.hivemq.com:8884/mqtt 40 TestRoom
const url = process.argv[2] || 'wss://broker.hivemq.com:8884/mqtt';
const runSecs = parseInt(process.argv[3] || '40', 10);
const beaconRoom = process.argv[4] || '';
const REG = 'itools/registry/rooms';
const cid = 'probe-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);

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

// CONNECT (MQTT 3.1.1, clean session, keepalive 30)
const connectBody = Buffer.concat([
  str('MQTT'), Buffer.from([4, 0x02, 0, 30]), str(cid)
]);
const connectPkt = packet(1, 0, connectBody);

// SUBSCRIBE reg topic, packet id 1, QoS 0
const subBody = Buffer.concat([Buffer.from([0, 1]), str(REG), Buffer.from([0])]);
const subPkt = packet(8, 2, subBody);

let got = 0, opened = false;
const ws = new WebSocket(url);
ws.binaryType = 'arraybuffer';

function parsePublish(data) {
  // returns {topic, payload} for QoS0 publish
  const buf = Buffer.from(data);
  let i = 0;
  const tlen = (buf[2] << 8) | buf[3];
  const topic = buf.subarray(4, 4 + tlen).toString('utf8');
  const payload = buf.subarray(4 + tlen).toString('utf8');
  return { topic, payload };
}

ws.onopen = () => {
  opened = true;
  ws.send(connectPkt);
  console.log('[' + new Date().toISOString() + '] CONNECT ->', url, 'cid', cid);
};

ws.onmessage = (ev) => {
  const buf = Buffer.from(ev.data);
  if (buf.length < 2) return;
  const type = buf[0] >> 4;
  if (type === 2) { // CONNACK
    console.log('[' + new Date().toISOString() + '] CONNACK ok, SUBSCRIBE', REG);
    ws.send(subPkt);
    if (beaconRoom) {
      // publish a beacon as if we were another client in that room
      const b = JSON.stringify({ type: 'room-beacon', room: beaconRoom, nick: 'probe', id: 'probe-' + Date.now().toString(36), ts: Date.now() });
      const pubBody = Buffer.concat([str(REG), Buffer.from([0]), Buffer.from(b, 'utf8')]);
      ws.send(packet(3, 0, pubBody));
      console.log('[' + new Date().toISOString() + '] PUBLISH beacon room=' + beaconRoom);
    }
  } else if (type === 3) { // PUBLISH
    got++;
    const { topic, payload } = parsePublish(ev.data);
    console.log('[' + new Date().toISOString() + '] RECV topic=' + topic + ' payload=' + payload.slice(0, 200));
  } else if (type === 9) { // SUBACK
    console.log('[' + new Date().toISOString() + '] SUBACK');
  } else if (type === 13) {
    console.log('[' + new Date().toISOString() + '] PINGRESP');
  }
};

ws.onerror = (e) => console.log('[' + new Date().toISOString() + '] WS error', e && e.message || e);
ws.onclose = (e) => console.log('[' + new Date().toISOString() + '] WS closed', e && e.code, e && e.reason);

setInterval(() => { if (opened) ws.send(packet(12, 0, Buffer.from([0, 1]))); }, 25000); // PINGREQ

setTimeout(() => {
  console.log('=== probe done: received ' + got + ' pub/sub msgs in ' + runSecs + 's ===');
  try { ws.close(); } catch (e) {}
  process.exit(0);
}, runSecs * 1000);
