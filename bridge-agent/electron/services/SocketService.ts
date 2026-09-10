import http from 'node:http'
import { Server, Socket } from 'socket.io'
import type { BridgeMessage, MessageType } from '../types/protocol.js'

const PORT = 4000
const HOST = '0.0.0.0'

type MessageHandler = (msg: BridgeMessage) => void
type ConnectHandler = () => void

class SocketServiceClass {
  private _io: Server | null = null
  private _handlers = new Map<MessageType, MessageHandler[]>()
  private _connectHandlers: ConnectHandler[] = []

  start(): void {
    const httpServer = http.createServer()
    this._io = new Server(httpServer, {
      cors: { origin: '*', methods: ['GET', 'POST'] },
    })

    this._io.on('connection', (socket: Socket) => {
      console.log(`[SocketService] Client connected: ${socket.id}`)

      // Notify feature services so they can push initial state to the new client
      this._connectHandlers.forEach((h) => h())

      socket.on('bridge-message', (raw: unknown) => {
        const msg = raw as BridgeMessage
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
  }

  broadcast(msg: BridgeMessage): void {
    if (!this._io) {
      console.warn('[SocketService] broadcast() called before start()')
      return
    }
    console.log(`[SocketService] [SEND] [${msg.type}] ${msg.eventId}`)
    this._io.emit('bridge-message', msg)
  }

  onMessage(type: MessageType, handler: MessageHandler): void {
    const existing = this._handlers.get(type) ?? []
    this._handlers.set(type, [...existing, handler])
  }

  /** Called whenever a new client connects. Use to push current state. */
  onClientConnect(handler: ConnectHandler): void {
    this._connectHandlers.push(handler)
  }
}

export const SocketService = new SocketServiceClass()
