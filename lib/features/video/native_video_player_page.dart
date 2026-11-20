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

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/player/kernel/video_fit.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/glass.dart';
import '../music/music_player_controller.dart';
import '../player/fullscreen_controller.dart';
import '../player/playback_session.dart';
import '../player/screen_brightness.dart';
import '../../core/native/system_volume.dart';
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
  double _volume = 1.0;
  // System volume for the right-half vertical drag: _volume is only
  // the cached level (seed for the sync drag start); the drag itself
  // writes through SystemVolume, never the player gain.
  final SystemVolume _systemVolume = SystemVolume();
  double _brightness = 0.5;
  bool _closing = false;
  // Seek drag (horizontal swipe): preview the target, seek once on
  // release — never a seek per update (Pure Live: rapid seeks complete
  // with cancel errors when superseded).
  double? _dragSeekTarget;
  double _dragSeekStart = 0;
  double _dragSeekDelta = 0;
  // Brightness/volume drag (vertical swipe): left half brightness,
  // right half volume (Pure Live PlayerGestureLayer).
  _PlayerDragSide? _dragSide;
  // The drag HUD value (brightness or volume, 0-1). A ValueNotifier,
  // not a setState field: pointer ticks arrive at ~60-120 Hz and the
  // HUD is a small subtree — rebuilding the whole player page per
  // tick is what made the drag feel choppy (chen 2026-11-20). The
  // page build only reads the notifier object; the hint pill rebuilds
  // alone through the ValueListenableBuilder.
  final ValueNotifier<double> _dragValueNotifier = ValueNotifier<double>(0);
  Timer? _dragHintTimer;
  Timer? _hideTimer;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlaybackStatus>? _statusSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<double>? _volumeSub;
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
    _fullscreen = Get.put(FullscreenController());
    _rate = VideoPlaybackSettings.playbackRate;
    unawaited(_session.setRate(_rate));
    // System brightness for the left-half vertical drag (best-effort;
    // 0.5 when the native channel is unavailable, e.g. unit tests).
    unawaited(
      ScreenBrightness.getBrightness().then((v) {
        _brightness = v;
      }),
    );
    // System volume for the right-half vertical drag (best-effort;
    // falls back to the cached _volume when the native channel is
    // unavailable, e.g. unit tests). Hardware-key / Control Center
    // changes push back through volumeChanges -> _onExternalVolume.
    unawaited(
      _systemVolume.getVolume().then((v) {
        _volume = v;
      }),
    );
    _volumeSub = _systemVolume.volumeChanges.listen(_onExternalVolume);
    _statusSub = _session.onStatus.listen((status) {
      if (!mounted) return;
      if (status == PlaybackStatus.completed) {
        _onEpisodeEnded();
      } else if (status == PlaybackStatus.playing) {
        setState(() {
          _loading = false;
          _playing = true;
        });
      } else if (status == PlaybackStatus.paused) {
        setState(() => _playing = false);
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
  Future<bool> _openEpisodeUrl() async {
    final url = _episode.url;
    return _session.open(
      url: url,
      isLive: false,
      declaredFormat: _declaredFormat(url),
      headers: _playHeaders(),
    );
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

  Future<void> _openCurrent() async {
    // Pause any playing music the moment this film starts playing
    // (chen: only when a specific film starts — browsing the video
    // tab, categories or a detail page never pauses). Guarded by
    // registration: if no music controller exists, no music can be
    // playing. No auto-resume on exit; the user resumes manually.
    if (Get.isRegistered<MusicPlayerController>()) {
      unawaited(MusicPlayerController.ensure().pause());
    }
    final epoch = ++_openEpoch;
    setState(() {
      _loading = true;
      _failed = false;
      _loadingHint = '正在加载…';
      _ended = false;
      _position = 0;
      _duration = 0;
      _resumeSought = false;
    });
    var ok = await _openEpisodeUrl();
    if (!ok) {
      // Play URL dead — switch source and keep looking until one
      // plays (chen 2026-11-17: 换源播放，直到找到能播的为止).
      if (mounted) setState(() => _loadingHint = '正在换源播放…');
      ok = await _trySwitchSource();
    }
    if (epoch != _openEpoch || !mounted) return;
    if (!ok) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    // Speed is re-applied by the session's _swapBackend after a
    // backend swap; volume needs nothing — it is the system volume
    // now, not a per-backend gain.
    // Resume seek, once per episode: open() already verified the first
    // frame, so seeking now lands on a playing stream. Only for the
    // episode the detail page launched with a saved position (> 10 s
    // per the vodLocalLoad rule); later episodes start at 0.
    if (_resumePosition > 10 && !_resumeSought) {
      _resumeSought = true;
      await _session.seekTo(
        Duration(milliseconds: (_resumePosition * 1000).round()),
      );
    }
    await _recordHistory();
  }

  Future<void> _recordHistory() async {
    // Never throws: history I/O must never break playback or exit.
    try {
      final m = _detail.meta;
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
    } else {
      setState(() {
        _ended = true;
        _showControls = true;
      });
    }
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

  Future<void> _switchLine(int line) async {
    if (line == _lineIdx) return;
    await _saveProgress();
    _resumePosition = 0;
    setState(() {
      _lineIdx = line;
      _epIdx = 0;
    });
    await _openCurrent();
  }

  Future<void> _retry() async {
    // VOD: same-URL retry is correct (episode URLs do not expire
    // like live anti-codes — fix 18.7).
    await _openCurrent();
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
          _dragSide != null ||
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
    unawaited(_session.setRate(2.0));
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
    _armHideTimer();
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

  /// Hardware keys / Control Center moved the system volume outside
  /// the app: show the real value in the drag HUD (same 800 ms linger
  /// as _onSystemDragEnd). Ignored while a brightness drag is showing.
  void _onExternalVolume(double volume) {
    if (!mounted) return;
    if (_dragSide == _PlayerDragSide.brightness) return;
    // Own-set echoes never reach here (SystemVolume suppresses them);
    // a genuine hardware-key / Control Center change updates the HUD
    // value directly — no page rebuild beyond showing the pill.
    _dragValueNotifier.value = volume;
    _volume = volume;
    setState(() {
      _dragSide = _PlayerDragSide.volume;
    });
    _dragHintTimer?.cancel();
    _dragHintTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _dragSide = null);
    });
  }

  // -- Vertical drag: left half brightness, right half volume. --

  void _onSystemDragStart(DragStartDetails details) async {
    if (_failed || _ended) return;
    _hideTimer?.cancel();
    _dragHintTimer?.cancel();
    final width = MediaQuery.of(context).size.width;
    final isBrightness = details.globalPosition.dx < width / 2;
    // Windows: no screen-brightness API and no brightness UI — a
    // vertical drag starting on the left half is a no-op here (not
    // brightness, and never a fake HUD value). Right-half volume
    // still works.
    if (Platform.isWindows && isBrightness) return;
    // Brightness seed: re-read at drag start, never the init-time
    // capture. _brightness goes stale the moment the user moves
    // brightness in Control Center (or the system does): anchoring
    // the drag to the stale value would jump the screen brightness
    // back to the old level on the first move. Best-effort with a
    // short timeout — a stalled channel falls back to the cached
    // level instead of dropping the drag. Volume needs no re-read:
    // _volume is kept live by the volumeChanges stream (hardware
    // keys / Control Center push back through _onExternalVolume).
    var seed = isBrightness ? _brightness : _volume;
    if (isBrightness) {
      try {
        seed = await ScreenBrightness.getBrightness().timeout(
          const Duration(milliseconds: 300),
        );
      } catch (_) {}
      if (!mounted) return;
    }
    setState(() {
      _dragSide = isBrightness
          ? _PlayerDragSide.brightness
          : _PlayerDragSide.volume;
      if (isBrightness) _brightness = seed;
    });
    // The HUD value rides the notifier (no page rebuild); the side
    // above is the only setState at drag start.
    _dragValueNotifier.value = seed;
  }

  void _onSystemDragUpdate(DragUpdateDetails details) {
    final side = _dragSide;
    if (side == null) return;
    // HUD first, through the notifier only — the page is NOT rebuilt
    // per tick (see _dragValueNotifier). The platform call is
    // coalesced inside SystemVolume.setVolume, so a fast drag sends
    // the latest value instead of a queue of stale ones.
    final next = (_dragValueNotifier.value - details.delta.dy / 300)
        .clamp(0.0, 1.0);
    _dragValueNotifier.value = next;
    if (side == _PlayerDragSide.brightness) {
      _brightness = next;
      unawaited(ScreenBrightness.setBrightness(next));
    } else {
      _volume = next;
      unawaited(_systemVolume.setVolume(next));
    }
  }

  void _onSystemDragEnd(DragEndDetails details) {
    if (_dragSide == null) return;
    // Let the final value linger briefly, then hide the card.
    _dragHintTimer?.cancel();
    _dragHintTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _dragSide = null);
    });
    _armHideTimer();
  }

  void _onSystemDragCancel() {
    _dragHintTimer?.cancel();
    if (mounted) setState(() => _dragSide = null);
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
                // Drag handle (visual cue for the existing
                // swipe-down-to-dismiss gesture — no new control).
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(top: 10),
                    decoration: BoxDecoration(
                      color: theme.hairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
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
                            borderRadius: BorderRadius.circular(8),
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
        // Re-read the CURRENT brightness as the next drag's seed —
        // never set it. Whatever the user picked in Control Center
        // while backgrounded is the brightness now; re-applying the
        // old player value here would be the bug chen reported.
        unawaited(
          ScreenBrightness.getBrightness().then((v) {
            if (mounted) _brightness = v;
          }),
        );
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
    _dragHintTimer?.cancel();
    _dragValueNotifier.dispose();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _statusSub?.cancel();
    _errorSub?.cancel();
    _volumeSub?.cancel();
    _systemVolume.dispose();
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
              if (_loading)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: Colors.white),
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
                                      await _session.seekTo(
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
              if (_dragSide != null)
                Center(
                  // The pill alone listens to the drag value: pointer
                  // ticks rebuild only this subtree, never the page.
                  child: ValueListenableBuilder<double>(
                    valueListenable: _dragValueNotifier,
                    builder: (context, value, _) => _SystemHint(
                      side: _dragSide!,
                      value: value,
                    ),
                  ),
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

  final _PlayerDragSide side;
  final double value;

  @override
  Widget build(BuildContext context) {
    final isBrightness = side == _PlayerDragSide.brightness;
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

enum _PlayerDragSide { brightness, volume }

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
