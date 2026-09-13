export type MessageType = 'clipboard' | 'file' | 'camera-signal' | 'ping' | 'notification' | 'device'
export type Origin = 'android' | 'windows'

export interface BridgeMessage<T = unknown> {
  eventId: string     // crypto.randomUUID()
  type: MessageType
  origin: Origin
  timestamp: string   // ISO 8601 UTC
  payload: T
}

export type ClipboardContentType = 'text' | 'url' | 'otp' | 'email' | 'phone' | 'image'

export interface ClipboardPayload {
  kind?: 'text' | 'image'
  text?: string
  transferId?: string
  mimeType?: string
}

export interface ClipboardHistoryItem {
  id: string
  kind: 'text' | 'image'
  contentType: ClipboardContentType
  text?: string
  imageThumbnail?: string  // base64 Data URL (e.g. data:image/png;base64,...) for UI preview
  imagePath?: string       // absolute local path to cached file on disk
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
  transferType?: 'file' | 'clipboard-image'
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

// ── Device status (battery) & find-my-phone ───────────────────────────────

export interface BatteryUpdatePayload {
  event: 'battery-update'
  /** Battery level 0–100 */
  level: number
  isCharging: boolean
}

export interface RingPayload {
  event: 'ring'
}

export type DevicePayload = BatteryUpdatePayload | RingPayload
