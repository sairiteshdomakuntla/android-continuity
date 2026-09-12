import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import crypto from 'node:crypto'
import { randomUUID } from 'node:crypto'
import { Notification, nativeImage } from 'electron'
import type { NativeImage } from 'electron'
import { SocketService } from './SocketService.js'
import { ClipboardHistoryService } from './ClipboardHistoryService.js'
import type {
  BridgeMessage,
  FileMetaPayload,
  FileChunkPayload,
  FileCompletePayload,
  FilePayload,
} from '../types/protocol.js'

const CHUNK_SIZE = 65536 // 64 KB

/** Progress update emitted to the renderer during Windows→Android sends */
export interface FileSendProgress {
  transferId: string
  fileName: string
  bytesSent: number
  totalBytes: number
  done: boolean
  error?: string
}

export interface ClipboardImageReceivedInfo {
  img: NativeImage
  sha256: string
  path: string
  transferId: string
}

type ProgressHandler = (p: FileSendProgress) => void
type ClipboardImageHandler = (info: ClipboardImageReceivedInfo) => void

// ── In-progress receive state (Android → Windows) ────────────────────────────

interface ReceiveState {
  fileName: string
  destPath: string
  stream: fs.WriteStream
  hash: crypto.Hash
  chunksReceived: number
  totalChunks: number
  isClipboardImage?: boolean
}

class FileTransferServiceClass {
  private _receives = new Map<string, ReceiveState>()
  private _progressHandlers: ProgressHandler[] = []
  private _clipboardImageHandlers: ClipboardImageHandler[] = []
  private _sendQueue: Promise<unknown> = Promise.resolve()

  start(): void {
    SocketService.onMessage('file', (msg: BridgeMessage) => {
      this._handleIncoming(msg as BridgeMessage<FilePayload>)
    })
    console.log('[FileTransferService] Started — listening for file messages')
  }

  onSendProgress(handler: ProgressHandler): void {
    this._progressHandlers.push(handler)
  }

  onClipboardImageReceived(handler: ClipboardImageHandler): void {
    this._clipboardImageHandlers.push(handler)
  }

  private _enqueueSend<T>(fn: () => Promise<T>): Promise<T> {
    const next = this._sendQueue.then(fn, fn)
    this._sendQueue = next.then(
      () => {},
      () => {}
    )
    return next
  }

  // ── Windows → Android: send a file ────────────────────────────────────────

  async sendFile(filePath: string): Promise<void> {
    return this._enqueueSend(async () => {
      const fileName = path.basename(filePath)
      const transferId = randomUUID()

      if (!SocketService.hasConnectedClients()) {
        const errMsg = 'No connected Android phone found. Please open Bridge on your phone.'
        console.warn(`[FileTransferService] ${errMsg}`)
        this._emitProgress({ transferId, fileName, bytesSent: 0, totalBytes: 0, done: false, error: errMsg })
        throw new Error(errMsg)
      }

      const stat = await fs.promises.stat(filePath)
      const totalBytes = stat.size
      const totalChunks = Math.ceil(totalBytes / CHUNK_SIZE)
      const mimeType = this._guessMime(fileName)

      console.log(`[FileTransferService] Sending "${fileName}" (${totalBytes} bytes, ${totalChunks} chunks) to connected Android device`)

      // Emit file-meta
      SocketService.broadcast(
        this._envelope('file-meta', 'windows', {
          event: 'file-meta',
          transferId,
          fileName,
          mimeType,
          totalBytes,
          totalChunks,
          transferType: 'file',
        } satisfies FileMetaPayload)
      )

      // Allow mobile client to prepare MediaStore file stream before receiving chunks
      await new Promise((resolve) => setTimeout(resolve, 100))

      // Stream file, hash incrementally
      const hash = crypto.createHash('sha256')
      const readStream = fs.createReadStream(filePath, { highWaterMark: CHUNK_SIZE })
      let index = 0
      let bytesSent = 0

      for await (const rawChunk of readStream) {
        const buf = Buffer.isBuffer(rawChunk) ? rawChunk : Buffer.from(rawChunk as ArrayBufferLike)
        hash.update(buf)
        const data = buf.toString('base64')

        SocketService.broadcast(
          this._envelope('file-chunk', 'windows', {
            event: 'file-chunk',
            transferId,
            index,
            data,
          } satisfies FileChunkPayload)
        )

        bytesSent += buf.byteLength
        index++
        this._emitProgress({ transferId, fileName, bytesSent, totalBytes, done: false })
        await new Promise((resolve) => setTimeout(resolve, 5))
      }

      const sha256 = hash.digest('hex')
      SocketService.broadcast(
        this._envelope('file-complete', 'windows', {
          event: 'file-complete',
          transferId,
          sha256,
        } satisfies FileCompletePayload)
      )

      this._emitProgress({ transferId, fileName, bytesSent: totalBytes, totalBytes, done: true })
      console.log(`[FileTransferService] Sent "${fileName}" — SHA-256: ${sha256}`)
    })
  }

  // ── Windows → Android: send a clipboard image chunked ─────────────────────

  async sendClipboardImage(pngBuffer: Buffer, transferId?: string): Promise<string> {
    return this._enqueueSend(async () => {
      const id = transferId || randomUUID()
      const fileName = `clipboard_${Date.now()}.png`

      if (!SocketService.hasConnectedClients()) {
        console.warn('[FileTransferService] Cannot send clipboard image: no connected Android client')
        return id
      }

      const totalBytes = pngBuffer.length
      const totalChunks = Math.max(1, Math.ceil(totalBytes / CHUNK_SIZE))
      const mimeType = 'image/png'

      console.log(`[FileTransferService] Sending clipboard image (${totalBytes} bytes, ${totalChunks} chunks, id=${id})`)

      // 1. Emit file-meta tagged as clipboard-image
      SocketService.broadcast(
        this._envelope('file-meta', 'windows', {
          event: 'file-meta',
          transferId: id,
          fileName,
          mimeType,
          totalBytes,
          totalChunks,
          transferType: 'clipboard-image',
        } satisfies FileMetaPayload)
      )

      // Brief delay for Android receiver setup
      await new Promise((resolve) => setTimeout(resolve, 60))

      // 2. Stream chunks incrementally
      const hash = crypto.createHash('sha256')
      let offset = 0
      let index = 0

      while (offset < totalBytes) {
        const end = Math.min(offset + CHUNK_SIZE, totalBytes)
        const chunk = pngBuffer.subarray(offset, end)
        hash.update(chunk)
        const data = chunk.toString('base64')

        SocketService.broadcast(
          this._envelope('file-chunk', 'windows', {
            event: 'file-chunk',
            transferId: id,
            index,
            data,
          } satisfies FileChunkPayload)
        )

        offset = end
        index++
        await new Promise((resolve) => setTimeout(resolve, 5))
      }

      // 3. Emit file-complete
      const sha256 = hash.digest('hex')
      SocketService.broadcast(
        this._envelope('file-complete', 'windows', {
          event: 'file-complete',
          transferId: id,
          sha256,
        } satisfies FileCompletePayload)
      )

      console.log(`[FileTransferService] Clipboard image transfer complete: id=${id}, SHA-256=${sha256}`)
      return id
    })
  }

  // ── Android → Windows: receive a file / clipboard image ───────────────────

  private _handleIncoming(msg: BridgeMessage<FilePayload>): void {
    const payload = msg.payload
    if (!payload?.event) return

    switch (payload.event) {
      case 'file-meta':
        this._onMeta(payload)
        break
      case 'file-chunk':
        this._onChunk(payload)
        break
      case 'file-complete':
        this._onComplete(payload)
        break
    }
  }

  private _onMeta(p: FileMetaPayload): void {
    const isClipboardImage = p.transferType === 'clipboard-image'
    let destPath: string

    if (isClipboardImage) {
      const cacheDir = ClipboardHistoryService.getImagesDir()
      fs.mkdirSync(cacheDir, { recursive: true })
      destPath = path.join(cacheDir, `clip_${p.transferId}.png`)
      console.log(`[FileTransferService] Receiving clipboard image → ${destPath}`)
    } else {
      const destDir = path.join(os.homedir(), 'Downloads', 'Bridge')
      fs.mkdirSync(destDir, { recursive: true })

      // Avoid overwriting existing files
      destPath = path.join(destDir, p.fileName)
      let counter = 1
      while (fs.existsSync(destPath)) {
        const { name, ext } = path.parse(p.fileName)
        destPath = path.join(destDir, `${name} (${counter++})${ext}`)
      }
      console.log(`[FileTransferService] Receiving "${p.fileName}" → ${destPath}`)
    }

    const stream = fs.createWriteStream(destPath)
    const hash = crypto.createHash('sha256')
    this._receives.set(p.transferId, {
      fileName: p.fileName,
      destPath,
      stream,
      hash,
      chunksReceived: 0,
      totalChunks: p.totalChunks,
      isClipboardImage,
    })
  }

  private _onChunk(p: FileChunkPayload): void {
    const state = this._receives.get(p.transferId)
    if (!state) {
      console.warn(`[FileTransferService] Chunk for unknown transferId: ${p.transferId}`)
      return
    }
    const rawBuf = Buffer.from(p.data, 'base64')
    state.hash.update(rawBuf)
    state.stream.write(rawBuf)
    state.chunksReceived++
  }

  private _onComplete(p: FileCompletePayload): void {
    const state = this._receives.get(p.transferId)
    if (!state) {
      console.warn(`[FileTransferService] file-complete for unknown transferId: ${p.transferId}`)
      return
    }

    state.stream.end(() => {
      const computed = state.hash.digest('hex')
      this._receives.delete(p.transferId)

      if (computed !== p.sha256) {
        console.error(`[FileTransferService] Checksum mismatch for "${state.fileName}"! Deleting.`)
        fs.unlink(state.destPath, () => {})
        return
      }

      if (state.isClipboardImage) {
        console.log(`[FileTransferService] Received clipboard image ✓ SHA-256 verified (${state.destPath})`)
        try {
          const img = nativeImage.createFromPath(state.destPath)
          if (!img.isEmpty()) {
            for (const handler of this._clipboardImageHandlers) {
              handler({
                img,
                sha256: computed,
                path: state.destPath,
                transferId: p.transferId,
              })
            }
          }
        } catch (e) {
          console.error('[FileTransferService] Failed to process received clipboard image:', e)
        }
      } else {
        console.log(`[FileTransferService] Received "${state.fileName}" ✓ SHA-256 verified`)
        new Notification({
          title: 'Bridge — File Received',
          body: `"${state.fileName}" saved to Downloads\\Bridge\\`,
        }).show()
      }
    })
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  private _envelope<T>(
    _type: string,
    origin: 'android' | 'windows',
    payload: T
  ): BridgeMessage<T> {
    return {
      eventId: randomUUID(),
      type: 'file',
      origin,
      timestamp: new Date().toISOString(),
      payload,
    }
  }

  private _emitProgress(p: FileSendProgress): void {
    this._progressHandlers.forEach((h) => h(p))
  }

  private _guessMime(fileName: string): string {
    const ext = path.extname(fileName).toLowerCase()
    const map: Record<string, string> = {
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.png': 'image/png',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
      '.heic': 'image/heic',
      '.mp4': 'video/mp4',
      '.mov': 'video/quicktime',
      '.mkv': 'video/x-matroska',
      '.pdf': 'application/pdf',
      '.zip': 'application/zip',
      '.txt': 'text/plain',
      '.mp3': 'audio/mpeg',
      '.m4a': 'audio/m4a',
    }
    return map[ext] ?? 'application/octet-stream'
  }
}

export const FileTransferService = new FileTransferServiceClass()
