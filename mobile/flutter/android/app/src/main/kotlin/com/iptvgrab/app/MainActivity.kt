package com.iptvgrab.app

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvgrab/background-control"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setKeepAlive" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    toggleKeepAlive(enabled)
                    result.success(null)
                }

                "enterPictureInPicture" -> result.success(enterPipIfAvailable())
                else -> result.notImplemented()
            }
        }
    }

    private fun toggleKeepAlive(enabled: Boolean) {
        val intent = Intent(this, BackgroundKeepAliveService::class.java)
        if (enabled) {
            ContextCompat.startForegroundService(this, intent)
        } else {
            stopService(intent)
        }
    }

    private fun enterPipIfAvailable(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
            return false
        }
        enterPictureInPictureMode(PictureInPictureParams.Builder().build())
        return true
    }
}
