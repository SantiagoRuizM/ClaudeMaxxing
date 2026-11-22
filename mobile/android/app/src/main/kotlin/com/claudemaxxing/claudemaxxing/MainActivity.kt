package com.claudemaxxing.claudemaxxing

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

private const val APK_URL = "https://github.com/SantiagoRuizM/ClaudeMaxxing/releases/latest/download/ClaudeMaxxing.apk"

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The browser downloads the update, so the app needs no permission to install packages.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "claudemaxxing/update").setMethodCallHandler { call, result ->
            if (call.method != "download") {
                result.notImplemented()
            } else {
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(APK_URL)))
                    result.success(true)
                } catch (e: ActivityNotFoundException) {
                    result.success(false)
                }
            }
        }
    }
}
