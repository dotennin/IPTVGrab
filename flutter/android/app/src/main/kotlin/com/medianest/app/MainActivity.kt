package com.medianest.app

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.mediarouter.app.MediaRouteChooserDialog
import androidx.mediarouter.media.MediaRouteSelector
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    // Pending media to cast once a session is established.
    private var pendingCastUrl: String? = null
    private var pendingCastTitle: String? = null
    private var pendingCastIsLive: Boolean = false

    private val castSessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarted(session: CastSession, sessionId: String) {
            val url = pendingCastUrl ?: return
            loadCastMedia(session, url, pendingCastTitle ?: "", pendingCastIsLive)
            pendingCastUrl = null
            pendingCastTitle = null
        }
        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {}
        override fun onSessionEnded(session: CastSession, error: Int) {}
        override fun onSessionStarting(session: CastSession) {}
        override fun onSessionStartFailed(session: CastSession, error: Int) {}
        override fun onSessionEnding(session: CastSession) {}
        override fun onSessionResuming(session: CastSession, sessionId: String) {}
        override fun onSessionResumeFailed(session: CastSession, error: Int) {}
        override fun onSessionSuspended(session: CastSession, reason: Int) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "medianest/background-control"
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "medianest/cast"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "showCastPicker" -> {
                    val url = call.argument<String>("url") ?: ""
                    val title = call.argument<String>("title") ?: ""
                    val isLive = call.argument<Boolean>("isLive") ?: false
                    showCastPicker(url, title, isLive, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        try {
            CastContext.getSharedInstance(applicationContext)
                .sessionManager
                .addSessionManagerListener(castSessionListener, CastSession::class.java)
        } catch (_: Exception) {}
    }

    override fun onPause() {
        super.onPause()
        try {
            CastContext.getSharedInstance(applicationContext)
                .sessionManager
                .removeSessionManagerListener(castSessionListener, CastSession::class.java)
        } catch (_: Exception) {}
    }

    private fun showCastPicker(url: String, title: String, isLive: Boolean, result: MethodChannel.Result) {
        try {
            val castContext = CastContext.getSharedInstance(applicationContext)
            val currentSession = castContext.sessionManager.currentCastSession

            if (currentSession != null && currentSession.isConnected) {
                // Already connected — load media immediately.
                loadCastMedia(currentSession, url, title, isLive)
                result.success(null)
                return
            }

            // Remember what to cast when a session is established.
            pendingCastUrl = url
            pendingCastTitle = title
            pendingCastIsLive = isLive

            // Show the route-chooser dialog filtered to Chromecast devices.
            val selector = MediaRouteSelector.Builder()
                .addControlCategory(CastMediaControlIntent.categoryForCast("CC1AD845"))
                .build()

            val dialog = MediaRouteChooserDialog(this)
            dialog.routeSelector = selector
            dialog.show()

            result.success(null)
        } catch (e: Exception) {
            result.error("cast_unavailable", e.message, null)
        }
    }

    private fun loadCastMedia(session: CastSession, url: String, title: String, isLive: Boolean) {
        val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MOVIE).apply {
            putString(MediaMetadata.KEY_TITLE, title)
        }
        val contentType = when {
            url.contains(".m3u8", ignoreCase = true) -> "application/x-mpegurl"
            url.contains(".mp4", ignoreCase = true) -> "video/mp4"
            else -> "application/x-mpegurl"
        }
        val streamType = if (isLive) MediaInfo.STREAM_TYPE_LIVE else MediaInfo.STREAM_TYPE_BUFFERED
        val mediaInfo = MediaInfo.Builder(url)
            .setStreamType(streamType)
            .setContentType(contentType)
            .setMetadata(metadata)
            .build()
        val loadRequest = MediaLoadRequestData.Builder()
            .setMediaInfo(mediaInfo)
            .setAutoplay(true)
            .build()
        session.remoteMediaClient?.load(loadRequest)
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

