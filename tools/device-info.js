// Asks the iPad (via usbmuxd) who it is and probes a few ports.
// lockdownd GetValue works without pairing for basic keys (ProductType, ProductVersion, DeviceName).
const usbmux = require('../usbmux');
const plist = require('plist');

function lockdownRequest(sock, dict) {
  return new Promise((resolve, reject) => {
    let buf = Buffer.alloc(0);
    const onData = (d) => {
      buf = Buffer.concat([buf, d]);
      if (buf.length < 4) return;
      const len = buf.readUInt32BE(0);
      if (buf.length < 4 + len) return;
      sock.removeListener('data', onData);
      try { resolve(plist.parse(buf.subarray(4, 4 + len).toString('utf8'))); } catch (e) { reject(e); }
    };
    sock.on('data', onData);
    sock.once('error', reject);
    const body = Buffer.from(plist.build({ Label: 'ipad-display', ...dict }), 'utf8');
    const h = Buffer.alloc(4); h.writeUInt32BE(body.length, 0);
    sock.write(Buffer.concat([h, body]));
    setTimeout(() => reject(new Error('timeout')), 5000);
  });
}

(async () => {
  const devs = await usbmux.listDevices();
  if (!devs.length) { console.log('no USB device'); process.exit(1); }
  const id = devs[0].id;
  try {
    const s = await usbmux.connect(62078, id);
    const r = await lockdownRequest(s, { Request: 'GetValue' });
    s.destroy();
    const v = r.Value || {};
    console.log('device:', { name: v.DeviceName, product: v.ProductType, ios: v.ProductVersion, build: v.BuildVersion, cpu: v.CPUArchitecture, hw: v.HardwareModel });
    if (r.Error) console.log('lockdown error:', r.Error);
  } catch (e) { console.log('lockdown:', e.message); }
  for (const [port, what] of [[22, 'OpenSSH (jailbreak)'], [44, 'dropbear/other ssh'], [7801, 'iPad Display app']]) {
    try { const s = await usbmux.connect(port, id); s.destroy(); console.log('port', port, 'OPEN  -', what); }
    catch (e) { console.log('port', port, 'closed -', what); }
  }
})().catch((e) => { console.error(e.message); process.exit(2); });
