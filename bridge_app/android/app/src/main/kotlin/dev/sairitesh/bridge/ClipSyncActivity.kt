package dev.sairitesh.bridge

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Transparent "Sync Now" trampoline for the persistent notification action.
 *
 * Holds real window focus for a moment (no SYSTEM_ALERT_WINDOW, no special
 * permissions — a plain translucent Activity is enough for the Android 10+
 * clipboard focus gate), reads the primary clip as text, broadcasts it to
 * [com.example.bridge_core.ClipSyncReceiver] (same-package explicit
 * broadcast; the app module cannot compile-depend on the bridge_core
 * module, so action/extra are literals), and finishes immediately —
 * the full app UI never opens, no visible flash.
 *
 * Text only, mirroring the foreground syncNow text path. Non-text or
 * empty clips are logged and dropped silently.
 */
class ClipSyncActivity : Activity() {

    companion object {
        private const val TAG = "BridgeClipSync"
        private const val ACTION_PUSH = "dev.sairitesh.bridge.CLIP_SYNC_PUSH"
        private const val EXTRA_TEXT = "text"
    }

    private var done = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private val fallback = Runnable {
        if (!done) {
            try {
                Log.i(TAG, "fallback fired hasFocus=${hasWindowFocus()}")
            } catch (_: Exception) {
            }
            finishRead()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    override fun onResume() {
        super.onResume()
        // Safety net: if onWindowFocusChanged(true) never arrives, still
        // attempt a read (with whatever focus state we have) and finish —
        // never strand an (invisible) Activity instance.
        mainHandler.postDelayed(fallback, 1200)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && !done) {
            finishRead()
        }
    }

    override fun onPause() {
        mainHandler.removeCallbacks(fallback)
        super.onPause()
    }

    private fun finishRead() {
        done = true
        mainHandler.removeCallbacks(fallback)
        val text = readClipboardText()
        if (!text.isNullOrEmpty()) {
            val preview = if (text.length > 60) "${text.substring(0, 60)}…" else text
            Log.i(TAG, "push len=${text.length} preview=\"$preview\"")
            try {
                sendBroadcast(Intent(ACTION_PUSH).apply {
                    setPackage(packageName)
                    putExtra(EXTRA_TEXT, text)
                })
            } catch (e: Exception) {
                Log.w(TAG, "push broadcast failed: $e")
            }
        } else {
            Log.i(TAG, "empty/non-text clip — nothing to push")
        }
        finish()
    }

    private fun readClipboardText(): String? {
        return try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                ?: return null
            val clip = cm.primaryClip ?: return null
            if (clip.itemCount == 0) return null
            val item = clip.getItemAt(0)
            val text = item.text?.toString() ?: item.coerceToText(this)?.toString()
            if (text.isNullOrEmpty()) null else text
        } catch (e: Exception) {
            Log.w(TAG, "read failed: $e")
            null
        }
    }
}
