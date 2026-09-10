import http from 'node:http'
import { Server, Socket } from 'socket.io'
import type { BridgeMessage, MessageType } from '../types/protocol.js'
import { CryptoService } from './CryptoService.js'

const PORT = 4000
const HOST = '0.0.0.0'

type MessageHandler = (msg: BridgeMessage) => void
type ConnectHandler = () => void

class SocketServiceClass {
  private _io: Server | null = null
  private _encKey: Buffer | null = null
  private _handlers = new Map<MessageType, MessageHandler[]>()
  private _connectHandlers: ConnectHandler[] = []

  start(): Server {
    const httpServer = http.createServer()
    this._io = new Server(httpServer, {
      cors: { origin: '*', methods: ['GET', 'POST'] },
    })

    this._io.on('connection', (socket: Socket) => {
      console.log(`[SocketService] Client connected: ${socket.id}`)

      // Notify feature services only if encryption is ready (authenticated client)
      if (this._encKey) {
        this._connectHandlers.forEach((h) => h())
      }

      socket.on('bridge-message', (raw: unknown) => {
        let msg: BridgeMessage

        if (this._encKey) {
          if (typeof raw !== 'string') {
            console.warn('[SocketService] Expected encrypted base64 payload, received non-string. Dropping.')
            return
          }

          console.log(`[SocketService] [RECV ENCRYPTED] Raw wire payload: ${raw.slice(0, 32)}... (len: ${raw.length})`)

          try {
            const decryptedJson = CryptoService.decrypt(this._encKey, raw)
            msg = JSON.parse(decryptedJson) as BridgeMessage
          } catch (err) {
            console.error('[SocketService] Decryption failed! Dropping message:', err)
            return
          }
        } else {
          msg = raw as BridgeMessage
        }

        console.log(`[SocketService] [RECV] [${msg.type}] ${msg.eventId} from ${msg.origin}`)
        const handlers = this._handlers.get(msg.type) ?? []
        handlers.forEach((h) => h(msg))
      })

      socket.on('disconnect', (reason: string) => {
        console.log(`[SocketService] Client disconnected: ${socket.id} (${reason})`)
      })
    })

    httpServer.listen(PORT, HOST, () => {
      console.log(`[SocketService] Server listening on http://${HOST}:${PORT}`)
    })

    return this._io
  }

  getIo(): Server | null {
    return this._io
  }

  getClientCount(): number {
    return this._io?.engine?.clientsCount ?? 0
  }

  hasConnectedClients(): boolean {
    return this.getClientCount() > 0
  }

  setEncryptionKey(key: Buffer | null): void {
    this._encKey = key
    if (key) {
      console.log(`[SocketService] Encryption key set (${key.length} bytes). AES-256-GCM active.`)
    } else {
      console.log('[SocketService] Encryption key cleared.')
    }
  }

  getEncryptionKey(): Buffer | null {
    return this._encKey
  }

  broadcast(msg: BridgeMessage): void {
    if (!this._io) {
      console.warn('[SocketService] broadcast() called before start()')
      return
    }

    if (this._encKey) {
      const plaintext = JSON.stringify(msg)
      const ciphertext = CryptoService.encrypt(this._encKey, plaintext)
      console.log(`[SocketService] [SEND ENCRYPTED] [${msg.type}] ${msg.eventId}`)
      console.log(`[SocketService] Raw wire payload: ${ciphertext.slice(0, 32)}... (len: ${ciphertext.length})`)
      this._io.emit('bridge-message', ciphertext)
    } else {
      console.log(`[SocketService] [SEND] [${msg.type}] ${msg.eventId}`)
      this._io.emit('bridge-message', msg)
    }
  }

  onMessage(type: MessageType, handler: MessageHandler): void {
    const existing = this._handlers.get(type) ?? []
    this._handlers.set(type, [...existing, handler])
  }

  /** Called whenever a new client connects. Use to push current state. */
  onClientConnect(handler: ConnectHandler): void {
    this._connectHandlers.push(handler)
  }

  /** Explicitly trigger connect handlers once a client finishes handshake/authentication. */
  notifyClientConnect(): void {
    console.log('[SocketService] Notifying feature services of authenticated client connection')
    this._connectHandlers.forEach((h) => h())
  }
}

export const SocketService = new SocketServiceClass()
