import { app, BrowserWindow, ipcMain } from 'electron'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { SocketService } from './SocketService.js'
import { VirtualCameraService } from './VirtualCameraService.js'
import type { BridgeMessage, CameraSignalPayload } from '../types/protocol.js'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

class CameraSignalServiceClass {
  private _camWin: BrowserWindow | null = null
  private _getMainWin: (() => BrowserWindow | null) | null = null
  private _rendererDist = ''
  private _devServerUrl = ''
  private _isAppQuitting = false
  private _isWorkerReady = false
  private _pendingSignals: CameraSignalPayload[] = []

  start(getMainWin: () => BrowserWindow | null, rendererDist: string, devServerUrl: string): void {
    this._getMainWin = getMainWin
    this._rendererDist = rendererDist
    this._devServerUrl = devServerUrl

    // Forward virtual camera setup progress to renderer windows
    VirtualCameraService.onProgress((progress) => {
      this._broadcastToRenderers('camera-setup-progress', progress)
    })

    app.on('before-quit', () => {
      this._isAppQuitting = true
      VirtualCameraService.stop()
      if (this._camWin && !this._camWin.isDestroyed()) {
        this._camWin.destroy()
        this._camWin = null
      }
    })

    // ── Receive camera-signal messages from Android ───────────────────────────
    SocketService.onMessage('camera-signal', async (msg: BridgeMessage) => {
      const payload = msg.payload as CameraSignalPayload
      console.log(`[CameraSignalService] Received signal from Android: ${payload.event}`)

      if (payload.event === 'stop-camera') {
        this._pendingSignals = []
        this._sendToCamera('camera-signal', payload)
        setTimeout(() => this._closeCamWorker(), 500)
        return
      }

      if (payload.event === 'offer' || payload.event === 'start-camera') {
        if (!this._camWin || this._camWin.isDestroyed()) {
          await this._openCamWorker(false)
        }
      }

      if (!this._isWorkerReady) {
        console.log(`[CameraSignalService] Buffering signal until camera worker is ready: ${payload.event}`)
        this._pendingSignals.push(payload)
      } else {
        this._sendToCamera('camera-signal', payload)
      }
    })

    // ── IPC: worker notifies it is fully initialized and ready for signals ────
    ipcMain.on('camera-worker-ready', () => {
      console.log(`[CameraSignalService] Camera worker is READY — flushing ${this._pendingSignals.length} buffered signal(s)`)
      this._isWorkerReady = true
      const queue = [...this._pendingSignals]
      this._pendingSignals = []
      for (const sig of queue) {
        console.log(`[CameraSignalService] Dispatching buffered signal to worker: ${sig.event}`)
        this._sendToCamera('camera-signal', sig)
      }
    })

    // ── IPC: renderer → Android (outbound signaling) ──────────────────────────
    ipcMain.on('camera-signal-send', (_event, payload: CameraSignalPayload) => {
      console.log(`[CameraSignalService] Sending signal to Android: ${payload.event}`)
      SocketService.broadcast({
        eventId: randomUUID(),
        type: 'camera-signal',
        origin: 'windows',
        timestamp: new Date().toISOString(),
        payload,
      })
    })

    // ── IPC: renderer notifies camera stream is live ─────────────────────────
    ipcMain.on('camera-live', () => {
      console.log('[CameraSignalService] Camera stream is live — feeding virtual camera shared memory')
      VirtualCameraService.ensureReady()
      this._broadcastToRenderers('camera-status-update', { active: true })
    })

    // ── IPC: receive RGBA frame data from camera renderer ────────────────────
    // NOTE: frames arrive via preload sendFrame() as transferred (zero-copy)
    // ArrayBuffers, or as cloned buffers via the send() fallback. Either way
    // the payload is forwarded WITHOUT copying — sendFrame() reads it through
    // a zero-copy view. Copying multi-MB buffers here at 30fps was part of the
    // old freeze/burst choppiness.
    let vcamFrameCount = 0
    let lastVcamLog = Date.now()
    ipcMain.on('vcam-frame', (_event, frameData: { width: number; height: number; data: ArrayBuffer | Uint8Array | Buffer }) => {
      vcamFrameCount++
      const now = Date.now()
      if (vcamFrameCount === 1 || now - lastVcamLog >= 3000) {
        const byteLen = (frameData.data as any)?.byteLength ?? (frameData.data as Buffer)?.length ?? 0
        const expected = frameData.width * frameData.height * 4
        const agree = byteLen === expected ? 'DIMS-OK' : `DIM-MISMATCH(expected ${expected})`
        console.log(`[CameraSignalService] Stage2 IPC: vcam-frame #${vcamFrameCount} received (${frameData.width}x${frameData.height}, ${byteLen} bytes, ${agree}, header stride=${frameData.width}px) → pushFrame (mailbox) for steady writer`)
        lastVcamLog = now
      }
      VirtualCameraService.pushFrame(frameData.data, frameData.width, frameData.height)
    })

    // ── IPC: renderer signals virtual camera should stop ─────────────────────
    ipcMain.on('vcam-stop', () => {
      console.log('[CameraSignalService] vcam-stop received — stopping virtual camera')
      VirtualCameraService.stop()
      this._broadcastToRenderers('camera-status-update', { active: false })
    })

    // ── IPC: renderer requests to open preview window ─────────────────────────
    ipcMain.handle('open-camera-window', async () => {
      return this._openCamWorker(true)
    })

    // ── IPC: renderer requests to close camera window ─────────────────────────
    ipcMain.handle('close-camera-window', async () => {
      this._closeCamWorker()
    })

    // ── IPC: check virtual camera registration status ─────────────────────────
    ipcMain.handle('get-camera-status', async () => {
      return {
        isVirtualCameraRegistered: VirtualCameraService.isRegistered(),
      }
    })

    // ── Poll: socket disconnect → tear down camera worker ─────────────────────
    setInterval(() => {
      if (this._camWin && !this._camWin.isDestroyed() && !SocketService.hasConnectedClients()) {
        console.log('[CameraSignalService] Socket disconnected — stopping camera worker')
        this._sendToCamera('camera-stream-ended', {})
        setTimeout(() => this._closeCamWorker(), 500)
      }
    }, 2000)

    console.log('[CameraSignalService] Started (headless background pipeline ready)')
  }

  private async _openCamWorker(showPreview = false): Promise<{ success: boolean; error?: string }> {
    if (this._camWin && !this._camWin.isDestroyed()) {
      if (showPreview) {
        this._camWin.setPosition(100, 100)
        this._camWin.setSkipTaskbar(false)
        this._camWin.setFocusable(true)
        this._camWin.show()
        this._camWin.focus()
      }
      return { success: true }
    }

    this._isWorkerReady = false

    this._camWin = new BrowserWindow({
      width: 1280,
      height: 720,
      // Completely off-screen when headless: Chromium GPU pipelines stay 100% active without popping up any window
      x: showPreview ? undefined : -10000,
      y: showPreview ? undefined : -10000,
      show: true,
      skipTaskbar: !showPreview,
      focusable: showPreview,
      title: 'Bridge Camera Worker',
      webPreferences: {
        backgroundThrottling: false, // Prevent Chromium from pausing WebRTC/timers
        preload: path.join(__dirname, 'preload.mjs'),
      },
    })

    this._camWin.on('close', (e) => {
      if (!this._isAppQuitting) {
        e.preventDefault()
        this._closeCamWorker()
      }
    })

    if (this._devServerUrl) {
      await this._camWin.loadURL(`${this._devServerUrl}camera.html`)
    } else {
      await this._camWin.loadFile(path.join(this._rendererDist, 'camera.html'))
    }

    console.log('[CameraSignalService] Camera worker initialized (headless: ' + !showPreview + ')')

    // Ensure virtual camera shared memory is ready to receive frames
    VirtualCameraService.ensureReady()

    return { success: true }
  }

  private _closeCamWorker(): void {
    if (this._camWin && !this._camWin.isDestroyed()) {
      console.log('[CameraSignalService] Stopping camera worker')
      this._sendToCamera('camera-stream-ended', {})
      this._camWin.destroy()
      this._camWin = null
      this._isWorkerReady = false
      this._pendingSignals = []

      if (SocketService.hasConnectedClients()) {
        SocketService.broadcast({
          eventId: randomUUID(),
          type: 'camera-signal',
          origin: 'windows',
          timestamp: new Date().toISOString(),
          payload: { event: 'stop-camera' } satisfies CameraSignalPayload,
        })
      }

      VirtualCameraService.stop()
      this._broadcastToRenderers('camera-status-update', { active: false })
    }
  }

  private _sendToCamera(channel: string, payload: unknown): void {
    if (this._camWin && !this._camWin.isDestroyed()) {
      this._camWin.webContents.send(channel, payload)
    }
  }

  private _broadcastToRenderers(channel: string, payload: unknown): void {
    const mainWin = this._getMainWin?.()
    if (mainWin && !mainWin.isDestroyed()) {
      mainWin.webContents.send(channel, payload)
    }
    if (this._camWin && !this._camWin.isDestroyed()) {
      this._camWin.webContents.send(channel, payload)
    }
  }
}

export const CameraSignalService = new CameraSignalServiceClass()
