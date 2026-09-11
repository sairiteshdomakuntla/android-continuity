package com.example.bridge_app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class ShareTargetActivity : FlutterActivity() {

    companion object {
        const val SHARE_CHANNEL = "bridge/share"
    }

    private var pendingUris: List<String> = emptyList()

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingUris = extractUris(intent)
        super.onCreate(savedInstanceState)
    }

    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine {
        val engine = FlutterEngine(context)
        val flutterLoader = FlutterInjector.instance().flutterLoader()
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                flutterLoader.findAppBundlePath(),
                "mainShare"
            )
        )
        return engine
    }

    override fun shouldDestroyEngineWithHost(): Boolean {
        return true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupShareChannel(flutterEngine)
    }

    private fun setupShareChannel(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSharedUris" -> result.success(pendingUris)
                    "finish"        -> { finish(); result.success(null) }
                    else            -> result.notImplemented()
                }
            }
    }

    private fun extractUris(intent: Intent?): List<String> {
        if (intent == null) return emptyList()
        return when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (uri != null) listOf(uri.toString()) else emptyList()
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("UNCHECKED_CAST")
                val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                uris?.map { it.toString() } ?: emptyList()
            }
            else -> emptyList()
        }
    }
}
