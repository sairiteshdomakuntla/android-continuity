import { app, safeStorage } from 'electron'
import fs from 'node:fs'
import path from 'node:path'

export interface PairedDevice {
  deviceId: string
  pairingKey: string // 256-bit base64
  name?: string
  pairedAt: string
}

export class DeviceStorageService {
  private static getFilePath(): string {
    return path.join(app.getPath('userData'), 'paired_devices.enc')
  }

  static loadDevices(): PairedDevice[] {
    const filePath = this.getFilePath()
    if (!fs.existsSync(filePath)) {
      return []
    }

    try {
      const encryptedBuffer = fs.readFileSync(filePath)
      let jsonStr = ''

      if (safeStorage.isEncryptionAvailable()) {
        jsonStr = safeStorage.decryptString(encryptedBuffer)
      } else {
        console.warn('[DeviceStorageService] safeStorage encryption unavailable, reading raw buffer')
        jsonStr = encryptedBuffer.toString('utf8')
      }

      const devices = JSON.parse(jsonStr) as PairedDevice[]
      return Array.isArray(devices) ? devices : []
    } catch (err) {
      console.error('[DeviceStorageService] Failed to load paired devices:', err)
      return []
    }
  }

  static saveDevices(devices: PairedDevice[]): void {
    const filePath = this.getFilePath()
    const jsonStr = JSON.stringify(devices, null, 2)

    try {
      let buffer: Buffer
      if (safeStorage.isEncryptionAvailable()) {
        buffer = safeStorage.encryptString(jsonStr)
      } else {
        console.warn('[DeviceStorageService] safeStorage encryption unavailable, writing raw buffer')
        buffer = Buffer.from(jsonStr, 'utf8')
      }

      fs.writeFileSync(filePath, buffer)
      console.log(`[DeviceStorageService] Saved ${devices.length} paired device(s)`)
    } catch (err) {
      console.error('[DeviceStorageService] Failed to save paired devices:', err)
      throw err
    }
  }

  static addOrUpdateDevice(device: PairedDevice): void {
    const devices = this.loadDevices()
    const index = devices.findIndex((d) => d.deviceId === device.deviceId)
    if (index >= 0) {
      devices[index] = device
    } else {
      devices.push(device)
    }
    this.saveDevices(devices)
  }

  static removeDevice(deviceId: string): void {
    const devices = this.loadDevices().filter((d) => d.deviceId !== deviceId)
    this.saveDevices(devices)
  }

  static clearAll(): void {
    const filePath = this.getFilePath()
    if (fs.existsSync(filePath)) {
      fs.unlinkSync(filePath)
    }
    console.log('[DeviceStorageService] Cleared all paired devices')
  }

  static getPrimaryDevice(): PairedDevice | null {
    const devices = this.loadDevices()
    return devices.length > 0 ? devices[0] : null
  }
}
