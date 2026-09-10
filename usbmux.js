// Minimal usbmuxd client: list USB-attached iOS devices and open a TCP tunnel to a
// port on the device. Replaces `iproxy` — the host talks to usbmuxd directly.
//
// usbmuxd is provided by macOS itself and, on Windows, by iTunes / the "Apple Devices"
// app ("Apple Mobile Device Service", listening on 127.0.0.1:27015).
//
// Wire format: 16-byte little-endian header { length, version=1, type=8 (plist), tag }
// followed by an XML plist. After a successful Connect the same socket becomes the tunnel.

const net = require('net');
const plist = require('plist');

const WIN_ADDR = { host: '127.0.0.1', port: 27015 };
const UNIX_PATH = '/var/run/usbmuxd';

function open() {
  return new Promise((resolve, reject) => {
    const s = process.platform === 'win32' ? net.connect(WIN_ADDR) : net.connect(UNIX_PATH);
    s.once('connect', () => resolve(s));
    s.once('error', (e) => reject(new Error('usbmuxd недоступен (' + e.code + '). На Windows установите iTunes или приложение "Apple Devices".')));
  });
}

function encode(dict, tag) {
  const body = Buffer.from(plist.build(dict), 'utf8');
  const h = Buffer.alloc(16);
  h.writeUInt32LE(16 + body.length, 0);
  h.writeUInt32LE(1, 4);
  h.writeUInt32LE(8, 8);
  h.writeUInt32LE(tag, 12);
  return Buffer.concat([h, body]);
}

// Send one request, resolve with the parsed plist reply. Leaves the socket open.
function request(sock, dict, tag = 1) {
  return new Promise((resolve, reject) => {
    let buf = Buffer.alloc(0);
    const onData = (d) => {
      buf = Buffer.concat([buf, d]);
      if (buf.length < 16) return;
      const len = buf.readUInt32LE(0);
      if (buf.length < len) return;
      sock.removeListener('data', onData);
      sock.removeListener('error', onErr);
      try { resolve(plist.parse(buf.subarray(16, len).toString('utf8'))); } catch (e) { reject(e); }
    };
    const onErr = (e) => { sock.removeListener('data', onData); reject(e); };
    sock.on('data', onData);
    sock.once('error', onErr);
    sock.write(encode({ ...dict, ClientVersionString: 'ipad-display', ProgName: 'ipad-display' }, tag));
  });
}

async function listDevices() {
  const s = await open();
  try {
    const r = await request(s, { MessageType: 'ListDevices' });
    return (r.DeviceList || [])
      .filter((d) => d.Properties && d.Properties.ConnectionType === 'USB')
      .map((d) => ({ id: d.DeviceID, serial: d.Properties.SerialNumber, productId: d.Properties.ProductID }));
  } finally { s.destroy(); }
}

const RESULT = { 0: 'OK', 2: 'устройство не найдено', 3: 'устройство отклонило соединение (приложение iPad Display не запущено?)', 5: 'malformed request' };

// Returns a connected net.Socket tunnelled to `port` on the device.
async function connect(port, deviceId) {
  if (deviceId == null) {
    const devs = await listDevices();
    if (!devs.length) throw new Error('iPad по USB не найден (usbmuxd не видит устройств)');
    deviceId = devs[0].id;
  }
  const s = await open();
  const r = await request(s, { MessageType: 'Connect', DeviceID: deviceId, PortNumber: ((port & 0xff) << 8) | ((port >> 8) & 0xff) });
  if (r.Number !== 0) { s.destroy(); throw new Error('usbmuxd Connect: ' + (RESULT[r.Number] || 'код ' + r.Number)); }
  return s;
}

module.exports = { listDevices, connect };
