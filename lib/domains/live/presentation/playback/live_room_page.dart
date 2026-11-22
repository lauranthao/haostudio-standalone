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
//   toast "清晰度已限制为…". URLs identical after a quality change -> silent
//   abort (no toast: nothing changed).
// - Line buttons show only "线路 N", never CDN names.
// - Only the PREFERRED quality is persisted (preferResolution /
//   preferResolutionCellular); current quality+line live in memory per
//   room session and die with the room.
//
// Huya recovery (fix 3): on failure, next line first, then fresh re-parse
// (never the same URL), 60 s throttle, 10 s fallback restores the failure
// UI. Prefetch a new URL ~100 s after issue.

import '../../../../core/theme/hao_radius.dart';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flame_barrage/flame_barrage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import '../../../../widgets/hao_pressable.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../../../widgets/hao_toast.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/danmaku/danmaku_occlusion.dart';
import '../../../../core/danmaku/danmaku_occlusion_mask.dart';
import '../../../../core/logging/app_log.dart';
import '../../../../core/native/person_segmentation.dart';
import '../../../../core/models/live_models.dart';
import '../../../../core/player/kernel/player_engine.dart';
import '../../../../core/storage/hive_store.dart';
import '../../../../core/theme/hao_themes.dart';
import '../../../../core/theme/glass.dart';
import '../../../../features/settings/source_stores.dart';
import '../../../../features/settings/danmaku_settings_page.dart';
import '../../../../shared/platforms/live_site.dart';
import '../../../../shared/platforms/sites.dart';
import '../../data/playback_header_resolver.dart';
import '../../../../features/player/fullscreen_controller.dart';
import '../../../../features/player/playback_session.dart';
import '../../../../features/player/screen_brightness.dart';
import '../../../../features/player/system_drag_controller.dart';
import '../../../../features/video/widgets/referer_image.dart';
import '../../../../features/live/live_breadcrumb.dart';
import '../../../../features/live/live_recovery.dart';
import '../../../../features/music/music_player_controller.dart';
import '../../live_audio_sleep.dart';
import '../../live_history_store.dart';
import '../../live_metrics.dart';
import '../../live_network_quality.dart';
import '../../live_power_saving.dart';
import '../../live_recorder.dart';
import '../../live_volume_boost.dart';
import '../live_room_tools_sheet.dart';
import 'danmaku_block_store.dart';
import 'danmaku_filter.dart';
import 'live_fullscreen_clock.dart';
import 'live_multiview_page.dart';
import 'live_player_settings_sheet.dart';
import 'live_recording_center_page.dart';
import 'room_detail_sheet.dart';
import 'room_switch_panel.dart';

/// Live room entry. Entry is ALWAYS portrait (fix 2): there is no
/// parameter to request landscape — the VOD direct-to-landscape path
/// cannot leak into live, and only the [ ] button rotates the room.
///
/// [playlist] is the room's source list (the live tab's room list) for
/// the L04 switch-room panel's "当前列表" group; empty when the room
/// was opened without one. [site] / [backendFactory] are test seams
/// only: production passes neither and gets Sites.of(platform) + the
/// real native backends.
class LiveRoomPage extends StatefulWidget {
  /// P1-8: auto-recovery budget for one episode of consecutive session
  /// errors — how many recovery attempts run before the failure card.
  /// Multi-line rooms keep the old bound (one attempt per extra line:
  /// `lineCount - 1`). A single-line room (Kuaishou by design, Douyin
  /// often 1-2 lines) gets the session ladder's fresh budget
  /// (`freshRounds = 2`, playback_session.dart): held plan first, then
  /// a live re-parse. The old bound was 0 for `lineCount == 1`, so the
  /// FIRST error showed the failure card and `_recoverWithFreshUrls`
  /// never ran — a mid-playback stall (12 s watchdog) in a single-line
  /// room could only be fixed by a manual retry.
  @visibleForTesting
  static int autoRecoveryBudget(int lineCount) {
    if (lineCount == 1) return 2; // == PlaybackSession.open freshRounds
    return lineCount - 1;
  }

  const LiveRoomPage({
    super.key,
    required this.room,
    this.playlist = const [],
    this.site,
    this.backendFactory,
  });

  final LiveRoom room;

  /// The room's source list for the switch-room panel.
  final List<LiveRoom> playlist;

  final LiveSite? site;
  final BackendFactory? backendFactory;

  @override
  State<LiveRoomPage> createState() => _LiveRoomPageState();
}

class _LiveRoomPageState extends State<LiveRoomPage>
    with WidgetsBindingObserver {
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
  // Ladder progress text ("正在尝试 MPV…") shown under the spinner
  // while the session is trying engines; null when no attempt ran yet.
  String? _ladderHint;

  // Pure Live player overlay state (video_controller_panel +
  // PlayerGestureLayer, copied behaviour):
  // - single tap shows/hides the bars (a tap on a paused surface also
  //   resumes playback); double-tap toggles fullscreen; a vertical
  //   drag on the left half changes brightness, on the right half the
  //   volume; the bars auto-hide 5 s after being shown.
  // - the lock hides every bar and gesture except the unlock button.
  final GlobalKey _videoSurfaceKey = GlobalKey();
  bool _controlsVisible = true;
  bool _controlsLocked = false;
  Timer? _hideControlsTimer;
  // Fullscreen-entry worker: entering fullscreen always re-shows the
  // bars and restarts the 5 s auto-hide (see the worker setup in
  // initState). One worker on the flag covers every entry path —
  // the [ ] buttons and the double-tap all funnel through
  // FullscreenController.toggleFullscreen.
  Worker? _fullscreenWorker;
  bool _playing = false;
  bool _paused = false;
  // Background audio-only: true while the app is backgrounded and the
  // room was playing, so the foreground handler knows to restore the
  // video track (and to resume if mpv paused natively anyway).
  bool _backgroundAudioOnly = false;
  // Whether this room already paused the user's music on its first
  // transition to playing (chen: open a live room pauses music).
  bool _pausedMusicForRoom = false;
  // Danmaku display toggle (Pure Live PlayerDanmakuButton): display
  // only — the transport keeps running; hides the portrait list and
  // the fullscreen barrage alike.
  bool _danmakuVisible = true;
  // Build-29 live tools (I group): pure-audio + sleep timer, volume
  // boost, power saving, recording, fullscreen clock. All state
  // lives here (the tools sheet only displays it); all of it is
  // per-room and dies with the room except the persisted boost %
  // and clock corner.
  bool _audioOnlyManual = false;
  late final LiveSleepTimer _sleepTimer;
  int _boostPct = 100;
  // Last session volume _applyBoost actually wrote, and the engine
  // it was written to. A fresh backend starts at 1.0 (the room
  // never sets a player volume of its own — the drag drives the
  // SYSTEM volume), so the guard starts at the default engine's
  // 1.0: entering a room at boost 100% writes nothing to the
  // session. An engine swap resets the guard (the new backend must
  // get the boost even if the value matches the old backend's).
  PlayerEngine _lastBoostEngine = PlayerEngine.mediaKit;
  double _lastBoostVolume = 1.0;
  final LivePowerSaving _powerSaving = LivePowerSaving();
  LiveRecorder? _recorder;
  bool _isRecording = false;
  LiveClockCorner _clockCorner = LiveClockCorner.topRight;
  // D 组直播设置面板: cellular entry-downgrade opt-out (default ON
  // = today's behaviour). Read once at entry; the panel toggles the
  // same key for the NEXT room entry (the downgrade applies at
  // entry only, never mid-room).
  bool _cellularDowngrade = true;
  // Vertical drag brightness/volume (P1-U2): shared
  // [SystemDragController] with the VOD player — same seed, HUD and
  // sensitivity (300 px = full range). The vertical drag drives the
  // DEVICE volume, not the player gain. HUD linger 1 s (live value).
  final SystemDragController _drag = SystemDragController(
    hudLinger: const Duration(seconds: 1),
  );
  bool _dragInSystemZone = false;
  // Fullscreen barrage pool (Pure Live PlayerDanmakuSurface +
  // LivePlayerFacade.floatingDanmaku): rendered over the video in
  // fullscreen only; the portrait list below stays the danmaku
  // surface in portrait.
  final BarrageController _barrageController = BarrageController();
  // Danmaku occlusion avoidance (1.1.6, reduced version): same
  // controller as the VOD page — Vision person mask over
  // low-frequency MPV snapshots, whole-layer ShaderMask on the
  // flying danmaku. Live only matters in landscape fullscreen
  // (portrait has no flying danmaku, only the list below); the gate
  // below includes the fullscreen flag for exactly that reason.
  late final DanmakuOcclusionController _occlusion;
  // Automatic-recovery budget: consecutive session-error retries in
  // this episode. advanceLine() wraps around and never returns null
  // for >= 2 lines, so without a bound a failing room retries lines
  // forever and saturates the UI isolate — the app looks frozen
  // (spinner stuck, taps ignored, failure card never reachable).
  // Reset on healthy playback and on every user-initiated (re)open.
  int _consecutiveAutoFailures = 0;

  final List<LiveMessage> _danmaku = [];
  final ScrollController _danmakuScroll = ScrollController();
  LiveDanmaku? _danmakuTransport;
  bool _danmakuEnded = false;

  // Danmaku display settings (DanmakuSettings, Hive-backed): read on
  // entry and re-read live while the room is open, so a change in the
  // settings page takes effect without leaving the room.
  // Speed / stroke / colour exist in DanmakuSettings and apply ONLY
  // to the fullscreen flying danmaku (BarrageConfig): the portrait
  // list is a chat list of plain Text, so it has no scroll speed or
  // stroke to honour. Area is fullscreen-only the same way. Maximum
  // count caps both sides (list + flying, flying clamped to the
  // engine pool ceiling 72).
  bool _danmakuEnabled = true;
  double _danmakuFontSize = DanmakuSettings.defaultFontSize;
  double _danmakuOpacity = DanmakuSettings.defaultOpacity;
  double _danmakuArea = DanmakuSettings.defaultAreaFraction;
  bool _danmakuStroke = DanmakuSettings.defaultStroke;
  double _danmakuStrokeWidth = DanmakuSettings.defaultStrokeWidth;
  double _danmakuSpeed = DanmakuSettings.defaultSpeed;
  int _danmakuMaxCount = DanmakuSettings.defaultMaxCount;
  String _danmakuColorMode = DanmakuSettings.colorModeUniform;
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

  // Burst throttle (1.1.6): at most 30 chat messages per rolling
  // 1 s window reach the list / flying danmaku; the rest are
  // dropped (the filter already ran before the quota check, so a
  // dropped message never enters the similarity cache either).
  // Super-chat is exempt: gifts must never be throttled away.
  // No deferred batching: the room renders synchronously on emit
  // (the widget tests assert right after emit + pump), so a
  // Timer-based batch would break that contract; the quota bounds
  // setState to 30/s and the scroll-to-bottom callback is coalesced
  // instead (one pending post-frame callback at most).
  static const int danmakuBurstQuotaPerSecond = 30;
  DateTime? _danmakuBurstWindowStart;
  int _danmakuBurstCount = 0;
  bool _danmakuScrollPending = false;

  // While a quality switch's session.open is in flight, errors from
  // THAT open belong to the switch (open's bool return), not to the
  // still-playing old stream: _onSessionError must not run recovery
  // for them, or a failed switch would resurrect the failure card
  // after _switchQuality restored the old quality. Set to the
  // switch epoch before open, cleared right after it returns.
  int? _qualitySwitchEpoch;

  // S4: tap highlights one danmaku item (accent wash); tapping it
  // again clears the highlight. Long-press opens the block menu.
  int? _highlightedDanmakuIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _room = widget.room;
    _site = widget.site ?? Sites.of(widget.room.platform);
    _session = PlaybackSession(backendFactory: widget.backendFactory);
    _occlusion = DanmakuOcclusionController(
      segmentation: PersonSegmentation(),
      frameSource: () async =>
          _session.frameCapableBackend?.captureFrameJpeg(),
      isFrameCapable: () => _session.frameCapableBackend != null,
    );
    _fullscreen = Get.put(FullscreenController());
    // Entering fullscreen re-shows the bars and restarts the 5 s
    // auto-hide from that moment: the portrait bar is page chrome
    // (always visible when unlocked), so a hidden _controlsVisible
    // is invisible in portrait — but the fullscreen overlay bar is
    // gated on it, so without this, entering fullscreen after the
    // 5 s auto-hide opens with no controls until the video is
    // tapped. Exiting fullscreen leaves the bars alone. Locked
    // stays locked: the overlay gate hides the bars and only the
    // unlock button shows.
    _fullscreenWorker = ever<bool>(
      _fullscreen.isFullscreen,
      (isFs) {
        if (isFs && !_controlsLocked) _showControls();
      },
    );
    _recovery = LiveRecovery(site: _site, room: _room);
    AppLog.info('进入直播间：${_room.platform} ${_room.roomId}');
    _danmakuFilter = DanmakuContentFilter();
    // Build-29 tools: sleep timer (expiry pauses the session),
    // persisted volume boost + fullscreen clock corner.
    _sleepTimer = LiveSleepTimer(onExpire: _onSleepExpire);
    _boostPct = loadBoostPct();
    _clockCorner = loadClockCorner();
    _cellularDowngrade = liveCellularDowngradeEnabled();
    _readDanmakuSettings();
    _subscribeDanmakuSettings();
    _session.onError.listen(_onSessionError);
    _session.onStallNotice.listen((_) {
      if (mounted) setState(() => _showingStallNotice = true);
    });
    _session.onLadderAttempt.listen((engine) {
      if (mounted) {
        setState(() => _ladderHint = '正在尝试 ${engine.displayName}…');
      }
    });
    _session.onStatus.listen((status) {
      if (!mounted) return;
      final playing = status == PlaybackStatus.playing;
      setState(() {
        _playing = playing;
        _paused = status == PlaybackStatus.paused;
        if (playing) {
          _loading = false;
          // L-P0-2: an automatic recovery that re-opens successfully
          // lands here — clear the failure card with it. The only
          // other place that clears _failed is the manual retry; the
          // auto path had no clearing at all, so the black failure
          // overlay kept covering a playing stream.
          _failed = false;
          _showingStallNotice = false;
          _ladderHint = null;
          // Healthy playback resets the auto-recovery budget.
          _consecutiveAutoFailures = 0;
        }
      });
      if (playing) {
        // Build-29 volume boost: re-apply on every (re-)open, so a
        // ladder engine swap never silently drops the gain.
        unawaited(_applyBoost());
        // Pause any playing music the moment this live room starts
        // playing (chen: same rule as VOD — only when the stream
        // actually starts, never on browsing the live list or on
        // entering the room before playback starts). First playing
        // transition of this room only: line/quality switches and
        // recovery re-opens are the same room, not a new entry.
        // No auto-resume on exit; the user resumes manually.
        if (!_pausedMusicForRoom && Get.isRegistered<MusicPlayerController>()) {
          _pausedMusicForRoom = true;
          unawaited(MusicPlayerController.ensure().pause());
        }
        if (_controlsVisible) _armControlsHide();
      }
    });
    // Entry is portrait, always, by construction — there is no
    // landscape-entry parameter (fix 2).
    unawaited(LiveBreadcrumb.write('live-msg'));
    unawaited(LiveBreadcrumb.write('live-present'));
    unawaited(_loadRoom());
    // Keep the HUD on the real level when hardware keys / Control
    // Center move it. The drag itself reads the level live; the
    // controller owns the volume stream + per-side caches.
    _drag.init();
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
      final preferred = HiveStore.getString(HiveKeys.preferResolution, '原画');
      final preferredIndex = qualities.indexWhere(
        (q) => q.quality == preferred,
      );
      // No exact match: Pure Live maps the saved preference
      // proportionally onto the available qualities
      // (_fallbackQualityIndex) instead of blindly taking index 0.
      _currentQuality = preferredIndex >= 0
          ? preferredIndex
          : _fallbackQualityIndex(qualities, preferred);
      // Build-29 item 3: mobile data auto-drops a notch (Wi-Fi /
      // unknown keeps the preferred quality). Best-effort: a
      // detection failure reads as unknown and never downgrades.
      // D 组: the panel's opt-out switch gates this (default ON).
      final network = await detectNetworkType();
      if (network == LiveNetworkType.cellular &&
          liveCellularDowngradeEnabled()) {
        _currentQuality = entryQualityIndex(
          qualities,
          _currentQuality,
          network: network,
        );
      }
      await _resolveAndPlay();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
          // L-P2-6: one "加载失败" for every cause hid whether the
          // room is offline, the anchor is off air, or the parse
          // itself failed. Offline (transport/DNS) and parse failure
          // are told apart here; the off-air case never reaches this
          // catch — an empty resolution says "主播暂未开播或房间无法播放"
          // in _resolveAndPlay.
          _errorMessage = _isOfflineError(e) ? '网络异常，请检查网络后重试' : '解析失败，请重试';
        });
      }
    }
  }

  /// True when [e] looks like the device being offline (transport /
  /// DNS failure), as opposed to a parse / adapter failure. Dio
  /// wraps the underlying SocketException, so both the Dio type and
  /// the raw socket error count; the message fallback covers adapters
  /// that rethrow as plain text.
  static bool _isOfflineError(Object e) {
    if (e is SocketException || e is HttpException) return true;
    if (e is DioException) {
      return e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError ||
          e.error is SocketException;
    }
    final s = e.toString();
    return s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        s.contains('Network is unreachable');
  }

  /// Read the danmaku display settings for this room's platform.
  /// DanmakuSettings falls back to its defaults when Hive is not
  /// initialised, so this never crashes the room.
  void _readDanmakuSettings() {
    _danmakuEnabled = DanmakuSettings.isEnabled(_site.id);
    _danmakuFontSize = DanmakuSettings.fontSize();
    _danmakuOpacity = DanmakuSettings.opacity();
    _danmakuArea = DanmakuSettings.areaFraction();
    _danmakuStroke = DanmakuSettings.stroke();
    _danmakuStrokeWidth = DanmakuSettings.strokeWidth();
    _danmakuSpeed = DanmakuSettings.speed();
    _danmakuMaxCount = DanmakuSettings.maxCount();
    _danmakuColorMode = DanmakuSettings.colorMode();
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
      final listenable = HiveStore.box.listenable(
        keys: [
          HiveKeys.danmakuEnabled,
          HiveKeys.danmakuFontSize,
          HiveKeys.danmakuOpacity,
          HiveKeys.danmakuArea,
          HiveKeys.danmakuStroke,
          HiveKeys.danmakuStrokeWidth,
          HiveKeys.danmakuSpeed,
          HiveKeys.danmakuMaxCount,
          HiveKeys.danmakuColorMode,
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

  /// Append one danmaku message, capped at [_danmakuMaxCount]
  /// (oldest dropped first), and stick to the bottom while the user
  /// is already near it. The S3 content filter runs FIRST: a blocked
  /// message never reaches the list (and never enters the similarity
  /// cache). Burst throttle runs SECOND, chat only: at most
  /// [danmakuBurstQuotaPerSecond] chat messages per rolling 1 s
  /// window are kept; the rest are dropped outright (never listed,
  /// never flown). Super-chat is exempt from the quota.
  void _onDanmakuMessage(LiveMessage message) {
    if (!mounted) return;
    if (!_danmakuFilter.shouldShow(message, platform: _site.id)) return;
    if (message.type == LiveMessageType.chat) {
      final now = DateTime.now();
      final start = _danmakuBurstWindowStart;
      if (start == null ||
          now.difference(start) >= const Duration(seconds: 1)) {
        _danmakuBurstWindowStart = now;
        _danmakuBurstCount = 0;
      }
      if (_danmakuBurstCount >= danmakuBurstQuotaPerSecond) return;
      _danmakuBurstCount++;
    }
    final stick =
        !_danmakuScroll.hasClients ||
        _danmakuScroll.position.pixels >=
            _danmakuScroll.position.maxScrollExtent - 200;
    setState(() {
      _danmaku.add(message);
      if (_danmaku.length > _danmakuMaxCount) {
        _danmaku.removeRange(0, _danmaku.length - _danmakuMaxCount);
      }
    });
    // Fullscreen barrage (Pure Live PlayerDanmakuSurface): the same
    // message also flies over the video while fullscreen. The pool is
    // bounded by the engine (maxPendingCount 120 / maxPendingAge 5 s),
    // and nothing is sent in portrait — the list below is the danmaku
    // surface there.
    if (_fullscreen.isFullscreen.value && _danmakuEnabled && _danmakuVisible) {
      // Platform colour, flying only: the adapter's colour when it
      // has one. 0xFFFFFFFF is the adapters' "no colour" sentinel
      // (most leave it), so it falls back to the config white
      // instead of painting white-on-white. A platform-coloured
      // item forces a stroke: a pale platform colour over bright
      // video is unreadable without it.
      final platformColored =
          _danmakuColorMode == DanmakuSettings.colorModePlatform &&
          message.color != 0xFFFFFFFF;
      _barrageController.send(
        BarrageItem(
          content: _showUsernames && message.userName.isNotEmpty
              ? '${message.userName}: ${message.message}'
              : message.message,
          userName: message.userName,
          textColor: platformColored ? Color(message.color) : null,
          showStroke: platformColored ? true : null,
        ),
      );
    }
    // One pending scroll callback at most: a burst of N messages in
    // one frame used to queue N post-frame jumpTo calls.
    if (stick && !_danmakuScrollPending) {
      _danmakuScrollPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _danmakuScrollPending = false;
        if (!mounted) return;
        if (_danmakuScroll.hasClients) {
          _danmakuScroll.jumpTo(_danmakuScroll.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _resolveAndPlay() async {
    final epoch = ++_selectionEpoch;
    _consecutiveAutoFailures = 0; // new episode, fresh retry budget
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
      final ackedIndex = _ackedQualityIndex(
        _qualities,
        resolution.appliedQualityData,
      );
      if (ackedIndex >= 0 && ackedIndex != _currentQuality) {
        setState(() => _currentQuality = ackedIndex);
        HaoToast.show('提示', message:  '清晰度已限制为${_qualities[ackedIndex].quality}');
      }
    }
    _recovery.lines = resolution.urls;
    _recovery.facts = resolution.streamFacts;
    _recovery.issuedAt = resolution.issuedAt ?? DateTime.now();
    _recovery.refreshAt = resolution.refreshAt;
    _recovery.invalidAt = resolution.invalidAt;
    _recovery.quality = quality;
    _recovery.currentLineIndex = 0;
    _recovery.discardHeld(); // a hold belongs to the old resolution
    // Arm the lease prefetch for this resolution (Pure Live 5.6.5
    // fetch-and-hold): the initial resolve never goes through
    // fetchFresh, so without this the hold timer would never exist on
    // the happy path — and the URL would die at its ~125 s hard expiry
    // with nothing held for recovery.
    _recovery.schedulePrefetch();
    final firstUrl = resolution.urls.first;
    final ok = await _session.open(
      url: firstUrl,
      // L-P1-3: hand the ladder the whole resolution — every line is
      // tried (per engine) before any fresh re-parse, instead of
      // failing the room on urls.first alone.
      urls: resolution.urls,
      isLive: true,
      headers: _playbackHeaders,
      declaredFormat: resolution.factsFor(0).format,
      refreshUrls: _refreshUrls,
      excludeIjk: _excludeIjk,
    );
    if (epoch != _selectionEpoch || !mounted) return;
    if (!ok) {
      setState(() {
        _loading = false;
        _failed = true;
        _ladderHint = null;
      });
    }
  }

  /// IJK is excluded from Huya/Douyu live (L-P0-1): fijk's
  /// data-source call drops every request header, so those streams
  /// die ~7 s after opening on IJK (the CDN cuts header-less
  /// connections). The other three platforms keep the full ladder.
  bool get _excludeIjk => _site.id == 'huya' || _site.id == 'douyu';

  /// Playback headers for this room — Pure Live PlaybackHeaderResolver:
  /// Huya/Douyu streams MUST carry UA + Origin + Referer or the CDN
  /// cuts the connection after a few seconds (measured: Huya FLV dies
  /// at ~7 s with no headers, plays 25 s+ with them). Every session
  /// open in this room passes these headers; the Douyu cookie reuses
  /// this room's site instance so its dy_did matches the device id
  /// that signed the stream URL.
  Map<String, String> get _playbackHeaders => PlaybackHeaderResolver.resolve(
    platform: _site.id,
    roomId: _room.roomId,
    douyuCookie: _site is DouyuSite ? _site.playbackCookie : '',
  );

  /// Fresh-URL callback for the session ladder: the held prefetched
  /// plan first (Pure Live `_tryRefresh` attempt 0), else a live
  /// re-parse (attempt 1) — never the dead URL. The matched line goes
  /// first so the ladder opens the same line that was playing, not
  /// urls.first (a refresh may re-order lines).
  Future<List<String>?> _refreshUrls() async {
    final held = _recovery.takeHeld();
    if (held != null) return _matchedFirst(held.urls);
    final fresh = await _recovery.fetchFresh();
    if (fresh == null) return null;
    return _matchedFirst(fresh.urls);
  }

  /// The given URLs with the currently playing line moved to the front
  /// (the line `takeHeld` / `fetchFresh` already matched by URL
  /// identity). The session ladder opens `fresh.first`, so this is
  /// what makes it resume the same line instead of line 0.
  List<String> _matchedFirst(List<String> urls) {
    if (urls.isEmpty) return urls;
    final index = _recovery.currentLineIndex % urls.length;
    if (index == 0) return urls;
    final reordered = List<String>.of(urls);
    reordered.insert(0, reordered.removeAt(index));
    return reordered;
  }

  void _onSessionError(String message) {
    if (!mounted) return;
    // Errors from a quality switch's own open belong to the switch
    // (open's bool return) — not to the still-playing old stream.
    // Running recovery here would re-open the NEW (dead) lines and,
    // once the budget is spent, raise the failure card over a
    // healthy old stream that _switchQuality just restored.
    if (_qualitySwitchEpoch != null) return;
    AppLog.warn('直播异常：$message');
    // Order: next line first (no request), then fresh re-parse.
    // BOUND: after the recovery budget for this episode is spent, stop
    // and show the failure card. advanceLine() wraps around, so
    // without this the room retries lines forever — the retry storm
    // saturates the UI isolate and the whole app looks frozen
    // (spinner stuck, taps ignored, failure card never reachable).
    // The initial open already tried one line, so lines.length - 1
    // further advances cover every line exactly once; a single-line
    // room gets the ladder's fresh budget instead (P1-8 — see
    // LiveRoomPage.autoRecoveryBudget). Healthy playback resets the
    // counter, so this bounds one episode of consecutive failures.
    if (_consecutiveAutoFailures >=
        LiveRoomPage.autoRecoveryBudget(_recovery.lines.length)) {
      // Lines exhausted at this quality: show the failure card.
      AppLog.error('直播失败：$message');
      // Pure Live never auto-downgrades — recovery is re-parse +
      // sweep at the same quality, and when the sweep is exhausted
      // the room fails visibly instead of silently dropping quality
      // (the old auto-downgrade could never fire anyway: every
      // successful recovery reset its counter to 0).
      setState(() {
        _failed = true;
        _errorMessage = message;
      });
      return;
    }
    _consecutiveAutoFailures++;
    // Pure Live _runRecoverTask: refresh sources FIRST (fresh
    // signatures), then sweep from the current line. The old order
    // (next line first) re-opened the stalled line's possibly-expired
    // signature and burned the recovery budget on dead URLs.
    unawaited(_recoverWithFreshUrls(message));
  }

  /// Recovery with fresh URLs first. The held prefetched plan is spent
  /// first (Pure Live `_tryRefresh` attempt 0 — costs no request, no
  /// throttle); only when nothing usable is held do we live re-parse
  /// (attempt 1). `fetchFresh` is throttled to once per 60 s inside
  /// LiveRecovery: when the session's own ladder-exhaust path already
  /// refreshed, this returns null and we fall through to the next line
  /// — whose list `fetchFresh` already replaced with fresh URLs, so it
  /// is still a fresh line, never the dead one.
  Future<void> _recoverWithFreshUrls(String message) async {
    AppLog.info('直播恢复：重新解析播放地址');
    final fresh = _recovery.takeHeld() ?? await _recovery.fetchFresh();
    if (!mounted) return;
    if (fresh != null && fresh.urls.isNotEmpty) {
      // fetchFresh already matched the line by URL identity and
      // updated currentLineIndex + facts — open the matched line,
      // not urls.first (the refresh may re-order lines).
      final index = _recovery.currentLineIndex % fresh.urls.length;
      await _session.open(
        url: fresh.urls[index],
        isLive: true,
        headers: _playbackHeaders,
        declaredFormat: _recovery.factsFor(index).format,
        refreshUrls: _refreshUrls,
        excludeIjk: _excludeIjk,
      );
      return;
    }
    // L-P1-4: the two nulls are NOT the same. A throttled null means
    // a fresh resolution landed within the last 60 s, so the current
    // list is still fresh and the next line is worth opening. A
    // fetch-failure null (network error / timeout / empty parse)
    // means the list is old — Huya's anti-code is shared across ALL
    // lines and expires ~100-130 s after issue, so an old line is
    // almost certainly dead too; opening it only burns the recovery
    // budget and delays the failure card. Show the card instead.
    if (!_recovery.freshFetchThrottled) {
      if (mounted) {
        setState(() {
          _failed = true;
          _errorMessage = message;
        });
      }
      return;
    }
    final next = _recovery.advanceLine();
    if (next != null) {
      await _session.open(
        url: next,
        isLive: true,
        headers: _playbackHeaders,
        declaredFormat: _recovery.factsFor(_recovery.currentLineIndex).format,
        refreshUrls: _refreshUrls,
        excludeIjk: _excludeIjk,
      );
      return;
    }
    if (mounted) {
      setState(() {
        _failed = true;
        _errorMessage = message;
      });
    }
  }

  /// Switch line: open playUrls[newIndex] directly, NO network request.
  Future<void> _switchLine(int index) async {
    if (index == _recovery.currentLineIndex) return; // no-op
    if (index < 0 || index >= _recovery.lines.length) return;
    // New line = new picture: the old person mask is a stale
    // silhouette — drop it at once (the 500 ms expiry is only the
    // backstop).
    _occlusion.invalidateMask();
    final epoch = ++_selectionEpoch;
    _consecutiveAutoFailures = 0; // user-initiated, fresh retry budget
    _recovery.currentLineIndex = index;
    setState(() => _loading = true);
    final ok = await _session.open(
      url: _recovery.lines[index],
      isLive: true,
      headers: _playbackHeaders,
      declaredFormat: _recovery.factsFor(index).format,
      refreshUrls: _refreshUrls,
      excludeIjk: _excludeIjk,
    );
    if (epoch != _selectionEpoch || !mounted) return;
    setState(() {
      _loading = !ok;
      _failed = !ok;
    });
  }

  /// Switch quality: re-parse. Identical URLs after the switch ->
  /// silent abort (no toast: nothing changed).
  ///
  /// [persist] false skips saving the preference. There is NO
  /// automatic downgrade (Pure Live has none either): a stall recovers
  /// by re-parsing + sweeping lines at the same quality, and when the
  /// lines are exhausted the room shows the failure card.
  ///
  /// Server receipt vs request: the server may confirm a LOWER quality
  /// than requested (Douyu downgrades anonymous 原画 to 蓝光4M). The
  /// selection follows the CONFIRMED quality — same rule as entry —
  /// so the UI shows the quality actually playing, never the requested
  /// label. When the confirmed stream is identical to the one already
  /// playing, the cap is said plainly ("清晰度已限制为蓝光4M"); with
  /// no cap and identical URLs the switch is a silent abort. A resolve
  /// that throws (all CDNs failed) is a toast, not a silent no-op: the
  /// throw used to escape uncaught through unawaited(), leaving the
  /// room on the old quality with no feedback at all.
  ///
  /// Failure keeps the old picture (1.1.6): the switch snapshots the
  /// old quality + recovery plan BEFORE the optimistic update, and
  /// open failing restores the whole snapshot, never sets [_failed]
  /// (the old backend is untouched — PlaybackSession only swaps on
  /// first frame — so the old stream is still playing under the
  /// restore), and toasts "切换失败，已保持原清晰度". The preference
  /// is only persisted after a successful open, and stores the
  /// server-confirmed quality, never the requested one.
  Future<void> _switchQuality(int index, {bool persist = true}) async {
    if (index == _currentQuality) return; // no-op
    // New quality = new picture: drop the old person mask at once.
    _occlusion.invalidateMask();
    final epoch = ++_selectionEpoch;
    _consecutiveAutoFailures = 0; // user-initiated, fresh retry budget
    final before = List<String>.of(_recovery.lines);
    final quality = _qualities[index];
    late final LivePlayUrlResolution resolution;
    try {
      resolution = await _site.resolvePlayUrlsForRecovery(
        liveRoom: _room,
        quality: quality,
      );
    } catch (_) {
      if (epoch != _selectionEpoch || !mounted) return;
      HaoToast.show('提示', message:  '切换清晰度失败，请重试');
      return;
    }
    if (epoch != _selectionEpoch || !mounted) return; // stale response
    if (resolution.urls.isEmpty) {
      HaoToast.show('提示', message:  '该清晰度暂无可用线路');
      return;
    }
    // Server-confirmed quality (may be lower than requested).
    final ackedIndex = _ackedQualityIndex(
      _qualities,
      resolution.appliedQualityData,
    );
    final effectiveIndex = ackedIndex >= 0 ? ackedIndex : index;
    if (_sameUrlList(before, resolution.urls)) {
      if (ackedIndex >= 0 && ackedIndex != index) {
        HaoToast.show('提示', message: 
          '清晰度已限制为${_qualities[ackedIndex].quality}',
        );
      }
      // Identical URLs and no cap: nothing changed, nothing to say —
      // no toast, just abort.
      return;
    }
    // Snapshot the old picture BEFORE the optimistic update: on an
    // open failure every field below is restored, so the room (UI,
    // recovery plan, lease) is exactly as it was before the tap.
    // The old held prefetch plan cannot be restored (discardHeld
    // drops it and LiveRecovery keeps no copy) — the restored lease
    // re-arms schedulePrefetch, so the next hold is re-fetched
    // instead of served stale; recovery meanwhile re-parses.
    final prevQualityIndex = _currentQuality;
    final prevLines = List<String>.of(_recovery.lines);
    final prevFacts = List<LiveStreamFacts>.of(_recovery.facts);
    final prevQuality = _recovery.quality;
    final prevLineIndex = _recovery.currentLineIndex;
    final prevIssuedAt = _recovery.issuedAt;
    final prevRefreshAt = _recovery.refreshAt;
    final prevInvalidAt = _recovery.invalidAt;
    setState(() {
      _currentQuality = effectiveIndex;
      _loading = true;
    });
    if (ackedIndex >= 0 && ackedIndex != index) {
      HaoToast.show('提示', message: 
        '清晰度已限制为${_qualities[ackedIndex].quality}',
      );
    }
    _recovery.lines = resolution.urls;
    _recovery.facts = resolution.streamFacts;
    _recovery.issuedAt = resolution.issuedAt ?? DateTime.now();
    _recovery.refreshAt = resolution.refreshAt;
    _recovery.invalidAt = resolution.invalidAt;
    // Recovery re-parses with the quality ACTUALLY playing (the server
    // may have capped the request): re-requesting the capped rate keeps
    // landing on the same stream instead of re-downgrading every time.
    _recovery.quality = _qualities[effectiveIndex];
    _recovery.currentLineIndex = 0;
    _recovery.discardHeld(); // a hold belongs to the old quality
    _recovery.schedulePrefetch(); // new resolution, new lease prefetch
    // Errors from THIS open belong to the switch (its bool return),
    // not to the old stream — see _onSessionError.
    _qualitySwitchEpoch = epoch;
    final ok = await _session.open(
      url: resolution.urls.first,
      // b30: hand the ladder the whole resolution (L-P1-3, same as
      // the entry path): a switch that only tries urls.first fails
      // the whole quality when just the first line is dead, even
      // though the other lines play — the user sees "切换失败，已保持
      // 原清晰度" for a quality that was actually available.
      urls: resolution.urls,
      isLive: true,
      headers: _playbackHeaders,
      declaredFormat: resolution.factsFor(0).format,
      refreshUrls: _refreshUrls,
      excludeIjk: _excludeIjk,
    );
    _qualitySwitchEpoch = null;
    if (epoch != _selectionEpoch || !mounted) return;
    if (!ok) {
      // New stream dead: restore the old picture in full. The old
      // backend was never swapped out, so the old stream is still
      // playing — no failure card, no re-parse of the new quality.
      // _recovery may have been mutated by the session's own fresh
      // re-parse attempts during the failed open; the snapshot
      // overwrites all of it. schedulePrefetch re-arms the OLD
      // lease (it cancels the new-resolution timer first).
      _recovery.lines = prevLines;
      _recovery.facts = prevFacts;
      _recovery.issuedAt = prevIssuedAt;
      _recovery.refreshAt = prevRefreshAt;
      _recovery.invalidAt = prevInvalidAt;
      _recovery.quality = prevQuality;
      _recovery.currentLineIndex = prevLineIndex;
      _recovery.schedulePrefetch();
      setState(() {
        _currentQuality = prevQualityIndex;
        _loading = false;
        _failed = false;
        _ladderHint = null;
      });
      HaoToast.show('提示', message:  '切换失败，已保持原清晰度');
      return;
    }
    setState(() {
      _loading = false;
      _failed = false;
    });
    if (persist) {
      // Fire-and-forget persistence: the quality switch must not wait
      // on storage I/O (and must keep working when storage is
      // unavailable). Only after a successful open, and the
      // server-CONFIRMED quality — persisting the requested one
      // would re-request a capped rate on the next entry.
      unawaited(
        HiveStore.put(
          HiveKeys.preferResolution,
          _qualities[effectiveIndex].quality,
        ).catchError((_) {}),
      );
    }
  }

  /// Index of the quality the server actually confirmed, or -1 when the
  /// server confirmed nothing usable. The confirmed value is matched by
  /// selection id (Douyu: the opaque rate id; Huya: the quality id) or
  /// by label — the same rule the entry path uses. Covered by the room
  /// widget tests (entry ack + switch ack): the switch path and the
  /// entry path must agree on what is actually playing, never on what
  /// was merely requested.
  static int _ackedQualityIndex(
    List<LivePlayQuality> qualities,
    Object? appliedQualityData,
  ) {
    if (appliedQualityData == null) return -1;
    final acked = appliedQualityData.toString();
    return qualities.indexWhere(
      (q) => q.selectionId == acked || q.quality == acked,
    );
  }

  /// Default quality when the saved preference has no exact match —
  /// Pure Live `_setDefaultResolution` (player_controller.dart): map
  /// the saved preference's position in PL's system resolution list
  /// proportionally onto the room's available qualities. (The old
  /// 8M fallback was built on a wrong diagnosis — "蓝光50M" is NOT
  /// 50 Mbps, ffprobe measures ~8.2 Mbps — and PL plays the mapped
  /// quality, which for the default '原画' preference is index 0.)
  /// System list, verbatim from PL PlayerConsts.resolutions.
  static const List<String> _systemResolutions = [
    '原画',
    '蓝光8M',
    '蓝光4M',
    '超清',
    '流畅',
  ];

  static int _fallbackQualityIndex(
    List<LivePlayQuality> qualities,
    String preferred,
  ) {
    final preferLevel = _systemResolutions.indexOf(preferred);
    if (preferLevel < 0 || qualities.isEmpty) return 0;
    final preferRatio = preferLevel / (_systemResolutions.length - 1);
    return (preferRatio * (qualities.length - 1)).round().clamp(
      0,
      qualities.length - 1,
    );
  }

  bool _sameUrlList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Manual retry: same order as automatic recovery (Pure Live
  /// _runRecoverTask) — HELD prefetched plan first, then a FRESH
  /// re-parse, then the next line, never the dead URL. The fresh
  /// re-parse is FORCED (P1-T2): a manual retry is a deliberate user
  /// action, so it re-parses at once even inside the 60 s throttle
  /// window a successful automatic fetch stamped.
  Future<void> _manualRetry() async {
    setState(() {
      _failed = false;
      _loading = true;
      _errorMessage = null;
      _ladderHint = null;
      _consecutiveAutoFailures = 0; // user-initiated, fresh retry budget
    });
    final fresh =
        _recovery.takeHeld() ?? await _recovery.fetchFresh(force: true);
    if (fresh != null && fresh.urls.isNotEmpty && mounted) {
      // takeHeld/fetchFresh already matched the line by URL identity — open the
      // matched line, not urls.first (the refresh may re-order lines).
      final index = _recovery.currentLineIndex % fresh.urls.length;
      await _session.open(
        url: fresh.urls[index],
        isLive: true,
        headers: _playbackHeaders,
        declaredFormat: _recovery.factsFor(index).format,
        refreshUrls: _refreshUrls,
        excludeIjk: _excludeIjk,
      );
      return;
    }
    final next = _recovery.advanceLine();
    if (next != null) {
      await _session.open(
        url: next,
        isLive: true,
        headers: _playbackHeaders,
        declaredFormat: _recovery.factsFor(_recovery.currentLineIndex).format,
        refreshUrls: _refreshUrls,
        excludeIjk: _excludeIjk,
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
          if (next.platform == _room.platform && next.roomId == _room.roomId) {
            return;
          }
          // The panel already popped itself before calling onSelect
          // (showRoomSwitchPanel's wrapper pops the sheet, then
          // invokes this callback), so there is nothing left to pop
          // here — the old extra pop() removed the room page itself.
          //
          // Get.off defaults preventDuplicates: true and derives the
          // route name from the page builder's runtime type, so every
          // LiveRoomPage gets the same name; the room was entered via
          // Get.to with the same builder shape, so the guard compared
          // the names equal and silently returned null — the switch
          // did nothing (chen: "切换直播间也没用"). Pass
          // preventDuplicates: false: replacing a room page with
          // another room page is exactly what this action is for.
          Get.off(
            () => LiveRoomPage(
              room: next,
              playlist: widget.playlist,
              // NO site: the new room resolves its own adapter via
              // Sites.of(next.platform). Forwarding widget.site would
              // reuse the previous room's adapter when the panel
              // switches across platforms (e.g. Huya -> Douyu via
              // follows), and the new room would resolve URLs with
              // the wrong platform's signing. backendFactory stays:
              // it builds backends by engine, not by platform.
              backendFactory: widget.backendFactory,
            ),
            preventDuplicates: false,
          );
        },
      ),
    );
  }

  /// L05: open the room detail sheet (never covers the video).
  void _openRoomDetail() {
    unawaited(showRoomDetailSheet(context: context, room: _room));
  }

  // ---- Build-29 live tools (I group) ---------------------------------
  //
  // All of these are room-local state; the tools sheet only displays
  // them. Audio-only / sleep / boost / power-saving / recording /
  // fullscreen clock / multi-view / PiP verdicts.

  /// Sleep timer expiry: pause the session once, say so.
  void _onSleepExpire() {
    unawaited(_session.pause());
    HaoToast.show('定时关闭', message: '已按定时暂停直播');
  }

  /// Manual pure-audio toggle. The session path is MPV-only
  /// (IJK / AVPlayer no-op in the backend); the sheet's subtitle
  /// says so when the engine is not MPV. The background handler
  /// re-applies this flag on foreground return (see
  /// _enterForeground) so a manual audio-only is never lost to a
  /// background/foreground cycle.
  Future<void> _setAudioOnlyManual(bool value) async {
    _audioOnlyManual = value;
    await _session.setAudioOnly(value || _backgroundAudioOnly);
    if (mounted) setState(() {});
  }

  /// Apply the persisted volume boost for the live engine. Base
  /// player volume is 1.0 (the room never sets a player volume of
  /// its own — the drag drives the SYSTEM volume); the boost is a
  /// software gain on top, clamped to the engine's real ceiling
  /// (MPV 300% since volume-max=300 landed, IJK/AVPlayer 100% —
  /// see live_volume_boost). When the effective volume already
  /// equals what this engine has, the write is skipped: entering
  /// a room at boost 100% must not touch the session at all.
  Future<void> _applyBoost() async {
    final engine = _session.activeEngine ?? PlayerEngine.mediaKit;
    final effective = effectiveSessionVolume(
      baseVolume: 1.0,
      boostPct: _boostPct,
      engine: engine,
    );
    if (engine == _lastBoostEngine &&
        (effective - _lastBoostVolume).abs() < 0.001) {
      return;
    }
    _lastBoostEngine = engine;
    _lastBoostVolume = effective;
    await _session.setVolume(effective);
  }

  Future<void> _setBoostPct(int pct) async {
    _boostPct = clampBoostPct(pct);
    unawaited(saveBoostPct(_boostPct));
    await _applyBoost();
    if (mounted) setState(() {});
  }

  /// Power saving on/off: lowest quality + hide danmaku, restoring
  /// the exact previous quality + danmaku on exit. The quality
  /// switch never persists the power-saving tier (persist: false).
  Future<void> _setPowerSaving(bool value) async {
    if (value) {
      final target = _powerSaving.enter(
        qualityCount: _qualities.length,
        currentQualityIndex: _currentQuality,
      );
      setState(() => _danmakuVisible = false);
      if (target != null && target != _currentQuality) {
        await _switchQuality(target, persist: false);
      }
    } else {
      final prev = _powerSaving.exit();
      setState(() => _danmakuVisible = true);
      if (prev != null && prev != _currentQuality) {
        await _switchQuality(prev, persist: false);
      }
    }
    if (mounted) setState(() {});
  }

  /// Cellular-downgrade switch flipped mid-room (b30): applies to
  /// THIS room, not the next entry. On cellular, ON drops to the
  /// ceiling quality and OFF restores the saved preferred quality
  /// (same resolution as entry, see _loadRoom); on Wi-Fi / unknown
  /// the downgrade never applies, so nothing changes. Both go
  /// through _switchQuality with persist: false — the switch must
  /// not overwrite the user's preferred quality — and a failed
  /// switch keeps the old picture (_switchQuality restores it).
  Future<void> _applyCellularDowngradeNow(bool enabled) async {
    if (_qualities.isEmpty || !mounted) return;
    final network = await detectNetworkType();
    if (network != LiveNetworkType.cellular) return;
    final preferred = HiveStore.getString(HiveKeys.preferResolution, '原画');
    final preferredIndex = _qualities.indexWhere(
      (q) => q.quality == preferred,
    );
    final resolvedPreferred = preferredIndex >= 0
        ? preferredIndex
        : _fallbackQualityIndex(_qualities, preferred);
    final target = cellularDowngradeTargetIndex(
      qualities: _qualities,
      currentIndex: _currentQuality,
      preferredIndex: resolvedPreferred,
      network: network,
      enabled: enabled,
    );
    if (target != null) {
      await _switchQuality(target, persist: false);
    }
  }

  /// Start / stop recording the current stream to local storage
  /// (FLV raw copy / HLS segments, see LiveRecorder). The URL is
  /// the currently playing line.
  Future<void> _toggleRecording() async {
    if (_isRecording) {
      final file = await _recorder?.stop();
      _recorder = null;
      if (mounted) setState(() => _isRecording = false);
      HaoToast.show(
        '录制已保存',
        message: file?.path.split('/').last ?? '',
      );
      return;
    }
    final lines = _recovery.lines;
    if (lines.isEmpty) {
      HaoToast.show('提示', message: '当前没有可录制的流');
      return;
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/live_recordings');
      final recorder = LiveRecorder(dio: Dio(), directory: dir);
      final url = lines[_recovery.currentLineIndex % lines.length];
      await recorder.start(
        streamUrl: url,
        platform: _room.platform,
        roomId: _room.roomId,
        headers: _playbackHeaders,
      );
      _recorder = recorder;
      if (mounted) setState(() => _isRecording = true);
      HaoToast.show('开始录制', message: '录制保存到本地，可在录制中心查看');
    } catch (_) {
      HaoToast.show('提示', message: '录制启动失败');
    }
  }

  /// Open the multi-view page with this room first, then the
  /// playlist neighbours (up to 4 total). Opening one cell
  /// full-screen replaces the multi-view page with a single room.
  void _openMultiView() {
    final others = widget.playlist
        .where(
          (r) => r.platform != _room.platform || r.roomId != _room.roomId,
        )
        .toList();
    final rooms = [_room, ...others].take(4).toList();
    Get.to(
      () => LiveMultiViewPage(
        rooms: rooms,
        onOpenSingle: (room) => Get.to(
          () => LiveRoomPage(room: room, playlist: widget.playlist),
        ),
      ),
    );
  }

  /// The tools sheet (items 4/8/10/12/13/14/15). Built inside a
  /// StatefulBuilder so toggling a row refreshes the sheet itself,
  /// not just the room behind it.
  void _openToolsSheet() {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.35),
        builder: (sheetContext) => StatefulBuilder(
          builder: (context, setSheetState) {
            void refreshSheet() => setSheetState(() {});
            return LiveRoomToolsSheet(
              audioOnly: _audioOnlyManual,
              onAudioOnlyChanged: (v) async {
                await _setAudioOnlyManual(v);
                refreshSheet();
              },
              sleep: _sleepTimer.current,
              onSleepChanged: (d) {
                _sleepTimer.set(d);
                if (mounted) setState(() {});
                refreshSheet();
              },
              boostPct: _boostPct,
              onBoostChanged: (pct) async {
                await _setBoostPct(pct);
                refreshSheet();
              },
              engine: _session.activeEngine ?? PlayerEngine.mediaKit,
              baseVolume: 1.0,
              powerSaving: _powerSaving.isOn,
              onPowerSavingChanged: (v) async {
                await _setPowerSaving(v);
                refreshSheet();
              },
              isRecording: _isRecording,
              onToggleRecording: () async {
                await _toggleRecording();
                refreshSheet();
              },
              onOpenMultiView: () {
                Navigator.of(sheetContext).pop();
                _openMultiView();
              },
              onOpenRecordingCenter: () {
                Navigator.of(sheetContext).pop();
                Get.to(() => const LiveRecordingCenterPage());
              },
              clockCorner: _clockCorner,
              onClockCornerChanged: (c) {
                _clockCorner = c;
                unawaited(saveClockCorner(c));
                if (mounted) setState(() {});
                refreshSheet();
              },
            );
          },
        ),
      ),
    );
  }

  // -- D 组直播设置面板 (build 29) --------------------------------------
  //
  // Pure Live-style control-bar settings entry → bottom sheet, LIVE
  // ONLY (no speed / super-resolution / dialogue boost). Every row
  // writes the SAME Hive key the settings page reads
  // (DanmakuSettings keys / the persisted boost %) or the same room
  // state the tools sheet displays — one key, one room state, no
  // second copy — so a change takes effect on the current room
  // immediately and the settings page reads the same value after.
  // The tools sheet (I 组) is untouched; this panel is a second
  // entry to the same room state, not a second state.

  void _openLiveSettingsSheet() {
    // Guard for completion refreshes: a switch that finishes after
    // the sheet was popped must not call setSheetState on a disposed
    // sheet (a quality switch restores the old quality on failure,
    // after the optimistic update — the sheet needs that refresh,
    // but only while it is still open).
    var sheetOpen = true;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.35),
        builder: (sheetContext) => StatefulBuilder(
          builder: (context, setSheetState) {
            void refreshSheet() {
              if (sheetOpen) setSheetState(() {});
            }

            return LivePlayerSettingsSheet(
              settings: _liveSettingsSnapshot(refreshSheet),
            );
          },
        ),
      ).then((_) => sheetOpen = false),
    );
  }

  /// Cycle to the next quality tier (the panel's 画质 row). The
  /// room's [_switchQuality] keeps the fidelity semantics: the
  /// preference is only persisted after a successful open, and a
  /// failed switch restores the old quality.
  Future<void> _cycleLiveQuality() async {
    if (_qualities.length < 2) return;
    await _switchQuality((_currentQuality + 1) % _qualities.length);
  }

  LivePlayerSettings _liveSettingsSnapshot(void Function() refreshSheet) {
    final engine = _session.activeEngine ?? PlayerEngine.mediaKit;
    return LivePlayerSettings(
      qualityLabel: _qualities.isEmpty
          ? ''
          : _qualities[_currentQuality.clamp(0, _qualities.length - 1)]
                .quality,
      canCycleQuality: _qualities.length >= 2,
      onQualityCycle: () {
        // Optimistic refresh (the switch updates _currentQuality
        // before its open), plus a completion refresh so a failed
        // switch restoring the old quality shows up in the sheet.
        refreshSheet();
        unawaited(_cycleLiveQuality().then((_) => refreshSheet()));
      },
      danmakuEnabled: _danmakuEnabled,
      onDanmakuEnabledChanged: (value) {
        // The room's danmaku listener re-reads the gate live (same
        // path as a Settings change while the room is open).
        unawaited(DanmakuSettings.setEnabled(_site.id, value));
        refreshSheet();
      },
      similarityEnabled: DanmakuSettings.similarityEnabled(),
      onSimilarityChanged: (value) {
        // The filter config is re-read by the room's danmaku
        // listener (the key is in its listenable set).
        unawaited(DanmakuSettings.setSimilarityEnabled(value));
        refreshSheet();
      },
      blockEmoteOnly: DanmakuSettings.blockEmoteOnly(),
      onBlockEmoteChanged: (value) {
        unawaited(DanmakuSettings.setBlockEmoteOnly(value));
        refreshSheet();
      },
      blockLong: DanmakuSettings.blockLong(),
      onBlockLongChanged: (value) {
        unawaited(DanmakuSettings.setBlockLong(value));
        refreshSheet();
      },
      douyuBotFilter: DanmakuSettings.douyuBotFilter(),
      onDouyuBotChanged: (value) {
        unawaited(DanmakuSettings.setDouyuBotFilter(value));
        refreshSheet();
      },
      danmakuOcclusionAvoidance: HiveStore.getBool(
        HiveKeys.danmakuOcclusionAvoidance,
        false,
      ),
      onDanmakuOcclusionChanged: (value) {
        // The occlusion gate re-evaluates on the next build (see
        // build(): _occlusion.update runs there).
        unawaited(
          HiveStore.put(HiveKeys.danmakuOcclusionAvoidance, value),
        );
        if (mounted) setState(() {});
        refreshSheet();
      },
      audioOnly: _audioOnlyManual,
      onAudioOnlyChanged: (value) {
        unawaited(_setAudioOnlyManual(value));
        refreshSheet();
      },
      sleep: _sleepTimer.current,
      onSleepCycle: () {
        final order = LiveSleepDuration.values;
        final next = order[
            (order.indexOf(_sleepTimer.current) + 1) % order.length];
        _sleepTimer.set(next);
        if (mounted) setState(() {});
        refreshSheet();
      },
      boostPct: _boostPct,
      effectiveBoostPct: effectiveBoostPct(
        baseVolume: 1.0,
        boostPct: _boostPct,
        engine: engine,
      ),
      onBoostChanged: (pct) {
        unawaited(_setBoostPct(pct));
        refreshSheet();
      },
      powerSaving: _powerSaving.isOn,
      onPowerSavingChanged: (value) {
        unawaited(_setPowerSaving(value));
        refreshSheet();
      },
      cellularDowngrade: _cellularDowngrade,
      onCellularDowngradeChanged: (value) {
        // b30: applies to this room at once (see
        // _applyCellularDowngradeNow) — not the next entry.
        setState(() => _cellularDowngrade = value);
        unawaited(saveLiveCellularDowngrade(value));
        unawaited(_applyCellularDowngradeNow(value));
        refreshSheet();
      },
    );
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
        // isScrollControlled + scrollable content: without them a tall
        // sheet is capped at ~half the screen and the bottom rows are
        // clipped — same bug class as the music track sheet (v1.0.6).
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.35),
        builder: (sheetContext) => GlassSheetBackground(
          child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.userName.isNotEmpty)
                  ListTile(
                    leading: Icon(
                      shadows: HaoTheme.legibilityShadows(context),
                      Icons.person_off_outlined,
                      color: theme.textPrimary,
                    ),
                    title: Text(
                      '屏蔽该用户 (${message.userName})',
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary),
                    ),
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      await _blockDanmakuUser(message.userName);
                    },
                  ),
                ListTile(
                  leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.block_outlined, color: theme.textPrimary),
                  title: Text(
                    '屏蔽这句话',
                    style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary),
                  ),
                  subtitle: Text(
                    message.message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary),
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await _blockDanmakuMessage(message.message);
                  },
                ),
                ListTile(
                  leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.close, color: theme.textPrimary),
                  title: Text('取消', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary)),
                  onTap: () => Navigator.of(sheetContext).pop(),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
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
    HaoToast.show('已屏蔽', message:  '已屏蔽用户 $userName');
  }

  Future<void> _blockDanmakuMessage(String text) async {
    await DanmakuBlockStore.add(text, 'word');
    _danmakuFilter.config = DanmakuFilterConfig.fromSettings();
    if (!mounted) return;
    setState(() {
      _danmaku.removeWhere((m) => m.message.contains(text));
      _highlightedDanmakuIndex = null;
    });
    HaoToast.show('已屏蔽', message:  '已屏蔽该弹幕');
  }

  // ---- Pure Live player overlay: bars, lock, gestures ----
  // (video_controller_panel.dart + player_ui_controller.dart,
  // PlayerGestureLayer — behaviour copied, wired to this room's
  // session/recovery instead of Pure Live's global player service.)

  /// Show the bars and arm the 5 s auto-hide (Pure Live
  /// VideoController._controllerHideDelay).
  void _showControls() {
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    _armControlsHide();
  }

  void _hideControls() {
    _hideControlsTimer?.cancel();
    if (mounted) setState(() => _controlsVisible = false);
  }

  void _armControlsHide() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_controlsLocked) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  /// Single tap on the video surface (Pure Live panel onTap):
  /// visible bars + playing (mobile) -> hide the bars; otherwise show
  /// the bars, and a tap on a PAUSED surface also resumes playback.
  /// A buffering/opening surface only reveals the bars — play() there
  /// would falsely mark it playing.
  void _onVideoTap() {
    if (_controlsLocked) return;
    if (_controlsVisible && _playing) {
      _hideControls();
      return;
    }
    _showControls();
    if (_paused) unawaited(_session.play());
  }

  /// Double-tap toggles fullscreen (Pure Live panel onDoubleTap),
  /// unless the controls are locked.
  void _onVideoDoubleTap() {
    if (_controlsLocked) return;
    unawaited(_fullscreen.toggleFullscreen());
  }

  /// Whether a drag start lies inside the launcher home-gesture strip
  /// (Pure Live `startsInSystemHomeGestureZone`, zone height 48).
  bool _startsInSystemHomeGestureZone(Offset localPosition, Size size) {
    if (size.height <= 0) return false;
    const zoneHeight = 48.0;
    final zone = zoneHeight.clamp(0.0, size.height / 3);
    return localPosition.dy >= size.height - zone;
  }

  /// Vertical drag: left half brightness, right half volume (Pure Live
  /// PlayerGestureLayer). Volume is the SYSTEM volume. The seed,
  /// sensitivity (300 px = full range, shared with the VOD player)
  /// and HUD all live in [_drag]; this page only guards where a drag
  /// may start (system home-gesture zone, locked controls).
  Future<void> _onVerticalDragStart(DragStartDetails details) async {
    final size = _videoSurfaceKey.currentContext?.size;
    _dragInSystemZone =
        size != null &&
        _startsInSystemHomeGestureZone(details.localPosition, size);
    if (_dragInSystemZone || _controlsLocked) return;
    if (size == null || size.width <= 0) return;
    await _drag.startDrag(details.localPosition, size);
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_dragInSystemZone || _controlsLocked) return;
    final size = _videoSurfaceKey.currentContext?.size;
    if (size == null || size.height <= 0) return;
    _drag.updateDrag(details, size);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    _dragInSystemZone = false;
    _drag.endDrag();
  }

  /// Drag HUD icon (Pure Live PlayerGestureLayerState._icon).
  IconData get _dragHudIcon {
    final value = _drag.value.value;
    if (_drag.isBrightness) {
      if (value <= 0) return Icons.brightness_low;
      return value < 0.5 ? Icons.brightness_medium : Icons.brightness_high;
    }
    if (value <= 0) return Icons.volume_mute;
    return value < 0.5 ? Icons.volume_down : Icons.volume_up;
  }

  void _lockControls() {
    _hideControlsTimer?.cancel();
    setState(() {
      _controlsLocked = true;
      _controlsVisible = false;
    });
  }

  void _unlockControls() {
    setState(() => _controlsLocked = false);
    _showControls();
  }

  /// Bottom-bar buttons (Pure Live BottomActionBar): play/pause,
  /// refresh, danmaku; fullscreen adds the quality + line selectors;
  /// right lock + fullscreen toggle. Shared by the fullscreen
  /// overlay (white on the black gradient) and the portrait
  /// below-video bar (theme colour on the scaffold) — same buttons,
  /// order, tooltips and handlers; only the colour changes. The
  /// quality/line buttons render only in fullscreen (their Obx
  /// returns a shrink in portrait — portrait has its own chip rows
  /// below the video).
  List<Widget> _bottomBarButtons(Color color) => [
    IconButton(
      icon: Icon(
        shadows: HaoTheme.legibilityShadows(context),
        _playing ? Icons.pause : Icons.play_arrow,
        color: color,
      ),
      tooltip: _playing ? '暂停' : '播放',
      onPressed: () => _session.togglePlayPause(),
    ),
    IconButton(
      icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.refresh, color: color),
      tooltip: '刷新',
      onPressed: _manualRetry,
    ),
    IconButton(
      icon: Icon(
        shadows: HaoTheme.legibilityShadows(context),
        _danmakuVisible ? Icons.chat_bubble_outline : Icons.chat_bubble,
        color: color,
      ),
      tooltip: _danmakuVisible ? '关闭弹幕' : '打开弹幕',
      onPressed: () => setState(() => _danmakuVisible = !_danmakuVisible),
    ),
    // D 组直播设置面板 (build 29): Pure Live-style control-bar
    // settings entry → bottom sheet. Lives in the shared bottom
    // bar, so it shows in portrait (below the video) and in
    // fullscreen alike. The tools sheet (I 组) is untouched.
    IconButton(
      icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.settings, color: color),
      tooltip: '直播设置',
      onPressed: _openLiveSettingsSheet,
    ),
    Obx(() {
      final fs = _fullscreen.isFullscreen.value;
      if (!fs) return const SizedBox.shrink();
      return TextButton(
        onPressed: _qualities.isEmpty ? null : _openQualitySheet,
        child: Text(
          _qualities.isEmpty ? '清晰度' : _qualities[_currentQuality].quality,
          style: TextStyle(
            shadows: HaoTheme.legibilityShadows(context),
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }),
    Obx(() {
      final fs = _fullscreen.isFullscreen.value;
      if (!fs) return const SizedBox.shrink();
      return TextButton(
        onPressed: _recovery.lines.length < 2 ? null : _openLineSheet,
        child: Text(
          '线路 ${_recovery.currentLineIndex + 1}',
          style: TextStyle(
            shadows: HaoTheme.legibilityShadows(context),
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }),
    const Spacer(),
    IconButton(
      icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.lock_open, color: color),
      tooltip: '锁定控制条',
      onPressed: _lockControls,
    ),
    IconButton(
      icon: Obx(
        () => Icon(
          shadows: HaoTheme.legibilityShadows(context),
          _fullscreen.isFullscreen.value
              ? Icons.fullscreen_exit
              : Icons.fullscreen,
          color: color,
        ),
      ),
      tooltip: '全屏',
      onPressed: () => _fullscreen.toggleFullscreen(),
    ),
  ];

  /// Quality selector (Pure Live FullscreenStreamSelectorButton).
  void _openQualitySheet() {
    if (_qualities.isEmpty) return;
    final theme = HaoTheme.of(context);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        // isScrollControlled + scrollable content: 9 Huya qualities
        // alone are ~500px — without these the bottom rows are clipped
        // (same bug class as the music track sheet, v1.0.6).
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.35),
        builder: (sheetContext) => GlassSheetBackground(
          child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _qualities.length; i++)
                  ListTile(
                    selected: i == _currentQuality,
                    selectedTileColor: theme.accentSoft,
                    selectedColor: theme.accent,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(HaoRadius.large),
                    ),
                    title: Text(
                      _qualities[i].quality,
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textPrimary,
                        fontSize: 15,
                        fontWeight: i == _currentQuality
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    trailing: i == _currentQuality
                        ? Icon(shadows: HaoTheme.legibilityShadows(context), Icons.check, color: theme.accent)
                        : null,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_switchQuality(i));
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }

  /// Line selector (Pure Live FullscreenStreamSelectorButton).
  void _openLineSheet() {
    if (_recovery.lines.length < 2) return;
    final theme = HaoTheme.of(context);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        // isScrollControlled + scrollable content: same bug class as
        // the music track sheet (v1.0.6) — tall content was clipped.
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.35),
        builder: (sheetContext) => GlassSheetBackground(
          child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _recovery.lines.length; i++)
                  ListTile(
                    selected: i == _recovery.currentLineIndex,
                    selectedTileColor: theme.accentSoft,
                    selectedColor: theme.accent,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(HaoRadius.large),
                    ),
                    title: Text(
                      '线路 ${i + 1}',
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textPrimary,
                        fontSize: 15,
                        fontWeight: i == _recovery.currentLineIndex
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    trailing: i == _recovery.currentLineIndex
                        ? Icon(shadows: HaoTheme.legibilityShadows(context), Icons.check, color: theme.accent)
                        : null,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_switchLine(i));
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Leaving the room hands the brightness back to the system:
    // a room-set level must not leak onto every other page (or
    // survive to be re-applied on the next foreground return).
    unawaited(ScreenBrightness.reset());
    _hideControlsTimer?.cancel();
    _fullscreenWorker?.dispose();
    _fullscreenWorker = null;
    _sleepTimer.dispose();
    unawaited(_recorder?.stop());
    _drag.dispose();
    _barrageController.dispose();
    _occlusion.dispose();
    _danmakuSettingsListenable?.removeListener(_onDanmakuSettingsChanged);
    _danmakuScroll.dispose();
    unawaited(_danmakuTransport?.stop());
    _recovery.dispose();
    unawaited(_session.dispose());
    Get.delete<FullscreenController>();
    super.dispose();
  }

  // -- App lifecycle: keep LIVE playing in background -----------------
  //
  // Root cause of "切到后台直播就停": nothing in Dart pauses the
  // session — mpv itself pauses when its video output is suspended
  // in background (vo=libmpv cannot present frames, so the core
  // stalls the whole stream). Music keeps playing because it has no
  // video track. The fix is Pure Live's audio-only background mode:
  // on background, drop the video track (audio keeps flowing); on
  // foreground, restore it and resume if mpv paused natively anyway
  // (play() is a no-op when already playing).
  //
  // LIVE ONLY — VOD keeps its own behaviour (pause in background is
  // normal for video-on-demand; live is real-time and cannot be
  // sped up or re-watched, so it must not stop). This observer lives
  // on the room page, never on the shared session.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _session.setForeground(false);
        // Give the brightness back to the system NOW, not only on
        // dispose: the iOS plugin re-applies a remembered app
        // brightness on every foreground return, so a stale room
        // value would overwrite whatever the user picked in Control
        // Center while backgrounded. reset() clears the remembered
        // value, so the return keeps the user's system brightness.
        // (The live audio keeps playing in background — only the
        // screen brightness is handed back, never the stream.)
        unawaited(ScreenBrightness.reset());
        _enterBackground();
      case AppLifecycleState.resumed:
        _session.setForeground(true);
        // Do NOT re-apply any brightness here: whatever the user
        // picked in Control Center while backgrounded is the
        // brightness now. The next vertical drag re-reads the
        // current value at drag start (_onVerticalDragUpdate),
        // so no cached seed needs refreshing.
        unawaited(_enterForeground());
      case AppLifecycleState.inactive:
        // Transient (call, Control Center, app switcher): the room
        // is still foreground — do not touch the video track.
        break;
    }
  }

  void _enterBackground() {
    if (_backgroundAudioOnly) return;
    // Background: the occlusion loop stops at once — no background
    // snapshots / inference / battery burn. The room keeps playing
    // audio-only, so unlike VOD there is no pause path that would
    // stop the loop for us; this call is the only stop.
    _occlusion.stopLoop();
    // Only when the room is actually trying to play; a user-paused
    // room stays paused, and an error/finished room has nothing to
    // keep alive.
    final s = _session.status;
    if (s != PlaybackStatus.playing &&
        s != PlaybackStatus.buffering &&
        s != PlaybackStatus.opening) {
      return;
    }
    _backgroundAudioOnly = true;
    unawaited(_session.setAudioOnly(true));
  }

  Future<void> _enterForeground() async {
    if (!_backgroundAudioOnly) return;
    _backgroundAudioOnly = false;
    // Build-29: a MANUAL audio-only stays on across the
    // background/foreground cycle (only the automatic background
    // audio-only is lifted here).
    await _session.setAudioOnly(_audioOnlyManual);
    // Foreground return re-evaluates the occlusion gate (the switch
    // may have changed in Settings while away).
    _occlusion.update(
      danmakuVisible:
          _fullscreen.isFullscreen.value &&
          _danmakuEnabled &&
          _danmakuVisible,
      playing: _playing,
    );
    // If mpv paused natively anyway (non-MPV engine, or a vo error
    // before the audio-only switch landed), resume: play() on an
    // already-playing player is a no-op.
    final s = _session.status;
    if (s == PlaybackStatus.playing ||
        s == PlaybackStatus.buffering ||
        s == PlaybackStatus.opening) {
      unawaited(_session.play());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    // The video surface is shared by both layouts: 16:9 in-page in
    // portrait, filling the screen in landscape fullscreen (a 16:9 box
    // would overflow the short side in landscape). Pure Live's
    // landscape video is `expandToParent` (SizedBox.expand) with NO
    // AppBar above it — the old fullscreen kept the AppBar, so the
    // video never filled the screen ("横屏显示不好").
    // Fullscreen-dependent children read the Rx flag through Obx so
    // the Video widget itself is never rebuilt on a fullscreen
    // toggle (same controller, same player, no restart).
    final videoSurface = Container(
      key: _videoSurfaceKey,
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _session.buildVideoWidget(),
          // Fullscreen barrage over the video (Pure Live
          // PlayerDanmakuSurface). Pointer events off so the gesture
          // layer below keeps working.
          Obx(() {
            final fs = _fullscreen.isFullscreen.value;
            // Danmaku occlusion gate (1.1.6): runs FIRST, before the
            // early return — exiting fullscreen must stop the loop,
            // and this Obx re-runs on every fullscreen toggle (Rx)
            // and on every page rebuild (danmaku toggle / playing
            // state), so this one call site sees all gates. Live
            // video fit is always contain; portrait has no flying
            // danmaku, so the gate includes the fullscreen flag.
            _occlusion.update(
              danmakuVisible: fs && _danmakuEnabled && _danmakuVisible,
              playing: _playing,
            );
            if (!fs || !_danmakuEnabled || !_danmakuVisible) {
              return const SizedBox.shrink();
            }
            return Positioned.fill(
              child: IgnorePointer(
                child: DanmakuOcclusionMask(
                  controller: _occlusion,
                  fit: BoxFit.contain,
                  child: FlameBarrageWidget(
                    controller: _barrageController,
                    enablePointerEvents: false,
                    config: BarrageConfig(
                      // Pure Live PlayerDanmakuSurface values.
                      emitInterval: 0.05,
                      fontSize: _danmakuFontSize,
                      opacity: _danmakuOpacity,
                      // Uniform flying colour is white in every theme
                      // (the video behind it is dark); platform mode
                      // overrides per item in _onDanmakuMessage.
                      textColor: Colors.white,
                      // Stroke / speed / max count (1.1.6, fullscreen
                      // flying only): stroke colour is fixed black.
                      showStroke: _danmakuStroke,
                      strokeColor: Colors.black,
                      strokeWidth: _danmakuStrokeWidth,
                      baseSpeed:
                          DanmakuSettings.baseSpeedPxPerSecond *
                          _danmakuSpeed,
                      maxVisibleCount: _danmakuMaxCount.clamp(
                        1,
                        DanmakuSettings.enginePoolMaxSize,
                      ),
                      // Danmaku area setting: the fraction of the video
                      // the flying danmaku may cover (full / top half /
                      // top third / top fifth). The engine re-derives the track
                      // layout live when it changes (forceRefresh).
                      area: _danmakuArea,
                      rasterizeItems: true,
                      maxPendingCount: 120,
                      maxPendingAge: const Duration(seconds: 5),
                      pictureCacheMaxSize: 96,
                      barragePoolMaxSize: 72,
                      textCacheMaxSize: 320,
                      trackHeight: (_danmakuFontSize * 1.55)
                          .clamp(24.0, 64.0)
                          .toDouble(),
                      emojiSize: (_danmakuFontSize * 1.3)
                          .clamp(16.0, 48.0)
                          .toDouble(),
                    ),
                    emojiAtlas: EmojiAtlas.instance,
                  ),
                ),
              ),
            );
          }),
          // Gesture layer (Pure Live panel GestureDetector +
          // PlayerGestureLayer): opaque on purpose — this detector is
          // what reveals and hides the bars. It sits BELOW the bars,
          // the lock button, the failure card and the spinner, so those
          // keep their taps (the old translucent detector as the last
          // Stack child won the gesture arena over the retry button).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onVideoTap,
              onDoubleTap: _onVideoDoubleTap,
              onVerticalDragStart: _onVerticalDragStart,
              onVerticalDragUpdate: _onVerticalDragUpdate,
              onVerticalDragEnd: _onVerticalDragEnd,
              onVerticalDragCancel: () {
                _dragInSystemZone = false;
                _drag.cancelDrag();
              },
            ),
          ),
          // Drag HUD (Pure Live PlayerGestureLayer card). Only this
          // card listens to the drag state: ticks rebuild the card,
          // never the room page. The HUD hides the moment the shared
          // controller clears the side (the old 300 ms fade is gone
          // with the shared controller; the 1 s linger stays).
          ValueListenableBuilder<SystemDragSide?>(
            valueListenable: _drag.side,
            builder: (context, dragSide, _) {
              if (dragSide == null) return const SizedBox.shrink();
              return Center(
                child: IgnorePointer(
                  // Over-video HUD: dark glass — the blur is real
                  // (BackdropFilter over the video), black stays
                  // legible over any frame in every theme/mode.
                  child: DarkGlass(
                    radius: 16,
                    // Only this card listens to the drag value: ticks
                    // rebuild the card, never the room page.
                    child: ValueListenableBuilder<double>(
                      valueListenable: _drag.value,
                      builder: (context, value, _) => Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_dragHudIcon, shadows: HaoTheme.legibilityShadows(context),  color: Colors.white),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(HaoRadius.standard),
                                child: SizedBox(
                                  width: 100,
                                  height: 20,
                                  child: LinearProgressIndicator(
                                    value: value,
                                    backgroundColor: Colors.white38,
                                    valueColor: const AlwaysStoppedAnimation(
                                      Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Text(
                              '${(value * 100).round()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          // Top bar — fullscreen only (portrait already has the AppBar;
          // Pure Live fullscreen has no AppBar, its TopActionBar is the
          // overlay). Back exits fullscreen; title is the room title.
          Obx(() {
            final fs = _fullscreen.isFullscreen.value;
            if (!fs || !_controlsVisible || _controlsLocked) {
              return const SizedBox.shrink();
            }
            return Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.arrow_back, shadows: HaoTheme.legibilityShadows(context),  color: Colors.white),
                        tooltip: '退出全屏',
                        onPressed: () => _fullscreen.toggleFullscreen(),
                      ),
                      Expanded(
                        child: Text(
                          _room.title.isEmpty ? '直播间' : _room.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      // Build-29 tools sheet, fullscreen too.
                      IconButton(
                        icon: Icon(Icons.more_horiz, shadows: HaoTheme.legibilityShadows(context),  color: Colors.white),
                        tooltip: '直播工具',
                        onPressed: _openToolsSheet,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          // Bottom bar — fullscreen overlay ONLY (Pure Live
          // BottomActionBar: left play/pause, refresh, danmaku;
          // fullscreen adds the quality + line selectors; right lock
          // + fullscreen toggle). Portrait no longer overlays it: it
          // sat on the video's bottom strip, colliding with the
          // stream's own bottom HUD (chen 2026-11-20 — the game's
          // skill buttons). In portrait the bar lives below the
          // video (see the Column below), so the overlay only renders
          // in fullscreen, where the video fills the screen and
          // there is no "below" to move it to.
          //
          // The fullscreen gate MUST live in its own Obx (like the
          // top bar above): videoSurface is built once per build()
          // and reused by the outer Obx, so a plain `if` on
          // isFullscreen would never re-evaluate on a fullscreen
          // toggle — the overlay would stay mounted after exiting
          // fullscreen (caught by
          // live_room_portrait_control_bar_test: two '刷新' buttons
          // after pumpPortrait).
          Obx(() {
            final fs = _fullscreen.isFullscreen.value;
            if (!_controlsVisible || _controlsLocked || !fs) {
              return const SizedBox.shrink();
            }
            return Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                top: false,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  child: Row(children: _bottomBarButtons(Colors.white)),
                ),
              ),
            );
          }),
          // Build-29 item 12: fullscreen corner clock. Fullscreen
          // only; the top bar (~56px + safe area) and the bottom bar
          // own the screen edges, so the clock sits just inside
          // them. Tap cycles the four corners (the position is
          // persisted; the tools sheet shows it too).
          Obx(() {
            final fs = _fullscreen.isFullscreen.value;
            if (!fs) return const SizedBox.shrink();
            final corner = _clockCorner;
            return Positioned(
              top: corner == LiveClockCorner.topLeft ||
                      corner == LiveClockCorner.topRight
                  ? 64
                  : null,
              bottom: corner == LiveClockCorner.bottomLeft ||
                      corner == LiveClockCorner.bottomRight
                  ? 76
                  : null,
              left: corner == LiveClockCorner.topLeft ||
                      corner == LiveClockCorner.bottomLeft
                  ? 12
                  : null,
              right: corner == LiveClockCorner.topRight ||
                      corner == LiveClockCorner.bottomRight
                  ? 12
                  : null,
              child: LiveFullscreenClock(
                corner: corner,
                onCornerChanged: (c) {
                  _clockCorner = c;
                  unawaited(saveClockCorner(c));
                  if (mounted) setState(() {});
                },
              ),
            );
          }),
          // Locked: only the unlock button (Pure Live LockButton).
          if (_controlsLocked)
            Positioned(
              right: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton(
                  icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.lock, color: Colors.white),
                  tooltip: '解锁控制条',
                  onPressed: _unlockControls,
                ),
              ),
            ),
          if (_loading)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CupertinoActivityIndicator(color: Colors.white),
                  if (_ladderHint != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _ladderHint!,
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (_failed)
            _FailureCard(
              message: _errorMessage ?? '播放失败',
              onRetry: _manualRetry,
            ),
          if (_showingStallNotice && !_failed)
            Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: Center(
                child: DarkGlass(
                  radius: 999,
                  sigma: 16,
                  color: Colors.black.withValues(alpha: 0.45),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Text(
                      '重新连接…',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return Obx(() {
      final fullscreen = _fullscreen.isFullscreen.value;
      return PopScope(
        // In fullscreen the back gesture exits fullscreen instead of
        // leaving the room; a second back leaves the room.
        canPop: !fullscreen,
        onPopInvokedWithResult: (didPop, _) {
          // Blocked pop (fullscreen) or real pop: either way restore
          // portrait; a blocked pop only exits fullscreen.
          unawaited(_fullscreen.exitFullscreen());
        },
        child: Scaffold(
          // Pure Live fullscreen has NO AppBar: the overlay top bar is
          // the exit path and the video fills the whole screen. Keeping
          // the AppBar in fullscreen was the "横屏显示不好" — the video
          // never filled the screen.
          appBar: fullscreen
              ? null
              : AppBar(
                  title: Text(_room.title.isEmpty ? '直播间' : _room.title, style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
                  actions: [
                    IconButton(
                      icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.tune),
                      tooltip: '直播工具',
                      // Build-29 tools sheet: pure audio / sleep /
                      // boost / power saving / record / multi-view /
                      // PiP verdicts.
                      onPressed: _openToolsSheet,
                    ),
                    IconButton(
                      icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.swap_horiz),
                      tooltip: '切换直播间',
                      // L04: switch-room panel (follows / current list /
                      // history / replay follows).
                      onPressed: _openSwitchPanel,
                    ),
                    IconButton(
                      icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.fullscreen),
                      tooltip: '全屏',
                      // The [ ] button is the ONLY path to landscape (fix 2).
                      onPressed: () => _fullscreen.toggleFullscreen(),
                    ),
                  ],
                ),
          body: Column(
            children: [
              // 16:9 native video surface on top — in-page, portrait;
              // fills the screen in landscape fullscreen.
              if (fullscreen)
                Expanded(child: videoSurface)
              else
                AspectRatio(aspectRatio: 16 / 9, child: videoSurface),
              // Portrait control bar BELOW the video (chen 2026-11-20):
              // the overlaid bar sat on the video's bottom strip,
              // colliding with the stream's own bottom HUD (the
              // game's skill buttons in his screenshot). Page chrome
              // now — below the video, on the scaffold, theme
              // colours. Always visible when unlocked: it covers
              // nothing, so auto-hiding it would only shift the
              // layout up/down every 5 s. Locked hides it (the
              // unlock button still shows over the video).
              if (!fullscreen && !_controlsLocked)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    children: _bottomBarButtons(theme.textPrimary),
                  ),
                ),
              // Room info + quality / line controls below the video.
              // L05: the whole info bar is tappable — it opens the room
              // detail sheet (never covering the video).
              if (!fullscreen)
                HaoPressable(
                  onTap: _openRoomDetail,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: theme.hairline),
                          ),
                          // Dio loader (RefererImage), not CircleAvatar
                          // + NetworkImage: plain NetworkImage shows
                          // blank on chen's phone (v1.0.5 bug). Same
                          // 40x40 circle (default CircleAvatar radius
                          // 20), same '?' fallback.
                          child: ClipOval(
                            child: _room.avatar.isEmpty
                                ? Container(
                                    width: 40,
                                    height: 40,
                                    color: theme.accentSoft,
                                    alignment: Alignment.center,
                                    child: Text(
                                      _room.nick.isEmpty
                                          ? '?'
                                          : _room.nick[0],
                                      style: TextStyle(
                                        shadows: HaoTheme.legibilityShadows(context),
                                        color: theme.textPrimary,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  )
                                : RefererImage(
                                    url: _room.avatar,
                                    width: 40,
                                    height: 40,
                                    fit: BoxFit.cover,
                                    fallback: Container(
                                      width: 40,
                                      height: 40,
                                      color: theme.accentSoft,
                                      alignment: Alignment.center,
                                      child: Text(
                                        _room.nick.isEmpty
                                            ? '?'
                                            : _room.nick[0],
                                        style: TextStyle(
                                          shadows: HaoTheme.legibilityShadows(context),
                                          color: theme.textPrimary,
                                          fontSize: 18,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _room.nick.isEmpty ? '主播' : _room.nick,
                                style: TextStyle(
                                  shadows: HaoTheme.legibilityShadows(context),
                                  color: theme.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                // Build-29 item 6: the number is
                                // labelled by its real metric kind
                                // (在线 / 热度 / 观看) — never a bare
                                // "X 人在看".
                                metricLabelFor(_room.platform, _room.watching),
                                style: TextStyle(
                                  shadows: HaoTheme.legibilityShadows(context),
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
                              borderRadius: BorderRadius.circular(HaoRadius.small),
                            ),
                            child: const Text(
                              'LIVE',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        const SizedBox(width: 8),
                        Icon(
                          shadows: HaoTheme.legibilityShadows(context),
                          Icons.chevron_right,
                          size: 18,
                          color: theme.accent,
                        ),
                      ],
                    ),
                  ),
                ),
              // Quality selector.
              if (!fullscreen && _qualities.isNotEmpty)
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
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(HaoRadius.panel),
                          ),
                          side: BorderSide(
                            color: selected
                                ? theme.accent
                                : theme.hairline,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 2,
                          ),
                          labelStyle: TextStyle(
                            shadows: HaoTheme.legibilityShadows(context),
                            color: selected
                                ? theme.accent
                                : theme.textSecondary,
                            fontSize: 13,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                          onSelected: (_) => _switchQuality(i),
                        ),
                      );
                    },
                  ),
                ),
              // Line selector: buttons show only "线路 N", never CDN names.
              if (!fullscreen && _recovery.lines.length > 1)
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
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(HaoRadius.panel),
                          ),
                          side: BorderSide(
                            color: selected
                                ? theme.accent
                                : theme.hairline,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 2,
                          ),
                          labelStyle: TextStyle(
                            shadows: HaoTheme.legibilityShadows(context),
                            color: selected
                                ? theme.accent
                                : theme.textSecondary,
                            fontSize: 13,
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
              if (!fullscreen)
                Expanded(
                  child: !_danmakuEnabled
                      ? HaoPressable(
                          // Tap opens danmaku settings directly — the
                          // empty state is the shortcut, not a signpost.
                          onTap: () =>
                              Get.to(() => const DanmakuSettingsPage()),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: theme.accentSoft,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    shadows: HaoTheme.legibilityShadows(context),
                                    Icons.chat_bubble_outline,
                                    size: 32,
                                    color: theme.accent,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  '弹幕已关闭',
                                  style: TextStyle(
                                    shadows: HaoTheme.legibilityShadows(context),
                                    color: theme.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '点按打开弹幕设置',
                                  style: TextStyle(
                                    shadows: HaoTheme.legibilityShadows(context),
                                    color: theme.textMuted,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : _danmaku.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                shadows: HaoTheme.legibilityShadows(context),
                                Icons.chat_bubble_outline,
                                size: 36,
                                color: theme.textMuted,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _loading
                                    ? '弹幕加载中…'
                                    : (_danmakuEnded
                                        ? '弹幕已断开'
                                        : '暂无弹幕'),
                                style: TextStyle(
                                  shadows: HaoTheme.legibilityShadows(context),
                                  color: theme.textMuted,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        )
                      : Opacity(
                          opacity: _danmakuOpacity,
                          child: ListView.builder(
                            controller: _danmakuScroll,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _danmaku.length,
                            itemBuilder: (context, i) {
                              final m = _danmaku[i];
                              final highlighted = i == _highlightedDanmakuIndex;
                              final text =
                                  _showUsernames && m.userName.isNotEmpty
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
                              // Username in primary + semibold, message
                              // in secondary: same string, clearer scan.
                              // Platform colour mode dyes the message
                              // body only (username stays theme): the
                              // adapter's colour when it has one —
                              // 0xFFFFFFFF is the "no colour" sentinel
                              // most adapters leave, and stays theme.
                              final bodyColor =
                                  _danmakuColorMode ==
                                              DanmakuSettings
                                                  .colorModePlatform &&
                                          m.color != 0xFFFFFFFF
                                      ? Color(m.color)
                                      : theme.textSecondary;
                              final body =
                                  _showUsernames && m.userName.isNotEmpty
                                  ? Text.rich(
                                      TextSpan(
                                        children: [
                                          TextSpan(
                                            text: '${m.userName}: ',
                                            style: TextStyle(
                                              color: theme.textPrimary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          TextSpan(text: m.message),
                                        ],
                                      ),
                                      style: TextStyle(
                                        shadows: HaoTheme.legibilityShadows(context),
                                        color: bodyColor,
                                        fontSize: _danmakuFontSize,
                                        height: textHeight,
                                      ),
                                    )
                                  : Text(
                                      text,
                                      style: TextStyle(
                                        shadows: HaoTheme.legibilityShadows(context),
                                        color: bodyColor,
                                        fontSize: _danmakuFontSize,
                                        height: textHeight,
                                      ),
                                    );
                              final Widget row;
                              if (_listStyle == DanmakuSettings.listStyleCard) {
                                row = GlassCard(
                                  radius: 14,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
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
                                  _highlightedDanmakuIndex = highlighted
                                      ? null
                                      : i;
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
    });
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // Over-video failure card: black scrim stays (theme surface
    // would wash out over the video in light mode).
    return Container(
      color: Colors.black54,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(
                  backgroundColor: HaoTheme.of(context).accent,
                  foregroundColor:
                      Theme.of(context).colorScheme.onPrimary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                child: const Text(
                  '▶ 重试',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
