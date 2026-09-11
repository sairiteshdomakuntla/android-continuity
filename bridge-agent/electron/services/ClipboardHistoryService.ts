import { app } from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import type { ClipboardHistoryItem, Origin } from '../types/protocol.js'

const MAX_HISTORY_ITEMS = 20

class ClipboardHistoryServiceClass {
  private _items: ClipboardHistoryItem[] = []
  private _filePath: string = ''
  private _listeners: Array<(items: ClipboardHistoryItem[]) => void> = []

  init(): void {
    try {
      const userData = app.getPath('userData')
      this._filePath = path.join(userData, 'clipboard-history.json')
      this._load()
      console.log(`[ClipboardHistory] Initialized with ${this._items.length} items from ${this._filePath}`)
    } catch (err) {
      console.warn('[ClipboardHistory] Failed to initialize history storage:', err)
    }
  }

  getItems(): ClipboardHistoryItem[] {
    return [...this._items]
  }

  addEntry(text: string, origin: Origin, timestamp?: string, id?: string): ClipboardHistoryItem | null {
    if (!text || text.trim() === '') return null

    // If top item has exact same text and origin, don't duplicate
    if (this._items.length > 0 && this._items[0].text === text && this._items[0].origin === origin) {
      return null
    }

    const item: ClipboardHistoryItem = {
      id: id || randomUUID(),
      text,
      timestamp: timestamp || new Date().toISOString(),
      origin,
    }

    // Prepend to list without reordering or removing other existing items
    this._items.unshift(item)

    // Cap at MAX_HISTORY_ITEMS (oldest drops off)
    if (this._items.length > MAX_HISTORY_ITEMS) {
      this._items = this._items.slice(0, MAX_HISTORY_ITEMS)
    }

    this._save()
    this._notifyListeners()
    return item
  }

  onUpdate(callback: (items: ClipboardHistoryItem[]) => void): void {
    this._listeners.push(callback)
  }

  clear(): void {
    this._items = []
    this._save()
    this._notifyListeners()
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
        this._items = parsed.slice(0, MAX_HISTORY_ITEMS)
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
