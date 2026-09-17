import { app, BrowserWindow, dialog, ipcMain } from 'electron'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { SocketService } from './services/SocketService.js'
import { ClipboardService } from './services/ClipboardService.js'
import { DeviceStorageService, PairedDevice } from './services/DeviceStorageService.js'
import { PairingService, LanInterfaceCandidate } from './services/PairingService.js'
import { FileTransferService } from './services/FileTransferService.js'
import { CameraSignalService } from './services/CameraSignalService.js'
// MIC PARKED — Phone as Microphone, revisit later:
// import { MicSignalService } from './services/MicSignalService.js'
import { VirtualCameraService } from './services/VirtualCameraService.js'
import { ClipboardHistoryService } from './services/ClipboardHistoryService.js'
import { NotificationHistoryService } from './services/NotificationHistoryService.js'
import { NotificationService } from './services/NotificationService.js'
import { DeviceService } from './services/DeviceService.js'
import { RemoteInputService } from './services/RemoteInputService.js'
import { DiscoveryService } from './services/DiscoveryService.js'
import { TrayService, applyAutoLaunchChoice, readAutoLaunchOsState } from './services/TrayService.js'
import { AppSettingsService } from './services/AppSettingsService.js'

export { CameraSignalService }


const __dirname = path.dirname(fileURLToPath(import.meta.url))

app.name = 'Bridge Agent'
app.commandLine.appendSwitch('disable-renderer-backgrounding')
app.commandLine.appendSwitch('disable-background-timer-throttling')
app.commandLine.appendSwitch('disable-backgrounding-occluded-windows')
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required')
try {
  app.setPath('userData', path.join(app.getPath('appData'), 'Bridge Agent'))
} catch { }

process.env.APP_ROOT = path.join(__dirname, '..')

export const VITE_DEV_SERVER_URL = process.env['VITE_DEV_SERVER_URL']
export const MAIN_DIST = path.join(process.env.APP_ROOT, 'dist-electron')
export const RENDERER_DIST = path.join(process.env.APP_ROOT, 'dist')

process.env.VITE_PUBLIC = VITE_DEV_SERVER_URL ? path.join(process.env.APP_ROOT, 'public') : RENDERER_DIST

// ── Single instance: a second launch (or a login launch while Bridge runs)
// just restores the existing window instead of starting a rival socket server.
const gotSingleInstanceLock = app.requestSingleInstanceLock()
if (!gotSingleInstanceLock) {
  console.log('[Main] Another Bridge instance is already running — quitting this one.')
  app.quit()
} else {
  app.on('second-instance', () => {
    TrayService.showMainWindow()
  })
}


let win: BrowserWindow | null = null
let currentQrDataUrl: string | null = null
let currentPairingIp: string = '127.0.0.1'
let currentPairingPort: number = 4000
let currentSelectedCandidate: LanInterfaceCandidate | null = null
let currentCandidates: LanInterfaceCandidate[] = []

async function generateNewPairing(forcedIp?: string): Promise<{
  ip: string
  port: number
  qrDataUrl: string
  selected: LanInterfaceCandidate | null
  candidates: LanInterfaceCandidate[]
}> {
  const result = await PairingService.generatePairingData(forcedIp)
  currentQrDataUrl = result.dataUrl
  currentPairingIp = result.payload.ip
  currentPairingPort = result.payload.port
  currentSelectedCandidate = result.selected
  currentCandidates = result.candidates

  return {
    ip: result.payload.ip,
    port: result.payload.port,
    qrDataUrl: result.dataUrl,
    selected: result.selected,
    candidates: result.candidates,
  }
}

function createWindow(startHidden = false) {
  win = new BrowserWindow({
    width: 480,
    height: 750,
    minWidth: 420,
    minHeight: 650,
    title: 'Bridge Agent',
    frame: false, // custom title bar with Bridge gradient accent (see renderer .top-bar)
    icon: path.join(process.env.VITE_PUBLIC, 'tray', 'tray-connected.png'),
    show: !startHidden, // login launches start minimized to tray
    webPreferences: {
      preload: path.join(__dirname, 'preload.mjs'),
    },
  })

  win.webContents.on('did-finish-load', () => {
    win?.webContents.send('main-process-message', (new Date).toLocaleString())
  })

  // Closing the window hides to tray (see TrayService) — unless quitting.
  if (win) TrayService.attachWindow(win)

  if (VITE_DEV_SERVER_URL) {
    win.loadURL(VITE_DEV_SERVER_URL)
  } else {
    win.loadFile(path.join(RENDERER_DIST, 'index.html'))
  }
}

app.on('window-all-closed', () => {
  // With a live tray icon the app intentionally survives zero windows
  // (e.g. camera worker closed while the main window hides in the tray).
  if (TrayService.isRunning && !TrayService.isQuitting) return
  DiscoveryService.stop()
  if (process.platform !== 'darwin') {
    app.quit()
    win = null
  }
})

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow()
  }
})

// IPC Handlers for Renderer
// ── Custom title-bar window controls (frameless main window) ────────────────
ipcMain.handle('window-minimize', (event) => {
  BrowserWindow.fromWebContents(event.sender)?.minimize()
})

ipcMain.handle('window-close', (event) => {
  BrowserWindow.fromWebContents(event.sender)?.close()
})

ipcMain.handle('get-status', async () => {
  const devices = DeviceStorageService.loadDevices()
  const isPairing = PairingService.isPairingActive()
  return {
    devices,
    isPairingActive: isPairing,
    currentPairing: isPairing && currentQrDataUrl ? {
      ip: currentPairingIp,
      port: currentPairingPort,
      qrDataUrl: currentQrDataUrl,
      selected: currentSelectedCandidate,
      candidates: currentCandidates,
    } : null,
  }
})

ipcMain.handle('start-pairing', async (_event, forcedIp?: string) => {
  const pairingInfo = await generateNewPairing(forcedIp)
  win?.webContents.send('pairing-state-changed', {
    isPairingActive: true,
    currentPairing: pairingInfo,
    devices: DeviceStorageService.loadDevices(),
  })
  return pairingInfo
})

ipcMain.handle('select-ip', async (_event, ip: string) => {
  console.log(`[Main] User manually selected IP: ${ip}`)
  const pairingInfo = await generateNewPairing(ip)
  win?.webContents.send('pairing-state-changed', {
    isPairingActive: true,
    currentPairing: pairingInfo,
    devices: DeviceStorageService.loadDevices(),
  })
  return pairingInfo
})

ipcMain.handle('unpair-all', async () => {
  DeviceStorageService.clearAll()
  SocketService.setEncryptionKey(null)
  DeviceService.clearBattery()
  const pairingInfo = await generateNewPairing()
  win?.webContents.send('pairing-state-changed', {
    isPairingActive: true,
    currentPairing: pairingInfo,
    devices: [],
  })
  return pairingInfo
})

ipcMain.handle('get-clipboard-history', async () => {
  return ClipboardHistoryService.getItems()
})

ipcMain.handle('copy-history-item', async (_event, text: string) => {
  ClipboardService.copyLocally(text)
  return { success: true }
})

ipcMain.handle('clear-clipboard-history', async () => {
  ClipboardHistoryService.clear()
  return { success: true }
})

// ── Notification IPC ─────────────────────────────────────────────────────────

ipcMain.handle('get-notifications', async () => {
  return NotificationHistoryService.getItems()
})

ipcMain.handle('send-notification-reply', async (_event, notificationId: string, replyText: string) => {
  NotificationService.sendReply(notificationId, replyText)
  return { success: true }
})

ipcMain.handle('dismiss-notification', async (_event, notificationId: string) => {
  NotificationService.dismissNotification(notificationId)
  return { success: true }
})

ipcMain.handle('clear-notifications', async () => {
  NotificationHistoryService.clear()
  return { success: true }
})

// ── Device status (battery) & find-my-phone IPC ────────────────────────────

ipcMain.handle('get-battery-status', async () => {
  return DeviceService.getBattery()
})

ipcMain.handle('ring-phone', async () => {
  if (!SocketService.hasConnectedClients()) {
    return { success: false, error: 'No active connection' }
  }
  DeviceService.ringPhone()
  return { success: true }
})

// ── Remote input ("Phone as Remote") IPC ────────────────────────────────────

ipcMain.handle('remote-open', async () => {
  if (!SocketService.hasConnectedClients()) {
    return { success: false, error: 'No active connection' }
  }
  RemoteInputService.openRemote()
  return { success: true }
})

// ── App settings (auto-launch) IPC ───────────────────────────────────────────

ipcMain.handle('get-app-settings', () => {
  return {
    autoLaunch: readAutoLaunchOsState(),
    autoLaunchConfigured: AppSettingsService.getAutoLaunch() !== null,
  }
})

ipcMain.handle('set-auto-launch', (_event, enabled: boolean) => {
  applyAutoLaunchChoice(!!enabled)
  TrayService.refreshMenu()
  return { autoLaunch: readAutoLaunchOsState() }
})

// ── App quit IPC (in-window Quit button → same graceful path as tray) ────────

ipcMain.handle('quit-app', () => {
  TrayService.requestQuit()
  return { success: true }
})

app.whenReady().then(async () => {
  // Initialize Clipboard History
  ClipboardHistoryService.init()
  ClipboardHistoryService.onUpdate((items) => {
    win?.webContents.send('clipboard-history-updated', items)
  })

  // Initialize Notification Service
  NotificationHistoryService.onUpdate((items) => {
    win?.webContents.send('notifications-updated', items)
  })
  NotificationService.start()

  // Initialize Device Service (battery status + find-my-phone)
  DeviceService.onBatteryUpdate((status) => {
    win?.webContents.send('battery-updated', status)
  })
  DeviceService.start()

  // Initialize Remote Input Service (phone as trackpad)
  RemoteInputService.start()

  // 1. Start Socket.IO server
  const io = SocketService.start()

  // 2. Load existing paired devices
  const devices = DeviceStorageService.loadDevices()
  if (devices.length > 0) {
    const primary = devices[0]
    console.log(`[Main] Loaded paired device: ${primary.name ?? primary.deviceId}`)
    const key = Buffer.from(primary.pairingKey, 'base64')
    SocketService.setEncryptionKey(key)
  } else {
    console.log('[Main] No paired devices found. Generating initial pairing QR code.')
    await generateNewPairing()
  }

  // 3. Setup pairing listener
  PairingService.setupPairingListener(io, (device: PairedDevice) => {
    console.log(`[Main] New device paired successfully: ${device.name ?? device.deviceId}`)
    currentQrDataUrl = null
    win?.webContents.send('device-paired', {
      device,
      devices: DeviceStorageService.loadDevices(),
    })
  })

  // 4. Start Clipboard Service
  ClipboardService.start()

  // 5. Start File Transfer Service
  FileTransferService.start()
  FileTransferService.onSendProgress((progress) => {
    win?.webContents.send('file-progress', progress)
  })

  // 6. Register Virtual Camera DLLs (first-run only — idempotent)
  VirtualCameraService.ensureRegistered().catch((err) => {
    console.warn('[Main] Virtual camera registration warning:', err)
  })

  // 7. Start Camera Signal Service
  CameraSignalService.start(
    () => win,
    RENDERER_DIST,
    VITE_DEV_SERVER_URL ?? '',
  )

  // MIC PARKED — Phone as Microphone (Stage 1), revisit later:
  // MicSignalService.start(() => win)

  // 8. Start UDP LAN Discovery Service
  DiscoveryService.start()

  // 9. Auto-launch: default ON for first-time setup, then respect the
  // saved choice on every boot (the toggle + tray checkbox own it).
  if (AppSettingsService.getAutoLaunch() === null) {
    console.log('[Main] First run — enabling auto-launch by default')
    applyAutoLaunchChoice(true)
  }

  // 10. Open window (minimized to tray on login launches via --hidden)
  const startHidden = process.argv.includes('--hidden')
  createWindow(startHidden)

  // 11. System tray: close-to-tray, status icon, quick actions
  TrayService.start(
    () => win,
    path.join(process.env.VITE_PUBLIC, 'tray'),
  )
})

// ── File transfer IPC ─────────────────────────────────────────────────────────

ipcMain.handle('send-file', async (_event, directFilePaths?: string[]) => {
  if (!win) return { canceled: true }
  if (!SocketService.hasConnectedClients()) {
    dialog.showErrorBox(
      'Device Not Connected',
      'No active Android phone connection found. Please open Bridge on your phone to connect, then try sending again.'
    )
    return { canceled: false, error: 'No active connection' }
  }

  let filePaths = directFilePaths
  if (!filePaths || filePaths.length === 0) {
    const result = await dialog.showOpenDialog(win, {
      title: 'Send file to Android',
      properties: ['openFile', 'multiSelections'],
    })
    if (result.canceled || result.filePaths.length === 0) return { canceled: true }
    filePaths = result.filePaths
  }

  try {
    // Send sequentially
    for (const filePath of filePaths) {
      await FileTransferService.sendFile(filePath)
    }
    return { canceled: false, files: filePaths }
  } catch (err: any) {
    dialog.showErrorBox('Transfer Failed', err?.message ?? String(err))
    return { canceled: false, error: err?.message ?? String(err) }
  }
})
