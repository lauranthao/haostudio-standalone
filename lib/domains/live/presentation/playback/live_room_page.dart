// Live room page (fix 2 + study §3.2 + §2.8).
//
// Portrait on entry, ALWAYS: an ordinary in-app page whose top is a 16:9
// video surface with danmaku and room info below it (Pure Live
// LivePlayNormalLayout: Column of 16:9 video on top + Expanded danmaku/
// info area below). Entering a room NEVER forces landscape and NEVER
// rotates the app. ONLY the [ ] fullscreen button takes the room to
// landscape fullscreen (whole-app rotation); exiting returns to the same
// portrait room, same stream, no re-fetch, no restart.
//
// NO fullscreen modal on entry — the Swift `.fullScreen` modal WAS bug 2's
// root cause ("live room NOT playing inline small-screen — shows static
// cover + 正在 App 播放器中播放, no video").
//
// Quality / line rules (study §2.8):
// - Switch LINE = open playUrls[newIndex] directly, NO network request.
// - Switch QUALITY = re-parse (resolvePlayUrlsForRecovery).
// - Same quality+line = no-op. Epoch guard stops stale responses
//   overwriting a new room/selection.
// - Server ack differs from request -> UI corrects to the acked quality +
//   toast "清晰度已限制为…". URLs identical after a quality change -> toast
//   "清晰度流未变化" and abort.
// - Line buttons show only "线路 N", never CDN names.
// - Only the PREFERRED quality is persisted (preferResolution /
//   preferResolutionCellular); current quality+line live in memory per
//   room session and die with the room.
//
// Huya recovery (fix 3): on failure, next line first, then fresh re-parse
// (never the same URL), 60 s throttle, 10 s fallback restores the failure
// UI. Prefetch a new URL ~100 s after issue.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../../core/models/live_models.dart';
import '../../../../core/storage/hive_store.dart';
import '../../../../core/theme/hao_themes.dart';
import '../../../../shared/platforms/live_site.dart';
import '../../../../shared/platforms/sites.dart';
import '../../../../features/player/fullscreen_controller.dart';
import '../../../../features/player/playback_session.dart';
import '../../../../features/live/live_breadcrumb.dart';
import '../../../../features/live/live_recovery.dart';

/// Live room entry. [startLandscape] is ALWAYS false on entry (fix 2);
/// the parameter exists only so the flag is threaded explicitly and the
/// VOD direct-to-landscape path cannot leak into live.
///
/// [site] / [backendFactory] are test seams only: production passes
/// neither and gets Sites.of(platform) + the real native backends.
class LiveRoomPage extends StatefulWidget {
  const LiveRoomPage({
    super.key,
    required this.room,
    this.startLandscape = false,
    this.site,
    this.backendFactory,
  });

  final LiveRoom room;

  /// Must be false for live entry. Kept explicit per fix 2.
  final bool startLandscape;

  final LiveSite? site;
  final BackendFactory? backendFactory;

  @override
  State<LiveRoomPage> createState() => _LiveRoomPageState();
}

class _LiveRoomPageState extends State<LiveRoomPage> {
  late final LiveSite _site;
  late final PlaybackSession _session;
  late final FullscreenController _fullscreen;
  late final LiveRecovery _recovery;

  LiveRoom _room = const LiveRoom(roomId: '', platform: '');
  List<LivePlayQuality> _qualities = [];
  int _currentQuality = 0;
  int _selectionEpoch = 0;
  bool _loading = true;
  bool _failed = false;
  bool _showingStallNotice = false;
  String? _errorMessage;
  Timer? _prefetchTimer;

  final List<LiveMessage> _danmaku = [];
  final ScrollController _danmakuScroll = ScrollController();
  LiveDanmaku? _danmakuTransport;
  bool _danmakuEnded = false;

  @override
  void initState() {
    super.initState();
    _room = widget.room;
    _site = widget.site ?? Sites.of(widget.room.platform);
    _session = PlaybackSession(backendFactory: widget.backendFactory);
    _fullscreen = Get.put(FullscreenController());
    _recovery = LiveRecovery(site: _site, room: _room);
    _recovery.onPrefetchDue = _onPrefetchDue;
    _session.onError.listen(_onSessionError);
    _session.onStallNotice.listen((_) {
      if (mounted) setState(() => _showingStallNotice = true);
    });
    _session.onStatus.listen((status) {
      if (status == PlaybackStatus.playing && mounted) {
        setState(() {
          _loading = false;
          _showingStallNotice = false;
        });
      }
    });
    // Entry is portrait, always — even if startLandscape was (wrongly)
    // passed true, live entry stays portrait (fix 2).
    assert(
      !widget.startLandscape,
      'Live entry must be portrait; landscape only via the [ ] button.',
    );
    unawaited(LiveBreadcrumb.write('live-msg'));
    unawaited(LiveBreadcrumb.write('live-present'));
    unawaited(_loadRoom());
  }

  Future<void> _loadRoom() async {
    await LiveBreadcrumb.write('live-viewDidLoad');
    try {
      final detail = await _site.getRoomDetail(_room);
      if (!mounted) return;
      setState(() => _room = detail);
      // Danmaku is best-effort and independent of playback: it starts
      // from the room detail's danmakuData and must never crash the room.
      unawaited(_startDanmaku());
      final qualities = await _site.getPlayQualities(liveRoom: detail);
      if (!mounted) return;
      setState(() => _qualities = qualities);
      // Restore the PREFERRED quality (persisted), not the last session's.
      final preferred = HiveStore.getString(
        HiveKeys.preferResolution,
        '原画',
      );
      final preferredIndex = qualities.indexWhere(
        (q) => q.quality == preferred,
      );
      _currentQuality = preferredIndex >= 0 ? preferredIndex : 0;
      await _resolveAndPlay();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
          _errorMessage = '加载直播间失败，请检查网络后重试';
        });
      }
    }
  }

  /// Start the platform danmaku transport for this room. Args merge the
  /// room id with the room detail's play descriptor (`data`) and chat
  /// credentials (`danmakuData` — wins on key collision). Best-effort:
  /// any failure only marks danmaku ended; video is unaffected.
  Future<void> _startDanmaku() async {
    final transport = _site.getDanmaku();
    _danmakuTransport = transport;
    transport.onMessage = _onDanmakuMessage;
    transport.onClose = () {
      if (mounted) setState(() => _danmakuEnded = true);
    };
    final args = <String, dynamic>{
      'roomId': _room.roomId,
      'webRid': _room.roomId,
      ...?_room.data,
      ...?_room.danmakuData,
    };
    try {
      await transport.start(args);
    } catch (_) {
      if (mounted) setState(() => _danmakuEnded = true);
    }
  }

  /// Append one danmaku message, capped at 200 (oldest dropped first),
  /// and stick to the bottom while the user is already near it.
  void _onDanmakuMessage(LiveMessage message) {
    if (!mounted) return;
    final stick = !_danmakuScroll.hasClients ||
        _danmakuScroll.position.pixels >=
            _danmakuScroll.position.maxScrollExtent - 200;
    setState(() {
      _danmaku.add(message);
      if (_danmaku.length > 200) {
        _danmaku.removeRange(0, _danmaku.length - 200);
      }
    });
    if (stick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_danmakuScroll.hasClients) {
          _danmakuScroll.jumpTo(_danmakuScroll.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _resolveAndPlay() async {
    final epoch = ++_selectionEpoch;
    final quality = _qualities.isEmpty ? null : _qualities[_currentQuality];
    final resolution = await _site.resolvePlayUrls(
      liveRoom: _room,
      quality: quality,
    );
    if (epoch != _selectionEpoch || !mounted) return; // stale response
    if (resolution.urls.isEmpty) {
      setState(() {
        _loading = false;
        _failed = true;
        _errorMessage = '主播暂未开播或房间无法播放';
      });
      return;
    }
    // Server ack differs from request -> correct UI + toast.
    if (quality != null && resolution.appliedQualityData != null) {
      final acked = resolution.appliedQualityData.toString();
      final ackedIndex = _qualities.indexWhere(
        (q) => q.selectionId == acked || q.quality == acked,
      );
      if (ackedIndex >= 0 && ackedIndex != _currentQuality) {
        setState(() => _currentQuality = ackedIndex);
        Get.snackbar('提示', '清晰度已限制为${_qualities[ackedIndex].quality}');
      }
    }
    _recovery.lines = resolution.urls;
    _recovery.facts = resolution.streamFacts;
    _recovery.issuedAt = resolution.issuedAt ?? DateTime.now();
    _recovery.currentLineIndex = 0;
    // Arm the ~100 s proactive prefetch for this resolution (fix 3):
    // the initial resolve never goes through fetchFresh, so without
    // this the prefetch timer would never exist on the happy path.
    _recovery.schedulePrefetch();
    final firstUrl = resolution.urls.first;
    final ok = await _session.open(
      url: firstUrl,
      isLive: true,
      declaredFormat: resolution.factsFor(0).format,
      refreshUrls: _refreshUrls,
    );
    if (epoch != _selectionEpoch || !mounted) return;
    if (!ok) {
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// Fresh-URL callback for the session: re-parse, never the dead URL.
  Future<List<String>?> _refreshUrls() async {
    final fresh = await _recovery.fetchFresh();
    return fresh?.urls;
  }

  /// Prefetch point (~100 s after issue): fetch a fresh URL now so the
  /// transport never dies waiting for EOF. The prefetched URL is only
  /// swapped in after its first frame is verified (session ladder).
  Future<void> _onPrefetchDue() async {
    final fresh = await _recovery.fetchFresh();
    if (fresh == null || fresh.urls.isEmpty || !mounted) return;
    final index = _recovery.currentLineIndex % fresh.urls.length;
    final url = fresh.urls[index];
    if (url == _session.currentUrl) return;
    await _session.open(
      url: url,
      isLive: true,
      // Facts of the SAME line index, not factsFor(0): a refresh can
      // change this line's format (TX FLV -> TX HLS).
      declaredFormat: _recovery.factsFor(index).format,
      refreshUrls: _refreshUrls,
    );
  }

  void _onSessionError(String message) {
    if (!mounted) return;
    // Order: next line first (no request), then fresh re-parse.
    final next = _recovery.advanceLine();
    if (next != null) {
      unawaited(_session.open(
        url: next,
        isLive: true,
        declaredFormat:
            _recovery.factsFor(_recovery.currentLineIndex).format,
        refreshUrls: _refreshUrls,
      ));
      return;
    }
    setState(() {
      _failed = true;
      _errorMessage = message;
    });
  }

  /// Switch line: open playUrls[newIndex] directly, NO network request.
  Future<void> _switchLine(int index) async {
    if (index == _recovery.currentLineIndex) return; // no-op
    if (index < 0 || index >= _recovery.lines.length) return;
    final epoch = ++_selectionEpoch;
    _recovery.currentLineIndex = index;
    setState(() => _loading = true);
    final ok = await _session.open(
      url: _recovery.lines[index],
      isLive: true,
      declaredFormat: _recovery.factsFor(index).format,
      refreshUrls: _refreshUrls,
    );
    if (epoch != _selectionEpoch || !mounted) return;
    setState(() {
      _loading = !ok;
      _failed = !ok;
    });
  }

  /// Switch quality: re-parse. Identical URLs after the switch -> toast
  /// "清晰度流未变化" and abort.
  Future<void> _switchQuality(int index) async {
    if (index == _currentQuality) return; // no-op
    final epoch = ++_selectionEpoch;
    final before = List<String>.of(_recovery.lines);
    final quality = _qualities[index];
    final resolution = await _site.resolvePlayUrlsForRecovery(
      liveRoom: _room,
      quality: quality,
    );
    if (epoch != _selectionEpoch || !mounted) return; // stale response
    if (resolution.urls.isEmpty) {
      Get.snackbar('提示', '该清晰度暂无可用线路');
      return;
    }
    if (_sameUrlList(before, resolution.urls)) {
      Get.snackbar('提示', '清晰度流未变化');
      return;
    }
    setState(() {
      _currentQuality = index;
      _loading = true;
    });
    await HiveStore.put(HiveKeys.preferResolution, quality.quality);
    _recovery.lines = resolution.urls;
    _recovery.facts = resolution.streamFacts;
    _recovery.issuedAt = resolution.issuedAt ?? DateTime.now();
    _recovery.currentLineIndex = 0;
    _recovery.schedulePrefetch(); // new resolution, new 100 s prefetch
    final ok = await _session.open(
      url: resolution.urls.first,
      isLive: true,
      declaredFormat: resolution.factsFor(0).format,
      refreshUrls: _refreshUrls,
    );
    if (epoch != _selectionEpoch || !mounted) return;
    setState(() {
      _loading = !ok;
      _failed = !ok;
    });
  }

  bool _sameUrlList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Manual retry: same order as automatic recovery — next line, then
  /// FRESH re-parse, never the dead URL.
  Future<void> _manualRetry() async {
    setState(() {
      _failed = false;
      _loading = true;
      _errorMessage = null;
    });
    final next = _recovery.advanceLine();
    if (next != null) {
      await _session.open(
        url: next,
        isLive: true,
        declaredFormat:
            _recovery.factsFor(_recovery.currentLineIndex).format,
        refreshUrls: _refreshUrls,
      );
      return;
    }
    final fresh = await _recovery.fetchFresh();
    if (fresh != null && fresh.urls.isNotEmpty && mounted) {
      // fetchFresh already matched the line by URL identity — open the
      // matched line, not urls.first (the refresh may re-order lines).
      final index = _recovery.currentLineIndex % fresh.urls.length;
      await _session.open(
        url: fresh.urls[index],
        isLive: true,
        declaredFormat: _recovery.factsFor(index).format,
        refreshUrls: _refreshUrls,
      );
    } else if (mounted) {
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  void dispose() {
    _prefetchTimer?.cancel();
    _danmakuScroll.dispose();
    unawaited(_danmakuTransport?.stop());
    _recovery.dispose();
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
        backgroundColor: theme.scaffoldBackground,
        appBar: AppBar(
          title: Text(_room.title.isEmpty ? '直播间' : _room.title),
          actions: [
            IconButton(
              icon: const Icon(Icons.fullscreen),
              tooltip: '全屏',
              // The [ ] button is the ONLY path to landscape (fix 2).
              onPressed: () => _fullscreen.toggleFullscreen(),
            ),
          ],
        ),
        body: Column(
          children: [
            // 16:9 native video surface on top — in-page, portrait.
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _session.buildVideoWidget(),
                    if (_loading)
                      const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    if (_failed)
                      _FailureCard(
                        message: _errorMessage ?? '播放失败，请检查网络后点 ▶ 重试',
                        onRetry: _manualRetry,
                      ),
                    if (_showingStallNotice && !_failed)
                      const Positioned(
                        top: 8,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Text(
                            '重新连接…',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                      ),
                    // Play/pause tap on the video surface.
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () => _session.togglePlayPause(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Room info + quality / line controls below the video.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundImage: _room.avatar.isEmpty
                        ? null
                        : NetworkImage(_room.avatar),
                    child: _room.avatar.isEmpty
                        ? Text(_room.nick.isEmpty ? '?' : _room.nick[0])
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _room.nick.isEmpty ? '主播' : _room.nick,
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _room.watching > 0
                              ? '${_room.watching} 人在看'
                              : '',
                          style: TextStyle(
                            color: theme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_room.liveStatus)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        // Red ONLY for the LIVE badge (standing rule).
                        color: theme.liveRed,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'LIVE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Quality selector.
            if (_qualities.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _qualities.length,
                  itemBuilder: (context, i) {
                    final q = _qualities[i];
                    final selected = i == _currentQuality;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(q.quality),
                        selected: selected,
                        selectedColor: theme.accentSoft,
                        labelStyle: TextStyle(
                          color: selected
                              ? theme.accent
                              : theme.textSecondary,
                        ),
                        onSelected: (_) => _switchQuality(i),
                      ),
                    );
                  },
                ),
              ),
            // Line selector: buttons show only "线路 N", never CDN names.
            if (_recovery.lines.length > 1)
              SizedBox(
                height: 44,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _recovery.lines.length,
                  itemBuilder: (context, i) {
                    final selected = i == _recovery.currentLineIndex;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text('线路 ${i + 1}'),
                        selected: selected,
                        selectedColor: theme.accentSoft,
                        labelStyle: TextStyle(
                          color: selected
                              ? theme.accent
                              : theme.textSecondary,
                        ),
                        onSelected: (_) => _switchLine(i),
                      ),
                    );
                  },
                ),
              ),
            // Danmaku list below the video (per-platform transport
            // started from the room detail; capped at 200, newest last).
            Expanded(
              child: _danmaku.isEmpty
                  ? Center(
                      child: Text(
                        _loading
                            ? '弹幕加载中…'
                            : (_danmakuEnded ? '弹幕已断开' : '暂无弹幕'),
                        style: TextStyle(color: theme.textMuted),
                      ),
                    )
                  : ListView.builder(
                      controller: _danmakuScroll,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _danmaku.length,
                      itemBuilder: (context, i) {
                        final m = _danmaku[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            m.userName.isEmpty
                                ? m.message
                                : '${m.userName}: ${m.message}',
                            style: TextStyle(color: theme.textSecondary),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onRetry,
              child: const Text('▶ 重试'),
            ),
          ],
        ),
      ),
    );
  }
}
