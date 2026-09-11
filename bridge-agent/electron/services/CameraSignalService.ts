import { app, BrowserWindow, ipcMain } from 'electron'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { SocketService } from './SocketService.js'
import { ObsManagerService, CameraSetupProgress } from './ObsManagerService.js'
import type { BridgeMessage, CameraSignalPayload } from '../types/protocol.js'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// The camera window is roughly 16:9, always-on-top, frameless.
const CAM_W = 480
const CAM_H = 320 // ≈ 480 × (9/16) + top-bar space

class CameraSignalServiceClass {
  private _camWin: BrowserWindow | null = null
  private _getMainWin: (() => BrowserWindow | null) | null = null
  private _rendererDist = ''
  private _devServerUrl = ''
  private _isAppQuitting = false

  start(getMainWin: () => BrowserWindow | null, rendererDist: string, devServerUrl: string): void {
    this._getMainWin = getMainWin
    this._rendererDist = rendererDist
    this._devServerUrl = devServerUrl

    // Forward OBS setup progress to renderer windows
    ObsManagerService.onProgress((progress: CameraSetupProgress) => {
      this._broadcastToRenderers('camera-setup-progress', progress)
    })

    app.on('before-quit', () => {
      this._isAppQuitting = true
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
        this._sendToCamera('camera-signal', payload)
        // Give renderer a moment to clean up, then hide window
        setTimeout(() => this._closeCamWindow(), 800)
        return
      }

      if (payload.event === 'offer' || payload.event === 'start-camera') {
        if (!this._camWin || this._camWin.isDestroyed() || !this._camWin.isVisible()) {
          await this._openCamWindow()
        }
      }

      // offer / answer / ice-candidate — relay to camera window renderer
      this._sendToCamera('camera-signal', payload)
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

    // ── IPC: renderer notifies camera stream is live with video frames ───────
    ipcMain.on('camera-live', () => {
      console.log('[CameraSignalService] Camera is live, refreshing OBS capture')
      ObsManagerService.refreshCapture().catch(() => {})
    })

    // ── IPC: renderer requests to open camera window ──────────────────────────
    ipcMain.handle('open-camera-window', async () => {
      return this._openCamWindow()
    })

    // ── IPC: renderer requests to close camera window ─────────────────────────
    ipcMain.handle('close-camera-window', async () => {
      this._closeCamWindow()
    })

    // ── IPC: check if OBS is installed ─────────────────────────────────────────
    ipcMain.handle('get-camera-status', async () => {
      return {
        isObsInstalled: ObsManagerService.isInstalled(),
      }
    })

    // ── Poll: socket disconnect → tear down camera window ────────────────────
    setInterval(() => {
      if (this._camWin && this._camWin.isVisible() && !SocketService.hasConnectedClients()) {
        console.log('[CameraSignalService] Socket disconnected — hiding camera window')
        this._sendToCamera('camera-stream-ended', {})
        setTimeout(() => this._closeCamWindow(), 500)
      }
    }, 2000)

    console.log('[CameraSignalService] Started')
  }

  private async _openCamWindow(): Promise<{ success: boolean; error?: string }> {
    if (this._camWin && !this._camWin.isDestroyed()) {
      console.log('[CameraSignalService] Reusing existing camera window (preserving HWND for OBS)')
      this._camWin.show()
      this._camWin.focus()
    } else {
      this._camWin = new BrowserWindow({
        width: CAM_W,
        height: CAM_H,
        minWidth: 320,
        minHeight: 220,
        title: 'Bridge — Phone Camera',
        frame: false, // no native chrome — custom draggable top bar
        alwaysOnTop: true,
        resizable: true,
        transparent: false,
        backgroundColor: '#0a0a0f',
        webPreferences: {
          preload: path.join(__dirname, 'preload.mjs'),
        },
      })

      // Intercept window close: hide instead of destroying to preserve window handle for OBS
      this._camWin.on('close', (e) => {
        if (!this._isAppQuitting) {
          e.preventDefault()
          this._closeCamWindow()
        }
      })

      if (this._devServerUrl) {
        await this._camWin.loadURL(`${this._devServerUrl}camera.html`)
      } else {
        await this._camWin.loadFile(path.join(this._rendererDist, 'camera.html'))
      }

      console.log('[CameraSignalService] Camera window created and displayed')
    }

    // Start the automated OBS setup & Virtual Camera in background
    ObsManagerService.setupAndStartVirtualCamera().then((result) => {
      if (!result.success) {
        console.warn('[CameraSignalService] OBS Virtual Camera setup warning:', result.error)
      }
    }).catch((err) => {
      console.warn('[CameraSignalService] OBS Virtual Camera setup error:', err)
    })

    return { success: true }
  }

  private _closeCamWindow(): void {
    if (this._camWin && !this._camWin.isDestroyed() && this._camWin.isVisible()) {
      console.log('[CameraSignalService] Hiding camera window (preserving HWND for OBS Window Capture)')
      this._sendToCamera('camera-stream-ended', {})
      this._camWin.hide()

      if (SocketService.hasConnectedClients()) {
        SocketService.broadcast({
          eventId: randomUUID(),
          type: 'camera-signal',
          origin: 'windows',
          timestamp: new Date().toISOString(),
          payload: { event: 'stop-camera' } satisfies CameraSignalPayload,
        })
      }

      ObsManagerService.stopVirtualCam().catch(() => {})
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

