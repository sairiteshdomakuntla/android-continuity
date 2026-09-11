import { clipboard } from 'electron'
import { randomUUID } from 'node:crypto'
import { SocketService } from './SocketService.js'
import { EventDedupe } from './EventDedupe.js'
import { ClipboardHistoryService } from './ClipboardHistoryService.js'
import type { BridgeMessage, ClipboardPayload } from '../types/protocol.js'

const POLL_INTERVAL_MS = 500
const COOLDOWN_MS = 1500

function normalizeText(text: string): string {
  return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
}

function previewText(text: string, maxLen = 60): string {
  const clean = text.replace(/[\r\n\t]+/g, ' ')
  return clean.length > maxLen ? `${clean.slice(0, maxLen)}…` : clean
}

class ClipboardServiceClass {
  private _lastRawText = ''
  private _lastNormalizedText = ''
  private _lastNormalizedSentText = ''
  private _lastSentTime = 0
  private _dedupe = new EventDedupe()
  private _timer: ReturnType<typeof setInterval> | null = null

  start(): void {
    // Listen for incoming clipboard messages from Android
    SocketService.onMessage('clipboard', (msg: BridgeMessage) => {
      this._handleIncoming(msg as BridgeMessage<ClipboardPayload>)
    })

    // When a new Android client connects, push current clipboard if not already sent
    SocketService.onClientConnect(() => {
      setTimeout(() => this._pushCurrentToClient(), 150)
    })

    // Initialize initial text
    this._lastRawText = clipboard.readText()
    this._lastNormalizedText = normalizeText(this._lastRawText)
    this._lastNormalizedSentText = this._lastNormalizedText

    // Record initial clipboard in history if present
    if (this._lastRawText && this._lastRawText.trim() !== '') {
      ClipboardHistoryService.addEntry(this._lastRawText, 'windows')
    }

    this._timer = setInterval(() => this._poll(), POLL_INTERVAL_MS)
    console.log('[ClipboardService] Started — polling every 500ms with normalized change detection and duplicate suppression')
  }

  stop(): void {
    if (this._timer !== null) {
      clearInterval(this._timer)
      this._timer = null
    }
  }

  /**
   * Copies an entry back to the Windows local clipboard without syncing it to Android.
   */
  copyLocally(text: string): void {
    if (!text) return
    clipboard.writeText(text)
    this._lastRawText = text
    const norm = normalizeText(text)
    this._lastNormalizedText = norm
    this._lastNormalizedSentText = norm
    this._lastSentTime = Date.now()
    console.log(`[ClipboardService] Local copy from history: "${previewText(text)}" (sync suppressed)`)
  }

  private _pushCurrentToClient(): void {
    const current = clipboard.readText()
    if (!current || current.trim() === '') return

    const norm = normalizeText(current)
    if (norm === this._lastNormalizedSentText) {
      console.log(`[ClipboardService] [CLIENT CONNECT] Current clipboard already sent ("${previewText(current)}") — skipping redundant push`)
      return
    }

    const eventId = randomUUID()
    this._dedupe.add(eventId)
    this._lastRawText = current
    this._lastNormalizedText = norm
    this._lastNormalizedSentText = norm
    this._lastSentTime = Date.now()

    ClipboardHistoryService.addEntry(current, 'windows', new Date().toISOString(), eventId)

    const msg: BridgeMessage<ClipboardPayload> = {
      eventId,
      type: 'clipboard',
      origin: 'windows',
      timestamp: new Date().toISOString(),
      payload: { text: current },
    }
    console.log(`[ClipboardService] [CLIENT CONNECT] Pushing clipboard to new client: eventId=${eventId}, "${previewText(current)}"`)
    SocketService.broadcast(msg)
  }

  private _poll(): void {
    const current = clipboard.readText()
    if (current === this._lastRawText || current.trim() === '') return

    console.log(`[ClipboardService] [POLL] Detected raw clipboard change: len=${current.length} (prev=${this._lastRawText.length}), preview="${previewText(current)}"`)

    const norm = normalizeText(current)

    // Check if normalized text is unchanged (e.g. line ending conversion / format variation)
    if (norm === this._lastNormalizedText) {
      console.log('[ClipboardService] [POLL] Normalized text matches previous state — suppressing redundant send')
      this._lastRawText = current
      return
    }

    // Cooldown check for rapid repeated copy of exact same content
    const now = Date.now()
    if (norm === this._lastNormalizedSentText && now - this._lastSentTime < COOLDOWN_MS) {
      console.log(`[ClipboardService] [POLL] Suppressing send within ${COOLDOWN_MS}ms cooldown for identical text`)
      this._lastRawText = current
      this._lastNormalizedText = norm
      return
    }

    const eventId = randomUUID()
    if (this._dedupe.has(eventId)) return

    this._lastRawText = current
    this._lastNormalizedText = norm
    this._lastNormalizedSentText = norm
    this._lastSentTime = now
    this._dedupe.add(eventId)

    // Add to local history
    ClipboardHistoryService.addEntry(current, 'windows', new Date().toISOString(), eventId)

    const msg: BridgeMessage<ClipboardPayload> = {
      eventId,
      type: 'clipboard',
      origin: 'windows',
      timestamp: new Date().toISOString(),
      payload: { text: current },
    }
    console.log(`[ClipboardService] [SEND] Broadcasting to Android: eventId=${eventId}, "${previewText(current)}"`)
    SocketService.broadcast(msg)
  }

  private _handleIncoming(msg: BridgeMessage<ClipboardPayload>): void {
    if (this._dedupe.has(msg.eventId)) {
      console.log(`[ClipboardService] [DEDUPE] Suppressed echo for ${msg.eventId}`)
      return
    }

    const text = msg.payload?.text ?? ''
    if (!text) return

    console.log(`[ClipboardService] [RECV] Incoming clipboard from ${msg.origin}: eventId=${msg.eventId}, "${previewText(text)}"`)

    // Write to Windows clipboard
    clipboard.writeText(text)

    // Track so our next poll doesn't echo it back
    this._lastRawText = text
    const norm = normalizeText(text)
    this._lastNormalizedText = norm
    this._lastNormalizedSentText = norm
    this._lastSentTime = Date.now()
    this._dedupe.add(msg.eventId)

    // Add to history
    ClipboardHistoryService.addEntry(text, msg.origin, msg.timestamp, msg.eventId)
    console.log(`[ClipboardService] Written to Windows clipboard and added to history: "${previewText(text)}"`)
  }
}

export const ClipboardService = new ClipboardServiceClass()
