// Music player adapter — the narrow surface MusicPlayerController
// drives: one adapter per crossfade half (A/B). Two implementations:
//
// - AvMusicPlayer: just_audio / AVPlayer (iOS, macOS, Android).
// - MpvMusicPlayer: media_kit / libmpv (Windows — there is no AVPlayer
//   on Windows, and just_audio ships no Windows native code).
//
// Both honour the same contract (the controller's rules live ABOVE
// this interface and never change per engine):
// - open() returns false ONLY when the URL was refused before any
//   native call (so no error will arrive on stream.error and the
//   caller must fall back itself); it returns true once a source was
//   handed to the native player, even if the load later fails — that
//   failure IS reported on stream.error.
// - preload() buffers without playing; isPreloadedFor() reports it.
// - play()/seek() are no-ops until a source loaded successfully.
// - A load failure leaves processingState == ProcessingState.idle
//   (the controller's lost-error guard reads this synchronously
//   right after open() — see _crossfadeTo).
// - Volume is 0.0..1.0 (media_kit takes 0..100, the adapter converts);
//   rate 1.0 = normal.
//
// ProcessingState is just_audio's enum, kept as the shared vocabulary
// between the controller and both adapters so the existing test fakes
// (which extend AvMusicPlayer and override processingState) keep
// working unchanged. The MPV adapter imports it for the enum only
// and never calls just_audio.

import 'dart:async';

import 'package:just_audio/just_audio.dart' show ProcessingState;

/// The media_kit-shaped stream bundle the controller subscribes to.
abstract class MusicPlayerStreams {
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<bool> get playing;
  Stream<String> get error;
  Stream<bool> get completed;
}

/// One half of the A/B crossfade pair.
abstract class MusicPlayerAdapter {
  MusicPlayerStreams get stream;

  /// Synchronous load state. Only the idle/non-idle distinction is
  /// load-bearing (see the contract above); loading/ready/buffering
  /// all read as "not idle" to the controller.
  ProcessingState get processingState;

  /// Pre-buffer [url] without playing it. Returns true when the
  /// source loaded. A later [open] on this player supersedes the
  /// preload. A failed preload leaves nothing behind.
  Future<bool> preload(String url);

  /// True when this player already holds [url] buffered from
  /// [preload] (and nothing else was opened since).
  bool isPreloadedFor(String url);

  /// Open [url] (http(s) stream or file:// local download) and start
  /// playing when [play] is true. See the contract above for the
  /// return value and error reporting.
  Future<bool> open(String url, {bool play = true});

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// Volume 0.0..1.0.
  Future<void> setVolume(double volume);

  /// Playback rate, 1.0 = normal.
  Future<void> setRate(double rate);

  Future<void> dispose();
}
