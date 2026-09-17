import os from 'node:os'
import crypto from 'node:crypto'
import dgram from 'node:dgram'
import { execFileSync } from 'node:child_process'
import QRCode from 'qrcode'
import { Server, Socket } from 'socket.io'
import { DeviceStorageService, PairedDevice } from './DeviceStorageService.js'
import { SocketService } from './SocketService.js'

export interface PairingPayload {
  ip: string
  port: number
  pairingKey: string
}

export interface PairHandshakeMessage {
  pairingKey: string
  deviceId: string
  deviceName?: string
}

export interface LanInterfaceCandidate {
  name: string
  ip: string
  description: string
  hasDefaultGateway: boolean
  gateway: string | null
  isKernelRouteDefault: boolean
  isPrivate: boolean
  isVirtual: boolean
  score: number
  eligible: boolean
  rejectionReason: string | null
  selectionReason: string
}

export class PairingService {
  private static _currentPairingKey: string | null = null
  private static _isPairingActive = false
  private static _selectedIp: string | null = null
  private static _lastCandidates: LanInterfaceCandidate[] = []

  /**
   * Checks if an IPv4 address is in private RFC1918 ranges:
   * 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
   */
  private static isPrivateIp(ip: string): boolean {
    const parts = ip.split('.').map(Number)
    if (parts.length !== 4) return false
    if (parts[0] === 10) return true
    if (parts[0] === 192 && parts[1] === 168) return true
    if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return true
    return false
  }

  /**
   * Identifies virtual, hypervisor, or host-only adapters based on name, description, or known subnets.
   */
  private static isVirtualAdapter(name: string, description: string = ''): boolean {
    const text = `${name} ${description}`.toLowerCase()
    return (
      text.includes('virtualbox') ||
      text.includes('vbox') ||
      text.includes('vmware') ||
      text.includes('vmnet') ||
      text.includes('hyper-v') ||
      text.includes('vethernet') ||
      text.includes('wsl') ||
      text.includes('docker') ||
      text.includes('host-only') ||
      text.includes('bluetooth') ||
      text.includes('loopback') ||
      text.includes('tailscale') ||
      text.includes('zerotier') ||
      text.includes('tap') ||
      text.includes('tun') ||
      text.includes('pseudo') ||
      text.includes('vpn') ||
      text.includes('wireguard') ||
      text.includes('fortinet') ||
      text.includes('cisco') ||
      text.includes('anyconnect') ||
      text.includes('npcap') ||
      text.includes('teredo')
    )
  }

  /**
   * Asks the OS kernel for the default egress route IP using a non-transmitting UDP connect.
   */
  private static async getKernelEgressIp(): Promise<string | null> {
    return new Promise((resolve) => {
      try {
        const socket = dgram.createSocket('udp4')
        socket.connect(53, '8.8.8.8', () => {
          try {
            const addr = socket.address().address
            socket.close()
            resolve(addr)
          } catch {
            socket.close()
            resolve(null)
          }
        })
        socket.on('error', () => resolve(null))
      } catch {
        resolve(null)
      }
    })
  }

  /**
   * Queries Windows WMI for network adapter configurations (hardware descriptions and gateways).
   */
  private static getWmiAdapters(): Array<{ Description: string; IPAddress: string[]; DefaultIPGateway: string[] | null }> {
    if (process.platform !== 'win32') return []
    try {
      const stdout = execFileSync(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' | Select-Object Description, IPAddress, DefaultIPGateway | ConvertTo-Json -Compress",
        ],
        { encoding: 'utf8', timeout: 4000 }
      )

      if (!stdout || !stdout.trim()) return []
      const parsed = JSON.parse(stdout)
      return Array.isArray(parsed) ? parsed : [parsed]
    } catch (err) {
      console.warn('[PairingService] WMI query fallback error:', (err as Error).message)
      return []
    }
  }

  /**
   * Comprehensive multi-layered LAN interface resolution.
   */
  static async resolveLanInterfaces(): Promise<{
    selected: LanInterfaceCandidate | null
    candidates: LanInterfaceCandidate[]
    all: LanInterfaceCandidate[]
  }> {
    const kernelEgressIp = await this.getKernelEgressIp()
    const wmiAdapters = this.getWmiAdapters()
    const osInterfaces = os.networkInterfaces()

    const evaluated: LanInterfaceCandidate[] = []

    // Map IP -> WMI details
    const wmiByIp = new Map<string, { desc: string; gateways: string[] }>()
    for (const a of wmiAdapters) {
      const desc = a.Description || ''
      const gateways = Array.isArray(a.DefaultIPGateway)
        ? a.DefaultIPGateway
        : a.DefaultIPGateway
        ? [a.DefaultIPGateway]
        : []
      const ips = Array.isArray(a.IPAddress) ? a.IPAddress : a.IPAddress ? [a.IPAddress] : []
      for (const ip of ips) {
        wmiByIp.set(ip, { desc, gateways })
      }
    }

    for (const [ifaceName, addrList] of Object.entries(osInterfaces)) {
      if (!addrList) continue
      for (const net of addrList) {
        const isIpv4 = net.family === 'IPv4' || (net.family as unknown as number) === 4
        if (!isIpv4 || net.internal) continue

        const ip = net.address
        const wmiInfo = wmiByIp.get(ip)
        const desc = wmiInfo ? wmiInfo.desc : ''
        const gateways = wmiInfo ? wmiInfo.gateways : []
        const hasGateway = gateways.length > 0
        const isKernelDefault = kernelEgressIp === ip
        const isPrivate = this.isPrivateIp(ip)

        let isVirtual = this.isVirtualAdapter(ifaceName, desc)
        if (ip.startsWith('192.168.56.')) {
          isVirtual = true // VirtualBox default host-only subnet
        }

        let rejectionReason: string | null = null
        if (ip.startsWith('127.')) {
          rejectionReason = 'Loopback address (127.x.x.x)'
        } else if (ip.startsWith('169.254.')) {
          rejectionReason = 'Link-local address (169.254.x.x)'
        } else if (isVirtual) {
          rejectionReason = `Virtual/host-only adapter (${desc || ifaceName})`
        }

        let score = 0
        const reasons: string[] = []

        if (!rejectionReason) {
          if (isKernelDefault) {
            score += 1000
            reasons.push('Matches active OS kernel default egress route')
          }
          if (hasGateway) {
            score += 500
            reasons.push(`Has active LAN default gateway (${gateways.join(', ')})`)
          }
          const text = `${ifaceName} ${desc}`.toLowerCase()
          if (
            text.includes('wi-fi') ||
            text.includes('wireless') ||
            text.includes('wlan') ||
            text.includes('802.11')
          ) {
            score += 200
            reasons.push('Physical Wi-Fi interface')
          } else if (
            text.includes('ethernet') ||
            text.includes('gigabit') ||
            text.includes('realtek') ||
            text.includes('intel') ||
            text.includes('broadcom')
          ) {
            score += 150
            reasons.push('Physical Ethernet interface')
          }
          if (isPrivate) {
            score += 50
            reasons.push('Private RFC1918 LAN address')
          }
        }

        evaluated.push({
          name: ifaceName,
          ip,
          description: desc,
          hasDefaultGateway: hasGateway,
          gateway: gateways[0] || null,
          isKernelRouteDefault: isKernelDefault,
          isPrivate,
          isVirtual,
          score,
          eligible: !rejectionReason,
          rejectionReason,
          selectionReason: reasons.join(' + ') || 'Fallback interface',
        })
      }
    }

    const eligible = evaluated.filter((e) => e.eligible).sort((a, b) => b.score - a.score)
    this._lastCandidates = eligible

    console.log('\n[PairingService] === Network Interface Audit ===')
    for (const c of evaluated) {
      if (c.eligible) {
        console.log(
          `[PairingService] [ELIGIBLE] ${c.name} (${c.ip}): ${c.description || 'N/A'} | Score: ${c.score} | ${c.selectionReason}`
        )
      } else {
        console.log(
          `[PairingService] [EXCLUDED] ${c.name} (${c.ip}): ${c.description || 'N/A'} -> ${c.rejectionReason}`
        )
      }
    }
    console.log('[PairingService] ===============================')

    const selected = eligible.length > 0 ? eligible[0] : null
    if (selected) {
      console.log(`[PairingService] >>> SELECTED LAN INTERFACE: ${selected.name} (${selected.ip})`)
      console.log(`[PairingService] >>> REASON: ${selected.selectionReason} (Score: ${selected.score})\n`)
    } else {
      console.warn('[PairingService] >>> WARNING: No eligible physical LAN interface detected!')
    }

    return { selected, candidates: eligible, all: evaluated }
  }

  /**
   * Generates a new 256-bit random pairing key and QR payload.
   * If manualIp is provided, uses it; otherwise uses the highest-ranked LAN interface.
   */
  static async generatePairingData(forcedIp?: string): Promise<{
    payload: PairingPayload
    dataUrl: string
    selected: LanInterfaceCandidate | null
    candidates: LanInterfaceCandidate[]
  }> {
    const resolution = await this.resolveLanInterfaces()
    let ip = '127.0.0.1'
    let chosenCandidate: LanInterfaceCandidate | null = null

    if (forcedIp) {
      ip = forcedIp
      chosenCandidate = resolution.candidates.find((c) => c.ip === forcedIp) || null
      console.log(`[PairingService] User explicitly selected interface IP: ${ip}`)
    } else if (resolution.selected) {
      ip = resolution.selected.ip
      chosenCandidate = resolution.selected
    } else {
      console.error('[PairingService] Could not find any valid LAN interface!')
    }

    this._selectedIp = ip
    const port = 4000
    const pairingKey = crypto.randomBytes(32).toString('base64')
    this._currentPairingKey = pairingKey
    this._isPairingActive = true

    const payload: PairingPayload = { ip, port, pairingKey }
    const jsonStr = JSON.stringify(payload)
    const dataUrl = await QRCode.toDataURL(jsonStr, {
      errorCorrectionLevel: 'M',
      margin: 2,
      width: 280,
    })

    console.log(`[PairingService] Generated pairing session for advertised IP: ${ip}:${port}`)
    return {
      payload,
      dataUrl,
      selected: chosenCandidate,
      candidates: resolution.candidates,
    }
  }

  /**
   * Returns current active candidates.
   */
  static getLastCandidates(): LanInterfaceCandidate[] {
    return this._lastCandidates
  }

  static getSelectedIp(): string | null {
    return this._selectedIp
  }

  /**
   * Starts the temporary unencrypted pairing handshake listener on the Socket.IO server.
   * Only accepts a handshake matching `_currentPairingKey`. Rejects/disconnects anything else.
   */
  static setupPairingListener(
    io: Server,
    onPaired?: (device: PairedDevice) => void
  ): void {
    io.on('connection', (socket: Socket) => {
      socket.on('pair-handshake', (data: unknown) => {
        if (!this._isPairingActive || !this._currentPairingKey) {
          console.warn(`[PairingService] Handshake received but pairing is not active. Rejecting socket ${socket.id}`)
          socket.emit('pair-error', { message: 'Pairing session is not active on PC. Please click "Pair New" on your computer to show a fresh QR code.' })
          setTimeout(() => socket.disconnect(true), 500)
          return
        }

        const msg = data as PairHandshakeMessage
        if (!msg || typeof msg.pairingKey !== 'string') {
          console.warn(`[PairingService] Invalid handshake format from socket ${socket.id}`)
          socket.emit('pair-error', { message: 'Invalid handshake message format' })
          setTimeout(() => socket.disconnect(true), 500)
          return
        }

        if (msg.pairingKey !== this._currentPairingKey) {
          console.warn(`[PairingService] Pairing key mismatch from socket ${socket.id}! Rejecting.`)
          socket.emit('pair-error', { message: 'Pairing key mismatch. Please scan the current QR code shown on your PC.' })
          setTimeout(() => socket.disconnect(true), 500)
          return
        }

        console.log(`[PairingService] Handshake SUCCESS from device: ${msg.deviceId} (${msg.deviceName ?? 'Unknown'})`)
        
        const device: PairedDevice = {
          deviceId: msg.deviceId || crypto.randomUUID(),
          pairingKey: this._currentPairingKey,
          name: msg.deviceName || 'Android Device',
          pairedAt: new Date().toISOString(),
        }

        // Save to encrypted storage
        DeviceStorageService.addOrUpdateDevice(device)

        // Close/deactivate temporary pairing listener
        this._isPairingActive = false
        this._currentPairingKey = null

        // Respond with pair-success
        socket.emit('pair-success', {
          deviceId: device.deviceId,
          status: 'ok',
        })

        // Activate encryption on SocketService
        const keyBuffer = Buffer.from(device.pairingKey, 'base64')
        SocketService.setEncryptionKey(keyBuffer)
        SocketService.notifyClientConnect()

        if (onPaired) {
          onPaired(device)
        }
      })
    })
  }

  static isPairingActive(): boolean {
    return this._isPairingActive
  }

  static cancelPairing(): void {
    this._isPairingActive = false
    this._currentPairingKey = null
  }
}
