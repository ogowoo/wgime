import { readFileSync } from 'node:fs';
import { zstdDecompressSync } from 'node:zlib';

const path = process.argv[2];
const buf = readFileSync(path);
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const starts = [];
for (let i = 0; i + 4 <= buf.length; i++) {
  if (buf[i] === MAGIC[0] && buf[i + 1] === MAGIC[1] && buf[i + 2] === MAGIC[2] && buf[i + 3] === MAGIC[3]) starts.push(i);
}
starts.push(buf.length);
let raw = '';
for (let i = 0; i + 1 < starts.length; i++) {
  try { raw += zstdDecompressSync(buf.subarray(starts[i], starts[i + 1])).toString('utf8'); } catch {}
}
for (const line of raw.split('\n')) {
  if (line.trim() === '') continue;
  let ev;
  try { ev = JSON.parse(line); } catch { continue; }
  if (['assistant/chunk', 'text-chunks', 'reasoning-chunks', 'turn/start', 'turn/end', 'step/start', 'step/end'].includes(ev.type)) {
    console.log(ev.seq, ev.type, JSON.stringify(ev.data).slice(0, 220));
  }
}
