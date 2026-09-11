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
    const httpServer = http.createServer((req, res) => {
      if (req.url === '/obs-camera' || req.url === '/obs-camera.html') {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
        res.end(getObsCameraHtml())
        return
      }
      res.writeHead(404)
      res.end('Not found')
    })
    this._io = new Server(httpServer, {
      cors: { origin: '*', methods: ['GET', 'POST'] },
    })

    this._io.on('connection', (socket: Socket) => {
      console.log(`[SocketService] Client connected: ${socket.id}`)

      // Notify feature services only if encryption is ready (authenticated client)
      if (this._encKey) {
        this._connectHandlers.forEach((h) => h())
      }

      // ── Local OBS Browser Source Receiver ─────────────────────────────────
      socket.on('obs-camera-ready', () => {
        console.log('[SocketService] OBS Camera receiver connected and ready')
      })

      socket.on('obs-camera-signal-out', (payload: any) => {
        console.log(`[SocketService] OBS Camera sending signal to Android: ${payload?.event}`)
        const { randomUUID } = require('node:crypto')
        this.broadcast({
          eventId: randomUUID(),
          type: 'camera-signal',
          origin: 'windows',
          timestamp: new Date().toISOString(),
          payload,
        })
      })

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

        // Relay camera signals to local OBS Browser Source receiver
        if (msg.type === 'camera-signal') {
          this._io?.emit('obs-camera-signal-in', msg.payload)
        }

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

function getObsCameraHtml(): string {
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>Bridge OBS Camera Receiver</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
    #video {
      width: 100vw;
      height: 100vh;
      object-fit: cover;
      display: block;
      background: #000;
    }
  </style>
  <script src="/socket.io/socket.io.js"></script>
</head>
<body>
  <video id="video" autoplay playsinline muted></video>
  <script>
    const video = document.getElementById('video');
    const socket = io();
    let pc = null;

    const ICE_CONFIG = {
      iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
    };

    function createPeerConnection() {
      if (pc) {
        pc.close();
        pc = null;
      }
      const conn = new RTCPeerConnection(ICE_CONFIG);
      pc = conn;

      conn.onicecandidate = (evt) => {
        if (evt.candidate) {
          socket.emit('obs-camera-signal-out', {
            event: 'ice-candidate',
            candidate: evt.candidate.toJSON(),
          });
        }
      };

      conn.ontrack = (evt) => {
        if (evt.streams && evt.streams[0]) {
          video.srcObject = evt.streams[0];
          video.play().catch((e) => console.warn('video.play error:', e));
        }
      };

      return conn;
    }

    async function handleOffer(sdp) {
      console.log('[OBS-Cam] Handling offer from Android...');
      const conn = createPeerConnection();
      await conn.setRemoteDescription({ type: 'offer', sdp });
      const answer = await conn.createAnswer();
      await conn.setLocalDescription(answer);
      socket.emit('obs-camera-signal-out', {
        event: 'answer',
        sdp: answer.sdp,
      });
      console.log('[OBS-Cam] Answer sent to Android');
    }

    async function handleIceCandidate(candidate) {
      if (!pc || !candidate) return;
      try {
        await pc.addIceCandidate(new RTCIceCandidate(candidate));
      } catch (e) {
        console.warn('[OBS-Cam] addIceCandidate error:', e);
      }
    }

    socket.on('connect', () => {
      console.log('[OBS-Cam] Connected to Bridge local socket');
      socket.emit('obs-camera-ready');
    });

    socket.on('obs-camera-signal-in', async (payload) => {
      console.log('[OBS-Cam] Received signal:', payload && payload.event);
      if (!payload) return;
      if (payload.event === 'offer' && payload.sdp) {
        await handleOffer(payload.sdp);
      } else if (payload.event === 'ice-candidate' && payload.candidate) {
        await handleIceCandidate(payload.candidate);
      } else if (payload.event === 'stop-camera') {
        if (pc) { pc.close(); pc = null; }
        video.srcObject = null;
      }
    });
  </script>
</body>
</html>`
}
