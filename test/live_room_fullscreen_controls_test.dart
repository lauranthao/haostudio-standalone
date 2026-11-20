// Live-room fullscreen controls (follow-up to build 23, found by the
// portrait-control-bar fix: entering fullscreen after the 5 s
// auto-hide opened with NO controls until the video was tapped).
//
// Root cause: the portrait bar is page chrome (always visible when
// unlocked), so a hidden _controlsVisible is invisible in portrait —
// but the fullscreen overlay bar is gated on it. None of the
// fullscreen entry paths (the [ ] buttons, the double-tap) ever
// re-showed the controls.
//
// The fix: a worker on FullscreenController.isFullscreen that calls
// _showControls() on entry (show + restart the 5 s hide timer).
// Exiting fullscreen leaves the bars alone. VOD is untouched —
// it has its own FullscreenController instance and its own page.
//
// Harness copied from live_room_portrait_control_bar_test.dart
// (Hive temp dir, fakes, pump helpers). ONE pump only: a second
// room pump in the same file hangs on this VM (same note as the
// portrait test). Entering fullscreen flips the flag directly —
// the real [ ] tap calls enterFullscreen(), whose SystemChrome
// awaits never complete in a widget test (established in
// live_room_player_audit_test.dart). After flipping to fullscreen,
// use plain tester.pump() only — never runAsync while the
// fullscreen Flame barrage is mounted.

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
    hiveDir = await Directory.systemTemp.createTemp('hao-room-fs-');
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

  group('live room fullscreen controls', () {
    testWidgets('entering fullscreen re-shows hidden controls and '
        'restarts the 5 s hide', (tester) async {
      await resetStores(tester);
      await pumpRoom(tester);

      // Portrait: exactly one bar (the below-video page chrome).
      expect(find.byTooltip('刷新'), findsOneWidget);

      // Let the 5 s auto-hide fire. The portrait bar stays (page
      // chrome), but the overlay state is now hidden — that is the
      // setup for the bug: entering fullscreen from here used to
      // open with no controls until the video was tapped.
      await tester.pump(const Duration(seconds: 5));

      // Enter fullscreen: the overlay bar must be visible
      // immediately, with no video tap.
      await pumpFullscreen(tester);
      expect(find.byType(AppBar), findsNothing);
      expect(
        find.byTooltip('刷新'),
        findsOneWidget,
        reason: 'entering fullscreen must re-show hidden controls',
      );
      expect(find.text('原画'), findsOneWidget);

      // The hide timer restarted at entry: still visible 4 s in...
      await tester.pump(const Duration(seconds: 4));
      expect(find.byTooltip('刷新'), findsOneWidget);
      // ...and hidden again 2 s later (5 s after entry, not after
      // the old portrait arm — a stale timer would have hidden it
      // before the 4 s check, a missing re-arm would never hide it).
      await tester.pump(const Duration(seconds: 2));
      expect(find.byTooltip('刷新'), findsNothing);

      // Exit fullscreen: portrait bar is page chrome again.
      await pumpPortrait(tester);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byTooltip('刷新'), findsOneWidget);

      // Re-enter fullscreen: controls show again (state was hidden).
      await pumpFullscreen(tester);
      expect(find.byTooltip('刷新'), findsOneWidget);

      // Locked: entering fullscreen must NOT show the overlay —
      // the lock gate hides it, and the unlock button is the only
      // way back. Exit first (the overlay [] is hidden when
      // locked), lock in portrait, re-enter.
      await pumpPortrait(tester);
      await tester.tap(find.byTooltip('锁定控制条'));
      await tester.pump();
      expect(find.byTooltip('解锁控制条'), findsOneWidget);
      await pumpFullscreen(tester);
      expect(
        find.byTooltip('刷新'),
        findsNothing,
        reason: 'locked fullscreen must stay control-free',
      );
      expect(find.byTooltip('解锁控制条'), findsOneWidget);
      await pumpPortrait(tester);
      await tester.tap(find.byTooltip('解锁控制条'));
      await tester.pump();
      expect(find.byTooltip('刷新'), findsOneWidget);

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
