import { clipboard, nativeImage } from 'electron'
import { randomUUID } from 'node:crypto'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { SocketService } from './SocketService.js'
import { EventDedupe } from './EventDedupe.js'
import { ClipboardHistoryService } from './ClipboardHistoryService.js'
import { FileTransferService } from './FileTransferService.js'
import type { BridgeMessage, ClipboardPayload, ClipboardHistoryItem } from '../types/protocol.js'

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
  private _lastImageHash = ''
  private _lastImageSentHash = ''
  private _lastSentTime = 0
  private _dedupe = new EventDedupe()
  private _timer: ReturnType<typeof setInterval> | null = null

  start(): void {
    // Listen for incoming clipboard messages from Android
    SocketService.onMessage('clipboard', (msg: BridgeMessage) => {
      this._handleIncoming(msg as BridgeMessage<ClipboardPayload>)
    })

    // Listen for verified clipboard images received via chunked transfer
    FileTransferService.onClipboardImageReceived((info) => {
      this._handleIncomingImage(info)
    })

    // When a new Android client connects, push current clipboard if not already sent
    SocketService.onClientConnect(() => {
      setTimeout(() => this._pushCurrentToClient(), 150)
    })

    // Initialize initial text and image hash
    this._lastRawText = clipboard.readText()
    this._lastNormalizedText = normalizeText(this._lastRawText)
    this._lastNormalizedSentText = this._lastNormalizedText

    const initialImg = clipboard.readImage()
    if (!initialImg.isEmpty()) {
      const pngBuf = initialImg.toPNG()
      this._lastImageHash = crypto.createHash('sha256').update(pngBuf).digest('hex')
      this._lastImageSentHash = this._lastImageHash
    }

    // Record initial text in history if present
    if (this._lastRawText && this._lastRawText.trim() !== '') {
      ClipboardHistoryService.addEntry(this._lastRawText, 'windows')
    }

    this._timer = setInterval(() => this._poll(), POLL_INTERVAL_MS)
    console.log('[ClipboardService] Started — polling every 500ms with rich type support (text + image)')
  }

  stop(): void {
    if (this._timer !== null) {
      clearInterval(this._timer)
      this._timer = null
    }
  }

  /**
   * Copies an entry back to the Windows local clipboard without syncing it to Android.
   * Supports both history item ID, full item object, or raw text.
   */
  copyLocally(itemOrText: string | ClipboardHistoryItem): void {
    if (!itemOrText) return

    let item: ClipboardHistoryItem | undefined
    if (typeof itemOrText === 'string') {
      item = ClipboardHistoryService.getItemById(itemOrText)
    } else {
      item = itemOrText
    }

    if (item && item.kind === 'image' && item.imagePath && fs.existsSync(item.imagePath)) {
      try {
        const img = nativeImage.createFromPath(item.imagePath)
        if (!img.isEmpty()) {
          const pngBuf = img.toPNG()
          const hash = crypto.createHash('sha256').update(pngBuf).digest('hex')
          this._lastImageHash = hash
          this._lastImageSentHash = hash
          this._lastRawText = ''
          this._lastNormalizedText = ''
          clipboard.writeImage(img)
          console.log(`[ClipboardService] Local copy image from history: ${item.imagePath} (sync suppressed)`)
          return
        }
      } catch (e) {
        console.error('[ClipboardService] Error restoring image from history:', e)
      }
    }

    const text = typeof itemOrText === 'string' && !item ? itemOrText : (item?.text || '')
    if (!text) return

    clipboard.writeText(text)
    this._lastRawText = text
    const norm = normalizeText(text)
    this._lastNormalizedText = norm
    this._lastNormalizedSentText = norm
    this._lastImageHash = ''
    this._lastSentTime = Date.now()
    console.log(`[ClipboardService] Local copy from history: "${previewText(text)}" (sync suppressed)`)
  }

  private _pushCurrentToClient(): void {
    // 1. Check if an image is currently in the clipboard
    const img = clipboard.readImage()
    if (!img.isEmpty()) {
      const pngBuf = img.toPNG()
      const hash = crypto.createHash('sha256').update(pngBuf).digest('hex')
      if (hash === this._lastImageSentHash) {
        console.log('[ClipboardService] [CLIENT CONNECT] Current image already sent — skipping push')
        return
      }

      const eventId = randomUUID()
      this._dedupe.add(eventId)
      this._lastImageHash = hash
      this._lastImageSentHash = hash
      this._lastRawText = ''
      this._lastNormalizedText = ''

      const cacheDir = ClipboardHistoryService.getImagesDir()
      const imagePath = path.join(cacheDir, `clip_${eventId}.png`)
      try {
        fs.writeFileSync(imagePath, pngBuf)
      } catch (e) {
        console.warn('[ClipboardService] Failed to cache initial image:', e)
      }

      const thumbnail = img.resize({ width: 160 }).toDataURL()
      ClipboardHistoryService.addImageEntry(thumbnail, imagePath, 'windows', new Date().toISOString(), eventId)

      // Emit announcement + chunked transfer
      const msg: BridgeMessage<ClipboardPayload> = {
        eventId,
        type: 'clipboard',
        origin: 'windows',
        timestamp: new Date().toISOString(),
        payload: {
          kind: 'image',
          transferId: eventId,
          mimeType: 'image/png',
        },
      }
      SocketService.broadcast(msg)
      FileTransferService.sendClipboardImage(pngBuf, eventId)
      return
    }

    // 2. Otherwise push text
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
      payload: { kind: 'text', text: current },
    }
    console.log(`[ClipboardService] [CLIENT CONNECT] Pushing clipboard to new client: eventId=${eventId}, "${previewText(current)}"`)
    SocketService.broadcast(msg)
  }

  private _poll(): void {
    // 1. Check for image copy
    const img = clipboard.readImage()
    if (!img.isEmpty()) {
      const pngBuf = img.toPNG()
      const hash = crypto.createHash('sha256').update(pngBuf).digest('hex')

      if (hash !== this._lastImageHash) {
        console.log(`[ClipboardService] [POLL] Detected image clipboard change: ${pngBuf.length} bytes, hash=${hash.slice(0, 10)}`)
        this._lastImageHash = hash
        this._lastImageSentHash = hash
        this._lastRawText = ''
        this._lastNormalizedText = ''
        this._lastNormalizedSentText = ''

        const transferId = randomUUID()
        this._dedupe.add(transferId)

        const cacheDir = ClipboardHistoryService.getImagesDir()
        const imagePath = path.join(cacheDir, `clip_${transferId}.png`)
        try {
          fs.writeFileSync(imagePath, pngBuf)
        } catch (e) {
          console.warn('[ClipboardService] Failed to cache local image copy:', e)
        }

        const thumbnail = img.resize({ width: 160 }).toDataURL()
        ClipboardHistoryService.addImageEntry(thumbnail, imagePath, 'windows', new Date().toISOString(), transferId)

        const msg: BridgeMessage<ClipboardPayload> = {
          eventId: transferId,
          type: 'clipboard',
          origin: 'windows',
          timestamp: new Date().toISOString(),
          payload: {
            kind: 'image',
            transferId,
            mimeType: 'image/png',
          },
        }
        SocketService.broadcast(msg)
        FileTransferService.sendClipboardImage(pngBuf, transferId)
      }
      return
    }

    // Image is empty in clipboard — clear image hash so future image copies are detected
    this._lastImageHash = ''

    // 2. Check for text copy
    const current = clipboard.readText()
    if (current === this._lastRawText || current.trim() === '') return

    console.log(`[ClipboardService] [POLL] Detected raw clipboard change: len=${current.length} (prev=${this._lastRawText.length}), preview="${previewText(current)}"`)

    const norm = normalizeText(current)

    // Check if normalized text is unchanged
    if (norm === this._lastNormalizedText) {
      this._lastRawText = current
      return
    }

    // Cooldown check for rapid repeated copy of identical text
    const now = Date.now()
    if (norm === this._lastNormalizedSentText && now - this._lastSentTime < COOLDOWN_MS) {
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

    // Add to local history with auto-classification
    ClipboardHistoryService.addEntry(current, 'windows', new Date().toISOString(), eventId)

    const msg: BridgeMessage<ClipboardPayload> = {
      eventId,
      type: 'clipboard',
      origin: 'windows',
      timestamp: new Date().toISOString(),
      payload: { kind: 'text', text: current },
    }
    console.log(`[ClipboardService] [SEND] Broadcasting to Android: eventId=${eventId}, "${previewText(current)}"`)
    SocketService.broadcast(msg)
  }

  private _handleIncoming(msg: BridgeMessage<ClipboardPayload>): void {
    if (this._dedupe.has(msg.eventId)) {
      return
    }

    if (msg.payload?.kind === 'image') {
      // Chunked image transfer will be delivered by FileTransferService.
      // Do NOT add msg.eventId to _dedupe here: the sender reuses the same
      // id as transferId, and _handleIncomingImage relies on _dedupe as its
      // exactly-once guard — adding it now would suppress the real image.
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
    this._lastImageHash = ''
    this._lastSentTime = Date.now()
    this._dedupe.add(msg.eventId)

    // Add to history
    ClipboardHistoryService.addEntry(text, msg.origin, msg.timestamp, msg.eventId)
    console.log(`[ClipboardService] Written to Windows clipboard and added to history: "${previewText(text)}"`)
  }

  private _handleIncomingImage(info: { img: Electron.NativeImage; sha256: string; path: string; transferId: string }): void {
    if (this._dedupe.has(info.transferId)) {
      console.log(`[ClipboardService] Suppressing duplicate received image: ${info.transferId}`)
      return
    }

    this._dedupe.add(info.transferId)
    this._lastRawText = ''
    this._lastNormalizedText = ''
    this._lastNormalizedSentText = ''
    this._lastSentTime = Date.now()

    // Write directly to Windows clipboard so user can immediately Ctrl+V into Paint, Word, etc.
    clipboard.writeImage(info.img)

    // IMPORTANT: Compute _lastImageHash from the clipboard readback using
    // the same method _poll() uses (clipboard.readImage().toPNG()), NOT from
    // info.sha256. The raw file SHA-256 differs from what Electron's PNG
    // encoder produces, so the poll would detect a "new" image and echo it
    // back to Android.
    const readback = clipboard.readImage()
    if (!readback.isEmpty()) {
      const pngBuf = readback.toPNG()
      const readbackHash = crypto.createHash('sha256').update(pngBuf).digest('hex')
      this._lastImageHash = readbackHash
      this._lastImageSentHash = readbackHash
    } else {
      // Fallback: use the file hash (better than nothing)
      this._lastImageHash = info.sha256
      this._lastImageSentHash = info.sha256
    }

    const thumbnail = info.img.resize({ width: 160 }).toDataURL()
    ClipboardHistoryService.addImageEntry(thumbnail, info.path, 'android', new Date().toISOString(), info.transferId)
    console.log(`[ClipboardService] Written received image to Windows clipboard and history (path: ${info.path})`)
  }
}

export const ClipboardService = new ClipboardServiceClass()
