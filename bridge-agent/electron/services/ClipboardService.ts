import { clipboard } from 'electron'
import { randomUUID } from 'node:crypto'
import { SocketService } from './SocketService.js'
import { EventDedupe } from './EventDedupe.js'
import type { BridgeMessage, ClipboardPayload } from '../types/protocol.js'

const POLL_INTERVAL_MS = 500

class ClipboardServiceClass {
  private _lastText = ''
  private _dedupe = new EventDedupe()
  private _timer: ReturnType<typeof setInterval> | null = null

  start(): void {
    // Listen for incoming clipboard messages from Android
    SocketService.onMessage('clipboard', (msg: BridgeMessage) => {
      this._handleIncoming(msg as BridgeMessage<ClipboardPayload>)
    })

    // When a new Android client connects, immediately push the current Windows
    // clipboard to it. This covers the case where the user copied text on Windows
    // while Bridge was closed/backgrounded on Android.
    SocketService.onClientConnect(() => {
      // Small delay so the client's bridge-message listener is registered first
      setTimeout(() => this._pushCurrentToClient(), 150)
    })

    // Poll the Windows clipboard for changes
    this._lastText = clipboard.readText()
    this._timer = setInterval(() => this._poll(), POLL_INTERVAL_MS)
    console.log('[ClipboardService] Started — polling every 500ms')
  }

  stop(): void {
    if (this._timer !== null) {
      clearInterval(this._timer)
      this._timer = null
    }
  }

  private _pushCurrentToClient(): void {
    const current = clipboard.readText()
    if (!current || current.trim() === '') return

    const eventId = randomUUID()
    this._dedupe.add(eventId)
    // Update _lastText so the next poll doesn't redundantly re-send this
    this._lastText = current

    const msg: BridgeMessage<ClipboardPayload> = {
      eventId,
      type: 'clipboard',
      origin: 'windows',
      timestamp: new Date().toISOString(),
      payload: { text: current },
    }
    console.log(`[ClipboardService] Pushing current clipboard to new client: "${current.slice(0, 60)}${current.length > 60 ? '…' : ''}"`)
    SocketService.broadcast(msg)
  }

  private _poll(): void {
    const current = clipboard.readText()
    if (current === this._lastText || current.trim() === '') return

    const eventId = randomUUID()
    if (this._dedupe.has(eventId)) return   // astronomically unlikely, but guard anyway

    this._lastText = current
    this._dedupe.add(eventId)

    const msg: BridgeMessage<ClipboardPayload> = {
      eventId,
      type: 'clipboard',
      origin: 'windows',
      timestamp: new Date().toISOString(),
      payload: { text: current },
    }
    SocketService.broadcast(msg)
  }

  private _handleIncoming(msg: BridgeMessage<ClipboardPayload>): void {
    if (this._dedupe.has(msg.eventId)) {
      console.log(`[ClipboardService] Dedupe suppressed echo for ${msg.eventId}`)
      return
    }

    const text = msg.payload?.text ?? ''
    if (!text) return

    // Write to Windows clipboard
    clipboard.writeText(text)
    // Track so our next poll doesn't echo it back
    this._lastText = text
    this._dedupe.add(msg.eventId)
    console.log(`[ClipboardService] Written to Windows clipboard: "${text.slice(0, 60)}${text.length > 60 ? '…' : ''}"`)
  }
}

export const ClipboardService = new ClipboardServiceClass()
