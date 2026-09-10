// ipad-display — host side (macOS / Windows). Electron main process.
//
// Responsibilities:
//   * capture the chosen monitor (the renderer does it via getDisplayMedia)
//   * serve the iPad web client over HTTP + push JPEG frames over WebSocket (Wi-Fi)
//   * push frames over a raw TCP socket to the native iPad app (USB via iproxy, or Wi-Fi)
//
// Frame protocol (both transports): one message == one whole JPEG frame.
// The client answers every frame with an ack ('a' text on WebSocket, one byte on TCP).
// A new frame is only sent to a client after its ack, so a slow iPad is never flooded:
// it simply receives fewer frames, always the latest one.

const { app, BrowserWindow, desktopCapturer, ipcMain, session, shell } = require('electron');
const http = require('http');
const fs = require('fs');
const path = require('path');
const net = require('net');
const os = require('os');
const { WebSocketServer } = require('ws');
const QRCode = require('qrcode');
const usbmux = require('./usbmux');

const HTTP_PORT = parseInt(process.env.IPAD_DISPLAY_PORT || '7800', 10);

let win = null;
let selectedSourceId = null;

// ---------- frame distribution ----------
let latestFrame = null; // Buffer with the newest JPEG
let latestSeq = 0;
const wsClients = new Map(); // ws -> { inflight, sentSeq, ip }
const tcp = { socket: null, mode: 'tcp', host: null, port: null, inflight: false, sentSeq: 0, state: 'off', error: null, timer: null, want: false };

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
  ws.send(latestFrame, { binary: true }, (err) => { if (err) st.inflight = false; });
}

function sendTcp() {
  const s = tcp.socket;
  if (!s || tcp.state !== 'connected' || tcp.inflight || !latestFrame || tcp.sentSeq === latestSeq) return;
  tcp.inflight = true;
  tcp.sentSeq = latestSeq;
  const header = Buffer.alloc(4);
  header.writeUInt32BE(latestFrame.length, 0);
  s.write(Buffer.concat([header, latestFrame]));
}

// ---------- push client to the native app: USB via usbmuxd, or plain TCP (Wi-Fi / iproxy) ----------
function tcpConnect(host, port) {
  tcpDisconnect();
  tcp.want = true;
  tcp.mode = 'tcp';
  tcp.host = host;
  tcp.port = port;
  tcpTry();
}

function usbConnect(port) {
  tcpDisconnect();
  tcp.want = true;
  tcp.mode = 'usb';
  tcp.host = 'usb';
  tcp.port = port;
  tcpTry();
}

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
  tcp.state = 'connecting';
  tcp.error = null;
  notifyStatus();
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
  tcp.socket = s;
  s.setNoDelay(true);
  tcp.state = 'connected';
  tcp.inflight = false;
  tcp.sentSeq = 0;
  notifyStatus();
  sendTcp();
  s.on('data', (d) => {
    // any byte from the device == ack of the last frame
    if (d.length) { tcp.inflight = false; sendTcp(); }
  });
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
    ws.on('message', (msg) => {
      const t = msg.toString();
      if (t === 'a') { st.inflight = false; sendWs(ws, st); }
      else if (t === 'hello') { st.sentSeq = 0; st.inflight = false; sendWs(ws, st); }
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
    for (const a of addrs) {
      if (a.family === 'IPv4' && !a.internal) out.push({ name, address: a.address });
    }
  }
  return out;
}

function notifyStatus() {
  if (!win || win.isDestroyed()) return;
  win.webContents.send('status', {
    ws: [...wsClients.values()].map((s) => s.ip),
    tcp: { state: tcp.state, mode: tcp.mode, host: tcp.host, port: tcp.port, error: tcp.error },
  });
}

// ---------- Electron window ----------
function createWindow() {
  win = new BrowserWindow({
    width: 580,
    height: 800,
    title: 'iPad Display',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      backgroundThrottling: false, // keep capturing while the window is hidden / minimized
    },
  });
  win.loadFile('panel.html');
  win.on('closed', () => { win = null; });
}

app.whenReady().then(() => {
  // Electron routes getDisplayMedia() through this handler; hand it the monitor picked in the panel.
  session.defaultSession.setDisplayMediaRequestHandler(async (request, callback) => {
    const sources = await desktopCapturer.getSources({ types: ['screen'] });
    const src = sources.find((s) => s.id === selectedSourceId) || sources[0];
    if (!src) return callback({});
    callback({ video: src });
  });

  createWindow();
  startServer();
  // IPAD_DISPLAY_TCP=host:port — connect to the native app immediately (scripting / tests).
  if (process.env.IPAD_DISPLAY_TCP === 'usb') usbConnect(7801);
  else if (process.env.IPAD_DISPLAY_TCP) {
    const [h, p] = process.env.IPAD_DISPLAY_TCP.split(':');
    tcpConnect(h || '127.0.0.1', parseInt(p || '7801', 10));
  }
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on('window-all-closed', () => { app.quit(); });

// ---------- IPC ----------
ipcMain.handle('get-sources', async () => {
  const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 200, height: 125 } });
  return sources.map((s) => ({ id: s.id, name: s.name, display_id: s.display_id, thumb: s.thumbnail.toDataURL() }));
});
ipcMain.handle('select-source', (e, id) => { selectedSourceId = id; return true; });
ipcMain.handle('get-info', async () => {
  const ips = localIPs();
  const urls = ips.map((i) => 'http://' + i.address + ':' + HTTP_PORT + '/');
  const qr = urls.length ? await QRCode.toDataURL(urls[0], { margin: 1, width: 180 }) : null;
  return { ips, port: HTTP_PORT, urls, qr, platform: process.platform, autostart: !!process.env.IPAD_DISPLAY_AUTOSTART };
});
ipcMain.handle('tcp-connect', (e, host, port) => { tcpConnect(host, port); return true; });
ipcMain.handle('tcp-disconnect', () => { tcpDisconnect(); return true; });
ipcMain.handle('usb-connect', (e, port) => { usbConnect(port); return true; });
ipcMain.handle('usb-list', async () => { try { return { devices: await usbmux.listDevices() }; } catch (e) { return { error: e.message }; } });
ipcMain.handle('open-external', (e, url) => shell.openExternal(url));
ipcMain.on('frame', (e, ab) => onNewFrame(Buffer.from(ab)));
