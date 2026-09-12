// npm run setup — runs the installer for the current platform.
const path = require('path');
const { spawnSync } = require('child_process');

const root = path.join(__dirname, '..');
const args = process.argv.slice(2);
const win = process.platform === 'win32';
const cmd = win ? 'powershell.exe' : 'bash';
const argv = win
  ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'install.ps1'), ...args]
  : [path.join(root, 'install.sh'), ...args];

const r = spawnSync(cmd, argv, { stdio: 'inherit', cwd: root });
process.exit(r.status === null ? 1 : r.status);
