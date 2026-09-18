package dev.sairitesh.bridge

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager

/**
 * Full-screen "Bridge is ringing" overlay — Clay+Linen themed first-class
 * screen (linen background, clay accents, Fraunces/Nunito Sans).
 *
 * Launched from the background isolate via the ring notification's
 * full-screen intent (lock-screen safe) or directly when the app was
 * recently visible. Never boots a Flutter engine.
 */
class RingActivity : Activity() {

    companion object {
        /** Must match RingManager.ACTION_RING_STOPPED_UI (kept as literals:
         * the app module cannot compile-depend on the bridge_core module). */
        private const val ACTION_RING_STOPPED_UI = "dev.sairitesh.bridge.RING_STOPPED_UI"
        private const val ACTION_STOP_RING = "dev.sairitesh.bridge.STOP_RING"
    }

    private var uiStopReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_ring)

        // Show over the lock screen so the overlay greets the user on unlock.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(false)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
            )
        }

        findViewById<android.view.View>(R.id.btn_stop_ring).setOnClickListener {
            sendStop()
        }

        uiStopReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                finish()
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(
                uiStopReceiver,
                IntentFilter(ACTION_RING_STOPPED_UI),
                RECEIVER_NOT_EXPORTED,
            )
        } else {
            registerReceiver(
                uiStopReceiver,
                IntentFilter(ACTION_RING_STOPPED_UI),
            )
        }
    }

    /**
     * Volume keys stop the ring immediately, mirroring how Android
     * silences alarms with hardware keys.
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN ||
            keyCode == KeyEvent.KEYCODE_VOLUME_UP
        ) {
            sendStop()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onDestroy() {
        try {
            uiStopReceiver?.let { unregisterReceiver(it) }
        } catch (_: Exception) {
        }
        uiStopReceiver = null
        super.onDestroy()
    }

    private fun sendStop() {
        try {
            // Route through the shared stop receiver (stops sound +
            // vibration, restores volume, clears the notification).
            val stop = Intent(ACTION_STOP_RING).apply {
                setPackage(packageName)
            }
            sendBroadcast(stop)
        } catch (_: Exception) {
        }
        finish()
    }
}
