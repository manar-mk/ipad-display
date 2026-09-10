// Emulates the native iPad app (TCP side): listens on 7801, reads typed messages, acks JPEG frames, beacons on UDP.
const net = require('net');
const dgram = require('dgram');
const fs = require('fs');
const port = parseInt(process.argv[2] || '7801', 10);
const want = parseInt(process.argv[3] || '5', 10);
const beacon = dgram.createSocket('udp4');
beacon.bind(() => { beacon.setBroadcast(true); });
const timer = setInterval(() => beacon.send(`IPADDISPLAY ${port}`, 7802, '255.255.255.255'), 2000);
net.createServer((s) => {
  console.log('host connected from', s.remoteAddress);
  let buf = Buffer.alloc(0), n = 0, audio = 0;
  s.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    while (buf.length >= 4) {
      const len = buf.readUInt32BE(0);
      if (buf.length < 4 + len) break;
      const type = String.fromCharCode(buf[4]), payload = buf.subarray(5, 4 + len); buf = buf.subarray(4 + len);
      if (type === 'F') console.log('audio format', payload.readUInt32BE(0), 'Hz', payload[4], 'ch');
      else if (type === 'A') audio += payload.length;
      else if (type === 'J') {
        n++;
        if (n >= want) { fs.writeFileSync('tools/last-tcp-frame.jpg', payload); console.log(`got ${n} tcp frames, last ${payload.length} bytes, audio ${audio} bytes, saved tools/last-tcp-frame.jpg`); s.write(Buffer.from([0x54, 1, 0x80, 0, 0x80, 0])); setTimeout(() => process.exit(0), 300); return; }
        s.write(Buffer.from([1]));
      }
    }
  });
}).listen(port, () => console.log('fake iPad app listening on', port, '+ UDP beacon'));
setTimeout(() => { console.error('timeout'); process.exit(2); }, 60000);
