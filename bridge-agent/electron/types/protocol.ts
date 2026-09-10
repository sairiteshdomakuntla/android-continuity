export type MessageType = 'clipboard' | 'file' | 'camera-signal' | 'ping'
export type Origin = 'android' | 'windows'

export interface BridgeMessage<T = unknown> {
  eventId: string     // crypto.randomUUID()
  type: MessageType
  origin: Origin
  timestamp: string   // ISO 8601 UTC
  payload: T
}

export interface ClipboardPayload {
  text: string
}
