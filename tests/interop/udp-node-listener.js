// UDP listener probe (cross-process): listens on 20003 with reuseAddr, logs anything
const dgram = require('dgram');
const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
sock.on('message', (buf, rinfo) => console.log('GOT from ' + rinfo.address + ': ' + buf.toString('utf8').slice(0, 60)));
sock.on('error', (e) => console.log('ERR ' + e));
sock.bind(20003, () => {
  try { sock.setBroadcast(true); } catch (e) {}
  try { sock.addMembership('224.0.0.251'); } catch (e) {}
  console.log('listening on 20003 (+mcast 5353 membership)');
  // also send one broadcast immediately so the other side can hear us
  const b = Buffer.from('{"from":"node"}');
  sock.send(b, 20003, '255.255.255.255');
  sock.send(b, 5353, '224.0.0.251');
});
setTimeout(() => process.exit(0), 15000);
