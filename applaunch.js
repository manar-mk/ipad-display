// Best-effort: start the iPad app without touching the iPad.
//
// A jailbroken device runs OpenSSH, and the CI build ships a tiny `sblaunch` helper next to the app bundle,
// so when the cable is in but nothing answers on the app port we can ask SpringBoard to open it. Everything
// here is optional: no SSH, no password, no helper — we just give up quietly and keep retrying the socket.
const { Client } = require('ssh2');
const usbmux = require('./usbmux');

const BUNDLE = 'com.manar.ipaddisplay';
let busy = false;
let lastTry = 0;

function launchOverUsb({ minInterval = 60000, password = process.env.IPAD_SSH_PASS || 'alpine' } = {}) {
  if (busy || Date.now() - lastTry < minInterval) return Promise.resolve(false);
  busy = true; lastTry = Date.now();
  return new Promise(async (resolve) => {
    let sock;
    const done = (ok, why) => { busy = false; if (why) console.log('[launch] ' + why); resolve(ok); };
    try { sock = await usbmux.connect(22); } catch (e) { return done(false, 'no SSH on the device (' + e.message + ')'); }
    const c = new Client();
    const bail = (e) => { try { c.end(); } catch (_) {} done(false, 'ssh: ' + e.message); };
    c.on('error', bail);
    c.on('ready', () => {
      c.exec('sblaunch ' + BUNDLE + ' 2>&1 || echo no-sblaunch', (err, stream) => {
        if (err) return bail(err);
        let out = '';
        stream.on('data', (d) => { out += d; });
        stream.on('close', () => { c.end(); done(!/no-sblaunch/.test(out), 'iPad app: ' + out.trim()); });
      });
    });
    c.connect({ sock, username: 'root', password, readyTimeout: 8000,
      algorithms: { kex: ['diffie-hellman-group14-sha1', 'diffie-hellman-group1-sha1', 'diffie-hellman-group-exchange-sha256', 'ecdh-sha2-nistp256'],
        serverHostKey: ['ssh-rsa', 'ssh-dss', 'ecdsa-sha2-nistp256'], cipher: ['aes128-ctr', 'aes256-ctr', 'aes128-cbc', '3des-cbc'], hmac: ['hmac-sha1', 'hmac-sha2-256'] } });
  });
}

module.exports = { launchOverUsb };
