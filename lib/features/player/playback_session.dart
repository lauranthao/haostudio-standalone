// Playback session — the single playback API the UI talks to.
//
// State machine (study §F): idle / opening / buffering / playing /
// paused / completed / error / stopped. Health is judged by POSITION
// movement, not by player flags (a "playing" flag only means "not
// paused"). Staging: a new backend is initialised + opened + verified
// playable BEFORE it replaces the old one — never swap in a backend that
// has not proven it can play.
//
// Live failure order (fix 3): next line -> fresh re-parse (never the same
// URL) -> engine ladder. VOD failure: ladder, then manual retry (episode
// URLs do not expire like live anti-codes).

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/player/kernel/avplayer_backend.dart';
import '../../core/player/kernel/ijk_backend.dart';
import '../../core/player/kernel/mpv_backend.dart';
import '../../core/player/kernel/player_backend.dart';
import '../../core/player/kernel/player_engine.dart';
import '../../core/player/kernel/player_kernel.dart';
import '../../core/player/kernel/recovery_ladder.dart';
import '../../core/storage/hive_store.dart';
import '../live/live_breadcrumb.dart';

enum PlaybackStatus {
  idle,
  opening,
  buffering,
  playing,
  paused,
  completed,
  error,
  stopped,
}

/// Callbacks the session uses to reach the platform layer for fresh URLs.
/// [refreshUrls] must RE-PARSE (never return the dead URL) and returns null
/// when the room is offline / the parse failed.
typedef RefreshUrls = Future<List<String>?> Function();

/// Build one backend per engine. Overridable for tests (fake backends);
/// production always uses the real native backends.
typedef BackendFactory = PlayerBackend Function(PlayerEngine engine);

PlayerBackend _defaultBackendFactory(PlayerEngine engine) {
  switch (engine) {
    case PlayerEngine.mediaKit:
      return MpvBackend();
    case PlayerEngine.fijk:
      return IjkBackend();
    case PlayerEngine.exo:
      return AvPlayerBackend();
  }
}

class PlaybackSession {
  PlaybackSession({
    this._preferred = PlayerEngine.mediaKit,
    BackendFactory? backendFactory,
  }) : _backendFactory = backendFactory ?? _defaultBackendFactory;

  PlayerEngine _preferred;
  final BackendFactory _backendFactory;
  PlayerBackend? _backend;
  PlaybackStatus _status = PlaybackStatus.idle;
  String? _currentUrl;
  bool _isLive = false;
  String? _declaredFormat;
  Map<String, String>? _headers;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<void>? _completedSub;
  Timer? _stallTimer;
  Duration _lastPosition = Duration.zero;
  DateTime _lastPositionAt = DateTime.now();
  bool _stallNoticed = false;
  bool _disposed = false;

  final _statusController = StreamController<PlaybackStatus>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _stallNoticeController = StreamController<void>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();

  PlaybackStatus get status => _status;
  PlayerEngine? get activeEngine => _backend?.engine;
  String? get currentUrl => _currentUrl;
  bool get isLive => _isLive;

  Stream<PlaybackStatus> get onStatus => _statusController.stream;
  Stream<String> get onError => _errorController.stream;

  /// Fired at 4 s of position stall (UI shows "重新连接").
  Stream<void> get onStallNotice => _stallNoticeController.stream;

  /// Raw playback position (forwarded from the active backend). VOD
  /// uses it to save resume positions (throttled by the caller); live
  /// does not use it. Additive only — no existing behaviour changed.
  Stream<Duration> get positionStream => _positionController.stream;

  Widget buildVideoWidget() =>
      _backend?.buildVideoWidget() ?? const SizedBox.shrink();

  /// Total duration of the current VOD source. Re-emitted through the
  /// session's own controller (like position), so a ladder backend swap
  /// does not strand the UI's listener. Live reports Duration.zero.
  Stream<Duration> get durationStream => _durationController.stream;

  /// Seek the current VOD source (no-op for live — live is not seekable).
  /// The caller guards with [isLive]; seeking before the backend exists
  /// is a harmless no-op.
  Future<void> seekTo(Duration position) async {
    if (_isLive) return;
    await _backend?.seekTo(position);
  }

  PlayerEngine get preferredEngine => _preferred;

  /// Switch the preferred engine immediately: rebuild the backend, keep
  /// source/position/intent (study §3.3). Persists the choice.
  /// The persistence write is fire-and-forget: an engine switch must
  /// never wait on storage I/O.
  Future<void> switchEngine(PlayerEngine engine, {bool isManual = false}) async {
    _preferred = engine;
    unawaited(
      HiveStore.put(HiveKeys.videoPlayerKey, engine.key).catchError((_) {}),
    );
    if (_currentUrl != null) {
      await open(
        url: _currentUrl!,
        isLive: _isLive,
        declaredFormat: _declaredFormat,
        headers: _headers,
      );
    }
    if (isManual) {
      // Settings display follows the engine actually playing; the status
      // stream lets the settings page re-read activeEngine.
      _emitStatus(_status);
    }
  }

  PlayerBackend _buildBackend(PlayerEngine engine) => _backendFactory(engine);

  void _emitStatus(PlaybackStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  void _emitError(String message) {
    if (!_errorController.isClosed) _errorController.add(message);
  }

  /// Open a URL through the kernel ladder. Returns true once real
  /// playback is verified on some capable engine.
  ///
  /// [freshRounds] bounds the fresh-URL recursion (fix 3): at most 2
  /// fresh re-parses per open, so a room whose re-parse keeps returning
  /// dead URLs cannot loop forever.
  Future<bool> open({
    required String url,
    required bool isLive,
    String? declaredFormat,
    Map<String, String>? headers,
    RefreshUrls? refreshUrls,
    int freshRounds = 2,
  }) async {
    if (_disposed) return false;
    _currentUrl = url;
    _isLive = isLive;
    _declaredFormat = declaredFormat;
    _headers = headers;
    _emitStatus(PlaybackStatus.opening);
    // Breadcrumb is best-effort telemetry: never let playback start wait
    // on a storage write.
    unawaited(LiveBreadcrumb.write('live-prepared'));

    final engines = candidatesFor(
      url: url,
      declaredFormat: declaredFormat,
      isLive: isLive,
      preferred: _preferred,
    );
    if (engines.isEmpty) {
      _emitStatus(PlaybackStatus.error);
      _emitError('没有可用的播放器引擎');
      return false;
    }

    final ladder = RecoveryLadder(
      engines: engines,
      urls: [url],
      attempt: ({required PlayerEngine engine, required String url}) async {
        final candidate = _buildBackend(engine);
        try {
          // sourceOpen 18 s (study §1.3): a backend whose open() never
          // returns must not stall the ladder. TimeoutException is
          // caught below and the candidate is disposed.
          await candidate
              .open(
                url: url,
                headers: headers,
                isLive: isLive,
                declaredFormat: declaredFormat,
              )
              .timeout(const Duration(seconds: 18));
          final ok = await candidate.waitForFirstFrame();
          if (!ok) {
            await candidate.dispose();
            return false;
          }
          // Staged swap: only now does the new backend replace the old.
          await _swapBackend(candidate);
          unawaited(LiveBreadcrumb.write('live-first-frame'));
          return true;
        } catch (_) {
          await candidate.dispose();
          return false;
        }
      },
    );

    final won = await ladder.run();
    if (won != null) {
      // Settings follows the engine actually playing.
      _preferred = won.engine;
      _emitStatus(PlaybackStatus.playing);
      unawaited(LiveBreadcrumb.write('live-playing'));
      _startHealthWatch();
      return true;
    }

    // Ladder exhausted. Live goes to the fresh-URL path (fix 3), never a
    // dead-end error on the same URL. Bounded by [freshRounds].
    if (isLive && refreshUrls != null && freshRounds > 0) {
      final fresh = await refreshUrls();
      if (fresh != null && fresh.isNotEmpty && fresh.first != url) {
        return open(
          url: fresh.first,
          isLive: isLive,
          declaredFormat: declaredFormat,
          headers: headers,
          refreshUrls: refreshUrls,
          freshRounds: freshRounds - 1,
        );
      }
    }
    _emitStatus(PlaybackStatus.error);
    _emitError('播放失败，请检查网络后重试');
    return false;
  }

  Future<void> _swapBackend(PlayerBackend next) async {
    final old = _backend;
    _backend = next;
    _attachBackend(next);
    // Dispose the old backend only after the new one is attached and
    // verified (fix 1: never release while a callback may still hold it).
    await old?.dispose();
  }

  void _attachBackend(PlayerBackend backend) {
    unawaited(_positionSub?.cancel());
    unawaited(_durationSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_completedSub?.cancel());
    _positionSub = backend.positionStream.listen((pos) {
      if (!_positionController.isClosed) _positionController.add(pos);
      if (pos != _lastPosition) {
        _lastPosition = pos;
        _lastPositionAt = DateTime.now();
        _stallNoticed = false;
      }
      if (_status == PlaybackStatus.opening ||
          _status == PlaybackStatus.buffering) {
        _emitStatus(PlaybackStatus.playing);
      }
    });
    _durationSub = backend.durationStream.listen((dur) {
      if (!_durationController.isClosed) _durationController.add(dur);
    });
    _errorSub = backend.errorStream.listen((message) {
      if (message.isEmpty) return;
      _onBackendFailure(message);
    });
    _completedSub = backend.completedStream.listen((_) {
      if (_isLive) {
        // Live EOF is an error -> recovery ladder, not completion.
        _onBackendFailure('live_source_completed');
      } else {
        _emitStatus(PlaybackStatus.completed);
      }
    });
  }

  void _onBackendFailure(String message) {
    if (_status == PlaybackStatus.error) return;
    _emitStatus(PlaybackStatus.error);
    _emitError(message);
  }

  /// Position-movement health watch: 4 s stall -> notice, 12 s -> failure.
  void _startHealthWatch() {
    _stallTimer?.cancel();
    _lastPosition = Duration.zero;
    _lastPositionAt = DateTime.now();
    _stallNoticed = false;
    _stallTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) return;
      if (_status != PlaybackStatus.playing) return;
      final stalled = DateTime.now().difference(_lastPositionAt);
      if (stalled >= const Duration(seconds: 4) && !_stallNoticed) {
        _stallNoticed = true;
        if (!_stallNoticeController.isClosed) {
          _stallNoticeController.add(null);
        }
      }
      if (stalled >= const Duration(seconds: 12)) {
        _onBackendFailure('buffering_stall');
      }
    });
    // Healthy 30 s of playback resets the recovery budget (study §1.3) —
    // the ladder's resetBudget() is called by the room when playback has
    // been healthy; no timer is needed here.
  }

  Future<void> play() async {
    await _backend?.play();
    _emitStatus(PlaybackStatus.playing);
  }

  Future<void> pause() async {
    await _backend?.pause();
    _emitStatus(PlaybackStatus.paused);
  }

  Future<void> togglePlayPause() async {
    if (_status == PlaybackStatus.playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> setVolume(double volume) => _backend?.setVolume(volume) ?? Future.value();

  /// Idempotent dispose (fix 1): cancel callbacks first, then release.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stallTimer?.cancel();
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _errorSub?.cancel();
    await _completedSub?.cancel();
    await _backend?.dispose();
    _backend = null;
    await _statusController.close();
    await _errorController.close();
    await _stallNoticeController.close();
    await _positionController.close();
    await _durationController.close();
    unawaited(LiveBreadcrumb.write('live-closed'));
  }
}
