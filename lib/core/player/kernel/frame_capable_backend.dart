// Frame-capable backend — optional capability, MPV only.
//
// Follows the TrackCapableBackend pattern on purpose: a separate
// interface that EXTENDS PlayerBackend (not an unrelated interface),
// so `backend is FrameCapableBackend` narrows and the caller can use
// the method directly. It is a separate interface (not a method on
// PlayerBackend) because the old fakes use `implements
// PlayerBackend` — any method added to that class, even with a
// default body, breaks every `implements` fake at compile time.
//
// Only MPV implements this (media_kit Player.screenshot()). AVPlayer
// (BetterPlayer) and IJK (flv_lzc) expose no frame outlet in Dart,
// so they stay without it and danmaku occlusion avoidance silently
// stays off on them — no error, no prompt, danmaku plays in full.

import 'dart:typed_data';

import 'player_backend.dart';

abstract class FrameCapableBackend extends PlayerBackend {
  /// One JPEG snapshot of the current video frame, or null when the
  /// backend cannot produce one (not opened yet, disposed, native
  /// error). JPEG, not raw BGRA: a 1080p BGRA frame is ~8 MB per
  /// snapshot over the channel at 5 Hz; mpv encodes the JPEG natively
  /// and the transfer is tens of KB. The native side decodes it for
  /// Vision. Best-effort: never throws.
  Future<Uint8List?> captureFrameJpeg();
}
