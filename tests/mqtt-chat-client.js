// Full second-client simulation: connects to a broker, subscribes to the room
// registry + a chat room, publishes beacons and chat messages, and reports
// everything it receives. Proves the Active-Rooms pipeline end to end.
// Usage: node mqtt-chat-client.js <broker-url> <room> <seconds>
const url = process.argv[2] || 'wss://broker.hivemq.com:8884/mqtt';
const room = process.argv[3] || 'probe-room';
const secs = parseInt(process.argv[4] || '60', 10);
const REG = 'itools/registry/rooms';
const ROOM_TOPIC = 'itools/chat/' + room;
const cid = 'test2-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);

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
// subscribe to registry + room topic, pkt ids 1 and 2
const subBody = Buffer.concat([Buffer.from([0, 1]), str(REG), Buffer.from([0]), str(ROOM_TOPIC), Buffer.from([0])]);
const subPkt = packet(8, 2, subBody);

let opened = false, sent = 0, connack = false, suback = false;
const ws = new WebSocket(url);
ws.binaryType = 'arraybuffer';

function publish(topic, obj) {
  const b = JSON.stringify(obj);
  const pubBody = Buffer.concat([str(topic), Buffer.from([0]), Buffer.from(b, 'utf8')]);
  ws.send(packet(3, 0, pubBody));
  sent++;
  return b;
}
function parsePub(buf) {
  // skip fixed header (1 + varint remain len)
  let i = 1;
  while (buf[i] & 0x80) i++;
  i++;
  const tlen = (buf[i] << 8) | buf[i + 1]; i += 2;
  const topic = buf.subarray(i, i + tlen).toString('utf8'); i += tlen;
  const qos = (buf[0] >> 1) & 3;
  if (qos > 0) i += 2;
  return { topic, payload: buf.subarray(i).toString('utf8') };
}

ws.onopen = () => { opened = true; ws.send(connectPkt); console.log('[' + new Date().toISOString() + '] CONNECT ->', url, 'cid', cid, 'room', room); };
ws.onmessage = (ev) => {
  const buf = Buffer.from(ev.data);
  if (buf.length < 2) return;
  const type = buf[0] >> 4;
  if (type === 2) { connack = true; console.log('[' + new Date().toISOString() + '] CONNACK ok, SUBSCRIBE', REG, '+', ROOM_TOPIC); ws.send(subPkt); }
  else if (type === 9) { suback = true;
    console.log('[' + new Date().toISOString() + '] SUBACK - joined room "' + room + '"');
    // join message like the real client
    publish(ROOM_TOPIC, { type: 'join', nick: 'probe', ts: Date.now(), id: cid });
    // immediate beacon
    const b = publish(REG, { type: 'room-beacon', room: room, nick: 'probe', id: cid, ts: Date.now() });
    console.log('[' + new Date().toISOString() + '] beacon#1 sent: ' + b);
    setInterval(() => {
      if (opened) {
        publish(REG, { type: 'room-beacon', room: room, nick: 'probe', id: cid, ts: Date.now() });
        console.log('[' + new Date().toISOString() + '] beacon#sent');
      }
    }, 8000);
    // one chat message into the room
    setTimeout(() => {
      const mb = publish(ROOM_TOPIC, { type: 'chat', nick: 'probe', text: 'hello from test client', ts: Date.now(), id: cid });
      console.log('[' + new Date().toISOString() + '] chat msg sent: ' + mb);
    }, 2000);
  }
  else if (type === 3) { const { topic, payload } = parsePub(buf); console.log('[' + new Date().toISOString() + '] << topic=' + topic + ' payload=' + payload.slice(0, 300)); }
  else if (type === 13) { console.log('[' + new Date().toISOString() + '] PINGRESP'); }
  else { console.log('[' + new Date().toISOString() + '] pkt type=' + type); }
};
ws.onerror = (e) => console.log('[' + new Date().toISOString() + '] WS error', e && e.message || e);
ws.onclose = (e) => { console.log('[' + new Date().toISOString() + '] closed', e && e.code, e && e.reason); process.exit(0); };
setInterval(() => { if (opened) ws.send(packet(12, 0, Buffer.from([0, 1]))); }, 25000);
setTimeout(() => { console.log('=== done after ' + secs + 's, sent ' + sent + ' msgs (connack=' + connack + ' suback=' + suback + ') ==='); try { ws.close(); } catch (e) {} process.exit(0); }, secs * 1000);
