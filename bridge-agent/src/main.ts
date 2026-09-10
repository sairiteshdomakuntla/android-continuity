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

interface FileSendProgress {
  transferId: string
  fileName: string
  bytesSent: number
  totalBytes: number
  done: boolean
  error?: string
}

const appEl = document.querySelector<HTMLDivElement>('#app')!

function render(state: StatusResponse) {
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
          Encrypted tunnel established. Clipboard synchronization is active.
        </p>
        <div id="file-progress-container" class="file-progress-container" style="display:none">
          <div class="file-progress-name" id="file-progress-name"></div>
          <div class="file-progress-bar-track">
            <div class="file-progress-bar-fill" id="file-progress-bar"></div>
          </div>
          <div class="file-progress-label" id="file-progress-label"></div>
        </div>
        <div class="actions">
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
  `

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
}

async function refresh() {
  try {
    const status = (await window.ipcRenderer.invoke('get-status')) as StatusResponse
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
