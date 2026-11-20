// MPV-backed music player for Windows — media_kit (libmpv).
//
// Windows has no AVPlayer and just_audio ships no Windows native
// code, so the AVPlayer adapter (AvMusicPlayer) can never play there.
// This adapter implements the same MusicPlayerAdapter contract the
// controller drives (see music_player_adapter.dart), so every rule
// above it — first playable source plays immediately, quality-tier
// fallback, Master only from a real Master URL, A/B crossfade —
// behaves identically on Windows. Only the engine differs.
//
// Differences from AvMusicPlayer, handled here:
// - Volume is 0.0..1.0 here; media_kit takes 0..100 (converted).
// - Errors arrive on errorStream as String (same shape as media_kit
//   video backends). Load failures do NOT throw from open()/play():
//   they are reported on the error stream, exactly like AvMusicPlayer,
//   so the controller's candidate-fallback / next-song path runs
//   unchanged.
// - processingState is derived synchronously from the load flags
//   (see the getter): failed => idle, loaded => ready, no source
//   yet => idle. The controller only reads idle vs non-idle.
// - media_kit's Player() constructor needs MediaKit.ensureInitialized()
//   first (main() does it; this constructor does it defensively too,
//   like MpvBackend).
// - Equalizer: mpv has no per-player EQ API in the Dart layer — the
//   10-band EQ + preamp are applied as an `af` filter chain
//   (equalizer=… per band + volume=… for preamp) via
//   NativePlayer.setProperty, the same call MpvBackend uses for its
//   tuning table. [applyEqualizer] pushes the current settings to
//   every live instance AND remembers them, so a player opened later
//   applies them in open() (the store pushes at startup before any
//   player exists).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:media_kit/media_kit.dart';

import '../../core/logging/app_log.dart';
import '../../services/music/music_models.dart' show isPlayableUrl;
import 'music_player_adapter.dart';

/// One media_kit-backed audio player (one half of the A/B crossfade
/// pair on Windows).
class MpvMusicPlayer implements MusicPlayerAdapter {
  MpvMusicPlayer() {
    // Defensive: the native media_kit library must be initialised
    // before Player() is created (main() does this; same pattern as
    // MpvBackend — _player is late final so it is created here,
    // after ensureInitialized, not in a field initializer).
    MediaKit.ensureInitialized();
    _player = Player(
      configuration: const PlayerConfiguration(title: 'HAo Studio'),
    );
    _errorSub = _player.stream.error.listen((e) {
      if (e.isNotEmpty) {
        _failed = true;
        AppLog.debug('MPV 音乐播放出错：$e');
      }
    });
    _completedSub = _player.stream.completed.listen((done) {
      if (done) _completed = true;
    });
    _live.add(this);
    // A player created after the user changed the EQ still gets the
    // current settings (applied again in open(), after the source is
    // loaded — this early apply covers the no-open-yet window).
    unawaited(_applyAf(_currentAf));
  }

  /// True on Windows, where media_kit is the music engine. False
  /// everywhere else — mobile keeps AVPlayer (chen's iron law).
  static bool get isSupported => Platform.isWindows;

  late final Player _player;

  // Live instances, for the equalizer push (see [applyEqualizer]).
  static final Set<MpvMusicPlayer> _live = {};

  /// The `af` filter chain last pushed by [applyEqualizer] ('' =
  /// no EQ). Remembered so a player opened later applies the same
  /// settings in open().
  static String _currentAf = '';

  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _completedSub;

  var _hasSource = false;
  var _failed = false;
  var _completed = false;
  var _preloadedUrl = '';
  var _disposed = false;

  @override
  MusicPlayerStreams get stream => MpvMusicPlayerStreams(_player);

  @override
  ProcessingState get processingState {
    if (_failed) return ProcessingState.idle;
    if (_completed) return ProcessingState.completed;
    if (!_hasSource) return ProcessingState.idle;
    return ProcessingState.ready;
  }

  @override
  Future<bool> preload(String url) async {
    _preloadedUrl = '';
    if (!isPlayableUrl(url)) return false;
    try {
      await _player.open(Media(url), play: false);
      _hasSource = true;
      _failed = false;
      _completed = false;
      _preloadedUrl = url;
      await _applyAf(_currentAf);
      return true;
    } catch (e) {
      _failed = true;
      AppLog.debug('MPV 音乐预缓冲失败：$e');
      return false;
    }
  }

  @override
  bool isPreloadedFor(String url) =>
      _preloadedUrl.isNotEmpty && _preloadedUrl == url;

  @override
  Future<bool> open(String url, {bool play = true}) async {
    _hasSource = false;
    _preloadedUrl = '';
    _failed = false;
    _completed = false;
    if (!isPlayableUrl(url)) return false;
    try {
      await _player.open(Media(url), play: play);
      _hasSource = true;
      // A load that already failed reports through the error stream
      // (and flips _failed); the controller's idle check right after
      // open() reads the flags synchronously.
      await _applyAf(_currentAf);
    } catch (e) {
      // Also delivered on errorStream; swallow so _openOn completes.
      // Mark failed so the controller's idle check catches it now
      // instead of waiting for the (possibly lost) stream event.
      _failed = true;
      AppLog.debug('MPV 音乐打开失败：$e');
    }
    return true;
  }

  @override
  Future<void> play() async {
    if (!_hasSource || _disposed) return;
    try {
      await _player.play();
    } catch (_) {}
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    try {
      await _player.pause();
    } catch (_) {}
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_hasSource || _disposed) return;
    try {
      await _player.seek(position);
    } catch (_) {}
  }

  /// Volume 0.0..1.0 (media_kit takes 0..100).
  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    try {
      await _player.setVolume(volume.clamp(0.0, 1.0) * 100);
    } catch (_) {}
  }

  /// Playback rate, 1.0 = normal.
  @override
  Future<void> setRate(double rate) async {
    if (_disposed) return;
    try {
      await _player.setRate(rate);
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _live.remove(this);
    await _errorSub?.cancel();
    await _completedSub?.cancel();
    try {
      await _player.dispose();
    } catch (_) {}
  }

  /// Push the 10-band EQ + preamp to every live Windows music
  /// player as an mpv `af` filter chain, and remember it for players
  /// opened later. [gains] are dB per band (0.5 steps, +-12);
  /// [preamp] is dB. Disabled or all-flat means no filter chain
  /// (af = ''), which is exactly flat. Best-effort: a failed set
  /// never throws — the store already persisted the values.
  static Future<void> applyEqualizer({
    required bool enabled,
    required List<double> gains,
    required double preamp,
  }) async {
    _currentAf = equalizerAf(
      enabled: enabled,
      gains: gains,
      preamp: preamp,
    );
    for (final player in _live.toList()) {
      await player._applyAf(_currentAf);
    }
  }

  /// Build the mpv `af` chain for the EQ. One `equalizer` filter per
  /// non-flat band (width one octave — the standard 10-band layout)
  /// plus a `volume` filter for the preamp (linear gain). Returns ''
  /// when nothing needs filtering.
  static String equalizerAf({
    required bool enabled,
    required List<double> gains,
    required double preamp,
  }) {
    if (!enabled) return '';
    const frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
    final parts = <String>[];
    for (var i = 0; i < frequencies.length && i < gains.length; i++) {
      final g = gains[i];
      if (g == 0) continue;
      parts.add(
        'equalizer=f=${frequencies[i]}:width_type=o:width=1:g=${_fmtNum(g)}',
      );
    }
    if (preamp != 0) {
      // dB -> linear: 10^(dB/20).
      parts.add('volume=${_fmtNum(math.pow(10, preamp / 20))}');
    }
    return parts.join(',');
  }

  static String _fmtNum(num value) {
    if (value == value.truncateToDouble()) return value.toInt().toString();
    var s = value.toStringAsFixed(2);
    // Trim trailing zeros: 2.50 -> 2.5, 0.50 -> 0.5.
    while (s.endsWith('0')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
  }

  Future<void> _applyAf(String af) async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty('af', af);
      } catch (e) {
        AppLog.debug('MPV 音乐均衡器设置失败：$e');
      }
    }
  }
}

/// The media_kit stream bundle the controller subscribes to.
class MpvMusicPlayerStreams implements MusicPlayerStreams {
  MpvMusicPlayerStreams(this._player);

  final Player _player;

  @override
  Stream<Duration> get position => _player.stream.position;

  @override
  Stream<Duration> get duration => _player.stream.duration;

  @override
  Stream<bool> get playing => _player.stream.playing;

  @override
  Stream<String> get error => _player.stream.error;

  @override
  Stream<bool> get completed => _player.stream.completed.distinct();
}
