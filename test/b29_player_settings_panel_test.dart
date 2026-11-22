// D 组播放器内设置面板 (build 29) — panel tests.
//
// Pins the three D-group items that live in the players:
//  (1) VOD + live in-player settings panels: every row writes the
//      SAME Hive key the settings page reads (one key, two writers,
//      no second state) and applies to the running session — panel
//      change ⇒ settings page reads the same value, and vice versa
//      (pre-seeded key ⇒ panel shows it).
//  (2) K 缺口: live volume ceiling 1.3 → 3.0 is covered in
//      b29_live_i_test.dart (item 8); here the VOD PiP entry shows
//      only for a PiP-capable backend and never for MPV/IJK.
//  (3) Emby mediaType: VideoDetail carries it (Emby `Type`), the
//      player's _recordHistory prefers it over the CMS regex, so an
//      Emby movie whose genres ('动作 / 科幻') miss kVideoMovieRe
//      gets no "下一集".
//
// Harness copied from b29_vod_player_features_test.dart (Hive temp
// dir, fake backends, pump/unmount helpers) and from
// live_room_portrait_control_bar_test.dart (fake live site). ONE
// LiveRoomPage pump in this file (a second room pump hangs on this
// VM — same note as the portrait-bar test); the live panel is
// otherwise covered at the sheet level with recording callbacks.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/storage/local_paths.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/live_audio_sleep.dart';
import 'package:standalone/domains/live/live_network_quality.dart';
import 'package:standalone/domains/live/live_volume_boost.dart';
import 'package:standalone/domains/live/presentation/playback/live_player_settings_sheet.dart';
import 'package:standalone/domains/live/presentation/playback/live_room_page.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/settings/source_stores.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_history_store.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/features/video/vod_player_settings_sheet.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/vod_danmaku_client.dart';
import 'package:standalone/shared/platforms/live_site.dart';
import 'package:standalone/widgets/native_switch.dart';
import 'package:standalone/widgets/player_settings_sheet.dart';

import 'helpers/hive_test_setup.dart';

/// No-network danmaku client: candidates [] means "no danmaku for
/// this episode" with zero HTTP, so enabling the VOD danmaku gate
/// in a test never touches the network.
class _StubDanmakuClient extends VodDanmakuClient {
  @override
  Future<List<VodDanmakuCandidate>?> fetchCandidates({
    required String title,
    required String episode,
  }) async =>
      const [];
}

VideoDetail _detail({
  String title = '流浪地球2',
  String type = '',
  String mediaType = '',
  dynamic source = 12,
  List<PlayEpisode> episodes = const [
    PlayEpisode(name: '第1集', url: 'https://example.com/ep1.mp4'),
    PlayEpisode(name: '第2集', url: 'https://example.com/ep2.mp4'),
  ],
}) =>
    VideoDetail(
      source: source,
      vodId: '93344',
      meta: VideoMeta(name: title, type: type),
      mediaType: mediaType,
      lines: [PlayLine(name: '线路1', episodes: episodes)],
    );

class _FakeBackend implements PlayerBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final List<double> rates = [];
  final List<Duration> seeks = [];
  final List<bool> audioOnlyCalls = [];
  final List<double> volumes = [];
  int playCount = 0;
  int pauseCount = 0;
  bool _disposed = false;

  void emitPosition(Duration p) => _position.add(p);
  void emitDuration(Duration d) => _duration.add(d);
  void emitCompleted() => _completed.add(null);

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  @override
  Widget buildVideoWidget() =>
      const SizedBox(key: ValueKey('fake-video'));

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {}

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      true;

  @override
  Future<void> play() async {
    playCount++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _playing.add(false);
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> setAudioOnly(bool audioOnly) async {
    audioOnlyCalls.add(audioOnly);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
  }

  @override
  Future<void> seekTo(Duration position) async {
    seeks.add(position);
  }

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _error.close();
    await _completed.close();
  }
}

/// Dialogue-boost-capable fake: proves the session forwards the
/// panel's switch to a capable backend.
class _FakeCapableBackend extends _FakeBackend
    implements DialogueBoostCapableBackend {
  final List<bool> dialogueBoostCalls = [];

  @override
  Future<void> setDialogueBoost(bool enabled) async {
    dialogueBoostCalls.add(enabled);
  }
}

/// PiP-capable fake (AVPlayer-shaped): proves the 更多 menu offers
/// PiP exactly when the backend supports it.
class _FakePipBackend extends _FakeCapableBackend
    implements PictureInPictureCapableBackend {
  int pipCalls = 0;

  @override
  Future<bool> enterPictureInPicture() async {
    pipCalls++;
    return true;
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-b29-panel-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    LocalPaths.setDocumentsPathForTest(hiveDir.path);
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    LocalPaths.resetForTest();
    await hiveDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
  });

  late PlaybackSession session;
  late _FakeBackend backend;

  Future<void> pumpPlayer(
    WidgetTester tester, {
    VideoDetail? detail,
    _FakeBackend Function()? factory,
  }) async {
    backend = factory?.call() ?? _FakeBackend();
    session = PlaybackSession(backendFactory: (_) => backend);
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: NativeVideoPlayerPage(
          detail: detail ?? _detail(),
          session: session,
          danmakuClient: _StubDanmakuClient(),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  Future<void> unmountPlayer(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await drainHiveWrites(tester);
  }

  /// Reset the keys this file writes, before a pump reads them as
  /// defaults. Drain first (earlier tests' fire-and-forget writes
  /// stall hive_ce's queue until a drain lets their I/O land).
  Future<void> resetVodKeys(WidgetTester tester) async {
    await drainHiveWrites(tester);
    await tester.runAsync(() async {
      await HiveStore.delete(HiveKeys.vodPlaybackRate);
      await HiveStore.delete(HiveKeys.vodDialogueBoost);
      await HiveStore.delete(HiveKeys.vodDoubleTapSeekSeconds);
      await HiveStore.delete(HiveKeys.vodSubtitleDelay);
      await HiveStore.delete(HiveKeys.danmakuEnabled);
    });
    await drainHiveWrites(tester);
  }

  Future<void> openVodPanel(WidgetTester tester) async {
    await tester.tap(find.byTooltip('播放设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('播放设置'), findsOneWidget);
  }

  // -- mediaType: pure ---------------------------------------------------

  group('VideoDetail.mediaType', () {
    test('round-trips through JSON; CMS details default to empty', () {
      final emby = _detail(
        title: 'Emby电影A',
        type: '动作 / 科幻',
        mediaType: 'Movie',
        source: EmbyClient.sourceId,
      );
      expect(
        VideoDetail.fromJson(emby.toJson()).mediaType,
        'Movie',
      );
      final cms = _detail();
      expect(cms.mediaType, '');
      expect(VideoDetail.fromJson(cms.toJson()).mediaType, '');
    });
  });

  // -- cellular downgrade key: pure --------------------------------------

  group('live cellular downgrade key', () {
    test('defaults ON (today behaviour); persists the opt-out', () async {
      expect(liveCellularDowngradeEnabled(), isTrue);
      await saveLiveCellularDowngrade(false);
      expect(liveCellularDowngradeEnabled(), isFalse);
      await saveLiveCellularDowngrade(true);
      expect(liveCellularDowngradeEnabled(), isTrue);
    });
  });

  // -- VOD panel: Hive-key sync ------------------------------------------

  group('VOD settings panel', () {
    testWidgets('gear opens the panel with the VOD rows', (tester) async {
      await resetVodKeys(tester);
      await pumpPlayer(tester);
      await openVodPanel(tester);
      expect(find.text('倍速'), findsOneWidget);
      expect(find.text('双击快进秒数'), findsOneWidget);
      expect(find.text('对白增强'), findsOneWidget);
      expect(find.text('Anime4K 超分'), findsOneWidget);
      expect(find.text('字幕时间偏移'), findsOneWidget);
      expect(find.text('双字幕'), findsOneWidget);
      expect(find.text('影视弹幕'), findsOneWidget);
      // Live-only controls never appear in the VOD panel.
      expect(find.text('直播设置'), findsNothing);
      await unmountPlayer(tester);
    });

    testWidgets('dialogue boost toggle writes the settings-page key '
        'and forwards to the session', (tester) async {
      await resetVodKeys(tester);
      await pumpPlayer(tester, factory: _FakeCapableBackend.new);
      await openVodPanel(tester);
      await tester.tap(find.text('对白增强'));
      await tester.pump();
      await drainHiveWrites(tester);
      // The exact key Settings → 影视播放 reads.
      expect(HiveStore.getBool(HiveKeys.vodDialogueBoost, false), isTrue);
      expect(session.dialogueBoost, isTrue);
      expect(
        (backend as _FakeCapableBackend).dialogueBoostCalls,
        contains(true),
      );
      await unmountPlayer(tester);
    });

    testWidgets('pre-seeded settings value shows ON in the panel '
        '(reverse direction)', (tester) async {
      await resetVodKeys(tester);
      await tester.runAsync(
        () => HiveStore.put(HiveKeys.vodDialogueBoost, true),
      );
      await drainHiveWrites(tester);
      await pumpPlayer(tester, factory: _FakeCapableBackend.new);
      await openVodPanel(tester);
      final row = tester.widget<HaoNativeSwitch>(
        find.byWidgetPredicate(
          (w) =>
              w is HaoNativeSwitch && w.semanticsLabel == '对白增强',
        ),
      );
      expect(row.value, isTrue);
      await unmountPlayer(tester);
    });

    testWidgets('double-tap step cycles and persists (10 → 15)',
        (tester) async {
      await resetVodKeys(tester);
      await pumpPlayer(tester);
      await openVodPanel(tester);
      await tester.tap(find.text('双击快进秒数'));
      await tester.pump();
      await drainHiveWrites(tester);
      expect(
        HiveStore.getInt(HiveKeys.vodDoubleTapSeekSeconds, 10),
        15,
      );
      expect(find.text('15 秒'), findsOneWidget);
      await unmountPlayer(tester);
    });

    testWidgets('subtitle delay stepper applies live and persists',
        (tester) async {
      await resetVodKeys(tester);
      await pumpPlayer(tester);
      await openVodPanel(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('vod_setting_sub_delay_plus')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('vod_setting_sub_delay_plus')));
      await tester.pump();
      await drainHiveWrites(tester);
      expect(session.currentSubtitleDelay, 0.1);
      expect(
        HiveStore.getDouble(HiveKeys.vodSubtitleDelay, 0.0),
        0.1,
      );
      await unmountPlayer(tester);
    });

    testWidgets('rate cycle remembers the rate (倍速记忆)',
        (tester) async {
      await resetVodKeys(tester);
      await pumpPlayer(tester);
      await openVodPanel(tester);
      await tester.tap(find.text('倍速'));
      await tester.pump();
      await drainHiveWrites(tester);
      expect(session.rate, 1.25);
      expect(HiveStore.getDouble(HiveKeys.vodPlaybackRate, 1.0), 1.25);
      await unmountPlayer(tester);
    });

    testWidgets('VOD danmaku master toggle writes the F key',
        (tester) async {
      await resetVodKeys(tester);
      await pumpPlayer(tester);
      await openVodPanel(tester);
      await tester.ensureVisible(find.text('影视弹幕'));
      await tester.pump();
      await tester.tap(find.text('影视弹幕'));
      await tester.pump();
      await drainHiveWrites(tester);
      expect(DanmakuSettings.isEnabled(DanmakuSettings.vodSiteId), isTrue);
      await unmountPlayer(tester);
    });

    testWidgets('PiP entry shows only for a capable backend',
        (tester) async {
      // AVPlayer-shaped backend: the entry shows and enters PiP.
      await resetVodKeys(tester);
      await pumpPlayer(tester, factory: _FakePipBackend.new);
      await tester.tap(find.byTooltip('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('画中画'), findsOneWidget);
      await tester.tap(find.text('画中画'));
      await tester.pump();
      expect((backend as _FakePipBackend).pipCalls, 1);
      await unmountPlayer(tester);
    });

    testWidgets('PiP entry hidden for a plain (MPV-shaped) backend',
        (tester) async {
      await resetVodKeys(tester);
      await pumpPlayer(tester);
      await tester.tap(find.byTooltip('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('画中画'), findsNothing);
      await unmountPlayer(tester);
    });
  });

  // -- Emby mediaType → history ------------------------------------------

  group('Emby mediaType → history next episode', () {
    testWidgets('Emby movie (mediaType Movie, genre type) has no '
        'next episode', (tester) async {
      await resetVodKeys(tester);
      await pumpPlayer(
        tester,
        detail: _detail(
          title: 'Emby电影A',
          type: '动作 / 科幻',
          mediaType: 'Movie',
          source: EmbyClient.sourceId,
          episodes: const [
            PlayEpisode(name: '正片', url: 'https://example.com/m1.mp4'),
            PlayEpisode(name: '第2集', url: 'https://example.com/m2.mp4'),
          ],
        ),
      );
      await drainHiveWrites(tester);
      expect(
        VideoHistoryStore.findByTitle('Emby电影A')?.nextEpName,
        '',
      );
      await unmountPlayer(tester);
    });

    testWidgets('same genres without mediaType fall back to the regex '
        'and still see a next episode', (tester) async {
      await resetVodKeys(tester);
      await pumpPlayer(
        tester,
        detail: _detail(
          title: 'Emby电影B',
          type: '动作 / 科幻',
          mediaType: '',
          source: EmbyClient.sourceId,
          episodes: const [
            PlayEpisode(name: '正片', url: 'https://example.com/m1.mp4'),
            PlayEpisode(name: '第2集', url: 'https://example.com/m2.mp4'),
          ],
        ),
      );
      await drainHiveWrites(tester);
      expect(
        VideoHistoryStore.findByTitle('Emby电影B')?.nextEpName,
        '第2集',
      );
      await unmountPlayer(tester);
    });
  });

  // -- Sheets in isolation: callbacks ------------------------------------

  VodPlayerSettings vodSettings({
    ValueChanged<bool>? onDialogue,
    VoidCallback? onRate,
    ValueChanged<double>? onDelay,
    ValueChanged<bool>? onSuperRes,
  }) =>
      VodPlayerSettings(
        rateLabel: '1.0x',
        onRateCycle: onRate ?? () {},
        doubleTapSeekSeconds: 10,
        onDoubleTapSeekCycle: () {},
        autoNext: true,
        onAutoNextChanged: (_) {},
        videoFitLabel: '自动',
        onVideoFitCycle: () {},
        skipIntroLabel: '关',
        onSkipIntroCycle: () {},
        dialogueBoost: false,
        onDialogueBoostChanged: onDialogue ?? (_) {},
        audioOnly: false,
        onAudioOnlyChanged: (_) {},
        superResolution: false,
        superResolutionLocked: false,
        onSuperResolutionChanged: onSuperRes,
        interpolation: false,
        interpolationLocked: false,
        onInterpolationChanged: (_) {},
        sdrToHdr: false,
        sdrToHdrLocked: false,
        onSdrToHdrChanged: (_) {},
        dvP8Downgrade: true,
        onDvP8Changed: (_) {},
        lowMemoryLabel: '自动',
        onLowMemoryCycle: () {},
        subtitleDelay: 0.0,
        onSubtitleDelayChanged: onDelay ?? (_) {},
        subtitleFontLabel: '标准',
        onSubtitleFontCycle: () {},
        subtitleColorLabel: '白色',
        onSubtitleColorCycle: () {},
        subtitlePositionLabel: '底部',
        onSubtitlePositionCycle: () {},
        dualSubtitleOn: false,
        onDualSubtitleTap: () {},
        danmakuEnabled: false,
        onDanmakuEnabledChanged: (_) {},
        danmakuVisible: false,
        onDanmakuVisibleChanged: (_) {},
        danmakuOcclusionAvoidance: false,
        onDanmakuOcclusionChanged: (_) {},
      );

  LivePlayerSettings liveSettings({
    VoidCallback? onQuality,
    ValueChanged<bool>? onSimilarity,
    ValueChanged<int>? onBoost,
    VoidCallback? onSleep,
  }) =>
      LivePlayerSettings(
        qualityLabel: '原画',
        canCycleQuality: true,
        onQualityCycle: onQuality ?? () {},
        danmakuEnabled: true,
        onDanmakuEnabledChanged: (_) {},
        similarityEnabled: false,
        onSimilarityChanged: onSimilarity ?? (_) {},
        blockEmoteOnly: false,
        onBlockEmoteChanged: (_) {},
        blockLong: false,
        onBlockLongChanged: (_) {},
        douyuBotFilter: false,
        onDouyuBotChanged: (_) {},
        danmakuOcclusionAvoidance: false,
        onDanmakuOcclusionChanged: (_) {},
        audioOnly: false,
        onAudioOnlyChanged: (_) {},
        sleep: LiveSleepDuration.off,
        onSleepCycle: onSleep ?? () {},
        boostPct: 100,
        effectiveBoostPct: 100,
        onBoostChanged: onBoost ?? (_) {},
        powerSaving: false,
        onPowerSavingChanged: (_) {},
        cellularDowngrade: true,
        onCellularDowngradeChanged: (_) {},
      );

  Future<void> pumpSheet(WidgetTester tester, Widget sheet) async {
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(body: SingleChildScrollView(child: sheet)),
      ),
    );
    await tester.pump();
  }

  group('sheets in isolation', () {
    testWidgets('VOD sheet rows fire their callbacks', (tester) async {
      var dialogue = false;
      var rateCalls = 0;
      var delay = 0.0;
      await pumpSheet(
        tester,
        VodPlayerSettingsSheet(
          settings: vodSettings(
            onDialogue: (v) => dialogue = v,
            onRate: () => rateCalls++,
            onDelay: (v) => delay = v,
          ),
        ),
      );
      await tester.ensureVisible(find.text('对白增强'));
      await tester.pump();
      await tester.tap(find.text('对白增强'));
      await tester.pump();
      expect(dialogue, isTrue);
      await tester.ensureVisible(find.text('倍速'));
      await tester.pump();
      await tester.tap(find.text('倍速'));
      await tester.pump();
      expect(rateCalls, 1);
      await tester.ensureVisible(
        find.byKey(const ValueKey('vod_setting_sub_delay_plus')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('vod_setting_sub_delay_plus')),
      );
      await tester.pump();
      expect(delay, 0.1);
    });

    testWidgets('locked trio row does nothing when tapped',
        (tester) async {
      var superResCalls = 0;
      await pumpSheet(
        tester,
        VodPlayerSettingsSheet(
          settings: vodSettings(
            onSuperRes: (_) => superResCalls++,
          ),
        ),
      );
      // Lock the super-res row by passing a null callback (the page
      // does this when interpolation / SDR→HDR is on).
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: SingleChildScrollView(
              child: VodPlayerSettingsSheet(
                settings: vodSettings(onSuperRes: null),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Anime4K 超分'));
      await tester.pump();
      await tester.tap(find.text('Anime4K 超分'));
      await tester.pump();
      expect(superResCalls, 0);
    });

    testWidgets('live sheet rows fire their callbacks', (tester) async {
      var qualityCalls = 0;
      var similarity = false;
      var boost = 100;
      var sleepCalls = 0;
      await pumpSheet(
        tester,
        LivePlayerSettingsSheet(
          settings: liveSettings(
            onQuality: () => qualityCalls++,
            onSimilarity: (v) => similarity = v,
            onBoost: (v) => boost = v,
            onSleep: () => sleepCalls++,
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('live_setting_quality')),
      );
      await tester.pump();
      expect(qualityCalls, 1);
      await tester.tap(find.text('过滤相似弹幕'));
      await tester.pump();
      expect(similarity, isTrue);
      await tester.ensureVisible(
        find.byKey(const ValueKey('live_setting_boost_plus')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('live_setting_boost_plus')),
      );
      await tester.pump();
      expect(boost, 125);
      await tester.ensureVisible(find.text('定时关闭'));
      await tester.pump();
      await tester.tap(find.text('定时关闭'));
      await tester.pump();
      expect(sleepCalls, 1);
      // Live-only panel never offers VOD controls.
      expect(find.text('倍速'), findsNothing);
      expect(find.text('Anime4K 超分'), findsNothing);
    });
  });

  // -- Live room: ONE pump -----------------------------------------------
  //
  // The whole live integration (panel → same Hive keys the settings
  // page reads + room applies) runs in this single pump: a second
  // room pump in this file hangs on this VM (portrait-bar note).

  group('live settings panel in the room', () {
    testWidgets('panel toggles write the settings-page keys and the '
        'room applies them', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const room = LiveRoom(
        roomId: '660000',
        platform: 'huya',
        title: 'room A',
        nick: 'anchor A',
        liveStatus: true,
        watching: 100,
      );
      await drainHiveWrites(tester);
      await tester.runAsync(() async {
        await DanmakuSettings.setSimilarityEnabled(false);
        await saveBoostPct(100);
        await saveLiveCellularDowngrade(true);
        await HiveStore.delete(HiveKeys.preferResolution);
      });
      await drainHiveWrites(tester);
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveRoomPage(
            room: room,
            playlist: const [room],
            site: _FakeLiveSite(),
            backendFactory: (_) => _FakeBackend(),
          ),
        ),
      );
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(find.text('room A'), findsOneWidget);

      // Settings entry in the control bar (portrait, below video).
      expect(find.byTooltip('直播设置'), findsOneWidget);
      await tester.tap(find.byTooltip('直播设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('直播设置'), findsOneWidget);
      expect(find.byKey(const ValueKey('live_setting_quality')), findsOneWidget);
      expect(find.text('过滤相似弹幕'), findsOneWidget);

      // Danmaku filter: same key 弹幕设置 reads.
      await tester.tap(find.text('过滤相似弹幕'));
      await tester.pump();
      await drainHiveWrites(tester);
      expect(DanmakuSettings.similarityEnabled(), isTrue);

      // Volume boost: same persisted key, 100 → 125.
      await tester.ensureVisible(
        find.byKey(const ValueKey('live_setting_boost_plus')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('live_setting_boost_plus')),
      );
      await tester.pump();
      await drainHiveWrites(tester);
      expect(loadBoostPct(), 125);

      // Cellular downgrade opt-out: same new key, true → false.
      await tester.ensureVisible(find.text('移动网自动降画质'));
      await tester.pump();
      await tester.tap(find.text('移动网自动降画质'));
      await tester.pump();
      await drainHiveWrites(tester);
      expect(liveCellularDowngradeEnabled(), isFalse);

      // Quality cycle: 原画 → 超清, persisted only after the
      // confirmed open (the fidelity rule).
      await tester.tap(
        find.byKey(const ValueKey('live_setting_quality')),
      );
      await tester.pump();
      await settle(tester);
      await drainHiveWrites(tester);
      // The panel row itself shows the switched quality (read the
      // row widget, not a bare text find — the room also renders
      // quality chips with the same labels).
      expect(
        tester
            .widget<PlayerSettingsCycleRow>(
              find.byKey(const ValueKey('live_setting_quality')),
            )
            .valueLabel,
        '超清',
      );
      expect(
        HiveStore.getString(HiveKeys.preferResolution, ''),
        '超清',
      );

      // Close the sheet, then dispose the room.
      await tester.tapAt(const Offset(400, 100));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await drainHiveWrites(tester);
    });
  });
}

class _FakeLiveSite extends LiveSite {
  final danmaku = _FakeLiveDanmaku();

  @override
  String get id => 'huya';

  @override
  String get name => 'Huya';

  @override
  LiveDanmaku getDanmaku() => danmaku;

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async => room;

  @override
  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async =>
      const [
        LivePlayQuality(quality: '原画', id: '10000'),
        LivePlayQuality(quality: '超清', id: '20000'),
      ];

  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final issued = DateTime.now();
    // Per-quality URL: a switch that resolves to the SAME url as the
    // playing stream is an identical-stream abort by design
    // (_switchQuality's fidelity rule), so the fake must differ.
    return LivePlayUrlResolution(
      urls: ['https://example.com/live_${quality?.id ?? 'x'}.m3u8'],
      issuedAt: issued,
      refreshAt: issued.add(const Duration(seconds: 100)),
      invalidAt: issued.add(const Duration(seconds: 125)),
      streamFacts: const [LiveStreamFacts(format: 'hls')],
    );
  }
}

class _FakeLiveDanmaku extends LiveDanmaku {
  int startCount = 0;
  int stopCount = 0;

  @override
  bool get isConnected => startCount > stopCount;

  @override
  Future<void> heartbeat() async {}

  @override
  Future<void> start(Map<String, dynamic> args) async {
    startCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}
