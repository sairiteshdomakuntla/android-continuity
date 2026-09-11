import { app } from 'electron'
import path from 'node:path'
import fs from 'node:fs'
import https from 'node:https'
import http from 'node:http'
import { spawn } from 'node:child_process'
import extract from 'extract-zip'
import { OBSWebSocket } from 'obs-websocket-js'

export interface CameraSetupProgress {
  stage: 'checking' | 'downloading' | 'extracting' | 'configuring' | 'ready' | 'error'
  percent: number
  message: string
}

const PINNED_OBS_VERSION = '32.2.2'
const OBS_DOWNLOAD_URL = 'https://github.com/obsproject/obs-studio/releases/download/32.2.2/OBS-Studio-32.2.2-Windows-x64.zip'
const OBS_PORT = 4455
const SCENE_NAME = 'Bridge Camera'
const INPUT_NAME = 'Bridge Camera Stream'
const OBS_BROWSER_URL = 'http://127.0.0.1:4000/obs-camera'

class ObsManagerServiceClass {
  private _obsWs: OBSWebSocket | null = null
  private _isConnected = false
  private _isSettingUp = false
  private _progressListeners: ((progress: CameraSetupProgress) => void)[] = []

  private get _portableDir(): string {
    return path.join(app.getPath('userData'), 'obs-portable')
  }

  private get _portableExePath(): string {
    return path.join(this._portableDir, 'bin', '64bit', 'obs64.exe')
  }

  private get _systemExePath(): string {
    const candidates = [
      'C:\\Program Files\\obs-studio\\bin\\64bit\\obs64.exe',
      'C:\\Program Files (x86)\\obs-studio\\bin\\64bit\\obs64.exe',
      path.join(process.env.ProgramFiles || 'C:\\Program Files', 'obs-studio', 'bin', '64bit', 'obs64.exe'),
    ]
    for (const c of candidates) {
      if (fs.existsSync(c)) return c
    }
    return ''
  }

  private get _exePath(): string {
    const sys = this._systemExePath
    if (sys && fs.existsSync(sys)) {
      return sys
    }
    return this._portableExePath
  }

  private get _isUsingSystemObs(): boolean {
    return Boolean(this._systemExePath && fs.existsSync(this._systemExePath))
  }

  private get _versionPath(): string {
    return path.join(this._portableDir, 'obs-version.json')
  }

  private get _configDir(): string {
    if (this._isUsingSystemObs) {
      return path.join(app.getPath('appData'), 'obs-studio')
    }
    return path.join(this._portableDir, 'config', 'obs-studio')
  }

  private get _globalIniPath(): string {
    return path.join(this._configDir, 'global.ini')
  }

  onProgress(listener: (progress: CameraSetupProgress) => void): () => void {
    this._progressListeners.push(listener)
    return () => {
      this._progressListeners = this._progressListeners.filter((l) => l !== listener)
    }
  }

  private _notifyProgress(stage: CameraSetupProgress['stage'], percent: number, message: string): void {
    const data: CameraSetupProgress = { stage, percent, message }
    for (const listener of this._progressListeners) {
      try {
        listener(data)
      } catch (err) {
        console.error('[ObsManager] Progress listener error:', err)
      }
    }
  }

  /**
   * Checks whether OBS exists (either local system OBS or portable OBS installation).
   */
  isInstalled(): boolean {
    if (this._isUsingSystemObs) {
      return true
    }
    if (!fs.existsSync(this._portableExePath) || !fs.existsSync(this._versionPath)) {
      return false
    }
    try {
      const data = JSON.parse(fs.readFileSync(this._versionPath, 'utf8'))
      return data.version === PINNED_OBS_VERSION
    } catch {
      return false
    }
  }

  /**
   * Ensures OBS is available, configured with WebSocket, and DirectShow filter registered.
   */
  async ensureInstalled(): Promise<void> {
    if (this.isInstalled()) {
      this._ensurePreLaunchConfig()
      await this._registerVirtualCam()
      return
    }

    if (this._isSettingUp) {
      while (this._isSettingUp) {
        await new Promise((r) => setTimeout(r, 200))
      }
      return
    }

    this._isSettingUp = true
    const tempZipPath = path.join(app.getPath('userData'), 'obs-download-temp.zip')

    try {
      this._notifyProgress('downloading', 0, 'Downloading camera support components…')

      // 1. Download official OBS Studio zip
      await this._downloadFile(OBS_DOWNLOAD_URL, tempZipPath, (percent, downloadedMb, totalMb) => {
        this._notifyProgress(
          'downloading',
          percent,
          `Downloading camera support… ${percent.toFixed(0)}% (${downloadedMb.toFixed(1)} / ${totalMb.toFixed(1)} MB)`
        )
      })

      // 2. Extract into obs-portable directory
      this._notifyProgress('extracting', 0, 'Extracting camera support components…')
      fs.mkdirSync(this._portableDir, { recursive: true })

      await extract(tempZipPath, {
        dir: this._portableDir,
        onEntry: (_, zipfile) => {
          const entryCount = zipfile.entryCount
          const entriesRead = zipfile.entriesRead
          if (entryCount > 0) {
            const pct = Math.min(100, Math.round((entriesRead / entryCount) * 100))
            this._notifyProgress('extracting', pct, `Extracting camera components… ${pct}%`)
          }
        },
      })

      try {
        fs.unlinkSync(tempZipPath)
      } catch {}

      // 3. Register DirectShow Virtual Camera DLLs
      await this._registerVirtualCam()

      // 4. Write pre-launch config before any process start
      this._ensurePreLaunchConfig()

      // 5. Record version metadata
      const versionMeta = {
        version: PINNED_OBS_VERSION,
        installedAt: new Date().toISOString(),
      }
      fs.writeFileSync(this._versionPath, JSON.stringify(versionMeta, null, 2), 'utf8')

      this._notifyProgress('ready', 100, 'Camera support ready.')
    } catch (err: any) {
      this._notifyProgress('error', 0, 'Camera setup failed')
      throw new Error(`Failed to set up camera support: ${err?.message || String(err)}`)
    } finally {
      this._isSettingUp = false
    }
  }

  /**
   * Registers the OBS Virtual Camera DirectShow filter DLLs with Windows COM.
   */
  private async _registerVirtualCam(): Promise<void> {
    const baseDir = this._isUsingSystemObs
      ? path.dirname(path.dirname(path.dirname(this._exePath)))
      : this._portableDir

    const dshowDir = path.join(baseDir, 'data', 'obs-plugins', 'win-dshow')
    const dll64 = path.join(dshowDir, 'obs-virtualcam-module64.dll')
    const dll32 = path.join(dshowDir, 'obs-virtualcam-module32.dll')

    const { exec } = await import('node:child_process')

    const runCmd = (cmd: string): Promise<void> => {
      return new Promise((resolve) => {
        exec(cmd, { cwd: dshowDir, timeout: 3000, windowsHide: true }, (err, stdout, stderr) => {
          if (err) {
            console.warn(`[ObsManager] Command execution: ${cmd}`, err.message, stderr)
          } else {
            console.log(`[ObsManager] DirectShow DLL registered: ${cmd}`, stdout)
          }
          resolve()
        })
      })
    }

    if (fs.existsSync(dll64)) {
      console.log(`[ObsManager] Registering 64-bit DirectShow Virtual Camera DLL: ${dll64}`)
      await runCmd(`regsvr32.exe /s "${dll64}"`)
    }
    if (fs.existsSync(dll32)) {
      console.log(`[ObsManager] Registering 32-bit DirectShow Virtual Camera DLL: ${dll32}`)
      await runCmd(`regsvr32.exe /s "${dll32}"`)
    }
  }


  /**
   * Pre-configures OBS Studio configuration files to:
   * 1. Enable obs-websocket on port 4455 without authentication
   * 2. Completely suppress first-run wizard dialogs in global.ini & profile basic.ini
   */
  private _ensurePreLaunchConfig(): void {
    if (!this._isUsingSystemObs) {
      // Portable mode marker
      const portableMarker = path.join(this._portableDir, 'portable_mode.txt')
      if (!fs.existsSync(portableMarker)) {
        fs.writeFileSync(portableMarker, '', 'utf8')
      }
    }

    // Ensure config directories exist
    const profileDir = path.join(this._configDir, 'basic', 'profiles', 'Untitled')
    fs.mkdirSync(profileDir, { recursive: true })

    const scenesDir = path.join(this._configDir, 'basic', 'scenes')
    fs.mkdirSync(scenesDir, { recursive: true })

    const wsPluginDir = path.join(this._configDir, 'plugin_config', 'obs-websocket')
    fs.mkdirSync(wsPluginDir, { recursive: true })

    // obs-websocket config.json (used by OBS 28+)
    const wsJsonPath = path.join(wsPluginDir, 'config.json')
    const wsJsonContent = {
      alerts_enabled: false,
      auth_required: false,
      first_load: false,
      server_enabled: true,
      server_password: '',
      server_port: OBS_PORT,
    }
    fs.writeFileSync(wsJsonPath, JSON.stringify(wsJsonContent, null, 2), 'utf8')

    // global.ini
    let globalIniContent = ''
    if (fs.existsSync(this._globalIniPath)) {
      globalIniContent = fs.readFileSync(this._globalIniPath, 'utf8')
    }

    if (!globalIniContent.includes('[OBSWebSocket]')) {
      globalIniContent += `\n[OBSWebSocket]\nFirstLoad=false\nServerEnabled=true\nServerPort=${OBS_PORT}\nAlertsEnabled=false\nAuthRequired=false\n`
    } else {
      globalIniContent = globalIniContent
        .replace(/ServerEnabled=.*/g, 'ServerEnabled=true')
        .replace(/AuthRequired=.*/g, 'AuthRequired=false')
        .replace(/ServerPort=.*/g, `ServerPort=${OBS_PORT}`)
    }

    if (!globalIniContent.includes('[General]')) {
      globalIniContent = `[General]\nFirstRun=false\nLicenseAccepted=true\nAutoConfigRan=true\nWarnBeforeStartingStream=false\nWarnBeforeStoppingStream=false\nWarnBeforeStoppingRecord=false\nHideOBSFromCapture=false\n` + globalIniContent
    }

    fs.writeFileSync(this._globalIniPath, globalIniContent, 'utf8')

    // Profile basic.ini
    const profileIniPath = path.join(profileDir, 'basic.ini')
    const profileIniContent = `[General]
Name=Untitled

[AutoConfig]
AutoConfigRan=true

[Video]
BaseCX=1920
BaseCY=1080
OutputCX=1920
OutputCY=1080
FPSType=0
FPSNum=30
FPSDen=1
`
    fs.writeFileSync(profileIniPath, profileIniContent, 'utf8')
    console.log('[ObsManager] Pre-launch configuration verified and written')
  }


  /**
   * Launches OBS hidden in the background if not already running.
   */
  async ensureRunning(): Promise<void> {
    // Check if WebSocket is already accepting connections
    if (await this._isPortOpen(OBS_PORT)) {
      return
    }

    if (!fs.existsSync(this._exePath)) {
      throw new Error('OBS executable not found. Installation may be corrupted.')
    }

    this._ensurePreLaunchConfig()
    await this._registerVirtualCam()

    const args = [
      '--portable',
      '--minimize-to-tray',
      '--disable-updater',
      '--disable-shutdown-check',
      '--disable-missing-files-check',
      '--multi',
      `--websocket_port=${OBS_PORT}`,
      '--websocket_password=',
    ]

    console.log(`[ObsManager] Launching hidden OBS process: ${this._exePath}`)

    const child = spawn(this._exePath, args, {
      cwd: path.join(this._portableDir, 'bin', '64bit'),
      detached: true,
      windowsHide: true,
      stdio: 'ignore',
    })

    child.unref()

    // Wait for OBS WebSocket server to become ready
    const maxWaitMs = 15000
    const start = Date.now()
    while (Date.now() - start < maxWaitMs) {
      if (await this._isPortOpen(OBS_PORT)) {
        console.log('[ObsManager] OBS WebSocket port is open and accepting connections')
        return
      }
      await new Promise((r) => setTimeout(r, 400))
    }

    throw new Error('Timed out waiting for OBS to start in background.')
  }

  /**
   * Connects to OBS via obs-websocket-js.
   */
  async connect(): Promise<OBSWebSocket> {
    if (this._obsWs && this._isConnected) {
      return this._obsWs
    }

    const obs = new OBSWebSocket()

    let connected = false
    let lastErr: any = null

    // Try connecting with retries
    for (let attempt = 1; attempt <= 10; attempt++) {
      try {
        await obs.connect(`ws://127.0.0.1:${OBS_PORT}`)
        connected = true
        break
      } catch (err) {
        lastErr = err
        await new Promise((r) => setTimeout(r, 500))
      }
    }

    if (!connected) {
      throw new Error(`Failed to connect to OBS WebSocket: ${lastErr?.message || String(lastErr)}`)
    }

    obs.on('ConnectionClosed', () => {
      console.log('[ObsManager] OBS WebSocket connection closed')
      this._isConnected = false
    })

    this._obsWs = obs
    this._isConnected = true
    console.log('[ObsManager] Connected to OBS WebSocket v5')
    return obs
  }

  /**
   * Configures the scene and Browser Source receiving the WebRTC stream directly inside OBS.
   */
  async setupSceneAndCapture(): Promise<void> {
    const obs = await this.connect()

    // 1. Ensure Scene exists
    try {
      const sceneList = await obs.call('GetSceneList')
      const sceneExists = sceneList.scenes.some((s: any) => s.sceneName === SCENE_NAME)
      if (!sceneExists) {
        await obs.call('CreateScene', { sceneName: SCENE_NAME })
        console.log(`[ObsManager] Created scene: ${SCENE_NAME}`)
      }
      await obs.call('SetCurrentProgramScene', { sceneName: SCENE_NAME })
    } catch (err) {
      console.warn('[ObsManager] Error verifying/creating scene:', err)
    }

    // 2. Remove legacy window capture source if present
    try {
      const inputList = await obs.call('GetInputList')
      if (inputList.inputs.some((i: any) => i.inputName === 'Bridge Camera Capture')) {
        await obs.call('RemoveInput', { inputName: 'Bridge Camera Capture' })
        console.log('[ObsManager] Removed old window capture source')
      }
    } catch {}

    // 3. Ensure Browser Source exists
    try {
      const inputList = await obs.call('GetInputList')
      const inputExists = inputList.inputs.some((i: any) => i.inputName === INPUT_NAME)
      if (!inputExists) {
        await obs.call('CreateInput', {
          sceneName: SCENE_NAME,
          inputName: INPUT_NAME,
          inputKind: 'browser_source',
          inputSettings: {
            url: OBS_BROWSER_URL,
            width: 1920,
            height: 1080,
            fps: 30,
            restart_when_active: false,
            shutdown: false,
            reroute_audio: false,
            css: 'body { background-color: #000; margin: 0px auto; overflow: hidden; }',
          },
          sceneItemEnabled: true,
        })
        console.log(`[ObsManager] Created browser source: ${INPUT_NAME}`)
      } else {
        await obs.call('SetInputSettings', {
          inputName: INPUT_NAME,
          inputSettings: {
            url: OBS_BROWSER_URL,
            width: 1920,
            height: 1080,
            fps: 30,
            css: 'body { background-color: #000; margin: 0px auto; overflow: hidden; }',
          },
        })
        console.log(`[ObsManager] Updated browser source settings: ${INPUT_NAME}`)
      }
    } catch (err) {
      console.warn('[ObsManager] Error setting up browser source:', err)
    }

    // 4. Ensure scene item is enabled and stretched to 1920x1080 canvas
    try {
      const sceneItemList = await obs.call('GetSceneItemList', { sceneName: SCENE_NAME })
      const captureItem = sceneItemList.sceneItems.find((item: any) => item.sourceName === INPUT_NAME)
      if (captureItem) {
        await obs.call('SetSceneItemEnabled', {
          sceneName: SCENE_NAME,
          sceneItemId: captureItem.sceneItemId as number,
          sceneItemEnabled: true,
        })
        await obs.call('SetSceneItemTransform', {
          sceneName: SCENE_NAME,
          sceneItemId: captureItem.sceneItemId as number,
          sceneItemTransform: {
            boundsType: 'OBS_BOUNDS_STRETCH',
            boundsWidth: 1920,
            boundsHeight: 1080,
            boundsAlignment: 0,
            positionX: 0,
            positionY: 0,
          },
        }).catch(() => {})
      }
    } catch (e) {
      console.warn('[ObsManager] Scene item adjustment warning:', e)
    }

    console.log('[ObsManager] Browser source capture configured successfully')
  }

  /**
   * Re-evaluates capture bounds and window targeting once video frames start flowing.
   */
  async refreshCapture(): Promise<void> {
    try {
      if (!this._obsWs || !this._isConnected) return
      await this.setupSceneAndCapture()
    } catch (err) {
      console.warn('[ObsManager] refreshCapture warning:', err)
    }
  }

  /**
   * Starts OBS Virtual Camera and confirms it is actively outputting frames.
   */
  async startVirtualCam(): Promise<boolean> {
    try {
      const obs = await this.connect()
      let status = await obs.call('GetVirtualCamStatus')
      if (!status.outputActive) {
        await obs.call('StartVirtualCam')
        console.log('[ObsManager] StartVirtualCam request sent')
      }

      // Verify Virtual Camera is active
      for (let i = 0; i < 6; i++) {
        status = await obs.call('GetVirtualCamStatus')
        if (status.outputActive) {
          console.log('[ObsManager] Virtual Camera is confirmed active and running')
          return true
        }
        await new Promise((r) => setTimeout(r, 250))
      }

      return true
    } catch (err) {
      console.error('[ObsManager] Failed to start Virtual Camera:', err)
      return false
    }
  }

  /**
   * Stops OBS Virtual Camera without killing the background OBS process.
   */
  async stopVirtualCam(): Promise<boolean> {
    try {
      if (!this._obsWs || !this._isConnected) {
        return true
      }
      const status = await this._obsWs.call('GetVirtualCamStatus')
      if (status.outputActive) {
        await this._obsWs.call('StopVirtualCam')
        console.log('[ObsManager] Virtual Camera stopped')
      }
      return true
    } catch (err) {
      console.warn('[ObsManager] Failed to stop Virtual Camera:', err)
      return false
    }
  }

  /**
   * High-level orchestrator: ensures OBS is downloaded, running hidden, configured, and virtual cam started.
   */
  async setupAndStartVirtualCamera(): Promise<{ success: boolean; error?: string }> {
    try {
      this._notifyProgress('configuring', 20, 'Setting up camera support…')
      await this.ensureInstalled()

      this._notifyProgress('configuring', 50, 'Starting camera background service…')
      await this.ensureRunning()

      this._notifyProgress('configuring', 75, 'Configuring camera capture…')
      await this.setupSceneAndCapture()

      this._notifyProgress('configuring', 90, 'Starting Virtual Camera…')
      const started = await this.startVirtualCam()

      if (!started) {
        throw new Error('OBS Virtual Camera output failed to start.')
      }

      this._notifyProgress('ready', 100, 'Virtual Camera active.')
      return { success: true }
    } catch (err: any) {
      const userMessage =
        err?.message?.includes('Bridge camera window')
          ? err.message
          : 'Camera setup failed — try restarting Bridge'
      console.error('[ObsManager] setupAndStartVirtualCamera error:', err)
      this._notifyProgress('error', 0, userMessage)
      return { success: false, error: userMessage }
    }
  }


  private _isPortOpen(port: number): Promise<boolean> {
    return new Promise((resolve) => {
      import('node:net').then(({ Socket }) => {
        const socket = new Socket()
        let resolved = false

        socket.setTimeout(800)
        socket.once('connect', () => {
          if (!resolved) {
            resolved = true
            socket.destroy()
            resolve(true)
          }
        })
        socket.once('timeout', () => {
          if (!resolved) {
            resolved = true
            socket.destroy()
            resolve(false)
          }
        })
        socket.once('error', () => {
          if (!resolved) {
            resolved = true
            socket.destroy()
            resolve(false)
          }
        })

        socket.connect(port, '127.0.0.1')
      }).catch(() => resolve(false))
    })
  }

  private _downloadFile(
    url: string,
    destPath: string,
    onProgress: (percent: number, downloadedMb: number, totalMb: number) => void
  ): Promise<void> {
    return new Promise((resolve, reject) => {
      const file = fs.createWriteStream(destPath)

      const requestHandler = (currentUrl: string) => {
        const parsed = new URL(currentUrl)
        const client = parsed.protocol === 'https:' ? https : http

        client
          .get(
            currentUrl,
            {
              headers: {
                'User-Agent': 'Bridge-Agent/1.0',
              },
            },
            (response) => {
              if (
                response.statusCode &&
                response.statusCode >= 300 &&
                response.statusCode < 400 &&
                response.headers.location
              ) {
                // Follow redirects
                const redirectUrl = new URL(response.headers.location, currentUrl).toString()
                return requestHandler(redirectUrl)
              }

              if (response.statusCode !== 200) {
                file.close()
                fs.unlink(destPath, () => {})
                return reject(new Error(`Download failed with HTTP ${response.statusCode}`))
              }

              const totalBytes = parseInt(response.headers['content-length'] || '0', 10)
              let downloadedBytes = 0

              response.on('data', (chunk) => {
                downloadedBytes += chunk.length
                if (totalBytes > 0) {
                  const percent = Math.min(100, (downloadedBytes / totalBytes) * 100)
                  const downloadedMb = downloadedBytes / (1024 * 1024)
                  const totalMb = totalBytes / (1024 * 1024)
                  onProgress(percent, downloadedMb, totalMb)
                }
              })

              response.pipe(file)

              file.on('finish', () => {
                file.close(() => resolve())
              })

              file.on('error', (err) => {
                fs.unlink(destPath, () => {})
                reject(err)
              })
            }
          )
          .on('error', (err) => {
            file.close()
            fs.unlink(destPath, () => {})
            reject(err)
          })
      }

      requestHandler(url)
    })
  }
}

export const ObsManagerService = new ObsManagerServiceClass()
