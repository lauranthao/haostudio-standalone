// Native landscape VOD player page (fix 4 + VOD rules).
//
// VOD tap-play goes DIRECTLY to landscape fullscreen (whole-app
// rotation, tab bar and content included) — the opposite of live,
// which stays portrait until the [ ] button. There is NO quality
// selector on VOD ever (one play URL per episode, no quality tiers —
// live only, hard rule). Episode auto-plays the next episode on end
// - Episode auto-plays the next episode on end (same line) when the
//   `vodAutoNext` toggle is ON (default ON, persisted in Hive —
//   `VideoPlaybackSettings.autoNext`; toggle in the player top bar and
//   in Settings → 播放与缓存). Toggle OFF or the last episode -> the
//   end state, never a loop. Advancing clears the resume position:
//   the new episode always starts at 0.
//
// The player is native (PlaybackSession → MPV/IJK/AVPlayer ladder),
// never a web <video>. No inline web playback path exists in-app.
//
// Duration + seek come from the backend contract (PlaybackSession
// durationStream / seekTo): the control bar shows a thin 4 px progress
// line with elapsed left / remaining right, scrubbing seeks, and a
// resumed episode seeks to its saved position once after open.

import '../../core/theme/hao_radius.dart';
import 'dart:async';

import 'package:flame_barrage/flame_barrage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import '../../widgets/hao_pressable.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../../core/danmaku/danmaku_occlusion.dart';
import '../../core/danmaku/danmaku_occlusion_mask.dart';
import '../../core/native/person_segmentation.dart';
import '../../core/player/kernel/player_backend.dart';
import '../../core/player/kernel/video_fit.dart';
import '../../core/player/vod_controls.dart';
import '../../core/storage/hive_store.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/hao_settle_spring.dart';
import '../../core/theme/glass.dart';
import '../../core/theme/haptics.dart';
import '../../services/video/emby_client.dart';
import '../../services/video/emby_models.dart';
import '../../domains/live/presentation/playback/danmaku_filter.dart';
import '../../services/video/vod_danmaku_client.dart';
import '../music/music_player_controller.dart';
import '../player/fullscreen_controller.dart';
import '../player/playback_session.dart';
import '../player/screen_brightness.dart';
import '../player/system_drag_controller.dart';
import '../settings/source_stores.dart';
import 'cms_sources.dart';
import 'video_detail_service.dart';
import 'video_history_store.dart';
import 'video_models.dart';
import 'video_title_helpers.dart';

/// Next episode index when the current episode ends, or null when
/// playback must stop at the end state (V-P0-2, pure — unit-tested):
/// - autoNext OFF -> stop (previous behaviour, no advance);
/// - last episode -> stop (end state, never loops);
/// - otherwise -> the next episode in the same line.
int? autoNextEpisodeIndex({
  required int current,
  required int total,
  required bool autoNext,
}) {
  if (!autoNext) return null;
  final next = current + 1;
  return next < total ? next : null;
}

/// Resolve the line/episode to play on a switch-target detail
/// (P1-17, pure — unit-tested):
/// - Same episode by NAME first, searched across ALL of the target's
///   lines (the target may put the episode on its 2nd/3rd line while
///   the current source has it on the 1st) — `matchedByName` true.
/// - No same-name episode: keep the CURRENT line number (clamped to
///   the target's line count) and clamp the episode index into that
///   line — never "always line 1". `matchedByName` false, and the
///   caller must NOT resume a saved position into the clamped
///   episode: the clamp is a best-effort neighbour, not the same
///   episode (P1-15 rule: only the same episode resumes).
/// - No episodes anywhere: (0, 0, false); the caller skips the target.
({int lineIdx, int epIdx, bool matchedByName}) resolveSwitchTarget({
  required List<PlayLine> lines,
  required String epName,
  required int lineIdx,
  required int epIdx,
}) {
  if (lines.isEmpty) return (lineIdx: 0, epIdx: 0, matchedByName: false);
  for (var li = 0; li < lines.length; li++) {
    final eps = lines[li].episodes;
    for (var ei = 0; ei < eps.length; ei++) {
      if (eps[ei].name == epName) {
        return (lineIdx: li, epIdx: ei, matchedByName: true);
      }
    }
  }
  final li = lineIdx.clamp(0, lines.length - 1);
  var eps = lines[li].episodes;
  var targetLine = li;
  if (eps.isEmpty) {
    // The corresponding line is empty: first non-empty line wins.
    var found = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].episodes.isNotEmpty) {
        found = i;
        break;
      }
    }
    if (found < 0) return (lineIdx: 0, epIdx: 0, matchedByName: false);
    targetLine = found;
    eps = lines[found].episodes;
  }
  return (
    lineIdx: targetLine,
    epIdx: epIdx.clamp(0, eps.length - 1),
    matchedByName: false,
  );
}

/// Opens [detail] at [initialLineIndex]/[initialEpisodeIndex] in
/// landscape fullscreen. [onClose] reports the last line/episode/
/// position so the detail page can refresh its resume state.
/// [initialPosition] (seconds) seeks once after open when > 10 s — the
/// detail page passes the saved resume position for the resumed episode.
/// [session] is a test seam only: production always passes null and the
/// page owns a fresh [PlaybackSession].
/// [detailService] is a test seam only: production passes the detail
/// page's service (shared cache); null owns a fresh one. It drives the
/// play-time source switch (same title, next fastest source).
class NativeVideoPlayerPage extends StatefulWidget {
  const NativeVideoPlayerPage({
    super.key,
    required this.detail,
    this.initialLineIndex = 0,
    this.initialEpisodeIndex = 0,
    this.initialPosition = 0,
    this.onClose,
    this.session,
    this.detailService,
    this.danmakuClient,
  });

  final VideoDetail detail;
  final int initialLineIndex;
  final int initialEpisodeIndex;
  final double initialPosition;

  /// (lineIdx, epIdx, positionSeconds)
  final void Function(int lineIdx, int epIdx, double position)? onClose;

  /// Test seam: an injected [PlaybackSession] (fake backends in
  /// tests). Null in production.
  final PlaybackSession? session;

  /// Test seam: an injected [VideoDetailService]. Null in production.
  final VideoDetailService? detailService;

  /// Test seam: an injected [VodDanmakuClient]. Null in production
  /// (the page owns a default client hitting danmu-api).
  final VodDanmakuClient? danmakuClient;

  @override
  State<NativeVideoPlayerPage> createState() => _NativeVideoPlayerPageState();
}

class _NativeVideoPlayerPageState extends State<NativeVideoPlayerPage>
    with WidgetsBindingObserver {
  late final PlaybackSession _session;
  late final FullscreenController _fullscreen;
  late final VideoDetailService _detailService;

  /// Mutable: a play-time source switch replaces the detail with the
  /// winning source's detail (same title, same episode), so history,
  /// resume and play headers follow the source that actually plays.
  late VideoDetail _detail;

  late int _lineIdx;
  late int _epIdx;
  late bool _autoNext;
  late VideoFitMode _videoFit;
  double _position = 0;
  double _duration = 0;
  double _resumePosition = 0;
  bool _resumeSought = false;
  bool _scrubbing = false;
  double _scrubValue = 0;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  bool _loading = true;
  bool _failed = false;
  String _loadingHint = '正在加载…';
  bool _ended = false;
  bool _showControls = true;
  bool _playing = false;
  double _rate = 1.0;
  // Long-press 2x (Bilibili-style): temporary override only — the user's
  // persisted _rate is never touched, so release always restores it.
  bool _longPressSpeeding = false;
  // Skip intro/outro (1.1.6, VOD only): mode read once at open (the
  // settings page is never open during playback); per-episode state
  // resets when the position listener sees a new (line, episode).
  // The window resolves per episode: Emby Chapters markers first,
  // else the per-episode custom CMS seconds. The listener is the
  // ONLY reset point — _openCurrent/_onEpisodeEnded/_switchLine
  // belong to the source-chain group and are never edited here.
  VodSkipIntroMode _skipMode = VodSkipIntroMode.off;
  int _skipEpLine = -1;
  int _skipEpIdx = -1;
  ({double start, double end})? _skipIntroWindow;
  bool _skipIntroAutoDone = false;
  bool _skipCreditsDone = false;
  bool _skipShowIntro = false;
  bool _skipShowCredits = false;
  Timer? _skipCountdown;
  int _skipCountdownLeft = 0;
  // Vertical drag brightness/volume (P1-U2): shared
  // [SystemDragController] with the live room — same seed, HUD and
  // sensitivity (300 px = full range). The drag drives the DEVICE
  // volume, not the player gain. HUD linger 800 ms (VOD value).
  final SystemDragController _drag = SystemDragController();
  bool _closing = false;
  // VOD danmaku (build 28): Flame timeline over the video, opt-in,
  // default OFF. Master gate = DanmakuSettings 'vod' key;
  // _danmakuVisible is the per-episode display toggle (initial value
  // = gate value, sticky across episodes on this page). The engine
  // clock is internal, so pause / rate / seek are all mirrored
  // explicitly below — never assumed to follow the video.
  final BarrageController _barrageController = BarrageController();
  // Danmaku occlusion avoidance (1.1.6, reduced version): Vision
  // person mask over low-frequency MPV snapshots, whole-layer
  // ShaderMask on the danmaku layer. MPV-only, default off, one
  // switch for VOD + live. Owns the take-frame -> segment -> mask
  // loop; the page only drives its gates (update) and drops the
  // mask on episode/source switches (invalidateMask).
  late final DanmakuOcclusionController _occlusion;
  late final VodDanmakuClient _danmakuClient;
  bool _danmakuEnabled = false;
  bool _danmakuVisible = false;
  double _danmakuFontSize = DanmakuSettings.defaultFontSize;
  double _danmakuOpacity = DanmakuSettings.defaultOpacity;
  double _danmakuArea = DanmakuSettings.defaultAreaFraction;
  ValueListenable<Box<dynamic>>? _danmakuSettingsListenable;
  List<VodDanmakuCandidate>? _danmakuCandidates;
  int _danmakuCandidateIndex = 0;
  List<VodDanmakuComment>? _danmakuComments;
  List<BarrageItem>? _danmakuItems;
  bool _danmakuLoaded = false;
  // Seek drag (horizontal swipe): preview the target, seek once on
  // release — never a seek per update (Pure Live: rapid seeks complete
  // with cancel errors when superseded).
  double? _dragSeekTarget;
  double _dragSeekStart = 0;
  double _dragSeekDelta = 0;
  Timer? _hideTimer;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlaybackStatus>? _statusSub;
  StreamSubscription<String>? _errorSub;
  var _openEpoch = 0;

  PlayEpisode get _episode => _detail.lines[_lineIdx].episodes[_epIdx];

  String get _title => _detail.meta.name;

  String get _epLabel {
    final line = _detail.lines[_lineIdx];
    final prefix = _detail.lines.length > 1 ? '${line.name} · ' : '';
    return '$prefix${_episode.name}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _detail = widget.detail;
    _detailService = widget.detailService ?? VideoDetailService();
    _lineIdx = widget.initialLineIndex.clamp(0, _detail.lines.length - 1);
    final eps = _detail.lines[_lineIdx].episodes;
    _epIdx = widget.initialEpisodeIndex.clamp(0, eps.length - 1);
    _autoNext = VideoPlaybackSettings.autoNext;
    _videoFit = VideoPlaybackSettings.videoFit;
    _session = widget.session ?? PlaybackSession();
    _occlusion = DanmakuOcclusionController(
      segmentation: PersonSegmentation(),
      frameSource: () async =>
          _session.frameCapableBackend?.captureFrameJpeg(),
      isFrameCapable: () => _session.frameCapableBackend != null,
    );
    _fullscreen = Get.put(FullscreenController());
    _rate = VideoPlaybackSettings.playbackRate;
    unawaited(_session.setRate(_rate));
    _skipMode = vodSkipIntroMode();
    // Subtitle offset + appearance (1.1.6): persisted delay and
    // appearance tiers, MPV only. The session remembers them and
    // re-applies them on every backend swap, so applying once here
    // covers episode / line / kernel switches.
    unawaited(_session.setSubtitleDelay(vodSubtitleDelaySeconds()));
    unawaited(
      _session.setSubtitleAppearance(
        fontSize: vodSubtitleFontSize(),
        color: vodSubtitleColor(),
        position: vodSubtitlePosition(),
      ),
    );
    _danmakuClient = widget.danmakuClient ?? VodDanmakuClient();
    _readDanmakuSettings();
    _danmakuVisible = _danmakuEnabled;
    _subscribeDanmakuSettings();
    // Vertical drag brightness/volume: the shared controller owns the
    // volume stream + per-side caches (P1-U2).
    _drag.init();
    _statusSub = _session.onStatus.listen((status) {
      if (!mounted) return;
      if (status == PlaybackStatus.completed) {
        _onEpisodeEnded();
      } else if (status == PlaybackStatus.playing) {
        setState(() {
          _loading = false;
          _playing = true;
        });
        // The barrage engine runs its own clock: freeze it with the
        // video or the overlay drifts ahead while paused.
        _barrageController.resume();
      } else if (status == PlaybackStatus.paused) {
        setState(() => _playing = false);
        _barrageController.pause();
      } else if (status == PlaybackStatus.buffering && _loading) {
        // An engine attempt just failed its first frame and the
        // ladder is trying the next kernel — say so instead of
        // leaving the user staring at a bare spinner.
        setState(() => _loadingHint = '正在切换播放内核…');
      } else if (status == PlaybackStatus.error) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    });
    _errorSub = _session.onError.listen((_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    });
    _positionSub = _session.positionStream.listen((pos) {
      _position = pos.inMilliseconds / 1000.0;
      _checkSkipPoints();
      if (mounted) setState(() {});
      final now = DateTime.now();
      if (now.difference(_lastSave) > const Duration(seconds: 10)) {
        _lastSave = now;
        unawaited(_saveProgress());
      }
    });
    _durationSub = _session.durationStream.listen((dur) {
      final seconds = dur.inMilliseconds / 1000.0;
      if (seconds > 0 && seconds != _duration) {
        _duration = seconds;
        if (mounted) setState(() {});
      }
    });
    _resumePosition = widget.initialPosition;
    unawaited(_fullscreen.enterFullscreen());
    unawaited(_openCurrent());
    _armHideTimer();
  }

  String _declaredFormat(String url) {
    final lower = url.toLowerCase().split('?').first;
    if (lower.endsWith('.m3u8')) return 'hls';
    if (lower.endsWith('.flv')) return 'flv';
    if (lower.endsWith('.mp4') || lower.endsWith('.mov')) return 'mp4';
    return '';
  }

  /// Headers for the VOD stream request: many CMS CDNs 403 without a
  /// Referer, and several upstreams key behaviour off the UA.
  /// Referer is the origin of the CMS source this video came from.
  Map<String, String> _playHeaders() {
    final headers = <String, String>{'User-Agent': kDirectVideoUa};
    final sourceId = _detail.source.toString();
    for (final s in VideoSourcesStore.getAll()) {
      if (s.idKey == sourceId && s.apiUrl.isNotEmpty) {
        final origin = Uri.tryParse(toHttps(s.apiUrl))?.origin;
        if (origin != null && origin.isNotEmpty) {
          headers['Referer'] = origin;
        }
        break;
      }
    }
    return headers;
  }

  /// Open the current episode's URL through the kernel ladder.
  /// One open is capped at 30 s total (V-P1-2): three engines ×
  /// (10 s open + 18 s first frame) is ~84 s worst case, and a
  /// source switch then re-tries up to 3 more sources — minutes of
  /// spinner before the failure card. The 10 s / 18 s per-attempt
  /// budgets are untouched; the session-level budget just cuts the
  /// whole attempt short so the next line/source can be tried.
  Future<bool> _openEpisodeUrl() async {
    final url = _episode.url;
    return _session.open(
      url: url,
      isLive: false,
      declaredFormat: _declaredFormat(url),
      headers: _playHeaders(),
      openBudget: const Duration(seconds: 30),
    );
  }

  /// Same-episode, other-line fallback (V-P1-1): the current
  /// episode's URL is dead — try the SAME episode on the other lines
  /// of THIS detail first (local data, zero network requests) before
  /// any cross-source sweep. Returns true when one plays. The
  /// episode name match reuses [resolveSwitchTarget]'s rule: same
  /// name = same episode, so the saved position follows it.
  Future<bool> _tryOtherLines() async {
    final epName = _episode.name;
    final fromLine = _lineIdx;
    final fromEp = _epIdx;
    final savedPosition = _resumePosition;
    for (var li = 0; li < _detail.lines.length; li++) {
      if (li == fromLine) continue;
      final eps = _detail.lines[li].episodes;
      final ei = eps.indexWhere((e) => e.name == epName);
      if (ei < 0) continue;
      if (!mounted) return false;
      setState(() {
        _lineIdx = li;
        _epIdx = ei;
        _resumeSought = false;
        _resumePosition = savedPosition;
      });
      if (await _openEpisodeUrl()) return true;
    }
    // Nothing on the other lines played: restore the original
    // line/episode so the cross-source switch starts from the same
    // episode it was asked for, not the last dead line tried.
    if (mounted) {
      setState(() {
        _lineIdx = fromLine;
        _epIdx = fromEp;
        _resumePosition = savedPosition;
      });
    }
    return false;
  }

  /// Play-time source switch (chen 2026-11-17: 换源播放，直到找到能播
  /// 的为止): the current episode's URL failed to open — find the
  /// same title on the next fastest source and play the same episode
  /// there. Tries up to 3 alts (5 s per detail fetch); returns true
  /// when a switched episode is playing. On success [_detail]/
  /// [_lineIdx]/[_epIdx] point at the new source, so history, resume
  /// and play headers follow the source that actually plays.
  Future<bool> _trySwitchSource() async {
    final meta = _detail.meta;
    if (meta.name.isEmpty) return false;
    // Capture before the loop: a failed switch attempt already
    // replaced _detail, so later matches must still use the ORIGINAL
    // episode name/index/line.
    final epName = _episode.name;
    final epIndex = _epIdx;
    final lineIndex = _lineIdx;
    var attempts = 0;
    try {
      await for (final alt in _detailService.findAlts(
        meta.name,
        meta.year,
        _detail.source,
      )) {
        if (attempts >= 3) break;
        attempts++;
        VideoDetail altDetail;
        try {
          altDetail = await _detailService
              .get(alt.source, alt.vodId)
              .timeout(const Duration(seconds: 5));
        } catch (_) {
          continue;
        }
        if (!altDetail.usable) continue;
        if (!altDetail.lines.any((l) => l.episodes.isNotEmpty)) continue;
        // P1-17: same episode by name across ALL lines first; else
        // keep the current line number and clamp the episode index
        // into that line — never forced to the target's line 1.
        final target = resolveSwitchTarget(
          lines: altDetail.lines,
          epName: epName,
          lineIdx: lineIndex,
          epIdx: epIndex,
        );
        if (!mounted) return false;
        setState(() {
          _detail = altDetail;
          _lineIdx = target.lineIdx;
          _epIdx = target.epIdx;
          _resumeSought = false;
        });
        if (await _openEpisodeUrl()) {
          // P1-15: only the SAME episode resumes. A name-matched
          // switch keeps the saved position (the resume seek in
          // _openCurrent runs after this returns); a clamped switch
          // landed on a neighbour episode, so the old position must
          // not follow it there.
          if (!target.matchedByName) {
            _resumePosition = 0;
            _resumeSought = true;
          }
          if (mounted) {
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(const SnackBar(content: Text('已切换片源，继续播放')));
          }
          return true;
        }
        // Switched URL also dead — keep looking at the next source.
      }
    } catch (_) {}
    return false;
  }

  /// Open the current episode. Returns true once it is playing.
  ///
  /// [seamless]: the line-switch path (1.1.6, called only after a
  /// successful [PlaybackSession.preopen]). The old line keeps
  /// playing until the preopened backend swaps in, so this path
  /// must NOT reset the UI: no `_position = 0`, no fullscreen
  /// spinner, no danmaku clear (the timeline is the same episode's
  /// — it is only seeked to the current position), no other-line /
  /// cross-source fallback (a failed seamless swap falls back to
  /// the OLD line, never to a third line or another source — the
  /// caller restores the old line/episode indices). A new episode
  /// (seamless: false) keeps the old reset behaviour.
  Future<bool> _openCurrent({bool seamless = false}) async {
    // Pause any playing music the moment this film starts playing
    // (chen: only when a specific film starts — browsing the video
    // tab, categories or a detail page never pauses). Guarded by
    // registration: if no music controller exists, no music can be
    // playing. No auto-resume on exit; the user resumes manually.
    // A seamless line switch is not a new film starting: skip it.
    if (!seamless && Get.isRegistered<MusicPlayerController>()) {
      unawaited(MusicPlayerController.ensure().pause());
    }
    final epoch = ++_openEpoch;
    if (seamless) {
      // Keep position/duration/loading exactly as they are — the
      // old picture stays up until the swap. Only the end/failed
      // flags are cleared (we are switching to a playing stream).
      // Danmaku: same episode, same timeline — seek it, don't clear
      // it. When the engine is not attached yet there is nothing
      // to seek; the post-first-frame load seeks to _position.
      setState(() {
        _failed = false;
        _ended = false;
      });
      if (_barrageController.engine != null) {
        _barrageController.seekTo(
          Duration(milliseconds: (_position * 1000).round()),
        );
      }
    } else {
      setState(() {
        _loading = true;
        _failed = false;
        _loadingHint = '正在加载…';
        _ended = false;
        _position = 0;
        _duration = 0;
        _resumeSought = false;
      });
      // A new episode voids the old timeline: clear the engine and
      // drop the cached candidates/comments, so no previous-episode
      // danmaku can bleed into this one.
      _barrageController.clear();
      // New episode/source: the old person mask is a stale
      // silhouette of the previous picture — drop it at once (the
      // 500 ms expiry is only the backstop).
      _occlusion.invalidateMask();
      _danmakuLoaded = false;
      _danmakuCandidates = null;
      _danmakuComments = null;
      _danmakuItems = null;
      _danmakuCandidateIndex = 0;
    }
    var ok = false;
    if (seamless) {
      // The preopened backend was verified playable before the old
      // line was touched; the swap seeks to the resume position.
      // Any failure here leaves the old backend playing.
      ok = await _session.swapToPreopened(
        url: _episode.url,
        resumePosition:
            Duration(milliseconds: (_resumePosition * 1000).round()),
      );
    } else {
      ok = await _openEpisodeUrl();
    }
    if (!ok && !seamless) {
      // Play URL dead — first the other lines of THIS detail (same
      // episode, zero network — V-P1-1), then a cross-source switch.
      if (mounted) setState(() => _loadingHint = '正在切换线路…');
      ok = await _tryOtherLines();
    }
    if (!ok && !seamless) {
      // Play URL dead — switch source and keep looking until one
      // plays (chen 2026-11-17: 换源播放，直到找到能播的为止).
      if (mounted) setState(() => _loadingHint = '正在换源播放…');
      ok = await _trySwitchSource();
    }
    if (epoch != _openEpoch || !mounted) return false;
    if (!ok) {
      // Seamless failure: the old stream is STILL playing behind
      // this call — never show the failure card for it. The caller
      // (_switchLine) restores the old line/episode and toasts.
      if (!seamless) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
      return false;
    }
    // Speed is re-applied by the session's _swapBackend after a
    // backend swap; volume needs nothing — it is the system volume
    // now, not a per-backend gain.
    // Resume seek, once per episode: open() already verified the first
    // frame, so seeking now lands on a playing stream. Only for the
    // episode the detail page launched with a saved position (> 10 s
    // per the vodLocalLoad rule); later episodes start at 0.
    // (A seamless swap already sought — _resumeSought is true there.)
    if (_resumePosition > 10 && !_resumeSought) {
      _resumeSought = true;
      await _session.seekTo(
        Duration(milliseconds: (_resumePosition * 1000).round()),
      );
    }
    await _recordHistory();
    // Emby: report playback start to the server (1.1.6, best-
    // effort — a failed report never breaks playback; local history
    // above is still the fallback). The episode id comes from the
    // stream URL for series episodes, the detail id for movies.
    if (mounted && _detail.sourceKey == EmbyClient.sourceId) {
      try {
        final config = EmbyConfigStore.load();
        if (config != null && config.isConfigured) {
          final emby = EmbyClient(config: config);
          final itemId =
              EmbyClient.episodeIdFromStreamUrl(_episode.url) ??
                  _detail.vodId;
          unawaited(
            emby.reportPlaybackStart(
              itemId,
              positionSeconds: _resumePosition > 0 ? _resumePosition : 0,
            ),
          );
        }
      } catch (_) {}
    }
    // Danmaku is strictly post-first-frame: the open above already
    // verified playback, so this never delays首播 (hop 1 alone took
    // 24.6 s cold in the audit). Fully async, silent on any failure.
    // (In seamless mode this is a no-op when the timeline is
    // already loaded for this episode.)
    if (mounted) unawaited(_maybeLoadDanmaku());
    return true;
  }

  Future<void> _recordHistory() async {
    // Never throws: history I/O must never break playback or exit.
    try {
      final m = _detail.meta;
      // 1.1.6 (browse A3 §4): next-episode info for the Aggregated
      // Continue Bar's "下一集" row — same-line next first; cross-line
      // only for Emby (its lines are seasons; CMS lines are play
      // lines, not seasons, so a CMS row never jumps lines).
      final next = historyNextEpisode(
        lines: _detail.lines,
        lineIdx: _lineIdx,
        epIdx: _epIdx,
        allowCrossLine: _detail.sourceKey == EmbyClient.sourceId,
      );
      await VideoHistoryStore.record(
        WatchHistoryEntry(
          source: _detail.source,
          vodId: _detail.vodId,
          title: m.name,
          pic: m.pic,
          picAlt: m.picAlt,
          // Year feeds the film key (P1-16): without it, a remake
          // would merge into the original's history row.
          year: m.year,
          lineIdx: _lineIdx,
          epIdx: _epIdx,
          epName: _episode.name,
          position: _position,
          duration: _duration,
          totalEpisodes: next.totalEpisodes,
          nextEpName: next.nextEpName,
          at: DateTime.now(),
        ),
      );
    } catch (_) {}
  }

  Future<void> _saveProgress() async {
    // Never throws: a storage failure must never trap the user on
    // this page (the exit path awaits this before popping).
    try {
      await VideoHistoryStore.saveResume(
        _detail.source,
        _detail.vodId,
        lineIdx: _lineIdx,
        epIdx: _epIdx,
        epName: _episode.name,
        position: _position,
        duration: _duration,
      );
      await _recordHistory();
    } catch (_) {}
  }

  /// Auto-play the next episode on end (same line only, V-P0-2).
  /// Toggle OFF or the last episode -> the end state, never a loop.
  /// Advancing clears the resume position: the new episode starts
  /// at 0, never at the previous episode's saved position. The
  /// transition stays in this player — no fake player, no detail
  /// reload.
  ///
  /// Last episode of the line (1.1.6 cross-source continuation):
  /// before settling on the end state, look for the NEXT episode
  /// number elsewhere — same detail's other lines, then other
  /// sources with the same title, then (Emby only) the next season
  /// line. STRONG match only: same normalised title (guaranteed by
  /// findAlts) + EXACT episode number. A weak/ambiguous match never
  /// auto-plays — it simply leaves the end state as it is. A found
  /// candidate never jumps silently either: with autoNext ON it
  /// gets a 5 s cancellable countdown, with autoNext OFF a "去看"
  /// action. CMS has no "next season" concept — never guessed.
  void _onEpisodeEnded() {
    if (!mounted) return;
    final eps = _detail.lines[_lineIdx].episodes;
    final next = autoNextEpisodeIndex(
      current: _epIdx,
      total: eps.length,
      autoNext: _autoNext,
    );
    if (next != null) {
      unawaited(_saveProgress());
      _resumePosition = 0;
      setState(() => _epIdx = next);
      unawaited(_openCurrent());
      return;
    }
    // End of this line: save + (Emby) end the server session and
    // mark played. Best-effort — never thrown into the end state.
    unawaited(_saveProgress());
    if (_detail.sourceKey == EmbyClient.sourceId) {
      try {
        final config = EmbyConfigStore.load();
        if (config != null && config.isConfigured) {
          final emby = EmbyClient(config: config);
          final itemId =
              EmbyClient.episodeIdFromStreamUrl(_episode.url) ??
                  _detail.vodId;
          unawaited(emby.reportPlaybackStopped(itemId));
          unawaited(emby.markPlayed(itemId));
        }
      } catch (_) {}
    }
    setState(() {
      _ended = true;
      _showControls = true;
    });
    // The continuation search is async (alt details are fetched);
    // it runs in a closure so this method keeps its void signature
    // (the status listener calls it bare).
    unawaited(() async {
      final detailAtEnd = _detail;
      final lineAtEnd = _lineIdx;
      final epAtEnd = _epIdx;
      final epNum = parseEpisodeNumber(_episode.name);
      final isEmby = detailAtEnd.sourceKey == EmbyClient.sourceId;
      ({VideoDetail detail, int lineIdx, int epIdx, String label})?
          target;
      // 1. Same detail, other lines: next episode number.
      if (epNum != null) {
        final found = findEpisodeByNumber(detailAtEnd.lines, epNum + 1);
        if (found != null && found.lineIdx != lineAtEnd) {
          target = (
            detail: detailAtEnd,
            lineIdx: found.lineIdx,
            epIdx: found.epIdx,
            label:
                '${detailAtEnd.lines[found.lineIdx].name} · 第 ${epNum + 1} 集',
          );
        }
      }
      // 2. Cross-source (CMS only): same title + exact next number.
      // findAlts already guarantees the normalised-title (+ year)
      // match; the number match here is what makes it strong.
      if (target == null && !isEmby && epNum != null) {
        var attempts = 0;
        try {
          await for (final alt in _detailService.findAlts(
            detailAtEnd.meta.name,
            detailAtEnd.meta.year,
            detailAtEnd.source,
          )) {
            if (attempts >= 3) break;
            attempts++;
            VideoDetail altDetail;
            try {
              altDetail = await _detailService
                  .get(alt.source, alt.vodId)
                  .timeout(const Duration(seconds: 5));
            } catch (_) {
              continue;
            }
            if (!altDetail.usable) continue;
            final found = findEpisodeByNumber(altDetail.lines, epNum + 1);
            if (found == null) continue;
            var sourceName = altDetail.source.toString();
            for (final s in VideoSourcesStore.getAll()) {
              if (s.idKey == altDetail.source.toString()) {
                sourceName = s.name;
                break;
              }
            }
            target = (
              detail: altDetail,
              lineIdx: found.lineIdx,
              epIdx: found.epIdx,
              label: '$sourceName · 第 ${epNum + 1} 集',
            );
            break;
          }
        } catch (_) {}
      }
      // 3. Emby only: next season line (lines ARE seasons), first
      // episode. Same series, server-ordered seasons — strong by
      // construction, no title/number guessing involved.
      if (target == null && isEmby) {
        final nextLine = lineAtEnd + 1;
        if (nextLine < detailAtEnd.lines.length &&
            detailAtEnd.lines[nextLine].episodes.isNotEmpty) {
          target = (
            detail: detailAtEnd,
            lineIdx: nextLine,
            epIdx: 0,
            label: '${detailAtEnd.lines[nextLine].name} · 第 1 集',
          );
        }
      }
      if (target == null) return;
      final t = target;
      // Still on the same end state? The user may have left, tapped
      // another episode, or closed the page while the search ran.
      bool stillAtEnd() =>
          mounted &&
          _ended &&
          identical(_detail, detailAtEnd) &&
          _lineIdx == lineAtEnd &&
          _epIdx == epAtEnd;
      if (!stillAtEnd()) return;
      var started = false;
      Future<void> playTarget() async {
        if (started || !stillAtEnd()) return;
        started = true;
        await _saveProgress();
        _resumePosition = 0;
        setState(() {
          _detail = t.detail;
          _lineIdx = t.lineIdx;
          _epIdx = t.epIdx;
        });
        await _openCurrent();
      }

      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      if (_autoNext) {
        // 5 s cancellable countdown: never jump silently, and a
        // mid-countdown autoNext-off also cancels the jump.
        var cancelled = false;
        messenger.showSnackBar(
          SnackBar(
            content: Text('下一集在${t.label}，即将播放'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: '取消',
              onPressed: () {
                cancelled = true;
              },
            ),
          ),
        );
        await Future<void>.delayed(const Duration(seconds: 5));
        if (cancelled || !_autoNext) return;
        await playTarget();
      } else {
        // AutoNext OFF: nothing plays by itself — the manual entry
        // is the "去看" action on this prompt.
        messenger.showSnackBar(
          SnackBar(
            content: Text('下一集在${t.label}'),
            duration: const Duration(seconds: 8),
            action: SnackBarAction(
              label: '去看',
              onPressed: () {
                unawaited(playTarget());
              },
            ),
          ),
        );
      }
    }());
  }

  // Optimistic: flip the UI state first, persist fire-and-forget.
  // Awaiting the Hive put before setState makes the toggle feel
  // dead while the store flushes — and in the widget-test fake
  // zone the put's Future never resolves, so a second tap computes
  // the same `next` from the stale `_autoNext` (proven by the
  // in-player toggle test). Same pattern as the L05 follow toggle.
  void _toggleAutoNext() {
    final next = !_autoNext;
    setState(() => _autoNext = next);
    unawaited(VideoPlaybackSettings.setAutoNext(next));
  }

  Future<void> _goEpisode(int delta) async {
    final eps = _detail.lines[_lineIdx].episodes;
    final next = _epIdx + delta;
    if (next < 0 || next >= eps.length) return;
    await _saveProgress();
    // A different episode starts at 0, not at the previous resume point.
    _resumePosition = 0;
    setState(() => _epIdx = next);
    await _openCurrent();
  }

  /// Manual line switch (V-P2-3 + 1.1.6 seamless): keep the current
  /// episode — same episode NUMBER first (cross-source names differ
  /// in format: `第1集` vs `01`), then the same episode NAME (not
  /// found → episode 0) — and keep its played position, so switching
  /// lines mid-episode resumes where it was instead of restarting
  /// from the top. A different episode never inherits the old
  /// position (P1-15 rule: only the same episode resumes).
  ///
  /// Seamless (1.1.6): the new line's URL is PREOPENED first — the
  /// old line keeps playing until the new backend proves it can
  /// play. Any preopen/swap failure stays on the old line with a
  /// toast: never a failure card, never a silent jump to a third
  /// line or another source.
  Future<void> _switchLine(int line) async {
    if (line == _lineIdx) return;
    if (line < 0 || line >= _detail.lines.length) return;
    await _saveProgress();
    final epName = _episode.name;
    final epNum = parseEpisodeNumber(epName);
    final position = _position;
    final savedResume = _resumePosition;
    final fromLine = _lineIdx;
    final fromEp = _epIdx;
    final eps = _detail.lines[line].episodes;
    if (eps.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('该线路没有可播的集')),
        );
      }
      return;
    }
    // Strong match first: same episode number, then same name.
    var ei = -1;
    if (epNum != null) {
      ei = eps.indexWhere((e) => e.episodeNumber == epNum);
    }
    if (ei < 0) {
      ei = eps.indexWhere((e) => e.name == epName);
    }
    final sameEpisode = ei >= 0;
    final targetIdx = sameEpisode ? ei : 0;
    final target = eps[targetIdx];
    final resume = sameEpisode ? position : 0.0;
    // Preopen before touching anything visible: while this runs,
    // the old line just keeps playing.
    final preopened = await _session.preopen(
      url: target.url,
      isLive: false,
      declaredFormat: _declaredFormat(target.url),
      headers: _playHeaders(),
    );
    if (!preopened) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('该线路暂时打不开，已留在当前线路')),
        );
      }
      return;
    }
    if (!mounted) return;
    _resumePosition = resume;
    _resumeSought = true;
    setState(() {
      _lineIdx = line;
      _epIdx = targetIdx;
    });
    final epochBefore = _openEpoch;
    final ok = await _openCurrent(seamless: true);
    if (!ok && mounted && _openEpoch == epochBefore + 1) {
      // Swap failed after a successful preopen (defensive — the old
      // backend is still the playing one): back to the old line and
      // episode, old stream uninterrupted. A newer open (epoch
      // moved again) owns the indices now, so never restore then.
      _resumePosition = savedResume;
      setState(() {
        _lineIdx = fromLine;
        _epIdx = fromEp;
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('切换失败，已留在当前线路')),
      );
    }
  }

  Future<void> _retry() async {
    // VOD: same-URL retry is correct (episode URLs do not expire
    // like live anti-codes — fix 18.7).
    await _openCurrent();
  }

  // -- VOD danmaku (build 28) -------------------------------------------
  //
  // Config values are copied verbatim from the live room
  // (live_room_page.dart FlameBarrageWidget): same emit interval,
  // pool/cache caps, track/emoji sizing. The only difference is the
  // source: a fetched timeline (loadTimeline + seekTo) instead of
  // live per-message send.

  BarrageConfig _barrageConfig() => BarrageConfig(
    // Pure Live PlayerDanmakuSurface values.
    emitInterval: 0.05,
    fontSize: _danmakuFontSize,
    opacity: _danmakuOpacity,
    area: _danmakuArea,
    rasterizeItems: true,
    maxPendingCount: 120,
    maxPendingAge: const Duration(seconds: 5),
    pictureCacheMaxSize: 96,
    barragePoolMaxSize: 72,
    textCacheMaxSize: 320,
    trackHeight: (_danmakuFontSize * 1.55).clamp(24.0, 64.0).toDouble(),
    emojiSize: (_danmakuFontSize * 1.3).clamp(16.0, 48.0).toDouble(),
  );

  double get _effectiveRate => _longPressSpeeding ? 2.0 : _rate;

  void _applyBarrageRate() {
    _barrageController.playbackRate = _effectiveRate;
  }

  /// Read the danmaku display settings for VOD. DanmakuSettings
  /// falls back to its defaults when Hive is not initialised, so this
  /// never crashes the player.
  void _readDanmakuSettings() {
    _danmakuEnabled = DanmakuSettings.isEnabled(DanmakuSettings.vodSiteId);
    _danmakuFontSize = DanmakuSettings.fontSize();
    _danmakuOpacity = DanmakuSettings.opacity();
    _danmakuArea = DanmakuSettings.areaFraction();
  }

  /// Watch the danmaku keys while the player is open (copied from
  /// the live room): a change in the settings page applies without
  /// leaving the player. Guarded: when Hive is not initialised there
  /// is simply no live update.
  void _subscribeDanmakuSettings() {
    try {
      final listenable = HiveStore.box.listenable(
        keys: [
          HiveKeys.danmakuEnabled,
          HiveKeys.danmakuFontSize,
          HiveKeys.danmakuOpacity,
          HiveKeys.danmakuArea,
          HiveKeys.danmakuListStyle,
          HiveKeys.danmakuListSpacing,
          HiveKeys.danmakuShowUsernames,
          HiveKeys.danmakuSimilarityEnabled,
          HiveKeys.danmakuSimilarityThreshold,
          HiveKeys.danmakuBlockEmoteOnly,
          HiveKeys.danmakuBlockLong,
          HiveKeys.danmakuBlockLongLength,
          HiveKeys.danmakuDouyuBotFilter,
          HiveKeys.danmakuBlockList,
        ],
      );
      _danmakuSettingsListenable = listenable;
      listenable.addListener(_onDanmakuSettingsChanged);
    } catch (_) {
      // Hive unavailable — defaults apply, no live updates.
    }
  }

  void _onDanmakuSettingsChanged() {
    if (!mounted) return;
    final wasEnabled = _danmakuEnabled;
    _readDanmakuSettings();
    // Style changes apply live to the running engine.
    _barrageController.updateConfig(_barrageConfig());
    if (wasEnabled == _danmakuEnabled) {
      // Filter keys may have changed: rebuild the timeline from the
      // cached comments (no re-fetch) so a new block word takes
      // effect on what is already flying.
      if (_danmakuLoaded) _rebuildDanmakuTimeline();
      setState(() {});
      return;
    }
    if (_danmakuEnabled) {
      // Re-enabled mid-player: show and load.
      setState(() => _danmakuVisible = true);
      unawaited(_maybeLoadDanmaku());
    } else {
      // Disabled mid-player: drop the overlay.
      _barrageController.clear();
      setState(() {});
    }
  }

  /// Rebuild the engine timeline from the cached comments (filter
  /// re-read from the current settings). No network.
  void _rebuildDanmakuTimeline() {
    final comments = _danmakuComments;
    if (comments == null || !_danmakuEnabled || !_danmakuVisible) return;
    final items = _danmakuClient.buildTimeline(
      comments,
      filterConfig: DanmakuFilterConfig.fromSettings(),
    );
    _danmakuItems = items;
    _applyTimelineItems(items);
  }

  /// Feed [items] to the engine at the current position. The engine
  /// only exists while the overlay widget is mounted; a toggle-on
  /// rebuild lands a frame later, so when it is not attached yet the
  /// load is deferred to the next frame instead of being dropped
  /// into a detached controller.
  void _applyTimelineItems(List<BarrageItem> items) {
    if (_barrageController.engine == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_danmakuEnabled || !_danmakuVisible) return;
        _barrageController.loadTimeline(items);
        _barrageController.seekTo(
          Duration(milliseconds: (_position * 1000).round()),
        );
        _applyBarrageRate();
      });
      return;
    }
    _barrageController.loadTimeline(items);
    _barrageController.seekTo(
      Duration(milliseconds: (_position * 1000).round()),
    );
    _applyBarrageRate();
  }

  /// Post-first-frame entry point: gate + visibility only. The fetch
  /// itself is silent on every failure (no danmaku this episode).
  Future<void> _maybeLoadDanmaku() async {
    if (!_danmakuEnabled || !_danmakuVisible || _danmakuLoaded) return;
    await _loadDanmaku();
  }

  /// Hop 1 (candidates, top-1 passing the dual check) then hop 2
  /// (full comment timeline), then loadTimeline + seekTo(current
  /// position) so a resumed episode does not start its danmaku at 0.
  /// Epoch-guarded: a newer _openCurrent (episode/line switch) drops
  /// the stale result.
  Future<void> _loadDanmaku() async {
    if (!_danmakuEnabled || !_danmakuVisible) return;
    final epoch = _openEpoch;
    try {
      final candidates =
          _danmakuCandidates ??
          await _danmakuClient.fetchCandidates(
            title: _title,
            episode: _episode.name,
          );
      if (epoch != _openEpoch || !mounted) return;
      if (candidates == null || candidates.isEmpty) return;
      _danmakuCandidates = candidates;
      final candidate = selectVodDanmakuCandidate(
        candidates,
        queryTitle: _title,
        year: _detail.meta.year,
        startIndex: _danmakuCandidateIndex,
      );
      if (candidate == null) return;
      _danmakuCandidateIndex = candidates.indexOf(candidate);
      final comments = await _danmakuClient.fetchCommentsFor(candidate);
      if (epoch != _openEpoch || !mounted) return;
      if (comments == null || comments.isEmpty) return;
      if (!_danmakuEnabled || !_danmakuVisible) return;
      _danmakuComments = comments;
      _rebuildDanmakuTimeline();
      _danmakuLoaded = true;
      if (mounted) setState(() {});
    } catch (_) {
      // Silent: no danmaku this episode, playback unaffected.
    }
  }

  /// Per-episode display toggle (top-bar button). Off clears the
  /// engine and unmounts the overlay; on re-feeds the cached timeline
  /// at the current position, or triggers the fetch when nothing was
  /// loaded yet. The master gate lives in Settings, not here.
  void _toggleDanmakuVisible() {
    if (!_danmakuEnabled) return;
    final next = !_danmakuVisible;
    setState(() => _danmakuVisible = next);
    if (!next) {
      _barrageController.clear();
      return;
    }
    final items = _danmakuItems;
    if (items != null) {
      _applyTimelineItems(items);
    } else {
      unawaited(_loadDanmaku());
    }
    _armHideTimer();
  }

  /// "换弹幕源": long-press the top-bar toggle to take the next
  /// candidate that still passes the dual check (wrapping to the top
  /// once). No toast, no prompt — the overlay simply switches.
  Future<void> _cycleDanmakuCandidate() async {
    final candidates = _danmakuCandidates;
    if (!_danmakuEnabled ||
        !_danmakuVisible ||
        candidates == null ||
        candidates.length < 2) {
      return;
    }
    var next = selectVodDanmakuCandidate(
      candidates,
      queryTitle: _title,
      year: _detail.meta.year,
      startIndex: _danmakuCandidateIndex + 1,
    );
    next ??= selectVodDanmakuCandidate(
      candidates,
      queryTitle: _title,
      year: _detail.meta.year,
    );
    if (next == null) return;
    final nextIndex = candidates.indexOf(next);
    if (nextIndex == _danmakuCandidateIndex) return;
    final epoch = _openEpoch;
    try {
      final comments = await _danmakuClient.fetchCommentsFor(next);
      if (epoch != _openEpoch || !mounted) return;
      if (comments == null || comments.isEmpty) return;
      if (!_danmakuEnabled || !_danmakuVisible) return;
      _danmakuCandidateIndex = nextIndex;
      _danmakuComments = comments;
      _danmakuLoaded = true;
      _rebuildDanmakuTimeline();
      if (mounted) setState(() {});
    } catch (_) {
      // Silent: keep the current source.
    }
  }

  void _armHideTimer() {
    _hideTimer?.cancel();
    // 5 s, Pure Live's value: after revealing the controls the user
    // needs enough time to find and tap the exit button.
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      // Never hide mid-interaction. A drag's onCancel (this drag lost
      // the gesture arena to another drag, e.g. the Slider) re-arms the
      // timer at drag start; if it fired here the controls would vanish
      // under the user's finger, the Slider would unmount and the seek
      // would be swallowed. Defer instead of hiding — the drag's end
      // handler re-arms the timer for 5 s after the interaction ends.
      if (_scrubbing ||
          _dragSeekTarget != null ||
          _drag.side.value != null ||
          _longPressSpeeding) {
        _armHideTimer();
        return;
      }
      if (_playing) setState(() => _showControls = false);
    });
  }

  // NO double-tap seek (PiliPlus has it — quarters, 10 s step — but
  // deliberately NOT ported): adding onDoubleTap makes Flutter hold
  // every single tap until the double-tap timeout (~300 ms, the
  // DoubleTap recognizer holds the arena on first tap-up,
  // multitap.dart _registerFirstTap -> arena.hold), so the tap that
  // wakes the controls after auto-hide lands 300 ms late — the
  // v1.0.7 "controls gone, can't exit" path. PiliPlus's
  // ImmediateTap only makes onTapDown immediate, not onTapUp, so it
  // does not fix this either; PiliPlus accepts the delay, we don't
  // (video_controls_show_test pins the immediate wake-tap). If this
  // is ever revisited, it needs a tap path that stays immediate AND
  // a double-tap path — not GestureDetector's onDoubleTap.
  void _onSurfaceTap() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _armHideTimer();
  }

  /// Cycle the VOD picture fit (自动 -> 拉伸 -> 裁剪): persists, then
  /// rebuilds — MPV/IJK re-apply the fit live, AVPlayer on next open
  /// (see video_fit.dart).
  void _cycleVideoFit() {
    final next = _videoFit.next;
    setState(() => _videoFit = next);
    unawaited(VideoPlaybackSettings.setVideoFit(next));
    _armHideTimer();
  }

  String get _rateLabel => '${_longPressSpeeding ? 2.0 : _rate}x';

  // -- Long-press 2x (Bilibili-style): hold the video to play at 2x,
  // release to go back to the user's rate. Temporary override only —
  // _rate (and the persisted vodPlaybackRate) is never changed here.
  // Gesture arena keeps this from fighting the drags: a hold still for
  // ~500ms wins the long-press, any real movement wins the drag instead.
  void _onLongPressStart(LongPressStartDetails details) {
    // Controls hidden: the user's intent is to wake the UI, not to
    // speed up. A hold is the natural "wake" press — letting it start
    // 2x instead wins the gesture arena over onTap, so the controls
    // stay hidden and there is no way out (chen v1.0.7: controls
    // gone, can't exit). Reveal first; 2x only when the controls
    // are already up.
    if (!_showControls) {
      setState(() => _showControls = true);
      _armHideTimer();
      return;
    }
    if (!_playing || _failed || _ended || _longPressSpeeding) return;
    // Don't let the hide timer fire mid-hold and unmount the
    // controls under the user's finger; re-armed on release.
    _hideTimer?.cancel();
    setState(() => _longPressSpeeding = true);
    // One medium confirmation (Beans medium = long-press): the
    // master haptics switch gates it, so a user who turned haptics
    // off feels nothing here and the 2x still applies.
    HaoHaptics.medium();
    unawaited(_session.setRate(2.0));
    _applyBarrageRate();
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    _restoreRateAfterLongPress();
  }

  void _onLongPressCancel() {
    _restoreRateAfterLongPress();
  }

  void _restoreRateAfterLongPress() {
    if (!_longPressSpeeding) return;
    setState(() => _longPressSpeeding = false);
    unawaited(_session.setRate(_rate));
    _applyBarrageRate();
    _armHideTimer();
  }

  // -- Skip intro/outro (1.1.6, VOD only) -------------------------------
  //
  // Driven from the position listener: every position event re-checks
  // the current episode's window. Episode-change detection lives
  // here (not in _openCurrent — that method belongs to the
  // source-chain group): a new (line, episode) clears the one-shot
  // flags, cancels the countdown and re-resolves the window.
  //
  // Modes (Hive vodSkipIntroMode, default off):
  // - manual: a "跳过片头/片尾" pill shows while inside the window;
  //   tapping seeks / advances. No automatic seek, ever.
  // - auto3s: same pill + a 3 s countdown on it, then auto-seek.
  //   Tapping skips at once; seeking out of the window cancels.
  // - autoNow: the first position event inside the window seeks at
  //   once (no pill). A resume landing inside the window skips once
  //   — that is the correct behaviour, the user stopped mid-intro.
  // - off: nothing (no pill, no seek).
  // The auto flags block only the AUTOMATIC seek: after an auto
  // skip, seeking back into the window still shows the manual pill
  // (manual/auto3s). Credits auto-advance calls _onEpisodeEnded(),
  // which honours _autoNext — OFF or last episode shows the end
  // card instead of advancing.

  void _checkSkipPoints() {
    if (_skipMode == VodSkipIntroMode.off) return;
    if (_lineIdx != _skipEpLine || _epIdx != _skipEpIdx) {
      _skipEpLine = _lineIdx;
      _skipEpIdx = _epIdx;
      _skipIntroAutoDone = false;
      _skipCreditsDone = false;
      _skipShowIntro = false;
      _skipShowCredits = false;
      _cancelSkipCountdown();
      _skipIntroWindow = resolveIntroWindow(
        markers: SkipMarkers(
          introStart: _episode.introStart,
          introEnd: _episode.introEnd,
          creditsStart: _episode.creditsStart,
        ),
        customSeconds: readSkipIntroDuration(
          title: _title,
          episodeName: _episode.name,
        ),
      );
    }
    if (_failed || _ended) return;
    _checkSkipIntro();
    _checkSkipCredits();
  }

  void _checkSkipIntro() {
    final window = _skipIntroWindow;
    if (window == null) {
      if (_skipShowIntro) {
        _skipShowIntro = false;
        _cancelSkipCountdown();
      }
      return;
    }
    final inWindow = _position >= window.start && _position < window.end;
    if (!inWindow) {
      if (_skipShowIntro) {
        _skipShowIntro = false;
        _cancelSkipCountdown();
      }
      return;
    }
    switch (_skipMode) {
      case VodSkipIntroMode.off:
        break;
      case VodSkipIntroMode.manual:
        _skipShowIntro = true;
      case VodSkipIntroMode.autoNow:
        if (_skipIntroAutoDone) break;
        _skipIntroAutoDone = true;
        _skipIntroNow();
      case VodSkipIntroMode.auto3s:
        _skipShowIntro = true;
        if (!_skipIntroAutoDone) _startSkipCountdown(window.end);
    }
  }

  void _checkSkipCredits() {
    final credits = _episode.creditsStart;
    if (credits == null || _skipCreditsDone) {
      if (_skipShowCredits) _skipShowCredits = false;
      return;
    }
    // A credits marker at/after (duration - 5 s) is not a usable
    // trigger — the episode is effectively over already.
    if (_duration <= 0 || credits >= _duration - 5) return;
    if (_position < credits) {
      if (_skipShowCredits) _skipShowCredits = false;
      return;
    }
    switch (_skipMode) {
      case VodSkipIntroMode.off:
        break;
      case VodSkipIntroMode.manual:
        _skipShowCredits = true;
      case VodSkipIntroMode.auto3s:
      case VodSkipIntroMode.autoNow:
        _skipCreditsDone = true;
        _onEpisodeEnded();
    }
  }

  void _startSkipCountdown(double target) {
    if (_skipCountdown != null) return;
    _skipCountdownLeft = 3;
    _skipCountdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _skipCountdownLeft -= 1;
      if (_skipCountdownLeft <= 0) {
        timer.cancel();
        _skipCountdown = null;
        _skipIntroAutoDone = true;
        _skipShowIntro = false;
        _seekForSkip(target);
        if (mounted) setState(() {});
        return;
      }
      setState(() {});
    });
  }

  void _cancelSkipCountdown() {
    _skipCountdown?.cancel();
    _skipCountdown = null;
    _skipCountdownLeft = 0;
  }

  void _seekForSkip(double target) {
    final at = Duration(milliseconds: (target * 1000).round());
    unawaited(_session.seekTo(at));
    _barrageController.seekTo(at);
  }

  void _skipIntroNow() {
    final window = _skipIntroWindow;
    if (window == null) return;
    _cancelSkipCountdown();
    _skipIntroAutoDone = true;
    _skipShowIntro = false;
    _seekForSkip(window.end);
    if (mounted) setState(() {});
  }

  void _skipCreditsNow() {
    _skipCreditsDone = true;
    _skipShowCredits = false;
    if (mounted) setState(() {});
    _onEpisodeEnded();
  }

  /// Full-width horizontal swipe covers up to 5 minutes (or the whole
  /// video when shorter).
  double get _seekSpan =>
      _duration <= 0 ? 0 : (_duration < 300 ? _duration : 300);

  /// Cycle the playback speed through Pure Live's defaultRates
  /// (0.5x -> 2.0x); the choice persists and survives episode
  /// switches (the session re-applies it on backend swap).
  Future<void> _cycleRate() async {
    final rates = VideoPlaybackSettings.vodRates;
    final idx = rates.indexOf(_rate);
    final next = rates[(idx + 1) % rates.length];
    setState(() => _rate = next);
    unawaited(VideoPlaybackSettings.setPlaybackRate(next));
    try {
      await _session.setRate(next);
    } catch (_) {}
    _applyBarrageRate();
    _armHideTimer();
  }

  // -- Horizontal drag: seek with a preview, one seek on release. --

  void _onSeekDragStart(DragStartDetails details) {
    if (_duration <= 0 || _failed || _ended) return;
    _hideTimer?.cancel();
    setState(() {
      _dragSeekStart = _scrubbing ? _scrubValue : _position;
      _dragSeekTarget = _dragSeekStart;
      _dragSeekDelta = 0;
    });
  }

  void _onSeekDragUpdate(DragUpdateDetails details) {
    if (_dragSeekTarget == null) return;
    final width = MediaQuery.of(context).size.width;
    if (width <= 0 || _seekSpan <= 0) return;
    setState(() {
      _dragSeekDelta += details.delta.dx / width * _seekSpan;
      _dragSeekTarget = (_dragSeekStart + _dragSeekDelta).clamp(0.0, _duration);
    });
  }

  Future<void> _onSeekDragEnd(DragEndDetails details) async {
    final target = _dragSeekTarget;
    if (target == null) return;
    setState(() => _dragSeekTarget = null);
    try {
      await _session.seekTo(Duration(milliseconds: (target * 1000).round()));
    } catch (_) {}
    _barrageController.seekTo(
      Duration(milliseconds: (target * 1000).round()),
    );
    _armHideTimer();
  }

  void _onSeekDragCancel() {
    if (mounted) setState(() => _dragSeekTarget = null);
    // Do NOT re-arm the hide timer here: this fires when the drag loses
    // the gesture arena to another gesture (e.g. the Slider won), i.e.
    // the user is still interacting — re-arming would hide the controls
    // mid-drag. If the pointer was genuinely cancelled, leaving the
    // controls visible is the safe direction; the next interaction
    // re-arms the timer.
  }

  // -- Vertical drag: left half brightness, right half volume. --
  //
  // Seed, sensitivity (300 px = full range) and HUD all live in the
  // shared [_drag] controller (P1-U2, same as the live room). This
  // page only guards where a drag may start (failed/ended player)
  // and keeps the controls-hide timer in sync. Behaviour changes
  // vs the old VOD-only code: the side now follows the finger
  // mid-drag (live behaviour — was fixed at drag start), and the HUD
  // linger is armed on the last tick as well as on drag end.

  void _onSystemDragStart(DragStartDetails details) async {
    if (_failed || _ended) return;
    _hideTimer?.cancel();
    final size = MediaQuery.of(context).size;
    await _drag.startDrag(details.globalPosition, size);
  }

  void _onSystemDragUpdate(DragUpdateDetails details) {
    _drag.updateDrag(details, MediaQuery.of(context).size);
  }

  void _onSystemDragEnd(DragEndDetails details) {
    if (_drag.side.value == null) return;
    _drag.endDrag();
    _armHideTimer();
  }

  void _onSystemDragCancel() {
    _drag.cancelDrag();
    // Do NOT re-arm the hide timer here — same reason as
    // _onSeekDragCancel: losing the arena to another gesture means the
    // user is still interacting; re-arming would hide the controls
    // mid-gesture.
  }

  void _openEpisodeSheet() {
    final theme = HaoTheme.of(context);
    final eps = _detail.lines[_lineIdx].episodes;
    showModalBottomSheet<void>(
      context: context,
      // isScrollControlled: without it the sheet is capped at ~half the
      // screen height, but this sheet asks for 0.6 — the bottom rows
      // were clipped. Same bug class as the music track sheet (v1.0.6).
      // Content already scrolls via the ListView below, so no extra
      // SingleChildScrollView wrapper is needed here.
      isScrollControlled: true,
      // N-10: framework grabber + settle-spring rise (same spring as
      // the player close). The hand-drawn handle below is removed —
      // showDragHandle renders the one grabber, two bars would stack.
      showDragHandle: true,
      sheetAnimationStyle: const AnimationStyle(
        curve: HaoSettleSpringCurve(),
        reverseCurve: HaoSettleSpringCurve(),
      ),
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (context) {
        return GlassSheetBackground(
          child: SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    '选集 (${eps.length})',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.02,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: eps.length,
                    itemBuilder: (context, i) {
                      final selected = i == _epIdx;
                      return ListTile(
                        leading: Container(
                          width: 44,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: selected ? theme.accentSoft : theme.surface,
                            borderRadius: BorderRadius.circular(HaoRadius.standard),
                          ),
                          child: Text(
                            (i + 1).toString().padLeft(2, '0'),
                            style: TextStyle(
                              color: selected
                                  ? theme.accent
                                  : theme.textSecondary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        title: Text(
                          eps[i].name,
                          style: TextStyle(
                            color: selected ? theme.accent : theme.textPrimary,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                        onTap: () async {
                          Navigator.of(context).pop();
                          if (i == _epIdx) return;
                          await _saveProgress();
                          // A different episode starts at 0, not at the
                          // previous resume point (same rule as auto-next).
                          _resumePosition = 0;
                          setState(() => _epIdx = i);
                          await _openCurrent();
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        );
      },
    );
  }

  /// Audio/subtitle track picker (build 28, Emby formats).
  ///
  /// Same bottom-sheet pattern as [_openEpisodeSheet] — no new menu
  /// system. The lists are enumerated BEFORE the sheet opens (a local
  /// MPV query, bounded so a stuck backend can never trap the tap);
  /// backends that cannot enumerate (IJK / AVPlayer) answer [] and
  /// the sheet shows the "无音轨 / 无字幕" empty state instead of a
  /// broken list. '自动' returns to the backend default, '关闭'
  /// (subtitles only) turns subtitles off. The choice itself lives
  /// in the session ([PlaybackSession.setAudioTrack] /
  /// [PlaybackSession.setSubtitleTrack]) — it is remembered there and
  /// re-applied after episode / line / backend switches, so this page
  /// keeps no track state of its own; the sheet re-reads
  /// [PlaybackSession.currentAudioTrackId] /
  /// [PlaybackSession.currentSubtitleTrackId] on every open.
  Future<void> _openTrackSheet() async {
    List<PlaybackTrack> audio;
    List<PlaybackTrack> subtitles;
    try {
      audio = await _session
          .audioTracks()
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      audio = const [];
    }
    try {
      subtitles = await _session
          .subtitleTracks()
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      subtitles = const [];
    }
    if (!mounted) return;
    final theme = HaoTheme.of(context);
    showModalBottomSheet<void>(
      context: context,
      // Same sizing rationale as the episode sheet (see above).
      isScrollControlled: true,
      // N-10: framework grabber + settle-spring rise (same spring as
      // the player close); hand-drawn handle removed, see above.
      showDragHandle: true,
      sheetAnimationStyle: const AnimationStyle(
        curve: HaoSettleSpringCurve(),
        reverseCurve: HaoSettleSpringCurve(),
      ),
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (context) {
        return GlassSheetBackground(
          child: SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    '音轨与字幕',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.02,
                    ),
                  ),
                ),
                Expanded(
                  child: StatefulBuilder(
                    builder: (context, setSheetState) {
                      Widget sectionHeader(String label) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          label,
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      );

                      Widget trackRow({
                        required String rowKey,
                        required String id,
                        required String label,
                        required bool selected,
                        required Future<void> Function(String) apply,
                      }) {
                        return ListTile(
                          key: ValueKey(rowKey),
                          title: Text(
                            label,
                            style: TextStyle(
                              color: selected
                                  ? theme.accent
                                  : theme.textPrimary,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                            ),
                          ),
                          trailing: selected
                              ? Icon(Icons.check, color: theme.accent)
                              : null,
                          onTap: selected
                              ? null
                              : () {
                                  // The session records the choice
                                  // synchronously before applying it
                                  // to the backend, so the checkmark
                                  // moves at once.
                                  unawaited(apply(id));
                                  setSheetState(() {});
                                },
                        );
                      }

                      final audioId =
                          _session.currentAudioTrackId ?? 'auto';
                      final subtitleId =
                          _session.currentSubtitleTrackId ?? 'auto';
                      final secondaryId =
                          _session.currentSecondarySubtitleTrackId ?? 'no';
                      // A Column, not a ListView: the list is short
                      // (auto + a handful of tracks) and every row
                      // must stay built — a ListView disposes
                      // off-screen rows, which also makes the
                      // checkmark state unreadable while scrolled.
                      return SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                          sectionHeader('音轨'),
                          if (audio.isEmpty)
                            ListTile(
                              key: const ValueKey('vod-track-audio-empty'),
                              title: Text(
                                '无音轨',
                                style: TextStyle(
                                  color: theme.textSecondary,
                                ),
                              ),
                            )
                          else ...[
                            trackRow(
                              rowKey: 'vod-track-audio-auto',
                              id: 'auto',
                              label: '自动',
                              selected: audioId == 'auto',
                              apply: _session.setAudioTrack,
                            ),
                            for (final t in audio)
                              trackRow(
                                rowKey: 'vod-track-audio-${t.id}',
                                id: t.id,
                                label: t.displayName,
                                selected: audioId == t.id,
                                apply: _session.setAudioTrack,
                              ),
                          ],
                          sectionHeader('字幕轨'),
                          if (subtitles.isEmpty)
                            ListTile(
                              key: const ValueKey('vod-track-sub-empty'),
                              title: Text(
                                '无字幕',
                                style: TextStyle(
                                  color: theme.textSecondary,
                                ),
                              ),
                            )
                          else ...[
                            trackRow(
                              rowKey: 'vod-track-sub-auto',
                              id: 'auto',
                              label: '自动',
                              selected: subtitleId == 'auto',
                              apply: _session.setSubtitleTrack,
                            ),
                            trackRow(
                              rowKey: 'vod-track-sub-no',
                              id: 'no',
                              label: '关闭',
                              selected: subtitleId == 'no',
                              apply: _session.setSubtitleTrack,
                            ),
                            for (final t in subtitles)
                              trackRow(
                                rowKey: 'vod-track-sub-${t.id}',
                                id: t.id,
                                label: t.displayName,
                                selected: subtitleId == t.id,
                                apply: _session.setSubtitleTrack,
                              ),
                          ],
                          sectionHeader('第二字幕'),
                          // mpv renders the secondary track as
                          // toptitle above the main track; a bitmap
                          // (PGS) secondary overlaps the main track
                          // (mpv behaviour) — said here, not hidden.
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                            child: Text(
                              '位图字幕作第二字幕时会与主字幕重叠',
                              style: TextStyle(
                                color: theme.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          if (subtitles.isEmpty)
                            ListTile(
                              key: const ValueKey('vod-track-sub2-empty'),
                              title: Text(
                                '无字幕',
                                style: TextStyle(
                                  color: theme.textSecondary,
                                ),
                              ),
                            )
                          else ...[
                            trackRow(
                              rowKey: 'vod-track-sub2-no',
                              id: 'no',
                              label: '无',
                              selected: secondaryId == 'no',
                              apply: _session.setSecondarySubtitleTrack,
                            ),
                            // The main track is never a useful second
                            // subtitle (the same text twice, top +
                            // bottom), so it is not offered here.
                            // When the main track is 'auto' nothing
                            // is excluded — the concrete track is
                            // unknown.
                            for (final t in subtitles)
                              if (t.id != subtitleId)
                                trackRow(
                                  rowKey: 'vod-track-sub2-${t.id}',
                                  id: t.id,
                                  label: t.displayName,
                                  selected: secondaryId == t.id,
                                  apply: _session.setSecondarySubtitleTrack,
                                ),
                          ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        );
      },
    );
  }

  /// Exit the player. The route pops FIRST — nothing slow is awaited
  /// before it: playback is paused (bounded, so the film goes quiet
  /// the moment the user taps back instead of relying on dispose()
  /// racing the route pop), the position is reported to the detail
  /// page (sync, cannot block), then the route pops immediately.
  /// The orientation channel and the Hive save run AFTER the pop as
  /// fire-and-forget cleanup, so a stalled platform channel or a
  /// wedged storage write can never trap the user on this page again.
  ///
  /// (v1.0.6 "still won't exit": the old _close() awaited
  /// exitFullscreen() and an UNBOUNDED _saveProgress() before pop —
  /// either one stalling left the film on screen with no way out.
  /// Widget-test proof: SystemChrome calls never complete in the
  /// test harness, and the old code only popped after the 2 s
  /// exitFullscreen timeout; with pop-first the route pops in
  /// milliseconds even when the channel never replies.)
  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      await _session.pause().timeout(const Duration(seconds: 1));
    } catch (_) {}
    try {
      widget.onClose?.call(_lineIdx, _epIdx, _position);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
    // Cleanup after the pop — never awaited, never blocking the exit.
    unawaited(
      _fullscreen
          .exitFullscreen()
          .timeout(const Duration(seconds: 2))
          .catchError((_) {}),
    );
    unawaited(_saveProgress());
  }

  // Screen-on follows the session (playback_session.dart): background
  // releases it, foreground re-holds it only if still playing. VOD
  // pauses in background (normal for video-on-demand; live keeps
  // audio-only instead) — pausing the SESSION, not just the native
  // player, so the status the UI shows stays honest: the Video widget
  // already pauses the native player on background but never tells
  // the session, which used to leave the page showing "playing" over
  // a frozen frame (double-tap to resume). Inactive is transient
  // (call / Control Center): leave the track alone, like the live room.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _session.setForeground(false);
        // Background: the occlusion loop stops at once (no
        // background snapshots / inference / battery burn) — the
        // pause path below would stop it too, but this must not
        // depend on the pause racing the backgrounding.
        _occlusion.stopLoop();
        // Give the brightness back to the system NOW, not only on
        // dispose: the iOS plugin re-applies a remembered app
        // brightness on every foreground return, so a stale player
        // value would overwrite whatever the user picked in Control
        // Center while backgrounded. reset() clears the remembered
        // value, so the return keeps the user's system brightness.
        unawaited(ScreenBrightness.reset());
        final s = _session.status;
        if (s == PlaybackStatus.playing ||
            s == PlaybackStatus.buffering ||
            s == PlaybackStatus.opening) {
          unawaited(_session.pause());
        }
      case AppLifecycleState.resumed:
        _session.setForeground(true);
        // Foreground return re-evaluates the occlusion gate (the
        // switch may have changed in Settings while away).
        _occlusion.update(
          danmakuVisible: _danmakuEnabled && _danmakuVisible,
          playing: _playing,
        );
        // Re-read the CURRENT brightness as the next drag's seed —
        // never set it. Whatever the user picked in Control Center
        // while backgrounded is the brightness now; re-applying the
        // old player value here would be the bug chen reported.
        unawaited(_drag.refreshBrightnessSeed());
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Leaving the player hands the brightness back to the system:
    // a player-set level must not leak onto every other page (or
    // survive to be re-applied on the next foreground return).
    unawaited(ScreenBrightness.reset());
    _hideTimer?.cancel();
    _cancelSkipCountdown();
    _drag.dispose();
    _danmakuSettingsListenable?.removeListener(_onDanmakuSettingsChanged);
    _barrageController.dispose();
    _occlusion.dispose();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _statusSub?.cancel();
    _errorSub?.cancel();
    unawaited(_saveProgress());
    unawaited(_session.dispose());
    try {
      Get.delete<FullscreenController>();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // No HaoTheme read here: the player surface is always black video,
    // so its controls are white-on-black in every theme/mode (the line
    // chips use white pills, not the theme accent — see below).
    // Danmaku occlusion gate (1.1.6): idempotent + cheap, so it runs
    // on every build — every gate (switch, danmaku visibility,
    // playing state, engine) changes via a rebuild, and this one call
    // site cannot miss any of them. The loop itself only starts when
    // switch on + danmaku flying + playing + MPV.
    _occlusion.update(
      danmakuVisible: _danmakuEnabled && _danmakuVisible,
      playing: _playing,
    );
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_fullscreen.exitFullscreen());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onSurfaceTap,
          onLongPressStart: _onLongPressStart,
          onLongPressEnd: _onLongPressEnd,
          onLongPressCancel: _onLongPressCancel,
          onHorizontalDragStart: _onSeekDragStart,
          onHorizontalDragUpdate: _onSeekDragUpdate,
          onHorizontalDragEnd: _onSeekDragEnd,
          onHorizontalDragCancel: _onSeekDragCancel,
          onVerticalDragStart: _onSystemDragStart,
          onVerticalDragUpdate: _onSystemDragUpdate,
          onVerticalDragEnd: _onSystemDragEnd,
          onVerticalDragCancel: _onSystemDragCancel,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _session.buildVideoWidget(),
              // VOD danmaku overlay (build 28): timeline mode, over
              // the video, UNDER the top/bottom bars. IgnorePointer +
              // enablePointerEvents:false so taps/drags keep reaching
              // the page gesture layer; it never hides with the
              // controls (danmaku keeps flying, only the bars hide).
              if (_danmakuEnabled && _danmakuVisible)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DanmakuOcclusionMask(
                      controller: _occlusion,
                      fit: _videoFit.boxFit,
                      child: FlameBarrageWidget(
                        controller: _barrageController,
                        enablePointerEvents: false,
                        config: _barrageConfig(),
                        emojiAtlas: EmojiAtlas.instance,
                      ),
                    ),
                  ),
                ),
              // Page-level text subtitles (1.1.6, ROUTE A): ABOVE the
              // danmaku layer, below the control bars. The built-in
              // SubtitleView is hidden in MpvBackend (it lives inside
              // Video and can never paint above danmaku); this
              // overlay draws the same [main, secondary] lines from
              // the session. Bitmap (PGS) subtitles have no text
              // event and are not in here — see mpv_backend.dart.
              Positioned(
                key: const ValueKey('vod-subtitle-overlay'),
                left: 0,
                right: 0,
                bottom: 120,
                child: IgnorePointer(
                  child: StreamBuilder<List<String>>(
                    stream: _session.subtitleStream,
                    initialData: const ['', ''],
                    builder: (context, snapshot) {
                      final lines = (snapshot.data ?? const ['', ''])
                          .where((line) => line.trim().isNotEmpty)
                          .map((line) => line.trim())
                          .toList();
                      if (lines.isEmpty) return const SizedBox.shrink();
                      return Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.66),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            lines.join('\n'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              height: 1.4,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              // Skip intro/outro pills (1.1.6): right side, above the
              // subtitle line and the bottom bar. The auto3s pill
              // counts down 3/2/1 while it waits.
              if (_skipShowIntro)
                Positioned(
                  right: 16,
                  bottom: 168,
                  child: _SkipButton(
                    label:
                        _skipMode == VodSkipIntroMode.auto3s &&
                            _skipCountdownLeft > 0
                        ? '跳过片头 $_skipCountdownLeft'
                        : '跳过片头',
                    onTap: _skipIntroNow,
                  ),
                ),
              if (_skipShowCredits)
                Positioned(
                  right: 16,
                  bottom: 168,
                  child: _SkipButton(
                    label: '跳过片尾',
                    onTap: _skipCreditsNow,
                  ),
                ),
              if (_loading)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CupertinoActivityIndicator(color: Colors.white),
                      const SizedBox(height: 12),
                      Text(
                        _loadingHint,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              if (_failed) _FailureCard(onRetry: _retry, onClose: _close),
              if (_ended && !_failed) _EndedCard(onClose: _close),
              // Top bar: back + title + episode. Shown whenever the
              // controls are up — including the failed state, so a
              // failed player never traps the user without a way out.
              if (_showControls) ...[
                // Top bar: back + title + episode.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xB3000000), Color(0x00000000)],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(8, 32, 16, 24),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                          onPressed: _close,
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                _epLabel,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // NO quality selector on VOD — one URL per
                        // episode, no quality tiers (live only).
                        // Auto-play-next toggle (V-P0-2, default ON):
                        // dimmed when off, white when on.
                        IconButton(
                          icon: Icon(
                            Icons.playlist_play,
                            color: _autoNext ? Colors.white : Colors.white38,
                          ),
                          tooltip: '自动连播',
                          onPressed: _toggleAutoNext,
                        ),
                        // Danmaku (build 28, opt-in, default OFF): icon
                        // + tooltip copied from the live room. Greyed
                        // (not hidden) while the master gate is off,
                        // so the top-bar layout never jumps. Long-press
                        // cycles to the next candidate ("换弹幕源").
                        IconButton(
                          icon: Icon(
                            _danmakuVisible
                                ? Icons.chat_bubble_outline
                                : Icons.chat_bubble,
                            color: _danmakuEnabled
                                ? Colors.white
                                : Colors.white38,
                          ),
                          tooltip: _danmakuVisible ? '关闭弹幕' : '打开弹幕',
                          onPressed: _danmakuEnabled
                              ? _toggleDanmakuVisible
                              : null,
                          onLongPress: _danmakuEnabled
                              ? () => unawaited(_cycleDanmakuCandidate())
                              : null,
                        ),
                        // Audio/subtitle tracks (build 28, Emby
                        // formats): one entry opening the track sheet
                        // below — same bottom-sheet pattern as 选集,
                        // no new menu system. Always enabled: on a
                        // backend that cannot enumerate tracks the
                        // sheet shows the empty state instead.
                        IconButton(
                          icon: const Icon(
                            Icons.subtitles,
                            color: Colors.white,
                          ),
                          tooltip: '音轨与字幕',
                          onPressed: () => unawaited(_openTrackSheet()),
                        ),
                        // Picture fit (PiliPlus VideoFitType + Kazumi
                        // PlayerAspectRatio): cycles 自动/拉伸/裁剪.
                        // VOD only — this page never serves live.
                        IconButton(
                          icon: const Icon(
                            Icons.aspect_ratio,
                            color: Colors.white,
                          ),
                          tooltip: '画面比例：${_videoFit.label}',
                          onPressed: _cycleVideoFit,
                        ),
                        IconButton(
                          icon: const Icon(Icons.list, color: Colors.white),
                          tooltip: '选集',
                          onPressed: _openEpisodeSheet,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              // Bottom bar: play/pause, prev/next episode, elapsed.
              // Hidden when failed/ended (nothing to control there).
              if (_showControls && !_failed && !_ended) ...[
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xB3000000), Color(0x00000000)],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_detail.lines.length > 1)
                          SizedBox(
                            height: 36,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: _detail.lines.length,
                              itemBuilder: (context, i) {
                                final selected = i == _lineIdx;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  child: ChoiceChip(
                                    label: Text(_detail.lines[i].name),
                                    selected: selected,
                                    // Player surface is ALWAYS black
                                    // video, in every theme/mode — so
                                    // the light-mode accents (dark gold
                                    // / dark teal / dark blue, made for
                                    // light scaffolds) are unreadable
                                    // here. White-on-black pills are the
                                    // correct treatment on this surface.
                                    selectedColor: Colors.white
                                        .withValues(alpha: 0.20),
                                    backgroundColor: Colors.white
                                        .withValues(alpha: 0.08),
                                    side: BorderSide(
                                      color: selected
                                          ? Colors.white
                                              .withValues(alpha: 0.60)
                                          : Colors.white
                                              .withValues(alpha: 0.25),
                                    ),
                                    labelStyle: TextStyle(
                                      color: selected
                                          ? Colors.white
                                          : Colors.white70,
                                      fontWeight: selected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                    onSelected: (_) => _switchLine(i),
                                  ),
                                );
                              },
                            ),
                          ),
                        Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                _playing ? Icons.pause : Icons.play_arrow,
                                color: Colors.white,
                                size: 32,
                              ),
                              onPressed: () {
                                _session.togglePlayPause();
                                _armHideTimer();
                              },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.skip_previous,
                                color: Colors.white,
                              ),
                              tooltip: '上一集',
                              onPressed: () => _goEpisode(-1),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.skip_next,
                                color: Colors.white,
                              ),
                              tooltip: '下一集',
                              onPressed: () => _goEpisode(1),
                            ),
                            const SizedBox(width: 8),
                            // Elapsed left / remaining right (fix 6 thin
                            // 4 px track; the Slider's hit area stays
                            // generous). No duration yet -> elapsed only.
                            Text(
                              formatMmSs(_scrubbing ? _scrubValue : _position),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                            if (_duration > 0) ...[
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 4,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 7,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 14,
                                    ),
                                    activeTrackColor: Colors.white,
                                    inactiveTrackColor: Colors.white30,
                                    thumbColor: Colors.white,
                                  ),
                                  child: Slider(
                                    value:
                                        (_scrubbing ? _scrubValue : _position)
                                            .clamp(0.0, _duration),
                                    max: _duration,
                                    onChangeStart: (_) {
                                      // The hide timer must not fire
                                      // mid-drag: it would unmount the
                                      // whole control bar (this Slider
                                      // included), cancel the drag and
                                      // swallow the seek — onChangeEnd
                                      // never runs, so the progress
                                      // never moves (chen v1.0.7:
                                      // dragging the progress bar
                                      // sometimes does nothing). Same
                                      // cancel/re-arm pattern as the
                                      // outer seek/brightness drags
                                      // (onChangeEnd re-arms below).
                                      _hideTimer?.cancel();
                                      setState(() {
                                        _scrubbing = true;
                                        _scrubValue = _position;
                                      });
                                    },
                                    onChanged: (v) {
                                      setState(() => _scrubValue = v);
                                    },
                                    onChangeEnd: (v) async {
                                      setState(() => _scrubbing = false);
                                      // N-13: light tap on release, click
                                      // at either end of the timeline.
                                      HaoHaptics.sliderEnd(v, 0, _duration);
                                      await _session.seekTo(
                                        Duration(
                                          milliseconds: (v * 1000).round(),
                                        ),
                                      );
                                      _barrageController.seekTo(
                                        Duration(
                                          milliseconds: (v * 1000).round(),
                                        ),
                                      );
                                      _armHideTimer();
                                    },
                                  ),
                                ),
                              ),
                              Text(
                                '-${formatMmSs(_duration - (_scrubbing ? _scrubValue : _position))}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                            const Spacer(),
                            // Playback speed (Pure Live rates, tap to
                            // cycle 0.5x -> 2.0x).
                            TextButton(
                              onPressed: _cycleRate,
                              child: Text(
                                _rateLabel,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.fullscreen_exit,
                                color: Colors.white,
                              ),
                              tooltip: '退出全屏',
                              onPressed: _close,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              // Drag hints, above the control bars.
              if (_dragSeekTarget != null)
                Center(
                  child: _SeekHint(
                    target: _dragSeekTarget!,
                    delta: _dragSeekDelta,
                  ),
                ),
              // Drag hint pill: only this subtree listens to the drag
              // side/value — pointer ticks rebuild the pill, never the
              // page.
              ValueListenableBuilder<SystemDragSide?>(
                valueListenable: _drag.side,
                builder: (context, dragSide, _) {
                  if (dragSide == null) return const SizedBox.shrink();
                  return Center(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _drag.value,
                      builder: (context, value, _) => _SystemHint(
                        side: dragSide,
                        value: value,
                      ),
                    ),
                  );
                },
              ),
              if (_longPressSpeeding)
                const Center(child: _LongPressSpeedHint()),
            ],
          ),
        ),
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.onRetry, required this.onClose});

  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '播放失败，请检查网络后重试',
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('▶ 重试')),
            const SizedBox(height: 8),
            // A failed player must always offer a way out (the v1.0.5
            // trap: the top bar was hidden while failed, so the only
            // back button vanished exactly when playback failed).
            TextButton(
              onPressed: onClose,
              child: const Text('返回', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }
}


/// Skip intro/outro pill (1.1.6): white pill, black text — the player
/// surface is always black video, so the white-on-black treatment
/// matches the other player pills (_HintPill), not the theme accent.
class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: HaoPressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// Centre hint pill over the video (seek / 2x / brightness-volume):
/// dark glass — BackdropFilter blurs the video behind the pill, so the
/// white text stays legible over any frame. Theme GlassCard is NOT used
/// here: the player is a dark scene in both modes and GlassCard's light
/// -mode fill (near-white) would make the white text unreadable.
class _HintPill extends StatelessWidget {
  const _HintPill({required this.child, this.width});

  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return DarkGlass(
      radius: 12,
      child: SizedBox(width: width, child: child),
    );
  }
}

/// Center overlay shown while the user drags horizontally to seek:
/// target time + the delta from where the drag started.
class _SeekHint extends StatelessWidget {
  const _SeekHint({required this.target, required this.delta});

  final double target;
  final double delta;

  @override
  Widget build(BuildContext context) {
    final forward = delta >= 0;
    final deltaText = delta.abs() < 1
        ? ''
        : ' ${forward ? '+' : '-'}${delta.abs().round()}s';
    return _HintPill(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              forward ? Icons.fast_forward : Icons.fast_rewind,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
            Text(
              '${formatMmSs(target)}$deltaText',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Center card shown while the user drags vertically: brightness
/// (left half) or volume (right half), Pure Live style.
/// Centre pill shown while long-press 2x is active (Bilibili-style).
class _LongPressSpeedHint extends StatelessWidget {
  const _LongPressSpeedHint();

  @override
  Widget build(BuildContext context) {
    return _HintPill(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fast_forward, color: Colors.white),
          SizedBox(width: 8),
          Text(
            '2.0x',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        ),
      ),
    );
  }
}

class _SystemHint extends StatelessWidget {
  const _SystemHint({required this.side, required this.value});

  final SystemDragSide side;
  final double value;

  @override
  Widget build(BuildContext context) {
    final isBrightness = side == SystemDragSide.brightness;
    return _HintPill(
      width: 160,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isBrightness ? Icons.brightness_6 : Icons.volume_up,
            color: Colors.white,
          ),
          const SizedBox(height: 8),
          Text(
            isBrightness ? '亮度' : '音量',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: value,
            color: Colors.white,
            backgroundColor: Colors.white30,
          ),
          const SizedBox(height: 6),
          Text(
            '${(value * 100).round()}%',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        ),
      ),
    );
  }
}

class _EndedCard extends StatelessWidget {
  const _EndedCard({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '已播完',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onClose, child: const Text('返回详情')),
          ],
        ),
      ),
    );
  }
}
