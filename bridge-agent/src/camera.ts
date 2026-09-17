/**
 * camera.ts — Background WebRTC Answerer & Virtual Camera Pipeline.
 *
 * Receives WebRTC video stream from Android phone over LAN, captures each
 * frame at its NATIVE resolution (landscape or portrait — read live from the
 * incoming track, never assumed), and transmits raw top-down RGBA pixel data
 * directly to the main process via IPC ('vcam-frame').
 *
 * Runs completely headlessly in a hidden background worker window so
 * no unwanted popup window appears on the user's desktop.
 */

// ── DOM refs (available if window is ever shown) ──────────────────────────────
const video       = (document.getElementById('cam-video') as HTMLVideoElement) || document.createElement('video')
const statusDot   = document.getElementById('status-dot') as HTMLDivElement | null
const statusText  = document.getElementById('status-text') as HTMLSpanElement | null
const waitOverlay = document.getElementById('waiting-overlay') as HTMLDivElement | null
const endedOverlay = document.getElementById('ended-overlay') as HTMLDivElement | null
const liveBadge   = document.getElementById('live-badge') as HTMLDivElement | null
const btnStop     = document.getElementById('btn-stop') as HTMLButtonElement | null
const btnClose    = document.getElementById('btn-close') as HTMLButtonElement | null

// Ensure video element plays automatically without audio
video.autoplay = true
video.muted = true
;(video as any).playsInline = true

// ── ICE configuration ─────────────────────────────────────────────────────────
const ICE_CONFIG: RTCConfiguration = {
  iceServers: [
    { urls: 'stun:stun.l.google.com:19302' },
  ],
}

// ── Frame capture constants ──────────────────────────────────────────────────
// Fallback canvas size used only before the first real frame dimensions are
// known. The live canvas ALWAYS tracks the actual incoming track dimensions
// (see ensureCanvas) — never assume landscape.
const FALLBACK_WIDTH  = 1280
const FALLBACK_HEIGHT = 720
const TARGET_FPS     = 30

// Max frames pushed over IPC per second. This is an ANTI-BURST cap, not the
// output clock: pushes may run slightly faster than realtime (up to ~40fps)
// so the main-process mailbox always holds a fresh frame, while a steady 30fps
// writer there enforces even output cadence. A frame arriving too soon is
// dropped as stale BEFORE any expensive drawImage/getImageData work — the NEXT
// tick delivers the freshest frame. This latest-only behavior is what prevents
// freeze-then-fast-forward bursts.
const SEND_INTERVAL_MS = 25

// Capture size cap (long side, pixels). Full-size GPU readbacks in a hidden
// window stall unpredictably (5–50ms spikes), and every downstream stage
// (IPC bytes, row flip, shared-mem write, filter convert) scales with pixels.
// Capping to 960 (e.g. 720x1280 → 540x960, 1280x720 → 960x540) roughly halves
// per-frame cost and readback variance; remote apps display ~640px wide anyway,
// so visible quality loss is negligible while motion gets markedly smoother.
const MAX_LONG_SIDE = 960

// ── State ─────────────────────────────────────────────────────────────────────
let pc: RTCPeerConnection | null = null
let isLive = false
let captureActive = false
let captureCanvas: OffscreenCanvas | null = null
let captureCtx: OffscreenCanvasRenderingContext2D | null = null
let canvasTimer: ReturnType<typeof setInterval> | null = null
let trackReader: ReadableStreamDefaultReader<any> | null = null
let totalFramesSent = 0
let lastFpsLog = performance.now()
let intervalFrameCount = 0
let lastSendTime = 0
let staleDropped = 0

let isRemoteDescriptionSet = false
let pendingCandidates: RTCIceCandidateInit[] = []

// Last seen source dimensions — logged when they change so orientation or
// renegotiation switches (landscape ↔ portrait) are visible in the console.
let lastSrcW = 0
let lastSrcH = 0

// ── Diagnostics (timing/stats probes — logging only, no behavior change) ────

// Per-frame stage timing: drawImage+getImageData ("capture") and the IPC
// bridge send ("send"), averaged over TIMING_WINDOW sent frames. Max is
// tracked too — for smoothness, spikes matter more than averages.
let capAccumMs = 0
let capMaxMs = 0
let sendAccumMs = 0
let sendMaxMs = 0
let timedFrames = 0
const TIMING_WINDOW = 90

function noteTimings(capMs: number, sendMs: number): void {
  capAccumMs += capMs
  sendAccumMs += sendMs
  if (capMs > capMaxMs) capMaxMs = capMs
  if (sendMs > sendMaxMs) sendMaxMs = sendMs
  timedFrames++
  if (timedFrames >= TIMING_WINDOW) {
    console.log(`[Camera] DIAG stage-time avg over ${timedFrames} sent frames: capture(draw+read)=${(capAccumMs / timedFrames).toFixed(2)}ms (max ${capMaxMs.toFixed(1)}ms) | ipcSend=${(sendAccumMs / timedFrames).toFixed(2)}ms (max ${sendMaxMs.toFixed(1)}ms) | 30fps budget=33.3ms`)
    capAccumMs = sendAccumMs = capMaxMs = sendMaxMs = timedFrames = 0
  }
}

// Inbound WebRTC stats: the ground truth of what the phone/network delivers,
// independent of everything downstream. Polled every STATS_INTERVAL_MS while
// capturing; per-second rates come from counter deltas (authoritative)
// alongside Chrome's own framesPerSecond when present.
const STATS_INTERVAL_MS = 3000
let statsTimer: ReturnType<typeof setInterval> | null = null
let prevInbound: { t: number; received: number; decoded: number; dropped: number } | null = null

async function logInboundStats(): Promise<void> {
  if (!pc) return
  try {
    const stats = await pc.getStats()
    let found: any = null
    stats.forEach((report: any) => {
      if (report.type === 'inbound-rtp' && (report.kind === 'video' || report.mediaType === 'video')) {
        found = report
      }
    })
    if (!found) {
      console.warn('[Camera] DIAG webrtc: getStats() returned no video inbound-rtp report (stream may carry no video yet)')
      return
    }
    const now = performance.now()
    const received: number = found.framesReceived ?? 0
    const decoded: number = found.framesDecoded ?? 0
    const dropped: number = found.framesDropped ?? 0
    let rates = 'rates=n/a(first sample)'
    if (prevInbound) {
      const dt = (now - prevInbound.t) / 1000
      if (dt > 0) {
        rates = `recv=${((received - prevInbound.received) / dt).toFixed(1)}/s decode=${((decoded - prevInbound.decoded) / dt).toFixed(1)}/s drop=${((dropped - prevInbound.dropped) / dt).toFixed(1)}/s over ${dt.toFixed(1)}s`
      }
    }
    prevInbound = { t: now, received, decoded, dropped }
    const jitter = typeof found.jitter === 'number' ? found.jitter.toFixed(3) : (found.jitter ?? '?')
    console.log(`[Camera] DIAG webrtc inbound video: ${rates} | totals: received=${received} decoded=${decoded} dropped=${dropped} | chromeFps=${found.framesPerSecond ?? '?'} size=${found.frameWidth ?? '?'}x${found.frameHeight ?? '?'} jitter=${jitter}s freezes=${found.freezeCount ?? '?'} pli=${found.pliCount ?? '?'} nack=${found.nackCount ?? '?'}`)
  } catch (err) {
    console.warn('[Camera] DIAG webrtc: getStats() failed:', err)
  }
}

function startStatsPoller(): void {
  if (statsTimer) clearInterval(statsTimer)
  prevInbound = null
  statsTimer = setInterval(() => { logInboundStats() }, STATS_INTERVAL_MS)
}

function stopStatsPoller(): void {
  if (statsTimer) {
    clearInterval(statsTimer)
    statsTimer = null
  }
  prevInbound = null
}

// ── UI helpers ────────────────────────────────────────────────────────────────
function setWaiting() {
  isLive = false
  if (statusDot) statusDot.classList.remove('live')
  if (statusText) {
    statusText.classList.remove('live')
    statusText.textContent = 'Waiting for Android…'
  }
  if (waitOverlay) waitOverlay.classList.remove('hidden')
  if (endedOverlay) endedOverlay.classList.remove('visible')
  if (liveBadge) liveBadge.classList.remove('visible')
  video.srcObject = null
}

function setLive() {
  isLive = true
  if (statusDot) statusDot.classList.add('live')
  if (statusText) {
    statusText.classList.add('live')
    statusText.textContent = 'Streaming live'
  }
  if (waitOverlay) waitOverlay.classList.add('hidden')
  if (endedOverlay) endedOverlay.classList.remove('visible')
  if (liveBadge) liveBadge.classList.add('visible')

  // Notify main process camera is live
  window.ipcRenderer.send('camera-live')
}

function setEnded(reason = 'Stream ended') {
  isLive = false
  stopCapture()
  if (statusDot) statusDot.classList.remove('live')
  if (statusText) {
    statusText.classList.remove('live')
    statusText.textContent = reason
  }
  if (waitOverlay) waitOverlay.classList.add('hidden')
  if (endedOverlay) endedOverlay.classList.add('visible')
  if (liveBadge) liveBadge.classList.remove('visible')
  video.srcObject = null

  // Tell main process to stop the virtual camera (→ no-signal state)
  window.ipcRenderer.send('vcam-stop')
}

// ── Frame capture pipeline ───────────────────────────────────────────────────

function initCapture() {
  ensureCanvas(FALLBACK_WIDTH, FALLBACK_HEIGHT)
}

/**
 * Pacer gate: returns true (and stamps the send time) when a frame may be
 * pushed, false when this frame should be skipped as stale. Call BEFORE doing
 * expensive drawImage/getImageData work so denied frames cost ~nothing.
 */
function pacerDue(): boolean {
  const now = performance.now()
  if (totalFramesSent > 0 && now - lastSendTime < SEND_INTERVAL_MS) {
    staleDropped++
    return false
  }
  lastSendTime = now
  return true
}

/**
 * Maps native source dims to capture dims: aspect preserved, long side capped
 * at MAX_LONG_SIDE, width snapped to multiples of 4 (UnityCapture requirement)
 * and height to even. Sources at/below the cap pass through untouched.
 */
function captureDims(srcW: number, srcH: number): { w: number; h: number } {
  const longSide = Math.max(srcW, srcH)
  if (longSide <= MAX_LONG_SIDE) return { w: srcW, h: srcH }
  const scale = MAX_LONG_SIDE / longSide
  const w = Math.max(4, Math.floor((srcW * scale) / 4) * 4)
  const h = Math.max(2, Math.floor((srcH * scale) / 2) * 2)
  return { w, h }
}

/**
 * Sizes the capture canvas to the given capture dimensions (see captureDims).
 * Recreates the canvas whenever they change (camera flip, orientation change,
 * renegotiation, cap adjustments) so drawImage() never stretches, shears, or
 * crops the source. Logs every change with orientation for diagnosis.
 *
 * NOTE: resizing (or recreating) a canvas resets its 2D context, so the
 * context is always (re)acquired here together with the canvas.
 */
function ensureCanvas(w: number, h: number): boolean {
  if (!w || !h) return false
  if (captureCanvas && captureCtx && captureCanvas.width === w && captureCanvas.height === h) return true
  captureCanvas = new OffscreenCanvas(w, h)
  captureCtx = captureCanvas.getContext('2d', { willReadFrequently: true }) as OffscreenCanvasRenderingContext2D | null
  if (!captureCtx) {
    console.error('[Camera] Failed to acquire 2D context for capture canvas!')
    captureCanvas = null
    return false
  }
  console.log(`[Camera] Capture canvas → ${w}x${h} (${w >= h ? 'landscape' : 'portrait'})`)
  return true
}

/**
 * Starts frame extraction from the active WebRTC video track.
 * Prefers WebCodecs MediaStreamTrackProcessor for direct hardware frame decoding.
 * Falls back to an OffscreenCanvas interval loop.
 */
async function startFrameCapture(stream: MediaStream) {
  if (captureActive) return
  captureActive = true
  initCapture()

  const videoTrack = stream.getVideoTracks()[0]
  if (!videoTrack) {
    console.warn('[Camera] No video track available in stream!')
    return
  }

  console.log('[Camera] Starting frame capture for track:', videoTrack.label || 'WebRTC Video Track')

  // Ground-truth delivery stats while capturing (see DIAG webrtc logs).
  startStatsPoller()

  // 1. Try WebCodecs MediaStreamTrackProcessor (fastest, zero DOM, background safe)
  if (typeof (window as any).MediaStreamTrackProcessor !== 'undefined') {
    try {
      console.log('[Camera] Initializing MediaStreamTrackProcessor (WebCodecs)...')
      const processor = new (window as any).MediaStreamTrackProcessor({ track: videoTrack })
      const reader = processor.readable.getReader()
      trackReader = reader

      runWebCodecsLoop(reader)
      return
    } catch (err) {
      console.warn('[Camera] MediaStreamTrackProcessor initialization failed, falling back to canvas:', err)
    }
  }

  // 2. Fallback: High-precision canvas capture with setInterval
  runCanvasLoop()
}

async function runWebCodecsLoop(reader: ReadableStreamDefaultReader<any>) {
  console.log('[Camera] WebCodecs hardware capture loop active')
  initCapture()

  while (captureActive && isLive) {
    let videoFrame: any = null
    try {
      const { done, value } = await reader.read()
      if (done || !value) break
      videoFrame = value

      if (captureCtx && captureCanvas) {
        // Native capture (aspect preserved, long side capped — see captureDims):
        // skip ALL expensive work when the pacer denies, so denied frames cost
        // ~nothing and the next tick delivers the freshest frame.
        const srcW = (videoFrame.displayWidth || (videoFrame as any).codedWidth || 0) as number
        const srcH = (videoFrame.displayHeight || (videoFrame as any).codedHeight || 0) as number
        if (srcW !== lastSrcW || srcH !== lastSrcH) {
          lastSrcW = srcW
          lastSrcH = srcH
          const d = captureDims(srcW, srcH)
          console.log(`[Camera] Source frame: ${srcW}x${srcH} (${srcW >= srcH ? 'landscape' : 'portrait'}) → capture ${d.w}x${d.h}`)
        }
        if (!pacerDue()) continue
        const { w, h } = captureDims(srcW, srcH)
        if (!ensureCanvas(w, h)) continue
        const tCap0 = performance.now()
        captureCtx.drawImage(videoFrame, 0, 0, w, h)
        const imgData = captureCtx.getImageData(0, 0, captureCanvas.width, captureCanvas.height)
        const capMs = performance.now() - tCap0
        onFrameReady(imgData.data.buffer, captureCanvas.width, captureCanvas.height, capMs)
      }
    } catch (err) {
      if (!captureActive) break
      console.warn('[Camera] WebCodecs frame processing error:', err)
    } finally {
      if (videoFrame) {
        try { videoFrame.close() } catch (_) {}
      }
    }
  }

  console.log('[Camera] WebCodecs capture loop ended')
}

function runCanvasLoop() {
  console.log('[Camera] Canvas fallback capture loop active (30 FPS)')
  if (canvasTimer) clearInterval(canvasTimer)
  initCapture()

  canvasTimer = setInterval(() => {
    if (!captureActive || !isLive || !video || video.readyState < 2) return
    if (!video.videoWidth || !video.videoHeight) return

    // Same native capture as the WebCodecs path (aspect preserved, capped).
    const srcW = video.videoWidth
    const srcH = video.videoHeight
    if (srcW !== lastSrcW || srcH !== lastSrcH) {
      lastSrcW = srcW
      lastSrcH = srcH
      const d = captureDims(srcW, srcH)
      console.log(`[Camera] Source frame: ${srcW}x${srcH} (${srcW >= srcH ? 'landscape' : 'portrait'}) → capture ${d.w}x${d.h}`)
    }
    if (!pacerDue()) return
    const { w, h } = captureDims(srcW, srcH)
    if (!ensureCanvas(w, h)) return
    if (!captureCtx || !captureCanvas) return
    const tCap0 = performance.now()
    captureCtx.drawImage(video, 0, 0, w, h)
    const imageData = captureCtx.getImageData(0, 0, captureCanvas.width, captureCanvas.height)
    const capMs = performance.now() - tCap0

    onFrameReady(imageData.data.buffer, captureCanvas.width, captureCanvas.height, capMs)
  }, 1000 / TARGET_FPS)
}

function onFrameReady(arrayBuffer: ArrayBuffer, width: number, height: number, capMs = 0) {
  // Pacing is enforced by the caller via pacerDue() BEFORE capture work, so
  // every frame arriving here is meant to be sent (latest-only, no IPC queue).
  totalFramesSent++
  intervalFrameCount++

  if (totalFramesSent === 1) {
    console.log(`[Camera] === Frame #1 Dispatched to IPC === (${width}x${height} ${width >= height ? 'landscape' : 'portrait'}, ${arrayBuffer.byteLength} bytes)`)
  }

  // Stage 1 probe: every 30th frame, confirm capture is producing non-empty
  // pixel data AND that payload bytes agree with the declared dimensions
  // (width*height*4). A BYTES!=EXPECTED mismatch here means capture and header
  // disagree and sendFrame() will drop the frame — visible without guesswork.
  if (totalFramesSent % 30 === 0) {
    const expected = width * height * 4
    const agree = arrayBuffer.byteLength === expected ? 'DIMS-OK' : `DIM-MISMATCH(expected ${expected})`
    const orient = width >= height ? 'landscape' : 'portrait'
    const sample = new Uint8Array(arrayBuffer, 0, Math.min(64, arrayBuffer.byteLength))
    let nonZero = 0
    for (let i = 0; i < sample.length; i++) if (sample[i] !== 0) nonZero++
    console.log(`[Camera] Stage1 capture: frame #${totalFramesSent} captured ${width}x${height} (${orient}, ${arrayBuffer.byteLength} bytes, ${agree}, sample non-zero: ${nonZero}/${sample.length}) → sending vcam-frame via IPC`)
  }

  const now = performance.now()
  if (now - lastFpsLog >= 3000) {
    const elapsed = (now - lastFpsLog) / 1000
    const fps = (intervalFrameCount / elapsed).toFixed(1)
    console.log(`[Camera] Renderer Sending: ${fps} FPS | Total: ${totalFramesSent} frames sent to virtual camera | stale dropped (pacer): ${staleDropped}`)
    intervalFrameCount = 0
    staleDropped = 0
    lastFpsLog = now
  }

  // Zero-copy handoff: the buffer is transferred (neutered here), never cloned
  // over IPC. Do not touch arrayBuffer after this call. The send itself is
  // timed for the DIAG stage-time probe (capMs measured by the caller).
  const tSend0 = performance.now()
  window.ipcRenderer.sendFrame(width, height, arrayBuffer)
  noteTimings(capMs, performance.now() - tSend0)
}

function stopCapture() {
  captureActive = false
  stopStatsPoller()
  if (canvasTimer) {
    clearInterval(canvasTimer)
    canvasTimer = null
  }
  if (trackReader) {
    trackReader.cancel().catch(() => {})
    trackReader = null
  }
}

// ── RTCPeerConnection management ──────────────────────────────────────────────

function createPeerConnection(): RTCPeerConnection {
  if (pc) teardown()

  const conn = new RTCPeerConnection(ICE_CONFIG)
  pc = conn

  // Send our local ICE candidates to Android via the signaling channel
  conn.onicecandidate = (evt) => {
    console.log('[Camera] onicecandidate:', evt.candidate ? 'candidate gathered' : 'gathering complete')
    window.ipcRenderer.send('camera-signal-send', {
      event: 'ice-candidate',
      candidate: evt.candidate ? evt.candidate.toJSON() : null,
    })
  }

  conn.oniceconnectionstatechange = () => {
    console.log('[Camera] ICE connection state:', conn.iceConnectionState)
    if (conn.iceConnectionState === 'failed' || conn.iceConnectionState === 'disconnected') {
      console.warn('[Camera] ICE disconnected — tearing down')
      teardown()
      setEnded('Connection lost')
    }
  }

  conn.onconnectionstatechange = () => {
    console.log('[Camera] PeerConnection state:', conn.connectionState)
    if (conn.connectionState === 'failed' || conn.connectionState === 'closed') {
      teardown()
      setEnded('Connection lost')
    }
  }

  // Receive the video track from Android
  conn.ontrack = (evt) => {
    console.log('[Camera] ontrack — WebRTC video track received!')
    const stream = (evt.streams && evt.streams[0]) ? evt.streams[0] : new MediaStream([evt.track])
    video.srcObject = stream
    video.play().catch((e) => console.warn('[Camera] video.play() notice:', e))

    setLive()

    // Start frame capture immediately!
    startFrameCapture(stream)
  }

  return conn
}

async function handleOffer(sdp: string): Promise<void> {
  console.log('[Camera] Received offer from Android, creating answer…')
  const conn = createPeerConnection()

  await conn.setRemoteDescription({ type: 'offer', sdp })
  isRemoteDescriptionSet = true

  // Apply any buffered ICE candidates received before remote description was set
  while (pendingCandidates.length > 0) {
    const cand = pendingCandidates.shift()
    if (cand) {
      try {
        await conn.addIceCandidate(new RTCIceCandidate(cand))
        console.log('[Camera] Applied buffered ICE candidate')
      } catch (e) {
        console.warn('[Camera] addIceCandidate error on buffered candidate:', e)
      }
    }
  }

  const answer = await conn.createAnswer()
  await conn.setLocalDescription(answer)

  // Allow up to 600ms for local candidate gathering so host candidates are embedded directly in SDP answer
  if (conn.iceGatheringState !== 'complete') {
    await new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, 600)
      const check = () => {
        if (conn.iceGatheringState === 'complete') {
          clearTimeout(timer)
          conn.removeEventListener('icegatheringstatechange', check)
          resolve()
        }
      }
      conn.addEventListener('icegatheringstatechange', check)
    })
  }

  const sdpToSend = conn.localDescription?.sdp || answer.sdp!
  window.ipcRenderer.send('camera-signal-send', {
    event: 'answer',
    sdp: sdpToSend,
  })
  console.log('[Camera] WebRTC Answer sent to Android')
}

async function handleIceCandidate(candidate: RTCIceCandidateInit | null): Promise<void> {
  if (!candidate) return
  if (!pc || !isRemoteDescriptionSet) {
    console.log('[Camera] Buffering ICE candidate (remote description not set yet)')
    pendingCandidates.push(candidate)
    return
  }

  try {
    await pc.addIceCandidate(new RTCIceCandidate(candidate))
    console.log('[Camera] Applied ICE candidate')
  } catch (e) {
    console.warn('[Camera] addIceCandidate error:', e)
  }
}

function teardown(): void {
  stopCapture()
  isRemoteDescriptionSet = false
  pendingCandidates = []
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
  window.ipcRenderer.send('camera-signal-send', { event: 'stop-camera' })
}

// ── IPC event listeners (signals from main process) ───────────────────────────

window.ipcRenderer.on('camera-signal', async (_event: unknown, payload: { event: string; sdp?: string; candidate?: RTCIceCandidateInit | null }) => {
  console.log('[Camera] Received signal:', payload.event)

  switch (payload.event) {
    case 'offer':
      if (payload.sdp) {
        await handleOffer(payload.sdp)
      }
      break

    case 'ice-candidate':
      await handleIceCandidate(payload.candidate ?? null)
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
  setEnded(data?.error || 'Camera setup failed')
})

// ── Button handlers (if window is displayed) ──────────────────────────────────

btnStop?.addEventListener('click', () => {
  stopStream()
})

btnClose?.addEventListener('click', async () => {
  if (isLive) {
    stopStream()
    await new Promise((r) => setTimeout(r, 200))
  }
  await window.ipcRenderer.invoke('close-camera-window')
})

// ── Initial state & notify worker ready ───────────────────────────────────────
setWaiting()
console.log('[Camera] Background camera worker initialized — awaiting WebRTC offer')
window.ipcRenderer.send('camera-worker-ready')

