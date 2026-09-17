/**
 * make-tray-icons.mjs — generates the Bridge system-tray icons.
 *
 * Pure Node.js, zero dependencies (uses node:zlib + a hand-rolled PNG
 * encoder). Run once: `node scripts/make-tray-icons.mjs`.
 *
 * Design tokens (must match the Clay+Linen system in src/style.css):
 *   --clay:  #BC5E36   tile when a device is connected
 *   --muted: #A29382   tile when not paired / offline
 *   --sage:  #6F7F5C   status dot when connected
 *   cream:   #FDF8EF   sprout mark + dot ring
 *
 * The mark is a simplified sprout (stem capsule + two rotated leaf
 * ellipses) drawn with signed-distance functions and 4x supersampling,
 * so edges stay smooth when Windows downscales to 16px tray size.
 * Connected vs disconnected differ by tile color AND the sage dot —
 * the same clay/sage status logic used in the main window.
 */

import { deflateSync } from 'node:zlib'
import { writeFileSync, mkdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const OUT_DIR = path.join(__dirname, '..', 'public', 'tray')

const SIZE = 64
const SS = 4 // supersample factor
const N = SIZE * SS

const CLAY = [188, 94, 54]
const MUTED = [162, 147, 130]
const SAGE = [111, 127, 92]
const CREAM = [253, 248, 239]

// ── SDF helpers (in unit space, tile = 64x64) ────────────────────────────────

function sdRoundBox(px, py, cx, cy, hx, hy, r) {
  const qx = Math.abs(px - cx) - (hx - r)
  const qy = Math.abs(py - cy) - (hy - r)
  const ax = Math.max(qx, 0)
  const ay = Math.max(qy, 0)
  return Math.hypot(ax, ay) + Math.min(Math.max(qx, qy), 0) - r
}

function sdCapsule(px, py, ax, ay, bx, by, r) {
  const pax = px - ax
  const pay = py - ay
  const bax = bx - ax
  const bay = by - ay
  const h = Math.min(1, Math.max(0, (pax * bax + pay * bay) / (bax * bax + bay * bay)))
  return Math.hypot(pax - bax * h, pay - bay * h) - r
}

/** Approximate rotated-ellipse SDF (approx is fine — AA hides the error). */
function sdEllipse(px, py, cx, cy, rx, ry, rotDeg) {
  const t = (rotDeg * Math.PI) / 180
  const dx = px - cx
  const dy = py - cy
  const lx = (dx * Math.cos(t) + dy * Math.sin(t)) / rx
  const ly = (-dx * Math.sin(t) + dy * Math.cos(t)) / ry
  const d = Math.hypot(lx, ly) - 1
  return d * Math.min(rx, ry)
}

function smoothstep(a, b, x) {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)))
  return t * t * (3 - 2 * t)
}

// ── Renderer ─────────────────────────────────────────────────────────────────

function renderPixel(x, y, connected) {
  // Returns [r, g, b, a] for one supersample.
  const tile = sdRoundBox(x, y, 32, 32, 30, 30, 14)
  if (tile > 0.6) return [0, 0, 0, 0]

  const stem = sdCapsule(x, y, 32, 48, 32, 30, 3.4)
  const leafL = sdEllipse(x, y, 21.5, 30, 11, 5.2, -30)
  const leafR = sdEllipse(x, y, 42.5, 30, 11, 5.2, 30)
  const mark = Math.min(stem, leafL, leafR)

  const dotRing = Math.hypot(x - 49, y - 49) - 11
  const dotFill = Math.hypot(x - 49, y - 49) - 8

  const tileCol = connected ? CLAY : MUTED
  let col = tileCol
  let alpha = 1 - smoothstep(-0.6, 0.6, tile)

  const markA = 1 - smoothstep(-0.6, 0.6, mark)
  col = [
    col[0] + (CREAM[0] - col[0]) * markA,
    col[1] + (CREAM[1] - col[1]) * markA,
    col[2] + (CREAM[2] - col[2]) * markA,
  ]

  if (connected) {
    const ringA = (1 - smoothstep(-0.6, 0.6, dotRing)) * smoothstep(-0.6, 0.6, dotFill)
    col = [
      col[0] + (CREAM[0] - col[0]) * ringA,
      col[1] + (CREAM[1] - col[1]) * ringA,
      col[2] + (CREAM[2] - col[2]) * ringA,
    ]
    const dotA = 1 - smoothstep(-0.6, 0.6, dotFill)
    col = [
      col[0] + (SAGE[0] - col[0]) * dotA,
      col[1] + (SAGE[1] - col[1]) * dotA,
      col[2] + (SAGE[2] - col[2]) * dotA,
    ]
  }

  return [Math.round(col[0]), Math.round(col[1]), Math.round(col[2]), Math.round(alpha * 255)]
}

function render(connected) {
  const px = Buffer.alloc(SIZE * SIZE * 4)
  for (let oy = 0; oy < SIZE; oy++) {
    for (let ox = 0; ox < SIZE; ox++) {
      let r = 0
      let g = 0
      let b = 0
      let a = 0
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const x = (ox + (sx + 0.5) / SS) * (SIZE / SIZE)
          const y = (oy + (sy + 0.5) / SS) * (SIZE / SIZE)
          const s = renderPixel(x, y, connected)
          // Premultiplied accumulation for correct downsampling.
          const sa = s[3] / 255
          r += (s[0] * sa) / (SS * SS)
          g += (s[1] * sa) / (SS * SS)
          b += (s[2] * sa) / (SS * SS)
          a += sa / (SS * SS)
        }
      }
      const i = (oy * SIZE + ox) * 4
      if (a > 0.003) {
        px[i] = Math.round(r / a)
        px[i + 1] = Math.round(g / a)
        px[i + 2] = Math.round(b / a)
        px[i + 3] = Math.round(a * 255)
      }
    }
  }
  return px
}

// ── Minimal PNG encoder ──────────────────────────────────────────────────────

const CRC_TABLE = (() => {
  const t = new Int32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    t[n] = c
  }
  return t
})()

function crc32(buf) {
  let c = -1
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8)
  return (c ^ -1) >>> 0
}

function chunk(type, data) {
  const len = Buffer.alloc(4)
  len.writeUInt32BE(data.length)
  const typeBuf = Buffer.from(type, 'ascii')
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])))
  return Buffer.concat([len, typeBuf, data, crc])
}

function encodePng(rgba, size) {
  const raw = Buffer.alloc((size * 4 + 1) * size)
  for (let y = 0; y < size; y++) {
    raw[y * (size * 4 + 1)] = 0 // filter: none
    rgba.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4)
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(size, 0)
  ihdr.writeUInt32BE(size, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 6 // color type: RGBA
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))])
}

// ── Main ─────────────────────────────────────────────────────────────────────

mkdirSync(OUT_DIR, { recursive: true })
for (const connected of [true, false]) {
  const name = connected ? 'tray-connected.png' : 'tray-disconnected.png'
  writeFileSync(path.join(OUT_DIR, name), encodePng(render(connected), SIZE))
  console.log(`wrote public/tray/${name}`)
}
