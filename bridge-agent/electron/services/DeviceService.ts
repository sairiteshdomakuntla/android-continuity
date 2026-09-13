import { randomUUID } from 'node:crypto'
import { SocketService } from './SocketService.js'
import type { BridgeMessage, DevicePayload, RingPayload } from '../types/protocol.js'

export interface BatteryStatus {
  level: number
  isCharging: boolean
  updatedAt: string
}

type BatteryListener = (status: BatteryStatus | null) => void

/**
 * Device-status (phone battery) + find-my-phone signalling.
 * Keeps only the most recent battery value — no history.
 */
class DeviceServiceClass {
  private _started = false
  private _battery: BatteryStatus | null = null
  private _listeners: BatteryListener[] = []

  start(): void {
    if (this._started) return
    this._started = true

    console.log('[DeviceService] Device service initialized and listening')

    SocketService.onMessage('device', (rawMsg: BridgeMessage) => {
      const msg = rawMsg as BridgeMessage<DevicePayload>
      const payload = msg.payload
      if (!payload || !payload.event) return

      if (payload.event === 'battery-update') {
        const level = Math.max(0, Math.min(100, Math.round(payload.level)))
        this._battery = {
          level,
          isCharging: !!payload.isCharging,
          updatedAt: msg.timestamp || new Date().toISOString(),
        }
        console.log(`[DeviceService] [RECV] Battery: ${level}%${this._battery.isCharging ? ' (charging)' : ''}`)
        this._notifyListeners()
      }
    })
  }

  getBattery(): BatteryStatus | null {
    return this._battery ? { ...this._battery } : null
  }

  clearBattery(): void {
    if (this._battery !== null) {
      this._battery = null
      this._notifyListeners()
    }
  }

  onBatteryUpdate(callback: BatteryListener): void {
    this._listeners.push(callback)
  }

  /** Windows → Android: ring the phone at max alarm volume. */
  ringPhone(): void {
    const msg: BridgeMessage<RingPayload> = {
      eventId: randomUUID(),
      type: 'device',
      origin: 'windows',
      timestamp: new Date().toISOString(),
      payload: { event: 'ring' },
    }
    console.log('[DeviceService] [SEND] Ringing phone')
    SocketService.broadcast(msg as BridgeMessage<unknown>)
  }

  private _notifyListeners(): void {
    const status = this.getBattery()
    for (const listener of this._listeners) {
      try {
        listener(status)
      } catch (e) {
        console.error('[DeviceService] Error notifying listener:', e)
      }
    }
  }
}

export const DeviceService = new DeviceServiceClass()
