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
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/player/kernel/avplayer_backend.dart';
import '../../core/player/kernel/frame_capable_backend.dart';
import '../../core/player/kernel/ijk_backend.dart';
import '../../core/player/kernel/mpv_backend.dart';
import '../../core/player/kernel/player_backend.dart';
import '../../core/player/kernel/player_engine.dart';
import '../../core/player/kernel/player_kernel.dart';
import '../../core/player/kernel/recovery_ladder.dart';
import '../../core/player/super_resolution.dart';
import '../../core/player/vod_controls.dart';
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
    PlayerEngine? preferred,
    BackendFactory? backendFactory,
  })  : _preferred = preferred ?? _storedPreferredEngine,
        _backendFactory = backendFactory ?? _defaultBackendFactory;

  /// The engine the user picked in Settings (`videoPlayerKey`).
  ///
  /// Was: the constructor always defaulted to MPV and nothing ever
  /// read `videoPlayerKey` on open — the settings engine picker wrote
  /// a key no session honoured, so picking IJK / AVPlayer changed
  /// nothing on the next open (orphan control; the settings comment
  /// claiming "picks it up on next open" was false). Now the stored
  /// choice is the default; an explicit [preferred] still wins
  /// (tests, callers). Uninitialised or corrupt storage falls back
  /// to MPV instead of throwing.
  static PlayerEngine get _storedPreferredEngine {
    try {
      return PlayerEngineX.fromKey(
        HiveStore.getString(HiveKeys.videoPlayerKey, 'mpv'),
      );
    } catch (_) {
      return PlayerEngine.mediaKit;
    }
  }

  PlayerEngine _preferred;
  final BackendFactory _backendFactory;
  PlayerBackend? _backend;
  PlaybackStatus _status = PlaybackStatus.idle;
  String? _currentUrl;
  bool _isLive = false;
  String? _declaredFormat;
  Map<String, String>? _headers;
  double _rate = 1.0;

  /// Last volume sent to the player (b30): the live volume boost
  /// (and multiview focus mute) is a software gain via [setVolume],
  /// and a quality / line / engine switch installs a fresh backend
  /// at its default volume 1.0. Remembered here so [_swapBackend]
  /// re-applies it — same rule as [_rate]. Null = never set (VOD
  /// never calls setVolume: its volume is the system volume, so
  /// nothing is re-applied there).
  double? _volume;

  /// IJK exclusion (L-P0-1): IJK's fijk data-source call drops every
  /// request header, so Huya/Douyu live streams (which need UA +
  /// Origin + Referer + cookie) die ~7 s after opening on IJK. The
  /// room sets this on open(); it is remembered so the fresh-URL
  /// recursion and [switchEngine] re-opens honour it too. VOD never
  /// sets it (its headers are best-effort, and IJK stays available).
  bool _excludeIjk = false;

  /// Open generation: each [open] call bumps it, so a ladder attempt
  /// from a superseded open (e.g. one cut short by [openBudget])
  /// can never swap its backend in or emit status after the new open
  /// started. Attempts check the generation after every await.
  int _openGeneration = 0;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<void>? _completedSub;
  StreamSubscription<List<String>>? _subtitleSub;
  Timer? _stallTimer;
  Duration _lastPosition = Duration.zero;
  DateTime _lastPositionAt = DateTime.now();
  bool _stallNoticed = false;
  bool _disposed = false;

  /// Dialogue boost (I-影视 item 3, VOD only): remembered so a
  /// ladder backend swap re-applies it to the new backend, like
  /// [_rate]. Implemented by MpvBackend (K 组, build 29:
  /// volume-max=300 + centre-channel fold); other backends no-op.
  bool _dialogueBoost = false;

  bool get dialogueBoost => _dialogueBoost;

  /// VOD picture-enhancement trio (b30): remembered so a ladder
  /// backend swap re-applies it to the new backend, like [_rate]
  /// and [_dialogueBoost]. At most one is ever true — the page owns
  /// the mutual exclusion in display, and [setVodEnhancement]
  /// normalises through resolveVodEnhancement (first-branch-wins,
  /// same order as MpvBackend.open()) before remembering.
  bool _superResolution = false;
  bool _interpolation = false;
  bool _sdrToHdr = false;

  bool get superResolution => _superResolution;
  bool get interpolation => _interpolation;
  bool get sdrToHdr => _sdrToHdr;

  /// Audio-only mode (live background playback): the video track is
  /// off while the app is backgrounded. Remembered so a ladder
  /// backend swap re-applies it to the new backend, like [_rate].
  bool _audioOnly = false;

  /// Selected audio/subtitle track ids (backend-native, see
  /// [PlaybackTrack.id]; null = backend default). Remembered so a
  /// ladder backend swap re-applies them to the new backend, like
  /// [_rate] — a swap must not silently reset the user's track
  /// choice. The player page reads these to mark the active row.
  String? _audioTrackId;
  String? _subtitleTrackId;

  String? get currentAudioTrackId => _audioTrackId;
  String? get currentSubtitleTrackId => _subtitleTrackId;

  /// Subtitle time offset, seconds (1.1.6, MPV `sub-delay`, ±10).
  /// Remembered like the track ids and re-applied after a ladder
  /// backend swap, so an episode / line / kernel switch never loses
  /// the user's sync correction.
  double _subtitleDelay = 0.0;

  double get currentSubtitleDelay => _subtitleDelay;

  /// Subtitle appearance (1.1.6, MPV `sub-font-size` / `sub-color` /
  /// `sub-pos`). Remembered like [_subtitleDelay] and re-applied
  /// after a ladder backend swap. Null = mpv defaults (never
  /// applied) — the player page sets it once at open from the
  /// persisted tiers, and the settings page changes it for the
  /// next open.
  ({int fontSize, String color, double position})? _subtitleAppearance;

  ({int fontSize, String color, double position})?
      get currentSubtitleAppearance => _subtitleAppearance;

  /// Second subtitle track id for dual subtitles (MPV
  /// `secondary-sid`; null = off). Remembered and re-applied like
  /// [_subtitleTrackId]. The picker row lives in the track sheet
  /// (native_video_player_page.dart), so this is in-memory until
  /// the picker calls [setSecondarySubtitleTrack].
  String? _secondarySubtitleTrackId;

  String? get currentSecondarySubtitleTrackId => _secondarySubtitleTrackId;

  /// Preopened (staged) backend for a seamless line switch (1.1.6):
  /// [preopen] opens the next line's URL on a fresh backend and
  /// holds it here — verified playable, but NOT installed — until
  /// [swapToPreopened] swaps it in. The currently playing backend
  /// is untouched while a preopen is in flight or staged, so a
  /// failed preopen costs nothing: the old line just keeps playing.
  /// A staged backend is owned by one preopen generation; a newer
  /// [open] or [preopen] disposes it (see [_disposePreopened]).
  PlayerBackend? _preopenedBackend;
  String? _preopenedUrl;
  PlayerEngine? _preopenedEngine;
  int _preopenGeneration = 0;

  /// Whether the app is in the foreground, as told by the owning page
  /// via [setForeground]. Defaults to foreground so a session used
  /// without a page (tests) still holds the wakelock while playing.
  bool _foreground = true;

  /// Whether the wakelock is currently held by this session. Guards
  /// the platform call so repeated playing emissions do not spam the
  /// channel (WakelockPlus itself dedupes, but the call is still a
  /// platform round-trip per emission).
  bool _wakelockHeld = false;

  bool get isAudioOnly => _audioOnly;

  final _statusController = StreamController<PlaybackStatus>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _stallNoticeController = StreamController<void>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _ladderAttemptController = StreamController<PlayerEngine>.broadcast();

  /// Text subtitle lines, forwarded from the active capable backend
  /// (`[main, secondary]`). The VOD page draws these in its own
  /// overlay above the danmaku layer; a backend without the
  /// capability contributes nothing (empty lines).
  final _subtitleController = StreamController<List<String>>.broadcast();

  /// Text subtitle lines `[main, secondary]` from the active backend.
  Stream<List<String>> get subtitleStream => _subtitleController.stream;

  PlaybackStatus get status => _status;
  PlayerEngine? get activeEngine => _backend?.engine;

  /// The active backend when it can hand out video frames (MPV
  /// only, 1.1.6 danmaku occlusion avoidance). Null on IJK / AVPlayer
  /// and before any backend is swapped in — the occlusion loop
  /// treats null as "feature silently off, danmaku plays in full".
  /// Re-read on every use: the ladder can swap the backend
  /// mid-playback, so a cached value would go stale.
  FrameCapableBackend? get frameCapableBackend {
    final backend = _backend;
    return backend is FrameCapableBackend ? backend : null;
  }
  String? get currentUrl => _currentUrl;
  bool get isLive => _isLive;

  Stream<PlaybackStatus> get onStatus => _statusController.stream;
  Stream<String> get onError => _errorController.stream;

  /// Fired at 4 s of position stall (UI shows "重新连接").
  Stream<void> get onStallNotice => _stallNoticeController.stream;

  /// Fired when the ladder starts trying an engine — the room shows
  /// "正在尝试 MPV…/IJK…" instead of a bare spinner.
  Stream<PlayerEngine> get onLadderAttempt =>
      _ladderAttemptController.stream;

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
  ///
  /// Position is preserved on VOD: the current position is captured
  /// BEFORE the re-open and sought back after it succeeds (live is
  /// not seekable, so nothing is sought there). Before this fix the
  /// switch re-opened from 0 — a manual engine switch mid-film
  /// restarted the film.
  Future<void> switchEngine(PlayerEngine engine, {bool isManual = false}) async {
    _preferred = engine;
    unawaited(
      HiveStore.put(HiveKeys.videoPlayerKey, engine.key).catchError((_) {}),
    );
    if (_currentUrl != null) {
      final resume = _isLive ? Duration.zero : _lastPosition;
      final ok = await open(
        url: _currentUrl!,
        isLive: _isLive,
        declaredFormat: _declaredFormat,
        headers: _headers,
        excludeIjk: _excludeIjk,
      );
      if (ok && !_isLive && resume > Duration.zero) {
        await seekTo(resume);
      }
    }
    if (isManual) {
      // Settings display follows the engine actually playing; the status
      // stream lets the settings page re-read activeEngine.
      _emitStatus(_status);
    }
  }

  /// Dispose a staged preopened backend, if any, and forget it.
  /// Never touches the playing backend.
  Future<void> _disposePreopened() async {
    final staged = _preopenedBackend;
    _preopenedBackend = null;
    _preopenedUrl = null;
    _preopenedEngine = null;
    if (staged != null) {
      await staged.dispose();
    }
  }

  /// Pre-open a URL on a fresh backend WITHOUT installing it
  /// (1.1.6 seamless line switch). The candidate walks the same
  /// engine ladder as [open] (10 s open + first-frame wait per
  /// engine, bounded by [timeout] overall — default 10 s, so a dead
  /// line never holds the switch longer than that) but the playing
  /// backend, [_currentUrl] and [status] are untouched throughout:
  /// no status is emitted, no position stream moves. Returns true
  /// once a backend has proven it can play [url]; the caller then
  /// swaps it in with [swapToPreopened]. Returns false when no
  /// engine could play it — the old line just keeps playing.
  ///
  /// A newer [open] or [preopen] retires this preopen at once (the
  /// generation guard): a superseded attempt never stages its
  /// backend, and a staged backend from an older preopen is
  /// disposed before a new one is staged.
  Future<bool> preopen({
    required String url,
    required bool isLive,
    String? declaredFormat,
    Map<String, String>? headers,
    bool excludeIjk = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_disposed) return false;
    final generation = ++_preopenGeneration;
    await _disposePreopened();
    if (_disposed || generation != _preopenGeneration) return false;
    var engines = candidatesFor(
      url: url,
      declaredFormat: declaredFormat,
      isLive: isLive,
      preferred: _preferred,
    );
    if (excludeIjk) {
      engines = engines.where((e) => e != PlayerEngine.fijk).toList();
    }
    if (engines.isEmpty) return false;
    final deadline = DateTime.now().add(timeout);
    for (final engine in engines) {
      if (_disposed || generation != _preopenGeneration) return false;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return false;
      PlayerBackend? candidate;
      try {
        candidate = _buildBackend(engine);
        final openTimeout = remaining < const Duration(seconds: 10)
            ? remaining
            : const Duration(seconds: 10);
        await candidate
            .open(
              url: url,
              headers: headers,
              isLive: isLive,
              declaredFormat: declaredFormat,
            )
            .timeout(openTimeout);
        if (_disposed || generation != _preopenGeneration) {
          await candidate.dispose();
          return false;
        }
        final frameBudget = deadline.difference(DateTime.now());
        if (frameBudget <= Duration.zero) {
          await candidate.dispose();
          return false;
        }
        final ok = await candidate.waitForFirstFrame(timeout: frameBudget);
        if (_disposed || generation != _preopenGeneration) {
          await candidate.dispose();
          return false;
        }
        if (!ok) {
          await candidate.dispose();
          continue;
        }
        _preopenedBackend = candidate;
        _preopenedUrl = url;
        _preopenedEngine = engine;
        return true;
      } catch (_) {
        if (candidate != null) {
          await candidate.dispose();
        }
        if (_disposed || generation != _preopenGeneration) return false;
      }
    }
    return false;
  }

  /// Swap in the backend staged by [preopen] (1.1.6 seamless line
  /// switch). Seeks it to [resumePosition] first (VOD only; live
  /// ignores the seek), then installs it through the staged
  /// [_swapBackend] — rate / audio-only / track choice are
  /// re-applied there, exactly as on a ladder swap. Returns false
  /// when nothing is staged (or the staged backend belongs to a
  /// different URL); the playing backend is untouched then.
  Future<bool> swapToPreopened({
    required String url,
    required Duration resumePosition,
  }) async {
    final staged = _preopenedBackend;
    if (_disposed || staged == null || _preopenedUrl != url) return false;
    _preopenedBackend = null;
    _preopenedUrl = null;
    final engine = _preopenedEngine;
    _preopenedEngine = null;
    if (!isLive && resumePosition > Duration.zero) {
      try {
        await staged.seekTo(resumePosition);
      } catch (_) {
        // Best-effort: a backend that refuses the pre-swap seek
        // still plays — from 0 rather than from the resume point,
        // which the caller reports, instead of failing the switch.
      }
    }
    await _swapBackend(staged);
    _currentUrl = url;
    if (engine != null) _preferred = engine;
    _emitStatus(PlaybackStatus.playing);
    _startHealthWatch();
    return true;
  }

  PlayerBackend _buildBackend(PlayerEngine engine) => _backendFactory(engine);

  void _emitStatus(PlaybackStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
    _applyWakelock();
  }

  /// Screen-on (wakelock) is owned HERE, by the session — the single
  /// place that knows "playing" for every engine:
  ///
  /// - MPV's Video widget has its own wakelock, but it is driven by a
  ///   playing subscription on the widget's controller: after a backend
  ///   swap the widget updates (didUpdateWidget only refreshes view
  ///   params) and the subscription still points at the disposed old
  ///   player, so the wakelock never re-enables — and a stale
  ///   playing=false event from the disposed player can switch it off
  ///   mid-playback. mpv_backend passes wakelock: false so this
  ///   session is the only writer.
  /// - IJK (FijkView) has no wakelock at all; BetterPlayer only holds
  ///   it in fullscreen. Either engine reached by user choice or by
  ///   ladder fallback (which persists via _preferred) left the screen
  ///   free to auto-lock during live AND VOD — chen 2026-11-17:
  ///   "看直播的时候系统会自动熄屏" + "估计影视也一样".
  ///
  /// Held while the session is actively playing (opening / buffering /
  /// playing — a room/line/quality switch must not drop it), in the
  /// foreground, and not in audio-only mode (live background audio
  /// must not force the screen on). Released on pause, completion,
  /// error, backgrounding, and dispose.
  bool get _wantWakelock =>
      _foreground &&
      !_audioOnly &&
      (_status == PlaybackStatus.opening ||
          _status == PlaybackStatus.buffering ||
          _status == PlaybackStatus.playing);

  void _applyWakelock() {
    final want = !_disposed && _wantWakelock;
    if (want == _wakelockHeld) return;
    _wakelockHeld = want;
    // Fire-and-forget, never throws: a failed platform call must not
    // break playback (same pattern as media_kit_video's Wakelock).
    unawaited(
      (want ? WakelockPlus.enable() : WakelockPlus.disable())
          .catchError((_) {}),
    );
  }

  /// App foreground state, told by the owning page (the lifecycle
  /// observer lives on the page, never on the shared session).
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    _applyWakelock();
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
  ///
  /// [urls] (L-P1-3): every URL of the current resolution, in line
  /// order. The ladder tries them all (per engine) before any fresh
  /// re-parse — a single-url caller only ever tries `url`. The winning
  /// URL becomes [_currentUrl], so an engine switch re-opens what is
  /// actually playing, not `urls.first`.
  ///
  /// [excludeIjk] (L-P0-1): drop IJK from the candidates — the room
  /// passes it for Huya/Douyu live, where IJK drops the headers the
  /// CDN requires.
  ///
  /// [openBudget] (V-P1-2): total budget for this open (VOD passes
  /// 30 s). When it fires the open reports false at once; the
  /// superseded ladder's attempts see the bumped generation and abort
  /// before swapping anything in, so the caller can move on to the
  /// next line/source immediately.
  Future<bool> open({
    required String url,
    required bool isLive,
    String? declaredFormat,
    Map<String, String>? headers,
    RefreshUrls? refreshUrls,
    int freshRounds = 2,
    List<String>? urls,
    bool excludeIjk = false,
    Duration? openBudget,
  }) async {
    if (_disposed) return false;
    // A fresh open retires any staged preopen: the staged backend
    // belongs to the old switch target, and an in-flight preopen
    // must never stage its backend after this open started.
    _preopenGeneration++;
    await _disposePreopened();
    _currentUrl = url;
    _isLive = isLive;
    _declaredFormat = declaredFormat;
    _headers = headers;
    _excludeIjk = excludeIjk;
    final generation = ++_openGeneration;
    _emitStatus(PlaybackStatus.opening);
    // Breadcrumb is best-effort telemetry: never let playback start wait
    // on a storage write.
    unawaited(LiveBreadcrumb.write('live-prepared'));

    var engines = candidatesFor(
      url: url,
      declaredFormat: declaredFormat,
      isLive: isLive,
      preferred: _preferred,
    );
    if (excludeIjk) {
      engines = engines.where((e) => e != PlayerEngine.fijk).toList();
    }
    if (engines.isEmpty) {
      _emitStatus(PlaybackStatus.error);
      _emitError('没有可用的播放器引擎');
      return false;
    }

    // De-duplicated, in line order; the single-url path stays [url].
    final ladderUrls = <String>[];
    for (final u in urls ?? [url]) {
      if (!ladderUrls.contains(u)) ladderUrls.add(u);
    }

    final ladder = RecoveryLadder(
      engines: engines,
      urls: ladderUrls,
      onAttempt: (engine, url) {
        if (!_ladderAttemptController.isClosed) {
          _ladderAttemptController.add(engine);
        }
      },
      attempt: ({required PlayerEngine engine, required String url}) async {
        // A disposed session must not start new work: the page is
        // gone, so any backend opened here would play with no owner
        // (background audio after exit — the v1.0.5 bug: the film
        // kept playing after the player page was popped).
        if (_disposed) return false;
        // Superseded by a newer open (budget cut or line switch):
        // never start, and never swap in, on behalf of the old open.
        if (generation != _openGeneration) return false;
        // A backend whose CONSTRUCTION throws (missing native library,
        // unregistered plugin) must fail just this attempt, not abort
        // the whole ladder — the next engine may still play. The catch
        // never disposes a backend that was already swapped in as live
        // (candidate == _backend after the swap).
        PlayerBackend? candidate;
        try {
          candidate = _buildBackend(engine);
          // sourceOpen timeout (study §1.3): a backend whose open()
          // never returns must not stall the ladder. TimeoutException
          // is caught below and the candidate is disposed.
          //
          // 10 s for both live and VOD (2026-11-17: VOD was 18 s —
          // a dead m3u8 burned 18 s per engine before the ladder
          // moved on, so "播放影片太慢". A healthy stream opens in
          // seconds; 10 s is still 5x headroom). The first-frame
          // wait stays 18 s per Pure Live's sourceReadyTimeout.
          const openTimeout = Duration(seconds: 10);
          await candidate
              .open(
                url: url,
                headers: headers,
                isLive: isLive,
                declaredFormat: declaredFormat,
              )
              .timeout(openTimeout);
          if (_disposed || generation != _openGeneration) {
            // Exit landed while this attempt was still opening, or a
            // newer open superseded it: drop the candidate before it
            // can start playing with no owner / for the old open.
            await candidate.dispose();
            return false;
          }
          // First-frame wait is 18 s per engine (Pure Live
          // sourceReadyTimeout): a tighter window condemns healthy
          // players still probing (multi-variant HLS masters, slow
          // Douyu/Huya opens) — the "一直加载中" the 8 s wait caused.
          final ok = await candidate.waitForFirstFrame(
            timeout: const Duration(seconds: 18),
          );
          if (generation != _openGeneration) {
            await candidate.dispose();
            return false;
          }
          if (!ok) {
            await candidate.dispose();
            // Tell the page the ladder is moving to the next kernel
            // instead of leaving it on a bare spinner.
            _emitStatus(PlaybackStatus.buffering);
            return false;
          }
          if (_disposed) {
            // Exit landed during the first-frame wait: the candidate
            // may already be playing audio — dispose it instead of
            // swapping it into a dead session.
            await candidate.dispose();
            return false;
          }
          // Staged swap: only now does the new backend replace the old.
          await _swapBackend(candidate);
          unawaited(LiveBreadcrumb.write('live-first-frame'));
          return true;
        } catch (_) {
          if (candidate != null && candidate != _backend) {
            await candidate.dispose();
          }
          if (generation != _openGeneration) return false;
          _emitStatus(PlaybackStatus.buffering);
          return false;
        }
      },
    );

    final ladderFuture = ladder.run();
    final won = openBudget == null
        ? await ladderFuture
        : await ladderFuture.timeout(openBudget, onTimeout: () {
            // Retire this open's ladder at once: an attempt still
            // in flight must see the bumped generation at its next
            // checkpoint and abort before swapping its backend in.
            _openGeneration++;
            return null;
          });
    if (_disposed) return false;
    if (generation != _openGeneration) return false;
    if (won != null) {
      // Settings follows the engine actually playing; the winning
      // URL is what an engine switch re-opens (L-P1-3).
      _preferred = won.engine;
      _currentUrl = won.url;
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
          urls: fresh,
          isLive: isLive,
          declaredFormat: declaredFormat,
          headers: headers,
          refreshUrls: refreshUrls,
          freshRounds: freshRounds - 1,
          excludeIjk: _excludeIjk,
          openBudget: openBudget,
        );
      }
    }
    _emitStatus(PlaybackStatus.error);
    _emitError('播放失败，请检查网络后重试');
    return false;
  }

  Future<void> _swapBackend(PlayerBackend next) async {
    if (_disposed) {
      // Never install a backend into a disposed session — it would
      // play with no owner and nothing left to stop it.
      await next.dispose();
      return;
    }
    final old = _backend;
    _backend = next;
    // A ladder swap must not reset a background audio-only mode:
    // the new backend would re-enable its video track and the
    // suspended vo could pause the stream again. Applied before the
    // attach so the backend is audio-only from the moment it is
    // installed (best-effort, like the rate re-apply below).
    if (_audioOnly) {
      try {
        await next.setAudioOnly(true);
      } catch (_) {}
    }
    // Same for dialogue boost: a swap must not silently reset it.
    // Best-effort — a backend without the capability no-ops.
    if (_dialogueBoost && next is DialogueBoostCapableBackend) {
      unawaited(next.setDialogueBoost(true).catchError((_) {}));
    }
    // Same for the VOD picture-enhancement trio (b30): a swap must
    // not silently reset it. The gates mirror MpvBackend.open()
    // (VOD + MPV + first-branch-wins); a backend without the
    // capability keeps the values remembered for the next swap.
    unawaited(_applyVodEnhancementToBackend(next).catchError((_) {}));
    _attachBackend(next);
    // A ladder swap must not reset a user-chosen speed (episode
    // auto-advance opens a fresh backend per episode).
    if (_rate != 1.0) {
      unawaited(next.setRate(_rate).catchError((_) {}));
    }
    // Same for the volume (b30): a swap must not silently reset the
    // live volume boost / multiview focus mute — the fresh backend
    // defaults to 1.0. Null = never set (VOD never calls setVolume).
    if (_volume != null) {
      unawaited(next.setVolume(_volume!).catchError((_) {}));
    }
    // Same for the track choice: a swap must not silently reset the
    // audio/subtitle track the user picked. Best-effort — a backend
    // without the capability no-ops, and a track id from another
    // engine is ignored by its backend.
    if (_audioTrackId != null && next is TrackCapableBackend) {
      unawaited(next.setAudioTrack(_audioTrackId!).catchError((_) {}));
    }
    if (_subtitleTrackId != null && next is TrackCapableBackend) {
      unawaited(
        next.setSubtitleTrack(_subtitleTrackId!).catchError((_) {}),
      );
    }
    // Same for the subtitle offset + appearance + dual-subtitle
    // choice: a swap must not silently reset them. Track first,
    // then delay (the offset is applied to the track that is
    // actually selected).
    if (_subtitleDelay != 0.0 && next is TrackCapableBackend) {
      unawaited(next.setSubtitleDelay(_subtitleDelay).catchError((_) {}));
    }
    if (_subtitleAppearance != null && next is TrackCapableBackend) {
      final a = _subtitleAppearance!;
      unawaited(
        next
            .setSubtitleAppearance(
              fontSize: a.fontSize,
              color: a.color,
              position: a.position,
            )
            .catchError((_) {}),
      );
    }
    if (_secondarySubtitleTrackId != null &&
        next is TrackCapableBackend) {
      unawaited(
        next
            .setSecondarySubtitleTrack(_secondarySubtitleTrackId!)
            .catchError((_) {}),
      );
    }
    // Dispose the old backend only after the new one is attached and
    // verified (fix 1: never release while a callback may still hold it).
    await old?.dispose();
  }

  /// Audio/subtitle tracks of the current source, as enumerated by
  /// the active backend. Only [TrackCapableBackend]s (MPV) answer;
  /// IJK / AVPlayer surface empty lists and the picker UI shows "no
  /// tracks" instead of a broken list. Never throws.
  Future<List<PlaybackTrack>> audioTracks() async {
    final backend = _backend;
    if (backend is! TrackCapableBackend) return const [];
    try {
      return await backend.audioTracks();
    } catch (_) {
      return const [];
    }
  }

  Future<List<PlaybackTrack>> subtitleTracks() async {
    final backend = _backend;
    if (backend is! TrackCapableBackend) return const [];
    try {
      return await backend.subtitleTracks();
    } catch (_) {
      return const [];
    }
  }

  /// Select an audio track by id ('auto' = backend default).
  /// Remembered and re-applied after a ladder backend swap; on a
  /// backend without the capability the choice is remembered but
  /// does nothing until a capable backend is swapped in.
  Future<void> setAudioTrack(String id) async {
    _audioTrackId = id;
    final backend = _backend;
    if (backend is! TrackCapableBackend) return;
    try {
      await backend.setAudioTrack(id);
    } catch (_) {}
  }

  /// Select a subtitle track by id ('auto' = backend default,
  /// 'no' = off). Same remembering rule as [setAudioTrack].
  Future<void> setSubtitleTrack(String id) async {
    _subtitleTrackId = id;
    final backend = _backend;
    if (backend is! TrackCapableBackend) return;
    try {
      await backend.setSubtitleTrack(id);
    } catch (_) {}
  }

  /// Set the subtitle time offset, seconds (1.1.6, MPV `sub-delay`).
  /// Clamped to ±10 s, remembered and re-applied after a ladder
  /// backend swap; on a backend without the capability the value is
  /// remembered but does nothing until a capable backend is swapped
  /// in. Applies immediately — no reopen needed.
  Future<void> setSubtitleDelay(double seconds) async {
    _subtitleDelay = clampSubtitleDelay(seconds);
    final backend = _backend;
    if (backend is! TrackCapableBackend) return;
    try {
      await backend.setSubtitleDelay(_subtitleDelay);
    } catch (_) {}
  }

  /// Set the subtitle appearance (1.1.6, MPV `sub-font-size` /
  /// `sub-color` / `sub-pos`). Same remembering rule as
  /// [setSubtitleDelay]: remembered and re-applied after a ladder
  /// backend swap. Applies immediately — no reopen needed.
  Future<void> setSubtitleAppearance({
    required int fontSize,
    required String color,
    required double position,
  }) async {
    _subtitleAppearance =
        (fontSize: fontSize, color: color, position: position);
    final backend = _backend;
    if (backend is! TrackCapableBackend) return;
    try {
      await backend.setSubtitleAppearance(
        fontSize: fontSize,
        color: color,
        position: position,
      );
    } catch (_) {}
  }

  /// Select the second subtitle track for dual subtitles (MPV
  /// `secondary-sid`; 'no' = off). Same remembering rule as
  /// [setSubtitleTrack] — with one normalization (b30): 'no' is
  /// remembered as null, not as the literal string 'no'. The page
  /// reads `currentSecondarySubtitleTrackId != null` for the 双字幕
  /// on/off label, and a remembered 'no' showed 开 after the user
  /// picked 无 — the switch looked like a摆设 that never turns off.
  /// The backend still receives 'no' (mpv's off switch); a swap
  /// re-applies only a real track id, and off needs no re-apply —
  /// a fresh backend defaults to off.
  Future<void> setSecondarySubtitleTrack(String id) async {
    _secondarySubtitleTrackId = id == 'no' ? null : id;
    final backend = _backend;
    if (backend is! TrackCapableBackend) return;
    try {
      await backend.setSecondarySubtitleTrack(id);
    } catch (_) {}
  }

  void _attachBackend(PlayerBackend backend) {
    unawaited(_positionSub?.cancel());
    unawaited(_durationSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_completedSub?.cancel());
    unawaited(_subtitleSub?.cancel());
    // Forward text subtitle lines to the page-level overlay. The
    // subscription is re-attached on every backend swap, so the
    // overlay never stays subscribed to a disposed backend's stream.
    if (backend is TrackCapableBackend) {
      _subtitleSub = backend.subtitleStream.listen((lines) {
        if (!_subtitleController.isClosed) {
          _subtitleController.add(lines);
        }
      });
    }
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
  /// Pure Live 5.6.5 `SessionTimings` (live_player session.dart
  /// `_armMoveWatchdog`): a live source that moved and then stands still
  /// shows the recovery attempt at stallNotice (4 s) and fails at
  /// bufferingStall (12 s). 3.x's `LiveWatchdogs.positionStallTimeout`
  /// is 15 s, but that is the detector of LAST resort, behind the frame
  /// (10 s) and buffering (12 s) watchdogs — which this session does
  /// not have (no frame/buffering signal on the backend contract), so
  /// the single position detector uses the 12 s failure point, matching
  /// 5.6.5's effective behaviour. Trade-off, recorded: a line that
  /// would have self-recovered in 12-15 s is now torn down instead;
  /// chen's stuck lines do not self-recover, so the earlier failure
  /// wins for him. The 4 s notice is UI only ("重新连接…"), not a failure.
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

  /// Set the player volume. Remembered (see [_volume]): a later
  /// backend swap re-applies it, so a live quality switch never
  /// silently drops the volume boost (b30 — the room's playing-event
  /// re-apply was defeated by its own same-engine dedup guard, and
  /// the session is the layer that owns the swap).
  Future<void> setVolume(double volume) async {
    _volume = volume;
    try {
      await _backend?.setVolume(volume);
    } catch (_) {}
  }

  double get rate => _rate;

  /// Dialogue boost (I-影视 item 3, VOD only): remembered and
  /// re-applied after a ladder backend swap, like [_rate]. Only a
  /// [DialogueBoostCapableBackend] (mpv, K 组 build 29) hears it —
  /// other backends no-op, and the choice is still remembered so
  /// a later capable swap picks it up. The caller (VOD page only)
  /// guards with shouldApplyDialogueBoost; live never calls this.
  Future<void> setDialogueBoost(bool enabled) async {
    _dialogueBoost = enabled;
    final backend = _backend;
    if (backend is! DialogueBoostCapableBackend) return;
    try {
      await backend.setDialogueBoost(enabled);
    } catch (_) {}
  }

  /// VOD picture-enhancement trio (b30): apply the FULL trio state
  /// to the running backend at once — the current episode changes
  /// immediately, no reopen, no rebuffer. The caller (VOD page)
  /// passes the whole state (it owns the mutual exclusion in
  /// display); the state is normalised here through
  /// [resolveVodEnhancement] (first-branch-wins, same order as
  /// MpvBackend.open()) and only what CHANGED is sent to the
  /// backend. Remembered and re-applied after a ladder backend
  /// swap (see [_applyVodEnhancementToBackend]); on a backend
  /// without the capability the values are remembered but do
  /// nothing until a capable backend is swapped in (open() already
  /// applied them from Hive for the current backend).
  Future<void> setVodEnhancement({
    required bool superResolution,
    required bool interpolation,
    required bool sdrToHdr,
  }) async {
    final branch = resolveVodEnhancement(
      superResolution: superResolution,
      interpolation: interpolation,
      sdrToHdr: sdrToHdr,
    );
    final effSuper = branch == VodEnhancementBranch.superResolution;
    final effInterp = branch == VodEnhancementBranch.interpolation;
    final effSdr = branch == VodEnhancementBranch.sdrToHdr;
    final prevSuper = _superResolution;
    final prevInterp = _interpolation;
    final prevSdr = _sdrToHdr;
    _superResolution = effSuper;
    _interpolation = effInterp;
    _sdrToHdr = effSdr;
    final backend = _backend;
    if (backend is! VodEnhancementCapableBackend) return;
    try {
      if (effSuper != prevSuper) {
        await backend.setSuperResolution(effSuper);
      }
      if (effInterp != prevInterp) {
        await backend.setFrameInterpolation(effInterp);
      }
      if (effSdr != prevSdr) {
        await backend.setSdrToHdr(effSdr);
      }
    } catch (_) {}
  }

  /// Re-apply the remembered trio to a freshly swapped-in backend
  /// (ladder swap / engine switch). The gates mirror
  /// MpvBackend.open() exactly (VOD + MPV + first-branch-wins) so a
  /// swap never applies a branch open() would not have, and live
  /// never gets any of it. Best-effort — a rejected write never
  /// breaks playback.
  Future<void> _applyVodEnhancementToBackend(
    PlayerBackend backend,
  ) async {
    if (backend is! VodEnhancementCapableBackend) return;
    try {
      if (shouldApplySuperResolution(
        isLive: _isLive,
        engine: backend.engine,
        switchOn: _superResolution,
      )) {
        await backend.setSuperResolution(true);
        return;
      }
      if (shouldApplyFrameInterpolation(
        isLive: _isLive,
        engine: backend.engine,
        switchOn: _interpolation,
        superResolutionOn: _superResolution,
        sdrToHdrOn: _sdrToHdr,
      )) {
        await backend.setFrameInterpolation(true);
        return;
      }
      if (shouldApplySdrToHdr(
        isLive: _isLive,
        engine: backend.engine,
        switchOn: _sdrToHdr,
        superResolutionOn: _superResolution,
        interpolationOn: _interpolation,
      )) {
        await backend.setSdrToHdr(true);
      }
    } catch (_) {}
  }

  /// Re-open the current stream in place (b30): the mechanism for
  /// settings that only take effect at open() — DV P8 routing and
  /// low-memory mode. Re-opens the CURRENT url with the stored
  /// params, so candidatesFor (DV gate) and mpvBaseProperties
  /// (low-memory mode) re-read the fresh Hive values, then seeks
  /// back to the last known position — the current episode keeps
  /// playing from where it was, with the new setting applied.
  /// VOD only (live has no position to keep and no caller needs
  /// it). Returns false when nothing is playing.
  Future<bool> reopenCurrent() async {
    if (_disposed || _isLive || _currentUrl == null) return false;
    final resume = _lastPosition;
    final ok = await open(
      url: _currentUrl!,
      isLive: false,
      declaredFormat: _declaredFormat,
      headers: _headers,
      excludeIjk: _excludeIjk,
    );
    if (ok && resume > Duration.zero) {
      await seekTo(resume);
    }
    return ok;
  }

  /// Whether the ACTIVE backend can enter system Picture-in-Picture
  /// right now (AVPlayer only — MPV/IJK have no AVFoundation
  /// playback underneath). The VOD 更多 menu shows its PiP entry
  /// only when this is true, so there is never a dead PiP button.
  /// Re-read on every use: the ladder can swap the backend
  /// mid-playback, so a cached value would go stale.
  bool get supportsPictureInPicture =>
      _backend is PictureInPictureCapableBackend;

  /// Enter system Picture-in-Picture on the active backend (K 组,
  /// build 29). True only when the backend implements
  /// [PictureInPictureCapableBackend] (AVPlayer) and PiP started;
  /// MPV/IJK return false — no AVFoundation playback underneath,
  /// so no Dart-side change can wire them. VOD + live both use
  /// this entry point; the caller (live tools sheet / VOD 更多
  /// menu) decides when to offer it.
  Future<bool> enterPictureInPicture() async {
    final backend = _backend;
    if (backend is! PictureInPictureCapableBackend) return false;
    try {
      return await backend.enterPictureInPicture();
    } catch (_) {
      return false;
    }
  }

  /// Audio-only mode for live background playback (Pure Live
  /// `setAudioOnly`): the video track is disabled so a suspended
  /// video output cannot pause the stream in background; the audio
  /// keeps playing. The flag is remembered and re-applied after a
  /// ladder backend swap. A backend that does not implement it
  /// (IJK / AVPlayer) no-ops — the room's foreground handler still
  /// resumes playback if it paused natively anyway.
  Future<void> setAudioOnly(bool audioOnly) async {
    _audioOnly = audioOnly;
    try {
      await _backend?.setAudioOnly(audioOnly);
    } catch (_) {}
    _applyWakelock();
  }

  /// Playback speed (VOD only). Stored so a ladder backend swap
  /// re-applies it; live never sets it.
  Future<void> setRate(double rate) async {
    _rate = rate;
    try {
      await _backend?.setRate(rate);
    } catch (_) {}
  }

  /// Idempotent dispose (fix 1): cancel callbacks first, then release.
  ///
  /// The backend-subscription cancels are fire-and-forget, NOT
  /// awaited: a broadcast StreamSubscription.cancel() future can
  /// stall — under fake async (widget tests) it never completes at
  /// all, so awaiting it wedged dispose() before the backend was
  /// released and the film kept its backend alive after exit. The
  /// backend release must never wait on stream teardown; the
  /// cancels still run, they just don't gate the release.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _applyWakelock();
    _stallTimer?.cancel();
    unawaited(_positionSub?.cancel());
    unawaited(_durationSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_completedSub?.cancel());
    unawaited(_subtitleSub?.cancel());
    await _disposePreopened();
    await _backend?.dispose();
    _backend = null;
    await _statusController.close();
    await _errorController.close();
    await _stallNoticeController.close();
    await _positionController.close();
    await _durationController.close();
    await _subtitleController.close();
    await _ladderAttemptController.close();
    unawaited(LiveBreadcrumb.write('live-closed'));
  }
}
