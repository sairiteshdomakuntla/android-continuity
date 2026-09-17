import { app, Tray, Menu, nativeImage, BrowserWindow } from 'electron'
import path from 'node:path'
import { SocketService } from './SocketService.js'
import { DeviceStorageService } from './DeviceStorageService.js'
import { DeviceService } from './DeviceService.js'
import { AppSettingsService } from './AppSettingsService.js'

/**
 * TrayService — system tray icon, context menu, and close-to-tray lifecycle.
 *
 * UI/lifecycle only: it READS connection state (paired devices + socket
 * clients) and CALLS existing features (show window, ring phone, quit).
 * It never touches socket, encryption, or transport logic.
 *
 * Behavior:
 *  - Main-window close (X or title-bar button) hides to tray instead of
 *    quitting, so file/notification services keep running.
 *  - Left-click restores the window; right-click shows a live menu:
 *    Open Bridge / status line (informational) / Ring Phone (when
 *    connected) / Launch at startup (checkbox) / Quit Bridge.
 *  - Tray icon + tooltip reflect connection state (clay+sage when
 *    connected, muted when not — same logic as the main window dots).
 *  - Quit Bridge goes through `app.quit()`, so every existing
 *    `before-quit` handler (camera worker teardown, virtual-camera stop)
 *    runs exactly as it does today.
 */
class TrayServiceClass {
  private _tray: Tray | null = null
  private _getMainWin: (() => BrowserWindow | null) | null = null
  private _iconDir = ''
  private _isQuitting = false
  private _lastStateKey = ''
  private _hideBalloonShown = false
  private _pollTimer: ReturnType<typeof setInterval> | null = null

  /** True once Quit Bridge was chosen — main-window close may proceed. */
  get isQuitting(): boolean {
    return this._isQuitting
  }

  get isRunning(): boolean {
    return this._tray !== null && !this._tray.isDestroyed()
  }

  start(getMainWin: () => BrowserWindow | null, iconDir: string): void {
    this._getMainWin = getMainWin
    this._iconDir = iconDir

    try {
      this._tray = new Tray(this._iconPath(false))
    } catch (err) {
      console.error('[TrayService] Failed to create tray icon:', err)
      return
    }

    this._tray.setToolTip('Bridge — Not paired')
    this._tray.on('click', () => this.showMainWindow())
    this._tray.on('right-click', () => {
      this._refreshState(true)
      this._tray?.popUpContextMenu(this._buildMenu())
    })

    // Close-to-tray is wired in createWindow() via attachWindow(), so every
    // window (initial or re-created) behaves the same.
    this._refreshState(true)
    this._pollTimer = setInterval(() => this._refreshState(false), 2000)

    app.on('before-quit', () => {
      if (this._pollTimer) {
        clearInterval(this._pollTimer)
        this._pollTimer = null
      }
    })

    console.log('[TrayService] Started (close-to-tray active)')
  }

  /** Wire close-to-tray onto a window (called for the initial window and any re-created one). */
  attachWindow(win: BrowserWindow | null): void {
    if (!win || win.isDestroyed()) return
    win.on('close', (e) => {
      if (!this._isQuitting) {
        e.preventDefault()
        win.hide()
        this._onHiddenToTray()
      }
    })
  }

  /** Show and focus the main window (restore from tray). */
  showMainWindow(): void {
    const win = this._getMainWin?.()
    if (!win || win.isDestroyed()) return
    if (win.isMinimized()) win.restore()
    win.show()
    win.focus()
  }

  /** Graceful full exit: lets every existing before-quit handler run. */
  requestQuit(): void {
    if (this._isQuitting) return
    console.log('[TrayService] Quit Bridge requested from tray — shutting down gracefully')
    this._isQuitting = true
    app.quit()
  }

  /** Rebuild the context menu now (e.g. after the auto-launch toggle). */
  refreshMenu(): void {
    this._refreshState(true)
  }

  // ── internals ─────────────────────────────────────────────────────────────

  private _iconPath(connected: boolean): string {
    return path.join(this._iconDir, connected ? 'tray-connected.png' : 'tray-disconnected.png')
  }

  private _connectionState(): { paired: boolean; connected: boolean; deviceName: string | null } {
    const primary = DeviceStorageService.getPrimaryDevice()
    const paired = primary !== null
    const connected = paired && SocketService.hasConnectedClients()
    return { paired, connected, deviceName: primary?.name ?? primary?.deviceId ?? null }
  }

  private _statusLine(): string {
    const { paired, connected, deviceName } = this._connectionState()
    if (connected) return `Connected to ${deviceName ?? 'Android Device'}`
    if (paired) return `Paired — waiting for ${deviceName ?? 'phone'}`
    return 'Not paired'
  }

  private _stateKey(): string {
    const { paired, connected, deviceName } = this._connectionState()
    return `${paired}|${connected}|${deviceName ?? ''}`
  }

  /** Update icon + tooltip when state changes; rebuild menu on demand. */
  private _refreshState(rebuildMenu: boolean): void {
    if (!this._tray || this._tray.isDestroyed()) return
    const key = this._stateKey()
    if (rebuildMenu || key !== this._lastStateKey) {
      this._lastStateKey = key
      const { connected, deviceName } = this._connectionState()
      try {
        this._tray.setImage(nativeImage.createFromPath(this._iconPath(connected)))
      } catch (err) {
        console.warn('[TrayService] Failed to update tray icon:', err)
      }
      this._tray.setToolTip(
        connected
          ? `Bridge — Connected to ${deviceName ?? 'Android Device'}`
          : 'Bridge — Not connected',
      )
    }
  }

  private _buildMenu(): Menu {
    const { connected } = this._connectionState()
    const autoLaunchEnabled = readAutoLaunchOsState()
    return Menu.buildFromTemplate([
      {
        label: 'Open Bridge',
        click: () => this.showMainWindow(),
      },
      {
        label: this._statusLine(),
        enabled: false,
      },
      { type: 'separator' },
      {
        label: 'Ring Phone',
        enabled: connected,
        click: () => {
          // Same guard as the renderer's ring-phone handler.
          if (SocketService.hasConnectedClients()) {
            DeviceService.ringPhone()
          }
        },
      },
      {
        label: 'Launch at startup',
        type: 'checkbox',
        checked: autoLaunchEnabled,
        click: (item) => {
          applyAutoLaunchChoice(item.checked)
          this._broadcastSettings()
        },
      },
      { type: 'separator' },
      {
        label: 'Quit Bridge',
        click: () => this.requestQuit(),
      },
    ])
  }

  /** Push the live auto-launch state to the open settings UI, if any. */
  private _broadcastSettings(): void {
    try {
      this._getMainWin?.()?.webContents.send('app-settings-changed', {
        autoLaunch: readAutoLaunchOsState(),
      })
    } catch {
      // Window may be closed — the toggle re-reads on next open.
    }
  }

  private _onHiddenToTray(): void {
    if (this._hideBalloonShown) return
    this._hideBalloonShown = true
    try {
      this._tray?.displayBalloon({
        title: 'Bridge is still running',
        content: 'Bridge keeps syncing from the system tray. Right-click the tray icon to open or quit.',
      })
    } catch {
      // Balloons are best-effort (not supported on all platforms).
    }
  }
}

export const TrayService = new TrayServiceClass()

// ── Auto-launch helpers (OS registration; choice persisted via AppSettingsService) ──

const LOGIN_ARGS = ['--hidden']

/** Live OS-registered state (source of truth for menus/toggles). */
export function readAutoLaunchOsState(): boolean {
  try {
    return app.getLoginItemSettings({ args: LOGIN_ARGS }).openAtLogin
  } catch {
    return AppSettingsService.getAutoLaunch() ?? false
  }
}

/**
 * Persist the user's choice AND apply it to the OS. Called from the tray
 * menu checkbox and the renderer's settings toggle (via IPC) alike.
 */
export function applyAutoLaunchChoice(enabled: boolean): void {
  try {
    app.setLoginItemSettings({
      openAtLogin: enabled,
      args: enabled ? LOGIN_ARGS : [],
    })
    console.log(`[TrayService] Auto-launch ${enabled ? 'enabled' : 'disabled'}`)
  } catch (err) {
    console.error('[TrayService] Failed to apply auto-launch setting:', err)
  }
  AppSettingsService.setAutoLaunch(enabled)
}
