// Manual smoke test: does @nut-tree-fork/nut-js load and run inside the
// Electron runtime (same Node/N-API surface the shipped app uses)?
// Run: npx electron test/electron-nut-smoke.cjs
const { app } = require('electron')
const { mouse, Point } = require('@nut-tree-fork/nut-js')

app.whenReady().then(async () => {
  try {
    // Same configuration RemoteInputService applies.
    mouse.config.autoDelayMs = 0
    mouse.config.mouseSpeed = 100000

    const start = await mouse.getPosition()
    console.log(`[electron-smoke] nut-js loaded in Electron; mouse at (${start.x}, ${start.y})`)

    await mouse.move([new Point(start.x + 30, start.y + 20)])
    const after = await mouse.getPosition()
    const ok = after.x === start.x + 30 && after.y === start.y + 20
    console.log(`[electron-smoke] after mouse.move: (${after.x}, ${after.y}) -> ${ok ? 'PASS' : 'FAIL'}`)

    await mouse.move([new Point(start.x, start.y)])
    app.exit(ok ? 0 : 1)
  } catch (e) {
    console.error('[electron-smoke] FAILED:', e)
    app.exit(1)
  }
})
