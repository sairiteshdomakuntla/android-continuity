package com.example.bridge_core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Handles the notification "Stop" action (and the in-overlay stop button).
 * Declared in the app manifest; lives here so both engines and the
 * notification action share one implementation with no module dependency.
 */
class StopRingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == RingManager.ACTION_STOP_RING) {
            RingManager.stopRing(context.applicationContext)
        }
    }
}
