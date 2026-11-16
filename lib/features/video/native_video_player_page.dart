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
import '../player/fullscreen_controller.dart';
import '../player/playback_session.dart';
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
  }

  Future<void> _saveProgress() async {
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

  Future<void> _close() async {
    await _saveProgress();
    widget.onClose?.call(_lineIdx, _epIdx, _position);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _statusSub?.cancel();
    _errorSub?.cancel();
    unawaited(_saveProgress());
    unawaited(_session.dispose());
    Get.delete<FullscreenController>();
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
                _FailureCard(onRetry: _retry),
              if (_ended && !_failed)
                _EndedCard(onClose: _close),
              if (_showControls && !_failed && !_ended) ...[
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
                // Bottom bar: play/pause, prev/next episode, elapsed.
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
            ],
          ),
        ),
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.onRetry});

  final VoidCallback onRetry;

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
