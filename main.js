// ipad-display — host side (macOS / Windows). Electron main process.
//
//   * captures the chosen monitor (renderer, getDisplayMedia) + system audio (Windows loopback)
//   * serves the iPad web client over HTTP + WebSocket (Wi-Fi, Safari)
//   * pushes frames/audio to the native iPad app over TCP (Wi-Fi, auto-discovered) or USB (usbmuxd)
//   * receives touch events from the iPad and injects them as mouse input on the captured display
//
// Wire protocol to the native app: [uint32 BE len][uint8 type][payload]
//   'J' JPEG frame (ack'd by the device with byte 0x01), 'F' audio format, 'A' PCM chunk.
//   Device -> host: 0x01 ack, 'T' touch [phase][x16][y16].
// WebSocket (web client): same typed binary messages; text 'a' = ack, text JSON {"t":"touch",...}.

const { app, BrowserWindow, desktopCapturer, ipcMain, session, shell, screen } = require('electron');
const http = require('http');
const fs = require('fs');
const path = require('path');
const net = require('net');
const os = require('os');
const dgram = require('dgram');
const { spawn } = require('child_process');
const { WebSocketServer } = require('ws');
const QRCode = require('qrcode');
const usbmux = require('./usbmux');

const HTTP_PORT = parseInt(process.env.IPAD_DISPLAY_PORT || '7800', 10);
const BEACON_PORT = 7802;
const APP_PORT = 7801;

// ---------- settings ----------
// audioSource: 'auto' (virtual cable such as "CABLE Output" if present, else whole system), 'loopback', or an audio input deviceId
const DEFAULTS = { displayId: null, size: '1024x768', fps: 15, quality: 60, autostart: true, autoconnect: true, audio: true, audioSource: 'auto', touch: true };
let settings = { ...DEFAULTS };
const settingsFile = () => path.join(app.getPath('userData'), 'settings.json');
function loadSettings() { try { settings = { ...DEFAULTS, ...JSON.parse(fs.readFileSync(settingsFile(), 'utf8')) }; } catch (e) { /* first run */ } }
function saveSettings(patch) { settings = { ...settings, ...patch }; try { fs.writeFileSync(settingsFile(), JSON.stringify(settings, null, 2)); } catch (e) { console.error('settings:', e.message); } }

let win = null;
let wantLoopback = true; // renderer sets this right before getDisplayMedia (false when a virtual cable is captured instead)
let selectedSourceId = null;
let selectedDisplay = null; // Electron display object of the captured monitor (for touch mapping)

// ---------- framing ----------
const frameMsg = (type, payload) => { const h = Buffer.alloc(5); h.writeUInt32BE(payload.length + 1, 0); h[4] = type.charCodeAt(0); return Buffer.concat([h, payload]); };

// ---------- frame / audio distribution ----------
let latestFrame = null; // Buffer with the newest JPEG
let latestSeq = 0;
let audioFormat = null; // { rate, channels }
const wsClients = new Map(); // ws -> { inflight, sentSeq, ip }
const tcp = { socket: null, mode: 'tcp', host: null, port: null, inflight: false, sentSeq: 0, state: 'off', error: null, timer: null, want: false, rx: Buffer.alloc(0) };

function onNewFrame(buf) {
  latestFrame = buf;
  latestSeq++;
  for (const [ws, st] of wsClients) sendWs(ws, st);
  sendTcp();
}

function sendWs(ws, st) {
  if (st.inflight || ws.readyState !== ws.OPEN || !latestFrame || st.sentSeq === latestSeq) return;
  st.inflight = true;
  st.sentSeq = latestSeq;
  ws.send(frameMsg('J', latestFrame), { binary: true }, (err) => { if (err) st.inflight = false; });
}

function sendTcp() {
  const s = tcp.socket;
  if (!s || tcp.state !== 'connected' || tcp.inflight || !latestFrame || tcp.sentSeq === latestSeq) return;
  tcp.inflight = true;
  tcp.sentSeq = latestSeq;
  s.write(frameMsg('J', latestFrame));
}

function audioFormatMsg() { const p = Buffer.alloc(5); p.writeUInt32BE(audioFormat.rate, 0); p[4] = audioFormat.channels; return frameMsg('F', p); }

function onAudioFormat(rate, channels) {
  audioFormat = { rate, channels };
  const m = audioFormatMsg();
  if (tcp.socket && tcp.state === 'connected') tcp.socket.write(m);
  for (const [ws] of wsClients) if (ws.readyState === ws.OPEN) ws.send(m, { binary: true });
}

function onAudioChunk(buf) {
  if (!settings.audio) return;
  const m = frameMsg('A', buf);
  if (tcp.socket && tcp.state === 'connected' && tcp.socket.writableLength < 256 * 1024) tcp.socket.write(m);
  for (const [ws] of wsClients) if (ws.readyState === ws.OPEN && ws.bufferedAmount < 256 * 1024) ws.send(m, { binary: true });
}

// ---------- touch -> mouse ----------
let mouseHelper = null;
function mouseCmd(line) {
  if (!settings.touch) return;
  if (process.platform === 'win32') {
    if (!mouseHelper) {
      // A persistent PowerShell process: SetCursorPos + mouse_event per line, no native module needed.
      const script = `
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class M{[DllImport("user32.dll")]public static extern bool SetCursorPos(int x,int y);[DllImport("user32.dll")]public static extern void mouse_event(uint f,uint x,uint y,uint d,UIntPtr e);[DllImport("user32.dll")]public static extern bool SetProcessDpiAwarenessContext(IntPtr c);}'
[M]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null   # per-monitor v2: SetCursorPos takes physical pixels
while ($true) { $l = [Console]::In.ReadLine(); if ($null -eq $l) { break }; $p = $l.Split(' ');
  switch ($p[0]) { 'move' { [M]::SetCursorPos([int]$p[1],[int]$p[2]) } 'down' { [M]::SetCursorPos([int]$p[1],[int]$p[2]); [M]::mouse_event(2,0,0,0,[UIntPtr]::Zero) } 'up' { [M]::SetCursorPos([int]$p[1],[int]$p[2]); [M]::mouse_event(4,0,0,0,[UIntPtr]::Zero) } } }`;
      mouseHelper = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { stdio: ['pipe', 'ignore', 'ignore'], windowsHide: true });
      mouseHelper.on('exit', () => { mouseHelper = null; });
      mouseHelper.on('error', () => { mouseHelper = null; });
    }
    if (mouseHelper) mouseHelper.stdin.write(line + '\n');
  } else if (process.platform === 'darwin') {
    // macOS: persistent python helper using Quartz (pyobjc ships with the system python on many Macs).
    if (!mouseHelper) {
      const py = `
import sys, Quartz
def ev(t, x, y, b=Quartz.kCGMouseButtonLeft):
    e = Quartz.CGEventCreateMouseEvent(None, t, (x, y), b); Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)
for line in sys.stdin:
    p = line.split()
    if not p: continue
    x, y = float(p[1]), float(p[2])
    if p[0] == 'move': ev(Quartz.kCGEventMouseMoved, x, y)
    elif p[0] == 'down': ev(Quartz.kCGEventLeftMouseDown, x, y)
    elif p[0] == 'up': ev(Quartz.kCGEventLeftMouseUp, x, y)
`;
      mouseHelper = spawn('python3', ['-c', py], { stdio: ['pipe', 'ignore', 'ignore'] });
      mouseHelper.on('exit', () => { mouseHelper = null; });
      mouseHelper.on('error', () => { mouseHelper = null; });
    }
    if (mouseHelper) mouseHelper.stdin.write(line + '\n');
  }
}

function onTouch(phase, nx, ny) {
  const d = selectedDisplay || screen.getPrimaryDisplay();
  const b = d.bounds;
  let x, y;
  if (process.platform === 'win32') {
    // physical pixels: origin from nativeOrigin, size = DIP size * this monitor's scale factor
    const o = d.nativeOrigin || { x: b.x * d.scaleFactor, y: b.y * d.scaleFactor };
    x = Math.round(o.x + nx * b.width * d.scaleFactor);
    y = Math.round(o.y + ny * b.height * d.scaleFactor);
  } else {
    x = Math.round(b.x + nx * b.width); y = Math.round(b.y + ny * b.height); // macOS: points
  }
  mouseCmd((phase === 0 ? 'down' : phase === 2 ? 'up' : 'move') + ' ' + x + ' ' + y);
}

// Device -> host bytes on the TCP socket: 0x01 ack, 'T' touch (6 bytes)
function onDeviceData(d) {
  tcp.rx = Buffer.concat([tcp.rx, d]);
  for (;;) {
    if (!tcp.rx.length) return;
    const t = tcp.rx[0];
    if (t === 0x01) { tcp.rx = tcp.rx.subarray(1); tcp.inflight = false; sendTcp(); continue; }
    if (t === 0x54 /* 'T' */) {
      if (tcp.rx.length < 6) return;
      onTouch(tcp.rx[1], tcp.rx.readUInt16BE(2) / 65535, tcp.rx.readUInt16BE(4) / 65535);
      tcp.rx = tcp.rx.subarray(6);
      continue;
    }
    tcp.rx = tcp.rx.subarray(1); // unknown byte: skip
  }
}

// ---------- push client to the native app: USB via usbmuxd, or plain TCP (Wi-Fi) ----------
function tcpConnect(host, port) { tcpDisconnect(); Object.assign(tcp, { want: true, mode: 'tcp', host, port }); tcpTry(); }
function usbConnect(port) { tcpDisconnect(); Object.assign(tcp, { want: true, mode: 'usb', host: 'usb', port }); tcpTry(); }

function dial() {
  if (tcp.mode === 'usb') return usbmux.connect(tcp.port);
  return new Promise((resolve, reject) => {
    const c = net.connect({ host: tcp.host, port: tcp.port });
    c.once('connect', () => resolve(c));
    c.once('error', reject);
  });
}

async function tcpTry() {
  if (!tcp.want) return;
  tcp.state = 'connecting'; tcp.error = null; notifyStatus();
  let s;
  try { s = await dial(); }
  catch (e) {
    tcp.error = e.message;
    tcp.state = tcp.want ? 'retrying' : 'off';
    notifyStatus();
    if (tcp.want) tcp.timer = setTimeout(tcpTry, 2000);
    return;
  }
  if (!tcp.want) { s.destroy(); return; }
  tcp.socket = s; tcp.rx = Buffer.alloc(0);
  s.setNoDelay(true);
  tcp.state = 'connected'; tcp.inflight = false; tcp.sentSeq = 0;
  notifyStatus();
  if (audioFormat) s.write(audioFormatMsg());
  sendTcp();
  s.on('data', onDeviceData);
  const drop = () => {
    if (tcp.socket !== s) return;
    tcp.socket = null;
    tcp.state = tcp.want ? 'retrying' : 'off';
    notifyStatus();
    if (tcp.want) tcp.timer = setTimeout(tcpTry, 1500);
  };
  s.on('error', drop);
  s.on('close', drop);
}

function tcpDisconnect() {
  tcp.want = false;
  clearTimeout(tcp.timer);
  if (tcp.socket) { tcp.socket.destroy(); tcp.socket = null; }
  tcp.state = 'off';
  notifyStatus();
}

// ---------- auto-connect: LAN beacon from the iPad app (Wi-Fi first), USB as fallback ----------
const discovered = new Map(); // ip -> { port, seen }
function startDiscovery() {
  const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  sock.on('message', (msg, rinfo) => {
    const m = /^IPADDISPLAY (\d+)/.exec(msg.toString());
    if (!m) return;
    discovered.set(rinfo.address, { port: parseInt(m[1], 10), seen: Date.now() });
    notifyStatus();
    // The app only beacons while no host is connected, so a beacon means it is free: take it over Wi-Fi.
    if (settings.autoconnect && tcp.state !== 'connected' && !(tcp.mode === 'tcp' && tcp.host === rinfo.address && tcp.want)) {
      console.log('auto-connect Wi-Fi ->', rinfo.address);
      tcpConnect(rinfo.address, parseInt(m[1], 10));
    }
  });
  sock.on('error', (e) => console.error('discovery:', e.message));
  sock.bind(BEACON_PORT);

  // USB fallback: nothing connected and a device sits on the cable -> try usbmuxd.
  setInterval(async () => {
    for (const [ip, d] of discovered) if (Date.now() - d.seen > 10000) discovered.delete(ip);
    if (!settings.autoconnect || tcp.state === 'connected' || tcp.state === 'connecting') return;
    if (tcp.want && Date.now() - (tcp.since || 0) < 15000) return; // give the current attempt a chance
    try {
      const devs = await usbmux.listDevices();
      if (devs.length && !(tcp.mode === 'usb' && tcp.want)) { console.log('auto-connect USB'); usbConnect(APP_PORT); tcp.since = Date.now(); }
    } catch (e) { /* no usbmuxd on this machine */ }
  }, 5000);
}

// ---------- HTTP + WebSocket (Wi-Fi web client) ----------
const CLIENT_DIR = path.join(__dirname, 'client');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.ico': 'image/x-icon' };

function startServer() {
  const server = http.createServer((req, res) => {
    let p = req.url.split('?')[0];
    if (p === '/') p = '/index.html';
    const file = path.join(CLIENT_DIR, path.normalize(p));
    if (!file.startsWith(CLIENT_DIR)) { res.writeHead(403); return res.end(); }
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); return res.end('not found'); }
      res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
      res.end(data);
    });
  });

  const wss = new WebSocketServer({ server, perMessageDeflate: false });
  wss.on('connection', (ws, req) => {
    const st = { inflight: false, sentSeq: 0, ip: req.socket.remoteAddress };
    wsClients.set(ws, st);
    notifyStatus();
    if (audioFormat) ws.send(audioFormatMsg(), { binary: true });
    ws.on('message', (msg) => {
      const t = msg.toString();
      if (t === 'a') { st.inflight = false; sendWs(ws, st); }
      else if (t === 'hello') { st.sentSeq = 0; st.inflight = false; sendWs(ws, st); }
      else if (t[0] === '{') { try { const j = JSON.parse(t); if (j.t === 'touch') onTouch(j.phase, j.x, j.y); } catch (e) { /* ignore */ } }
    });
    ws.on('close', () => { wsClients.delete(ws); notifyStatus(); });
    ws.on('error', () => {});
    sendWs(ws, st);
  });

  server.on('error', (e) => {
    console.error('HTTP server error:', e.message);
    if (win && !win.isDestroyed()) win.webContents.send('server-error', e.message);
  });
  server.listen(HTTP_PORT, '0.0.0.0', () => console.log('Serving iPad client on http://0.0.0.0:' + HTTP_PORT));
}

function localIPs() {
  const out = [];
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs) if (a.family === 'IPv4' && !a.internal) out.push({ name, address: a.address });
  }
  return out;
}

function notifyStatus() {
  if (!win || win.isDestroyed()) return;
  win.webContents.send('status', {
    ws: [...wsClients.values()].map((s) => s.ip),
    tcp: { state: tcp.state, mode: tcp.mode, host: tcp.host, port: tcp.port, error: tcp.error },
    discovered: [...discovered.keys()],
  });
}

// ---------- capture source selection ----------
async function pickSource() {
  const sources = await desktopCapturer.getSources({ types: ['screen'] });
  const displays = screen.getAllDisplays();
  const byId = (id) => sources.find((s) => String(s.display_id) === String(id));
  let src = selectedSourceId && sources.find((s) => s.id === selectedSourceId);
  if (!src && settings.displayId) src = byId(settings.displayId);
  if (!src) { // prefer a secondary 4:3 display, i.e. the 1024x768 Virtual Display Driver monitor
    const primary = screen.getPrimaryDisplay().id;
    const virt = displays.find((d) => d.id !== primary && Math.abs(d.bounds.width / d.bounds.height - 4 / 3) < 0.02);
    if (virt) src = byId(virt.id);
  }
  if (!src) src = sources[0];
  if (src) { selectedSourceId = src.id; selectedDisplay = displays.find((d) => String(d.id) === String(src.display_id)) || null; }
  return src;
}

// ---------- Electron window ----------
function createWindow() {
  win = new BrowserWindow({
    width: 600, height: 880, title: 'iPad Display',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, backgroundThrottling: false },
  });
  win.loadFile('panel.html');
  win.on('closed', () => { win = null; });
}

app.whenReady().then(() => {
  loadSettings();
  if (process.env.IPAD_DISPLAY_AUTOSTART) settings.autostart = true;
  session.defaultSession.setDisplayMediaRequestHandler(async (request, callback) => {
    const src = await pickSource();
    if (!src) return callback({});
    // 'loopback' = system audio (Windows only; Chromium on macOS has no loopback source).
    // The renderer asks for audio here only when the source is "whole system"; a virtual cable is captured via getUserMedia instead.
    callback(process.platform === 'win32' && settings.audio && wantLoopback ? { video: src, audio: 'loopback' } : { video: src });
  });
  for (const d of screen.getAllDisplays()) console.log('display', d.id, JSON.stringify(d.bounds), 'scale', d.scaleFactor, 'native', JSON.stringify(d.nativeOrigin || null), d.id === screen.getPrimaryDisplay().id ? 'primary' : '');
  createWindow();
  startServer();
  startDiscovery();
  if (process.env.IPAD_DISPLAY_TCP === 'usb') usbConnect(APP_PORT);
  else if (process.env.IPAD_DISPLAY_TCP) { const [h, p] = process.env.IPAD_DISPLAY_TCP.split(':'); tcpConnect(h || '127.0.0.1', parseInt(p || '7801', 10)); }
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on('window-all-closed', () => { app.quit(); });
app.on('will-quit', () => { if (mouseHelper) mouseHelper.kill(); });

// ---------- IPC ----------
ipcMain.handle('get-sources', async () => {
  const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 200, height: 125 } });
  const displays = screen.getAllDisplays();
  const chosen = await pickSource();
  return sources.map((s) => {
    const d = displays.find((x) => String(x.id) === String(s.display_id));
    return { id: s.id, name: s.name, display_id: s.display_id, thumb: s.thumbnail.toDataURL(), bounds: d && d.bounds, selected: !!chosen && chosen.id === s.id };
  });
});
ipcMain.handle('select-source', async (e, id) => {
  selectedSourceId = id;
  const sources = await desktopCapturer.getSources({ types: ['screen'] });
  const s = sources.find((x) => x.id === id);
  if (s) { saveSettings({ displayId: s.display_id }); selectedDisplay = screen.getAllDisplays().find((d) => String(d.id) === String(s.display_id)) || null; }
  return true;
});
ipcMain.handle('get-info', async () => {
  const ips = localIPs();
  const urls = ips.map((i) => 'http://' + i.address + ':' + HTTP_PORT + '/');
  const qr = urls.length ? await QRCode.toDataURL(urls[0], { margin: 1, width: 180 }) : null;
  return { ips, port: HTTP_PORT, urls, qr, platform: process.platform, settings, autostart: settings.autostart };
});
ipcMain.handle('save-settings', (e, patch) => { saveSettings(patch); return settings; });
ipcMain.handle('set-loopback', (e, v) => { wantLoopback = !!v; return true; });
ipcMain.handle('tcp-connect', (e, host, port) => { tcpConnect(host, port); return true; });
ipcMain.handle('tcp-disconnect', () => { tcpDisconnect(); return true; });
ipcMain.handle('usb-connect', (e, port) => { usbConnect(port); return true; });
ipcMain.handle('usb-list', async () => { try { return { devices: await usbmux.listDevices() }; } catch (e) { return { error: e.message }; } });
ipcMain.handle('open-external', (e, url) => shell.openExternal(url));
ipcMain.handle('install-vdd', () => new Promise((resolve) => {
  if (process.platform !== 'win32') return resolve({ error: 'Только для Windows. На macOS используйте DeskPad или BetterDisplay.' });
  const script = path.join(__dirname, 'driver', 'windows', 'install-vdd.ps1');
  const log = path.join(app.getPath('userData'), 'vdd-install.log');
  const inner = `& '${script}' *> '${log}'`;
  const ps = spawn('powershell.exe', ['-NoProfile', '-Command', `Start-Process powershell -Verb RunAs -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',${JSON.stringify(inner)})`], { windowsHide: true });
  ps.on('exit', (code) => { let out = ''; try { out = fs.readFileSync(log, 'utf8'); } catch (e) { /* no log */ } resolve({ code, out }); });
}));
ipcMain.on('frame', (e, ab) => onNewFrame(Buffer.from(ab)));
ipcMain.on('audio-format', (e, rate, channels) => onAudioFormat(rate, channels));
ipcMain.on('audio', (e, ab) => onAudioChunk(Buffer.from(ab)));
