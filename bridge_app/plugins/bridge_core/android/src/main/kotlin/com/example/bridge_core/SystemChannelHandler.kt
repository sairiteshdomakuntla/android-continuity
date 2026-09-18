package com.example.bridge_core

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.graphics.drawable.IconCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

class SystemChannelHandler(
    private val context: Context,
    private val activityProvider: () -> Activity?
) {
    companion object {
        const val SYSTEM_CHANNEL = "bridge/system"
        const val NOTIF_PERM_REQUEST_CODE = 1001

        private val batteryChannels = CopyOnWriteArrayList<MethodChannel>()
        private val mainHandler = Handler(Looper.getMainLooper())
        private val batteryReceiverRegistered = AtomicBoolean(false)

        private val batteryReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != Intent.ACTION_BATTERY_CHANGED) return
                val state = readBatteryState(intent) ?: return
                mainHandler.post {
                    for (channel in batteryChannels) {
                        try {
                            channel.invokeMethod("onBatteryChanged", state)
                        } catch (e: Exception) {
                            // Channel might be detached
                        }
                    }
                }
            }
        }

        /** Reads level 0–100 + charging from a battery-changed intent. */
        fun readBatteryState(intent: Intent): Map<String, Any>? {
            return try {
                val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                if (level < 0 || scale <= 0) return null
                val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL
                mapOf(
                    "level" to (level * 100 / scale),
                    "isCharging" to isCharging,
                )
            } catch (e: Exception) {
                null
            }
        }

        fun registerBatteryChannel(context: Context, channel: MethodChannel) {
            batteryChannels.add(channel)
            // ACTION_BATTERY_CHANGED is sticky + protected: dynamic registration
            // only, once per process. The sticky intent replays immediately.
            if (batteryReceiverRegistered.compareAndSet(false, true)) {
                try {
                    context.applicationContext.registerReceiver(
                        batteryReceiver,
                        IntentFilter(Intent.ACTION_BATTERY_CHANGED),
                    )
                } catch (e: Exception) {
                    batteryReceiverRegistered.set(false)
                    android.util.Log.w("SystemChannelHandler", "battery receiver failed: $e")
                }
            }
        }

        fun unregisterBatteryChannel(channel: MethodChannel) {
            batteryChannels.remove(channel)
        }

        // ── "Sync Now" trampoline fan-out ─────────────────────────────
        // Every attached Flutter engine (UI + background isolate) gets a
        // turn; Dart decides which isolate acts. The background isolate
        // owns the socket and runs the real pipeline.
        private val clipSyncChannels = CopyOnWriteArrayList<MethodChannel>()

        fun registerClipSyncChannel(channel: MethodChannel) {
            clipSyncChannels.add(channel)
        }

        fun unregisterClipSyncChannel(channel: MethodChannel) {
            clipSyncChannels.remove(channel)
        }

        fun pushTrampolineClipboard(text: String) {
            mainHandler.post {
                for (channel in clipSyncChannels) {
                    try {
                        channel.invokeMethod(
                            "onTrampolineClipboard", mapOf("text" to text))
                    } catch (e: Exception) {
                        // Channel might be detached
                    }
                }
            }
        }
    }

    /**
     * Finds the most recent screenshot in MediaStore.
     * Returns Triple(row ID, dateTakenMs, mimeType) or null.
     * Screenshots live in a "Screenshots" bucket on most OEMs; as a fallback
     * the newest images are scanned for screenshot-like names/paths.
     */
    private fun findLatestScreenshot(collection: Uri, projection: Array<String>): Triple<Long, Long, String?>? {
        val resolver = context.contentResolver
        val idCol = MediaStore.Images.Media._ID

        fun rowToTriple(cursor: android.database.Cursor): Triple<Long, Long, String?>? {
            val id = cursor.getLong(cursor.getColumnIndexOrThrow(idCol))
            val takenIdx = cursor.getColumnIndex(MediaStore.Images.Media.DATE_TAKEN)
            val addedIdx = cursor.getColumnIndex(MediaStore.Images.Media.DATE_ADDED)
            val mimeIdx = cursor.getColumnIndex(MediaStore.Images.Media.MIME_TYPE)
            val taken = if (takenIdx >= 0) cursor.getLong(takenIdx) else 0L
            val added = if (addedIdx >= 0) cursor.getLong(addedIdx) else 0L
            val dateTakenMs = if (taken > 0) taken else added * 1000L
            val mime = if (mimeIdx >= 0) cursor.getString(mimeIdx) else null
            return Triple(id, dateTakenMs, mime)
        }

        // 1. Direct bucket match (covers Samsung, Pixel, Xiaomi, Oppo, Vivo…).
        try {
            resolver.query(
                collection,
                projection,
                "${MediaStore.Images.Media.BUCKET_DISPLAY_NAME} = ?",
                arrayOf("Screenshots"),
                "${MediaStore.Images.Media.DATE_TAKEN} DESC"
            )?.use { cursor ->
                if (cursor.moveToFirst()) return rowToTriple(cursor)
            }
        } catch (e: Exception) {
            android.util.Log.w("SystemChannelHandler", "screenshot bucket query failed", e)
        }

        // 2. Fallback: scan newest images for screenshot-like bucket/name.
        try {
            resolver.query(
                collection,
                projection,
                null,
                null,
                "${MediaStore.Images.Media.DATE_ADDED} DESC"
            )?.use { cursor ->
                val bucketIdx = cursor.getColumnIndex(MediaStore.Images.Media.BUCKET_DISPLAY_NAME)
                val nameIdx = cursor.getColumnIndex(MediaStore.Images.Media.DISPLAY_NAME)
                var scanned = 0
                while (cursor.moveToNext() && scanned < 30) {
                    scanned++
                    val bucket = if (bucketIdx >= 0) cursor.getString(bucketIdx) ?: "" else ""
                    val name = if (nameIdx >= 0) cursor.getString(nameIdx) ?: "" else ""
                    if (bucket.equals("Screenshots", ignoreCase = true) ||
                        bucket.contains("screenshot", ignoreCase = true) ||
                        name.startsWith("Screenshot", ignoreCase = true)
                    ) {
                        return rowToTriple(cursor)
                    }
                }
            }
        } catch (e: Exception) {
            android.util.Log.w("SystemChannelHandler", "screenshot scan query failed", e)
        }
        return null
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isIgnoringBatteryOptimizations" -> {
                val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                val isIgnoring = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && pm != null) {
                    pm.isIgnoringBatteryOptimizations(context.packageName)
                } else {
                    true
                }
                result.success(isIgnoring)
            }

            "requestIgnoreBatteryOptimizations" -> {
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        context.startActivity(intent)
                    }
                    result.success(true)
                } catch (e: Exception) {
                    try {
                        val fallbackIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = Uri.parse("package:${context.packageName}")
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        context.startActivity(fallbackIntent)
                        result.success(true)
                    } catch (e2: Exception) {
                        result.error("INTENT_ERROR", e2.message, null)
                    }
                }
            }

            "isNotificationPermissionGranted" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val granted = ContextCompat.checkSelfPermission(
                        context,
                        Manifest.permission.POST_NOTIFICATIONS
                    ) == PackageManager.PERMISSION_GRANTED
                    result.success(granted)
                } else {
                    result.success(true)
                }
            }

            "requestNotificationPermission" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val activity = activityProvider()
                    if (activity != null) {
                        ActivityCompat.requestPermissions(
                            activity,
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            NOTIF_PERM_REQUEST_CODE
                        )
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                } else {
                    result.success(true)
                }
            }

            "getClipboard" -> {
                try {
                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    if (clipboard == null) {
                        result.success(null)
                        return
                    }
                    val clip = clipboard.primaryClip
                    if (clip == null || clip.itemCount == 0) {
                        result.success(null)
                        return
                    }
                    val item = clip.getItemAt(0)
                    val uri = item.uri
                    val mimeType = if (uri != null) context.contentResolver.getType(uri) else null
                    val isImage = (mimeType?.startsWith("image/") == true) || (clip.description?.hasMimeType("image/*") == true)

                    if (isImage && uri != null) {
                        try {
                            val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                            if (bytes != null && bytes.isNotEmpty()) {
                                val imagesDir = File(context.cacheDir, "clipboard_images").apply { mkdirs() }
                                val cacheFile = File(imagesDir, "clip_${System.currentTimeMillis()}.png")
                                cacheFile.writeBytes(bytes)
                                result.success(mapOf(
                                    "type" to "image",
                                    "mimeType" to (mimeType ?: "image/png"),
                                    "uri" to uri.toString(),
                                    "path" to cacheFile.absolutePath,
                                    "bytes" to bytes
                                ))
                                return
                            }
                        } catch (e: Exception) {
                            android.util.Log.w("SystemChannelHandler", "Failed to read clipboard image uri $uri", e)
                        }
                    }

                    val text = item.text?.toString() ?: item.coerceToText(context)?.toString()
                    if (!text.isNullOrEmpty()) {
                        result.success(mapOf(
                            "type" to "text",
                            "text" to text
                        ))
                        return
                    }

                    result.success(null)
                } catch (e: Exception) {
                    result.error("CLIPBOARD_READ_ERROR", e.message, null)
                }
            }

            "setClipboard" -> {
                val text = call.argument<String>("text") ?: ""
                try {
                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    if (clipboard != null) {
                        Handler(Looper.getMainLooper()).post {
                            try {
                                val clip = ClipData.newPlainText("Bridge", text)
                                clipboard.setPrimaryClip(clip)
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("CLIPBOARD_WRITE_ERROR", e.message, null)
                            }
                        }
                    } else {
                        result.error("NO_CLIPBOARD_SERVICE", "ClipboardManager unavailable", null)
                    }
                } catch (e: Exception) {
                    result.error("CLIPBOARD_EXCEPTION", e.message, null)
                }
            }

            "setClipboardImage" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("ARG", "path required", null)
                    return
                }
                try {
                    val file = File(path)
                    if (!file.exists()) {
                        result.error("FILE_NOT_FOUND", "Image file does not exist: $path", null)
                        return
                    }
                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    if (clipboard != null) {
                        Handler(Looper.getMainLooper()).post {
                            try {
                                val authority = "${context.packageName}.fileprovider"
                                val contentUri = FileProvider.getUriForFile(context, authority, file)
                                val clip = ClipData.newUri(context.contentResolver, "Bridge Clipboard Image", contentUri)
                                clipboard.setPrimaryClip(clip)
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("CLIPBOARD_WRITE_ERROR", e.message, null)
                            }
                        }
                    } else {
                        result.error("NO_CLIPBOARD_SERVICE", "ClipboardManager unavailable", null)
                    }
                } catch (e: Exception) {
                    result.error("CLIPBOARD_EXCEPTION", e.message, null)
                }
            }

            "getClipboardCacheDir" -> {
                try {
                    val imagesDir = File(context.cacheDir, "clipboard_images").apply { mkdirs() }
                    result.success(imagesDir.absolutePath)
                } catch (e: Exception) {
                    result.error("IO", e.message, null)
                }
            }

            "getLatestScreenshot" -> {
                // Screenshots are saved to MediaStore (never to the clipboard),
                // so Bridge queries the latest one explicitly for Windows pasting.
                try {
                    val readPerm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        Manifest.permission.READ_MEDIA_IMAGES
                    } else {
                        Manifest.permission.READ_EXTERNAL_STORAGE
                    }
                    if (ContextCompat.checkSelfPermission(context, readPerm) != PackageManager.PERMISSION_GRANTED) {
                        result.success(mapOf("needsPermission" to true))
                        return
                    }

                    val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
                    } else {
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                    }
                    val projection = arrayOf(
                        MediaStore.Images.Media._ID,
                        MediaStore.Images.Media.DATE_TAKEN,
                        MediaStore.Images.Media.DATE_ADDED,
                        MediaStore.Images.Media.MIME_TYPE,
                        MediaStore.Images.Media.DISPLAY_NAME,
                        MediaStore.Images.Media.BUCKET_DISPLAY_NAME
                    )

                    val found = findLatestScreenshot(collection, projection)
                    if (found == null) {
                        result.success(null)
                        return
                    }

                    val (shotId, dateTakenMs, mimeType) = found
                    val shotUri = ContentUris.withAppendedId(collection, shotId)
                    val bytes = try {
                        context.contentResolver.openInputStream(shotUri)?.use { it.readBytes() }
                    } catch (e: Exception) {
                        android.util.Log.w("SystemChannelHandler", "Failed to read screenshot uri $shotUri", e)
                        null
                    }
                    if (bytes == null || bytes.isEmpty()) {
                        result.success(null)
                        return
                    }

                    val imagesDir = File(context.cacheDir, "clipboard_images").apply { mkdirs() }
                    val cacheFile = File(imagesDir, "shot_${shotId}.png")
                    cacheFile.writeBytes(bytes)
                    result.success(mapOf(
                        "type" to "screenshot",
                        "id" to shotId.toString(),
                        "dateTakenMs" to dateTakenMs,
                        "mimeType" to (mimeType ?: "image/png"),
                        "path" to cacheFile.absolutePath
                    ))
                } catch (e: Exception) {
                    result.error("SCREENSHOT_READ_ERROR", e.message, null)
                }
            }

            // ── Battery state (one-shot read; changes stream via onBatteryChanged)
            "getBatteryState" -> {
                try {
                    val sticky = context.applicationContext.registerReceiver(
                        null,
                        IntentFilter(Intent.ACTION_BATTERY_CHANGED),
                    )
                    val state = sticky?.let { readBatteryState(it) }
                    if (state != null) result.success(state)
                    else result.error("UNAVAILABLE", "Battery state unavailable", null)
                } catch (e: Exception) {
                    result.error("BATTERY_ERROR", e.message, null)
                }
            }

            // ── Find-my-phone ringer ──────────────────────────────────────
            "startRing" -> {
                try {
                    RingManager.startRing(context.applicationContext)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("RING_ERROR", e.message, null)
                }
            }

            "stopRing" -> {
                try {
                    RingManager.stopRing(context.applicationContext)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("RING_ERROR", e.message, null)
                }
            }

            "isRinging" -> {
                result.success(RingManager.isRinging())
            }

            // ── Persistent-notification "Sync Now" action ─────────────
            // Augments the flutter_background_service foreground
            // notification in place (same id, same channel — no new
            // notification, no new channel). Re-applied on service start
            // and app resume: the plugin re-posts a bare notification on
            // restart, wiping the action. No special permissions involved.
            "ensureSyncNowAction" -> {
                try {
                    result.success(ensureSyncNowAction(context.applicationContext))
                } catch (e: Exception) {
                    result.error("NOTIF_ERROR", e.message, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Clones the live persistent notification (title, text, icon, tap
     * behavior) and re-posts it with a "Sync Now" action that launches
     * the transparent ClipSyncActivity trampoline. Returns false when
     * the service notification isn't up yet (caller retries later).
     */
    private fun ensureSyncNowAction(appContext: Context): Boolean {
        // Must match flutter_background_service's Config default
        // ("foreground_notification_id", 112233) and the channel id
        // passed in AndroidConfiguration.
        val channelId = "bridge_foreground_service"
        val notifId = 112233
        try {
            val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE)
                as? NotificationManager ?: return false
            val base = try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    nm.activeNotifications.firstOrNull { it.id == notifId }
                        ?.notification
                } else {
                    null
                }
            } catch (_: Exception) {
                null
            } ?: return false

            val openSync = Intent().apply {
                setClassName(
                    appContext.packageName,
                    "${appContext.packageName}.ClipSyncActivity"
                )
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val syncTap = PendingIntent.getActivity(
                appContext, 7701, openSync, pendingFlags)

            val builder = NotificationCompat.Builder(appContext, channelId)
                .setOngoing(true)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setWhen(base.`when`)
                .addAction(
                    android.R.drawable.ic_popup_sync,
                    "Sync Now", syncTap)

            val extras = base.extras
            builder.setContentTitle(extras.getCharSequence(Notification.EXTRA_TITLE))
            builder.setContentText(extras.getCharSequence(Notification.EXTRA_TEXT))

            // Preserve tap-to-open; fall back to a plain launch intent.
            val tap = base.contentIntent ?: try {
                val launch = appContext.packageManager
                    .getLaunchIntentForPackage(appContext.packageName)
                if (launch != null) PendingIntent.getActivity(
                    appContext, 7702, launch, pendingFlags) else null
            } catch (_: Exception) {
                null
            }
            builder.setContentIntent(tap)

            // Clone the small icon (plugin's own); fall back to the app
            // icon — a valid small icon is mandatory for notify().
            var iconSet = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    val si = base.smallIcon
                    if (si != null) {
                        val compat: IconCompat? =
                            IconCompat.createFromIcon(appContext, si)
                        if (compat != null) {
                            builder.setSmallIcon(compat)
                            iconSet = true
                        }
                    }
                } catch (_: Exception) {
                }
            }
            if (!iconSet) {
                val appIcon = appContext.applicationInfo.icon
                if (appIcon != 0) {
                    builder.setSmallIcon(appIcon)
                    iconSet = true
                }
            }
            if (!iconSet) return false

            nm.notify(notifId, builder.build())
            return true
        } catch (e: Exception) {
            android.util.Log.w("SystemChannelHandler",
                "ensureSyncNowAction failed: $e")
            return false
        }
    }
}
