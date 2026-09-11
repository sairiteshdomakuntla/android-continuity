package com.example.bridge_core

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArrayList

class NotificationsChannelHandler(private val context: Context) {

    companion object {
        const val NOTIFICATION_CHANNEL = "bridge/notifications"
        private val activeChannels = CopyOnWriteArrayList<MethodChannel>()
        private val mainHandler = Handler(Looper.getMainLooper())

        init {
            // Hook listener callback to broadcast events to all attached Flutter engines
            BridgeNotificationListenerService.onNotificationEvent = { event ->
                mainHandler.post {
                    for (channel in activeChannels) {
                        try {
                            channel.invokeMethod("onNotificationEvent", event)
                        } catch (e: Exception) {
                            // Channel might be detached
                        }
                    }
                }
            }
        }

        fun registerChannel(channel: MethodChannel) {
            activeChannels.add(channel)
        }

        fun unregisterChannel(channel: MethodChannel) {
            activeChannels.remove(channel)
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isNotificationAccessGranted" -> {
                try {
                    val enabledPackages = NotificationManagerCompat.getEnabledListenerPackages(context)
                    val granted = enabledPackages.contains(context.packageName)
                    result.success(granted)
                } catch (e: Exception) {
                    result.error("PERMISSION_CHECK_ERROR", e.message, null)
                }
            }

            "requestNotificationAccess" -> {
                try {
                    val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    context.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("INTENT_ERROR", e.message, null)
                }
            }

            "sendReply" -> {
                val notificationId = call.argument<String>("notificationId") ?: ""
                val replyText = call.argument<String>("replyText") ?: ""

                if (notificationId.isEmpty()) {
                    result.error("INVALID_ARG", "notificationId is required", null)
                    return
                }

                val success = BridgeNotificationListenerService.sendReply(notificationId, replyText)
                result.success(success)
            }

            "dismissNotification" -> {
                val notificationId = call.argument<String>("notificationId") ?: ""

                if (notificationId.isEmpty()) {
                    result.error("INVALID_ARG", "notificationId is required", null)
                    return
                }

                val success = BridgeNotificationListenerService.cancelNotificationById(notificationId)
                result.success(success)
            }

            else -> result.notImplemented()
        }
    }
}
