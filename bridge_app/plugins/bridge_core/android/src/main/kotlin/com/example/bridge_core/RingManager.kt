package com.example.bridge_core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat

/**
 * Find-my-phone ringer. Runs entirely natively so it works from the
 * background isolate with the UI process dead.
 *
 * Sound goes through STREAM_ALARM at max volume (unaffected by
 * silent/vibrate ringer mode), paired with vibration. Auto-stops after
 * [RING_DURATION_MS]. Previous alarm volume is restored on stop.
 */
object RingManager {
    const val ACTION_STOP_RING = "com.example.bridge_app.STOP_RING"
    const val ACTION_RING_STOPPED_UI = "com.example.bridge_app.RING_STOPPED_UI"
    const val RINGActivity_CLASS = "com.example.bridge_app.RingActivity"

    private const val RING_CHANNEL_ID = "bridge_ring"
    private const val RING_NOTIFICATION_ID = 3301
    private const val RING_DURATION_MS = 15_000L

    private val mainHandler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var ringing = false
    private var prevAlarmVolume = -1

    private val autoStop = Runnable {
        try {
            // Context is captured at start; use last known via callback below.
            pendingStop?.invoke()
        } catch (_: Exception) {
        }
    }
    private var pendingStop: (() -> Unit)? = null

    @Synchronized
    fun isRinging(): Boolean = ringing

    /**
     * Starts ringing. Safe to call from any thread/engine; all
     * MediaPlayer work happens on the main thread.
     */
    fun startRing(context: Context) {
        val appContext = context.applicationContext
        mainHandler.post {
            startRingOnMain(appContext)
        }
    }

    fun stopRing(context: Context) {
        val appContext = context.applicationContext
        mainHandler.post {
            stopRingOnMain(appContext)
        }
    }

    private fun startRingOnMain(context: Context) {
        // Restart the auto-stop timer if already ringing.
        mainHandler.removeCallbacks(autoStop)
        pendingStop = { stopRingOnMain(context) }
        mainHandler.postDelayed(autoStop, RING_DURATION_MS)

        if (!ringing) {
            if (!startPlayer(context)) {
                mainHandler.removeCallbacks(autoStop)
                pendingStop = null
                return
            }
            ringing = true
        }

        showRingNotification(context)

        // Best-effort direct overlay launch (works when the app was
        // recently visible; blocked from background on API 29+ — the
        // full-screen notification intent below covers that case).
        try {
            val overlay = Intent().apply {
                setClassName(context.packageName, RINGActivity_CLASS)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            context.startActivity(overlay)
        } catch (_: Exception) {
        }
    }

    private fun stopRingOnMain(context: Context) {
        mainHandler.removeCallbacks(autoStop)
        pendingStop = null
        if (!ringing && player == null) {
            cancelNotification(context)
            return
        }
        ringing = false
        try {
            player?.stop()
        } catch (_: Exception) {
        }
        try {
            player?.release()
        } catch (_: Exception) {
        }
        player = null
        stopVibration(context)
        restoreVolume(context)
        cancelNotification(context)
        // Tell the overlay activity (if visible) to finish itself.
        try {
            context.sendBroadcast(Intent(ACTION_RING_STOPPED_UI).apply {
                setPackage(context.packageName)
            })
        } catch (_: Exception) {
        }
    }

    private fun startPlayer(context: Context): Boolean {
        val soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        if (soundUri == null) {
            android.util.Log.w("RingManager", "No ringtone URI available")
            return false
        }
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        try {
            if (audio != null) {
                prevAlarmVolume =
                    audio.getStreamVolume(AudioManager.STREAM_ALARM)
                audio.setStreamVolume(
                    AudioManager.STREAM_ALARM,
                    audio.getStreamMaxVolume(AudioManager.STREAM_ALARM),
                    0,
                )
            }
            val mp = MediaPlayer().apply {
                setDataSource(context, soundUri)
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                isLooping = true
                prepare()
            }
            mp.start()
            player = mp
            startVibration(context)
            return true
        } catch (e: Exception) {
            android.util.Log.w("RingManager", "startPlayer failed: $e")
            restoreVolume(context)
            return false
        }
    }

    private fun restoreVolume(context: Context) {
        if (prevAlarmVolume < 0) return
        try {
            val audio =
                context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            audio?.setStreamVolume(
                AudioManager.STREAM_ALARM, prevAlarmVolume, 0)
        } catch (_: Exception) {
        } finally {
            prevAlarmVolume = -1
        }
    }

    private fun startVibration(context: Context) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE)
                    as? VibratorManager
                vm?.defaultVibrator?.vibrate(
                    VibrationEffect.createWaveform(longArrayOf(0, 900, 400), 0))
            } else {
                @Suppress("DEPRECATION")
                val vib = context.getSystemService(Context.VIBRATOR_SERVICE)
                    as? Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vib?.vibrate(
                        VibrationEffect.createWaveform(longArrayOf(0, 900, 400), 0))
                } else {
                    @Suppress("DEPRECATION")
                    vib?.vibrate(longArrayOf(0, 900, 400), 0)
                }
            }
        } catch (_: Exception) {
        }
    }

    private fun stopVibration(context: Context) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE)
                    as? VibratorManager
                vm?.defaultVibrator?.cancel()
            } else {
                @Suppress("DEPRECATION")
                (context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator)?.cancel()
            }
        } catch (_: Exception) {
        }
    }

    private fun ensureChannel(context: Context) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm =
                    context.getSystemService(Context.NOTIFICATION_SERVICE)
                        as? NotificationManager
                nm?.createNotificationChannel(
                    NotificationChannel(
                        RING_CHANNEL_ID,
                        "Bridge Ring",
                        NotificationManager.IMPORTANCE_HIGH,
                    ).apply {
                        description = "Full-screen alert when your PC rings this phone"
                        lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    }
                )
            }
        } catch (_: Exception) {
        }
    }

    private fun pendingFlags(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
    }

    private fun showRingNotification(context: Context) {
        try {
            ensureChannel(context)
            val openOverlay = Intent().apply {
                setClassName(context.packageName, RINGActivity_CLASS)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val fullScreen = PendingIntent.getActivity(
                context, 4101, openOverlay, pendingFlags())

            val stopIntent = Intent(ACTION_STOP_RING).apply {
                setPackage(context.packageName)
            }
            val stopAction = PendingIntent.getBroadcast(
                context, 4102, stopIntent, pendingFlags())

            val notif = NotificationCompat.Builder(context, RING_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle("Bridge is ringing")
                .setContentText("Your PC is looking for this phone")
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setAutoCancel(false)
                .setOngoing(true)
                .setFullScreenIntent(fullScreen, true)
                .setContentIntent(fullScreen)
                .addAction(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "Stop", stopAction)
                .build()
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as? NotificationManager
            nm?.notify(RING_NOTIFICATION_ID, notif)
        } catch (e: Exception) {
            android.util.Log.w("RingManager", "showRingNotification failed: $e")
        }
    }

    private fun cancelNotification(context: Context) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as? NotificationManager
            nm?.cancel(RING_NOTIFICATION_ID)
        } catch (_: Exception) {
        }
    }
}
