import dgram from 'node:dgram'
import os from 'node:os'
import { PairingService } from './PairingService.js'

export class DiscoveryService {
  private static _socket: dgram.Socket | null = null
  public static readonly DISCOVERY_PORT = 4001
  private static _heartbeatTimer: NodeJS.Timeout | null = null

  static start(): void {
    if (this._socket) return

    try {
      const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
      this._socket = socket

      socket.on('message', async (msg, rinfo) => {
        try {
          const text = msg.toString('utf8')
          if (text.includes('bridge-discover')) {
            console.log(`[DiscoveryService] Received discovery request from ${rinfo.address}:${rinfo.port}`)
            const ip = PairingService.getSelectedIp() || (await PairingService.resolveLanInterfaces()).selected?.ip
            if (!ip) return

            const response = JSON.stringify({
              type: 'bridge-announce',
              ip,
              port: 4000,
              hostname: os.hostname(),
            })

            socket.send(response, rinfo.port, rinfo.address, (err) => {
              if (err) {
                console.error('[DiscoveryService] Error sending discovery response:', err)
              } else {
                console.log(`[DiscoveryService] Sent announcement to ${rinfo.address}:${rinfo.port} (IP: ${ip}:4000)`)
              }
            })
          }
        } catch (err) {
          console.error('[DiscoveryService] Error processing discovery packet:', err)
        }
      })

      socket.on('error', (err) => {
        console.error('[DiscoveryService] UDP socket error:', err)
      })

      socket.bind(this.DISCOVERY_PORT, () => {
        try {
          socket.setBroadcast(true)
        } catch (_) {}
        console.log(`[DiscoveryService] Listening for LAN discovery requests on UDP port ${this.DISCOVERY_PORT}`)
      })

      // Periodically broadcast beacon every 10s to announce presence on the LAN
      this._heartbeatTimer = setInterval(async () => {
        await this.broadcastPresence()
      }, 10000)
    } catch (err) {
      console.error('[DiscoveryService] Failed to start UDP discovery service:', err)
    }
  }

  static async broadcastPresence(): Promise<void> {
    if (!this._socket) return
    try {
      const ip = PairingService.getSelectedIp() || (await PairingService.resolveLanInterfaces()).selected?.ip
      if (!ip) return

      const announcement = JSON.stringify({
        type: 'bridge-beacon',
        ip,
        port: 4000,
        hostname: os.hostname(),
      })

      this._socket.send(announcement, this.DISCOVERY_PORT, '255.255.255.255')
    } catch (_) {
      // Ignored if network changes or broadcast is restricted
    }
  }

  static stop(): void {
    if (this._heartbeatTimer) {
      clearInterval(this._heartbeatTimer)
      this._heartbeatTimer = null
    }
    if (this._socket) {
      try {
        this._socket.close()
      } catch (_) {}
      this._socket = null
    }
  }
}
