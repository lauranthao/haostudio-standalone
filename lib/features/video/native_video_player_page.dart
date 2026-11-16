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

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/theme/hao_themes.dart';
import '../music/music_player_controller.dart';
import '../player/fullscreen_controller.dart';
import '../player/playback_session.dart';
import '../player/screen_brightness.dart';
import 'cms_sources.dart';
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

/// Opens [detail] at [initialLineIndex]/[initialEpisodeIndex] in
/// landscape fullscreen. [onClose] reports the last line/episode/
/// position so the detail page can refresh its resume state.
/// [initialPosition] (seconds) seeks once after open when > 10 s — the
/// detail page passes the saved resume position for the resumed episode.
/// [session] is a test seam only: production always passes null and the
/// page owns a fresh [PlaybackSession].
class NativeVideoPlayerPage extends StatefulWidget {
  const NativeVideoPlayerPage({
    super.key,
    required this.detail,
    this.initialLineIndex = 0,
    this.initialEpisodeIndex = 0,
    this.initialPosition = 0,
    this.onClose,
    this.session,
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

  @override
  State<NativeVideoPlayerPage> createState() => _NativeVideoPlayerPageState();
}

class _NativeVideoPlayerPageState extends State<NativeVideoPlayerPage> {
  late final PlaybackSession _session;
  late final FullscreenController _fullscreen;

  late int _lineIdx;
  late int _epIdx;
  late bool _autoNext;
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
  double _volume = 1.0;
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
  double _dragSystemValue = 0;
  Timer? _dragHintTimer;
  Timer? _hideTimer;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlaybackStatus>? _statusSub;
  StreamSubscription<String>? _errorSub;
  var _openEpoch = 0;

  VideoDetail get _detail => widget.detail;

  PlayEpisode get _episode =>
      _detail.lines[_lineIdx].episodes[_epIdx];

  String get _title => _detail.meta.name;

  String get _epLabel {
    final line = _detail.lines[_lineIdx];
    final prefix = _detail.lines.length > 1 ? '${line.name} · ' : '';
    return '$prefix${_episode.name}';
  }

  @override
  void initState() {
    super.initState();
    _lineIdx = widget.initialLineIndex.clamp(0, _detail.lines.length - 1);
    final eps = _detail.lines[_lineIdx].episodes;
    _epIdx = widget.initialEpisodeIndex.clamp(0, eps.length - 1);
    _autoNext = VideoPlaybackSettings.autoNext;
    _session = widget.session ?? PlaybackSession();
    _fullscreen = Get.put(FullscreenController());
    _rate = VideoPlaybackSettings.playbackRate;
    unawaited(_session.setRate(_rate));
    // System brightness for the left-half vertical drag (best-effort;
    // 0.5 when the native channel is unavailable, e.g. unit tests).
    unawaited(ScreenBrightness.getBrightness().then((v) {
      _brightness = v;
    }));
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
    final url = _episode.url;
    final ok = await _session.open(
      url: url,
      isLive: false,
      declaredFormat: _declaredFormat(url),
      headers: _playHeaders(),
    );
    if (epoch != _openEpoch || !mounted) return;
    if (!ok) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    // Re-apply the user's volume after a backend swap (episode
    // change / ladder rebuild resets the backend to full volume).
    // Speed is re-applied by the session's _swapBackend instead.
    if (_volume != 1.0) {
      unawaited(_session.setVolume(_volume));
    }
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

  Future<void> _toggleAutoNext() async {
    final next = !_autoNext;
    await VideoPlaybackSettings.setAutoNext(next);
    if (!mounted) return;
    setState(() => _autoNext = next);
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
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _playing) setState(() => _showControls = false);
    });
  }

  void _onSurfaceTap() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _armHideTimer();
  }

  String get _rateLabel => '${_rate}x';

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
      _dragSeekTarget =
          (_dragSeekStart + _dragSeekDelta).clamp(0.0, _duration);
    });
  }

  Future<void> _onSeekDragEnd(DragEndDetails details) async {
    final target = _dragSeekTarget;
    if (target == null) return;
    setState(() => _dragSeekTarget = null);
    try {
      await _session.seekTo(
        Duration(milliseconds: (target * 1000).round()),
      );
    } catch (_) {}
    _armHideTimer();
  }

  void _onSeekDragCancel() {
    if (mounted) setState(() => _dragSeekTarget = null);
    _armHideTimer();
  }

  // -- Vertical drag: left half brightness, right half volume. --

  void _onSystemDragStart(DragStartDetails details) {
    if (_failed || _ended) return;
    _hideTimer?.cancel();
    _dragHintTimer?.cancel();
    final width = MediaQuery.of(context).size.width;
    final isBrightness = details.globalPosition.dx < width / 2;
    setState(() {
      _dragSide =
          isBrightness ? _PlayerDragSide.brightness : _PlayerDragSide.volume;
      _dragSystemValue = isBrightness ? _brightness : _volume;
    });
  }

  void _onSystemDragUpdate(DragUpdateDetails details) {
    final side = _dragSide;
    if (side == null) return;
    setState(() {
      _dragSystemValue =
          (_dragSystemValue - details.delta.dy / 300).clamp(0.0, 1.0);
    });
    if (side == _PlayerDragSide.brightness) {
      _brightness = _dragSystemValue;
      unawaited(ScreenBrightness.setBrightness(_dragSystemValue));
    } else {
      _volume = _dragSystemValue;
      unawaited(_session.setVolume(_dragSystemValue));
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
    _armHideTimer();
  }

  void _openEpisodeSheet() {
    final theme = HaoTheme.of(context);
    final eps = _detail.lines[_lineIdx].episodes;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.surfaceSolid,
      builder: (context) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    '选集 (${eps.length})',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
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
                            color: selected
                                ? theme.accentSoft
                                : theme.surface,
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
                            color: selected
                                ? theme.accent
                                : theme.textPrimary,
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
        );
      },
    );
  }

  /// Exit the player. Never blocks on anything: playback is paused
  /// FIRST (bounded, so the film goes quiet the moment the user taps
  /// back instead of relying on dispose() racing the route pop —
  /// the v1.0.5 bug where the film kept playing in the background
  /// after exit), then fullscreen is exited (bounded, so a hung
  /// native channel cannot trap the user), then progress is saved
  /// best-effort, then the route pops. Every step is guarded — a
  /// storage or callback failure must never leave the user stuck on
  /// this page (the v1.0.5 "sometimes can't exit" bug: an unguarded
  /// Hive write throwing before pop, and a failed player hiding its
  /// only back button).
  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      await _session.pause().timeout(
            const Duration(seconds: 1),
          );
    } catch (_) {}
    try {
      await _fullscreen.exitFullscreen().timeout(
            const Duration(seconds: 2),
          );
    } catch (_) {}
    try {
      await _saveProgress();
    } catch (_) {}
    try {
      widget.onClose?.call(_lineIdx, _epIdx, _position);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _dragHintTimer?.cancel();
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
    final theme = HaoTheme.of(context);
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
              if (_failed)
                _FailureCard(onRetry: _retry, onClose: _close),
              if (_ended && !_failed)
                _EndedCard(onClose: _close),
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
                            color: _autoNext
                                ? Colors.white
                                : Colors.white38,
                          ),
                          tooltip: '自动连播',
                          onPressed: _toggleAutoNext,
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.list,
                            color: Colors.white,
                          ),
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
                                    label: Text(
                                      _detail.lines[i].name,
                                    ),
                                    selected: selected,
                                    selectedColor: theme.accentSoft,
                                    labelStyle: TextStyle(
                                      color: selected
                                          ? theme.accent
                                          : Colors.white70,
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
                                _playing
                                    ? Icons.pause
                                    : Icons.play_arrow,
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
                              formatMmSs(_scrubbing
                                  ? _scrubValue
                                  : _position),
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
                                    thumbShape:
                                        const RoundSliderThumbShape(
                                      enabledThumbRadius: 7,
                                    ),
                                    overlayShape:
                                        const RoundSliderOverlayShape(
                                      overlayRadius: 14,
                                    ),
                                    activeTrackColor: Colors.white,
                                    inactiveTrackColor: Colors.white30,
                                    thumbColor: Colors.white,
                                  ),
                                  child: Slider(
                                    value: (_scrubbing
                                            ? _scrubValue
                                            : _position)
                                        .clamp(0.0, _duration),
                                    max: _duration,
                                    onChangeStart: (_) {
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
                  child: _SystemHint(
                    side: _dragSide!,
                    value: _dragSystemValue,
                  ),
                ),
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
              child: const Text(
                '返回',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
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
    );
  }
}

/// Center card shown while the user drags vertically: brightness
/// (left half) or volume (right half), Pure Live style.
class _SystemHint extends StatelessWidget {
  const _SystemHint({required this.side, required this.value});

  final _PlayerDragSide side;
  final double value;

  @override
  Widget build(BuildContext context) {
    final isBrightness = side == _PlayerDragSide.brightness;
    return Container(
      width: 160,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
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
