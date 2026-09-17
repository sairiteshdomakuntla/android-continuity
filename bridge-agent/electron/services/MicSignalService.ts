import { app, BrowserWindow, ipcMain } from 'electron'
import { randomUUID } from 'node:crypto'
import { SocketService } from './SocketService.js'
import type { MicSignalPayload } from '../types/protocol.js'

/**
 * MicSignalService — "Phone as Microphone" signaling relay (Stage 1).
 *
 * Mirrors CameraSignalService cleanup patterns exactly:
 *  - Android `stop-mic` → forward to renderer, which tears down its PC.
 *  - Renderer stop → broadcast `stop-mic` to Android.
 *  - Socket disconnect (poll) → send `mic-stream-ended` to renderer so
 *    audio stops within a few seconds (same path camera uses).
 *  - App quit → broadcast `stop-mic` if clients remain.
 *
 * Unlike camera, there is no hidden worker window: the main renderer owns
 * the answerer RTCPeerConnection and plays audio via <audio autoplay>.
 */
class MicSignalServiceClass {
  private _getMainWin: (() => BrowserWindow | null) | null = null
  private _micActive = false

  start(getMainWin: () => BrowserWindow | null): void {
    this._getMainWin = getMainWin

    app.on('before-quit', () => {
      if (this._micActive && SocketService.hasConnectedClients()) {
        try {
          SocketService.broadcast({
            eventId: randomUUID(),
            type: 'mic-signal',
            origin: 'windows',
            timestamp: new Date().toISOString(),
            payload: { event: 'stop-mic' } satisfies MicSignalPayload,
          })
        } catch { /* shutting down */ }
      }
      this._micActive = false
    })

    // ── Receive mic-signal messages from Android ────────────────────────────
    SocketService.onMessage('mic-signal', async (msg) => {
      const payload = msg.payload as MicSignalPayload
      console.log(`[MicSignalService] Received signal from Android: ${payload.event}`)
      this._sendToMain('mic-signal', payload)
    })

    // ── IPC: renderer → Android (outbound signaling) ────────────────────────
    ipcMain.on('mic-signal-send', (_event, payload: MicSignalPayload) => {
      console.log(`[MicSignalService] Sending signal to Android: ${payload.event}`)
      if (payload.event === 'start-mic') this._micActive = true
      if (payload.event === 'stop-mic') this._micActive = false
      SocketService.broadcast({
        eventId: randomUUID(),
        type: 'mic-signal',
        origin: 'windows',
        timestamp: new Date().toISOString(),
        payload,
      })
    })

    // ── IPC: renderer notifies mic stream state ─────────────────────────────
    ipcMain.on('mic-live', () => {
      console.log('[MicSignalService] Mic stream is live')
      this._micActive = true
      this._broadcastToRenderers('mic-status-update', { active: true })
    })

    ipcMain.on('mic-stopped', () => {
      console.log('[MicSignalService] Mic stream stopped')
      this._micActive = false
      this._broadcastToRenderers('mic-status-update', { active: false })
    })

    // ── Poll: socket disconnect → tear down mic playback ────────────────────
    setInterval(() => {
      if (this._micActive && !SocketService.hasConnectedClients()) {
        console.log('[MicSignalService] Socket disconnected — stopping mic playback')
        this._micActive = false
        this._sendToMain('mic-stream-ended', {})
        this._broadcastToRenderers('mic-status-update', { active: false })
      }
    }, 2000)

    console.log('[MicSignalService] Started (main-window audio playback)')
  }

  private _sendToMain(channel: string, payload: unknown): void {
    const mainWin = this._getMainWin?.()
    if (mainWin && !mainWin.isDestroyed()) {
      mainWin.webContents.send(channel, payload)
    }
  }

  private _broadcastToRenderers(channel: string, payload: unknown): void {
    this._sendToMain(channel, payload)
  }
}

export const MicSignalService = new MicSignalServiceClass()
