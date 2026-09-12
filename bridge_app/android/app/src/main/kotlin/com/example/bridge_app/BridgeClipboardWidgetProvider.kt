package com.example.bridge_app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context

/**
 * Home-screen clipboard quick-access widget. All rendering is delegated to
 * [BridgeWidgetUpdater] (reads the Dart-written snapshot file); this class
 * only hooks the provider lifecycle. No polling — updates are pushed from
 * Dart via the `bridge/widget` channel whenever history changes.
 *
 * Note: no custom onReceive — the base class already routes
 * APPWIDGET_UPDATE to onUpdate; duplicating it only double-pushes.
 */
class BridgeClipboardWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        BridgeWidgetUpdater.updateAll(context)
    }
}
