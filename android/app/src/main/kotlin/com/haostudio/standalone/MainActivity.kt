package com.haostudio.standalone

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Android Now Playing shell for music (MediaSession + media
        // notification): same channel + contract as the iOS plugin
        // (com.haostudio.standalone/now_playing). Registered here so
        // the channel exists before Dart constructs NowPlayingService.
        flutterEngine.plugins.add(NowPlayingPlugin())
        // Android system volume shell (AudioManager STREAM_MUSIC):
        // same channel + contract as ios/Runner/SystemVolumePlugin.swift
        // (com.haostudio.standalone/system_volume). Without it the Dart
        // side runs best-effort — reads fall back to 1.0, writes are
        // dropped — so dragging the volume on Android never moved the
        // device volume. Registered here so the channel exists before
        // the video / live players construct SystemVolume.
        flutterEngine.plugins.add(SystemVolumePlugin())
    }
}
