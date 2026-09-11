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
    }

    private var filesChannel: MethodChannel? = null
    private var systemChannel: MethodChannel? = null
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
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        filesChannel?.setMethodCallHandler(null)
        systemChannel?.setMethodCallHandler(null)
        filesChannel = null
        systemChannel = null
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
