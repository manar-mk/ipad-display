// Local TCP port forward into the iPad over USB (iproxy replacement).
// usage: node tools/usb-forward.js <localPort> <devicePort>   e.g. 2222 22
const net = require('net');
const usbmux = require('../usbmux');
const local = parseInt(process.argv[2] || '2222', 10);
const remote = parseInt(process.argv[3] || '22', 10);
net.createServer(async (c) => {
  try {
    const d = await usbmux.connect(remote);
    c.pipe(d).pipe(c);
    c.on('error', () => d.destroy()); d.on('error', () => c.destroy());
  } catch (e) { console.error('connect failed:', e.message); c.destroy(); }
}).listen(local, '127.0.0.1', () => console.log(`127.0.0.1:${local} -> iPad:${remote}`));
