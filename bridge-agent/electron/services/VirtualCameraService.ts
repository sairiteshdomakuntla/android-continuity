/**
 * VirtualCameraService.ts
 *
 * Manages the UnityCapture-based virtual camera:
 *   1. First-run DLL registration (regsvr32) — branded as "Bridge Phone Camera"
 *   2. Shared memory frame writer matching UnityCapture's SharedImageMemory protocol
 *   3. Lifecycle: open shared memory → send frames → stop (→ no-signal state)
 *
 * Uses koffi for Win32 API FFI — no native compilation required.
 */

import { app } from 'electron'
import path from 'node:path'
import fs from 'node:fs'
import { exec } from 'node:child_process'
import { createRequire } from 'node:module'

// ESM-compatible require for loading CJS native modules (koffi).
// The main process is built as ESM (dist-electron/main.js), so bare
// `require()` is not defined at runtime. createRequire(import.meta.url)
// gives us a working require bound to this module.
const _require = createRequire(import.meta.url)

// ---------------------------------------------------------------------------
// Win32 constants
// ---------------------------------------------------------------------------

const INVALID_HANDLE_VALUE = BigInt('0xFFFFFFFFFFFFFFFF') // INVALID_HANDLE_VALUE as pointer
const FALSE = 0
const SYNCHRONIZE = 0x00100000
const EVENT_MODIFY_STATE = 0x0002
const FILE_MAP_WRITE = 0x0002
const PAGE_READWRITE = 0x04
const WAIT_OBJECT_0 = 0

// UnityCapture shared memory constants
const SHARED_HEADER_SIZE = 32 // bytes
const MAX_SHARED_IMAGE_SIZE = 3840 * 2160 * 4 * 2 // ~66MB, 4K RGBA 16-bit
const FRAME_TIMEOUT_MS = 1000 // ms before filter shows "no signal"

// UnityCapture format enum
const FORMAT_UINT8 = 0
const RESIZEMODE_LINEAR = 1
const MIRRORMODE_DISABLED = 0

// Named objects for CapNum 0 (null char terminator for backward compat with old filters).
// Verified against UnityCapture Source/shared.inl: for CapNum 0 the C++ code sets
// CSCapNumChar = '\0', turning "UnityCapture_Mutx0" into "UnityCapture_Mutx\0"
// (i.e. the C string "UnityCapture_Mutx"). The trailing \0 below produces the
// same effective C string when passed as `const char *` via koffi.
const MUTEX_NAME       = 'UnityCapture_Mutx\0'
const EVENT_WANT_NAME  = 'UnityCapture_Want\0'
const EVENT_SENT_NAME  = 'UnityCapture_Sent\0'
const SHARED_DATA_NAME = 'UnityCapture_Data\0'

// Branding
const DEVICE_NAME = 'Bridge Phone Camera'

export interface VirtualCameraSetupProgress {
  stage: 'checking' | 'registering' | 'ready' | 'error'
  percent: number
  message: string
}

// ---------------------------------------------------------------------------
// Koffi Win32 API declarations (lazy-loaded)
// ---------------------------------------------------------------------------

let k: typeof import('koffi')
let _win32: {
  CreateMutexA: (...args: any[]) => any
  OpenMutexA: (...args: any[]) => any
  CreateEventA: (...args: any[]) => any
  OpenEventA: (...args: any[]) => any
  CreateFileMappingA: (...args: any[]) => any
  OpenFileMappingA: (...args: any[]) => any
  MapViewOfFile: (...args: any[]) => any
  UnmapViewOfFile: (...args: any[]) => any
  WaitForSingleObject: (...args: any[]) => any
  ReleaseMutex: (...args: any[]) => any
  SetEvent: (...args: any[]) => any
  CloseHandle: (...args: any[]) => any
  RtlMoveMemory: (...args: any[]) => any
} | null = null

function win32() {
  if (_win32) return _win32

  // NOTE: must use createRequire-based loader — bare require() throws
  // "ReferenceError: require is not defined" in the ESM main bundle.
  k = _require('koffi')
  const kernel32 = k.load('kernel32.dll')

  // HANDLE type as opaque pointer (registered globally for use in func signatures below)
  k.pointer('HANDLE', k.opaque())

  _win32 = {
    CreateMutexA:       kernel32.func('HANDLE __stdcall CreateMutexA(void *lpAttr, int bInitialOwner, const char *lpName)'),
    OpenMutexA:         kernel32.func('HANDLE __stdcall OpenMutexA(uint32_t dwDesiredAccess, int bInheritHandle, const char *lpName)'),
    CreateEventA:       kernel32.func('HANDLE __stdcall CreateEventA(void *lpAttr, int bManualReset, int bInitialState, const char *lpName)'),
    OpenEventA:         kernel32.func('HANDLE __stdcall OpenEventA(uint32_t dwDesiredAccess, int bInheritHandle, const char *lpName)'),
    CreateFileMappingA: kernel32.func('HANDLE __stdcall CreateFileMappingA(HANDLE hFile, void *lpAttr, uint32_t flProtect, uint32_t dwMaxHi, uint32_t dwMaxLo, const char *lpName)'),
    OpenFileMappingA:   kernel32.func('HANDLE __stdcall OpenFileMappingA(uint32_t dwDesiredAccess, int bInheritHandle, const char *lpName)'),
    MapViewOfFile:      kernel32.func('void * __stdcall MapViewOfFile(HANDLE hFileMappingObject, uint32_t dwDesiredAccess, uint32_t dwFileOffsetHi, uint32_t dwFileOffsetLo, uintptr_t dwNumberOfBytes)'),
    UnmapViewOfFile:    kernel32.func('int __stdcall UnmapViewOfFile(void *lpBaseAddress)'),
    WaitForSingleObject:kernel32.func('uint32_t __stdcall WaitForSingleObject(HANDLE hHandle, uint32_t dwMilliseconds)'),
    ReleaseMutex:       kernel32.func('int __stdcall ReleaseMutex(HANDLE hHandle)'),
    SetEvent:           kernel32.func('int __stdcall SetEvent(HANDLE hHandle)'),
    CloseHandle:        kernel32.func('int __stdcall CloseHandle(HANDLE hHandle)'),
    // RtlMoveMemory copies bytes between memory regions — our key tool for writing to shared mem
    RtlMoveMemory:      kernel32.func('void __stdcall RtlMoveMemory(void *Dest, const uint8_t *Src, uintptr_t Length)'),
  }

  console.log('[VirtualCamera] koffi Win32 API bindings loaded')
  return _win32
}

// ---------------------------------------------------------------------------
// Service class
// ---------------------------------------------------------------------------

class VirtualCameraServiceClass {
  private _hMutex: any = null
  private _hWantFrameEvent: any = null
  private _hSentFrameEvent: any = null
  private _hSharedFile: any = null
  private _pSharedBuf: any = null // void* pointer to the mapped view
  private _isOpen = false
  private _progressListeners: ((progress: VirtualCameraSetupProgress) => void)[] = []

  // ── Progress notification ─────────────────────────────────────────────────

  onProgress(listener: (progress: VirtualCameraSetupProgress) => void): () => void {
    this._progressListeners.push(listener)
    return () => {
      this._progressListeners = this._progressListeners.filter((l) => l !== listener)
    }
  }

  private _notifyProgress(stage: VirtualCameraSetupProgress['stage'], percent: number, message: string): void {
    const data: VirtualCameraSetupProgress = { stage, percent, message }
    for (const listener of this._progressListeners) {
      try { listener(data) } catch (err) {
        console.error('[VirtualCamera] Progress listener error:', err)
      }
    }
  }

  // ── DLL paths ──────────────────────────────────────────────────────────────

  private get _dllDir(): string {
    const programData = process.env.ProgramData || 'C:\\ProgramData'
    return path.join(programData, 'Bridge Agent', 'virtual-camera')
  }

  private get _dll64Path(): string {
    return path.join(this._dllDir, 'UnityCaptureFilter64.dll')
  }

  private get _dll32Path(): string {
    return path.join(this._dllDir, 'UnityCaptureFilter32.dll')
  }

  /**
   * Path to bundled DLLs — in dev mode they're in resources/virtual-camera/,
   * in production they're in the app's resources/ via extraResources.
   */
  private get _bundledDllDir(): string {
    if (app.isPackaged) {
      return path.join(process.resourcesPath, 'virtual-camera')
    }
    return path.join(app.getAppPath(), 'resources', 'virtual-camera')
  }

  // ── DLL Registration ───────────────────────────────────────────────────────

  /**
   * Checks whether our virtual camera DLLs have been registered.
   */
  isRegistered(): boolean {
    const markerPath = path.join(this._dllDir, 'registered.json')
    if (!fs.existsSync(markerPath)) return false
    try {
      const data = JSON.parse(fs.readFileSync(markerPath, 'utf8'))
      return data.registered === true && data.deviceName === DEVICE_NAME
    } catch {
      return false
    }
  }

  /**
   * Ensures the DLLs are copied to a stable location and registered with Windows.
   * Idempotent — skips if already registered.
   */
  async ensureRegistered(): Promise<void> {
    this.ensureFriendlyName()
    if (this.isRegistered()) {
      console.log('[VirtualCamera] DLLs already registered as "' + DEVICE_NAME + '"')
      return
    }

    this._notifyProgress('checking', 10, 'Checking virtual camera setup…')

    // 1. Copy DLLs to stable userData location
    fs.mkdirSync(this._dllDir, { recursive: true })

    const bundled64 = path.join(this._bundledDllDir, 'UnityCaptureFilter64.dll')
    const bundled32 = path.join(this._bundledDllDir, 'UnityCaptureFilter32.dll')

    if (fs.existsSync(bundled64)) {
      fs.copyFileSync(bundled64, this._dll64Path)
      console.log('[VirtualCamera] Copied 64-bit DLL to', this._dll64Path)
    }
    if (fs.existsSync(bundled32)) {
      fs.copyFileSync(bundled32, this._dll32Path)
      console.log('[VirtualCamera] Copied 32-bit DLL to', this._dll32Path)
    }

    // 2. Register with regsvr32 (requires admin)
    this._notifyProgress('registering', 40, 'Registering virtual camera (may request admin)…')

    const results: boolean[] = []
    if (fs.existsSync(this._dll64Path)) {
      results.push(await this._registerDll(this._dll64Path))
    }
    if (fs.existsSync(this._dll32Path)) {
      results.push(await this._registerDll(this._dll32Path))
    }

    if (results.length === 0) {
      this._notifyProgress('error', 0, 'Virtual camera DLLs not found')
      throw new Error('UnityCapture DLLs not found in bundled resources')
    }

    if (!results.some(Boolean)) {
      this._notifyProgress('error', 0, 'Failed to register virtual camera — admin access may be required')
      throw new Error('Failed to register UnityCapture DLLs')
    }

    // 3. Write registration marker
    const marker = {
      registered: true,
      deviceName: DEVICE_NAME,
      registeredAt: new Date().toISOString(),
    }
    fs.writeFileSync(path.join(this._dllDir, 'registered.json'), JSON.stringify(marker, null, 2), 'utf8')

    this._notifyProgress('ready', 100, '"' + DEVICE_NAME + '" is ready')
    console.log('[VirtualCamera] Registration complete — device: "' + DEVICE_NAME + '"')
  }

  /**
   * Registers a single DLL with regsvr32 using an elevated PowerShell process.
   * /i:"DeviceName" sets the custom device name, /s suppresses dialogs.
   */
  private _registerDll(dllPath: string): Promise<boolean> {
    return new Promise((resolve) => {
      // regsvr32 command with custom device name via /i:UnityCaptureName= parameter
      const regsvr32Args = `/s /i:UnityCaptureName="${DEVICE_NAME}" "${dllPath}"`

      // Use PowerShell Start-Process with -Verb RunAs for UAC elevation
      const psScript = `Start-Process -FilePath 'regsvr32.exe' -ArgumentList '${regsvr32Args.replace(/'/g, "''")}' -Verb RunAs -Wait -WindowStyle Hidden`

      console.log('[VirtualCamera] Registering DLL:', dllPath)

      exec(`powershell -NoProfile -Command "${psScript.replace(/"/g, '\\"')}"`, {
        timeout: 30000,
        windowsHide: true,
      }, (err, _stdout, stderr) => {
        if (err) {
          console.warn('[VirtualCamera] Elevated registration warning:', err.message, stderr)
          // Fallback: try without elevation (works if Bridge is already running as admin)
          exec(`regsvr32.exe ${regsvr32Args}`, { timeout: 10000, windowsHide: true }, (err2) => {
            if (err2) {
              console.warn('[VirtualCamera] Non-elevated registration also failed:', err2.message)
              resolve(false)
            } else {
              console.log('[VirtualCamera] DLL registered (non-elevated):', dllPath)
              resolve(true)
            }
          })
        } else {
          console.log('[VirtualCamera] DLL registered (elevated):', dllPath)
          resolve(true)
        }
      })
    })
  }

  // ── Shared Memory Lifecycle ────────────────────────────────────────────────

  /**
   * Opens the shared memory region for writing frames.
   *
   * The UnityCapture protocol has the receiver (DirectShow filter) create the
   * shared memory objects. The sender opens them. But when no consumer app has
   * opened the virtual camera yet, the receiver doesn't exist — so we create
   * the objects ourselves. The filter picks them up when it starts.
   *
   * Crucially, this means pushing frames before any app has selected
   * "Bridge Phone Camera" is safe — it does NOT hang. The mutex is created
   * by us and always available.
   */
  ensureReady(): boolean {
    if (this._isOpen) return true

    try {
      const ok = this._openSharedMemory()
      if (ok) {
        console.log('[VirtualCamera] ensureReady: shared memory opened successfully')
      } else {
        console.error('[VirtualCamera] ensureReady: _openSharedMemory returned false — see warnings above')
      }
      return ok
    } catch (err) {
      console.error('[VirtualCamera] Failed to open shared memory:', err)
      return false
    }
  }

  private _openSharedMemory(): boolean {
    if (this._pSharedBuf) return true

    const w = win32()

    // ── Mutex ─────────────────────────────────────────────────────────────
    if (!this._hMutex) {
      // Try to open existing (receiver already running), else create
      this._hMutex = w.OpenMutexA(SYNCHRONIZE, FALSE, MUTEX_NAME)
      if (this._hMutex) {
        console.log('[VirtualCamera] Open: mutex opened (existing receiver)')
      } else {
        this._hMutex = w.CreateMutexA(null, FALSE, MUTEX_NAME)
      }
      if (!this._hMutex) {
        console.warn('[VirtualCamera] Failed to open/create mutex')
        return false
      }
      console.log('[VirtualCamera] Open: mutex handle ready')
    }

    // ── WantFrame event (sender creates) ──────────────────────────────────
    if (!this._hWantFrameEvent) {
      this._hWantFrameEvent = w.CreateEventA(null, FALSE, FALSE, EVENT_WANT_NAME)
      if (!this._hWantFrameEvent) {
        console.warn('[VirtualCamera] Failed to create WantFrame event')
        return false
      }
      console.log('[VirtualCamera] Open: WantFrame event ready')
    }

    // ── SentFrame event (try open, else create) ───────────────────────────
    if (!this._hSentFrameEvent) {
      this._hSentFrameEvent = w.OpenEventA(EVENT_MODIFY_STATE, FALSE, EVENT_SENT_NAME)
      if (!this._hSentFrameEvent) {
        this._hSentFrameEvent = w.CreateEventA(null, FALSE, FALSE, EVENT_SENT_NAME)
      }
      if (!this._hSentFrameEvent) {
        console.warn('[VirtualCamera] Failed to open/create SentFrame event')
        return false
      }
      console.log('[VirtualCamera] Open: SentFrame event ready')
    }

    // ── Shared file mapping ───────────────────────────────────────────────
    if (!this._hSharedFile) {
      this._hSharedFile = w.OpenFileMappingA(FILE_MAP_WRITE, FALSE, SHARED_DATA_NAME)
      if (this._hSharedFile) {
        console.log('[VirtualCamera] Open: file mapping opened (existing)')
      } else {
        const totalSize = SHARED_HEADER_SIZE + MAX_SHARED_IMAGE_SIZE
        console.log(`[VirtualCamera] Open: no existing mapping — creating ${totalSize} bytes (${SHARED_DATA_NAME.replace(/\0/g, '')})`)
        this._hSharedFile = w.CreateFileMappingA(
          INVALID_HANDLE_VALUE, null, PAGE_READWRITE,
          0, // high-order DWORD of size (0 — our size fits in 32 bits)
          totalSize,
          SHARED_DATA_NAME
        )
      }
      if (!this._hSharedFile) {
        console.warn('[VirtualCamera] Failed to open/create shared file mapping')
        return false
      }
      console.log('[VirtualCamera] Open: file mapping handle ready')
    }

    // ── Map view ──────────────────────────────────────────────────────────
    this._pSharedBuf = w.MapViewOfFile(this._hSharedFile, FILE_MAP_WRITE, 0, 0, 0)
    if (!this._pSharedBuf) {
      console.warn('[VirtualCamera] Failed to map view of shared file')
      return false
    }
    console.log('[VirtualCamera] Open: MapViewOfFile succeeded — shared buffer mapped')

    // Write initial maxSize so the receiver knows the buffer capacity
    this._writeHeader(0, 0, 0)

    this._isOpen = true
    console.log('[VirtualCamera] Shared memory opened — ready to send frames')
    return true
  }

  /**
   * Writes the SharedMemHeader to the mapped memory region.
   * Layout verified against shared.inl `struct SharedMemHeader`:
   *   DWORD maxSize (0), int width (4), int height (8), int stride (12),
   *   int format (16), int resizemode (20), int mirrormode (24), int timeout (28)
   * Total SHARED_HEADER_SIZE = 32 bytes. Do not change field order/widths.
   *
   * NOTE on stride: UnityCapture convention is PIXELS per row, not bytes.
   * The official sender (UnityCapturePlugin.cpp:134) passes
   * `mapResource.RowPitch / 4`, and the filter (UnityCaptureFilter.cpp
   * ProcessJob) indexes rows via `uint32_t*` pointer arithmetic and compares
   * `RGBAInStride != Width` (pixels). Passing bytes (width*4) makes the filter
   * read row y from pixel offset y*width*4 — a 4x vertical squash into the top
   * of the frame with the rest black. Always pass width (pixels) here.
   */
  private _writeHeader(width: number, height: number, stride: number): void {
    const w = win32()
    const headerBuf = Buffer.alloc(SHARED_HEADER_SIZE)
    headerBuf.writeUInt32LE(MAX_SHARED_IMAGE_SIZE, 0)   // maxSize
    headerBuf.writeInt32LE(width, 4)                     // width
    headerBuf.writeInt32LE(height, 8)                    // height
    headerBuf.writeInt32LE(stride, 12)                   // stride
    headerBuf.writeInt32LE(FORMAT_UINT8, 16)             // format: UINT8 (BGRA)
    headerBuf.writeInt32LE(RESIZEMODE_LINEAR, 20)        // resizemode: linear
    headerBuf.writeInt32LE(MIRRORMODE_DISABLED, 24)      // mirrormode: disabled
    headerBuf.writeInt32LE(FRAME_TIMEOUT_MS, 28)         // timeout
    w.RtlMoveMemory(this._pSharedBuf, headerBuf, SHARED_HEADER_SIZE)
  }

  /**
   * Color swap setting.
   * NOTE: UnityCapture's DirectShow filter (UnityCaptureFilter.cpp RGBA8toBGRA8)
   * performs the RGBA→BGRA conversion itself before handing frames to
   * DirectShow MEDIASUBTYPE_RGB32/ARGB32. Since canvas.getImageData() already
   * produces RGBA, leaving swapRB = false delivers correct colors without
   * wasting CPU cycles. Set to true only for explicit testing.
   */
  public swapRB = false

  /**
   * Vertical flip setting (default true — do not disable without re-testing).
   *
   * WHY: canvas getImageData() / WebRTC VideoFrames are TOP-DOWN (row 0 = top
   * of scene). UnityCapture's filter declares a bottom-up DIB (positive
   * biHeight in GetMediaType, UnityCaptureFilter.cpp:866) and performs NO
   * vertical flip anywhere in its pipeline (all ProcessJobs copy rows straight
   * through; mirrormode is horizontal-only). There is no header flag to signal
   * row order — so the sender must supply BOTTOM-UP rows, otherwise consumers
   * (Chrome/webcamtests, Windows Camera) render the frame upside down.
   *
   * The flip moves whole 4-byte pixels row-by-row, so R/B channel order is
   * untouched and cannot reintroduce a color-swap bug.
   */
  public flipVertical = true

  // Preallocated buffer for writing header + frame data to shared memory (avoids 110MB/s GC churn)
  private _frameBuffer = Buffer.alloc(SHARED_HEADER_SIZE + MAX_SHARED_IMAGE_SIZE)

  // Frame delivery metrics and logging state
  private _frameCount = 0
  private _dropCount = 0
  private _lastFpsLogTime = 0
  private _fpsCounter = 0
  private _lastDimsKey = ''

  // Latest-only mailbox: IPC arrivals land here (cheap reference store) and a
  // steady 30fps writer clock pushes the freshest frame to shared memory.
  // Decoupling arrival jitter (WiFi/WebRTC variance, IPC latency) from the
  // output cadence is what makes motion look even instead of hitchy.
  private _mailbox: { data: Buffer | Uint8Array | ArrayBuffer; width: number; height: number; fresh: boolean } | null = null
  private _coalesced = 0
  private _writerTimer: ReturnType<typeof setInterval> | null = null
  private static readonly WRITER_INTERVAL_MS = 1000 / 30

  // DIAG: real inter-write gaps (target = 33.3ms). Mean/max per log window
  // reveal writer drift or event-loop stalls; starved ticks (no fresh frame)
  // distinguish "writer waiting on arrivals" (upstream) from "writer late"
  // (local scheduling). Logging only — no behavior change.
  private _lastWriteTime = 0
  private _writeGapSum = 0
  private _writeGapMax = 0
  private _starvedTicks = 0

  /**
   * Sets the DirectShow device name in the HKCU registry to "Bridge Phone Camera".
   * HKCU does not require Administrator elevation and overrides HKLM.
   */
  ensureFriendlyName(): void {
    const clsid = '{5C2CD55C-92AD-4999-8666-912BD3E70010}'
    const catClsid = '{860BB310-5D01-11d0-BD3B-00A0C911CE86}'
    const commands = [
      `reg add "HKCU\\Software\\Classes\\CLSID\\${catClsid}\\Instance\\${clsid}" /v FriendlyName /t REG_SZ /d "${DEVICE_NAME}" /f`,
      `reg add "HKCU\\Software\\Classes\\CLSID\\${clsid}" /ve /t REG_SZ /d "${DEVICE_NAME}" /f`,
      `reg add "HKCU\\Software\\Classes\\WOW6432Node\\CLSID\\${catClsid}\\Instance\\${clsid}" /v FriendlyName /t REG_SZ /d "${DEVICE_NAME}" /f`,
      `reg add "HKCU\\Software\\Classes\\WOW6432Node\\CLSID\\${clsid}" /ve /t REG_SZ /d "${DEVICE_NAME}" /f`,
    ]
    for (const cmd of commands) {
      exec(cmd, { windowsHide: true }, (err) => {
        if (err) console.warn('[VirtualCamera] FriendlyName registry update notice:', err.message)
      })
    }
  }

  /**
   * Receives a video frame from the renderer (fast path — must never block).
   * Validates dimensions, stores the frame in the latest-only mailbox
   * (overwriting any not-yet-written predecessor), and returns. The steady
   * writer clock picks it up within ~33ms. Dropped/coalesced frames are
   * counted and reported — coalescing is normal smoothing work, not an error.
   *
   * @param rgbaBuffer Raw top-down RGBA pixel data (ArrayBuffer via zero-copy
   *   postMessage transfer, or Uint8Array/Buffer via the send() fallback).
   *   Read ONLY through a zero-copy view — never Buffer.from() it.
   */
  pushFrame(rgbaBuffer: Buffer | Uint8Array | ArrayBuffer, width: number, height: number): void {
    const rowBytes = width * 4
    const dataSize = rowBytes * height

    // Non-positive dims guard (e.g. a transient 0-size frame mid-rotation).
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
      this._dropCount++
      console.warn(`[VirtualCamera] pushFrame: invalid dims ${width}x${height}. Dropped (total dropped: ${this._dropCount})`)
      return
    }

    // Dimension agreement guard: the payload must actually contain width*height
    // RGBA pixels. A mismatch means capture and header disagree — drop loudly
    // instead of reading out of bounds or writing a torn frame.
    if (rgbaBuffer.byteLength < dataSize) {
      this._dropCount++
      console.warn(`[VirtualCamera] pushFrame: DIM MISMATCH: payload ${rgbaBuffer.byteLength} bytes < ${width}x${height} (${dataSize} bytes). Dropped (total dropped: ${this._dropCount})`)
      return
    }

    if (dataSize > MAX_SHARED_IMAGE_SIZE) {
      this._dropCount++
      console.warn(`[VirtualCamera] pushFrame: frame too large: ${width}x${height} (${dataSize} bytes)`)
      return
    }

    // Log whenever the declared capture dims change (rotation, camera flip,
    // renegotiation) so the header trail shows orientation switches. The
    // vertical flip and R/B handling in _writeFrame are fully
    // dims-parameterized, so a dims change cannot reintroduce those bugs.
    const dimsKey = `${width}x${height}`
    if (dimsKey !== this._lastDimsKey) {
      this._lastDimsKey = dimsKey
      const orient = width >= height ? 'landscape' : 'portrait'
      console.log(`[VirtualCamera] Capture dims → header now ${dimsKey} (${orient}) stride=${width}px rowBytes=${rowBytes} data=${dataSize}B flip=${this.flipVertical ? 'on' : 'OFF'} swapRB=${this.swapRB ? 'ON' : 'off'}`)
      if (width % 4 !== 0) {
        console.warn(`[VirtualCamera] Width ${width} is not a multiple of 4 — UnityCapture advises widths in increments of 4; some consumers may pad rows.`)
      }
    }

    if (this._mailbox?.fresh) this._coalesced++
    this._mailbox = { data: rgbaBuffer, width, height, fresh: true }

    // Open shared memory eagerly so the first writer tick has no setup stall.
    if (!this._isOpen) this.ensureReady()
    this._ensureWriter()
  }

  /** Starts the steady output clock (idempotent). */
  private _ensureWriter(): void {
    if (this._writerTimer) return
    this._writerTimer = setInterval(() => this._onWriterTick(), VirtualCameraServiceClass.WRITER_INTERVAL_MS)
    // Don't keep the app alive for the writer alone; stop() clears it anyway.
    ;(this._writerTimer as any)?.unref?.()
  }

  /** Steady 30fps tick: writes the freshest mailbox frame, if any, else skips. */
  private _onWriterTick(): void {
    const box = this._mailbox
    if (!box?.fresh) {
      this._starvedTicks++
      return
    }
    box.fresh = false
    this._writeFrame(box.data, box.width, box.height)
  }

  /**
   * Writes a single video frame into the shared memory region.
   * Called only by the steady writer clock — never directly per IPC arrival.
   * The frame was validated in pushFrame(); dims here drive header stride,
   * row copies, and the vertical flip (all per-frame, never hardcoded).
   */
  private _writeFrame(rgbaBuffer: Buffer | Uint8Array | ArrayBuffer, width: number, height: number): void {
    this._frameCount++
    this._fpsCounter++

    // DIAG: real elapsed time since the previous shared-memory write.
    const wtNow = performance.now()
    if (this._lastWriteTime !== 0) {
      const gap = wtNow - this._lastWriteTime
      this._writeGapSum += gap
      if (gap > this._writeGapMax) this._writeGapMax = gap
    }
    this._lastWriteTime = wtNow

    if (!this._isOpen || !this._pSharedBuf) {
      if (!this.ensureReady()) {
        this._dropCount++
        console.error(`[VirtualCamera] _writeFrame: Cannot write frame #${this._frameCount} — shared memory not ready!`)
        return
      }
    }

    const w = win32()
    // Header stride is PIXELS per row (UnityCapture convention — see _writeHeader
    // note). rowBytes/dataSize are the byte counts used for the actual copies.
    const stridePx = width
    const rowBytes = width * 4
    const dataSize = rowBytes * height

    // ── Lock mutex (short timeout — never hang the main thread) ──────────
    // A long synchronous wait here stalls the whole Electron main loop while
    // the filter converts a frame, delaying IPC drains and causing visible
    // hitches. 50ms is ample (a 720p convert holds it for a few ms); on
    // timeout the frame is dropped and the next paced frame follows in ~33ms.
    const waitStart = performance.now()
    const waitResult = w.WaitForSingleObject(this._hMutex, 50)
    const waitDuration = (performance.now() - waitStart).toFixed(2)

    if (waitResult !== WAIT_OBJECT_0) {
      this._dropCount++
      console.warn(`[VirtualCamera] _writeFrame: Mutex WaitForSingleObject TIMEOUT/BUSY (code=${waitResult}, waited ${waitDuration}ms). Dropped frame #${this._frameCount} (total dropped: ${this._dropCount})`)
      return
    }

    try {
      // Header in preallocated buffer (stride = pixels per row, NOT bytes)
      this._frameBuffer.writeUInt32LE(MAX_SHARED_IMAGE_SIZE, 0)
      this._frameBuffer.writeInt32LE(width, 4)
      this._frameBuffer.writeInt32LE(height, 8)
      this._frameBuffer.writeInt32LE(stridePx, 12)
      this._frameBuffer.writeInt32LE(FORMAT_UINT8, 16)
      this._frameBuffer.writeInt32LE(RESIZEMODE_LINEAR, 20)
      this._frameBuffer.writeInt32LE(MIRRORMODE_DISABLED, 24)
      this._frameBuffer.writeInt32LE(FRAME_TIMEOUT_MS, 28)

      // Pixel data: source is top-down RGBA; shared memory must hold bottom-up
      // rows (see flipVertical note). All paths preserve R/B channel order —
      // the flip moves whole 4-byte pixels, never shuffles bytes within one.
      // srcView is a zero-copy window onto the caller's buffer (no Buffer.from
      // pass); rows land in _frameBuffer via .set(), then ONE RtlMoveMemory
      // carries header+data into shared memory.
      const srcView: Uint8Array = ArrayBuffer.isView(rgbaBuffer)
        ? new Uint8Array(rgbaBuffer.buffer, rgbaBuffer.byteOffset, dataSize)
        : new Uint8Array(rgbaBuffer as ArrayBuffer, 0, dataSize)
      if (this.swapRB) {
        // Manual R<->B swap for explicit testing, combined with the row flip
        // in a single pass so no temp buffer is needed.
        for (let y = 0; y < height; y++) {
          const srcRow = y * rowBytes
          const dstRow = SHARED_HEADER_SIZE + (this.flipVertical ? (height - 1 - y) : y) * rowBytes
          for (let x = 0; x < rowBytes; x += 4) {
            this._frameBuffer[dstRow + x]     = srcView[srcRow + x + 2] // B
            this._frameBuffer[dstRow + x + 1] = srcView[srcRow + x + 1] // G
            this._frameBuffer[dstRow + x + 2] = srcView[srcRow + x]     // R
            this._frameBuffer[dstRow + x + 3] = srcView[srcRow + x + 3] // A
          }
        }
      } else if (this.flipVertical) {
        // Row-granularity vertical flip via .set() (fast, in-process).
        // Whole pixels move intact — channel order untouched.
        for (let y = 0; y < height; y++) {
          this._frameBuffer.set(
            srcView.subarray(y * rowBytes, (y + 1) * rowBytes),
            SHARED_HEADER_SIZE + (height - 1 - y) * rowBytes
          )
        }
      } else {
        // Fast direct copy: no flip requested (debugging only — consumers
        // will render the frame upside down, see flipVertical note).
        this._frameBuffer.set(srcView.subarray(0, dataSize), SHARED_HEADER_SIZE)
      }

      // Single RtlMoveMemory call to write header + data into shared memory
      w.RtlMoveMemory(this._pSharedBuf, this._frameBuffer, SHARED_HEADER_SIZE + dataSize)
    } finally {
      w.ReleaseMutex(this._hMutex)
    }

    // Signal that a new frame has been sent
    w.SetEvent(this._hSentFrameEvent)

    // Check if an external consumer (Zoom/Teams/webcamtests) is actively waiting
    const isConsumerWaiting = w.WaitForSingleObject(this._hWantFrameEvent, 0) === WAIT_OBJECT_0

    if (this._frameCount === 1) {
      console.log(`[VirtualCamera] === Frame #1 Successfully Written to Shared Memory ===`)
      console.log(`[VirtualCamera] Header: ${width}x${height} stride=${stridePx}px rowBytes=${rowBytes} data=${dataSize}B format=UINT8 resize=LINEAR mirror=DISABLED | flipVertical=${this.flipVertical} swapRB=${this.swapRB}`)
      console.log(`[VirtualCamera] Info: Mutex wait: ${waitDuration}ms (WAIT_OBJECT_0) | External App Status: ${isConsumerWaiting ? 'ACTIVE (requesting frames)' : 'STANDBY (no app connected yet)'}`)
    }

    const now = performance.now()
    if (now - this._lastFpsLogTime >= 2000) {
      const elapsedSec = (now - this._lastFpsLogTime) / 1000
      const currentFps = (this._fpsCounter / elapsedSec).toFixed(1)
      const gapAvg = this._fpsCounter > 0 ? `${(this._writeGapSum / this._fpsCounter).toFixed(1)}ms` : 'n/a'
      console.log(`[VirtualCamera] Write Status: ${currentFps} FPS | Written: ${this._frameCount} | Dropped: ${this._dropCount} | Coalesced: ${this._coalesced} | gap avg/max: ${gapAvg}/${this._writeGapMax.toFixed(1)}ms (target 33.3ms) starvedTicks: ${this._starvedTicks} | Header: ${width}x${height} stride=${stridePx}px flip=${this.flipVertical ? 'on' : 'OFF'} swapRB=${this.swapRB ? 'ON' : 'off'} | Mutex wait: ${waitDuration}ms | Consumer: ${isConsumerWaiting ? 'ACTIVE' : 'STANDBY'}`)
      this._fpsCounter = 0
      this._coalesced = 0
      this._writeGapSum = 0
      this._writeGapMax = 0
      this._starvedTicks = 0
      this._lastFpsLogTime = now
    }
  }

  /**
   * Stops the virtual camera — halts the writer clock, clears the mailbox,
   * sets width=0 in shared memory header (→ "no signal" / black state in
   * consumer apps), then closes all shared memory handles.
   */
  stop(): void {
    if (this._writerTimer) {
      clearInterval(this._writerTimer)
      this._writerTimer = null
    }
    this._mailbox = null
    // Reset the fps/gap windows so the next stream's first status line is sane.
    this._fpsCounter = 0
    this._coalesced = 0
    this._writeGapSum = 0
    this._writeGapMax = 0
    this._starvedTicks = 0
    this._lastWriteTime = 0
    this._lastFpsLogTime = 0

    if (!this._isOpen || !this._pSharedBuf) return

    const w = win32()

    // Write width=0 to indicate capture is inactive
    const waitResult = w.WaitForSingleObject(this._hMutex, 200)
    if (waitResult === WAIT_OBJECT_0) {
      try {
        // Zero header: width=0 → filter returns CAPTUREINACTIVE → black/no-signal
        const headerBuf = Buffer.alloc(SHARED_HEADER_SIZE)
        headerBuf.writeUInt32LE(MAX_SHARED_IMAGE_SIZE, 0) // preserve maxSize
        // All other fields zero (width=0 is the key "inactive" signal)
        w.RtlMoveMemory(this._pSharedBuf, headerBuf, SHARED_HEADER_SIZE)
      } finally {
        w.ReleaseMutex(this._hMutex)
      }
    }

    this._closeHandles()
    console.log('[VirtualCamera] Stopped — showing no-signal state')
  }

  private _closeHandles(): void {
    const w = win32()

    if (this._pSharedBuf) {
      w.UnmapViewOfFile(this._pSharedBuf)
      this._pSharedBuf = null
    }
    if (this._hSharedFile) {
      w.CloseHandle(this._hSharedFile)
      this._hSharedFile = null
    }
    if (this._hSentFrameEvent) {
      w.CloseHandle(this._hSentFrameEvent)
      this._hSentFrameEvent = null
    }
    if (this._hWantFrameEvent) {
      w.CloseHandle(this._hWantFrameEvent)
      this._hWantFrameEvent = null
    }
    if (this._hMutex) {
      w.CloseHandle(this._hMutex)
      this._hMutex = null
    }
    this._isOpen = false
  }
}

export const VirtualCameraService = new VirtualCameraServiceClass()
