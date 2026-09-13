import { randomUUID } from 'node:crypto'
import { screen as electronScreen } from 'electron'
import { mouse, Point } from '@nut-tree-fork/nut-js'
import { SocketService } from './SocketService.js'
import type { BridgeMessage, RemoteInputPayload, RemoteOpenPayload } from '../types/protocol.js'

/**
 * Finger-travel (phone logical px) -> screen PHYSICAL px multiplier.
 * The Electron process is per-monitor-DPI-aware, so nut-js cursor
 * coordinates are physical pixels here. 1.8 makes a full-width swipe on
 * a typical phone cover roughly a third of a 1080p-class screen.
 * This is the default; the phone can override it at runtime via
 * `set-sensitivity` (see _handleSetSensitivity).
 */
const DEFAULT_MOVE_SENSITIVITY = 1.8

/**
 * Finger-travel px -> WHEEL UNITS (one wheel notch = 120 units).
 *
 * libnut passes scroll amounts straight through to SendInput as raw
 * mouseData wheel units — NOT whole notches — so we can emit the same
 * fine-grained sub-notch deltas a Windows precision touchpad sends.
 * 2.4 units per finger px keeps the intended speed (50 px of two-finger
 * travel per notch) while streaming small increments at the ~60 Hz wire
 * rate instead of batching them into rare full-notch jumps, which is
 * what made scrolling feel stepped.
 */
const SCROLL_UNITS_PER_PIXEL = 120 / 50

/**
 * If no remote move arrived for this long, re-sync the virtual cursor
 * position from the OS before the next move (so physical mouse moves
 * made in between are respected instead of being overwritten).
 */
const MOVE_RESYNC_MS = 400

interface VirtualBounds {
  minX: number
  minY: number
  maxX: number
  maxY: number
}

/**
 * "Phone as Remote" — stage 1 (trackpad).
 *
 * Applies remote-input events from the Android app to the OS cursor via
 * nut-js (SendInput on Windows). Design notes:
 *
 *  - Movement is relative. We keep a float "virtual" cursor position and
 *    apply each batched delta to it, then mouse.move() to the rounded
 *    target. The fractional remainder stays in the virtual position, so
 *    the ±1px rounding of the native layer at fractional DPI scaling
 *    (e.g. 125%) never accumulates into drift.
 *  - Move deltas that arrive while a native op is in flight are coalesced
 *    (summed) instead of queued one-by-one, so bursts never build up lag.
 *    Scroll deltas get the same treatment, at wheel-unit granularity.
 *  - All native ops are serialized through a single promise chain so
 *    clicks/scroll/move can never interleave mid-event.
 *  - nut-js defaults `mouse.config.autoDelayMs` to 100ms, which would add
 *    a visible delay to every click and scroll — we set it to 0.
 */
class RemoteInputServiceClass {
  private _started = false
  private _nativeReady = false
  private _nativeFailed = false

  // Virtual cursor position (float PHYSICAL px) — null = needs OS re-sync
  private _virtualX: number | null = null
  private _virtualY: number | null = null
  private _lastMoveAt = 0

  // Cursor movement sensitivity multiplier (runtime-settable from the phone)
  private _moveSensitivity = DEFAULT_MOVE_SENSITIVITY

  // Coalesced pending move delta
  private _pendingDx = 0
  private _pendingDy = 0
  private _flushScheduled = false

  // Leftover scroll units below one whole wheel unit (fractional)
  private _scrollAccum = 0

  // Coalesced pending whole wheel units below the current flush
  private _pendingScrollUnits = 0
  private _scrollFlushScheduled = false

  // Serializes native operations (one at a time, in arrival order)
  private _chain: Promise<unknown> = Promise.resolve()

  // Cached union of all display bounds, in PHYSICAL px (see _getBounds)
  private _bounds: VirtualBounds | null = null

  start(): void {
    if (this._started) return
    this._started = true

    console.log('[RemoteInput] Remote input service initialized and listening')

    electronScreen.on('display-metrics-changed', () => {
      this._bounds = null
    })

    SocketService.onMessage('remote-input', (rawMsg: BridgeMessage) => {
      const msg = rawMsg as BridgeMessage<RemoteInputPayload>
      const payload = msg.payload
      if (!payload || !payload.event) return

      switch (payload.event) {
        case 'mouse-move':
          this._handleMove(Number(payload.dx) || 0, Number(payload.dy) || 0)
          break
        case 'mouse-click':
          this._handleClick(payload.button === 'right' ? 'right' : 'left')
          break
        case 'scroll':
          this._handleScroll(Number(payload.dy) || 0)
          break
        case 'set-sensitivity':
          this._handleSetSensitivity(Number(payload.value) || 0)
          break
        default:
          break
      }
    })
  }

  /** Windows → Android: ask the phone to open the Remote (trackpad) screen. */
  openRemote(): void {
    const msg: BridgeMessage<RemoteOpenPayload> = {
      eventId: randomUUID(),
      type: 'remote-input',
      origin: 'windows',
      timestamp: new Date().toISOString(),
      payload: { event: 'open-remote' },
    }
    console.log('[RemoteInput] [SEND] Asking phone to open Remote screen')
    SocketService.broadcast(msg as BridgeMessage<unknown>)
  }

  // ── Handlers ────────────────────────────────────────────────────────────────

  private _handleMove(dx: number, dy: number): void {
    if (dx === 0 && dy === 0) return
    this._pendingDx += dx
    this._pendingDy += dy
    if (!this._flushScheduled) {
      this._flushScheduled = true
      setImmediate(() => {
        void this._flushMove()
      })
    }
  }

  private async _flushMove(): Promise<void> {
    this._flushScheduled = false
    const dx = this._pendingDx
    const dy = this._pendingDy
    this._pendingDx = 0
    this._pendingDy = 0
    if (dx === 0 && dy === 0) return

    if (!(await this._ensureNative())) return

    // Re-sync virtual position from the OS after an idle gap (physical
    // mouse may have moved the cursor in the meantime).
    const now = Date.now()
    if (this._virtualX === null || this._virtualY === null || now - this._lastMoveAt > MOVE_RESYNC_MS) {
      const pos = await mouse.getPosition()
      this._virtualX = pos.x
      this._virtualY = pos.y
    }
    this._lastMoveAt = now

    const bounds = this._getBounds()
    this._virtualX = Math.min(Math.max(this._virtualX + dx * this._moveSensitivity, bounds.minX), bounds.maxX)
    this._virtualY = Math.min(Math.max(this._virtualY + dy * this._moveSensitivity, bounds.minY), bounds.maxY)

    const target = new Point(Math.round(this._virtualX), Math.round(this._virtualY))
    this._enqueue(async () => {
      try {
        await mouse.move([target])
      } catch (err) {
        console.error('[RemoteInput] mouse.move() failed:', err)
        // Force re-sync from OS on next move
        this._virtualX = null
        this._virtualY = null
      }
    })
  }

  private _handleClick(button: 'left' | 'right'): void {
    this._enqueue(async () => {
      if (!(await this._ensureNative())) return
      try {
        if (button === 'left') {
          await mouse.leftClick()
        } else {
          await mouse.rightClick()
        }
        console.log(`[RemoteInput] Click: ${button}`)
      } catch (err) {
        console.error(`[RemoteInput] ${button}Click() failed:`, err)
      }
    })
  }

  /**
   * Continuous, high-resolution scrolling. Pixels are converted into
   * wheel units (120 per notch) and emitted as soon as they reach one
   * whole unit, so the OS receives a smooth stream of sub-notch deltas —
   * exactly what a precision touchpad produces — instead of rare
   * full-notch jumps. Bursts arriving within one event-loop tick are
   * summed (same coalescing the move path uses) so lag can never build
   * up; scroll speed is unchanged (~50 px of finger travel per notch).
   */
  private _handleScroll(dy: number): void {
    if (!Number.isFinite(dy) || dy === 0) return
    this._scrollAccum += dy * SCROLL_UNITS_PER_PIXEL

    const units = Math.trunc(this._scrollAccum)
    if (units !== 0) {
      this._scrollAccum -= units
      this._pendingScrollUnits += units
    }
    if (this._pendingScrollUnits === 0) return

    if (!this._scrollFlushScheduled) {
      this._scrollFlushScheduled = true
      setImmediate(() => {
        void this._flushScroll()
      })
    }
  }

  private async _flushScroll(): Promise<void> {
    this._scrollFlushScheduled = false
    const units = this._pendingScrollUnits
    this._pendingScrollUnits = 0
    if (units === 0 || !(await this._ensureNative())) return

    const down = units > 0
    const amount = Math.abs(units)
    this._enqueue(async () => {
      try {
        if (down) {
          await mouse.scrollDown(amount)
        } else {
          await mouse.scrollUp(amount)
        }
      } catch (err) {
        console.error(`[RemoteInput] scroll${down ? 'Down' : 'Up'}(${amount}) failed:`, err)
      }
    })
  }

  /**
   * Cursor-movement sensitivity override from the phone (affects mouse
   * moves only — never scroll speed or clicks). The phone's slider range
   * is 0.5–3; clamped defensively in case of garbage on the wire.
   */
  private _handleSetSensitivity(value: number): void {
    if (!Number.isFinite(value)) return
    const clamped = Math.min(Math.max(value, 0.1), 5)
    if (clamped !== this._moveSensitivity) {
      this._moveSensitivity = clamped
      console.log(`[RemoteInput] Move sensitivity set to ${clamped}×`)
    }
  }

  // ── Native layer ────────────────────────────────────────────────────────────

  /**
   * Configures nut-js exactly once. Failures are logged loudly — this is
   * a native dependency (SendInput via libnut) and any problem here must
   * be visible, not silently swallowed.
   */
  private async _ensureNative(): Promise<boolean> {
    if (this._nativeReady) return true
    if (this._nativeFailed) return false

    try {
      // nut-js default is 100ms — would make every click/scroll feel laggy.
      mouse.config.autoDelayMs = 0
      // mouse.move() busy-waits 1/mouseSpeed sec per call; default (1000)
      // blocks the event loop 1ms per move. 100000 -> 10us, negligible.
      mouse.config.mouseSpeed = 100000
      // Probe the native binding so a broken install surfaces on first use,
      // not silently at runtime later.
      await mouse.getPosition()
      this._nativeReady = true
      console.log('[RemoteInput] nut-js native input layer ready (mouse control active)')
      return true
    } catch (err) {
      this._nativeFailed = true
      console.error(
        '[RemoteInput] FAILED to initialize nut-js native input layer!',
        'Remote input (trackpad) will NOT work until this is fixed.',
        err,
      )
      return false
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /**
   * Union bounds of all displays, in the PHYSICAL pixel space nut-js uses
   * (the Electron process is per-monitor-DPI-aware, so cursor coordinates
   * are physical). Each display's DIP bounds are scaled by its own
   * scaleFactor, which is correct even across mixed-DPI multi-monitor
   * setups — so the cursor can reach every monitor.
   */
  private _getBounds(): VirtualBounds {
    if (this._bounds) return this._bounds
    try {
      let minX = Infinity
      let minY = Infinity
      let maxX = -Infinity
      let maxY = -Infinity
      for (const display of electronScreen.getAllDisplays()) {
        const sf = display.scaleFactor ?? 1
        const b = display.bounds
        minX = Math.min(minX, Math.round(b.x * sf))
        minY = Math.min(minY, Math.round(b.y * sf))
        maxX = Math.max(maxX, Math.round((b.x + b.width) * sf))
        maxY = Math.max(maxY, Math.round((b.y + b.height) * sf))
      }
      this._bounds = { minX, minY, maxX: maxX - 1, maxY: maxY - 1 }
    } catch (err) {
      console.error('[RemoteInput] Failed to compute display bounds:', err)
    }
    return this._bounds ?? { minX: 0, minY: 0, maxX: 1920, maxY: 1080 }
  }

  /** Serialize native ops; keep the chain alive across failures. */
  private _enqueue(op: () => Promise<unknown>): void {
    this._chain = this._chain.then(op).catch((err) => {
      console.error('[RemoteInput] Native op error:', err)
    })
  }
}

export const RemoteInputService = new RemoteInputServiceClass()
