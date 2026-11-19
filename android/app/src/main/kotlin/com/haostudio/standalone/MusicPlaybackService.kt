package com.haostudio.standalone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.session.MediaController
import android.media.session.MediaSession
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.net.URL

/**
 * Current music track, shared between [NowPlayingPlugin] (which
 * receives it from Dart) and this service (which renders it).
 */
data class NowPlayingTrack(
    val title: String,
    val artist: String,
    val album: String,
    val coverUrl: String,
    val durationMs: Long,
    val positionMs: Long,
    val playing: Boolean,
)

/**
 * Foreground service that owns the music media notification (status
 * bar / notification shade / lock screen). The notification is a
 * framework MediaStyle notification bound to the MediaSession owned
 * by [NowPlayingPlugin]; its prev / play-pause / next actions route
 * through the session's transport controls back to Dart, so the
 * buttons drive the real player (including the A/B crossfade pair —
 * Dart publishes from controller state, never from one player).
 *
 * This service is the display layer only: it never plays audio
 * itself and never changes playback state. Starting it does keep the
 * process alive while music plays, which may let playback continue
 * in background as a side effect — background playback itself is
 * NOT promised here (known limitation B4 stands).
 *
 * Cover art is fetched on a background thread; a failed fetch never
 * blocks or kills the notification — it just shows without art.
 */
class MusicPlaybackService : Service() {

    companion object {
        const val CHANNEL_ID = "hao_music_playback"
        const val NOTIFICATION_ID = 1001

        const val ACTION_PLAY = "com.haostudio.standalone.ACTION_PLAY"
        const val ACTION_PAUSE = "com.haostudio.standalone.ACTION_PAUSE"
        const val ACTION_NEXT = "com.haostudio.standalone.ACTION_NEXT"
        const val ACTION_PREVIOUS = "com.haostudio.standalone.ACTION_PREVIOUS"

        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_ALBUM = "album"
        const val EXTRA_COVER_URL = "coverUrl"
        const val EXTRA_DURATION_MS = "durationMs"
        const val EXTRA_POSITION_MS = "positionMs"
        const val EXTRA_PLAYING = "playing"
        const val EXTRA_SESSION_TOKEN = "sessionToken"

        private const val TAG = "HaoMusicService"
        private const val MAX_ART_PX = 512

        /**
         * Fallback used when the foreground-service start was refused
         * (Android 12+ background-start restriction): post the same
         * notification as a plain posted notification so the track is
         * still visible. No art here — the service fetches it on the
         * next successful start.
         */
        fun postPlainNotification(
            context: Context,
            track: NowPlayingTrack,
            token: MediaSession.Token?,
        ) {
            try {
                ensureChannel(context)
                val notification = buildNotification(
                    context, track, token, coverBitmap = null,
                )
                notificationManager(context).notify(NOTIFICATION_ID, notification)
            } catch (e: Exception) {
                Log.w(TAG, "plain notification failed", e)
            }
        }

        private fun notificationManager(context: Context): NotificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = notificationManager(context)
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "音乐播放",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "显示当前播放的歌曲"
                    // Media notifications never buzz or vibrate.
                    setSound(null, null)
                    enableVibration(false)
                },
            )
        }

        private fun openAppIntent(context: Context): PendingIntent? {
            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName) ?: return null
            return PendingIntent.getActivity(
                context, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun actionIntent(
            context: Context,
            action: String,
            token: MediaSession.Token?,
            requestCode: Int,
        ): PendingIntent {
            val intent = Intent(context, MusicPlaybackService::class.java).apply {
                this.action = action
                putExtra(EXTRA_SESSION_TOKEN, token)
            }
            return PendingIntent.getService(
                context, requestCode, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        /**
         * One notification builder for both paths (foreground service
         * and the plain fallback) so they can never drift apart.
         * Progress comes from the MediaSession playback state — the
         * system draws the seek bar on Android 13+ from it — so the
         * builder carries no explicit progress.
         */
        private fun buildNotification(
            context: Context,
            track: NowPlayingTrack,
            token: MediaSession.Token?,
            coverBitmap: Bitmap?,
        ): Notification {
            @Suppress("DEPRECATION")
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                Notification.Builder(context)
            }
            builder
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle(track.title)
                .setContentText(track.artist.ifEmpty { track.album })
                .setShowWhen(false)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
            if (coverBitmap != null) builder.setLargeIcon(coverBitmap)
            openAppIntent(context)?.let { builder.setContentIntent(it) }
            // Compact view shows prev / play-pause / next, in that order.
            builder.addAction(
                android.R.drawable.ic_media_previous, "上一首",
                actionIntent(context, ACTION_PREVIOUS, token, 1),
            )
            if (track.playing) {
                builder.addAction(
                    android.R.drawable.ic_media_pause, "暂停",
                    actionIntent(context, ACTION_PAUSE, token, 2),
                )
            } else {
                builder.addAction(
                    android.R.drawable.ic_media_play, "播放",
                    actionIntent(context, ACTION_PLAY, token, 2),
                )
            }
            builder.addAction(
                android.R.drawable.ic_media_next, "下一首",
                actionIntent(context, ACTION_NEXT, token, 3),
            )
            if (token != null) {
                builder.setStyle(
                    Notification.MediaStyle()
                        .setMediaSession(token)
                        .setShowActionsInCompactView(0, 1, 2),
                )
            }
            return builder.build()
        }
    }

    private var currentTrack: NowPlayingTrack? = null
    private var currentToken: MediaSession.Token? = null
    private var lastCoverUrl: String? = null
    private var lastCoverBitmap: Bitmap? = null
    private var destroyed = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) return START_NOT_STICKY
        when (intent.action) {
            ACTION_PLAY, ACTION_PAUSE, ACTION_NEXT, ACTION_PREVIOUS -> {
                handleTransportAction(intent.action!!, intent.sessionToken())
                return START_NOT_STICKY
            }
        }
        val track = NowPlayingTrack(
            title = intent.getStringExtra(EXTRA_TITLE) ?: "",
            artist = intent.getStringExtra(EXTRA_ARTIST) ?: "",
            album = intent.getStringExtra(EXTRA_ALBUM) ?: "",
            coverUrl = intent.getStringExtra(EXTRA_COVER_URL) ?: "",
            durationMs = intent.getLongExtra(EXTRA_DURATION_MS, 0),
            positionMs = intent.getLongExtra(EXTRA_POSITION_MS, 0),
            playing = intent.getBooleanExtra(EXTRA_PLAYING, false),
        )
        if (track.title.isEmpty()) return START_NOT_STICKY
        currentTrack = track
        currentToken = intent.sessionToken()
        ensureChannel(this)
        val notification = buildNotification(this, track, currentToken, lastCoverBitmap)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                @Suppress("DEPRECATION")
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Foreground promotion failed (should not happen — the
            // plugin already survived startForegroundService): fall
            // back to a plain posted notification.
            Log.w(TAG, "startForeground failed, posting plain", e)
            notificationManager(this).notify(NOTIFICATION_ID, notification)
        }
        maybeFetchCover(track.coverUrl)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        destroyed = true
        try {
            notificationManager(this).cancel(NOTIFICATION_ID)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    // MARK: - Transport actions (notification buttons)

    private fun handleTransportAction(action: String, token: MediaSession.Token?) {
        if (token == null) {
            Log.w(TAG, "transport action $action without session token")
            return
        }
        try {
            val controls = MediaController(this, token).transportControls
            when (action) {
                ACTION_PLAY -> controls.play()
                ACTION_PAUSE -> controls.pause()
                ACTION_NEXT -> controls.skipToNext()
                ACTION_PREVIOUS -> controls.skipToPrevious()
            }
        } catch (e: Exception) {
            Log.w(TAG, "transport action $action failed", e)
        }
        // The session callback forwards to Dart; Dart's publish
        // refreshes the notification with the new state.
    }

    // MARK: - Cover art

    private fun maybeFetchCover(coverUrl: String) {
        if (coverUrl.isEmpty() || !coverUrl.startsWith("http")) return
        if (coverUrl == lastCoverUrl) return
        lastCoverUrl = coverUrl
        lastCoverBitmap = null
        Thread {
            try {
                val connection = URL(coverUrl).openConnection()
                connection.connectTimeout = 5000
                connection.readTimeout = 5000
                val bytes = connection.getInputStream().use { it.readBytes() }
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                var sample = 1
                val maxDim = maxOf(bounds.outWidth, bounds.outHeight)
                while (maxDim / sample > MAX_ART_PX) sample *= 2
                val opts = BitmapFactory.Options().apply { inSampleSize = sample }
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
                    ?: return@Thread
                // Only apply if this is still the current cover and
                // the service is still alive for this track.
                if (destroyed || coverUrl != lastCoverUrl) return@Thread
                lastCoverBitmap = bitmap
                val track = currentTrack ?: return@Thread
                if (track.coverUrl != coverUrl) return@Thread
                val notification = buildNotification(
                    this, track, currentToken, bitmap,
                )
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        startForeground(
                            NOTIFICATION_ID, notification,
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        startForeground(NOTIFICATION_ID, notification)
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "re-post with art failed", e)
                }
            } catch (e: Exception) {
                // Art is best-effort only: the notification was
                // already posted without it and stays that way.
                Log.w(TAG, "cover fetch failed for $coverUrl", e)
            }
        }.start()
    }

    private fun Intent.sessionToken(): MediaSession.Token? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(EXTRA_SESSION_TOKEN, MediaSession.Token::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(EXTRA_SESSION_TOKEN) as? MediaSession.Token
        }
    }
}
