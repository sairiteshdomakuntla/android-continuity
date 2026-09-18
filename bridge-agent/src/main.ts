import './style.css'

interface PairedDevice {
  deviceId: string
  pairingKey: string
  name?: string
  pairedAt: string
}

interface LanInterfaceCandidate {
  name: string
  ip: string
  description: string
  hasDefaultGateway: boolean
  gateway: string | null
  isKernelRouteDefault: boolean
  isPrivate: boolean
  isVirtual: boolean
  score: number
  selectionReason: string
}

interface StatusResponse {
  devices: PairedDevice[]
  isPairingActive: boolean
  currentPairing: {
    ip: string
    port: number
    qrDataUrl: string
    selected: LanInterfaceCandidate | null
    candidates: LanInterfaceCandidate[]
  } | null
}

interface ClipboardHistoryItem {
  id: string
  kind: 'text' | 'image'
  contentType: 'text' | 'url' | 'otp' | 'email' | 'phone' | 'image'
  text?: string
  imageThumbnail?: string
  imagePath?: string
  timestamp: string
  origin: 'android' | 'windows'
}

interface NotificationItem {
  notificationId: string
  packageName: string
  appName: string
  title: string
  text: string
  timestamp: string
  hasReplyAction: boolean
  hasQuickActions: string[]
  replyError?: string
}

interface FileSendProgress {
  transferId: string
  fileName: string
  bytesSent: number
  totalBytes: number
  done: boolean
  error?: string
}

interface BatteryStatus {
  level: number
  isCharging: boolean
  updatedAt: string
}

const appEl = document.querySelector<HTMLDivElement>('#app')!
let clipboardHistory: ClipboardHistoryItem[] = []
let notificationsList: NotificationItem[] = []
let batteryStatus: BatteryStatus | null = null
let autoLaunch: boolean | null = null
let replyDrafts: Record<string, string> = {}
let replySubmitting: Record<string, boolean> = {}
let lastStatus: StatusResponse | null = null

// ── Render-only UI state (no IPC/backend impact) ─────────────────────────────
let activeTab: 'notifications' | 'clipboard' = 'notifications'
const expandedReplies = new Set<string>()
let dragCounter = 0
let isDragging = false

/* MIC PARKED — Phone as Microphone, revisit later. Uncomment this block to restore.
   (State, WebRTC answerer, and helpers for PC-speaker playback.)
// ── Phone-as-Microphone state (Stage 1: PC-speaker playback only) ───────────
// Separate RTCPeerConnection from the camera one so camera and mic run
// independently. This side is the ANSWERER; Android offers audio-only.
let micPc: RTCPeerConnection | null = null
let micActive = false
let micStream: MediaStream | null = null
let micRemoteDescSet = false
let micPendingCandidates: RTCIceCandidateInit[] = []
const MIC_ICE_CONFIG: RTCConfiguration = {
  iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
}

function sendMicSignal(payload: unknown): void {
  window.ipcRenderer.send('mic-signal-send', payload)
}

function attachMicAudio(): void {
  const audio = document.getElementById('mic-audio') as HTMLAudioElement | null
  if (audio && micStream) {
    if (audio.srcObject !== micStream) {
      audio.srcObject = micStream
    }
    audio.play().catch(() => {})
  }
}

function setMicBanner(active: boolean): void {
  micActive = active
  const banner = document.getElementById('mic-status-banner')
  if (banner) {
    banner.style.display = active ? 'flex' : 'none'
  }
  if (active) {
    attachMicAudio()
  } else {
    const audio = document.getElementById('mic-audio') as HTMLAudioElement | null
    if (audio) {
      audio.srcObject = null
    }
  }
}

function createMicPeerConnection(): RTCPeerConnection {
  teardownMicPc()
  const conn = new RTCPeerConnection(MIC_ICE_CONFIG)
  micPc = conn
  micRemoteDescSet = false
  micPendingCandidates = []

  conn.onicecandidate = (evt) => {
    sendMicSignal({
      event: 'ice-candidate',
      candidate: evt.candidate ? evt.candidate.toJSON() : null,
    })
  }

  conn.oniceconnectionstatechange = () => {
    if (conn.iceConnectionState === 'failed' || conn.iceConnectionState === 'disconnected') {
      console.warn('[Mic] ICE disconnected — tearing down')
      stopMic('Connection lost')
    }
  }

  conn.onconnectionstatechange = () => {
    if (conn.connectionState === 'failed' || conn.connectionState === 'closed') {
      stopMic('Connection lost')
    }
  }

  conn.ontrack = (evt) => {
    micStream = (evt.streams && evt.streams[0]) ? evt.streams[0] : new MediaStream([evt.track])
    console.log('[Mic] Audio track received — playing through default output device')
    attachMicAudio()
    setMicBanner(true)
    window.ipcRenderer.send('mic-live')
  }

  return conn
}

async function handleMicOffer(sdp: string): Promise<void> {
  console.log('[Mic] Received offer from Android, creating answer…')
  const conn = createMicPeerConnection()
  await conn.setRemoteDescription({ type: 'offer', sdp })
  micRemoteDescSet = true

  while (micPendingCandidates.length > 0) {
    const cand = micPendingCandidates.shift()
    if (cand) {
      try {
        await conn.addIceCandidate(new RTCIceCandidate(cand))
      } catch (e) {
        console.warn('[Mic] addIceCandidate error on buffered candidate:', e)
      }
    }
  }

  const answer = await conn.createAnswer()
  await conn.setLocalDescription(answer)
  sendMicSignal({ event: 'answer', sdp: conn.localDescription?.sdp || answer.sdp })
  console.log('[Mic] WebRTC Answer sent to Android')
}

async function handleMicIceCandidate(candidate: RTCIceCandidateInit | null): Promise<void> {
  if (!candidate) return
  if (!micPc || !micRemoteDescSet) {
    micPendingCandidates.push(candidate)
    return
  }
  try {
    await micPc.addIceCandidate(new RTCIceCandidate(candidate))
  } catch (e) {
    console.warn('[Mic] addIceCandidate error:', e)
  }
}

function teardownMicPc(): void {
  micRemoteDescSet = false
  micPendingCandidates = []
  if (micPc) {
    micPc.ontrack = null
    micPc.onicecandidate = null
    micPc.oniceconnectionstatechange = null
    micPc.onconnectionstatechange = null
    try { micPc.close() } catch {}
    micPc = null
  }
  if (micStream) {
    try {
      micStream.getTracks().forEach((t) => t.stop())
    } catch {}
    micStream = null
  }
  const audio = document.getElementById('mic-audio') as HTMLAudioElement | null
  if (audio) {
    audio.srcObject = null
  }
}

function startMic(): void {
  sendMicSignal({ event: 'start-mic' })
  // Banner flips live on first audio track; show "connecting" immediately.
  setMicBanner(true)
  const label = document.getElementById('mic-status-text')
  if (label) label.textContent = 'Connecting to phone microphone…'
}

function stopMic(_reason = 'Stopped'): void {
  teardownMicPc()
  setMicBanner(false)
  sendMicSignal({ event: 'stop-mic' })
  window.ipcRenderer.send('mic-stopped')
}
// MIC PARKED — end (uncomment the block above to restore). */

// ── Lucide icons (bundled inline SVG, 2px stroke — no CDN dependency) ─────────
const ICONS: Record<string, string> = {
  zap: '<path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>',
  camera: '<path d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3z"/><circle cx="12" cy="13" r="3"/>',
  fileUp: '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M9 15h6"/><path d="M12 18v-6"/>',
  plus: '<path d="M5 12h14"/><path d="M12 5v14"/>',
  bell: '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>',
  clipboardList: '<rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M12 11h4"/><path d="M12 16h4"/><path d="M8 11h.01"/><path d="M8 16h.01"/>',
  x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  minus: '<path d="M5 12h14"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
  key: '<path d="m21 2-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0 3 3L22 7l-3-3m-3.5 3.5L19 4"/>',
  mail: '<rect width="20" height="16" x="2" y="4" rx="2"/><path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7"/>',
  phone: '<path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"/>',
  image: '<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>',
  messageCircle: '<path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/>',
  smartphone: '<rect width="14" height="20" x="5" y="2" rx="2" ry="2"/><path d="M12 18h.01"/>',
  monitor: '<rect width="20" height="14" x="2" y="3" rx="2"/><path d="M8 21h8"/><path d="M12 17v4"/>',
  mouse: '<rect x="5" y="2" width="14" height="20" rx="7"/><path d="M12 6v4"/>',
  send: '<path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/>',
  trash: '<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
  fileText: '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>',
  shieldCheck: '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/>',
  sprout: '<path d="M7 20h10"/><path d="M10 20c5.5-2.5.8-6.4 3-10"/><path d="M9.5 9.4c1.1.8 1.8 2.2 2.3 3.7-2 .4-3.5.4-4.8-.3-1.2-.6-2.3-1.9-3-4.2 2.8-.5 4.4 0 5.5.8z"/><path d="M14.1 6a7 7 0 0 0-1.1 4c1.9-.1 3.3-.6 4.3-1.4 1-1 1.6-2.3 1.7-4.6-3.2.3-4.3 1-4.9 2z"/>',
  wifi: '<path d="M12 20h.01"/><path d="M2 8.82a15 15 0 0 1 20 0"/><path d="M5 12.859a10 10 0 0 1 14 0"/><path d="M8.5 16.429a5 5 0 0 1 7 0"/>',
  batteryMedium: '<rect width="16" height="10" x="2" y="7" rx="2" ry="2"/><line x1="22" x2="22" y1="11" y2="13"/><line x1="6" x2="6" y1="11" y2="13"/><line x1="10" x2="10" y1="11" y2="13"/><line x1="14" x2="14" y1="11" y2="13"/>',
  batteryCharging: '<path d="M14.856 6H16a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.935"/><path d="M5.14 18H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h2.936"/><path d="m11 7-3 5h4l-3 5"/><line x1="22" x2="22" y1="11" y2="13"/>',
  power: '<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.77.04"/>',
  mic: '<path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" x2="12" y1="19" y2="22"/>',
  micOff: '<line x1="2" x2="22" y1="2" y2="22"/><path d="M18.89 13.23A7.12 7.12 0 0 0 19 12v-2h-2.83"/><path d="M5 5v9a7 7 0 0 0 12.71 4"/><path d="M9 9v2a3 3 0 0 0 5.12 2.12"/><path d="M15 9.34V5a3 3 0 0 0-5.68-1.33"/><line x1="12" x2="12" y1="19" y2="22"/>',
  square: '<rect width="18" height="18" x="3" y="3" rx="2"/>',
  pencil: '<path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"/><path d="m15 5 4 4"/>',
  copy: '<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>',
}

function icon(name: string, size = 14): string {
  const body = ICONS[name] || ICONS.fileText
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`
}

function getRelativeTime(isoString: string): string {
  try {
    const diff = Math.floor((Date.now() - new Date(isoString).getTime()) / 1000)
    if (diff < 5) return 'just now'
    if (diff < 60) return `${diff}s ago`
    const mins = Math.floor(diff / 60)
    if (mins < 60) return `${mins}m ago`
    const hours = Math.floor(mins / 60)
    if (hours < 24) return `${hours}h ago`
    const days = Math.floor(hours / 24)
    return `${days}d ago`
  } catch {
    return 'recently'
  }
}

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;')
}

function appInitial(appName: string): string {
  const trimmed = (appName || 'P').trim()
  return escapeHtml(trimmed.charAt(0).toUpperCase() || 'P')
}

// ── Modal dialogs (rendered outside #app so re-renders never wipe them) ────

function ensureModalRoot(): HTMLElement {
  let root = document.getElementById('modal-root')
  if (!root) {
    root = document.createElement('div')
    root.id = 'modal-root'
    document.body.appendChild(root)
  }
  return root
}

function confirmDialog(opts: {
  title: string
  message: string
  confirmLabel?: string
  danger?: boolean
}): Promise<boolean> {
  const root = ensureModalRoot()
  return new Promise((resolve) => {
    const done = (v: boolean) => {
      root.innerHTML = ''
      document.removeEventListener('keydown', onKey)
      resolve(v)
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') done(false)
    }
    document.addEventListener('keydown', onKey)
    root.innerHTML = `
      <div class="modal-backdrop">
        <div class="modal" role="dialog" aria-modal="true">
          <h3 class="modal-title">${escapeHtml(opts.title)}</h3>
          <p class="modal-msg">${escapeHtml(opts.message)}</p>
          <div class="modal-actions">
            <button class="btn cancel" data-m-cancel>Cancel</button>
            <button class="btn confirm ${opts.danger ? 'danger' : ''}" data-m-ok>${escapeHtml(opts.confirmLabel || 'Confirm')}</button>
          </div>
        </div>
      </div>
    `
    root.querySelector('[data-m-cancel]')?.addEventListener('click', () => done(false))
    root.querySelector('[data-m-ok]')?.addEventListener('click', () => done(true))
    root.querySelector('.modal-backdrop')?.addEventListener('click', (e) => {
      if ((e.target as HTMLElement).classList.contains('modal-backdrop')) done(false)
    })
    ;(root.querySelector('[data-m-ok]') as HTMLButtonElement | null)?.focus()
  })
}

function clipTypeIcon(contentType: ClipboardHistoryItem['contentType']): string {
  switch (contentType) {
    case 'url': return icon('link')
    case 'otp': return icon('key')
    case 'email': return icon('mail')
    case 'phone': return icon('phone')
    case 'image': return icon('image')
    default: return icon('fileText')
  }
}

function renderNotificationItem(item: NotificationItem): string {
  const hasReply = item.hasReplyAction
  const draft = replyDrafts[item.notificationId] || ''
  const isSubmitting = !!replySubmitting[item.notificationId]
  const expanded = expandedReplies.has(item.notificationId)

  return `
    <div class="notif-item unread" data-notif-id="${escapeHtml(item.notificationId)}">
      <div class="notif-top">
        <div class="notif-app">
          <span class="app-avatar">${appInitial(item.appName)}</span>
          <span class="app-name">${escapeHtml(item.appName || 'Phone')}</span>
          <span class="notif-time">· ${getRelativeTime(item.timestamp)}</span>
        </div>
        <button
          class="notif-dismiss"
          data-dismiss-id="${escapeHtml(item.notificationId)}"
          title="Dismiss notification"
        >${icon('x', 13)}</button>
      </div>

      ${item.title ? `<div class="notif-title">${escapeHtml(item.title)}</div>` : ''}
      ${item.text ? `<div class="notif-body">${escapeHtml(item.text)}</div>` : ''}

      ${item.replyError
      ? `<div class="reply-error">${escapeHtml(item.replyError)}</div>`
      : ''
    }

      ${hasReply
      ? `
        <button class="reply-toggle" data-reply-toggle="${escapeHtml(item.notificationId)}">
          ${icon('messageCircle', 13)}<span>${expanded ? 'Hide reply' : 'Reply'}</span>
        </button>
        <div class="notif-reply-area ${expanded ? 'expanded' : ''}">
          <input
            type="text"
            class="reply-input"
            data-reply-id="${escapeHtml(item.notificationId)}"
            placeholder="Reply to ${escapeHtml(item.appName || 'notification')}…"
            value="${escapeHtml(draft)}"
          />
          <button
            class="reply-btn"
            data-send-reply-id="${escapeHtml(item.notificationId)}"
            ${isSubmitting ? 'disabled' : ''}
          >
            ${isSubmitting ? 'Sending…' : `${icon('send', 12)}<span>Send</span>`}
          </button>
        </div>
      `
      : ''
    }
    </div>
  `
}

function renderClipboardItem(item: ClipboardHistoryItem): string {
  const typeLabel = (item.contentType || 'text').toUpperCase()

  return `
    <div class="clipboard-item" data-id="${item.id}" title="Click to copy locally">
      <div class="clip-top">
        <span class="clip-type ${item.contentType || 'text'}">${clipTypeIcon(item.contentType)}<span>${typeLabel}</span></span>
      </div>
      ${item.kind === 'image' && item.imageThumbnail
      ? `<div class="clip-image-wrap"><img class="clip-image" src="${item.imageThumbnail}" alt="Clipboard image" /></div>`
      : `<div class="clip-content">${escapeHtml(item.text || '')}</div>`
    }
      <div class="clip-foot">${icon('copy', 11)}<span>Click to copy on this PC</span></div>
    </div>
  `
}

function render(state: StatusResponse) {
  lastStatus = state
  const devices = state.devices || []
  const hasDevices = devices.length > 0
  const isPairing = state.isPairingActive && state.currentPairing
  const pairing = state.currentPairing
  const primary = hasDevices ? devices[0] : null

  const connTitle = !hasDevices
    ? 'No phone linked'
    : (primary!.name || 'Android phone')
  const batteryChip = batteryStatus
    ? `<span class="battery-badge ${batteryStatus.isCharging ? 'charging' : ''} ${!batteryStatus.isCharging && batteryStatus.level <= 20 ? 'low' : ''}">${icon('batteryMedium', 11)}<span>${batteryStatus.level}%${batteryStatus.isCharging ? ' · Charging' : ''}</span></span>`
    : ''
  const connSub = !hasDevices
    ? 'Scan once — then everything is automatic'
    : batteryStatus
      ? `Last sync just now · AES-256 encrypted`
      : 'Encrypted link · AES-256-GCM'

  appEl.innerHTML = `
    <div class="top-bar">
      <div class="top-bar-left">
        <img class="brand-logo" src="/icon.png" alt="Bridge" />
        <span class="brand-name">Bridge</span>
        <span class="conn-pill ${hasDevices ? 'on' : ''}"><span class="dot"></span><span>${hasDevices ? 'Paired' : 'Setup'}</span></span>
      </div>
      <div class="top-bar-right">
        <button class="win-btn" id="btn-minimize" title="Minimize">${icon('minus', 14)}</button>
        <button class="win-btn close" id="btn-close" title="Close">${icon('x', 14)}</button>
      </div>
    </div>

    <div class="scroll">
      <section class="conn-card ${hasDevices ? 'live' : 'idle'}">
        <div class="conn-top">
          <span class="device-avatar ${hasDevices ? '' : 'idle'}">${icon(hasDevices ? 'smartphone' : 'smartphone', 22)}</span>
          <div class="conn-meta">
            <div class="conn-title-row">
              <span class="status-dot ${hasDevices ? 'connected' : ''}"></span>
              <h1 class="conn-title">${escapeHtml(connTitle)}</h1>
            </div>
            <p class="conn-sub">${escapeHtml(connSub)}</p>
          </div>
          <div class="conn-badges">
            ${hasDevices ? `<span class="enc-badge">${icon('shieldCheck', 11)}<span>AES-256</span></span>` : ''}
            ${batteryChip}
          </div>
        </div>
        <div class="conn-note"><span class="note-icon">${icon('check', 13)}</span><span>${hasDevices ? 'Set and forget — notifications, clipboard and files arrive on their own. No need to keep this window open.' : 'Pairing takes under a minute. After that Bridge lives in the tray and syncs quietly.'}</span></div>
      </section>

      ${hasDevices
      ? `
      <div class="eyebrow">Phone as a PC accessory</div>
      <div class="actions">
        <div class="actions-grid">
          <button id="btn-camera" class="action-tile hero"><span class="tile-icon">${icon('camera', 18)}</span><span><p class="tile-title">Phone camera</p><p class="tile-sub">Use as webcam</p></span></button>
          <button id="btn-remote" class="action-tile"><span class="tile-icon">${icon('mouse', 18)}</span><span><p class="tile-title">Remote</p><p class="tile-sub">Trackpad + keys</p></span></button>
          <button id="btn-send-file" class="action-tile"><span class="tile-icon">${icon('fileUp', 18)}</span><span><p class="tile-title">Send file</p><p class="tile-sub">Drop or browse</p></span></button>
          <button id="btn-ring" class="action-tile"><span class="tile-icon">${icon('bell', 18)}</span><span><p class="tile-title">Ring phone</p><p class="tile-sub">Find it fast</p></span></button>
          <!-- MIC PARKED: <button id="btn-mic" class="btn secondary" title="Use Phone as Mic">${icon('mic', 14)}<span>Phone Mic</span></button> -->
        </div>
        <div class="actions-foot">
          <button id="btn-pair-new" class="btn ghost">${icon('plus', 14)}<span>Pair new</span></button>
          <button id="btn-unpair" class="btn danger-ghost"><span>Unpair</span></button>
        </div>
      </div>
      `
      : ''
    }

      ${isPairing && pairing
      ? `
      <div class="eyebrow">Pair a new device</div>
      <div class="qr-card">
        <div class="qr-steps">
          <div class="qr-step"><b>1 · Open</b><span>Bridge app on your phone</span></div>
          <div class="qr-step"><b>2 · Scan</b><span>Tap the QR icon</span></div>
          <div class="qr-step"><b>3 · Done</b><span>Under a minute</span></div>
        </div>
        <div class="qr-img"><img src="${pairing.qrDataUrl}" alt="Pairing QR code" /></div>
        <div class="ip-pill">${icon('wifi', 13)}<span>${pairing.ip}:${pairing.port}</span></div>
        <div class="adapter-select">
          <label for="ip-select">Network interface</label>
          <select id="ip-select">
            ${(pairing.candidates || [])
        .map(
          (c) => `
              <option value="${c.ip}" ${c.ip === pairing.ip ? 'selected' : ''}>
                ${c.name} (${c.ip})${c.hasDefaultGateway ? ' — Gateway' : ''}
              </option>
            `
        )
        .join('')}
          </select>
          <div class="adapter-detail">
            ${pairing.selected
        ? `${escapeHtml(pairing.selected.description || pairing.selected.name)}${pairing.selected.gateway ? ` · Gateway ${escapeHtml(pairing.selected.gateway)}` : ''}`
        : 'Auto-detected active LAN interface'
      }
          </div>
        </div>
        <p class="instruction">
          On your phone, open <strong>Bridge</strong>, tap the <strong>QR icon</strong> and point the camera at this code.
        </p>
      </div>
      `
      : ''
    }

      ${!isPairing && !hasDevices
      ? `
      <div class="empty-state">
        <img class="empty-logo" src="/icon.png" alt="Bridge" />
        <h2>Your phone, on your PC</h2>
        <p>Notifications, clipboard, files and camera — over your own Wi-Fi, encrypted end to end. Nothing leaves your network.</p>
        <button id="btn-start-pair" class="btn primary">${icon('plus', 15)}<span>Show pairing code</span></button>
      </div>
      `
      : ''
    }

      ${hasDevices
      ? `
      <div class="camera-progress" id="camera-progress-container" style="display:none">
        <div class="camera-progress-title">${icon('camera', 13)}<span>Setting up camera support…</span></div>
        <div class="camera-progress-track">
          <div class="camera-progress-fill" id="camera-progress-bar"></div>
        </div>
        <div class="camera-progress-msg" id="camera-progress-message"></div>
      </div>
      <div class="camera-error" id="camera-error-banner" style="display:none">
        <span class="camera-error-text" id="camera-error-text">Camera setup failed — try restarting Bridge</span>
        <button class="camera-error-close" id="camera-error-close">${icon('x', 13)}</button>
      </div>
      <!-- MIC PARKED
      <div class="mic-status" id="mic-status-banner" style="display:none">
        <span class="mic-live-dot" id="mic-live-dot"></span>
        <span class="mic-status-text" id="mic-status-text">Phone microphone live</span>
        <span class="mic-live-badge">Live</span>
        <button class="mic-stop" id="btn-mic-stop">${icon('square', 11)}<span>Stop</span></button>
      </div>
      <audio id="mic-audio" autoplay></audio>
      -->
      `
      : ''
    }

      <div class="file-progress" id="file-progress-container" style="display:none">
        <div class="file-progress-name" id="file-progress-name"></div>
        <div class="file-progress-track">
          <div class="file-progress-fill" id="file-progress-bar"></div>
        </div>
        <div class="file-progress-label" id="file-progress-label"></div>
      </div>

      <div class="segmented">
        <button class="segment ${activeTab === 'notifications' ? 'active' : ''}" data-tab="notifications">
          ${icon('bell', 13)}<span>Notifications</span>
          ${notificationsList.length > 0 ? `<span class="badge">${notificationsList.length}</span>` : ''}
        </button>
        <button class="segment ${activeTab === 'clipboard' ? 'active' : ''}" data-tab="clipboard">
          ${icon('clipboardList', 13)}<span>Clipboard</span>
          ${clipboardHistory.length > 0 ? `<span class="badge">${clipboardHistory.length}</span>` : ''}
        </button>
      </div>

      <div class="eyebrow">Recent activity</div>
      ${activeTab === 'notifications'
      ? `
      <div class="panel">
        <div class="panel-header">
          <span class="panel-title">Phone notifications</span>
          ${notificationsList.length > 0
        ? `<button id="btn-clear-notifications" class="panel-btn">${icon('trash', 12)}<span>Clear all</span></button>`
        : `<span class="panel-count">${notificationsList.length}/20</span>`
      }
        </div>
        <div class="panel-body" id="notifications-list">
          ${notificationsList.length === 0
        ? `<div class="panel-empty"><span class="empty-icon">${icon('bell', 22)}</span><p><strong>All caught up.</strong><br />Phone alerts appear here the moment they arrive — and you can reply without touching your phone.</p></div>`
        : notificationsList.map(renderNotificationItem).join('')
      }
        </div>
      </div>
      `
      : `
      <div class="panel">
        <div class="panel-header">
          <span class="panel-title">Clipboard history</span>
          <span class="panel-count">${clipboardHistory.length}/20</span>
        </div>
        <div class="panel-body" id="history-list">
          ${clipboardHistory.length === 0
        ? `<div class="panel-empty"><span class="empty-icon">${icon('clipboardList', 22)}</span><p><strong>Nothing synced yet.</strong><br />Copy text or an image on either device — it lands here, ready to paste.</p></div>`
        : clipboardHistory.map(renderClipboardItem).join('')
      }
        </div>
      </div>
      `
    }

      <div class="eyebrow">Settings</div>
      <div class="panel settings-card">
        <button class="settings-row" id="btn-auto-launch" title="Launch Bridge automatically when Windows starts">
          <span class="settings-row-icon">${icon('power', 15)}</span>
          <span class="settings-row-text">
            <span class="settings-row-title">Launch at startup</span>
            <span class="settings-row-sub">Start minimized in the tray — sync from boot</span>
          </span>
          <span class="switch ${autoLaunch ? 'on' : ''}" aria-hidden="true"><span class="switch-knob"></span></span>
        </button>
        <button class="settings-row" id="btn-quit-app" title="Fully exit Bridge">
          <span class="settings-row-icon danger">${icon('x', 15)}</span>
          <span class="settings-row-text">
            <span class="settings-row-title">Quit Bridge</span>
            <span class="settings-row-sub">Fully exit — syncing stops until reopened</span>
          </span>
        </button>
        <p class="settings-hint">Closing this window keeps Bridge in the tray so sync never stops. Tip: drag any file onto this window to send it to your phone.</p>
      </div>
      <div class="app-foot">Bridge · local-only · AES-256-GCM encrypted</div>
    </div>

    <div id="drop-overlay" class="drop-overlay ${isDragging ? 'active' : ''}">
      <div class="drop-zone ${hasDevices ? '' : 'unpaired'}">
        <div class="drop-zone-icon-wrap">${icon(hasDevices ? 'fileUp' : 'smartphone', 26)}</div>
        <h2 class="drop-zone-title" id="drop-zone-title">${hasDevices ? `Drop to send to ${escapeHtml(primary?.name || 'Android Device')}` : 'Pair a device first'}</h2>
        <p class="drop-zone-sub" id="drop-zone-sub">${hasDevices ? 'Release to transfer sequentially' : 'Connect your phone to send files'}</p>
        <span class="drop-zone-badge" id="drop-zone-badge">${hasDevices ? `${icon('shieldCheck', 11)}<span>Encrypted · AES-256-GCM</span>` : `${icon('smartphone', 11)}<span>No device paired</span>`}</span>
      </div>
    </div>
  `

  // ── Attach Handlers ────────────────────────────────────────────────────────
  document.querySelector('#btn-minimize')?.addEventListener('click', async () => {
    try { await window.ipcRenderer.invoke('window-minimize') } catch { /* native frame fallback */ }
  })

  document.querySelector('#btn-close')?.addEventListener('click', async () => {
    try { await window.ipcRenderer.invoke('window-close') } catch { window.close() }
  })

  document.querySelector('#camera-error-close')?.addEventListener('click', () => {
    const errorBanner = document.getElementById('camera-error-banner')
    if (errorBanner) errorBanner.style.display = 'none'
  })

  document.querySelector('#btn-camera')?.addEventListener('click', async () => {
    const errorBanner = document.getElementById('camera-error-banner')
    if (errorBanner) errorBanner.style.display = 'none'

    window.ipcRenderer.send('camera-signal-send', { event: 'start-camera' })
    const res = await window.ipcRenderer.invoke('open-camera-window')
    if (res && res.success === false && res.error) {
      showCameraError(res.error)
    }
  })

  document.querySelector('#btn-send-file')?.addEventListener('click', async () => {
    await window.ipcRenderer.invoke('send-file')
  })

  /* MIC PARKED — uncomment to restore Phone-as-Mic buttons.
  document.querySelector('#btn-mic')?.addEventListener('click', () => {
    startMic()
  })

  document.querySelector('#btn-mic-stop')?.addEventListener('click', () => {
    stopMic()
  })

  // Re-apply mic banner/audio state after every re-render (render() rebuilds
  // innerHTML, which would otherwise drop the <audio> srcObject).
  if (micActive) {
    setMicBanner(true)
  }
  attachMicAudio()
  */

  document.querySelector('#btn-ring')?.addEventListener('click', async (e) => {
    const btn = e.currentTarget as HTMLButtonElement
    const label = btn.querySelector('span:last-child')
    const prev = label?.textContent
    try {
      const res = await window.ipcRenderer.invoke('ring-phone') as { success: boolean; error?: string }
      if (res && res.success === false && label) {
        label.textContent = 'Offline'
        setTimeout(() => { if (prev) label.textContent = prev }, 2000)
      }
    } catch {
      if (label && prev) {
        label.textContent = 'Offline'
        setTimeout(() => { label.textContent = prev }, 2000)
      }
    }
  })

  document.querySelector('#btn-remote')?.addEventListener('click', async (e) => {
    const btn = e.currentTarget as HTMLButtonElement
    const label = btn.querySelector('span:last-child')
    const prev = label?.textContent
    try {
      const res = await window.ipcRenderer.invoke('remote-open') as { success: boolean; error?: string }
      if (res && res.success === false) {
        if (label && prev) {
          label.textContent = 'Offline'
          setTimeout(() => { label.textContent = prev }, 2000)
        }
      } else if (label && prev) {
        label.textContent = 'Opening…'
        setTimeout(() => { label.textContent = prev }, 1500)
      }
    } catch {
      if (label && prev) {
        label.textContent = 'Offline'
        setTimeout(() => { label.textContent = prev }, 2000)
      }
    }
  })

  document.querySelector('#ip-select')?.addEventListener('change', async (e) => {
    const newIp = (e.target as HTMLSelectElement).value
    await window.ipcRenderer.invoke('select-ip', newIp)
    refresh()
  })

  document.querySelector('#btn-pair-new')?.addEventListener('click', async () => {
    await window.ipcRenderer.invoke('start-pairing')
    refresh()
  })

  document.querySelector('#btn-unpair')?.addEventListener('click', async () => {
    const ok = await confirmDialog({
      title: 'Unpair this device?',
      message: 'Bridge will forget this phone, delete encryption keys and show a fresh pairing code.',
      confirmLabel: 'Unpair',
      danger: true,
    })
    if (ok) {
      await window.ipcRenderer.invoke('unpair-all')
      refresh()
    }
  })

  document.querySelector('#btn-start-pair')?.addEventListener('click', async () => {
    await window.ipcRenderer.invoke('start-pairing')
    refresh()
  })

  document.querySelector('#btn-clear-notifications')?.addEventListener('click', async () => {
    await window.ipcRenderer.invoke('clear-notifications')
  })

  document.querySelector('#btn-auto-launch')?.addEventListener('click', async () => {
    try {
      const res = (await window.ipcRenderer.invoke('set-auto-launch', !autoLaunch)) as { autoLaunch?: boolean }
      if (res && typeof res.autoLaunch === 'boolean') {
        autoLaunch = res.autoLaunch
        if (lastStatus) render(lastStatus)
      }
    } catch (err) {
      console.error('Failed to update auto-launch setting:', err)
    }
  })

  document.querySelector('#btn-quit-app')?.addEventListener('click', async () => {
    const ok = await confirmDialog({
      title: 'Quit Bridge?',
      message: 'File sync and notifications will stop until you reopen it.',
      confirmLabel: 'Quit',
      danger: true,
    })
    if (ok) {
      try {
        await window.ipcRenderer.invoke('quit-app')
      } catch (err) {
        console.error('Failed to quit Bridge:', err)
      }
    }
  })

  // Segmented tab switching (render-only, no IPC)
  document.querySelectorAll<HTMLButtonElement>('.segment').forEach((btn) => {
    btn.addEventListener('click', () => {
      const tab = btn.getAttribute('data-tab')
      if (tab === 'notifications' || tab === 'clipboard') {
        activeTab = tab
        if (lastStatus) render(lastStatus)
      }
    })
  })

  // Reply toggle (collapsed by default, smooth expand)
  document.querySelectorAll<HTMLButtonElement>('.reply-toggle').forEach((btn) => {
    btn.addEventListener('click', () => {
      const notifId = btn.getAttribute('data-reply-toggle')
      if (!notifId) return
      if (expandedReplies.has(notifId)) {
        expandedReplies.delete(notifId)
      } else {
        expandedReplies.add(notifId)
      }
      if (lastStatus) render(lastStatus)
      // Restore focus to the expanded input
      if (expandedReplies.has(notifId)) {
        const input = document.querySelector<HTMLInputElement>(`.reply-input[data-reply-id="${CSS.escape(notifId)}"]`)
        input?.focus()
      }
    })
  })

  // Dismiss notification buttons
  document.querySelectorAll<HTMLButtonElement>('.notification-dismiss, .notif-dismiss').forEach((btn) => {
    btn.addEventListener('click', async (e) => {
      e.stopPropagation()
      const notifId = btn.getAttribute('data-dismiss-id')
      if (notifId) {
        await window.ipcRenderer.invoke('dismiss-notification', notifId)
      }
    })
  })

  // Reply inputs: remember draft
  document.querySelectorAll<HTMLInputElement>('.reply-input').forEach((input) => {
    const notifId = input.getAttribute('data-reply-id')
    if (!notifId) return

    input.addEventListener('input', () => {
      replyDrafts[notifId] = input.value
    })

    input.addEventListener('keydown', async (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        await submitReply(notifId)
      }
    })
  })

  // Reply buttons: trigger reply
  document.querySelectorAll<HTMLButtonElement>('.reply-btn').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const notifId = btn.getAttribute('data-send-reply-id')
      if (notifId) {
        await submitReply(notifId)
      }
    })
  })

  // History item click to copy locally
  document.querySelectorAll<HTMLDivElement>('.clipboard-item').forEach((el) => {
    el.addEventListener('click', async () => {
      const id = el.getAttribute('data-id')
      const item = clipboardHistory.find((h) => h.id === id)
      if (!item) return

      try {
        await window.ipcRenderer.invoke('copy-history-item', item.id)
        if (!el.querySelector('.clip-copied')) {
          const badge = document.createElement('span')
          badge.className = 'clip-copied'
          badge.innerHTML = `${icon('check', 12)}<span>Copied</span>`
          el.appendChild(badge)
          setTimeout(() => badge.remove(), 1300)
        }
      } catch (err) {
        console.error('Failed to copy history item:', err)
      }
    })
  })
}

async function submitReply(notificationId: string) {
  const text = (replyDrafts[notificationId] || '').trim()
  if (!text) return

  replySubmitting[notificationId] = true
  if (lastStatus) render(lastStatus)

  try {
    await window.ipcRenderer.invoke('send-notification-reply', notificationId, text)
    // Note: If reply fails asynchronously, reply-failed event will set item.replyError
    // Keep draft in case of failure so user doesn't lose their typed message
  } catch (err) {
    console.error('Error invoking send-notification-reply:', err)
  } finally {
    replySubmitting[notificationId] = false
    if (lastStatus) render(lastStatus)
  }
}

function showCameraError(msg: string) {
  const banner = document.getElementById('camera-error-banner')
  const text = document.getElementById('camera-error-text')
  if (banner && text) {
    text.textContent = msg
    banner.style.display = 'flex'
  }
}

async function refresh() {
  try {
    const status = (await window.ipcRenderer.invoke('get-status')) as StatusResponse
    try {
      const history = (await window.ipcRenderer.invoke('get-clipboard-history')) as ClipboardHistoryItem[]
      if (Array.isArray(history)) {
        clipboardHistory = history
      }
    } catch { }

    try {
      const notifs = (await window.ipcRenderer.invoke('get-notifications')) as NotificationItem[]
      if (Array.isArray(notifs)) {
        notificationsList = notifs
      }
    } catch { }

    try {
      const battery = (await window.ipcRenderer.invoke('get-battery-status')) as BatteryStatus | null
      if (battery && typeof battery.level === 'number') {
        batteryStatus = battery
      } else if (battery === null) {
        batteryStatus = null
      }
    } catch { }

    try {
      const settings = (await window.ipcRenderer.invoke('get-app-settings')) as { autoLaunch?: boolean }
      if (settings && typeof settings.autoLaunch === 'boolean') {
        autoLaunch = settings.autoLaunch
      }
    } catch { }

    render(status)
  } catch (e) {
    console.error('Failed to get status:', e)
  }
}

// IPC Listeners
window.ipcRenderer.on('device-paired', () => {
  refresh()
})

window.ipcRenderer.on('pairing-state-changed', () => {
  refresh()
})

window.ipcRenderer.on('clipboard-history-updated', (_event, items: ClipboardHistoryItem[]) => {
  if (Array.isArray(items)) {
    clipboardHistory = items
    if (lastStatus) {
      render(lastStatus)
    }
  }
})

window.ipcRenderer.on('notifications-updated', (_event, items: NotificationItem[]) => {
  if (Array.isArray(items)) {
    notificationsList = items
    if (lastStatus) {
      render(lastStatus)
    }
  }
})

window.ipcRenderer.on('battery-updated', (_event, status: BatteryStatus | null) => {
  batteryStatus = status && typeof status.level === 'number' ? status : null
  if (lastStatus) {
    render(lastStatus)
  }
})

window.ipcRenderer.on('app-settings-changed', (_event, settings: { autoLaunch?: boolean }) => {
  if (settings && typeof settings.autoLaunch === 'boolean') {
    autoLaunch = settings.autoLaunch
    if (lastStatus) {
      render(lastStatus)
    }
  }
})

window.ipcRenderer.on('camera-setup-progress', (_event, progress: { stage: string; percent: number; message: string }) => {
  const container = document.getElementById('camera-progress-container')
  const barEl = document.getElementById('camera-progress-bar')
  const msgEl = document.getElementById('camera-progress-message')
  if (!container || !barEl || !msgEl) return

  if (progress.stage === 'ready' || progress.stage === 'error') {
    if (progress.stage === 'ready') {
      barEl.style.width = '100%'
      msgEl.textContent = 'Camera ready ✓'
      setTimeout(() => {
        container.style.display = 'none'
      }, 1500)
    } else {
      container.style.display = 'none'
      showCameraError(progress.message || 'Camera setup failed — try restarting Bridge')
    }
    return
  }

  container.style.display = 'block'
  barEl.style.width = `${Math.max(5, Math.min(100, progress.percent))}%`
  msgEl.textContent = progress.message
})

window.ipcRenderer.on('camera-error', (_event, data: { error?: string }) => {
  showCameraError(data?.error || 'Camera setup failed — try restarting Bridge')
})

/* MIC PARKED — Phone-as-Microphone signaling (answerer, PC-speaker playback).
   Uncomment to restore.
window.ipcRenderer.on('mic-signal', async (_event, payload: { event: string; sdp?: string; candidate?: RTCIceCandidateInit | null }) => {
  switch (payload.event) {
    case 'offer':
      if (payload.sdp) {
        await handleMicOffer(payload.sdp)
      }
      break
    case 'ice-candidate':
      await handleMicIceCandidate(payload.candidate ?? null)
      break
    case 'stop-mic':
      teardownMicPc()
      setMicBanner(false)
      window.ipcRenderer.send('mic-stopped')
      break
  }
})

window.ipcRenderer.on('mic-stream-ended', () => {
  teardownMicPc()
  setMicBanner(false)
  window.ipcRenderer.send('mic-stopped')
})

window.ipcRenderer.on('mic-status-update', (_event, status: { active: boolean }) => {
  setMicBanner(!!status?.active)
})

window.addEventListener('beforeunload', () => {
  if (micActive) {
    try {
      sendMicSignal({ event: 'stop-mic' })
    } catch {}
    teardownMicPc()
  }
})
*/

window.ipcRenderer.on('file-progress', (_event, progress: FileSendProgress) => {
  const container = document.getElementById('file-progress-container')
  const nameEl = document.getElementById('file-progress-name')
  const barEl = document.getElementById('file-progress-bar')
  const labelEl = document.getElementById('file-progress-label')
  if (!container || !nameEl || !barEl || !labelEl) return

  if (progress.done || progress.error) {
    setTimeout(() => { container.style.display = 'none' }, 2000)
    if (progress.done) {
      barEl.style.width = '100%'
      labelEl.textContent = 'Sent ✓'
    } else {
      labelEl.textContent = `Error: ${progress.error}`
    }
    return
  }

  container.style.display = 'block'
  nameEl.textContent = progress.fileName
  const pct = progress.totalBytes > 0 ? (progress.bytesSent / progress.totalBytes) * 100 : 0
  barEl.style.width = `${pct.toFixed(1)}%`
  const kb = (n: number) => (n / 1024).toFixed(0)
  labelEl.textContent = `${kb(progress.bytesSent)} / ${kb(progress.totalBytes)} KB`
})

// Initial load
refresh()

// ── Magic Drop: Drag-and-drop file sending ────────────────────────────────────

function updateDropZoneUI() {
  const overlay = document.getElementById('drop-overlay')
  const zone = overlay?.querySelector('.drop-zone')
  const iconWrap = overlay?.querySelector('.drop-zone-icon-wrap')
  const titleEl = document.getElementById('drop-zone-title')
  const subEl = document.getElementById('drop-zone-sub')
  const badgeEl = document.getElementById('drop-zone-badge')
  if (!overlay || !zone || !titleEl || !subEl || !badgeEl || !iconWrap) return

  const hasDevices = (lastStatus?.devices?.length ?? 0) > 0
  const device = hasDevices ? lastStatus!.devices[0] : null
  const deviceName = device?.name || 'Android Device'

  if (hasDevices) {
    zone.classList.remove('unpaired')
    iconWrap.innerHTML = icon('fileUp', 26)
    titleEl.textContent = `Drop to send to ${deviceName}`
    subEl.textContent = 'Release to transfer sequentially'
    badgeEl.innerHTML = `${icon('shieldCheck', 11)}<span>Encrypted · AES-256-GCM</span>`
  } else {
    zone.classList.add('unpaired')
    iconWrap.innerHTML = icon('smartphone', 26)
    titleEl.textContent = 'Pair a device first'
    subEl.textContent = 'Connect your phone to send files'
    badgeEl.innerHTML = `${icon('smartphone', 11)}<span>No device paired</span>`
  }
}

window.addEventListener('dragenter', (e) => {
  e.preventDefault()
  if (!e.dataTransfer?.types?.includes('Files')) return
  dragCounter++
  if (dragCounter === 1) {
    isDragging = true
    updateDropZoneUI()
    const overlay = document.getElementById('drop-overlay')
    overlay?.classList.add('active')
  }
})

window.addEventListener('dragover', (e) => {
  e.preventDefault()
  if (e.dataTransfer) {
    const hasDevices = (lastStatus?.devices?.length ?? 0) > 0
    e.dataTransfer.dropEffect = hasDevices ? 'copy' : 'none'
  }
})

window.addEventListener('dragleave', (e) => {
  e.preventDefault()
  dragCounter--
  if (dragCounter <= 0) {
    dragCounter = 0
    isDragging = false
    const overlay = document.getElementById('drop-overlay')
    overlay?.classList.remove('active')
  }
})

window.addEventListener('dragend', () => {
  dragCounter = 0
  isDragging = false
  const overlay = document.getElementById('drop-overlay')
  overlay?.classList.remove('active')
})

window.addEventListener('blur', () => {
  dragCounter = 0
  isDragging = false
  const overlay = document.getElementById('drop-overlay')
  overlay?.classList.remove('active')
})

window.addEventListener('drop', async (e) => {
  e.preventDefault()
  dragCounter = 0
  isDragging = false
  const overlay = document.getElementById('drop-overlay')
  overlay?.classList.remove('active')

  const hasDevices = (lastStatus?.devices?.length ?? 0) > 0
  if (!hasDevices) {
    // Drop ignored when unpaired — overlay already warned the user to pair first
    return
  }

  const files = Array.from(e.dataTransfer?.files || [])
  const filePaths: string[] = []
  for (const file of files) {
    const p = (file as any).path
    if (typeof p === 'string' && p.length > 0) {
      filePaths.push(p)
    }
  }

  if (filePaths.length > 0) {
    try {
      await window.ipcRenderer.invoke('send-file', filePaths)
    } catch (err) {
      console.error('Failed to send dropped files:', err)
    }
  }
})
