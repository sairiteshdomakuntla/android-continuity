/**
 * camera.ts — Renderer for the floating Bridge Camera window.
 *
 * Acts as the WebRTC ANSWERER:
 *   Android (offerer) → sends offer → we answer → exchange ICE → stream plays
 *
 * All signaling travels through the encrypted SocketService channel via IPC.
 */

// ── DOM refs ──────────────────────────────────────────────────────────────────
const video      = document.getElementById('cam-video')      as HTMLVideoElement
const statusDot  = document.getElementById('status-dot')     as HTMLDivElement
const statusText = document.getElementById('status-text')    as HTMLSpanElement
const waitOverlay = document.getElementById('waiting-overlay') as HTMLDivElement
const endedOverlay = document.getElementById('ended-overlay')  as HTMLDivElement
const liveBadge  = document.getElementById('live-badge')     as HTMLDivElement
const btnStop    = document.getElementById('btn-stop')       as HTMLButtonElement
const btnClose   = document.getElementById('btn-close')      as HTMLButtonElement

// ── ICE configuration ─────────────────────────────────────────────────────────
// Both devices are on the same LAN — host candidates should negotiate directly.
// Google STUN is included as cheap insurance for unusual router/NAT setups.
const ICE_CONFIG: RTCConfiguration = {
  iceServers: [
    { urls: 'stun:stun.l.google.com:19302' },
  ],
}

// ── State ─────────────────────────────────────────────────────────────────────
let pc: RTCPeerConnection | null = null
let isLive = false

// ── UI helpers ────────────────────────────────────────────────────────────────

function setWaiting() {
  isLive = false
  statusDot.classList.remove('live')
  statusText.classList.remove('live')
  statusText.textContent = 'Waiting for Android…'
  waitOverlay.classList.remove('hidden')
  endedOverlay.classList.remove('visible')
  video.classList.remove('active')
  liveBadge.classList.remove('visible')
  video.srcObject = null
}

function setLive() {
  isLive = true
  statusDot.classList.add('live')
  statusText.classList.add('live')
  statusText.textContent = 'Streaming live'
  waitOverlay.classList.add('hidden')
  endedOverlay.classList.remove('visible')
  video.classList.add('active')
  liveBadge.classList.add('visible')
  window.ipcRenderer.send('camera-live')
}

function setEnded(reason = 'Stream ended') {
  isLive = false
  statusDot.classList.remove('live')
  statusText.classList.remove('live')
  statusText.textContent = reason
  waitOverlay.classList.add('hidden')
  endedOverlay.classList.add('visible')
  video.classList.remove('active')
  liveBadge.classList.remove('visible')
  video.srcObject = null
}

// ── RTCPeerConnection management ──────────────────────────────────────────────

function createPeerConnection(): RTCPeerConnection {
  if (pc) teardown()

  const conn = new RTCPeerConnection(ICE_CONFIG)
  pc = conn

  // Send our local ICE candidates to Android via the signaling channel
  conn.onicecandidate = (evt) => {
    console.log('[Camera] onicecandidate:', evt.candidate ? 'candidate' : 'null (gathering done)')
    window.ipcRenderer.send('camera-signal-send', {
      event: 'ice-candidate',
      candidate: evt.candidate ? evt.candidate.toJSON() : null,
    })
  }

  conn.oniceconnectionstatechange = () => {
    console.log('[Camera] ICE state:', conn.iceConnectionState)
    if (conn.iceConnectionState === 'failed' || conn.iceConnectionState === 'disconnected') {
      console.warn('[Camera] ICE failed/disconnected — tearing down')
      teardown()
      setEnded('Connection lost')
    }
  }

  conn.onconnectionstatechange = () => {
    console.log('[Camera] Connection state:', conn.connectionState)
    if (conn.connectionState === 'failed' || conn.connectionState === 'closed') {
      teardown()
      setEnded('Connection lost')
    }
  }

  // Receive the video track from Android
  conn.ontrack = (evt) => {
    console.log('[Camera] ontrack — stream received')
    if (evt.streams && evt.streams[0]) {
      video.srcObject = evt.streams[0]
      video.play().catch((e) => console.warn('[Camera] video.play() error:', e))
      setLive()
    }
  }

  return conn
}

async function handleOffer(sdp: string): Promise<void> {
  console.log('[Camera] Received offer, creating answer…')
  const conn = createPeerConnection()

  await conn.setRemoteDescription({ type: 'offer', sdp })
  const answer = await conn.createAnswer()
  await conn.setLocalDescription(answer)

  window.ipcRenderer.send('camera-signal-send', {
    event: 'answer',
    sdp: answer.sdp!,
  })
  console.log('[Camera] Answer sent')
}

async function handleIceCandidate(candidate: RTCIceCandidateInit | null): Promise<void> {
  if (!pc) return
  if (!candidate) {
    // null candidate = gathering complete on Android side; nothing to do
    return
  }
  try {
    await pc.addIceCandidate(new RTCIceCandidate(candidate))
    console.log('[Camera] Added ICE candidate')
  } catch (e) {
    console.warn('[Camera] addIceCandidate error:', e)
  }
}

function teardown(): void {
  if (pc) {
    pc.ontrack = null
    pc.onicecandidate = null
    pc.oniceconnectionstatechange = null
    pc.onconnectionstatechange = null
    pc.close()
    pc = null
  }
  video.srcObject = null
}

function stopStream(): void {
  teardown()
  setEnded('Stopped')
  // Notify Android to stop camera
  window.ipcRenderer.send('camera-signal-send', { event: 'stop-camera' })
}

async function startLocalPreview() {
  try {
    const devices = await navigator.mediaDevices.enumerateDevices()
    const obsCam = devices.find((d) => d.kind === 'videoinput' && d.label.toLowerCase().includes('obs'))
    const stream = await navigator.mediaDevices.getUserMedia({
      video: obsCam ? { deviceId: { exact: obsCam.deviceId } } : true,
    })
    video.srcObject = stream
    await video.play()
    setLive()
  } catch (err) {
    console.log('[Camera] Desktop preview fallback:', err)
    setLive()
  }
}

// ── IPC event listeners (signals from main process) ───────────────────────────

window.ipcRenderer.on('camera-signal', async (_event: unknown, payload: { event: string; sdp?: string; candidate?: RTCIceCandidateInit | null }) => {
  console.log('[Camera] Received camera-signal:', payload.event)

  switch (payload.event) {
    case 'offer':
      // The OBS Browser Source handles the incoming WebRTC stream directly.
      // The floating desktop window previews the OBS Virtual Camera.
      setTimeout(() => startLocalPreview(), 500)
      break

    case 'stop-camera':
      teardown()
      setEnded('Camera stopped')
      break
  }
})

window.ipcRenderer.on('camera-stream-ended', () => {
  console.log('[Camera] Received camera-stream-ended (socket disconnect)')
  teardown()
  setEnded('Connection lost')
})

window.ipcRenderer.on('camera-error', (_event: unknown, data: { error?: string }) => {
  console.error('[Camera] Received camera-error:', data?.error)
  if (!isLive) {
    setEnded(data?.error || 'Camera setup failed')
  } else {
    statusText.textContent = 'Live (Virtual Cam note: ' + (data?.error || 'setup warning') + ')'
  }
})

// ── Button handlers ────────────────────────────────────────────────────────────

btnStop.addEventListener('click', () => {
  stopStream()
})

btnClose.addEventListener('click', async () => {
  if (isLive) {
    stopStream()
    // Give a brief moment for stop-camera to go out before window closes
    await new Promise((r) => setTimeout(r, 200))
  }
  await window.ipcRenderer.invoke('close-camera-window')
})

// ── Initial state ─────────────────────────────────────────────────────────────
setWaiting()
console.log('[Camera] Camera renderer ready — waiting for WebRTC offer from Android')

