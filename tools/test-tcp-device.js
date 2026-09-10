// Emulates the native iPad app (TCP side): listens on 7801, reads length-prefixed JPEGs, acks each.
const net = require('net');
const fs = require('fs');
const port = parseInt(process.argv[2] || '7801', 10);
const want = parseInt(process.argv[3] || '5', 10);
net.createServer((s) => {
  console.log('host connected from', s.remoteAddress);
  let buf = Buffer.alloc(0), n = 0;
  s.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    while (buf.length >= 4) {
      const len = buf.readUInt32BE(0);
      if (buf.length < 4 + len) break;
      const frame = buf.subarray(4, 4 + len); buf = buf.subarray(4 + len);
      n++;
      if (n >= want) { fs.writeFileSync('tools/last-tcp-frame.jpg', frame); console.log(`got ${n} tcp frames, last ${len} bytes, saved tools/last-tcp-frame.jpg`); process.exit(0); }
      s.write(Buffer.from([1]));
    }
  });
}).listen(port, () => console.log('fake iPad app listening on', port));
setTimeout(() => { console.error('timeout'); process.exit(2); }, 30000);
