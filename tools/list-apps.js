// Lists user-installed apps on the iPad via lockdownd + installation_proxy.
// Needs a pairing record ("Trust this computer" done once). Windows keeps them in
// C:\ProgramData\Apple\Lockdown\<udid>.plist, macOS in /var/db/lockdown/<udid>.plist.
const fs = require('fs');
const path = require('path');
const tls = require('tls');
const plist = require('plist');
const bplist = require('bplist-parser');
const parseAny = (b) => b.subarray(0, 6).toString() === 'bplist' ? bplist.parseBuffer(b)[0] : plist.parse(b.toString('utf8'));
const usbmux = require('../usbmux');

const LOCKDOWN_DIRS = process.platform === 'win32' ? ['C:\\ProgramData\\Apple\\Lockdown'] : ['/var/db/lockdown'];

function readPairRecord(udid) {
  for (const d of LOCKDOWN_DIRS) {
    const f = path.join(d, udid + '.plist');
    if (fs.existsSync(f)) return plist.parse(fs.readFileSync(f, 'utf8'));
  }
  throw new Error('нет записи доверия для ' + udid + ' — нажмите Trust в Apple Devices и на iPad');
}

// Framed plist exchange used by lockdownd and most services: 4-byte BE length + XML plist.
function makeChannel(sock) {
  let buf = Buffer.alloc(0);
  const waiters = [];
  sock.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    while (buf.length >= 4) {
      const len = buf.readUInt32BE(0);
      if (buf.length < 4 + len) break;
      const msg = parseAny(buf.subarray(4, 4 + len));
      buf = buf.subarray(4 + len);
      const w = waiters.shift();
      if (w) w(msg);
    }
  });
  return {
    send(dict) {
      const body = Buffer.from(plist.build(dict), 'utf8');
      const h = Buffer.alloc(4); h.writeUInt32BE(body.length, 0);
      sock.write(Buffer.concat([h, body]));
    },
    recv() { return new Promise((res) => waiters.push(res)); },
    async call(dict) { this.send(dict); return this.recv(); },
  };
}

function upgradeTLS(sock, rec) {
  sock.removeAllListeners('data');
  return new Promise((resolve, reject) => {
    const t = tls.connect({ socket: sock, cert: rec.HostCertificate, key: rec.HostPrivateKey, rejectUnauthorized: false, minVersion: 'TLSv1' }, () => resolve(t));
    t.once('error', reject);
  });
}

(async () => {
  const devs = await usbmux.listDevices();
  if (!devs.length) throw new Error('iPad по USB не найден');
  const dev = devs[0];
  const rec = readPairRecord(dev.serial);

  // 1. lockdownd session
  let sock = await usbmux.connect(62078, dev.id);
  let ld = makeChannel(sock);
  const ss = await ld.call({ Label: 'ipad-display', Request: 'StartSession', HostID: rec.HostID, SystemBUID: rec.SystemBUID });
  if (ss.Error) throw new Error('StartSession: ' + ss.Error + (ss.Error === 'InvalidHostID' ? ' (запись доверия устарела, нажмите Trust заново)' : ''));
  if (ss.EnableSessionSSL) { sock = await upgradeTLS(sock, rec); ld = makeChannel(sock); }

  // 2. start installation_proxy
  const svc = await ld.call({ Label: 'ipad-display', Request: 'StartService', Service: 'com.apple.mobile.installation_proxy' });
  if (svc.Error) throw new Error('StartService: ' + svc.Error + (svc.Error === 'PasswordProtected' ? ' (разблокируйте iPad)' : ''));
  sock.destroy();

  let ssock = await usbmux.connect(svc.Port, dev.id);
  if (svc.EnableServiceSSL) ssock = await upgradeTLS(ssock, rec);
  const ip = makeChannel(ssock);
  ip.send({ Command: 'Browse', ClientOptions: { ApplicationType: process.argv[2] || 'User', ReturnAttributes: ['CFBundleIdentifier', 'CFBundleDisplayName', 'CFBundleShortVersionString', 'SignerIdentity'] } });

  const apps = [];
  for (;;) {
    const m = await ip.recv();
    if (m.CurrentList) apps.push(...m.CurrentList);
    if (m.Status === 'Complete') break;
  }
  ssock.destroy();
  console.log('Приложения (' + (process.argv[2] || 'User') + ') на ' + dev.serial.slice(0, 8) + '…: ' + apps.length);
  for (const a of apps.sort((x, y) => (x.CFBundleDisplayName || '').localeCompare(y.CFBundleDisplayName || ''))) {
    console.log('  ' + (a.CFBundleDisplayName || '?').padEnd(24) + (a.CFBundleIdentifier || '').padEnd(40) + (a.CFBundleShortVersionString || ''));
  }
  const has = (re) => apps.some((a) => re.test(a.CFBundleIdentifier + ' ' + a.CFBundleDisplayName));
  console.log('\nEverPwnage: ' + (has(/everpwnage|ios8-jailbreak|jailbreak/i) ? 'есть' : 'нет') + '   Cydia: ' + (has(/cydia/i) ? 'есть' : 'нет') + '   Zebra: ' + (has(/zebra|xyz\.willy/i) ? 'есть' : 'нет') + '   iPad Display: ' + (has(/ipaddisplay/i) ? 'есть' : 'нет'));
  process.exit(0);
})().catch((e) => { console.error('ошибка:', e.message); process.exit(2); });
