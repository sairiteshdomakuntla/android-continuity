package com.example.bridge_core

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class SystemChannelHandler(
    private val context: Context,
    private val activityProvider: () -> Activity?
) {
    companion object {
        const val SYSTEM_CHANNEL = "bridge/system"
        const val NOTIF_PERM_REQUEST_CODE = 1001
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
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                            data = Uri.parse("package:${context.packageName}")
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        context.startActivity(intent)
                    }
                    result.success(true)
                } catch (e: Exception) {
                    try {
                        val fallbackIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
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

            else -> result.notImplemented()
        }
    }
}
