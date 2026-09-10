// Emulates the native iPad app (TCP side): listens on 7801, beacons on UDP, parses typed messages.
// Reports JPEG frames, H.264 config/frames (fps, bitrate) and audio for N seconds, then exits.
const net = require('net');
const dgram = require('dgram');
const fs = require('fs');
const port = parseInt(process.argv[2] || '7801', 10);
const seconds = parseInt(process.argv[3] || '8', 10);
const beacon = dgram.createSocket('udp4');
beacon.bind(() => { beacon.setBroadcast(true); });
setInterval(() => beacon.send(`IPADDISPLAY ${port}`, 7802, '255.255.255.255'), 2000);

net.createServer((s) => {
  console.log('host connected from', s.remoteAddress);
  let buf = Buffer.alloc(0), jpeg = 0, v = 0, vBytes = 0, vKeys = 0, audio = 0, cfg = null, lastJpeg = null;
  const t0 = Date.now();
  s.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    while (buf.length >= 4) {
      const len = buf.readUInt32BE(0);
      if (buf.length < 4 + len) break;
      const type = String.fromCharCode(buf[4]), payload = buf.subarray(5, 4 + len); buf = buf.subarray(4 + len);
      if (type === 'F') console.log('audio format', payload.readUInt32BE(0), 'Hz', payload[4], 'ch');
      else if (type === 'A') audio += payload.length;
      else if (type === 'H') { cfg = payload; console.log('h264 config avcC', payload.length, 'bytes, profile', payload[1].toString(16), 'level', payload[3]); }
      else if (type === 'V') { v++; vBytes += payload.length - 5; if (payload[0] & 1) vKeys++; }
      else if (type === 'J') { jpeg++; lastJpeg = payload; s.write(Buffer.from([1])); }
    }
  });
  setTimeout(() => {
    const dt = (Date.now() - t0) / 1000;
    if (lastJpeg) fs.writeFileSync('tools/last-tcp-frame.jpg', lastJpeg);
    console.log(`in ${dt.toFixed(1)}s: jpeg ${jpeg} (${(jpeg / dt).toFixed(1)} fps), h264 ${v} frames (${(v / dt).toFixed(1)} fps, ${(vBytes * 8 / dt / 1e6).toFixed(2)} Mbit/s, ${vKeys} key), audio ${(audio / 1024 / dt).toFixed(0)} KB/s, config ${cfg ? 'yes' : 'no'}`);
    process.exit(0);
  }, seconds * 1000);
}).listen(port, () => console.log('fake iPad app listening on', port, '+ UDP beacon'));
setTimeout(() => { console.error('timeout: host never connected'); process.exit(2); }, (seconds + 40) * 1000);
