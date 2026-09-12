import { app } from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import type { ClipboardHistoryItem, ClipboardContentType, Origin } from '../types/protocol.js'
import { classifyClipboardText } from './contentClassification.js'

const MAX_HISTORY_ITEMS = 20

class ClipboardHistoryServiceClass {
  private _items: ClipboardHistoryItem[] = []
  private _filePath: string = ''
  private _imagesDir: string = ''
  private _listeners: Array<(items: ClipboardHistoryItem[]) => void> = []

  init(): void {
    try {
      const userData = app.getPath('userData')
      this._filePath = path.join(userData, 'clipboard-history.json')
      this._imagesDir = path.join(userData, 'clipboard-images')
      fs.mkdirSync(this._imagesDir, { recursive: true })
      this._load()
      this._pruneOrphanedImages()
      console.log(`[ClipboardHistory] Initialized with ${this._items.length} items from ${this._filePath}`)
    } catch (err) {
      console.warn('[ClipboardHistory] Failed to initialize history storage:', err)
    }
  }

  getImagesDir(): string {
    return this._imagesDir
  }

  getItems(): ClipboardHistoryItem[] {
    return [...this._items]
  }

  getItemById(id: string): ClipboardHistoryItem | undefined {
    return this._items.find((i) => i.id === id)
  }

  addEntry(
    text: string,
    origin: Origin,
    timestamp?: string,
    id?: string,
    contentType?: ClipboardContentType
  ): ClipboardHistoryItem | null {
    if (!text || text.trim() === '') return null

    // If top item has exact same text and origin, don't duplicate
    if (this._items.length > 0 && this._items[0].kind === 'text' && this._items[0].text === text && this._items[0].origin === origin) {
      return null
    }

    const item: ClipboardHistoryItem = {
      id: id || randomUUID(),
      kind: 'text',
      contentType: contentType || classifyClipboardText(text),
      text,
      timestamp: timestamp || new Date().toISOString(),
      origin,
    }

    this._insertAndTrim(item)
    return item
  }

  addImageEntry(
    imageThumbnail: string,
    imagePath: string,
    origin: Origin,
    timestamp?: string,
    id?: string
  ): ClipboardHistoryItem | null {
    // If top item has exact same image path and origin, don't duplicate
    if (this._items.length > 0 && this._items[0].kind === 'image' && this._items[0].imagePath === imagePath && this._items[0].origin === origin) {
      return null
    }

    const item: ClipboardHistoryItem = {
      id: id || randomUUID(),
      kind: 'image',
      contentType: 'image',
      imageThumbnail,
      imagePath,
      timestamp: timestamp || new Date().toISOString(),
      origin,
    }

    this._insertAndTrim(item)
    return item
  }

  private _insertAndTrim(item: ClipboardHistoryItem): void {
    // Prepend to list without reordering or removing other existing items
    this._items.unshift(item)

    // Cap at MAX_HISTORY_ITEMS (oldest drops off)
    if (this._items.length > MAX_HISTORY_ITEMS) {
      const evicted = this._items.slice(MAX_HISTORY_ITEMS)
      this._items = this._items.slice(0, MAX_HISTORY_ITEMS)
      for (const ev of evicted) {
        this._deleteImageFile(ev.imagePath)
      }
    }

    this._save()
    this._notifyListeners()
  }

  onUpdate(callback: (items: ClipboardHistoryItem[]) => void): void {
    this._listeners.push(callback)
  }

  clear(): void {
    for (const item of this._items) {
      this._deleteImageFile(item.imagePath)
    }
    this._items = []
    this._save()
    this._notifyListeners()
  }

  private _deleteImageFile(imagePath?: string): void {
    if (!imagePath) return
    try {
      if (fs.existsSync(imagePath)) {
        fs.unlinkSync(imagePath)
        console.log(`[ClipboardHistory] Evicted & unlinked image file: ${imagePath}`)
      }
    } catch (e) {
      console.warn(`[ClipboardHistory] Failed to unlink image file ${imagePath}:`, e)
    }
  }

  private _pruneOrphanedImages(): void {
    if (!this._imagesDir || !fs.existsSync(this._imagesDir)) return
    try {
      const activePaths = new Set(
        this._items
          .filter((i) => i.kind === 'image' && !!i.imagePath)
          .map((i) => path.resolve(i.imagePath!))
      )
      const files = fs.readdirSync(this._imagesDir)
      for (const file of files) {
        const fullPath = path.resolve(path.join(this._imagesDir, file))
        if (!activePaths.has(fullPath)) {
          try {
            fs.unlinkSync(fullPath)
            console.log(`[ClipboardHistory] Pruned orphaned cached image: ${fullPath}`)
          } catch {}
        }
      }
    } catch (e) {
      console.warn('[ClipboardHistory] Error during orphaned image prune:', e)
    }
  }

  private _notifyListeners(): void {
    for (const listener of this._listeners) {
      try {
        listener(this.getItems())
      } catch (e) {
        console.error('[ClipboardHistory] Error notifying listener:', e)
      }
    }
  }

  private _load(): void {
    if (!this._filePath || !fs.existsSync(this._filePath)) {
      this._items = []
      return
    }

    try {
      const content = fs.readFileSync(this._filePath, 'utf8')
      const parsed = JSON.parse(content)
      if (Array.isArray(parsed)) {
        this._items = parsed.slice(0, MAX_HISTORY_ITEMS).map((raw) => {
          const item = raw as Partial<ClipboardHistoryItem>
          return {
            id: item.id || randomUUID(),
            kind: item.kind || 'text',
            contentType: item.contentType || (item.kind === 'image' ? 'image' : classifyClipboardText(item.text || '')),
            text: item.text,
            imageThumbnail: item.imageThumbnail,
            imagePath: item.imagePath,
            timestamp: item.timestamp || new Date().toISOString(),
            origin: item.origin || 'windows',
          }
        })
      } else {
        this._items = []
      }
    } catch (err) {
      console.warn('[ClipboardHistory] Failed to parse history file, starting fresh:', err)
      this._items = []
    }
  }

  private _save(): void {
    if (!this._filePath) return
    try {
      fs.writeFileSync(this._filePath, JSON.stringify(this._items, null, 2), 'utf8')
    } catch (err) {
      console.error('[ClipboardHistory] Failed to save history to file:', err)
    }
  }
}

export const ClipboardHistoryService = new ClipboardHistoryServiceClass()
