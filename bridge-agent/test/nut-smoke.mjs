// Manual smoke test for the nut-js native input layer (Windows).
// Run: node test/nut-smoke.mjs
//
// This moves the real mouse cursor, scrolls, and clicks once —
// run it when a harmless window/desktop is in the foreground.
import { mouse, screen, Point } from '@nut-tree-fork/nut-js'

const results = []
function check(name, ok, detail = '') {
  results.push({ name, ok, detail })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`)
}

mouse.config.autoDelayMs = 0

console.log('--- nut-js smoke test ---')

// 1. Native module responds: read current position
const start = await mouse.getPosition()
check('getPosition()', Number.isFinite(start.x) && Number.isFinite(start.y), `start=(${start.x}, ${start.y})`)

// 2. setPosition + read back (absolute)
await mouse.setPosition(new Point(start.x + 40, start.y + 25))
let p = await mouse.getPosition()
check('setPosition(+40, +25)', p.x === start.x + 40 && p.y === start.y + 25, `read=(${p.x}, ${p.y})`)

// 3. Move back (negative delta)
await mouse.setPosition(new Point(start.x, start.y))
p = await mouse.getPosition()
check('setPosition(back to start)', p.x === start.x && p.y === start.y, `read=(${p.x}, ${p.y})`)

// 4. Screen bounds available
const w = await screen.width()
const h = await screen.height()
check('screen.width()/height()', w > 0 && h > 0, `screen=${w}x${h}`)

// 5. Clamp math (same logic RemoteInputService uses)
const clamp = (v, min, max) => Math.max(min, Math.min(max, v))
const clamped = clamp(w + 500, 0, w - 1)
check('clamp bounds math', clamped === w - 1, `clamp(w+500) -> ${clamped}`)

// 6. Scroll down/up one notch
try {
  await mouse.scrollDown(1)
  await new Promise((r) => setTimeout(r, 120))
  await mouse.scrollUp(1)
  check('scrollDown(1) / scrollUp(1)', true)
} catch (e) {
  check('scrollDown(1) / scrollUp(1)', false, String(e))
}

// 7. Left click at screen center (focuses whatever is there; harmless)
const cx = Math.floor(w / 2)
const cy = Math.floor(h / 2)
try {
  await mouse.setPosition(new Point(cx, cy))
  await mouse.leftClick()
  check('leftClick()', true)
} catch (e) {
  check('leftClick()', false, String(e))
}

// 8. Right click at center (opens a context menu if a window/desktop is there),
//    then dismiss it with a left click well outside the menu.
try {
  await mouse.rightClick()
  await new Promise((r) => setTimeout(r, 150))
  await mouse.setPosition(new Point(Math.max(10, cx - 260), Math.max(10, cy - 200)))
  await mouse.leftClick()
  check('rightClick() (+ dismiss)', true)
} catch (e) {
  check('rightClick() (+ dismiss)', false, String(e))
}

// 9. Restore original cursor position
await mouse.setPosition(new Point(start.x, start.y))

const failed = results.filter((r) => !r.ok)
console.log('---')
console.log(failed.length === 0 ? 'ALL CHECKS PASSED' : `${failed.length} CHECK(S) FAILED`)
process.exit(failed.length === 0 ? 0 : 1)
