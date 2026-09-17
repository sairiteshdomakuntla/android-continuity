export type MessageType = 'clipboard' | 'file' | 'camera-signal' | 'mic-signal' | 'ping' | 'notification' | 'device' | 'remote-input'
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

// ── Mic signaling ("Phone as Microphone") ───────────────────────────────────
// Separate audio-only peer connection from the camera one so camera and mic
// can run independently. Same offer/answer/ICE pattern over the same
// encrypted socket — Stage 1 plays through PC speakers only (no virtual
// audio driver, so not a system-wide selectable input yet).
export interface MicStartPayload    { event: 'start-mic' }
export interface MicStopPayload     { event: 'stop-mic' }
export interface MicOfferPayload    { event: 'offer';         sdp: string }
export interface MicAnswerPayload   { event: 'answer';        sdp: string }
export interface MicIcePayload      { event: 'ice-candidate'; candidate: RTCIceCandidateInit | null }

export type MicSignalPayload =
  | MicStartPayload
  | MicStopPayload
  | MicOfferPayload
  | MicAnswerPayload
  | MicIcePayload

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

// ── Remote input ("Phone as Remote") ──────────────────────────────────────────

/** Android → Windows: relative cursor movement deltas (logical pixels). */
export interface RemoteMouseMovePayload {
  event: 'mouse-move'
  dx: number
  dy: number
}

/** Android → Windows: single click (down+up) of a mouse button. */
export interface RemoteMouseClickPayload {
  event: 'mouse-click'
  button: 'left' | 'right'
}

/** Android → Windows: vertical scroll. Positive dy = fingers moved down = scroll down. */
export interface RemoteScrollPayload {
  event: 'scroll'
  dy: number
}

/** Android → Windows: cursor-movement sensitivity multiplier (moves only). */
export interface RemoteSetSensitivityPayload {
  event: 'set-sensitivity'
  value: number
}

/** Android → Windows: typed text (one or more characters, no modifiers). */
export interface RemoteKeyInputPayload {
  event: 'key-input'
  text: string
}

/** Android → Windows: non-character key tap. */
export interface RemoteKeySpecialPayload {
  event: 'key-special'
  key: 'enter' | 'backspace' | 'space'
}

/** Android → Windows: media key command, applies to the app with media focus. */
export interface RemoteMediaCommandPayload {
  event: 'media-command'
  command: 'play-pause' | 'next' | 'previous' | 'volume-up' | 'volume-down' | 'mute'
}

/** Windows → Android: open the Remote (trackpad) screen on the phone. */
export interface RemoteOpenPayload {
  event: 'open-remote'
}

export type RemoteInputPayload =
  | RemoteMouseMovePayload
  | RemoteMouseClickPayload
  | RemoteScrollPayload
  | RemoteSetSensitivityPayload
  | RemoteKeyInputPayload
  | RemoteKeySpecialPayload
  | RemoteMediaCommandPayload
  | RemoteOpenPayload
