import { ipcRenderer, contextBridge } from 'electron'

// --------- Expose some API to the Renderer process ---------
contextBridge.exposeInMainWorld('ipcRenderer', {
  on(...args: Parameters<typeof ipcRenderer.on>) {
    const [channel, listener] = args
    return ipcRenderer.on(channel, (event, ...args) => listener(event, ...args))
  },
  off(...args: Parameters<typeof ipcRenderer.off>) {
    const [channel, ...omit] = args
    return ipcRenderer.off(channel, ...omit)
  },
  send(...args: Parameters<typeof ipcRenderer.send>) {
    const [channel, ...omit] = args
    return ipcRenderer.send(channel, ...omit)
  },
  invoke(...args: Parameters<typeof ipcRenderer.invoke>) {
    const [channel, ...omit] = args
    return ipcRenderer.invoke(channel, ...omit)
  },

  /**
   * Sends one video frame to the main process for the virtual camera.
   * Uses ipcRenderer.postMessage with a transfer list so the pixel buffer
   * crosses the IPC channel zero-copy (no multi-MB structured-clone per
   * frame at 30fps — that serialization backlog is what caused
   * freeze-then-fast-forward bursts). Falls back to send() if transfer
   * throws on this Electron build. Main receives identical shape either way.
   *
   * NOTE: this must stay a dedicated function (not a generic postMessage
   * passthrough): the buffer may only be referenced ONCE on this side so the
   * transfer list neuters the same copy that is delivered — a generic
   * (message, transfer) split would get cloned into two separate buffers by
   * the context bridge and silently defeat the transfer.
   */
  sendFrame(width: number, height: number, data: ArrayBuffer) {
    const payload = { width, height, data }
    try {
      ipcRenderer.postMessage('vcam-frame', payload, [data] as unknown as MessagePort[])
    } catch (err) {
      console.warn('[preload] vcam-frame transfer failed, falling back to send():', err)
      ipcRenderer.send('vcam-frame', payload)
    }
  },

  // You can expose other APTs you need here.
  // ...
})
