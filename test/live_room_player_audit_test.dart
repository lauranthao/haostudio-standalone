// Live-room player audit (chen 2026-11-17: "播放器这里你看有什么问题
// 你自己改善 全屏也有问题").
//
// Page-level tests (fakes only, no network). Two things are verified
// by code inspection + analyze instead, the same as the VOD
// suppression (video_single_progress_bar_test.dart header):
// - the backend-side fixes (MPV live branch suppresses media_kit's
//   AdaptiveVideoControls + its background pause; AVPlayer/IJK pin
//   fit to contain): constructing a real MpvBackend needs the native
//   libmpv, which the Linux test harness cannot load.
// - the real [ ] tap path (FullscreenController.enterFullscreen):
//   its SystemChrome calls never complete in a widget test and hang
//   runAsync (established in danmaku_settings_effect_test.dart) — so
//   these tests flip `isFullscreen` directly and assert the ROOM's
//   layout for each state, which is what the audit changed. The
//   controller itself is Pure Live's WindowService verbatim
//   (setPreferredOrientations only — the documented way to rotate
//   with the orientation lock on).
//
// These tests guard what the page owns:
// - the ⇄ button says what it switches (tooltip "切换直播间");
// - fullscreen layout: no AppBar, overlay top bar (back exits +
//   title), quality + line buttons in the bottom bar;
// - exiting fullscreen restores portrait;
// - PopScope blocks the back gesture in fullscreen (canPop false),
//   so back exits fullscreen first;
// - the room has exactly one control bar (no seek Slider — live has
//   no seek; a second media_kit seek bar would be a Slider).
//
// NOTE: never call tester.runAsync while the fullscreen Flame barrage
// is mounted — the Flame ticker hangs runAsync (known hang in
// danmaku_settings_effect_test.dart). After flipping to fullscreen,
// use plain tester.pump() only.

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
    hiveDir = await Directory.systemTemp.createTemp('hao-room-audit-');
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

  // NOTE: do NOT await the Hive box close here. Pending Hive writes from
  // fire-and-forget deletes never resolve in the widget-test fake zone,
  // so awaiting close() hangs tearDownAll forever. Fire-and-forget: the
  // temp dir is deleted right after anyway.
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

  /// Pump the room directly as home (same shape as
  /// danmaku_settings_effect_test.dart's pumpRoom). No Get.to entry:
  /// the switch test owns the Get.to entry path, and the fullscreen
  /// layout under test does not depend on how the room was entered.
  /// Phone-tall viewport: the room Column (16:9 video + info +
  /// quality row + danmaku) is ~600 px tall and overflows the
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
    // Flush _loadRoom: getRoomDetail -> danmaku start ->
    // getPlayQualities -> resolve -> session open.
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 200));
    await settle(tester);
    expect(find.text('room A'), findsOneWidget);
  }

  /// Unmount the page so its session dispose runs, then let any Get
  /// snackbar finish its auto-dismiss (its AnimationController ticker
  /// outlives the Overlay otherwise). Same as
  /// danmaku_settings_effect_test.dart's disposeRoom.
  Future<void> disposeRoom(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  /// Enter/exit fullscreen by flipping the flag directly — the real
  /// [ ] tap calls enterFullscreen(), whose SystemChrome awaits never
  /// complete in a widget test. One plain pump after the flip (same
  /// as danmaku_settings_effect_test.dart); no runAsync while the
  /// fullscreen Flame barrage is mounted.
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

  // ONE widget test, one room pump. Pumping the live room a second
  // time in the same file hangs on this VM (same as
  // danmaku_settings_effect_test.dart's whole-file hang on its 2nd
  // test): a Hive write / session timer from the first room's
  // dispose never drains in the widget-test fake zone, and the next
  // pump stalls. So the whole portrait -> fullscreen -> portrait
  // sequence runs inside this single test.
  group('live room player audit', () {
    testWidgets('tooltip + fullscreen in/out + PopScope + one bar',
        (tester) async {
      await resetStores(tester);
      await pumpRoom(tester);

      // Switch button tooltip names the room switch.
      expect(find.byTooltip('切换直播间'), findsOneWidget);
      expect(find.byTooltip('切换'), findsNothing);

      // No seek bar in portrait (live has no seek; the room's own
      // bar has no Slider — a second media_kit control layer would
      // add one).
      expect(find.byType(Slider), findsNothing);
      // Back pops in portrait. PopScope is generic (PopScope<T>):
      // find.byType(PopScope) misses it when the inferred T differs,
      // so match by predicate instead.
      expect(
        tester
            .widget<PopScope>(
              find.byWidgetPredicate((w) => w is PopScope),
            )
            .canPop,
        isTrue,
      );

      // Enter fullscreen: no AppBar, overlay top bar (back exits +
      // title), quality + line buttons in the bottom bar.
      await pumpFullscreen(tester);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      expect(find.text('原画'), findsOneWidget);
      expect(find.text('线路 1'), findsOneWidget);
      expect(Get.find<FullscreenController>().isFullscreen.value, isTrue);
      expect(find.byType(Slider), findsNothing);
      // Back is blocked in fullscreen (exits fullscreen first).
      expect(
        tester
            .widget<PopScope>(
              find.byWidgetPredicate((w) => w is PopScope),
            )
            .canPop,
        isFalse,
      );

      // Exit fullscreen: portrait layout restored.
      await pumpPortrait(tester);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('原画'), findsOneWidget,
          reason: 'portrait quality chips are back');
      expect(Get.find<FullscreenController>().isFullscreen.value, isFalse);
      expect(find.byType(Slider), findsNothing);

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
    // Do NOT await the broadcast close() calls: inside a widget test's
    // fake-async zone a broadcast StreamController.close() future never
    // completes, so awaiting it stalls the session dispose chain.
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}
