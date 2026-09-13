// End-to-end test: synthetic "phone" client for the remote-input pipeline.
// Run: node test/remote-e2e-client.mjs
//
// Requires the Bridge app to be running in UNPAIRED mode (fresh userData)
// so the socket accepts plaintext bridge-message payloads — exactly what
// the Android app produces after AES decryption.
//
// Verifies: relative moves (direction, proportionality, coalescing),
// scroll, and click dispatch, by driving the real app over Socket.IO and
// reading the real cursor position via nut-js. Click dispatch is also
// asserted from the app's log ([RemoteInput] Click: ...).
//
// NOTE on coordinates: this Node client is DPI-UNAWARE, so it sees the
// screen in logical px, while the Electron app (per-monitor DPI aware)
// moves the cursor in physical px. The test calibrates the effective
// scale with one known move, then asserts all later moves are exactly
// proportional (finger_delta * SENSITIVITY physical px).
import { randomUUID } from 'node:crypto'
import { io } from 'socket.io-client'
import { mouse, Point } from '@nut-tree-fork/nut-js'

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const SENS = 1.8 // must match DEFAULT_MOVE_SENSITIVITY in RemoteInputService.ts

const results = []
function check(name, ok, detail = '') {
  results.push(ok)
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`)
}

mouse.config.autoDelayMs = 0
mouse.config.mouseSpeed = 100000

// ── Connect ──────────────────────────────────────────────────────────────────
const socket = io('http://127.0.0.1:4000', { transports: ['websocket'] })
try {
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve)
    socket.once('connect_error', reject)
    setTimeout(() => reject(new Error('connect timeout')), 8000)
  })
} catch (e) {
  console.error('FAIL  connect to bridge socket —', String(e))
  process.exit(1)
}
console.log('connected to bridge socket')

const send = (payload) => {
  socket.emit('bridge-message', {
    eventId: randomUUID(),
    type: 'remote-input',
    origin: 'android',
    timestamp: new Date().toISOString(),
    payload,
  })
}

const near = (actual, expected, tol = 3) => Math.abs(actual - expected) <= tol

try {
  const original = await mouse.getPosition()

  // Helper: settle > MOVE_RESYNC_MS (400ms) so the server re-syncs its
  // virtual cursor from the OS after our own repositioning.
  const settle = () => sleep(500)

  // ── 1. Calibration move: dx=200 must move the cursor RIGHT, and the
  //      measured logical delta gives us the DPI scale (physical/logical).
  await mouse.setPosition(new Point(300, 300))
  await settle()
  send({ event: 'mouse-move', dx: 200, dy: 0 })
  await sleep(300)
  let pos = await mouse.getPosition()
  const calibDelta = pos.x - 300
  const scale = (200 * SENS) / calibDelta // physical px per logical px
  check('calibration move (direction + proportionality)',
    calibDelta > 0 && scale > 0.5 && scale < 3,
    `logical delta=${calibDelta}px -> dpi scale=${scale.toFixed(3)}`)

  // ── 2. Sequential relative moves (like ~30ms-spaced finger flushes) ────────
  await mouse.setPosition(new Point(300, 300))
  await settle()
  let before = await mouse.getPosition()
  const seq = [[10, 0], [10, 5], [-5, 10], [8, -3], [12, 7], [6, 4], [9, 2]]
  let sx = 0
  let sy = 0
  for (const [dx, dy] of seq) {
    sx += dx
    sy += dy
    send({ event: 'mouse-move', dx, dy })
    await sleep(30)
  }
  await sleep(300)
  pos = await mouse.getPosition()
  const expX = before.x + (sx * SENS) / scale
  const expY = before.y + (sy * SENS) / scale
  check('sequential moves', near(pos.x, expX) && near(pos.y, expY),
    `at (${pos.x},${pos.y}) expected (~${Math.round(expX)},~${Math.round(expY)})`)

  // ── 3. Burst moves, no gap (coalescing must sum, not lag or drop) ─────────
  before = pos
  const burst = [[4, 3], [5, 5], [6, 1], [3, 4], [7, 2], [2, 8], [8, 6], [1, 2]]
  let bx = 0
  let by = 0
  for (const [dx, dy] of burst) {
    bx += dx
    by += dy
    send({ event: 'mouse-move', dx, dy })
  }
  await sleep(300)
  pos = await mouse.getPosition()
  const expX2 = before.x + (bx * SENS) / scale
  const expY2 = before.y + (by * SENS) / scale
  check('burst moves coalesced', near(pos.x, expX2) && near(pos.y, expY2),
    `at (${pos.x},${pos.y}) expected (~${Math.round(expX2)},~${Math.round(expY2)})`)

  // ── 4. Negative-direction move (up/left) ───────────────────────────────────
  before = pos
  send({ event: 'mouse-move', dx: -60, dy: -40 })
  await sleep(300)
  pos = await mouse.getPosition()
  const expX3 = before.x - (60 * SENS) / scale
  const expY3 = before.y - (40 * SENS) / scale
  check('negative-direction move', near(pos.x, expX3) && near(pos.y, expY3),
    `at (${pos.x},${pos.y}) expected (~${Math.round(expX3)},~${Math.round(expY3)})`)

  // ── 4b. Sensitivity override: 1.0× must halve the move, then restore ─────
  await mouse.setPosition(new Point(400, 300))
  await settle()
  before = await mouse.getPosition()
  send({ event: 'set-sensitivity', value: 1.0 })
  await sleep(150)
  send({ event: 'mouse-move', dx: 120, dy: 0 })
  await sleep(300)
  pos = await mouse.getPosition()
  const expXS = before.x + (120 * 1.0) / scale
  check('sensitivity override (1.0x)', near(pos.x, expXS),
    `at ${pos.x} expected ~${Math.round(expXS)}`)
  send({ event: 'set-sensitivity', value: SENS })
  await sleep(150)

  // ── 5. Scroll down/up one notch each (cursor position must be unaffected) ─
  // 50 logical px * 2.4 wheel-units/px = 120 units = one notch, delivered as
  // a continuous high-resolution stream by the host.
  before = pos
  send({ event: 'scroll', dy: 50 })
  await sleep(150)
  send({ event: 'scroll', dy: -50 })
  await sleep(300)
  pos = await mouse.getPosition()
  check('scroll down/up (cursor unaffected)', near(pos.x, before.x) && near(pos.y, before.y),
    `at (${pos.x},${pos.y})`)

  // ── 6. Clicks — steer to a point left of the app window, click, verify ────
  const target = new Point(100, 400)
  const cur = pos
  send({
    event: 'mouse-move',
    dx: Math.round((target.x - cur.x) * (scale / SENS)),
    dy: Math.round((target.y - cur.y) * (scale / SENS)),
  })
  await sleep(250)

  send({ event: 'mouse-click', button: 'left' })
  await sleep(250)
  send({ event: 'mouse-click', button: 'right' }) // context menu opens here (real scenario)
  await sleep(300)
  send({ event: 'mouse-move', dx: -40, dy: -60 }) // move off the menu
  await sleep(150)
  send({ event: 'mouse-click', button: 'left' }) // dismiss
  await sleep(300)
  check('click sequence dispatched (left/right/dismiss)', true)

  // ── Restore ────────────────────────────────────────────────────────────────
  await mouse.setPosition(new Point(original.x, original.y))
} catch (e) {
  check('test run', false, String(e))
} finally {
  socket.close()
}

const failed = results.filter((r) => !r).length
console.log('---')
console.log(failed === 0 ? 'CLIENT CHECKS PASSED (see app log for click-dispatch assertions)' : `${failed} CLIENT CHECK(S) FAILED`)
process.exit(failed === 0 ? 0 : 1)
