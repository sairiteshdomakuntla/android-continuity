import type { NotificationPostedPayload } from '../types/protocol.js'

export interface NotificationItem {
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

const MAX_NOTIFICATIONS = 20

class NotificationHistoryServiceClass {
  private _items: NotificationItem[] = []
  private _listeners: Array<(items: NotificationItem[]) => void> = []
  // Last seen content per id — lets callers tell a genuinely new/changed
  // alert apart from Android's frequent identical re-posts of the same key.
  private _lastContent = new Map<string, string>()

  getItems(): NotificationItem[] {
    return [...this._items]
  }

  /**
   * Inserts or refreshes an item.
   * @returns 'new' for a never-seen id, 'changed' when title/text differ
   * from the last seen content, 'same' for an identical re-post.
   */
  addOrUpdate(payload: NotificationPostedPayload): 'new' | 'changed' | 'same' {
    const existingIndex = this._items.findIndex((i) => i.notificationId === payload.notificationId)

    const item: NotificationItem = {
      notificationId: payload.notificationId,
      packageName: payload.packageName,
      appName: payload.appName,
      title: payload.title,
      text: payload.text,
      timestamp: payload.timestamp || new Date().toISOString(),
      hasReplyAction: payload.hasReplyAction,
      hasQuickActions: payload.hasQuickActions || [],
      // Clear previous error on updated notification
      replyError: undefined,
    }

    const contentSig = `${payload.title || ''}\n${payload.text || ''}`
    const prevSig = this._lastContent.get(payload.notificationId)
    this._lastContent.set(payload.notificationId, contentSig)

    if (existingIndex >= 0) {
      // Update existing
      this._items[existingIndex] = item
      this._notifyListeners()
      return prevSig === contentSig ? 'same' : 'changed'
    }

    // Prepend new notification
    this._items.unshift(item)
    if (this._items.length > MAX_NOTIFICATIONS) {
      const evicted = this._items.slice(MAX_NOTIFICATIONS)
      this._items = this._items.slice(0, MAX_NOTIFICATIONS)
      for (const e of evicted) this._lastContent.delete(e.notificationId)
    }

    this._notifyListeners()
    return 'new'
  }

  remove(notificationId: string): void {
    const beforeLen = this._items.length
    this._items = this._items.filter((i) => i.notificationId !== notificationId)
    this._lastContent.delete(notificationId)
    if (this._items.length !== beforeLen) {
      this._notifyListeners()
    }
  }

  markReplyFailed(notificationId: string, error?: string): void {
    const item = this._items.find((i) => i.notificationId === notificationId)
    if (item) {
      item.replyError = error || "Couldn't send — try again"
      this._notifyListeners()
    }
  }

  clearReplyError(notificationId: string): void {
    const item = this._items.find((i) => i.notificationId === notificationId)
    if (item && item.replyError) {
      item.replyError = undefined
      this._notifyListeners()
    }
  }

  clear(): void {
    this._items = []
    this._lastContent.clear()
    this._notifyListeners()
  }

  onUpdate(callback: (items: NotificationItem[]) => void): void {
    this._listeners.push(callback)
  }

  private _notifyListeners(): void {
    const items = this.getItems()
    for (const listener of this._listeners) {
      try {
        listener(items)
      } catch (e) {
        console.error('[NotificationHistory] Error notifying listener:', e)
      }
    }
  }
}

export const NotificationHistoryService = new NotificationHistoryServiceClass()
