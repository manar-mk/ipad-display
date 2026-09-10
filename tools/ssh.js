// Run a command on the iPad over SSH through the USB tunnel (no iproxy, no port forward needed).
// usage: node tools/ssh.js "<command>"      env: IPAD_SSH_PASS (default: alpine)
const { Client } = require('ssh2');
const usbmux = require('../usbmux');

const cmd = process.argv.slice(2).join(' ') || 'uname -a';
(async () => {
  const sock = await usbmux.connect(22);
  const c = new Client();
  c.on('ready', () => {
    c.exec(cmd, (err, stream) => {
      if (err) { console.error(err.message); process.exit(2); }
      stream.on('data', (d) => process.stdout.write(d));
      stream.stderr.on('data', (d) => process.stderr.write(d));
      stream.on('close', (code) => { c.end(); process.exit(code || 0); });
    });
  });
  c.on('error', (e) => { console.error('ssh:', e.message); process.exit(2); });
  c.connect({ sock, username: 'root', password: process.env.IPAD_SSH_PASS || 'alpine',
    algorithms: { kex: ['diffie-hellman-group14-sha1', 'diffie-hellman-group1-sha1', 'diffie-hellman-group-exchange-sha256', 'ecdh-sha2-nistp256'],
      serverHostKey: ['ssh-rsa', 'ssh-dss', 'ecdsa-sha2-nistp256'], cipher: ['aes128-ctr', 'aes256-ctr', 'aes128-cbc', '3des-cbc'], hmac: ['hmac-sha1', 'hmac-sha2-256'] } });
})().catch((e) => { console.error(e.message); process.exit(2); });
