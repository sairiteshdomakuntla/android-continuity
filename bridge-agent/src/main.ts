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
let replyDrafts: Record<string, string> = {}
let replySubmitting: Record<string, boolean> = {}
let lastStatus: StatusResponse | null = null

// ── Render-only UI state (no IPC/backend impact) ─────────────────────────────
let activeTab: 'notifications' | 'clipboard' = 'notifications'
const expandedReplies = new Set<string>()

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
  send: '<path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/>',
  trash: '<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
  fileText: '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>',
  shieldCheck: '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/>',
  sprout: '<path d="M7 20h10"/><path d="M10 20c5.5-2.5.8-6.4 3-10"/><path d="M9.5 9.4c1.1.8 1.8 2.2 2.3 3.7-2 .4-3.5.4-4.8-.3-1.2-.6-2.3-1.9-3-4.2 2.8-.5 4.4 0 5.5.8z"/><path d="M14.1 6a7 7 0 0 0-1.1 4c1.9-.1 3.3-.6 4.3-1.4 1-1 1.6-2.3 1.7-4.6-3.2.3-4.3 1-4.9 2z"/>',
  wifi: '<path d="M12 20h.01"/><path d="M2 8.82a15 15 0 0 1 20 0"/><path d="M5 12.859a10 10 0 0 1 14 0"/><path d="M8.5 16.429a5 5 0 0 1 7 0"/>',
  batteryMedium: '<rect width="16" height="10" x="2" y="7" rx="2" ry="2"/><line x1="22" x2="22" y1="11" y2="13"/><line x1="6" x2="6" y1="11" y2="13"/><line x1="10" x2="10" y1="11" y2="13"/><line x1="14" x2="14" y1="11" y2="13"/>',
  batteryCharging: '<path d="M14.856 6H16a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.935"/><path d="M5.14 18H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h2.936"/><path d="m11 7-3 5h4l-3 5"/><line x1="22" x2="22" y1="11" y2="13"/>',
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
  const originIcon = item.origin === 'android' ? icon('smartphone', 11) : icon('monitor', 11)
  const originLabel = item.origin === 'android' ? 'Android' : 'Windows'

  return `
    <div class="clipboard-item" data-id="${item.id}" title="Click to copy locally">
      <div class="clip-top">
        <span class="clip-type ${item.contentType || 'text'}">${clipTypeIcon(item.contentType)}<span>${typeLabel}</span></span>
        <span class="clip-origin">${originIcon}<span>${originLabel} · ${getRelativeTime(item.timestamp)}</span></span>
      </div>
      ${item.kind === 'image' && item.imageThumbnail
      ? `<div class="clip-image-wrap"><img class="clip-image" src="${item.imageThumbnail}" alt="Clipboard image" /></div>`
      : `<div class="clip-content">${escapeHtml(item.text || '')}</div>`
    }
    </div>
  `
}

function render(state: StatusResponse) {
  lastStatus = state
  const hasDevices = state.devices.length > 0
  const isPairing = state.isPairingActive && state.currentPairing
  const pairing = state.currentPairing
  const device = hasDevices ? state.devices[0] : null

  appEl.innerHTML = `
    <div class="top-bar">
      <div class="top-bar-left">
        <span class="brand-icon">${icon('sprout', 14)}</span>
        <span class="brand-name">Bridge</span>
      </div>
      <div class="top-bar-right">
        <button class="win-btn" id="btn-minimize" title="Minimize">${icon('minus', 14)}</button>
        <button class="win-btn close" id="btn-close" title="Close">${icon('x', 14)}</button>
      </div>
    </div>

    <div class="scroll">
      <section class="status-hero">
        <div class="status-row">
          <span class="status-dot ${hasDevices ? 'connected' : ''}"></span>
          <h1 class="status-main">${hasDevices ? escapeHtml(device!.name || 'Android Device') : 'Not Connected'}</h1>
        </div>
        ${hasDevices
      ? `<span class="enc-badge">${icon('shieldCheck', 11)}<span>Encrypted · AES-256-GCM</span></span>
        ${batteryStatus
          ? `<span class="battery-badge ${batteryStatus.isCharging ? 'charging' : ''}">${icon(batteryStatus.isCharging ? 'batteryCharging' : 'batteryMedium', 13)}<span>${batteryStatus.level}%${batteryStatus.isCharging ? ' · Charging' : ''}</span></span>`
          : ''
        }`
      : `<p class="status-sub">Pair your phone to start syncing</p>`
    }
      </section>

      ${hasDevices
      ? `
      <div class="actions">
        <button id="btn-camera" class="btn primary">${icon('camera', 15)}<span>Phone Camera</span></button>
        <div class="actions-row">
          <button id="btn-send-file" class="btn secondary">${icon('fileUp', 14)}<span>Send File</span></button>
          <button id="btn-ring" class="btn secondary">${icon('bell', 14)}<span>Ring Phone</span></button>
        </div>
        <div class="actions-row">
          <button id="btn-pair-new" class="btn ghost">${icon('plus', 14)}<span>Pair New</span></button>
          <button id="btn-unpair" class="btn danger-ghost"><span>Unpair</span></button>
        </div>
      </div>
      `
      : ''
    }

      ${isPairing && pairing
      ? `
      <div class="qr-card">
        <div class="qr-img"><img src="${pairing.qrDataUrl}" alt="Pairing QR code" /></div>
        <div class="ip-pill">${icon('wifi', 13)}<span>${pairing.ip}:${pairing.port}</span></div>
        <div class="adapter-select">
          <label for="ip-select">Network Interface</label>
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
          Open <strong>Bridge</strong> on your phone and scan this QR code to establish secure pairing.
        </p>
      </div>
      `
      : ''
    }

      ${!isPairing && !hasDevices
      ? `
      <div class="empty-state">
        <span class="empty-icon">${icon('sprout', 24)}</span>
        <p>No devices paired yet.<br />Generate a QR code to link your phone.</p>
        <button id="btn-start-pair" class="btn primary">${icon('plus', 15)}<span>Generate Pairing QR</span></button>
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

      ${activeTab === 'notifications'
      ? `
      <div class="panel">
        <div class="panel-header">
          <span class="panel-title">Phone Notifications</span>
          ${notificationsList.length > 0
        ? `<button id="btn-clear-notifications" class="panel-btn">${icon('trash', 12)}<span>Clear</span></button>`
        : `<span class="panel-count">${notificationsList.length}/20</span>`
      }
        </div>
        <div class="panel-body" id="notifications-list">
          ${notificationsList.length === 0
        ? `<div class="panel-empty"><span class="empty-icon">${icon('bell', 22)}</span><p>No notifications yet.<br />Incoming phone alerts will appear here.</p></div>`
        : notificationsList.map(renderNotificationItem).join('')
      }
        </div>
      </div>
      `
      : `
      <div class="panel">
        <div class="panel-header">
          <span class="panel-title">Clipboard History</span>
          <span class="panel-count">${clipboardHistory.length}/20</span>
        </div>
        <div class="panel-body" id="history-list">
          ${clipboardHistory.length === 0
        ? `<div class="panel-empty"><span class="empty-icon">${icon('clipboardList', 22)}</span><p>Nothing copied yet.<br />Copy text on either device to sync it.</p></div>`
        : clipboardHistory.map(renderClipboardItem).join('')
      }
        </div>
      </div>
      `
    }
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
    if (confirm('Are you sure you want to unpair this device?')) {
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
