// Danmaku settings take effect in the live room (Flutter v1.0.4).
//
// Proves the live room honours DanmakuSettings (Hive-backed):
// - Per-platform disable: NO transport is started and the room shows
//   an honest "弹幕已关闭" state (not a fake empty list, not an error).
// - Font size + opacity from the settings style the danmaku list.
// - Changes apply IMMEDIATELY while the room is open: toggling the
//   switch mid-room stops/starts the transport, and a font/opacity
//   change restyles the list without leaving the room.
//
// Fakes only — no network. The fake site serves one quality + one line
// and a fake danmaku transport that records start/stop and can emit
// messages on demand.

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
import 'package:standalone/domains/live/presentation/playback/live_room_page.dart';
import 'package:standalone/features/settings/source_stores.dart';
import 'package:standalone/shared/platforms/live_site.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-danmaku-test-');
    // HiveStore.init() goes through path_provider; point it at a temp
    // dir so LiveRoomPage / DanmakuSettings can use Hive in tests.
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
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
  });

  group('DanmakuSettings in LiveRoomPage', () {
    /// Let real async work drain: LiveRoomPage awaits Hive writes and
    /// a widget test's fake clock never drains real async I/O on its
    /// own. Without this, _loadRoom stalls and the room never resolves.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    Future<void> pumpRoom(WidgetTester tester, _FakeSite site) async {
      // Phone-tall viewport: the room Column (16:9 video + info +
      // quality row + danmaku) is ~600 px tall and overflows the
      // default 800x600 test surface, pushing the danmaku area
      // off-screen.
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveRoomPage(
            room: const LiveRoom(
              roomId: '660000',
              platform: 'huya',
              title: 'test room',
              nick: 'tester',
              liveStatus: true,
            ),
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
    }

    /// Unmount the page so its session dispose runs, then let any
    /// Get snackbar finish its auto-dismiss (its AnimationController
    /// ticker outlives the Overlay otherwise).
    Future<void> disposeRoom(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    /// Danmaku settings writes are Hive I/O: they must run in the real
    /// zone (runAsync); they hang inside the fake-async zone. The
    /// room's Hive listenable is fed by box.watch(), whose events
    /// arrive asynchronously — settle() (real 200 ms + pump) after the
    /// write so the listener's setState has landed before asserting.
    Future<void> setDanmakuEnabled(
      WidgetTester tester,
      bool value,
    ) async {
      await tester.runAsync(
        () => DanmakuSettings.setEnabled('huya', value),
      );
      await settle(tester);
    }

    Future<void> setDanmakuStyle(
      WidgetTester tester, {
      double? fontSize,
      double? opacity,
    }) async {
      await tester.runAsync(() async {
        if (fontSize != null) {
          await DanmakuSettings.setFontSize(fontSize);
        }
        if (opacity != null) {
          await DanmakuSettings.setOpacity(opacity);
        }
      });
      await settle(tester);
    }

    testWidgets('disabled platform: no transport, honest 已关闭 state', (
      tester,
    ) async {
      await setDanmakuEnabled(tester, false);
      final site = _FakeSite();
      await pumpRoom(tester, site);
      expect(site.danmaku.startCount, 0);
      expect(find.text('弹幕已关闭'), findsOneWidget);
      expect(find.text('暂无弹幕'), findsNothing);
      expect(find.text('弹幕加载中…'), findsNothing);
      await disposeRoom(tester);
    });

    testWidgets('enabled platform: transport starts, messages render '
        'with the configured font size + opacity', (tester) async {
      await setDanmakuEnabled(tester, true);
      await setDanmakuStyle(tester, fontSize: 14, opacity: 1.0);
      final site = _FakeSite();
      await pumpRoom(tester, site);
      expect(site.danmaku.startCount, 1);
      site.danmaku.emit(
        const LiveMessage(userName: 'Alice', message: 'hello'),
      );
      await tester.pump();
      expect(find.text('Alice: hello'), findsOneWidget);
      final text = tester.widget<Text>(find.text('Alice: hello'));
      expect(text.style?.fontSize, 14);
      final opacity = tester.widget<Opacity>(
        find.ancestor(
          of: find.text('Alice: hello'),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, 1.0);
      await disposeRoom(tester);
    });

    testWidgets('font size + opacity change updates the open room', (
      tester,
    ) async {
      await setDanmakuEnabled(tester, true);
      await setDanmakuStyle(tester, fontSize: 14, opacity: 1.0);
      final site = _FakeSite();
      await pumpRoom(tester, site);
      site.danmaku.emit(
        const LiveMessage(userName: 'Alice', message: 'hello'),
      );
      await tester.pump();
      expect(find.text('Alice: hello'), findsOneWidget);
      // Change both settings while the room is open: no restart, no
      // re-entry — the list restyles in place.
      await setDanmakuStyle(tester, fontSize: 20, opacity: 0.5);
      await tester.pump();
      final text = tester.widget<Text>(find.text('Alice: hello'));
      expect(text.style?.fontSize, 20);
      final opacity = tester.widget<Opacity>(
        find.ancestor(
          of: find.text('Alice: hello'),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, 0.5);
      // The transport was never restarted by a style change.
      expect(site.danmaku.startCount, 1);
      expect(site.danmaku.stopCount, 0);
      await disposeRoom(tester);
    });

    testWidgets('disabling mid-room stops the transport and shows 已关闭',
        (tester) async {
      await setDanmakuEnabled(tester, true);
      final site = _FakeSite();
      await pumpRoom(tester, site);
      site.danmaku.emit(
        const LiveMessage(userName: 'Alice', message: 'hello'),
      );
      await tester.pump();
      expect(find.text('Alice: hello'), findsOneWidget);
      expect(site.danmaku.startCount, 1);
      await setDanmakuEnabled(tester, false);
      await tester.pump();
      expect(site.danmaku.stopCount, 1);
      expect(find.text('弹幕已关闭'), findsOneWidget);
      expect(find.text('Alice: hello'), findsNothing);
      await disposeRoom(tester);
    });

    testWidgets('re-enabling mid-room restarts the transport', (
      tester,
    ) async {
      await setDanmakuEnabled(tester, false);
      final site = _FakeSite();
      await pumpRoom(tester, site);
      expect(site.danmaku.startCount, 0);
      expect(find.text('弹幕已关闭'), findsOneWidget);
      await setDanmakuEnabled(tester, true);
      await settle(tester);
      expect(site.danmaku.startCount, 1);
      expect(find.text('弹幕已关闭'), findsNothing);
      site.danmaku.emit(
        const LiveMessage(userName: 'Bob', message: 'back'),
      );
      await tester.pump();
      expect(find.text('Bob: back'), findsOneWidget);
      await disposeRoom(tester);
    });
  });
}

/// Fake LiveSite with one quality + one line and a fake danmaku
/// transport. [danmaku] is exposed so tests can assert start/stop
/// counts and emit messages on demand.
class _FakeSite extends LiveSite {
  final _FakeDanmaku danmaku = _FakeDanmaku();

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

/// Fake danmaku transport: records start/stop and emits messages
/// through onMessage on demand.
class _FakeDanmaku extends LiveDanmaku {
  int startCount = 0;
  int stopCount = 0;

  @override
  bool get isConnected => startCount > stopCount;

  void emit(LiveMessage message) => onMessage?.call(message);

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
/// tickers, no timers — the session health watch only fires after
/// 4 s of no positions, which no test here pumps past while mounted.
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
