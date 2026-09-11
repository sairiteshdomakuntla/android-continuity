import { Notification } from 'electron'
import { randomUUID } from 'node:crypto'
import { SocketService } from './SocketService.js'
import { NotificationHistoryService } from './NotificationHistoryService.js'
import type {
  BridgeMessage,
  NotificationPayload,
  NotificationReplyPayload,
  NotificationDismissRequestPayload,
} from '../types/protocol.js'

class NotificationServiceClass {
  private _started = false

  start(): void {
    if (this._started) return
    this._started = true

    console.log('[NotificationService] Notification service initialized and listening')

    SocketService.onMessage('notification', (rawMsg: BridgeMessage) => {
      const msg = rawMsg as BridgeMessage<NotificationPayload>
      const payload = msg.payload
      if (!payload || !payload.event) return

      console.log(`[NotificationService] [RECV] Event: ${payload.event} for id: ${payload.notificationId}`)

      switch (payload.event) {
        case 'posted': {
          NotificationHistoryService.addOrUpdate(payload)

          // Native Windows OS notification toast
          try {
            if (Notification.isSupported()) {
              const titleText = payload.appName
                ? `${payload.appName} • ${payload.title}`
                : payload.title || 'New Notification'
              const toast = new Notification({
                title: titleText,
                body: payload.text,
                silent: false,
              })
              toast.show()
            }
          } catch (err) {
            console.warn('[NotificationService] Failed to show OS notification toast:', err)
          }
          break
        }

        case 'dismissed': {
          NotificationHistoryService.remove(payload.notificationId)
          break
        }

        case 'reply-failed': {
          console.warn(`[NotificationService] Reply failed for ${payload.notificationId}: ${payload.error}`)
          NotificationHistoryService.markReplyFailed(payload.notificationId, payload.error)
          break
        }
      }
    })
  }

  sendReply(notificationId: string, replyText: string): void {
    NotificationHistoryService.clearReplyError(notificationId)

    const msg: BridgeMessage<NotificationReplyPayload> = {
      eventId: randomUUID(),
      type: 'notification',
      origin: 'windows',
      timestamp: new Date().toISOString(),
      payload: {
        event: 'reply',
        notificationId,
        replyText,
      },
    }

    console.log(`[NotificationService] [SEND] Sending reply for ${notificationId}: "${replyText}"`)
    SocketService.broadcast(msg as BridgeMessage<unknown>)
  }

  dismissNotification(notificationId: string): void {
    NotificationHistoryService.remove(notificationId)

    const msg: BridgeMessage<NotificationDismissRequestPayload> = {
      eventId: randomUUID(),
      type: 'notification',
      origin: 'windows',
      timestamp: new Date().toISOString(),
      payload: {
        event: 'dismiss-request',
        notificationId,
      },
    }

    console.log(`[NotificationService] [SEND] Sending dismiss-request for ${notificationId}`)
    SocketService.broadcast(msg as BridgeMessage<unknown>)
  }
}

export const NotificationService = new NotificationServiceClass()
