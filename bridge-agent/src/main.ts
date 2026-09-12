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

const appEl = document.querySelector<HTMLDivElement>('#app')!
let clipboardHistory: ClipboardHistoryItem[] = []
let notificationsList: NotificationItem[] = []
let replyDrafts: Record<string, string> = {}
let replySubmitting: Record<string, boolean> = {}
let lastStatus: StatusResponse | null = null

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

function renderNotificationItem(item: NotificationItem): string {
  const hasReply = item.hasReplyAction
  const draft = replyDrafts[item.notificationId] || ''
  const isSubmitting = !!replySubmitting[item.notificationId]

  return `
    <div class="notification-item" data-notif-id="${escapeHtml(item.notificationId)}">
      <div class="notification-top">
        <div class="notification-app">
          <span class="notification-app-icon">💬</span>
          <span class="notification-app-name">${escapeHtml(item.appName || 'Phone')}</span>
          <span class="notification-time">${getRelativeTime(item.timestamp)}</span>
        </div>
        <button
          class="notification-dismiss"
          data-dismiss-id="${escapeHtml(item.notificationId)}"
          title="Dismiss notification"
        >✕</button>
      </div>

      ${item.title ? `<div class="notification-title">${escapeHtml(item.title)}</div>` : ''}
      ${item.text ? `<div class="notification-body">${escapeHtml(item.text)}</div>` : ''}

      ${
        item.replyError
          ? `<div class="reply-error-badge">⚠️ ${escapeHtml(item.replyError)}</div>`
          : ''
      }

      ${
        hasReply
          ? `
        <div class="notification-reply-box">
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
            ${isSubmitting ? 'Sending…' : 'Reply'}
          </button>
        </div>
      `
          : ''
      }
    </div>
  `
}

function render(state: StatusResponse) {
  lastStatus = state
  const hasDevices = state.devices.length > 0
  const isPairing = state.isPairingActive && state.currentPairing
  const pairing = state.currentPairing

  appEl.innerHTML = `
    <div class="header">
      <div class="title-row">
        <h1>Bridge Agent</h1>
      </div>
      <div class="badge ${hasDevices ? 'active' : ''}">
        ${hasDevices ? '● AES-256-GCM Active' : '○ Pairing Mode'}
      </div>
    </div>

    ${
      isPairing && pairing
        ? `
      <div class="card">
        <div class="qr-container">
          <img class="qr-image" src="${pairing.qrDataUrl}" alt="Pairing QR Code" />
        </div>
        
        <div class="ip-pill">
          <span>LAN:</span> ${pairing.ip}:${pairing.port}
        </div>

        <div class="adapter-selector">
          <label class="adapter-label" for="ip-select">Network Interface</label>
          <select id="ip-select" class="interface-dropdown">
            ${(pairing.candidates || [])
              .map(
                (c) => `
              <option value="${c.ip}" ${c.ip === pairing.ip ? 'selected' : ''}>
                ${c.name} (${c.ip}) ${c.hasDefaultGateway ? '★ Gateway' : ''}
              </option>
            `
              )
              .join('')}
          </select>
          <div class="interface-details">
            ${
              pairing.selected
                ? `${pairing.selected.description || pairing.selected.name} ${
                    pairing.selected.gateway ? `• Gateway: ${pairing.selected.gateway}` : ''
                  }`
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

    ${
      hasDevices
        ? `
      <div class="paired-card">
        <div class="success-icon">✓</div>
        <h2 class="paired-title">Paired Device</h2>
        <div class="device-info">
          <span class="device-name">${state.devices[0].name || 'Android Device'}</span>
          <span class="device-id">${state.devices[0].deviceId.slice(0, 8)}...</span>
        </div>
        <p class="instruction">
          Encrypted tunnel established. Clipboard & notification synchronization active.
        </p>
        <div id="camera-progress-container" class="camera-progress-container" style="display:none">
          <div class="camera-progress-title">📷 Setting up camera support…</div>
          <div class="camera-progress-bar-track">
            <div class="camera-progress-bar-fill" id="camera-progress-bar"></div>
          </div>
          <div class="camera-progress-message" id="camera-progress-message"></div>
        </div>
        <div id="camera-error-banner" class="camera-error-banner" style="display:none">
          <span class="camera-error-text" id="camera-error-text">Camera setup failed — try restarting Bridge</span>
          <button class="camera-error-close" id="camera-error-close">✕</button>
        </div>
        <div id="file-progress-container" class="file-progress-container" style="display:none">
          <div class="file-progress-name" id="file-progress-name"></div>
          <div class="file-progress-bar-track">
            <div class="file-progress-bar-fill" id="file-progress-bar"></div>
          </div>
          <div class="file-progress-label" id="file-progress-label"></div>
        </div>
        <div class="actions">
          <button id="btn-camera" class="secondary">📷 Phone Camera</button>
          <button id="btn-send-file" class="secondary">📤 Send File</button>
          <button id="btn-pair-new" class="secondary">Pair New Device</button>
          <button id="btn-unpair" class="danger">Unpair</button>
        </div>
      </div>
    `
        : ''
    }

    ${
      !isPairing && !hasDevices
        ? `
      <div class="card">
        <p class="instruction">No devices paired.</p>
        <button id="btn-start-pair" style="margin-top: 16px;">Generate Pairing QR</button>
      </div>
    `
        : ''
    }

    <!-- ── Phone Notifications Card ──────────────────────────────── -->
    <div class="notifications-card">
      <div class="notifications-header">
        <div class="notifications-title">
          <span>🔔 Phone Notifications</span>
          <span class="notifications-count">${notificationsList.length}/20</span>
        </div>
        ${
          notificationsList.length > 0
            ? '<button id="btn-clear-notifications" class="text-btn">Clear all</button>'
            : ''
        }
      </div>
      <div class="notifications-list" id="notifications-list">
        ${
          notificationsList.length === 0
            ? '<div class="notifications-empty">No notifications from phone yet.<br>Incoming alerts will appear here in real-time.</div>'
            : notificationsList.map(renderNotificationItem).join('')
        }
      </div>
    </div>

    <!-- ── Clipboard History Card ────────────────────────────────────── -->
    <div class="history-card">
      <div class="history-header">
        <div class="history-title">
          <span>📋 Clipboard History</span>
          <span class="history-count">${clipboardHistory.length}/20</span>
        </div>
      </div>
      <div class="history-list" id="history-list">
        ${
          clipboardHistory.length === 0
            ? '<div class="history-empty">No clipboard items recorded yet.<br>Copy text on Windows or Android to sync.</div>'
            : clipboardHistory
                .map(
                  (item) => `
            <div class="history-item" data-id="${item.id}" title="Click to copy locally">
              <div class="history-item-top">
                <span class="history-origin ${item.origin}">
                  ${item.origin === 'android' ? '📱 Android' : '💻 Windows'}
                </span>
                <div class="history-time-wrap">
                  ${item.contentType ? `<span class="history-content-type type-${item.contentType}">${item.contentType.toUpperCase()}</span>` : ''}
                  <span class="history-time">${getRelativeTime(item.timestamp)}</span>
                </div>
              </div>
              ${
                item.kind === 'image' && item.imageThumbnail
                  ? `<div class="history-image-container"><img class="history-thumbnail" src="${item.imageThumbnail}" alt="Clipboard Image" /></div>`
                  : `<div class="history-text">${escapeHtml(item.text || '')}</div>`
              }
            </div>
          `
                )
                .join('')
        }
      </div>
    </div>
  `

  // ── Attach Handlers ────────────────────────────────────────────────────────
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

  // Dismiss notification buttons
  document.querySelectorAll<HTMLButtonElement>('.notification-dismiss').forEach((btn) => {
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
  document.querySelectorAll<HTMLDivElement>('.history-item').forEach((el) => {
    el.addEventListener('click', async () => {
      const id = el.getAttribute('data-id')
      const item = clipboardHistory.find((h) => h.id === id)
      if (!item) return

      try {
        await window.ipcRenderer.invoke('copy-history-item', item.id)
        const timeWrap = el.querySelector('.history-time-wrap')
        if (timeWrap) {
          const prevHtml = timeWrap.innerHTML
          timeWrap.innerHTML = '<span class="history-copied-badge">Copied! ✓</span>'
          setTimeout(() => {
            timeWrap.innerHTML = prevHtml
          }, 1500)
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
    } catch {}

    try {
      const notifs = (await window.ipcRenderer.invoke('get-notifications')) as NotificationItem[]
      if (Array.isArray(notifs)) {
        notificationsList = notifs
      }
    } catch {}

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
