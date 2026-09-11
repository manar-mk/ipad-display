// External hardware H.264 encoder in a separate ffmpeg process (runs from the main process, so it is
// immune to renderer throttling):
//   Windows: `ddagrab` (DXGI desktop duplication, on the GPU) -> `h264_mf` (Media Foundation: NVIDIA/Intel/AMD).
//   macOS:   `avfoundation` screen capture -> `h264_videotoolbox` (Apple hardware encoder).
// Output is a raw Annex B stream on stdout that we cut into access units (on AUD NALs, or on the first
// slice of a picture when the encoder emits no AUDs, as VideoToolbox does) and convert to AVCC for the iPad.
//
// Why not WebCodecs on Windows: Electron's WebCodecs there only offers software OpenH264; ffmpeg 9's NVENC
// needs driver >= 610, but Media Foundation reaches the same hardware through the vendor MFT.

const { spawn, execFile } = require('child_process');
const fs = require('fs');
const path = require('path');

const MAC = process.platform === 'darwin';

function findFfmpeg() {
  if (process.env.IPAD_DISPLAY_FFMPEG && fs.existsSync(process.env.IPAD_DISPLAY_FFMPEG)) return process.env.IPAD_DISPLAY_FFMPEG;
  if (MAC) { // Homebrew (Apple silicon / Intel), MacPorts; Electron's PATH lacks /opt/homebrew/bin when launched from Finder
    for (const p of ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg', '/opt/local/bin/ffmpeg']) if (fs.existsSync(p)) return p;
  }
  const roots = [path.join(process.env.LOCALAPPDATA || '', 'Microsoft', 'WinGet', 'Packages')];
  for (const r of roots) {
    try {
      for (const pkg of fs.readdirSync(r)) {
        if (!/ffmpeg/i.test(pkg)) continue;
        const stack = [path.join(r, pkg)];
        while (stack.length) {
          const d = stack.pop();
          for (const e of fs.readdirSync(d, { withFileTypes: true })) {
            const p = path.join(d, e.name);
            if (e.isDirectory()) stack.push(p);
            else if (e.name.toLowerCase() === 'ffmpeg.exe') return p;
          }
        }
      }
    } catch (e) { /* no winget dir */ }
  }
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    for (const n of ['ffmpeg.exe', 'ffmpeg']) { const p = path.join(dir, n); if (dir && fs.existsSync(p)) return p; }
  }
  return null;
}

// macOS: avfoundation device list -> [{ idx, name }] for the "Capture screen N" video devices and the audio device names.
function listAvfoundation(ffmpeg) {
  return new Promise((resolve) => {
    execFile(ffmpeg, ['-hide_banner', '-f', 'avfoundation', '-list_devices', 'true', '-i', ''], { timeout: 8000, killSignal: 'SIGKILL' },(err, stdout, stderr) => {
      const screens = [], audio = [];
      let section = '';
      for (const line of (stderr || '').split(/\r?\n/)) {
        if (/AVFoundation video devices/.test(line)) { section = 'video'; continue; }
        if (/AVFoundation audio devices/.test(line)) { section = 'audio'; continue; }
        const m = /\]\s+\[(\d+)\]\s+(.+?)\s*$/.exec(line);
        if (!m) continue;
        if (section === 'video' && /^Capture screen/i.test(m[2])) screens.push({ idx: +m[1], name: m[2] });
        if (section === 'audio') audio.push(m[2]);
      }
      resolve({ screens, audio });
    });
  });
}

// Which capture output has which size (pixels): ddagrab output_idx / avfoundation device index -> { width, height }
function probeOutputs(ffmpeg) {
  if (MAC) {
    return listAvfoundation(ffmpeg).then(({ screens }) => new Promise((resolve) => {
      const out = [];
      let i = 0;
      const next = () => {
        if (i >= screens.length) return resolve(out);
        const s = screens[i++];
        execFile(ffmpeg, ['-hide_banner', '-f', 'avfoundation', '-framerate', '30', '-i', `${s.idx}:none`, '-frames:v', '1', '-f', 'null', '-'],
          { timeout: 8000, killSignal: 'SIGKILL' },(err, stdout, stderr) => {
            const m = /Video: rawvideo.*?(\d{3,5})x(\d{3,5})/.exec(stderr || '');
            if (m) out.push({ idx: s.idx, width: +m[1], height: +m[2] });
            next();
          });
      };
      next();
    }));
  }
  return new Promise((resolve) => {
    const out = [];
    let idx = 0;
    const next = () => {
      if (idx > 5) return resolve(out);
      const i = idx++;
      execFile(ffmpeg, ['-hide_banner', '-init_hw_device', 'd3d11va', '-filter_complex', `ddagrab=output_idx=${i}:framerate=10`, '-frames:v', '1', '-f', 'null', '-'],
        { timeout: 8000, killSignal: 'SIGKILL', windowsHide: true },(err, stdout, stderr) => {
          const m = /Video: wrapped_avframe.*?(\d{3,5})x(\d{3,5})/.exec(stderr || '');
          if (m) { out.push({ idx: i, width: +m[1], height: +m[2] }); next(); }
          else resolve(out); // first missing index ends the enumeration
        });
    };
    next();
  });
}

// Annex B -> access units. Emits { key, avcc: Buffer } per frame and { avcC: Buffer } when SPS/PPS are (re)seen.
class AnnexBParser {
  constructor(onConfig, onFrame) { this.onConfig = onConfig; this.onFrame = onFrame; this.buf = Buffer.alloc(0); this.sps = null; this.pps = null; this.au = []; this.auKey = false; this.hasSlice = false; this.sentCfg = null; }
  push(chunk) {
    this.buf = Buffer.concat([this.buf, chunk]);
    // find NAL boundaries (00 00 01), keep the tail that may hold a partial NAL
    let start = this.findStart(0);
    while (start >= 0) {
      const nalStart = start + 3;
      const next = this.findStart(nalStart);
      if (next < 0) break;
      let nalEnd = next; if (nalEnd > 0 && this.buf[nalEnd - 1] === 0) nalEnd--; // 4-byte start code
      this.onNal(this.buf.subarray(nalStart, nalEnd));
      start = next;
    }
    if (start > 0) this.buf = this.buf.subarray(start);
  }
  findStart(from) { const b = this.buf; for (let i = from; i + 2 < b.length; i++) if (b[i] === 0 && b[i + 1] === 0 && b[i + 2] === 1) return i; return -1; }
  onNal(nal) {
    if (!nal.length) return;
    const type = nal[0] & 0x1f;
    if (type === 9) { this.flush(); return; }            // AUD: previous access unit is complete
    // No AUDs (VideoToolbox): a new picture starts with SPS/PPS/SEI or with a slice whose first_mb_in_slice is 0
    // (ue(v) "0" is a single 1 bit, i.e. the top bit of the byte after the NAL header).
    if (this.hasSlice && (type === 7 || type === 8 || type === 6 || ((type === 1 || type === 5) && nal.length > 1 && (nal[1] & 0x80)))) this.flush();
    if (type === 7) { this.sps = Buffer.from(nal); this.maybeConfig(); return; }
    if (type === 8) { this.pps = Buffer.from(nal); this.maybeConfig(); return; }
    if (type === 5) this.auKey = true;
    if (type === 1 || type === 5) this.hasSlice = true;
    if (type === 1 || type === 5 || type === 6) { const l = Buffer.alloc(4); l.writeUInt32BE(nal.length, 0); this.au.push(l, Buffer.from(nal)); }
  }
  maybeConfig() {
    if (!this.sps || !this.pps) return;
    const s = this.sps, p = this.pps;
    const avcC = Buffer.concat([Buffer.from([1, s[1], s[2], s[3], 0xff, 0xe1, s.length >> 8, s.length & 0xff]), s, Buffer.from([1, p.length >> 8, p.length & 0xff]), p]);
    if (this.sentCfg && this.sentCfg.equals(avcC)) return;
    this.sentCfg = avcC;
    this.onConfig(avcC);
  }
  flush() {
    if (!this.au.length) return;
    this.onFrame(Buffer.concat(this.au), this.auKey);
    this.au = []; this.auKey = false; this.hasSlice = false;
  }
}

class FfmpegEncoder {
  constructor(ffmpeg) { this.ffmpeg = ffmpeg; this.proc = null; this.onConfig = null; this.onFrame = null; this.onExit = null; }
  // maxSize: [w, h] the picture is scaled down to fit (macOS only; a Retina screen would otherwise go out at 2x).
  start({ outputIdx, fps = 60, bitrateKbps = 8000, gop = 120, maxSize = null }) {
    this.stop();
    const args = MAC
      ? ['-hide_banner', '-loglevel', 'warning', '-f', 'avfoundation', '-framerate', String(fps), '-pixel_format', 'nv12', '-capture_cursor', '1', '-i', `${outputIdx}:none`,
        ...(maxSize ? ['-vf', `scale='min(${maxSize[0]},iw)':'min(${maxSize[1]},ih)':force_original_aspect_ratio=decrease:force_divisible_by=2`] : []),
        '-c:v', 'h264_videotoolbox', '-realtime', '1', '-profile:v', 'baseline', '-b:v', `${bitrateKbps}k`, '-g', String(gop), '-bf', '0',
        '-f', 'h264', 'pipe:1']
      : ['-hide_banner', '-loglevel', 'warning', '-init_hw_device', 'd3d11va',
        '-filter_complex', `ddagrab=output_idx=${outputIdx}:framerate=${fps},hwdownload,format=bgra,format=nv12`,
        '-c:v', 'h264_mf', '-hw_encoding', '1', '-rate_control', 'ld_vbr', '-b:v', `${bitrateKbps}k`, '-g', String(gop), '-scenario', 'display_remoting',
        '-f', 'h264', 'pipe:1'];
    const parser = new AnnexBParser((c) => this.onConfig && this.onConfig(c), (f, k) => this.onFrame && this.onFrame(f, k));
    const p = spawn(this.ffmpeg, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    this.proc = p;
    p.stdout.on('data', (d) => parser.push(d));
    p.stderr.on('data', (d) => { const s = d.toString().trim(); if (s) console.error('[ffmpeg]', s.slice(0, 300)); });
    p.on('exit', (code) => { if (this.proc === p) { this.proc = null; this.onExit && this.onExit(code); } });
    p.on('error', (e) => { console.error('[ffmpeg] spawn:', e.message); if (this.proc === p) { this.proc = null; this.onExit && this.onExit(-1); } });
    return p;
  }
  get running() { return !!this.proc; }
  // SIGKILL: an ffmpeg stuck in AVFoundation/DXGI setup ignores SIGTERM, and a survivor keeps the display capture busy
  stop() { if (this.proc) { const p = this.proc; this.proc = null; try { p.kill('SIGKILL'); } catch (e) { /* gone */ } } }
}

// Audio capture devices: DirectShow on Windows, e.g. "CABLE Output (VB-Audio Virtual Cable)"; avfoundation on macOS, e.g. "BlackHole 2ch".
function listAudioDevices(ffmpeg) {
  if (MAC) return listAvfoundation(ffmpeg).then((r) => r.audio);
  return new Promise((resolve) => {
    execFile(ffmpeg, ['-hide_banner', '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'], { timeout: 8000, killSignal: 'SIGKILL', windowsHide: true },(err, stdout, stderr) => {
      const names = [];
      for (const line of (stderr || '').split(/\r?\n/)) { const m = /"([^"]+)" \(audio\)/.exec(line); if (m) names.push(m[1]); }
      resolve(names);
    });
  });
}

// Captures an audio device (dshow / avfoundation) with ffmpeg into fixed-size PCM chunks (s16le, mono, `rate` Hz).
// Runs in the main process, so it keeps going when the panel window is hidden or throttled.
class AudioCapture {
  constructor(ffmpeg) { this.ffmpeg = ffmpeg; this.proc = null; this.onChunk = null; this.onExit = null; }
  start({ device, rate = 22050, chunkSamples = 2048 }) {
    this.stop();
    const input = MAC ? ['-f', 'avfoundation', '-i', `:${device}`] : ['-f', 'dshow', '-audio_buffer_size', '20', '-i', `audio=${device}`];
    const args = ['-hide_banner', '-loglevel', 'warning', ...input, '-ac', '1', '-ar', String(rate), '-f', 's16le', 'pipe:1'];
    const p = spawn(this.ffmpeg, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    this.proc = p;
    const chunkBytes = chunkSamples * 2;
    let acc = Buffer.alloc(0);
    p.stdout.on('data', (d) => {
      acc = acc.length ? Buffer.concat([acc, d]) : d;
      while (acc.length >= chunkBytes) { const c = acc.subarray(0, chunkBytes); acc = acc.subarray(chunkBytes); if (this.onChunk) this.onChunk(Buffer.from(c)); }
    });
    p.stderr.on('data', (d) => { const s = d.toString().trim(); if (s) console.error('[ffmpeg-audio]', s.slice(0, 300)); });
    p.on('exit', (code) => { if (this.proc === p) { this.proc = null; this.onExit && this.onExit(code); } });
    p.on('error', (e) => { console.error('[ffmpeg-audio] spawn:', e.message); if (this.proc === p) { this.proc = null; this.onExit && this.onExit(-1); } });
  }
  get running() { return !!this.proc; }
  // SIGKILL: an ffmpeg stuck in AVFoundation/DXGI setup ignores SIGTERM, and a survivor keeps the display capture busy
  stop() { if (this.proc) { const p = this.proc; this.proc = null; try { p.kill('SIGKILL'); } catch (e) { /* gone */ } } }
}

module.exports = { findFfmpeg, probeOutputs, listAvfoundation, FfmpegEncoder, AnnexBParser, listAudioDevices, AudioCapture };
