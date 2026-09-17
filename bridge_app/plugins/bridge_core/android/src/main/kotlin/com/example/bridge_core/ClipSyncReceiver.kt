package com.example.bridge_core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives clipboard text pushed by the transparent [ClipSyncActivity]
 * trampoline (app module — hence literal action/class references, no
 * compile dependency either way) and fans it out to every attached
 * Flutter engine, including the background isolate that owns the
 * persistent socket.
 *
 * Explicit, same-package broadcast only ([.ClipSyncActivity] sets the
 * package); declared non-exported.
 */
class ClipSyncReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_PUSH = "com.example.bridge_app.CLIP_SYNC_PUSH"
        const val EXTRA_TEXT = "text"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_PUSH) return
        val text = intent.getStringExtra(EXTRA_TEXT) ?: return
        if (text.isEmpty()) return
        try {
            SystemChannelHandler.pushTrampolineClipboard(text)
        } catch (e: Exception) {
            android.util.Log.w("ClipSyncReceiver", "push failed: $e")
        }
    }
}
