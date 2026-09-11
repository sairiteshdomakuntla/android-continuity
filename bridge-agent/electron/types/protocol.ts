export type MessageType = 'clipboard' | 'file' | 'camera-signal' | 'ping' | 'notification'
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

export interface ClipboardHistoryItem {
  id: string
  text: string
  timestamp: string
  origin: Origin
}

// ── File transfer ─────────────────────────────────────────────────────────────

export interface FileMetaPayload {
  event: 'file-meta'
  transferId: string
  fileName: string
  mimeType: string
  totalBytes: number
  totalChunks: number
}

export interface FileChunkPayload {
  event: 'file-chunk'
  transferId: string
  index: number
  /** Raw file bytes for this chunk, base64-encoded */
  data: string
}

export interface FileCompletePayload {
  event: 'file-complete'
  transferId: string
  /** SHA-256 hex digest computed incrementally over raw chunk bytes */
  sha256: string
}

export type FilePayload = FileMetaPayload | FileChunkPayload | FileCompletePayload

// ── Camera signaling ──────────────────────────────────────────────────────────

export interface CameraStartPayload   { event: 'start-camera' }
export interface CameraStopPayload    { event: 'stop-camera' }
export interface CameraOfferPayload   { event: 'offer';         sdp: string }
export interface CameraAnswerPayload  { event: 'answer';        sdp: string }
export interface CameraIcePayload     { event: 'ice-candidate'; candidate: RTCIceCandidateInit | null }

export type CameraSignalPayload =
  | CameraStartPayload
  | CameraStopPayload
  | CameraOfferPayload
  | CameraAnswerPayload
  | CameraIcePayload

// ── Notification sync ────────────────────────────────────────────────────────

export interface NotificationPostedPayload {
  event: 'posted'
  notificationId: string
  packageName: string
  appName: string
  title: string
  text: string
  timestamp: string
  hasReplyAction: boolean
  hasQuickActions: string[]
}

export interface NotificationDismissedPayload {
  event: 'dismissed'
  notificationId: string
}

export interface NotificationReplyPayload {
  event: 'reply'
  notificationId: string
  replyText: string
}

export interface NotificationReplyFailedPayload {
  event: 'reply-failed'
  notificationId: string
  error?: string
}

export interface NotificationDismissRequestPayload {
  event: 'dismiss-request'
  notificationId: string
}

export type NotificationPayload =
  | NotificationPostedPayload
  | NotificationDismissedPayload
  | NotificationReplyPayload
  | NotificationReplyFailedPayload
  | NotificationDismissRequestPayload
