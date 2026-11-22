package com.claudemaxxing.claudemaxxing

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

private const val APK_URL = "https://github.com/SantiagoRuizM/ClaudeMaxxing/releases/latest/download/ClaudeMaxxing.apk"

/** Hosts the app, and starts the call's service while on screen: Android allows the microphone only that way. */
class MainActivity : FlutterActivity() {
    private var pending: Pair<MethodCall, MethodChannel.Result>? = null

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
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "claudemaxxing/call")
        CallService.channel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> start(call, result)
                "stop" -> {
                    stopService(Intent(this, CallService::class.java))
                    result.success(null)
                }
                else -> {
                    CallService.instance?.handle(call)
                    result.success(null)
                }
            }
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 23 && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            pending?.second?.success(false)
            pending = call to result
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
        } else {
            launchCall(call, result)
        }
    }

    private fun launchCall(call: MethodCall, result: MethodChannel.Result) {
        val intent = Intent(this, CallService::class.java)
        for (key in CallService.EXTRAS) intent.putExtra(key, call.argument<String>(key))
        // startService, not startForegroundService: the app is on screen, and a hang-up before the service is up can't crash it.
        try {
            startService(intent)
            result.success(true)
        } catch (e: IllegalStateException) {
            result.success(false)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MIC_REQUEST) return
        val (call, result) = pending ?: return
        pending = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) launchCall(call, result) else result.success(false)
    }

    // Back during a call hides the app instead of closing it: the conversation's logic lives in this engine.
    override fun popSystemNavigator(): Boolean {
        if (CallService.instance == null) return super.popSystemNavigator()
        moveTaskToBack(true)
        return true
    }

    override fun onDestroy() {
        // Without the engine nobody would hang up: never leave the microphone's service behind.
        stopService(Intent(this, CallService::class.java))
        CallService.channel = null
        super.onDestroy()
    }

    private companion object {
        const val MIC_REQUEST = 4783
    }
}
