// External hardware H.264 encoder for Windows: ffmpeg `ddagrab` (DXGI desktop duplication, on the GPU)
// -> `h264_mf` (Media Foundation, hardware encoder such as NVIDIA/Intel/AMD). Output is a raw Annex B
// stream on stdout that we cut into access units (on AUD NALs) and convert to AVCC for the iPad.
//
// Why not WebCodecs: Electron's WebCodecs on Windows only offers software OpenH264 here; ffmpeg 9's NVENC
// needs driver >= 610, but Media Foundation reaches the same hardware through the vendor MFT.

const { spawn, execFile } = require('child_process');
const fs = require('fs');
const path = require('path');

function findFfmpeg() {
  if (process.env.IPAD_DISPLAY_FFMPEG && fs.existsSync(process.env.IPAD_DISPLAY_FFMPEG)) return process.env.IPAD_DISPLAY_FFMPEG;
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

// Which DXGI output has which size: ddagrab output_idx -> { width, height }
function probeOutputs(ffmpeg) {
  return new Promise((resolve) => {
    const out = [];
    let idx = 0;
    const next = () => {
      if (idx > 5) return resolve(out);
      const i = idx++;
      execFile(ffmpeg, ['-hide_banner', '-init_hw_device', 'd3d11va', '-filter_complex', `ddagrab=output_idx=${i}:framerate=10`, '-frames:v', '1', '-f', 'null', '-'],
        { timeout: 8000, windowsHide: true }, (err, stdout, stderr) => {
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
  constructor(onConfig, onFrame) { this.onConfig = onConfig; this.onFrame = onFrame; this.buf = Buffer.alloc(0); this.sps = null; this.pps = null; this.au = []; this.auKey = false; this.sentCfg = null; }
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
    if (type === 7) { this.sps = Buffer.from(nal); this.maybeConfig(); return; }
    if (type === 8) { this.pps = Buffer.from(nal); this.maybeConfig(); return; }
    if (type === 5) this.auKey = true;
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
    this.au = []; this.auKey = false;
  }
}

class FfmpegEncoder {
  constructor(ffmpeg) { this.ffmpeg = ffmpeg; this.proc = null; this.onConfig = null; this.onFrame = null; this.onExit = null; }
  start({ outputIdx, fps = 60, bitrateKbps = 8000, gop = 120 }) {
    this.stop();
    const args = ['-hide_banner', '-loglevel', 'warning', '-init_hw_device', 'd3d11va',
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
  stop() { if (this.proc) { const p = this.proc; this.proc = null; try { p.kill(); } catch (e) { /* gone */ } } }
}

module.exports = { findFfmpeg, probeOutputs, FfmpegEncoder, AnnexBParser };
