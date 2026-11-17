// AVPlayer-backed music player — 歌一刀 (KMusic) uses AVFoundation's
// AVPlayer for music, and so do we now (chen 2026-11-17). Thin adapter
// around just_audio's AudioPlayer, which is AVPlayer on iOS.
//
// It exposes the small surface MusicPlayerController used from media_kit
// (two players A/B for Apple Music-style crossfade), so the controller
// keeps its shape and every music feature above it (lyrics, quality,
// downloads, favourites, listen report, comments) is untouched.
//
// Differences from media_kit, handled here:
// - Volume is 0.0..1.0 (media_kit took 0..100).
// - Rate is setSpeed (media_kit setRate); same meaning.
// - Errors arrive on errorStream as PlayerException (media_kit: String).
//   Load failures do NOT throw from open()/play(): they are reported on
//   the error stream, exactly like media_kit, so the controller's
//   candidate-fallback / next-song path runs unchanged.
// - just_audio's AudioPlayer() constructor is pure Dart (the native
//   player is created lazily on first load), but its methods throw
//   MissingPluginException on platforms without native audio. The
//   controller therefore only constructs adapters on supported
//   platforms (see AvMusicPlayer.isSupported) — on Linux tests the
//   players stay uninitialised, same as the old media_kit failure path.
//
// Audio session: just_audio activates the session itself on play()
// (audio_session default config = music() = category playback), which
// is exactly what NowPlayingPlugin sets — no fight over the session,
// and the plugin's heartbeat keeps it alive. just_audio also pauses
// on phone-call / headphone-unplug interruptions and resumes after.

import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import '../../services/music/music_models.dart';

/// One AVPlayer-backed audio player (one half of the A/B crossfade pair).
class AvMusicPlayer {
  final AudioPlayer _player = AudioPlayer();

  /// True on platforms where just_audio has a native AVPlayer
  /// (iOS/macOS/Android). False on Linux/Windows/web test runs.
  static bool get isSupported =>
      Platform.isIOS || Platform.isMacOS || Platform.isAndroid;

  /// "与其他音频同时播放" — port of Beans
  /// `PlayerManager.applyAudioMixPreference` (PlayerManager.swift:1451):
  /// category .playback, mode .default, options [.mixWithOthers] when
  /// on, no options when off, then setActive(true). just_audio only
  /// activates the session, it never re-configures the category, so
  /// this is not clobbered by playback. No-op (false) off supported
  /// platforms and in tests, where the platform channel is absent.
  static Future<bool> applyMixWithOthers(bool mix) async {
    if (!isSupported) return false;
    try {
      final session = await AudioSession.instance;
      await session.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionMode: AVAudioSessionMode.defaultMode,
          avAudioSessionCategoryOptions: mix
              ? AVAudioSessionCategoryOptions.mixWithOthers
              : AVAudioSessionCategoryOptions.none,
        ),
      );
      await session.setActive(true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// True once a source was loaded successfully. play()/seek() are
  /// no-ops until then, so a failed open can never hang the caller
  /// (just_audio's play() waits on the platform when the playlist is
  /// empty) and the controller's error-stream fallback runs instead.
  var _hasSource = false;

  AvMusicPlayerStreams get stream => AvMusicPlayerStreams(_player);

  /// Open [url] (http(s) stream or file:// local download) and start
  /// playing when [play] is true.
  ///
  /// Returns false when [url] can never load and was refused *before*
  /// any native call — in that case no error is emitted on
  /// [stream.error], so the caller must fall back itself (the
  /// controller's `_onPlayError` path). Returns true once a source was
  /// handed to the native player, even if the native load later fails:
  /// that failure IS reported on [stream.error], exactly as before.
  Future<bool> open(String url, {bool play = true}) async {
    _hasSource = false;
    // Never let a URL NSURL rejects reach AVURLAsset: it throws
    // NSInvalidArgumentException and kills the process (see
    // isPlayableUrl). Refuse it here instead.
    if (!isPlayableUrl(url)) return false;
    try {
      if (url.startsWith('file://')) {
        await _player.setAudioSource(AudioSource.uri(Uri.parse(url)));
      } else {
        await _player.setUrl(url);
      }
      _hasSource = true;
      if (play) await _player.play();
    } on PlayerException {
      // Also delivered on errorStream; swallow so _openOn completes.
    } catch (_) {
      // Same: a load failure is a stream error, not a throw.
    }
    return true;
  }

  /// Current processing state (synchronous). The controller uses it
  /// to tell a fresh load failure (idle — the native side sets the
  /// state to idle when it reports the error, AudioPlayer.m
  /// sendError:switchToIdle:) from a stale error from a superseded
  /// URL (the new source is loading / ready / playing by the time
  /// the late error is delivered, because just_audio's error stream
  /// is an async pipe off the same playback events that update this
  /// state synchronously). See MusicPlayerController._onStreamError.
  ProcessingState get processingState => _player.processingState;

  Future<void> play() async {
    if (!_hasSource) return;
    try {
      await _player.play();
    } on PlayerException {
      // Delivered on errorStream.
    } catch (_) {}
  }

  Future<void> pause() async {
    try {
      await _player.pause();
    } catch (_) {}
  }

  Future<void> seek(Duration position) async {
    if (!_hasSource) return;
    try {
      await _player.seek(position);
    } catch (_) {}
  }

  /// Volume 0.0..1.0 (media_kit took 0..100).
  Future<void> setVolume(double volume) async {
    try {
      await _player.setVolume(volume.clamp(0.0, 1.0));
    } catch (_) {}
  }

  /// Playback rate, 1.0 = normal (media_kit setRate).
  Future<void> setRate(double rate) async {
    try {
      await _player.setSpeed(rate);
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      await _player.dispose();
    } catch (_) {}
  }
}

/// The media_kit-shaped stream bundle the controller subscribes to.
/// just_audio's own streams are BehaviorSubject-backed (they replay the
/// latest value to a new subscriber), so they delegate 1:1.
class AvMusicPlayerStreams {
  AvMusicPlayerStreams(this._player);

  final AudioPlayer _player;

  Stream<Duration> get position => _player.positionStream;

  Stream<Duration> get duration =>
      _player.durationStream.map((d) => d ?? Duration.zero);

  Stream<bool> get playing => _player.playingStream;

  Stream<String> get error =>
      _player.errorStream.map((e) => e.message ?? 'play error');

  Stream<bool> get completed => _player.playerStateStream
      .map((s) => s.processingState == ProcessingState.completed)
      .distinct();
}
