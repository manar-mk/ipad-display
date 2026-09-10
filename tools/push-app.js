// Installs a built IPadDisplay.app onto a jailbroken iPad over the USB SSH tunnel:
// uploads the bundle to /Applications, fake-signs it with the device's ldid, runs uicache.
// usage: node tools/push-app.js <path-to-IPadDisplay.app>     env: IPAD_SSH_PASS (default alpine)
const fs = require('fs');
const path = require('path');
const { Client } = require('ssh2');
const usbmux = require('../usbmux');

const src = process.argv[2];
if (!src || !fs.existsSync(path.join(src, 'Info.plist'))) { console.error('usage: node tools/push-app.js <IPadDisplay.app>'); process.exit(1); }
const name = path.basename(src);
const dest = '/Applications/' + name;

function walk(dir, base = '') {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = path.posix.join(base, e.name);
    if (e.isDirectory()) out.push({ dir: rel }, ...walk(path.join(dir, e.name), rel));
    else out.push({ file: rel, abs: path.join(dir, e.name) });
  }
  return out;
}

const run = (c, cmd) => new Promise((res, rej) => c.exec(cmd, (err, s) => {
  if (err) return rej(err);
  let out = '';
  s.on('data', (d) => { out += d; }); s.stderr.on('data', (d) => { out += d; });
  s.on('close', (code) => res({ code, out: out.trim() }));
}));
const sftpOp = (sftp, fn, ...a) => new Promise((res, rej) => sftp[fn](...a, (e, r) => (e ? rej(e) : res(r))));

(async () => {
  const sock = await usbmux.connect(22);
  const c = new Client();
  await new Promise((res, rej) => {
    c.on('ready', res).on('error', rej).connect({ sock, username: 'root', password: process.env.IPAD_SSH_PASS || 'alpine',
      algorithms: { kex: ['diffie-hellman-group14-sha1', 'diffie-hellman-group1-sha1', 'diffie-hellman-group-exchange-sha256', 'ecdh-sha2-nistp256'],
        serverHostKey: ['ssh-rsa', 'ssh-dss', 'ecdsa-sha2-nistp256'], cipher: ['aes128-ctr', 'aes256-ctr', 'aes128-cbc', '3des-cbc'], hmac: ['hmac-sha1', 'hmac-sha2-256'] } });
  });
  console.log('ssh ok; removing old bundle');
  await run(c, `rm -rf '${dest}'; mkdir -p '${dest}'`);
  const sftp = await new Promise((res, rej) => c.sftp((e, s) => (e ? rej(e) : res(s))));
  for (const it of walk(src)) {
    if (it.dir) { await sftpOp(sftp, 'mkdir', dest + '/' + it.dir).catch(() => {}); continue; }
    await new Promise((res, rej) => sftp.fastPut(it.abs, dest + '/' + it.file, (e) => (e ? rej(e) : res())));
    console.log('  up', it.file);
  }
  // optional launcher next to the app bundle (built by CI): /usr/bin/sblaunch
  const sbl = path.join(path.dirname(src), 'sblaunch');
  if (fs.existsSync(sbl)) {
    await new Promise((res, rej) => sftp.fastPut(sbl, '/usr/bin/sblaunch', (e) => (e ? rej(e) : res())));
    await new Promise((res, rej) => sftp.fastPut(sbl + '.entitlements', '/tmp/sblaunch.entitlements', (e) => (e ? rej(e) : res())));
    const r = await run(c, 'chmod 755 /usr/bin/sblaunch && ldid -S/tmp/sblaunch.entitlements /usr/bin/sblaunch && echo sblaunch installed');
    console.log('  ' + r.out);
  }
  const post = await run(c, `chmod 755 '${dest}/IPadDisplay' && chown -R root:wheel '${dest}' && ldid -S '${dest}/IPadDisplay' && uicache 2>&1; echo "exit=$?"; ls -la '${dest}'`);
  console.log(post.out);
  c.end();
  const launch = await run(c, 'test -x /usr/bin/sblaunch && sblaunch com.manar.ipaddisplay 2>&1 || echo "no sblaunch: open iPad Display on the home screen"');
  console.log('launch: ' + launch.out);
})().catch((e) => { console.error('error:', e.message); process.exit(2); });
