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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../../../../core/models/live_models.dart';
import '../../../../core/storage/hive_store.dart';
import '../../../../core/theme/hao_themes.dart';
import '../../../../features/settings/source_stores.dart';
import '../../../../shared/platforms/live_site.dart';
import '../../../../shared/platforms/sites.dart';
import '../../../../features/player/fullscreen_controller.dart';
import '../../../../features/player/playback_session.dart';
import '../../../../features/live/live_breadcrumb.dart';
import '../../../../features/live/live_recovery.dart';
import '../../live_history_store.dart';
import 'danmaku_block_store.dart';
import 'danmaku_filter.dart';
import 'room_detail_sheet.dart';
import 'room_switch_panel.dart';

/// Live room entry. [startLandscape] is ALWAYS false on entry (fix 2);
/// the parameter exists only so the flag is threaded explicitly and the
/// VOD direct-to-landscape path cannot leak into live.
///
/// [playlist] is the room's source list (the live tab's room list) for
/// the L04 switch-room panel's "当前列表" group; empty when the room
/// was opened without one. [site] / [backendFactory] are test seams
/// only: production passes neither and gets Sites.of(platform) + the
/// real native backends.
class LiveRoomPage extends StatefulWidget {
  const LiveRoomPage({
    super.key,
    required this.room,
    this.startLandscape = false,
    this.playlist = const [],
    this.site,
    this.backendFactory,
  });

  final LiveRoom room;

  /// Must be false for live entry. Kept explicit per fix 2.
  final bool startLandscape;

  /// The room's source list for the switch-room panel.
  final List<LiveRoom> playlist;

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

  // Danmaku display settings (DanmakuSettings, Hive-backed): read on
  // entry and re-read live while the room is open, so a change in the
  // settings page takes effect without leaving the room.
  // Speed / area do NOT exist in DanmakuSettings: a list has no scroll
  // speed and no overlay area to size, so there is nothing to honour
  // for them — the settings page says so instead of faking sliders.
  bool _danmakuEnabled = true;
  double _danmakuFontSize = DanmakuSettings.defaultFontSize;
  double _danmakuOpacity = DanmakuSettings.defaultOpacity;
  bool _danmakuStarted = false;
  bool _roomDetailLoaded = false;
  ValueListenable<Box<dynamic>>? _danmakuSettingsListenable;

  // Chat-list style (S2): density, line spacing, show-username.
  String _listStyle = DanmakuSettings.listStyleCompact;
  String _listSpacing = DanmakuSettings.listSpacingStandard;
  bool _showUsernames = true;

  // Content filter (S3): block list + similarity + emote-only /
  // overlong + Douyu-bot, applied before a danmaku item renders.
  // One filter per room — its similarity cache dies with the room.
  late final DanmakuContentFilter _danmakuFilter;

  // S4: tap highlights one danmaku item (accent wash); tapping it
  // again clears the highlight. Long-press opens the block menu.
  int? _highlightedDanmakuIndex;

  @override
  void initState() {
    super.initState();
    _room = widget.room;
    _site = widget.site ?? Sites.of(widget.room.platform);
    _session = PlaybackSession(backendFactory: widget.backendFactory);
    _fullscreen = Get.put(FullscreenController());
    _recovery = LiveRecovery(site: _site, room: _room);
    _recovery.onPrefetchDue = _onPrefetchDue;
    _danmakuFilter = DanmakuContentFilter();
    _readDanmakuSettings();
    _subscribeDanmakuSettings();
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
    // Breadcrumb is best-effort telemetry: never let room entry wait on
    // a storage write.
    unawaited(LiveBreadcrumb.write('live-viewDidLoad'));
    try {
      final detail = await _site.getRoomDetail(_room);
      if (!mounted) return;
      _roomDetailLoaded = true;
      setState(() => _room = detail);
      // Entering a room records one history entry (L01 store; the
      // record moves a re-entry to the front). Best-effort and
      // idempotent — the L01 history page and the L04 switch panel
      // read the same store.
      unawaited(LiveHistoryStore.record(detail));
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

  /// Read the danmaku display settings for this room's platform.
  /// DanmakuSettings falls back to its defaults when Hive is not
  /// initialised, so this never crashes the room.
  void _readDanmakuSettings() {
    _danmakuEnabled = DanmakuSettings.isEnabled(_site.id);
    _danmakuFontSize = DanmakuSettings.fontSize();
    _danmakuOpacity = DanmakuSettings.opacity();
    _listStyle = DanmakuSettings.listStyle();
    _listSpacing = DanmakuSettings.listSpacing();
    _showUsernames = DanmakuSettings.showUsernames();
    // The filter re-reads its config (block list, similarity,
    // emote-only / overlong / Douyu-bot) from the same settings.
    _danmakuFilter.config = DanmakuFilterConfig.fromSettings();
  }

  /// Watch the danmaku keys while the room is open: a change in the
  /// settings page re-reads and applies immediately, no restart
  /// and no leaving the room. Guarded: when Hive is not initialised
  /// (unit tests without HiveStore.init) there is simply no live
  /// update and the defaults from [_readDanmakuSettings] apply.
  void _subscribeDanmakuSettings() {
    try {
      final listenable = HiveStore.box.listenable(keys: [
        HiveKeys.danmakuEnabled,
        HiveKeys.danmakuFontSize,
        HiveKeys.danmakuOpacity,
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
      ]);
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
    if (wasEnabled == _danmakuEnabled) {
      // Style / filter change only: restyle the list, re-apply the
      // block parts of the filter to what is already shown (a newly
      // blocked word/user disappears in place), and keep the
      // transport running untouched. Similarity is NOT re-applied to
      // shown items (see DanmakuContentFilter.blocksExisting).
      setState(() {
        _danmaku.removeWhere(
          (m) => _danmakuFilter.blocksExisting(m, platform: _site.id),
        );
        if (_highlightedDanmakuIndex != null &&
            _highlightedDanmakuIndex! >= _danmaku.length) {
          _highlightedDanmakuIndex = null;
        }
      });
      return;
    }
    if (_danmakuEnabled) {
      // Re-enabled while the room is open: start the transport, unless
      // the room detail has not loaded yet — _loadRoom starts it then.
      setState(() {});
      if (_roomDetailLoaded) unawaited(_startDanmaku());
    } else {
      // Disabled mid-room: stop the transport and drop the list, so
      // the "弹幕已关闭" state is honest instead of a stale list.
      unawaited(_danmakuTransport?.stop());
      _danmakuTransport = null;
      _danmakuStarted = false;
      _danmakuFilter.clear();
      _highlightedDanmakuIndex = null;
      setState(() {
        _danmaku.clear();
        _danmakuEnded = false;
      });
    }
  }

  /// Start the platform danmaku transport for this room. Args merge the
  /// room id with the room detail's play descriptor (`data`) and chat
  /// credentials (`danmakuData` — wins on key collision). Best-effort:
  /// any failure only marks danmaku ended; video is unaffected.
  Future<void> _startDanmaku() async {
    // Per-platform danmaku switch (DanmakuSettings): disabled means NO
    // transport at all — the room shows "弹幕已关闭" instead of a fake
    // empty list or an error. _danmakuStarted stops a second start
    // when the setting is toggled back on while the room is open (the
    // settings listener calls this too).
    if (!DanmakuSettings.isEnabled(_site.id) || _danmakuStarted) return;
    _danmakuStarted = true;
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
  /// and stick to the bottom while the user is already near it. The
  /// S3 content filter runs FIRST: a blocked message never reaches
  /// the list (and never enters the similarity cache).
  void _onDanmakuMessage(LiveMessage message) {
    if (!mounted) return;
    if (!_danmakuFilter.shouldShow(message, platform: _site.id)) return;
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
    // Fire-and-forget persistence: the quality switch must not wait on
    // storage I/O (and must keep working when storage is unavailable).
    unawaited(
      HiveStore.put(
        HiveKeys.preferResolution,
        quality.quality,
      ).catchError((_) {}),
    );
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

  /// L04: open the switch-room panel. Tapping a room replaces this
  /// room page with the new room (same playlist), so Back returns to
  /// the list, not through every switched room. Tapping the current
  /// room is a no-op.
  void _openSwitchPanel() {
    unawaited(
      showRoomSwitchPanel(
        context: context,
        currentRoom: _room,
        playlist: widget.playlist,
        onSelect: (next) {
          if (next.platform == _room.platform &&
              next.roomId == _room.roomId) {
            return;
          }
          Get.off(
            () => LiveRoomPage(
              room: next,
              playlist: widget.playlist,
              site: widget.site,
              backendFactory: widget.backendFactory,
            ),
          );
        },
      ),
    );
  }

  /// L05: open the room detail sheet (never covers the video).
  void _openRoomDetail() {
    unawaited(showRoomDetailSheet(context: context, room: _room));
  }

  /// S4: long-press a danmaku item — block this user / block this
  /// message / cancel, in place, without leaving the room. The block
  /// lands in [DanmakuBlockStore] (shared with the settings page),
  /// the filter config is re-read so later messages are filtered on
  /// arrival, and matching messages already shown are removed now.
  void _onDanmakuLongPress(LiveMessage message) {
    final theme = HaoTheme.of(context);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        backgroundColor: theme.surfaceStrong,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.userName.isNotEmpty)
                ListTile(
                  leading: Icon(
                    Icons.person_off_outlined,
                    color: theme.textPrimary,
                  ),
                  title: Text(
                    '屏蔽该用户 (${message.userName})',
                    style: TextStyle(color: theme.textPrimary),
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await _blockDanmakuUser(message.userName);
                  },
                ),
              ListTile(
                leading: Icon(
                  Icons.block_outlined,
                  color: theme.textPrimary,
                ),
                title: Text(
                  '屏蔽这句话',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  message.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.textSecondary),
                ),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _blockDanmakuMessage(message.message);
                },
              ),
              ListTile(
                leading: Icon(Icons.close, color: theme.textPrimary),
                title: Text(
                  '取消',
                  style: TextStyle(color: theme.textPrimary),
                ),
                onTap: () => Navigator.of(sheetContext).pop(),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _blockDanmakuUser(String userName) async {
    await DanmakuBlockStore.add(userName, 'user');
    _danmakuFilter.config = DanmakuFilterConfig.fromSettings();
    if (!mounted) return;
    setState(() {
      _danmaku.removeWhere((m) => m.userName.contains(userName));
      _highlightedDanmakuIndex = null;
    });
    Get.snackbar('已屏蔽', '已屏蔽用户 $userName');
  }

  Future<void> _blockDanmakuMessage(String text) async {
    await DanmakuBlockStore.add(text, 'word');
    _danmakuFilter.config = DanmakuFilterConfig.fromSettings();
    if (!mounted) return;
    setState(() {
      _danmaku.removeWhere((m) => m.message.contains(text));
      _highlightedDanmakuIndex = null;
    });
    Get.snackbar('已屏蔽', '已屏蔽该弹幕');
  }

  @override
  void dispose() {
    _prefetchTimer?.cancel();
    _danmakuSettingsListenable?.removeListener(_onDanmakuSettingsChanged);
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
              icon: const Icon(Icons.swap_horiz),
              tooltip: '切换',
              // L04: switch-room panel (follows / current list /
              // history / replay follows).
              onPressed: _openSwitchPanel,
            ),
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
                    // Play/pause tap on the video surface. It MUST sit
                    // below the failure card (and spinner / stall notice):
                    // as the last Stack child it was hit-tested first and
                    // its translucent tap recognizer won the gesture arena
                    // over the failure card's ▶ 重试 button, so a retry
                    // tap toggled play/pause instead of retrying.
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () => _session.togglePlayPause(),
                      ),
                    ),
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
                  ],
                ),
              ),
            ),
            // Room info + quality / line controls below the video.
            // L05: the whole info bar is tappable — it opens the room
            // detail sheet (never covering the video).
            InkWell(
              onTap: _openRoomDetail,
              child: Padding(
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
                    const SizedBox(width: 8),
                    Text(
                      '详情',
                      style: TextStyle(
                        color: theme.accent,
                        fontSize: 13,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: theme.accent,
                    ),
                  ],
                ),
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
            // Font size + opacity come from DanmakuSettings and update
            // live; when danmaku is disabled for this platform the
            // transport never starts and the room says so honestly.
            // S2: the list is a proper reviewable chat list — compact
            // or card density, line spacing, show-username toggle.
            // S3: every item passed the content filter before landing
            // here. S4: tap highlights an item; long-press opens the
            // block menu. The gestures live on the list items only —
            // the video surface keeps its own tap-to-play/pause, and
            // the list still scrolls (a drag is a scroll, not a tap).
            Expanded(
              child: !_danmakuEnabled
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '弹幕已关闭',
                            style: TextStyle(color: theme.textMuted),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '可在「设置 → 弹幕设置」中开启',
                            style: TextStyle(
                              color: theme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  : _danmaku.isEmpty
                      ? Center(
                          child: Text(
                            _loading
                                ? '弹幕加载中…'
                                : (_danmakuEnded ? '弹幕已断开' : '暂无弹幕'),
                            style: TextStyle(color: theme.textMuted),
                          ),
                        )
                      : Opacity(
                          opacity: _danmakuOpacity,
                          child: ListView.builder(
                            controller: _danmakuScroll,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _danmaku.length,
                            itemBuilder: (context, i) {
                              final m = _danmaku[i];
                              final highlighted =
                                  i == _highlightedDanmakuIndex;
                              final text = _showUsernames &&
                                      m.userName.isNotEmpty
                                  ? '${m.userName}: ${m.message}'
                                  : m.message;
                              // S2 line spacing (Pure Live ChatSpacing):
                              // compact halves the gaps (text 1.4 high),
                              // standard keeps them, loose x1.5 (1.7).
                              final gap = switch (_listSpacing) {
                                DanmakuSettings.listSpacingCompact => 2.0,
                                DanmakuSettings.listSpacingLoose => 12.0,
                                _ => 8.0,
                              };
                              final textHeight = switch (_listSpacing) {
                                DanmakuSettings.listSpacingCompact => 1.4,
                                DanmakuSettings.listSpacingLoose => 1.7,
                                _ => null,
                              };
                              final body = Text(
                                text,
                                style: TextStyle(
                                  color: theme.textSecondary,
                                  fontSize: _danmakuFontSize,
                                  height: textHeight,
                                ),
                              );
                              final Widget row;
                              if (_listStyle ==
                                  DanmakuSettings.listStyleCard) {
                                row = Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.surface,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: theme.hairline,
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 8,
                                        height: 8,
                                        margin: const EdgeInsets.only(
                                          top: 6,
                                          right: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: theme.accent,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      Expanded(child: body),
                                    ],
                                  ),
                                );
                              } else {
                                row = Padding(
                                  padding: EdgeInsets.symmetric(
                                    vertical: gap / 2,
                                  ),
                                  child: body,
                                );
                              }
                              return GestureDetector(
                                onTap: () => setState(() {
                                  _highlightedDanmakuIndex =
                                      highlighted ? null : i;
                                }),
                                onLongPress: () => _onDanmakuLongPress(m),
                                child: Container(
                                  color: highlighted
                                      ? theme.accentSoft
                                      : Colors.transparent,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: row,
                                ),
                              );
                            },
                          ),
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
