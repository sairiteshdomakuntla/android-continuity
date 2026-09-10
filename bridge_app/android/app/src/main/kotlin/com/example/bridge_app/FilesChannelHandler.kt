package com.example.bridge_app

import android.content.ContentResolver
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream

/**
 * Handles all bridge/files MethodChannel calls.
 * Extracted so it can be reused by both MainActivity (warm start)
 * and ShareTargetActivity (cold start without a live MainActivity).
 */
class FilesChannelHandler(private val contentResolver: ContentResolver) {

    private val inputStreams  = mutableMapOf<String, InputStream>()
    private val outputStreams = mutableMapOf<String, OutputStream>()
    private val outputUris    = mutableMapOf<String, Uri>()

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "openContentUri" -> {
                val uriStr = call.argument<String>("uri")
                    ?: return result.error("ARG", "uri required", null)
                val token = call.argument<String>("token")
                    ?: return result.error("ARG", "token required", null)
                try {
                    val uri = Uri.parse(uriStr)
                    var fileName = "unknown"
                    var mimeType = contentResolver.getType(uri) ?: "application/octet-stream"
                    var totalBytes = -1L
                    contentResolver.query(uri, null, null, null, null)?.use { c ->
                        if (c.moveToFirst()) {
                            val nameIdx = c.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                            val sizeIdx = c.getColumnIndex(MediaStore.MediaColumns.SIZE)
                            if (nameIdx >= 0) fileName = c.getString(nameIdx) ?: fileName
                            if (sizeIdx >= 0) totalBytes = c.getLong(sizeIdx)
                        }
                    }
                    if (totalBytes < 0) {
                        totalBytes = contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L
                    }
                    inputStreams[token] = contentResolver.openInputStream(uri)!!
                    result.success(mapOf("fileName" to fileName, "mimeType" to mimeType, "totalBytes" to totalBytes))
                } catch (e: Exception) {
                    result.error("IO", e.message, null)
                }
            }

            "readChunk" -> {
                val token = call.argument<String>("token")
                    ?: return result.error("ARG", "token required", null)
                val stream = inputStreams[token]
                if (stream == null) { result.success(ByteArray(0)); return }
                try {
                    val buf  = ByteArray(65536)
                    val read = stream.read(buf)
                    result.success(if (read <= 0) ByteArray(0) else buf.copyOf(read))
                } catch (e: Exception) {
                    result.error("IO", e.message, null)
                }
            }

            "closeInputStream" -> {
                val token = call.argument<String>("token") ?: return result.success(null)
                inputStreams.remove(token)?.close()
                result.success(null)
            }

            "createDownload" -> {
                val fileName = call.argument<String>("fileName")
                    ?: return result.error("ARG", "fileName required", null)
                val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                val token = call.argument<String>("token")
                    ?: return result.error("ARG", "token required", null)
                try {
                    val values = ContentValues().apply {
                        put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                        put(MediaStore.Downloads.MIME_TYPE, mimeType)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            put(MediaStore.Downloads.RELATIVE_PATH, "Download/Bridge")
                            put(MediaStore.Downloads.IS_PENDING, 1)
                        }
                    }
                    val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    } else {
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI
                    }
                    var uri = contentResolver.insert(collection, values)
                    if (uri == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        // Fallback to generic external collection
                        uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    }
                    if (uri == null) {
                        android.util.Log.e("FilesChannelHandler", "insert returned null for $fileName")
                        return result.error("IO", "Failed to insert MediaStore download entry for $fileName", null)
                    }
                    val stream = contentResolver.openOutputStream(uri)
                        ?: return result.error("IO", "Failed to open output stream for $uri", null)
                    outputUris[token] = uri
                    outputStreams[token] = stream
                    result.success(uri.toString())
                } catch (e: Exception) {
                    android.util.Log.e("FilesChannelHandler", "createDownload failed", e)
                    result.error("IO", e.message, null)
                }
            }

            "writeChunk" -> {
                val token = call.argument<String>("token")
                    ?: return result.error("ARG", "token required", null)
                val data = call.argument<ByteArray>("data")
                    ?: return result.error("ARG", "data required", null)
                val stream = outputStreams[token]
                    ?: return result.error("IO", "No stream for token $token", null)
                try {
                    stream.write(data)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("IO", e.message, null)
                }
            }

            "finalizeDownload" -> {
                val token = call.argument<String>("token")
                    ?: return result.error("ARG", "token required", null)
                try {
                    outputStreams.remove(token)?.close()
                    val uri = outputUris.remove(token)
                    if (uri != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        val values = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
                        contentResolver.update(uri, values, null, null)
                    }
                    result.success(null)
                } catch (e: Exception) {
                    result.error("IO", e.message, null)
                }
            }

            "deleteDownload" -> {
                val token = call.argument<String>("token")
                    ?: return result.error("ARG", "token required", null)
                try {
                    outputStreams.remove(token)?.close()
                    val uri = outputUris.remove(token)
                    if (uri != null) contentResolver.delete(uri, null, null)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("IO", e.message, null)
                }
            }

            else -> result.notImplemented()
        }
    }
}
