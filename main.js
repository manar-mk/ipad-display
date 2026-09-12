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

const { app, BrowserWindow, desktopCapturer, ipcMain, session, shell, screen, systemPreferences } = require('electron');
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
const applaunch = require('./applaunch');

const HTTP_PORT = parseInt(process.env.IPAD_DISPLAY_PORT || '7800', 10);
const BEACON_PORT = 7802;
const APP_PORT = 7801;

// ---------- settings ----------
// audioSource: 'auto' (virtual cable such as "CABLE Output" if present, else whole system), 'loopback', or an audio input deviceId
// codec: 'auto' (H.264 to the native app when WebCodecs can encode it, JPEG otherwise), 'h264', 'jpeg'; bitrate in kbit/s
const DEFAULTS = { displayId: null, size: '1024x768', fps: 60, quality: 60, autostart: true, autoconnect: true, audio: true, audioSource: 'auto', touch: true, codec: 'auto', bitrate: 6000, manageDisplay: true, manageAudio: true, audioDefault: false, lang: 'auto', autolaunch: true };
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
  if (ext.active) return; // the app is on the ffmpeg H.264 stream; JPEG would switch it back
  if (!s || tcp.state !== 'connected' || tcp.inflight || !latestFrame || tcp.sentSeq === latestSeq) return;
  tcp.inflight = true;
  tcp.sentSeq = latestSeq;
  s.write(frameMsg('J', latestFrame));
}

function audioFormatMsg() { const p = Buffer.alloc(5); p.writeUInt32BE(audioFormat.rate, 0); p[4] = audioFormat.channels; return frameMsg('F', p); }

// ---------- H.264 to the native app: 'H' avcC config, 'V' frames ----------
let videoConfig = null;   // Buffer (avcC), re-sent on every new connection
let needKey = true;       // next frame we forward must be a keyframe (new connection / backlog / device request)
const VIDEO_BACKLOG = 600 * 1024;
const videoStats = { frames: 0, bytes: 0, dropped: 0, t: Date.now() };
// Latency probe: the iPad echoes the pts of every frame it hands to the decoder ('P'); we remember when we
// sent each pts and keep an EMA of (now - sent). This covers network + decode queue, not capture/encode.
const ptsSent = new Map();
let latencyMs = null;
function onPresented(pts) {
  const t = ptsSent.get(pts);
  if (t === undefined) return;
  const l = Date.now() - t;
  latencyMs = latencyMs === null ? l : latencyMs * 0.9 + l * 0.1;
}

// ---------- external hardware encoder: ffmpeg ddagrab + h264_mf (Windows), avfoundation + h264_videotoolbox (macOS) ----------
const ffenc = require('./ffenc');
const MAC = process.platform === 'darwin';
const ext = { path: null, outputs: null, enc: null, active: false, starting: false, restartTimer: null, lastStart: 0 };
ext.path = (process.platform === 'win32' || MAC) ? ffenc.findFfmpeg() : null;
function encoderMode() {
  const c = settings.codec;
  if (c === 'ffmpeg') return ext.path ? 'ffmpeg' : 'webcodecs';
  if (c === 'auto') return ext.path ? 'ffmpeg' : 'webcodecs';
  return c; // 'h264' (WebCodecs) or 'jpeg'
}
async function externalOutputIdx() {
  // one shared probe: two concurrent avfoundation screen captures hang each other (Wi-Fi connect followed by the USB switch)
  if (!ext.outputs) ext.outputs = ffenc.probeOutputs(ext.path);
  ext.outputs = await ext.outputs;
  const d = selectedDisplay || screen.getPrimaryDisplay();
  const pw = Math.round(d.bounds.width * d.scaleFactor), ph = Math.round(d.bounds.height * d.scaleFactor);
  const hit = ext.outputs.find((o) => o.width === pw && o.height === ph) || ext.outputs.find((o) => Math.abs(o.width / o.height - 4 / 3) < 0.02);
  return hit ? hit.idx : null;
}
async function startExternal() {
  if (encoderMode() !== 'ffmpeg' || ext.active || ext.starting) return;
  ext.starting = true;
  let idx;
  try { idx = await externalOutputIdx(); } finally { ext.starting = false; }
  if (ext.active || tcp.state !== 'connected') return; // disconnected (or restarted) while probing
  if (idx === null) { console.error('[ffmpeg] no capture output matches the captured display; falling back to WebCodecs'); ext.path = null; return; }
  if (!ext.enc) ext.enc = new ffenc.FfmpegEncoder(ext.path);
  ext.active = true; ext.lastStart = Date.now();
  ext.enc.onConfig = (avcC) => onVideoConfig(avcC);
  ext.enc.onFrame = (avcc, key) => onVideoChunk(avcc, key, Date.now() >>> 0);
  ext.enc.onExit = (code) => { if (ext.active) { console.error('[ffmpeg] exited', code, '- restarting'); ext.active = false; setTimeout(startExternal, 1000); } };
  const max = /^(\d+)x(\d+)$/.exec(settings.size || ''); // macOS: fit a Retina/large screen into the configured size
  ext.enc.start({ outputIdx: idx, fps: Math.min(60, Math.max(15, settings.fps || 60)), bitrateKbps: settings.bitrate || 8000, gop: 120,
    maxSize: MAC && max && +max[1] > 0 ? [+max[1], +max[2]] : null });
  console.log('[ffmpeg] started on capture output', idx);
}
function stopExternal() { ext.active = false; clearTimeout(ext.restartTimer); if (ext.enc) ext.enc.stop(); stopExternalAudio(); }

// ---------- Windows session: attach/detach the virtual monitor, move the default sound device ----------
// On Windows the virtual display is an installed driver and the cable is a permanent device: without this
// they stay in the system after the host stops (a phantom screen, sound going nowhere). On macOS the virtual
// display lives only while the vdisplay helper runs, so nothing to undo there.
const WIN = process.platform === 'win32';
// driver/ holds things external tools must read or run (PowerShell scripts, the VDD driver, Swift helpers):
// in a packaged app it is unpacked next to app.asar (electron-builder asarUnpack), so use that real path.
const DRIVER_DIR = path.join(__dirname, 'driver').replace(/app\.asar([\\/])/, 'app.asar.unpacked$1');
const SESSION_PS = path.join(DRIVER_DIR, 'windows', 'session.ps1');
let sessionOn = false;
function runSession(action, sync) {
  if (!WIN) return Promise.resolve('');
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SESSION_PS, '-Action', action];
  if (sync) {
    try { const r = require('child_process').spawnSync('powershell.exe', args, { windowsHide: true, encoding: 'utf8', timeout: 20000 }); console.log('[session]', action, ((r.stdout || '') + (r.stderr || '')).trim()); } catch (e) { console.error('[session]', action, e.message); }
    return Promise.resolve('');
  }
  return new Promise((resolve) => {
    const p = spawn('powershell.exe', args, { windowsHide: true });
    let out = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { out += d; });
    p.on('exit', () => { console.log('[session]', action, out.trim()); resolve(out.trim()); });
    p.on('error', (e) => { console.error('[session]', action, e.message); resolve(''); });
    setTimeout(() => { try { p.kill(); } catch (e) { /* gone */ } resolve(''); }, 25000);
  });
}
function sessionHint(text) { if (win && !win.isDestroyed()) win.webContents.send('session-hint', text); }
async function sessionStart() {
  if (!WIN || sessionOn) return;
  sessionOn = true;
  sessionHint('');
  if (settings.manageDisplay) await runSession('attach');
  if (settings.manageAudio) await runSession('audio-show');
  if (settings.audioDefault) {
    const r = await runSession('audio-cable');
    // some vendor audio panels (Nahimic, Realtek, SteelSeries Sonar) force their own default device back
    if (/to-cable-failed/.test(r)) sessionHint('defaultFailed'); // the panel turns the key into text
  }
}
async function sessionStop(sync, why) {
  if (!WIN || !sessionOn) return;
  console.log('[session] stop (' + (why || '?') + ')');
  sessionOn = false;
  if (settings.audioDefault) await runSession('audio-restore', sync);
  if (settings.manageAudio) await runSession('audio-hide', sync);
  if (settings.manageDisplay) await runSession('detach', sync);
}

// ffmpeg capture (dshow / avfoundation) of the virtual cable for the app (see onAudioChunk); the renderer path stays for Safari.
const CABLE_RE = /CABLE Output|VB-Audio|Virtual Cable|BlackHole|iPad/i; // VB-CABLE on Windows, BlackHole on macOS
const extAudio = { device: null, probed: 0, cap: null, active: false };
async function startExternalAudio() {
  if (!settings.audio || !ext.path || extAudio.active) return;
  if (!extAudio.device && Date.now() - extAudio.probed > 30000) { // no cable yet: look again on later connects (it may get installed meanwhile)
    extAudio.probed = Date.now();
    const names = await ffenc.listAudioDevices(ext.path);
    extAudio.device = names.find((n) => CABLE_RE.test(n)) || null;
    console.log('[ffmpeg-audio] devices:', names.join(' | '), '-> using', extAudio.device);
  }
  if (!extAudio.device || tcp.state !== 'connected') return;
  if (!extAudio.cap) extAudio.cap = new ffenc.AudioCapture(ext.path);
  extAudio.active = true;
  if (!audioFormat || audioFormat.rate !== 22050 || audioFormat.channels !== 1) onAudioFormat(22050, 1);
  else if (tcp.socket) tcp.socket.write(audioFormatMsg());
  extAudio.cap.onChunk = (buf) => onAudioChunk(buf, 'ffmpeg');
  extAudio.cap.onExit = (code) => { if (extAudio.active) { console.error('[ffmpeg-audio] exited', code, '- restarting'); extAudio.active = false; setTimeout(startExternalAudio, 1000); } };
  extAudio.cap.start({ device: extAudio.device, rate: 22050, chunkSamples: 2048 });
  console.log('[ffmpeg-audio] started on', extAudio.device);
}
function stopExternalAudio() { extAudio.active = false; if (extAudio.cap) extAudio.cap.stop(); }

function requestKeyframe(why) {
  needKey = true;
  if (ext.active) { // ffmpeg cannot be asked for an IDR mid-stream: restart it (produces an immediate keyframe)
    if (Date.now() - ext.lastStart < 1500) return; // one just started, its first frame is a keyframe anyway
    clearTimeout(ext.restartTimer);
    ext.restartTimer = setTimeout(() => { if (ext.active) { ext.active = false; ext.enc.stop(); startExternal(); } }, 100);
    return;
  }
  if (win && !win.isDestroyed()) win.webContents.send('need-key', why);
}
function onVideoConfig(buf) {
  videoConfig = buf;
  if (tcp.socket && tcp.state === 'connected') { tcp.socket.write(frameMsg('H', buf)); needKey = true; }
}
function onVideoChunk(buf, key, ptsMs) {
  const s = tcp.socket;
  if (!s || tcp.state !== 'connected' || !videoConfig) return;
  if (needKey && !key) { videoStats.dropped++; return; }
  if (s.writableLength > VIDEO_BACKLOG) { // network can't keep up: drop until the next keyframe
    videoStats.dropped++;
    if (!needKey) requestKeyframe('backlog');
    return;
  }
  needKey = false;
  const pts = ptsMs >>> 0;
  const h = Buffer.alloc(5); h[0] = key ? 1 : 0; h.writeUInt32BE(pts, 1);
  s.write(frameMsg('V', Buffer.concat([h, buf])));
  ptsSent.set(pts, Date.now()); if (ptsSent.size > 240) ptsSent.delete(ptsSent.keys().next().value);
  videoStats.frames++; videoStats.bytes += buf.length;
}

function onAudioFormat(rate, channels) {
  audioFormat = { rate, channels };
  const m = audioFormatMsg();
  if (tcp.socket && tcp.state === 'connected') tcp.socket.write(m);
  for (const [ws] of wsClients) if (ws.readyState === ws.OPEN) ws.send(m, { binary: true });
}

const audioStats = { sent: 0, dropped: 0, peak: 0 }; // peak: loudest sample sent to the app since the last poll (0 = we are sending silence)
// Two producers: the panel's Web Audio capture (feeds Safari clients, and the app when ffmpeg audio is off)
// and ffmpeg dshow capture in this process (feeds the app; immune to renderer throttling).
function onAudioChunk(buf, source) {
  if (!settings.audio) return;
  const m = frameMsg('A', buf);
  const appFromRenderer = source === 'renderer' && !extAudio.active;
  // audio is small (4 KB per chunk): send it ahead of video unless the socket is badly backed up
  if ((source === 'ffmpeg' || appFromRenderer) && tcp.socket && tcp.state === 'connected') {
    if (tcp.socket.writableLength < 2 * 1024 * 1024) { tcp.socket.write(m); audioStats.sent++; } else audioStats.dropped++;
    for (let i = 0; i + 1 < buf.length; i += 16) { const v = Math.abs(buf.readInt16LE(i)); if (v > audioStats.peak) audioStats.peak = v; }
  }
  if (source !== 'renderer') return; // Safari clients keep getting the renderer's stream
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
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class M{[DllImport("user32.dll")]public static extern bool SetCursorPos(int x,int y);[DllImport("user32.dll")]public static extern void mouse_event(uint f,uint x,uint y,uint d,UIntPtr e);[DllImport("user32.dll")]public static extern void keybd_event(byte k,byte s,uint f,UIntPtr e);[DllImport("user32.dll")]public static extern bool SetProcessDpiAwarenessContext(IntPtr c);[StructLayout(LayoutKind.Sequential)]public struct PT{public int X,Y;}[DllImport("user32.dll")]public static extern bool GetCursorPos(out PT p);[DllImport("user32.dll")]public static extern IntPtr WindowFromPoint(PT p);[DllImport("user32.dll")]public static extern IntPtr GetAncestor(IntPtr h,uint f);[DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();[DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);
public static void Focus(){PT p;GetCursorPos(out p);IntPtr h=WindowFromPoint(p);if(h==IntPtr.Zero)return;IntPtr r=GetAncestor(h,2);if(r==IntPtr.Zero)r=h;if(GetForegroundWindow()==r)return;keybd_event(0x12,0,0,UIntPtr.Zero);keybd_event(0x12,0,2,UIntPtr.Zero);SetForegroundWindow(r);}}'
[M]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null   # per-monitor v2: SetCursorPos takes physical pixels
while ($true) { $l = [Console]::In.ReadLine(); if ($null -eq $l) { break }; $p = $l.Split(' ');
  switch ($p[0]) {
    'move'   { [M]::SetCursorPos([int]$p[1],[int]$p[2]) }
    'down'   { [M]::SetCursorPos([int]$p[1],[int]$p[2]); [M]::mouse_event(2,0,0,0,[UIntPtr]::Zero) }
    'up'     { [M]::SetCursorPos([int]$p[1],[int]$p[2]); [M]::mouse_event(4,0,0,0,[UIntPtr]::Zero) }
    'rclick' { [M]::SetCursorPos([int]$p[1],[int]$p[2]); [M]::mouse_event(8,0,0,0,[UIntPtr]::Zero); [M]::mouse_event(16,0,0,0,[UIntPtr]::Zero) }
    'wheel'  { [M]::mouse_event(0x0800,0,0,[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$p[1]),0),[UIntPtr]::Zero) }
    'hwheel' { [M]::mouse_event(0x1000,0,0,[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$p[1]),0),[UIntPtr]::Zero) }
    'zoom'   { [M]::Focus(); [M]::keybd_event(0x11,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 15; [M]::mouse_event(0x0800,0,0,[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$p[1]),0),[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [M]::keybd_event(0x11,0,2,[UIntPtr]::Zero) }
  } }`;
      mouseHelper = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { stdio: ['pipe', 'ignore', 'ignore'], windowsHide: true });
      mouseHelper.on('exit', () => { mouseHelper = null; });
      mouseHelper.on('error', () => { mouseHelper = null; });
    }
    if (mouseHelper) mouseHelper.stdin.write(line + '\n');
  } else if (MAC) {
    // macOS: driver/macos/mousehelper.swift (CGEvent), same command set; built with swiftc on first use.
    if (!mouseHelper) {
      const bin = macHelper('mousehelper');
      if (!bin.path) { if (!mac.mouseError) { mac.mouseError = bin.error; notifyStatus(); } return; }
      mouseHelper = spawn(bin.path, [], { stdio: ['pipe', 'pipe', 'ignore'] });
      mouseHelper.stdout.on('data', (d) => { // "ax 0|1" once at start (accessibility permission of this app), "pos x y" on request
        for (const l of d.toString().split('\n')) {
          const m = /^ax (\d)/.exec(l);
          if (m) { mac.axTrusted = m[1] === '1'; console.log('[mouse] accessibility trusted:', mac.axTrusted); notifyStatus(); }
          else if (l.trim()) console.log('[mouse]', l.trim());
        }
      });
      mouseHelper.on('exit', () => { mouseHelper = null; });
      mouseHelper.on('error', () => { mouseHelper = null; });
    }
    if (mouseHelper) mouseHelper.stdin.write(line + '\n');
  }
}

// ---------- macOS helpers (driver/macos/*.swift, compiled with swiftc from Command Line Tools on first use) ----------
// vdisplay: a virtual 1024x768 @ 60 Hz monitor "iPad Display" through the private CGVirtualDisplay API (as DeskPad does);
// it lives while the helper process runs. mousehelper: CGEvent mouse/scroll injection (needs Accessibility permission).
const mac = { vdisplay: null, vdisplayId: null, vdisplayError: null, axTrusted: null, mouseError: null };
const MAC_DIR = path.join(DRIVER_DIR, 'macos');
function macHelper(name) {
  const src = path.join(MAC_DIR, name + '.swift');
  let bin = path.join(MAC_DIR, name);
  // packaged .app: ship prebuilt (driver/macos/build.sh in CI); never rebuild inside the bundle
  if (app.isPackaged && fs.existsSync(bin)) return { path: bin };
  if (!app.isPackaged && fs.existsSync(bin) && fs.statSync(bin).mtimeMs >= fs.statSync(src).mtimeMs) return { path: bin };
  if (app.isPackaged) { // no prebuilt helper (e.g. a build from another machine): compile into the user's data dir
    const dir = path.join(app.getPath('userData'), 'helpers');
    try { fs.mkdirSync(dir, { recursive: true }); } catch (e) { /* exists */ }
    bin = path.join(dir, name);
    if (fs.existsSync(bin)) return { path: bin };
  }
  const extra = { vdisplay: ['-import-objc-header', path.join(MAC_DIR, 'CGVirtualDisplay.h'), '-framework', 'CoreGraphics'], mousehelper: ['-framework', 'ApplicationServices'], audiosetup: ['-framework', 'CoreAudio'] };
  const args = ['-O', src, '-o', bin, ...(extra[name] || [])];
  console.log('[mac] building', name, 'with swiftc');
  const r = require('child_process').spawnSync('xcrun', ['swiftc', ...args], { encoding: 'utf8', timeout: 180000 });
  if (r.status === 0 && fs.existsSync(bin)) return { path: bin };
  const why = (r.error && r.error.message) || (r.stderr || '').trim().split('\n').slice(-3).join(' ') || ('код ' + r.status);
  return { path: null, error: 'Не удалось собрать ' + name + ' (swiftc): ' + why + '. Нужны Command Line Tools: xcode-select --install' };
}
// Resolves with { id } once the display exists (or { error }); the helper is reused while it runs.
function startVdisplay() {
  if (!MAC) return Promise.resolve({ error: 'только для macOS' });
  if (mac.vdisplay && mac.vdisplayId !== null) return Promise.resolve({ id: mac.vdisplayId });
  const bin = macHelper('vdisplay');
  if (!bin.path) { mac.vdisplayError = bin.error; return Promise.resolve({ error: bin.error }); }
  return new Promise((resolve) => {
    const [w, h] = (/^(\d+)x(\d+)$/.exec(settings.size || '') || [0, 1024, 768]).slice(1).map(Number);
    const p = spawn(bin.path, [String(w || 1024), String(h || 768), '60'], { stdio: ['pipe', 'pipe', 'pipe'] });
    mac.vdisplay = p; mac.vdisplayId = null; mac.vdisplayError = null;
    let err = '', done = false;
    const finish = (r) => { if (!done) { done = true; resolve(r); } };
    p.stdout.on('data', (d) => { const m = /^display (\d+)/m.exec(d.toString()); if (m) { mac.vdisplayId = +m[1]; console.log('[vdisplay]', d.toString().trim()); finish({ id: mac.vdisplayId }); } });
    p.stderr.on('data', (d) => { err += d.toString(); });
    p.on('error', (e) => { err += e.message; });
    p.on('exit', (code) => {
      if (mac.vdisplay === p) { mac.vdisplay = null; mac.vdisplayId = null; }
      const msg = 'vdisplay завершился (код ' + code + '): ' + err.trim() + ' — CGVirtualDisplay не работает на этой macOS? Запасной путь: brew install --cask deskpad, в DeskPad задайте 1024×768';
      if (!done) mac.vdisplayError = msg; else if (code !== 0) console.error('[vdisplay]', msg);
      finish({ error: msg });
    });
    setTimeout(() => finish({ error: 'vdisplay не ответил за 8 с' }), 8000);
  });
}
function stopVdisplay() { if (mac.vdisplay) { const p = mac.vdisplay; mac.vdisplay = null; mac.vdisplayId = null; try { p.stdin.end('quit\n'); p.kill(); } catch (e) { /* gone */ } } }
const hasVirtualDisplay = () => { const primary = screen.getPrimaryDisplay().id; return screen.getAllDisplays().some((d) => d.id !== primary && Math.abs(d.bounds.width / d.bounds.height - 4 / 3) < 0.02); };

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

// Two-finger scroll: frame pixels -> wheel notches (WHEEL_DELTA = 120). Fractions are accumulated.
const scrollAcc = { x: 0, y: 0, z: 0 };
const PIXELS_PER_NOTCH = 40;
function onScroll(dx, dy) {
  scrollAcc.x += dx; scrollAcc.y += dy;
  const nx = Math.trunc(scrollAcc.x / PIXELS_PER_NOTCH), ny = Math.trunc(scrollAcc.y / PIXELS_PER_NOTCH);
  if (ny) { scrollAcc.y -= ny * PIXELS_PER_NOTCH; mouseCmd('wheel ' + (ny * 120)); }   // content follows the fingers: down = wheel up
  if (nx) { scrollAcc.x -= nx * PIXELS_PER_NOTCH; mouseCmd('hwheel ' + (-nx * 120)); }
}
function onZoom(delta) { // delta = scale change * 1000; one Ctrl+wheel notch per 8 %
  scrollAcc.z += delta;
  const n = Math.trunc(scrollAcc.z / 80);
  if (n) { scrollAcc.z -= n * 80; mouseCmd('zoom ' + (n * 120)); }
}
function onRightClick(nx, ny) {
  const d = selectedDisplay || screen.getPrimaryDisplay(); const b = d.bounds;
  const o = process.platform === 'win32' ? (d.nativeOrigin || { x: b.x * d.scaleFactor, y: b.y * d.scaleFactor }) : { x: b.x, y: b.y };
  const sf = process.platform === 'win32' ? d.scaleFactor : 1;
  mouseCmd('rclick ' + Math.round(o.x + nx * b.width * sf) + ' ' + Math.round(o.y + ny * b.height * sf));
}

// Device -> host bytes on the TCP socket: 0x01 ack, 'T' touch (6), 'S' scroll (5), 'Z' zoom (3), 'R' right click (5)
function onDeviceData(d) {
  tcp.rx = Buffer.concat([tcp.rx, d]);
  for (;;) {
    if (!tcp.rx.length) return;
    const t = tcp.rx[0];
    if (t === 0x01) { tcp.rx = tcp.rx.subarray(1); tcp.inflight = false; sendTcp(); continue; }
    if (t === 0x54 /* T */) { if (tcp.rx.length < 6) return; onTouch(tcp.rx[1], tcp.rx.readUInt16BE(2) / 65535, tcp.rx.readUInt16BE(4) / 65535); tcp.rx = tcp.rx.subarray(6); continue; }
    if (t === 0x53 /* S */) { if (tcp.rx.length < 5) return; onScroll(tcp.rx.readInt16BE(1), tcp.rx.readInt16BE(3)); tcp.rx = tcp.rx.subarray(5); continue; }
    if (t === 0x5a /* Z */) { if (tcp.rx.length < 3) return; onZoom(tcp.rx.readInt16BE(1)); tcp.rx = tcp.rx.subarray(3); continue; }
    if (t === 0x52 /* R */) { if (tcp.rx.length < 5) return; onRightClick(tcp.rx.readUInt16BE(1) / 65535, tcp.rx.readUInt16BE(3) / 65535); tcp.rx = tcp.rx.subarray(5); continue; }
    if (t === 0x4b /* K */) { tcp.rx = tcp.rx.subarray(1); requestKeyframe('device'); continue; }
    if (t === 0x50 /* P */) { if (tcp.rx.length < 5) return; onPresented(tcp.rx.readUInt32BE(1)); tcp.rx = tcp.rx.subarray(5); continue; }
    if (t === 0x58 /* X */) { // declined: the user picked another host on the iPad
      tcp.rx = tcp.rx.subarray(1);
      declinedUntil.set(tcp.mode === 'usb' ? 'usb' : tcp.host, Date.now() + 60000);
      tcp.error = 'iPad выбрал другой хост (повтор через минуту)';
      const err = tcp.error; tcpDisconnect(); tcp.error = err; tcp.state = 'declined'; notifyStatus();
      return;
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
  tcp.state = 'connected'; tcp.inflight = false; tcp.sentSeq = 0; tcp.hint = null;
  notifyStatus();
  s.write(frameMsg('N', Buffer.from(os.hostname(), 'utf8'))); // who we are, for the host picker on the iPad
  if (audioFormat) s.write(audioFormatMsg());
  if (encoderMode() === 'ffmpeg') { videoConfig = null; latencyMs = null; startExternal(); }
  else if (videoConfig) { s.write(frameMsg('H', videoConfig)); requestKeyframe('connect'); }
  startExternalAudio(); // no-op without ffmpeg / a virtual cable
  sendTcp();
  s.on('data', onDeviceData);
  const drop = () => {
    if (tcp.socket !== s) return;
    tcp.socket = null;
    stopExternal();
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
  stopExternal();
  if (tcp.socket) { tcp.socket.destroy(); tcp.socket = null; }
  tcp.state = 'off';
  notifyStatus();
}

// ---------- auto-connect: LAN beacon from the iPad app (Wi-Fi first), USB as fallback ----------
const discovered = new Map(); // ip -> { port, seen }
const declinedUntil = new Map(); // ip (or 'usb') -> timestamp until which we leave that iPad alone
function startDiscovery() {
  const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  sock.on('message', (msg, rinfo) => {
    const m = /^IPADDISPLAY (\d+)( busy)?/.exec(msg.toString());
    if (!m) return;
    const busy = !!m[2]; // another host is already showing on that iPad
    discovered.set(rinfo.address, { port: parseInt(m[1], 10), seen: Date.now(), busy });
    notifyStatus();
    // Answer with our name so the iPad can list hosts and let the user pick one.
    sock.send(Buffer.from('IPADDISPLAY-HOST ' + os.hostname()), rinfo.port, rinfo.address);
    if (busy) return;                                          // it is showing someone else
    if (declinedUntil.get(rinfo.address) > Date.now()) return; // the user chose another host on the iPad
    // The app only beacons while no host is connected, so a beacon means it is free: take it over Wi-Fi.
    if (settings.autoconnect && tcp.state !== 'connected' && !(tcp.mode === 'tcp' && tcp.host === rinfo.address && tcp.want)) {
      console.log('auto-connect Wi-Fi ->', rinfo.address);
      tcpConnect(rinfo.address, parseInt(m[1], 10));
    }
  });
  sock.on('error', (e) => console.error('discovery:', e.message));
  sock.bind(BEACON_PORT);

  // USB has priority: a cable means the user wants the lower-jitter path. If a device is on USB and we are
  // not connected through it, (re)connect over usbmuxd; otherwise USB stays the fallback when Wi-Fi is silent.
  let usbFailedAt = 0;
  setInterval(async () => {
    for (const [ip, d] of discovered) if (Date.now() - d.seen > 10000) discovered.delete(ip);
    if (!settings.autoconnect) return;
    let devs = [];
    try { devs = await usbmux.listDevices(); } catch (e) { return; /* no usbmuxd on this machine */ }
    if (!devs.length) return;
    if (declinedUntil.get('usb') > Date.now()) return; // the iPad declined us over USB a moment ago
    if (tcp.mode === 'usb' && (tcp.state === 'connected' || tcp.state === 'connecting')) return;
    if (tcp.mode === 'usb' && tcp.want && Date.now() - (tcp.since || 0) < 15000) return; // give the current USB attempt a chance
    if (Date.now() - usbFailedAt < 30000) return; // the app was not listening over USB a moment ago; retry later
    console.log('auto-connect USB' + (tcp.state === 'connected' ? ' (switching from Wi-Fi)' : ''));
    usbConnect(APP_PORT); tcp.since = Date.now();
    setTimeout(() => {
      if (tcp.mode === 'usb' && tcp.state !== 'connected') {
        usbFailedAt = Date.now(); tcpDisconnect();
        if (settings.autolaunch) applaunch.launchOverUsb().then((r) => {
          if (r === true) { usbFailedAt = 0; tcp.hint = null; }
          else if (r === 'locked') tcp.hint = 'locked';
          notifyStatus();
        });
      }
    }, 6000);
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
      else if (t[0] === '{') {
        try {
          const j = JSON.parse(t);
          if (j.t === 'touch') onTouch(j.phase, j.x, j.y);
          else if (j.t === 'scroll') onScroll(j.dx, j.dy);
          else if (j.t === 'zoom') onZoom(j.d);
          else if (j.t === 'rclick') onRightClick(j.x, j.y);
        } catch (e) { /* ignore */ }
      }
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
    tcp: { state: tcp.state, mode: tcp.mode, host: tcp.host, port: tcp.port, error: tcp.error, hint: tcp.hint || null },
    discovered: [...discovered].map(([ip, d]) => ({ ip, busy: !!d.busy })),
    mac: MAC ? { axTrusted: mac.axTrusted, mouseError: mac.mouseError, vdisplay: mac.vdisplayId, vdisplayError: mac.vdisplayError, screenAccess: systemPreferences.getMediaAccessStatus('screen') } : null,
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
    width: 720, height: 900, minWidth: 560, title: 'iPad Display',
    backgroundColor: '#11131a',
    icon: path.join(__dirname, 'assets', WIN ? 'icon.ico' : 'icon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, backgroundThrottling: false },
  });
  win.setMenuBarVisibility(false); // the default Electron menu says nothing useful here
  if (MAC && app.dock) { try { app.dock.setIcon(path.join(__dirname, 'assets', 'icon.png')); } catch (e) { /* dev only */ } }
  win.loadFile('panel.html');
  win.on('closed', () => { win = null; });
}

app.whenReady().then(async () => {
  loadSettings();
  if (process.env.IPAD_DISPLAY_AUTOSTART) settings.autostart = true;
  // macOS: bring up the virtual monitor before the panel enumerates screens (unless one exists already, e.g. DeskPad)
  if (MAC && !hasVirtualDisplay()) { const r = await startVdisplay(); if (r.error) console.error('[vdisplay]', r.error); else await new Promise((res) => setTimeout(res, 500)); }
  screen.on('display-added', () => { ext.outputs = null; });
  screen.on('display-removed', () => { ext.outputs = null; });
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
app.on('will-quit', () => { if (mouseHelper) mouseHelper.kill(); stopExternal(); stopVdisplay(); sessionStop(true, 'quit'); });
// SIGTERM/SIGINT (kill, Ctrl+C in the terminal) must still run will-quit: otherwise ffmpeg and vdisplay outlive the host
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => app.quit());

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
ipcMain.handle('session-start', async () => { await sessionStart(); return true; });
ipcMain.handle('session-stop', async () => { await sessionStop(false, 'panel'); return true; });
ipcMain.handle('set-loopback', (e, v) => { wantLoopback = !!v; return true; });
ipcMain.handle('tcp-connect', (e, host, port) => { tcpConnect(host, port); return true; });
ipcMain.handle('tcp-disconnect', () => { tcpDisconnect(); return true; });
ipcMain.handle('usb-connect', (e, port) => { usbConnect(port); return true; });
ipcMain.handle('usb-list', async () => { try { return { devices: await usbmux.listDevices() }; } catch (e) { return { error: e.message }; } });
ipcMain.handle('open-external', (e, url) => shell.openExternal(url));
ipcMain.handle('install-vdd', () => new Promise((resolve) => {
  if (MAC) return startVdisplay().then((r) => resolve(r.error ? { error: r.error, code: 1 } : { code: 0, out: 'виртуальный монитор «iPad Display» создан, id ' + r.id }));
  if (process.platform !== 'win32') return resolve({ error: 'Только для Windows и macOS.' });
  const script = path.join(DRIVER_DIR, 'windows', 'install-vdd.ps1');
  const log = path.join(app.getPath('userData'), 'vdd-install.log');
  const inner = `& '${script}' *> '${log}'`;
  const ps = spawn('powershell.exe', ['-NoProfile', '-Command', `Start-Process powershell -Verb RunAs -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',${JSON.stringify(inner)})`], { windowsHide: true });
  ps.on('exit', (code) => { let out = ''; try { out = fs.readFileSync(log, 'utf8'); } catch (e) { /* no log */ } resolve({ code, out }); });
}));
// macOS: Multi-Output Device "iPad Display + динамики" (BlackHole + built-in speakers), see driver/macos/audiosetup.swift
ipcMain.handle('setup-audio', () => {
  if (!MAC) return { error: 'Только для macOS' };
  const bin = macHelper('audiosetup');
  if (!bin.path) return { error: bin.error };
  const r = require('child_process').spawnSync(bin.path, [], { encoding: 'utf8', timeout: 20000 });
  extAudio.probed = 0; startExternalAudio(); // pick the cable up right away if the app is connected
  return { code: r.status, out: ((r.stdout || '') + (r.stderr || '')).trim() };
});
ipcMain.on('log', (e, msg) => console.log('[panel]', msg));
ipcMain.on('frame', (e, ab) => onNewFrame(Buffer.from(ab)));
ipcMain.on('audio-format', (e, rate, channels) => onAudioFormat(rate, channels));
ipcMain.on('audio', (e, ab) => onAudioChunk(Buffer.from(ab), 'renderer'));
ipcMain.on('video-config', (e, ab) => onVideoConfig(Buffer.from(ab)));
ipcMain.on('video-chunk', (e, ab, key, ptsMs) => onVideoChunk(Buffer.from(ab), !!key, ptsMs | 0));
ipcMain.handle('video-stats', () => { const dt = (Date.now() - videoStats.t) / 1000 || 1; const r = { fps: videoStats.frames / dt, kbps: videoStats.bytes * 8 / dt / 1000, dropped: videoStats.dropped, connected: tcp.state === 'connected', external: ext.active, encoder: encoderMode(), latency: latencyMs === null ? null : Math.round(latencyMs), audioSent: audioStats.sent, audioDropped: audioStats.dropped, audioPeak: audioStats.peak, audioSource: extAudio.active ? 'ffmpeg' : 'renderer' }; audioStats.sent = 0; audioStats.dropped = 0; audioStats.peak = 0; videoStats.frames = 0; videoStats.bytes = 0; videoStats.dropped = 0; videoStats.t = Date.now(); return r; });
