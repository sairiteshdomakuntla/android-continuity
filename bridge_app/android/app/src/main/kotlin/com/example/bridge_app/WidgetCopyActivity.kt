package com.example.bridge_app

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File

/**
 * Lightweight tap-to-copy trampoline for the home-screen widget.
 *
 * Unlike [ShareTargetActivity] this does NOT boot a Flutter engine: it
 * reads the widget snapshot file, writes the item straight to the system
 * clipboard natively, toasts, and finishes — the full app never opens.
 *
 * Transparent + noHistory + excluded from recents so there is no visible
 * flash. Exported (like ShareTargetActivity) because widget PendingIntents
 * are delivered by the launcher host process.
 */
class WidgetCopyActivity : Activity() {

    companion object {
        private const val TAG = "BridgeWidgetCopy"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleCopy(intent.getStringExtra(BridgeWidgetUpdater.EXTRA_ITEM_ID))
        finish()
    }

    private fun handleCopy(itemId: String?) {
        if (itemId.isNullOrEmpty()) {
            toast("Open Bridge to reconnect")
            return
        }
        val item = findItem(itemId)
        if (item == null) {
            toast("Item no longer available")
            return
        }
        try {
            val clipboard =
                getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            if (item.optString("kind") == "image") {
                val path = item.optString("imagePath")
                val file = if (path.isNotEmpty()) File(path) else null
                if (file == null || !file.exists()) {
                    toast("Image no longer available")
                    return
                }
                val uri = FileProvider.getUriForFile(
                    this, "${packageName}.fileprovider", file)
                val clip = ClipData.newUri(contentResolver, "Bridge image", uri)
                clipboard.setPrimaryClip(clip)
            } else {
                val text = item.optString("preview", "")
                if (text.isEmpty()) {
                    toast("Nothing to copy")
                    return
                }
                clipboard.setPrimaryClip(ClipData.newPlainText("Bridge", text))
            }
            toast("Copied to clipboard")
            // Refresh the widget (cheap; keeps counts consistent).
            BridgeWidgetUpdater.updateAll(this)
        } catch (e: Exception) {
            Log.w(TAG, "copy failed: $e")
            toast("Copy failed")
        }
    }

    private fun findItem(itemId: String): JSONObject? {
        return try {
            val file = BridgeWidgetUpdater.snapshotFile(this)
            if (!file.exists()) return null
            val arr = JSONObject(file.readText()).optJSONArray("items")
                ?: return null
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (o.optString("id") == itemId) return o
            }
            null
        } catch (e: Exception) {
            Log.w(TAG, "findItem failed: $e")
            null
        }
    }

    private fun toast(msg: String) {
        Toast.makeText(applicationContext, msg, Toast.LENGTH_SHORT).show()
    }
}
