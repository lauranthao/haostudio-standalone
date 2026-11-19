package com.haostudio.standalone

import android.content.Context
import android.database.ContentObserver
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Android system volume shell — the Android counterpart of
 * ios/Runner/SystemVolumePlugin.swift, on the SAME MethodChannel
 * (`com.haostudio.standalone/system_volume`) and the SAME contract.
 * Dart side is lib/core/native/system_volume.dart.
 *
 * The video / live vertical-drag volume drives the DEVICE volume, not
 * the player gain: the player gain leaves the system volume bar
 * untouched, which is the bug chen reported ("调音量系统都不会变").
 * Until this plugin landed, the Dart side ran best-effort on Android:
 * reads fell back to 1.0 and writes were dropped, so dragging the
 * volume on Android could even mute playback (player gain only).
 *
 *  - Read: AudioManager STREAM_MUSIC volume / max.
 *  - Write: AudioManager.setStreamVolume(STREAM_MUSIC, ..., flag 0) —
 *    flag 0 shows no system volume UI; the in-app drag HUD shows the
 *    value, same as iOS parking its MPVolumeView off-screen.
 *  - Push: a ContentObserver on Settings.System forwards hardware-key
 *    / system-UI changes to Dart as `volumeChanged`, so the drag HUD
 *    stays on the real value. Own setVolume calls do not echo: the
 *    observer suppresses the value this plugin just set.
 *
 * No new dependencies: framework AudioManager only.
 */
class SystemVolumePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.haostudio.standalone/system_volume"
        private const val TAG = "HaoSystemVolume"
    }

    private var channel: MethodChannel? = null
    private var audioManager: AudioManager? = null
    private var appContext: Context? = null
    private var volumeObserver: ContentObserver? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Last level pushed to Dart (or set by us). The observer skips
    // values equal to this, so our own setVolume never echoes back
    // as a separate volumeChanged event.
    private var lastPushed = 1.0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        audioManager =
            appContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
        lastPushed = currentLevel()
        volumeObserver = object : ContentObserver(mainHandler) {
            override fun onChange(selfChange: Boolean) {
                // Settings.System fires for ANY system-setting change
                // (brightness, etc.); only a real level move is pushed.
                val level = currentLevel()
                if (abs(level - lastPushed) > 0.001) {
                    lastPushed = level
                    mainHandler.post {
                        try {
                            channel?.invokeMethod(
                                "volumeChanged",
                                mapOf("volume" to level),
                            )
                        } catch (e: Exception) {
                            Log.w(TAG, "volumeChanged failed", e)
                        }
                    }
                }
            }
        }
        try {
            appContext?.contentResolver?.registerContentObserver(
                Settings.System.CONTENT_URI,
                true,
                volumeObserver!!,
            )
        } catch (e: Exception) {
            Log.w(TAG, "register volume observer failed", e)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        try {
            volumeObserver?.let {
                appContext?.contentResolver?.unregisterContentObserver(it)
            }
        } catch (e: Exception) {
            Log.w(TAG, "unregister volume observer failed", e)
        }
        volumeObserver = null
        channel?.setMethodCallHandler(null)
        channel = null
        audioManager = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getVolume" -> result.success(currentLevel())
            "setVolume" -> {
                val args = call.arguments as? Map<*, *>
                val volume = (args?.get("volume") as? Number)?.toDouble()
                if (volume == null) {
                    result.error(
                        "bad_args",
                        "setVolume needs a volume number",
                        null,
                    )
                    return
                }
                setLevel(volume.coerceIn(0.0, 1.0))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun currentLevel(): Double {
        val am = audioManager ?: return lastPushed
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            .coerceAtLeast(1)
        return (am.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max)
            .coerceIn(0.0, 1.0)
    }

    private fun setLevel(level: Double) {
        val am = audioManager ?: return
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            .coerceAtLeast(1)
        lastPushed = level
        try {
            // Flag 0: no system volume UI — the app shows its own drag HUD.
            am.setStreamVolume(
                AudioManager.STREAM_MUSIC,
                (level * max).roundToInt().coerceIn(0, max),
                0,
            )
        } catch (e: Exception) {
            Log.w(TAG, "setStreamVolume failed", e)
        }
    }
}
