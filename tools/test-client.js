// Emulates the iPad: connects over WebSocket, receives N frames, saves the last one as JPEG.
const WebSocket = require('ws');
const fs = require('fs');
const url = process.argv[2] || 'ws://127.0.0.1:7800/';
const want = parseInt(process.argv[3] || '10', 10);
const ws = new WebSocket(url);
let n = 0, bytes = 0, t0 = Date.now();
ws.on('open', () => { console.log('connected', url); ws.send('hello'); });
ws.on('message', (data, isBinary) => {
  if (!isBinary) return;
  n++; bytes += data.length;
  if (n >= want) {
    fs.writeFileSync('tools/last-frame.jpg', data);
    const dt = (Date.now() - t0) / 1000;
    console.log(`got ${n} frames, ${(bytes / n / 1024).toFixed(0)} KB avg, ${(n / dt).toFixed(1)} fps, saved tools/last-frame.jpg (${data.length} bytes)`);
    ws.close(); process.exit(0);
  }
  ws.send('a');
});
ws.on('error', (e) => { console.error('error', e.message); process.exit(1); });
setTimeout(() => { console.error('timeout, frames so far:', n); process.exit(2); }, 20000);
