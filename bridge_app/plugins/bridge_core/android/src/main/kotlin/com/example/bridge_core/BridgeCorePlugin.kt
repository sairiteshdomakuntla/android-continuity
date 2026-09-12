package com.example.bridge_core

import android.app.Activity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel

class BridgeCorePlugin : FlutterPlugin, ActivityAware {

    companion object {
        const val FILES_CHANNEL = "bridge/files"
        const val SYSTEM_CHANNEL = "bridge/system"
        const val NOTIFICATION_CHANNEL = "bridge/notifications"
        const val WIDGET_CHANNEL = "bridge/widget"
    }

    private var filesChannel: MethodChannel? = null
    private var systemChannel: MethodChannel? = null
    private var notificationsChannel: MethodChannel? = null
    private var widgetChannel: MethodChannel? = null
    private var currentActivity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val filesHandler = FilesChannelHandler(binding.applicationContext.contentResolver)
        filesChannel = MethodChannel(binding.binaryMessenger, FILES_CHANNEL).apply {
            setMethodCallHandler { call, result -> filesHandler.handle(call, result) }
        }

        val systemHandler = SystemChannelHandler(binding.applicationContext) { currentActivity }
        systemChannel = MethodChannel(binding.binaryMessenger, SYSTEM_CHANNEL).apply {
            setMethodCallHandler { call, result -> systemHandler.handle(call, result) }
        }

        val notificationsHandler = NotificationsChannelHandler(binding.applicationContext)
        notificationsChannel = MethodChannel(binding.binaryMessenger, NOTIFICATION_CHANNEL).apply {
            setMethodCallHandler { call, result -> notificationsHandler.handle(call, result) }
        }
        NotificationsChannelHandler.registerChannel(notificationsChannel!!)

        val widgetHandler = WidgetChannelHandler(binding.applicationContext)
        widgetChannel = MethodChannel(binding.binaryMessenger, WIDGET_CHANNEL).apply {
            setMethodCallHandler { call, result -> widgetHandler.handle(call, result) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        filesChannel?.setMethodCallHandler(null)
        systemChannel?.setMethodCallHandler(null)
        widgetChannel?.setMethodCallHandler(null)
        notificationsChannel?.let {
            it.setMethodCallHandler(null)
            NotificationsChannelHandler.unregisterChannel(it)
        }
        filesChannel = null
        systemChannel = null
        widgetChannel = null
        notificationsChannel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        currentActivity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        currentActivity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        currentActivity = binding.activity
    }

    override fun onDetachedFromActivity() {
        currentActivity = null
    }
}
