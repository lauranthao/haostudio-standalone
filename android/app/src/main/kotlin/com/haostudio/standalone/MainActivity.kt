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
    }
}
