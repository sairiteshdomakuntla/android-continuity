import { app, BrowserWindow, dialog, ipcMain } from 'electron'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { SocketService } from './services/SocketService.js'
import { ClipboardService } from './services/ClipboardService.js'
import { DeviceStorageService, PairedDevice } from './services/DeviceStorageService.js'
import { PairingService, LanInterfaceCandidate } from './services/PairingService.js'
import { FileTransferService } from './services/FileTransferService.js'
import { CameraSignalService } from './services/CameraSignalService.js'
import { ObsManagerService } from './services/ObsManagerService.js'
import { ClipboardHistoryService } from './services/ClipboardHistoryService.js'
import { NotificationHistoryService } from './services/NotificationHistoryService.js'
import { NotificationService } from './services/NotificationService.js'
import { DeviceService } from './services/DeviceService.js'

export { ObsManagerService, CameraSignalService }


const __dirname = path.dirname(fileURLToPath(import.meta.url))

app.name = 'Bridge Agent'
try {
  app.setPath('userData', path.join(app.getPath('appData'), 'Bridge Agent'))
} catch { }

process.env.APP_ROOT = path.join(__dirname, '..')

export const VITE_DEV_SERVER_URL = process.env['VITE_DEV_SERVER_URL']
export const MAIN_DIST = path.join(process.env.APP_ROOT, 'dist-electron')
export const RENDERER_DIST = path.join(process.env.APP_ROOT, 'dist')

process.env.VITE_PUBLIC = VITE_DEV_SERVER_URL ? path.join(process.env.APP_ROOT, 'public') : RENDERER_DIST


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

function createWindow() {
  win = new BrowserWindow({
    width: 480,
    height: 750,
    minWidth: 420,
    minHeight: 650,
    title: 'Bridge Agent',
    frame: false, // custom title bar with Bridge gradient accent (see renderer .top-bar)
    icon: path.join(process.env.VITE_PUBLIC, 'electron-vite.svg'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.mjs'),
    },
  })

  win.webContents.on('did-finish-load', () => {
    win?.webContents.send('main-process-message', (new Date).toLocaleString())
  })

  if (VITE_DEV_SERVER_URL) {
    win.loadURL(VITE_DEV_SERVER_URL)
  } else {
    win.loadFile(path.join(RENDERER_DIST, 'index.html'))
  }
}

app.on('window-all-closed', () => {
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

  // 6. Start Camera Signal Service
  CameraSignalService.start(
    () => win,
    RENDERER_DIST,
    VITE_DEV_SERVER_URL ?? '',
  )

  // 7. Open window
  createWindow()
})

// ── File transfer IPC ─────────────────────────────────────────────────────────

ipcMain.handle('send-file', async () => {
  if (!win) return { canceled: true }
  if (!SocketService.hasConnectedClients()) {
    dialog.showErrorBox(
      'Device Not Connected',
      'No active Android phone connection found. Please open Bridge on your phone to connect, then try sending again.'
    )
    return { canceled: false, error: 'No active connection' }
  }
  const result = await dialog.showOpenDialog(win, {
    title: 'Send file to Android',
    properties: ['openFile', 'multiSelections'],
  })
  if (result.canceled || result.filePaths.length === 0) return { canceled: true }
  try {
    // Send sequentially
    for (const filePath of result.filePaths) {
      await FileTransferService.sendFile(filePath)
    }
    return { canceled: false, files: result.filePaths }
  } catch (err: any) {
    dialog.showErrorBox('Transfer Failed', err?.message ?? String(err))
    return { canceled: false, error: err?.message ?? String(err) }
  }
})
