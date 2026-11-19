package com.haostudio.standalone

import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android Now Playing shell for music — the Android counterpart of
 * ios/Runner/NowPlayingPlugin.swift, on the SAME MethodChannel
 * (`com.haostudio.standalone/now_playing`) and the SAME contract:
 *
 *  - Dart pushes `updateNowPlaying` / `clearNowPlaying` (the Dart side
 *    already calls both on track change / play-pause / throttled
 *    position — no Dart change was needed for Android).
 *  - This side owns a framework MediaSession and forwards its
 *    transport callbacks back to Dart as `remoteCommand` (play /
 *    pause / toggle / next / previous / seek), exactly like the iOS
 *    plugin. The Dart side dedupes rapid next/previous, so one press
 *    advances exactly one track.
 *  - `showAirPlayPicker` stays iOS-only: it is NOT implemented here
 *    (MethodChannel notImplemented → Dart returns false).
 *
 * The MediaSession drives the status-bar / notification-shade media
 * notification (via MusicPlaybackService, a foreground service) and
 * the lock-screen / headset controls. The session is created lazily
 * on the first track push and is NEVER torn down on engine detach —
 * same lesson as iOS: tearing the command center down whenever the
 * queue transiently empties (or the engine re-attaches) leaves the
 * app deregistered with nothing re-registering it.
 *
 * No new dependencies: framework MediaSession + Notification only.
 * just_audio / ExoPlayer create no MediaSession of their own, so
 * there is no second owner fighting over the session (better_player's
 * foreground service is video-only and uses its own notification).
 */
class NowPlayingPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.haostudio.standalone/now_playing"
        private const val TAG = "HaoNowPlaying"
    }

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private var mediaSession: MediaSession? = null
    private var serviceStarted = false
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Deliberately do NOT release the MediaSession here: the
        // session + foreground service outlive the engine binding
        // (same as iOS, which never tears the command center down).
        // The channel handler is detached; it re-binds on re-attach.
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "updateNowPlaying" -> {
                val args = call.arguments as? Map<*, *>
                if (args == null) {
                    result.error("bad_args", "updateNowPlaying needs a map", null)
                    return
                }
                updateNowPlaying(args)
                result.success(null)
            }
            "clearNowPlaying" -> {
                clearNowPlaying()
                result.success(null)
            }
            // showAirPlayPicker is iOS-only (AVRoutePickerView has no
            // Android equivalent); Dart treats notImplemented as false.
            else -> result.notImplemented()
        }
    }

    // MARK: - Session

    private fun session(): MediaSession? {
        val ctx = appContext ?: return null
        return mediaSession ?: MediaSession(ctx, "HAoStudioNowPlaying").apply {
            setFlags(
                MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS,
            )
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = forwardCommand("play")
                override fun onPause() = forwardCommand("pause")
                override fun onSkipToNext() = forwardCommand("next")
                override fun onSkipToPrevious() = forwardCommand("previous")
                override fun onSeekTo(pos: Long) =
                    forwardCommand("seek", pos / 1000.0)
            }, mainHandler)
            mediaSession = this
        }
    }

    private fun forwardCommand(command: String, position: Double? = null) {
        val args = HashMap<String, Any>()
        args["command"] = command
        if (position != null) args["position"] = position
        // MediaSession callbacks run on the main handler already, but
        // post defensively: channel calls must be on the platform thread.
        mainHandler.post {
            try {
                channel?.invokeMethod("remoteCommand", args)
            } catch (e: Exception) {
                Log.w(TAG, "remoteCommand $command failed", e)
            }
        }
    }

    // MARK: - Publish / clear

    private fun updateNowPlaying(args: Map<*, *>) {
        val title = args["title"] as? String ?: ""
        if (title.isEmpty()) return
        val track = NowPlayingTrack(
            title = title,
            artist = args["artist"] as? String ?: "",
            album = args["album"] as? String ?: "",
            coverUrl = args["coverUrl"] as? String ?: "",
            durationMs = ((args["duration"] as? Number)?.toDouble() ?: 0.0)
                .times(1000).toLong().coerceAtLeast(0),
            positionMs = ((args["position"] as? Number)?.toDouble() ?: 0.0)
                .times(1000).toLong().coerceAtLeast(0),
            playing = args["playing"] as? Boolean ?: false,
        )
        val session = session() ?: return
        session.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, track.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, track.artist)
                .putString(
                    MediaMetadata.METADATA_KEY_ALBUM,
                    track.album.ifEmpty { "HAo Studio" },
                )
                .putLong(MediaMetadata.METADATA_KEY_DURATION, track.durationMs)
                .build(),
        )
        val state = if (track.playing) {
            PlaybackState.STATE_PLAYING
        } else {
            PlaybackState.STATE_PAUSED
        }
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_SKIP_TO_NEXT or
                        PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                        PlaybackState.ACTION_SEEK_TO,
                )
                .setState(state, track.positionMs, if (track.playing) 1.0f else 0.0f)
                .build(),
        )
        session.isActive = true
        startOrUpdateService(track, session.sessionToken)
    }

    private fun clearNowPlaying() {
        // Clear the info only; the session object stays (see class
        // header). The notification goes away with the service.
        mediaSession?.let {
            try {
                it.setPlaybackState(
                    PlaybackState.Builder()
                        .setState(PlaybackState.STATE_STOPPED, 0, 0f)
                        .build(),
                )
                it.setMetadata(null)
                it.isActive = false
            } catch (e: Exception) {
                Log.w(TAG, "clear session failed", e)
            }
        }
        val ctx = appContext
        if (ctx != null) {
            try {
                ctx.stopService(Intent(ctx, MusicPlaybackService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "stop service failed", e)
            }
        }
        serviceStarted = false
    }

    // MARK: - Foreground service

    private fun startOrUpdateService(track: NowPlayingTrack, token: MediaSession.Token) {
        val ctx = appContext ?: return
        val intent = Intent(ctx, MusicPlaybackService::class.java).apply {
            putExtra(MusicPlaybackService.EXTRA_TITLE, track.title)
            putExtra(MusicPlaybackService.EXTRA_ARTIST, track.artist)
            putExtra(MusicPlaybackService.EXTRA_ALBUM, track.album)
            putExtra(MusicPlaybackService.EXTRA_COVER_URL, track.coverUrl)
            putExtra(MusicPlaybackService.EXTRA_DURATION_MS, track.durationMs)
            putExtra(MusicPlaybackService.EXTRA_POSITION_MS, track.positionMs)
            putExtra(MusicPlaybackService.EXTRA_PLAYING, track.playing)
            putExtra(MusicPlaybackService.EXTRA_SESSION_TOKEN, token)
        }
        try {
            if (!serviceStarted) {
                // First start must be a foreground-service start (the
                // app is foregrounded when a track begins). Later
                // updates just re-deliver to the running service, so
                // they never trip the Android 12+ background-start
                // restriction.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(intent)
                } else {
                    ctx.startService(intent)
                }
            } else {
                ctx.startService(intent)
            }
            serviceStarted = true
        } catch (e: Exception) {
            // Foreground-service start refused (e.g. an auto-advance
            // while backgrounded on Android 12+): fall back to a plain
            // posted notification so the user still sees the track.
            // The service picks the notification up on the next
            // successful start.
            Log.w(TAG, "start service failed, posting plain notification", e)
            MusicPlaybackService.postPlainNotification(ctx, track, token)
        }
    }
}
