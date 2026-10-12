/**
 * Generates the launcher icons.
 *
 * A script rather than two committed binaries, for the same reason the Android side uses vector
 * drawables: the artwork stays reviewable as code, and there is no second copy to keep in sync.
 * HarmonyOS does not take SVG for `app.json5`'s `icon`, so a real PNG has to exist — this
 * produces one with `zlib` and about eighty lines of drawing helpers instead of checking a
 * binary into the repository.
 *
 * Usage: `node harmonyos/tools/make-icons.mjs`
 */

import { deflateSync } from 'node:zlib';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const harmonyRoot = join(here, '..');

const SIZE = 216;
const BACKGROUND = [0x1d, 0x4e, 0x89];
const INK = [0xff, 0xff, 0xff];

// --------------------------------------------------------------------------- //
// PNG encoding
// --------------------------------------------------------------------------- //

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) !== 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
})();

function crc32(buffer) {
  let c = 0xffffffff;
  for (let i = 0; i < buffer.length; i++) {
    c = CRC_TABLE[(c ^ buffer[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const typeBytes = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBytes, data])), 0);
  return Buffer.concat([length, typeBytes, data, crc]);
}

function encodePng(width, height, rgba) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;   // bit depth
  header[9] = 6;   // colour type: RGBA
  header[10] = 0;  // deflate
  header[11] = 0;  // adaptive filtering
  header[12] = 0;  // no interlace

  // One filter byte (0 = none) per scanline, then the row.
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// --------------------------------------------------------------------------- //
// Drawing
// --------------------------------------------------------------------------- //

function createCanvas(size, background) {
  const rgba = Buffer.alloc(size * size * 4);
  for (let i = 0; i < size * size; i++) {
    rgba[i * 4] = background[0];
    rgba[i * 4 + 1] = background[1];
    rgba[i * 4 + 2] = background[2];
    rgba[i * 4 + 3] = 255;
  }
  return rgba;
}

function put(rgba, size, x, y, colour) {
  if (x < 0 || y < 0 || x >= size || y >= size) {
    return;
  }
  const at = (y * size + x) * 4;
  rgba[at] = colour[0];
  rgba[at + 1] = colour[1];
  rgba[at + 2] = colour[2];
  rgba[at + 3] = 255;
}

function fillRect(rgba, size, x0, y0, x1, y1, colour) {
  for (let y = y0; y <= y1; y++) {
    for (let x = x0; x <= x1; x++) {
      put(rgba, size, x, y, colour);
    }
  }
}

/**
 * A rectangle outline with rounded corners.
 *
 * The corners are the only reason this is not four `fillRect` calls: a square corner reads as a
 * table rather than a photo frame at 216 px.
 */
function strokeRoundedRect(rgba, size, x0, y0, x1, y1, radius, thickness, colour) {
  for (let y = y0; y <= y1; y++) {
    for (let x = x0; x <= x1; x++) {
      const onHorizontal = (y < y0 + thickness || y > y1 - thickness) && x >= x0 + radius && x <= x1 - radius;
      const onVertical = (x < x0 + thickness || x > x1 - thickness) && y >= y0 + radius && y <= y1 - radius;
      if (onHorizontal || onVertical) {
        put(rgba, size, x, y, colour);
        continue;
      }
      // Corner arcs: keep the pixel when its distance from the arc centre lands in the band.
      if (x < x0 + radius || x > x1 - radius) {
        if (y < y0 + radius || y > y1 - radius) {
          const cx = x < x0 + radius ? x0 + radius : x1 - radius;
          const cy = y < y0 + radius ? y0 + radius : y1 - radius;
          const dx = x - cx;
          const dy = y - cy;
          const distance = Math.sqrt(dx * dx + dy * dy);
          if (distance <= radius && distance >= radius - thickness) {
            put(rgba, size, x, y, colour);
          }
        }
      }
    }
  }
}

function fillCircle(rgba, size, cx, cy, radius, colour) {
  for (let y = cy - radius; y <= cy + radius; y++) {
    for (let x = cx - radius; x <= cx + radius; x++) {
      const dx = x - cx;
      const dy = y - cy;
      if (dx * dx + dy * dy <= radius * radius) {
        put(rgba, size, x, y, colour);
      }
    }
  }
}

function drawLine(rgba, size, x0, y0, x1, y1, thickness, colour) {
  const steps = Math.max(Math.abs(x1 - x0), Math.abs(y1 - y0)) * 2 + 1;
  for (let step = 0; step <= steps; step++) {
    const t = step / steps;
    const x = Math.round(x0 + (x1 - x0) * t);
    const y = Math.round(y0 + (y1 - y0) * t);
    fillCircle(rgba, size, x, y, Math.floor(thickness / 2), colour);
  }
}

/**
 * The artwork: a photo frame with a ridge line inside it, and two caption strokes underneath.
 *
 * The caption strokes are the point of the app — every photo carries its own line of text — and
 * they are what makes the icon recognisable at launcher size.
 */
function drawIcon() {
  const rgba = createCanvas(SIZE, BACKGROUND);

  strokeRoundedRect(rgba, SIZE, 68, 50, 148, 118, 10, 8, INK);
  fillCircle(rgba, SIZE, 89, 73, 8, INK);
  drawLine(rgba, SIZE, 74, 112, 96, 86, 7, INK);
  drawLine(rgba, SIZE, 96, 86, 114, 106, 7, INK);
  drawLine(rgba, SIZE, 114, 106, 126, 94, 7, INK);
  drawLine(rgba, SIZE, 126, 94, 142, 112, 7, INK);

  fillRect(rgba, SIZE, 68, 140, 148, 149, INK);
  fillRect(rgba, SIZE, 68, 160, 112, 169, INK);

  return rgba;
}

// --------------------------------------------------------------------------- //

const rgba = drawIcon();
const png = encodePng(SIZE, SIZE, rgba);

const targets = [
  join(harmonyRoot, 'AppScope', 'resources', 'base', 'media', 'app_icon.png'),
  join(harmonyRoot, 'entry', 'src', 'main', 'resources', 'base', 'media', 'startIcon.png'),
];

for (const target of targets) {
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, png);
  console.log(`wrote ${target} (${png.length} bytes)`);
}
