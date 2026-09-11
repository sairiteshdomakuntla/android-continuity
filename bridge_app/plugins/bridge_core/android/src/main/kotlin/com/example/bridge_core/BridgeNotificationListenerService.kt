package com.example.bridge_core

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Intent
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap

class BridgeNotificationListenerService : NotificationListenerService() {

    data class CachedReply(
        val pendingIntent: PendingIntent,
        val remoteInput: RemoteInput
    )

    companion object {
        private const val TAG = "BridgeNotifListener"

        @Volatile
        var instance: BridgeNotificationListenerService? = null
            private set

        /**
         * Global callback invoked when notifications are posted or removed.
         * Broadcasts to active Flutter engines via bridge_core.
         */
        var onNotificationEvent: ((Map<String, Any?>) -> Unit)? = null

        private val activeReplies = ConcurrentHashMap<String, CachedReply>()

        fun sendReply(notificationId: String, replyText: String): Boolean {
            val service = instance
            if (service == null) {
                Log.w(TAG, "Cannot send reply: BridgeNotificationListenerService instance is null")
                return false
            }
            return service.executeReply(notificationId, replyText)
        }

        fun cancelNotificationById(notificationId: String): Boolean {
            val service = instance
            if (service == null) {
                Log.w(TAG, "Cannot cancel notification: BridgeNotificationListenerService instance is null")
                return false
            }
            return service.executeCancel(notificationId)
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        Log.i(TAG, "BridgeNotificationListenerService connected and active")
    }

    override fun onListenerDisconnected() {
        if (instance == this) {
            instance = null
        }
        Log.i(TAG, "BridgeNotificationListenerService disconnected")
        super.onListenerDisconnected()
    }

    override fun onDestroy() {
        if (instance == this) {
            instance = null
        }
        activeReplies.clear()
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        if (sbn == null) return

        val pkgName = sbn.packageName ?: return

        // 1. Filter out Bridge's own notifications (foreground service, file transfers, etc.)
        if (pkgName == packageName) return

        val notification = sbn.notification ?: return

        // 2. Filter out group summary notifications (WhatsApp, Gmail, etc.) to prevent duplicates
        if ((notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0) {
            Log.d(TAG, "Filtering out group summary notification from $pkgName (key=${sbn.key})")
            return
        }

        // 3. Filter out ongoing events (foreground services, downloads, persistent monitors)
        if ((notification.flags and Notification.FLAG_ONGOING_EVENT) != 0) {
            return
        }

        val extras = notification.extras
        val title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            ?: extras?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: ""

        // Skip blank notifications
        if (title.isBlank() && text.isBlank()) return

        // Resolve user-friendly App Name
        val pm = packageManager
        val appName = try {
            pm.getApplicationLabel(pm.getApplicationInfo(pkgName, 0)).toString()
        } catch (e: Exception) {
            pkgName
        }

        // Inspect notification actions for Direct Reply (RemoteInput)
        var replyAction: Notification.Action? = null
        var replyRemoteInput: RemoteInput? = null
        val quickActions = mutableListOf<String>()

        notification.actions?.forEach { action ->
            val actionTitle = action.title?.toString() ?: ""
            if (actionTitle.isNotBlank()) {
                quickActions.add(actionTitle)
            }

            if (replyAction == null && action.remoteInputs != null && action.remoteInputs.isNotEmpty()) {
                replyAction = action
                replyRemoteInput = action.remoteInputs[0]
            }
        }

        // Cache reply action if available
        if (replyAction != null && replyRemoteInput != null && replyAction.actionIntent != null) {
            activeReplies[sbn.key] = CachedReply(replyAction.actionIntent, replyRemoteInput)
            Log.d(TAG, "Cached Direct Reply action for notification: ${sbn.key}")
        } else {
            activeReplies.remove(sbn.key)
        }

        val timestamp = try {
            val millis = if (sbn.postTime > 0) sbn.postTime else System.currentTimeMillis()
            Instant.ofEpochMilli(millis).toString()
        } catch (e: Exception) {
            Instant.now().toString()
        }

        val payload = mapOf<String, Any?>(
            "event" to "posted",
            "notificationId" to sbn.key,
            "packageName" to pkgName,
            "appName" to appName,
            "title" to title,
            "text" to text,
            "timestamp" to timestamp,
            "hasReplyAction" to (replyAction != null),
            "hasQuickActions" to quickActions
        )

        Log.d(TAG, "Forwarding notification [posted] from $appName: \"$title\" - \"$text\" (reply=${replyAction != null})")
        onNotificationEvent?.invoke(payload)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        super.onNotificationRemoved(sbn)
        if (sbn == null) return

        val pkgName = sbn.packageName ?: return
        if (pkgName == packageName) return

        activeReplies.remove(sbn.key)

        val payload = mapOf<String, Any?>(
            "event" to "dismissed",
            "notificationId" to sbn.key
        )

        Log.d(TAG, "Forwarding notification [dismissed]: ${sbn.key}")
        onNotificationEvent?.invoke(payload)
    }

    private fun executeReply(notificationId: String, replyText: String): Boolean {
        val cached = activeReplies[notificationId]
        if (cached == null) {
            Log.w(TAG, "Reply failed: no active CachedReply for notificationId: $notificationId")
            return false
        }

        return try {
            val intent = Intent()
            val bundle = Bundle()
            bundle.putCharSequence(cached.remoteInput.resultKey, replyText)
            RemoteInput.addResultsToIntent(arrayOf(cached.remoteInput), intent, bundle)

            cached.pendingIntent.send(this, 0, intent)
            Log.i(TAG, "Successfully triggered RemoteInput reply for $notificationId with text: \"$replyText\"")
            true
        } catch (e: PendingIntent.CanceledException) {
            Log.w(TAG, "Reply failed: PendingIntent was canceled for $notificationId: ${e.message}")
            false
        } catch (e: Exception) {
            Log.e(TAG, "Reply failed with unexpected exception for $notificationId: ${e.message}", e)
            false
        }
    }

    private fun executeCancel(notificationId: String): Boolean {
        return try {
            cancelNotification(notificationId)
            activeReplies.remove(notificationId)
            Log.i(TAG, "Successfully cancelled notification: $notificationId")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to cancel notification $notificationId: ${e.message}", e)
            false
        }
    }
}
