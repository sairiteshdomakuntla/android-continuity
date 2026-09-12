package com.example.bridge_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.io.File

/**
 * Builds and pushes the Bridge clipboard home-screen widget from the
 * snapshot file written by Dart ([WidgetSnapshotService]).
 *
 * Styling mirrors the Clay + Linen system with flat color values
 * (RemoteViews cannot use custom fonts or shadows): linen card,
 * clay accents, sand dividers, espresso text.
 *
 * States:
 * - Missing/unpaired snapshot, `serviceAlive=false`, or snapshot older
 *   than [STALE_AFTER_MS] (covers force-kill) → reconnect card.
 * - Empty item list → calm empty state.
 * - Otherwise up to 4 recent items with tap-to-copy.
 */
object BridgeWidgetUpdater {    private const val TAG = "BridgeWidget"
    private const val SNAPSHOT_NAME = "widget_snapshot.json"
    private const val MAX_ITEMS = 4
    private const val STALE_AFTER_MS = 15 * 60 * 1000L

    const val ACTION_COPY = "com.example.bridge_app.WIDGET_COPY"
    const val EXTRA_ITEM_ID = "item_id"

    // Clay + Linen flat values (bridge-agent/src/style.css tokens).
    private const val LINEN = 0xFFF4EEE3.toInt()
    private const val CARD = 0xFFFCF9F3.toInt()
    private const val INK = 0xFF2F2620.toInt()
    private const val INK_SOFT = 0xFF6E6155.toInt()
    private const val MUTED = 0xFFA29382.toInt()
    private const val CLAY = 0xFFBC5E36.toInt()

    fun snapshotFile(context: Context): File {
        return File(context.applicationInfo.dataDir, "app_flutter/$SNAPSHOT_NAME")
    }

    /**
     * Declared static so the `bridge/widget` plugin channel can invoke it
     * reflectively from any engine (UI or background isolate) without an
     * instance receiver. (Without this, `Method.invoke(null, …)` throws
     * NullPointerException: null receiver.)
     */
    @JvmStatic
    fun updateAll(context: Context) {
        try {
            val appContext = context.applicationContext
            val manager = AppWidgetManager.getInstance(appContext)
            val ids = manager.getAppWidgetIds(
                ComponentName(appContext, BridgeClipboardWidgetProvider::class.java)
            )
            if (ids.isEmpty()) return
            for (id in ids) {
                try {
                    manager.updateAppWidget(id, buildViewsSafe(appContext))
                } catch (e: Exception) {
                    Log.e(TAG, "updateAppWidget($id) failed", e)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "updateAll failed", e)
        }
    }

    /**
     * Never let the host end up with a black/empty widget: if the full
     * layout cannot be built for any reason, push a minimal linen card
     * that opens the app, and log the real stack trace for diagnosis
     * (filter logcat with `BridgeWidget`).
     */
    private fun buildViewsSafe(context: Context): RemoteViews {
        return try {
            buildViews(context)
        } catch (e: Exception) {
            Log.e(TAG, "buildViews failed, pushing fallback", e)
            val fallback =
                RemoteViews(context.packageName, R.layout.bridge_widget_fallback)
            try {
                fallback.setOnClickPendingIntent(
                    R.id.widget_fallback_root, openAppIntent(context, 100))
            } catch (_: Exception) {
            }
            fallback
        }
    }

    private fun buildViews(context: Context): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.bridge_widget)
        val snapshot = readSnapshot(context)
        Log.d(TAG, "buildViews snapshot=${if (snapshot == null) "missing"
            else "alive=${snapshot.alive} paired=${snapshot.paired} items=${snapshot.items.size}"}")

        // Header tap + reconnect/footer taps always open the app.
        views.setOnClickPendingIntent(
            R.id.widget_header, openAppIntent(context, 100))
        views.setOnClickPendingIntent(
            R.id.widget_footer, openAppIntent(context, 101))
        views.setOnClickPendingIntent(
            R.id.widget_reconnect, openAppIntent(context, 102))

        if (snapshot == null || !snapshot.paired || !snapshot.alive) {
            showReconnect(views)
            return views
        }

        views.setTextViewText(R.id.widget_count, "${snapshot.items.size}")
        if (snapshot.items.isEmpty()) {
            views.setViewVisibility(R.id.widget_items, View.GONE)
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            views.setViewVisibility(R.id.widget_reconnect, View.GONE)
            return views
        }

        views.setViewVisibility(R.id.widget_items, View.VISIBLE)
        views.setViewVisibility(R.id.widget_empty, View.GONE)
        views.setViewVisibility(R.id.widget_reconnect, View.GONE)

        for (slot in 0 until MAX_ITEMS) {
            val slotIds = slotViewIds(slot)
            if (slot >= snapshot.items.size) {
                views.setViewVisibility(slotIds.root, View.GONE)
                continue
            }
            val item = snapshot.items[slot]
            views.setViewVisibility(slotIds.root, View.VISIBLE)
            views.setInt(slotIds.bar, "setBackgroundColor", typeColor(item.type))

            if (item.kind == "image" && item.imagePath != null) {
                views.setTextViewText(slotIds.preview, "Image")
                views.setTextViewText(
                    slotIds.meta, "IMAGE · ${relativeTime(item.timestampMs)}")
                val bitmap = decodeThumb(item.imagePath)
                if (bitmap != null) {
                    views.setViewVisibility(slotIds.thumb, View.VISIBLE)
                    views.setImageViewBitmap(slotIds.thumb, bitmap)
                } else {
                    views.setViewVisibility(slotIds.thumb, View.GONE)
                }
            } else {
                views.setTextViewText(slotIds.preview,
                    item.preview.ifEmpty { "…" })
                views.setTextViewText(slotIds.meta,
                    "${item.type.uppercase()} · ${relativeTime(item.timestampMs)}")
                views.setViewVisibility(slotIds.thumb, View.GONE)
            }
            views.setOnClickPendingIntent(slotIds.root, copyIntent(context, slot, item.id))
        }
        return views
    }

    private fun showReconnect(views: RemoteViews) {
        views.setViewVisibility(R.id.widget_items, View.GONE)
        views.setViewVisibility(R.id.widget_empty, View.GONE)
        views.setViewVisibility(R.id.widget_reconnect, View.VISIBLE)
    }

    // ── Intents ──────────────────────────────────────────────────────────

    private fun pendingFlags(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
    }

    private fun openAppIntent(context: Context, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        return PendingIntent.getActivity(
            context, requestCode, intent, pendingFlags())
    }

    private fun copyIntent(context: Context, slot: Int, itemId: String): PendingIntent {
        val intent = Intent(context, WidgetCopyActivity::class.java).apply {
            action = ACTION_COPY
            putExtra(EXTRA_ITEM_ID, itemId)
        }
        return PendingIntent.getActivity(
            context, slot, intent, pendingFlags())
    }

    // ── Snapshot parsing ─────────────────────────────────────────────────

    private data class WidgetItem(
        val id: String,
        val kind: String,
        val type: String,
        val preview: String,
        val imagePath: String?,
        val timestampMs: Long,
    )

    private data class Snapshot(val alive: Boolean, val paired: Boolean, val items: List<WidgetItem>)

    private fun readSnapshot(context: Context): Snapshot? {
        val file = snapshotFile(context)
        if (!file.exists()) return null
        // Force-kill safety: nobody marked the service stopped, but the
        // snapshot is old — treat as disconnected rather than stale data.
        if (System.currentTimeMillis() - file.lastModified() > STALE_AFTER_MS) {
            return Snapshot(alive = false, paired = true, items = emptyList())
        }
        return try {
            val json = JSONObject(file.readText())
            val alive = json.optBoolean("serviceAlive", false)
            val paired = json.optBoolean("paired", false)
            val arr = json.optJSONArray("items")
            val items = mutableListOf<WidgetItem>()
            if (arr != null) {
                for (i in 0 until minOf(arr.length(), MAX_ITEMS)) {
                    val o = arr.optJSONObject(i) ?: continue
                    val id = o.optString("id").ifEmpty { continue }
                    items.add(
                        WidgetItem(
                            id = id,
                            kind = o.optString("kind", "text"),
                            type = o.optString("contentType", "text"),
                            preview = o.optString("preview", ""),
                            imagePath = o.optString("imagePath", null as String?),
                            timestampMs = parseTimestamp(o.optString("timestamp", "")),
                        )
                    )
                }
            }
            Snapshot(alive, paired, items)
        } catch (e: Exception) {
            Log.w(TAG, "readSnapshot failed: $e")
            null
        }
    }

    private fun parseTimestamp(iso: String): Long {
        if (iso.isEmpty()) return 0L
        return try {
            // Dart writes UTC ISO-8601, e.g. 2026-09-12T15:00:00.000Z
            val fmt = java.text.SimpleDateFormat(
                "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", java.util.Locale.US)
            fmt.timeZone = java.util.TimeZone.getTimeZone("UTC")
            fmt.parse(iso)?.time ?: 0L
        } catch (e: Exception) {
            0L
        }
    }

    private fun relativeTime(ms: Long): String {
        if (ms <= 0) return "recently"
        val diff = (System.currentTimeMillis() - ms) / 1000
        if (diff < 5) return "just now"
        if (diff < 60) return "${diff}s ago"
        val mins = diff / 60
        if (mins < 60) return "${mins}m ago"
        val hours = mins / 60
        if (hours < 24) return "${hours}h ago"
        return "${hours / 24}d ago"
    }

    private fun typeColor(type: String): Int {
        return when (type.lowercase()) {
            "url" -> 0xFF557B95.toInt()
            "otp" -> 0xFFA9742B.toInt()
            "email" -> 0xFF8C6D8C.toInt()
            "phone" -> 0xFF57663F.toInt()
            "image" -> 0xFF8A3F22.toInt()
            else -> 0xFF6E6155.toInt()
        }
    }

    private fun decodeThumb(path: String): android.graphics.Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (bounds.outWidth / sample > 192 || bounds.outHeight / sample > 192) {
                sample *= 2
            }
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            BitmapFactory.decodeFile(path, opts)
        } catch (e: Exception) {
            Log.w(TAG, "decodeThumb failed: $e")
            null
        }
    }

    private data class SlotIds(val root: Int, val bar: Int, val preview: Int, val meta: Int, val thumb: Int)

    private fun slotViewIds(slot: Int): SlotIds {
        return when (slot) {
            0 -> SlotIds(R.id.widget_item_0, R.id.widget_bar_0, R.id.widget_preview_0, R.id.widget_meta_0, R.id.widget_thumb_0)
            1 -> SlotIds(R.id.widget_item_1, R.id.widget_bar_1, R.id.widget_preview_1, R.id.widget_meta_1, R.id.widget_thumb_1)
            2 -> SlotIds(R.id.widget_item_2, R.id.widget_bar_2, R.id.widget_preview_2, R.id.widget_meta_2, R.id.widget_thumb_2)
            else -> SlotIds(R.id.widget_item_3, R.id.widget_bar_3, R.id.widget_preview_3, R.id.widget_meta_3, R.id.widget_thumb_3)
        }
    }
}
