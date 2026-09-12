// Creates a desktop shortcut that starts the host with its own icon (Windows only).
//   node tools/make-shortcut.js
const path = require('path');
const { execFileSync } = require('child_process');

if (process.platform !== 'win32') {
  console.log('Ярлык нужен только на Windows. На macOS запускайте через npm start (или соберите .app).');
  process.exit(0);
}

const root = path.join(__dirname, '..');
const exe = path.join(root, 'node_modules', 'electron', 'dist', 'electron.exe');
const icon = path.join(root, 'assets', 'icon.ico');
const ps = `
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $ws.SpecialFolders('Desktop') 'iPad Display.lnk'))
$lnk.TargetPath = '${exe.replace(/'/g, "''")}'
$lnk.Arguments = '"${root.replace(/"/g, '""')}"'
$lnk.WorkingDirectory = '${root.replace(/'/g, "''")}'
$lnk.IconLocation = '${icon.replace(/'/g, "''")},0'
$lnk.Description = 'iPad Display — второй монитор из старого iPad'
$lnk.Save()
Write-Output $lnk.FullName
`;
try {
  const out = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], { encoding: 'utf8', windowsHide: true });
  console.log('Ярлык создан:', out.trim());
} catch (e) {
  console.error('Не удалось создать ярлык:', e.message);
  process.exit(1);
}
