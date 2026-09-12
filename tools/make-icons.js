// Draws the app icon and writes every size the project needs — no image libraries, no design tools:
//   assets/icon.png            512x512, rounded corners + alpha (macOS / docs / the panel)
//   assets/icon.ico            16..256, PNG-compressed entries (Windows window, taskbar, shortcut)
//   ios/IPadDisplay/Icon-*.png square and opaque, as iOS wants them (SpringBoard rounds them itself)
//
//   node tools/make-icons.js
//
// The picture: a blue rounded square, a white iPad lying on its side with a dark screen, a thin home
// button, and a "stream" arc pair in the corner. Everything is drawn with signed-distance functions and
// 4x4 supersampling, so the shapes stay clean down to 16 px.

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

// ---------- tiny PNG writer ----------
const CRC = (() => { const t = new Int32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c; } return t; })();
function crc32(buf) { let c = -1; for (let i = 0; i < buf.length; i++) c = CRC[(c ^ buf[i]) & 0xff] ^ (c >>> 8); return (c ^ -1) >>> 0; }
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}
// rgba: Uint8Array w*h*4; alpha=false writes an opaque RGB image (iOS icons must not carry alpha)
function png(rgba, w, h, alpha = true) {
  const bpp = alpha ? 4 : 3;
  const raw = Buffer.alloc((w * bpp + 1) * h);
  let o = 0;
  for (let y = 0; y < h; y++) {
    raw[o++] = 0; // filter: none
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      raw[o++] = rgba[i]; raw[o++] = rgba[i + 1]; raw[o++] = rgba[i + 2];
      if (alpha) raw[o++] = rgba[i + 3];
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = alpha ? 6 : 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}
// Windows .ico with PNG payloads (Vista+)
function ico(images) { // [{ size, png }]
  const head = Buffer.alloc(6); head.writeUInt16LE(0, 0); head.writeUInt16LE(1, 2); head.writeUInt16LE(images.length, 4);
  let offset = 6 + images.length * 16;
  const dirs = [], datas = [];
  for (const im of images) {
    const d = Buffer.alloc(16);
    d[0] = im.size >= 256 ? 0 : im.size; d[1] = im.size >= 256 ? 0 : im.size;
    d[2] = 0; d[3] = 0; d.writeUInt16LE(1, 4); d.writeUInt16LE(32, 6);
    d.writeUInt32LE(im.png.length, 8); d.writeUInt32LE(offset, 12);
    offset += im.png.length;
    dirs.push(d); datas.push(im.png);
  }
  return Buffer.concat([head, ...dirs, ...datas]);
}

// ---------- drawing ----------
const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const mix = (a, b, t) => a + (b - a) * t;
// distance to a rounded rectangle centred at (cx, cy)
function sdRoundRect(px, py, cx, cy, halfW, halfH, r) {
  const qx = Math.abs(px - cx) - (halfW - r), qy = Math.abs(py - cy) - (halfH - r);
  const ax = Math.max(qx, 0), ay = Math.max(qy, 0);
  return Math.sqrt(ax * ax + ay * ay) + Math.min(Math.max(qx, qy), 0) - r;
}
function sdCircle(px, py, cx, cy, r) { const dx = px - cx, dy = py - cy; return Math.sqrt(dx * dx + dy * dy) - r; }
// distance to a ring arc (annulus), used for the "signal" marks
function sdRing(px, py, cx, cy, r, thick) { return Math.abs(sdCircle(px, py, cx, cy, r)) - thick / 2; }

// Returns [r, g, b, a] (0..255) for a point in the unit square (0..1).
function shade(u, v, square) {
  let R = 0, G = 0, B = 0, A = 0;
  const put = (r, g, b, a) => { // paint over what is already there
    const na = a + A * (1 - a);
    if (na <= 0) { R = G = B = A = 0; return; }
    R = (r * a + R * A * (1 - a)) / na; G = (g * a + G * A * (1 - a)) / na; B = (b * a + B * A * (1 - a)) / na; A = na;
  };
  // background: rounded square (or a full square for iOS) with a vertical gradient
  const bgD = square ? -1 : sdRoundRect(u, v, 0.5, 0.5, 0.5, 0.5, 0.225);
  if (bgD < 0) {
    const t = clamp01(v * 0.95 + u * 0.05);
    put(mix(96, 29, t), mix(165, 78, t), mix(250, 216, t), 1); // #60a5fa -> #1d4ed8
  }
  // iPad: white body, dark screen, home button on the right
  const bodyH = 0.225, bodyW = bodyH * 4 / 3 * 1.06;
  const cx = 0.535, cy = 0.585;
  if (sdRoundRect(u, v, cx, cy, bodyW, bodyH, 0.030) < 0) put(255, 255, 255, 1);
  const scr = sdRoundRect(u, v, cx - 0.014, cy, bodyW - 0.042, bodyH - 0.034, 0.010);
  if (scr < 0) put(15, 32, 62, 1); // #0f203e
  // a soft highlight across the screen
  if (scr < 0 && v < cy - (u - (cx - bodyW)) * 0.38 + 0.02) put(255, 255, 255, 0.10);
  if (sdCircle(u, v, cx + bodyW - 0.021, cy, 0.012) < 0) put(190, 200, 215, 1);
  // two stream arcs in the top-left corner
  for (const [r, th] of [[0.10, 0.032], [0.175, 0.032]]) {
    const d = sdRing(u, v, 0.235, 0.275, r, th);
    if (d < 0 && (u - 0.235) > -0.02 && (v - 0.275) < 0.02) put(255, 255, 255, 0.95);
  }
  if (sdCircle(u, v, 0.235, 0.275, 0.030) < 0) put(255, 255, 255, 0.95);
  return [Math.round(R), Math.round(G), Math.round(B), Math.round(A * 255)];
}

function render(size, square) {
  const out = new Uint8Array(size * size * 4);
  const S = 4; // supersampling
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let sy = 0; sy < S; sy++) {
        for (let sx = 0; sx < S; sx++) {
          const [pr, pg, pb, pa] = shade((x + (sx + 0.5) / S) / size, (y + (sy + 0.5) / S) / size, square);
          const al = pa / 255;
          r += pr * al; g += pg * al; b += pb * al; a += al;
        }
      }
      const n = S * S, i = (y * size + x) * 4;
      out[i] = a > 0 ? Math.round(r / a) : 0;
      out[i + 1] = a > 0 ? Math.round(g / a) : 0;
      out[i + 2] = a > 0 ? Math.round(b / a) : 0;
      out[i + 3] = Math.round((a / n) * 255);
    }
  }
  return out;
}

// ---------- write everything ----------
const root = path.join(__dirname, '..');
const assets = path.join(root, 'assets');
fs.mkdirSync(assets, { recursive: true });

const big = render(512, false);
fs.writeFileSync(path.join(assets, 'icon.png'), png(big, 512, 512, true));

const icoSizes = [16, 24, 32, 48, 64, 128, 256];
fs.writeFileSync(path.join(assets, 'icon.ico'), ico(icoSizes.map((s) => ({ size: s, png: png(render(s, false), s, s, true) }))));

// iOS: opaque squares; iPad mini 1 uses 76 (home screen), 40 (spotlight), 29 (settings), the @2x ones are for Retina iPads
const iosDir = path.join(root, 'ios', 'IPadDisplay');
const iosSizes = [29, 40, 50, 57, 58, 72, 76, 80, 100, 114, 120, 144, 152, 167];
for (const s of iosSizes) fs.writeFileSync(path.join(iosDir, 'Icon-' + s + '.png'), png(render(s, true), s, s, false));

console.log('assets/icon.png, assets/icon.ico, ios/IPadDisplay/Icon-{' + iosSizes.join(',') + '}.png written');
