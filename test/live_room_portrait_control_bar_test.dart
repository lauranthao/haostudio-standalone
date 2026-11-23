// Live-room portrait control bar (chen 2026-11-20: "这个下面的东西
// 不能往下移吗 这样看着好别扭", with a screenshot of the live room
// in portrait).
//
// Screenshot identification (read first — the fix lives in the LIVE
// room, not the VOD player): the bottom row is pause / refresh /
// danmaku / lock / fullscreen and the top AppBar is back + title +
// swap + fullscreen, with NO progress slider. That is the live
// room's BottomActionBar + portrait AppBar: the VOD bottom bar has
// prev/next episode + a progress Slider + speed and no danmaku,
// lock or refresh buttons, and its top bar is a black-gradient
// overlay (not a white AppBar). The VOD player is untouched by
// this fix — in landscape fullscreen its bottom bar is already at
// the screen's bottom edge and the video fills the screen, so
// there is no "below" to move it to.
//
// What changed: in portrait the bar no longer overlays the bottom
// of the 16:9 video (where it collided with the stream's own
// bottom HUD — the game's skill buttons in chen's screenshot). It
// is page chrome below the video, theme-coloured on the scaffold,
// always visible when unlocked (it covers nothing, so auto-hiding
// it would only shift the layout). Fullscreen keeps the overlaid
// bar at the screen bottom.
//
// Harness copied from live_room_player_audit_test.dart (Hive temp
// dir, fakes, pump helpers). ONE pump only: a second room pump in
// the same file hangs on this VM (same note as the audit test).
// After flipping to fullscreen, use plain tester.pump() only —
// never runAsync while the fullscreen Flame barrage is mounted.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/widgets/hao_nav_bar.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/live_follow_store.dart';
import 'package:standalone/domains/live/live_history_store.dart';
import 'package:standalone/domains/live/presentation/playback/live_room_page.dart';
import 'package:standalone/features/player/fullscreen_controller.dart';
import 'package:standalone/features/settings/source_stores.dart';
import 'package:standalone/shared/platforms/live_site.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-room-bar-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
  });

  const roomA = LiveRoom(
    roomId: '660000',
    platform: 'huya',
    title: 'room A',
    nick: 'anchor A',
    liveStatus: true,
    watching: 100,
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  Future<void> resetStores(WidgetTester tester) async {
    await tester.runAsync(() async {
      await DanmakuSettings.setEnabled('huya', true);
      await LiveHistoryStore.clear();
      await LiveFollowStore.clear();
    });
    await settle(tester);
  }

  /// Phone-tall viewport: the room Column (16:9 video + bar + info
  /// + quality row + danmaku) is ~650 px tall and overflows the
  /// default 800x600 test surface, pushing the danmaku area
  /// off-screen.
  Future<void> pumpRoom(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final site = _FakeSite();
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: LiveRoomPage(
          room: roomA,
          playlist: const [roomA],
          site: site,
          backendFactory: (_) => _FakeBackend(),
        ),
      ),
    );
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 200));
    await settle(tester);
    expect(find.text('room A'), findsOneWidget);
  }

  Future<void> disposeRoom(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  void setFullscreen(WidgetTester tester, bool value) {
    Get.find<FullscreenController>().isFullscreen.value = value;
  }

  Future<void> pumpFullscreen(WidgetTester tester) async {
    setFullscreen(tester, true);
    await tester.pump();
  }

  Future<void> pumpPortrait(WidgetTester tester) async {
    setFullscreen(tester, false);
    await tester.pump();
  }

  group('live room portrait control bar', () {
    testWidgets('portrait bar sits below the video, fullscreen keeps '
        'the overlay', (tester) async {
      await resetStores(tester);
      await pumpRoom(tester);

      // Exactly ONE control bar in portrait (the below-video bar):
      // if the old overlay also rendered, the refresh button would
      // appear twice. ('全屏' appears twice by design: the AppBar
      // action + the bar toggle.)
      expect(find.byTooltip('刷新'), findsOneWidget);
      expect(find.byTooltip('锁定控制条'), findsOneWidget);
      expect(find.byTooltip('全屏'), findsNWidgets(2));

      // Geometry: the bar is BELOW the 16:9 video surface — its top
      // edge at or just under the video's bottom edge, never on top
      // of the video content (the old position was inside the
      // video, at the same height as the stream's own bottom HUD).
      final videoRect =
          tester.getRect(find.byKey(const ValueKey('fake-video')));
      final barRect = tester.getRect(find.byTooltip('刷新'));
      expect(
        barRect.top,
        greaterThanOrEqualTo(videoRect.bottom - 1.0),
        reason: 'portrait bar must start below the video surface',
      );
      expect(
        barRect.top,
        lessThan(videoRect.bottom + 24.0),
        reason: 'portrait bar sits directly under the video, not far away',
      );

      // Theme-coloured on the scaffold (light mode): white icons
      // would be invisible on the white page background.
      final theme = HaoTheme.of(tester.element(find.byType(LiveRoomPage)));
      final refreshIcon = tester.widget<Icon>(find.byIcon(Icons.refresh));
      expect(refreshIcon.color, theme.textPrimary);
      expect(refreshIcon.color, isNot(Colors.white));

      // The 5 s auto-hide fires but the portrait bar stays: it is
      // page chrome now, and hiding it would shift the layout.
      await tester.pump(const Duration(seconds: 5));
      expect(find.byTooltip('刷新'), findsOneWidget);

      // Fullscreen: the overlay bar is back at the screen bottom,
      // the below-video bar is gone (still exactly one bar), and
      // the quality button renders in the overlay. The 5 s
      // auto-hide above left _controlsVisible false, but entering
      // fullscreen re-shows the controls immediately (the
      // fullscreen-entry worker) — no video tap needed.
      await pumpFullscreen(tester);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byTooltip('刷新'), findsOneWidget);
      expect(find.text('原画'), findsOneWidget);
      // The video fills the screen and the bar sits at its bottom
      // edge: the 48 px button is centred in the 56 px row, so its
      // bottom lands 4 px above the edge — assert within that
      // centring slack, not pixel-exact.
      final fsVideoRect =
          tester.getRect(find.byKey(const ValueKey('fake-video')));
      expect(fsVideoRect.bottom, 1600.0);
      final fsBarRect = tester.getRect(find.byTooltip('刷新'));
      expect(
        fsBarRect.bottom,
        greaterThanOrEqualTo(1600 - 8.0),
        reason: 'fullscreen overlay bar sits at the screen bottom edge',
      );

      // Exit fullscreen: portrait layout restored, bar below the
      // video again.
      await pumpPortrait(tester);
      // b30: portrait nav bar is HaoNavBar (Cupertino), not a
      // Material AppBar — the iOS batch replaced all 38 AppBars.
      expect(find.byType(HaoNavBar), findsOneWidget);
      expect(find.byTooltip('刷新'), findsOneWidget);
      final videoRect2 =
          tester.getRect(find.byKey(const ValueKey('fake-video')));
      final barRect2 = tester.getRect(find.byTooltip('刷新'));
      expect(barRect2.top, greaterThanOrEqualTo(videoRect2.bottom - 1.0));

      await disposeRoom(tester);
    });
  });
}

class _FakeSite extends LiveSite {
  final danmaku = _FakeDanmaku();

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
      const [LivePlayQuality(quality: '原画', id: '10000')];

  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final issued = DateTime.now();
    return LivePlayUrlResolution(
      urls: const ['https://example.com/live.m3u8'],
      issuedAt: issued,
      refreshAt: issued.add(const Duration(seconds: 100)),
      invalidAt: issued.add(const Duration(seconds: 125)),
      streamFacts: const [LiveStreamFacts(format: 'hls')],
    );
  }
}

/// Fake danmaku transport: records start/stop, never emits.
class _FakeDanmaku extends LiveDanmaku {
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

/// Minimal fake native backend: instant open / first frame, no
/// tickers, no timers.
class _FakeBackend implements PlayerBackend {
  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

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
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Future<void> seekTo(Duration position) async {}

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Future<void> dispose() async {
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}
