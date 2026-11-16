// Player backend contract — one backend per engine.
//
// The native player (media_kit / fijk / BetterPlayer) IS the player for
// live AND VOD. The web page is only a browsing shell and must never render
// a web <video> player inside the app.
//
// Dispose discipline (fix 1, Dart spelling of the Swift C-string /
// render-queue crashes): every dispose first cancels/awaits pending frame
// or render callbacks, then releases the native handle, then nulls the
// reference; never release while a callback may still hold it, and never
// dispose twice. Dispose is idempotent and safe from any lifecycle path.

import 'package:flutter/widgets.dart';

import 'player_engine.dart';

/// Result of a staged open: the backend is only swapped in after it has
/// PROVEN it can play (first frame or position movement), never merely
/// because open() returned.
enum BackendOpenResult { playing, failed }

abstract class PlayerBackend {
  PlayerEngine get engine;

  /// The native video surface for this backend (16:9 via AspectRatio at
  /// the call site).
  Widget buildVideoWidget();

  /// Open a URL. Applies per-source properties (live: cache-pause=no,
  /// force-seekable=no; HLS: demuxer-lavf-format=hls) before playback.
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  });

  /// Verify real playback: first frame or position movement within
  /// [timeout]. `open` returning is NOT success.
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  });

  Future<void> play();
  Future<void> pause();
  Future<void> setVolume(double volume);

  /// Position stream — health is judged by POSITION movement, not by
  /// player flags (`playing` only means "not paused").
  Stream<Duration> get positionStream;

  /// Total duration when known (VOD). Live streams report Duration.zero
  /// (or never emit). Emits when the duration becomes known / changes,
  /// so the UI can build a progress bar once the value exists.
  Stream<Duration> get durationStream;

  /// Seek to [position] (VOD only). Live backends ignore it (live is
  /// not seekable); the session never calls it for live.
  Future<void> seekTo(Duration position);

  /// True while the backend reports playing.
  Stream<bool> get playingStream;

  /// Fatal playback errors (empty string payloads are ignored by callers).
  Stream<String> get errorStream;

  /// Normal end of a VOD source (live EOF is an error, not completion).
  Stream<void> get completedStream;

  /// Idempotent dispose: cancel callbacks first, then release the handle.
  Future<void> dispose();
}
