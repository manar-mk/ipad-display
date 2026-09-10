// Emulates the iPad web client: connects over WebSocket, receives typed messages, saves the last JPEG.
const WebSocket = require('ws');
const fs = require('fs');
const url = process.argv[2] || 'ws://127.0.0.1:7800/';
const want = parseInt(process.argv[3] || '10', 10);
const ws = new WebSocket(url);
let n = 0, bytes = 0, audio = 0, t0 = Date.now(), fmt = null;
ws.on('open', () => { console.log('connected', url); ws.send('hello'); });
ws.on('message', (data, isBinary) => {
  if (!isBinary) return;
  const type = String.fromCharCode(data[4]);
  if (type === 'F') { fmt = { rate: data.readUInt32BE(5), ch: data[9] }; return; }
  if (type === 'A') { audio += data.length - 5; return; }
  if (type !== 'J') return;
  const jpeg = data.subarray(5);
  n++; bytes += jpeg.length;
  if (n >= want) {
    fs.writeFileSync('tools/last-frame.jpg', jpeg);
    const dt = (Date.now() - t0) / 1000;
    console.log(`got ${n} frames, ${(bytes / n / 1024).toFixed(0)} KB avg, ${(n / dt).toFixed(1)} fps; audio ${fmt ? fmt.rate + 'Hz/' + fmt.ch + 'ch ' : ''}${(audio / 1024 / dt).toFixed(0)} KB/s; saved tools/last-frame.jpg`);
    ws.send(JSON.stringify({ t: 'touch', phase: 1, x: 0.5, y: 0.5 })); // harmless: moves the mouse to the centre of the captured display
    setTimeout(() => { ws.close(); process.exit(0); }, 200);
    return;
  }
  ws.send('a');
});
ws.on('error', (e) => { console.error('error', e.message); process.exit(1); });
setTimeout(() => { console.error('timeout, frames so far:', n); process.exit(2); }, 20000);
