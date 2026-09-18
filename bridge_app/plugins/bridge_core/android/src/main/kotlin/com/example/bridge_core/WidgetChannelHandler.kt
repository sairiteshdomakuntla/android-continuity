package com.example.bridge_core

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Serves the `bridge/widget` channel on whichever engine attaches (UI or
 * background isolate). The updater lives in the app module, which this
 * plugin module cannot reference at compile time, so it is resolved
 * reflectively at runtime (both live in the same APK classloader).
 * Failures degrade silently — widget updates are best-effort.
 */
class WidgetChannelHandler(private val context: Context) {
    companion object {
        const val WIDGET_CHANNEL = "bridge/widget"
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "updateWidget" -> {
                try {
                    val updaterClass =
                        Class.forName("dev.sairitesh.bridge.BridgeWidgetUpdater")
                    val updateAll = updaterClass.getMethod(
                        "updateAll",
                        android.content.Context::class.java,
                    )
                    updateAll.invoke(null, context.applicationContext)
                } catch (e: Exception) {
                    android.util.Log.w("BridgeWidget", "updateWidget failed: $e")
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
