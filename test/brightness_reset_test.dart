// Brightness reset tests (chen: brightness/volume belong ONLY in
// the video + live players, and the app must never fight the system
// brightness the user sets in Control Center).
//
// Root cause: setApplicationScreenBrightness writes the DEVICE
// brightness and the iOS plugin remembers it; with isAutoReset
// (default true) the plugin re-applies the remembered app value on
// every foreground return. The players set brightness but never
// reset it, so the player value leaked onto every page and kept
// overwriting the user's Control Center brightness on return.
// Fix: ScreenBrightness.reset() on dispose AND on backgrounding
// (paused), and re-read (never re-apply) on foreground; the VOD
// drag also re-reads the current brightness at drag start instead
// of anchoring to its init-time capture.
//
// Mocked platform channel: the plugin's method channel
// 'github.com/aaassseee/screen_brightness' — no native side runs
// in tests. What widget tests CANNOT prove (said plainly): the
// real on-device feel — whether the screen visibly returns to the
// system level on exit, and whether Control Center changes survive
// a foreground return on chen's phone. That is for his phone check.

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
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/player/screen_brightness.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/shared/platforms/live_site.dart';

/// Records calls on the screen_brightness method channel. `current`
/// is what getApplicationScreenBrightness returns — tests move it
/// to simulate the user changing brightness in Control Center.
class _BrightnessMock {
  double current = 0.5;
  int getCount = 0;
  final sets = <double>[];
  int resetCount = 0;
  bool throwOnReset = false;

  static const channel =
      MethodChannel('github.com/aaassseee/screen_brightness');

  Future<dynamic> _handler(MethodCall call) async {
    switch (call.method) {
      case 'getApplicationScreenBrightness':
        getCount++;
        return current;
      case 'setApplicationScreenBrightness':
        sets.add((call.arguments as Map)['brightness'] as double);
        return null;
      case 'resetApplicationScreenBrightness':
        if (throwOnReset) {
          throw PlatformException(code: '-1', message: 'reset failed');
        }
        resetCount++;
        return null;
      default:
        return null;
    }
  }

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handler);
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

VideoDetail _threeEpisodeDetail() => VideoDetail(
      source: 12,
      vodId: '93344',
      meta: VideoMeta(name: '流浪地球2'),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: const [
            PlayEpisode(name: '第1集', url: 'https://example.com/ep1.mp4'),
            PlayEpisode(name: '第2集', url: 'https://example.com/ep2.mp4'),
            PlayEpisode(name: '第3集', url: 'https://example.com/ep3.mp4'),
          ],
        ),
      ],
    );

/// Minimal fake backend: instant open/first-frame, no position
/// ticker (keeps the widget test's fake clock quiet).
class _FakeBackend implements PlayerBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  int playCount = 0;
  int pauseCount = 0;
  final audioOnlyCalls = <bool>[];
  bool _disposed = false;

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  void emitCompleted() => _completed.add(null);

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
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {
    audioOnlyCalls.add(audioOnly);
  }

  @override
  Future<void> setRate(double rate) async {}

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
    if (_disposed) return;
    _disposed = true;
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}

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

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-brightness-test-');
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
    unawaited(HiveStore.delete(HiveKeys.videoAutoNext));
    unawaited(HiveStore.delete(HiveKeys.videoHistory));
    unawaited(HiveStore.delete(HiveKeys.vodPlaybackRate));
  });

  group('ScreenBrightness.reset (unit)', () {
    test('reset calls resetApplicationScreenBrightness', () async {
      final mock = _BrightnessMock()..install();
      try {
        await ScreenBrightness.reset();
        expect(mock.resetCount, 1);
        expect(mock.sets, isEmpty);
      } finally {
        mock.uninstall();
      }
    });

    test('reset never throws when the channel fails', () async {
      final mock = _BrightnessMock()
        ..throwOnReset = true
        ..install();
      try {
        // Must complete normally — a missing/failing native side
        // must never crash dispose or the lifecycle handler.
        await ScreenBrightness.reset();
        expect(mock.resetCount, 0);
      } finally {
        mock.uninstall();
      }
      // No mock at all (no native side): still completes normally.
      await ScreenBrightness.reset();
      expect(await ScreenBrightness.getBrightness(), 0.5);
      await ScreenBrightness.setBrightness(0.8);
    });
  });

  group('NativeVideoPlayerPage brightness', () {
    late _BrightnessMock brightness;

    setUp(() {
      brightness = _BrightnessMock()..install();
    });

    tearDown(() {
      brightness.uninstall();
    });

    /// Real-zone settle (repo pattern: danmaku/live tests). The
    /// page's open chain awaits Hive I/O; real I/O hangs inside
    /// the fake-async zone, so let it land on the real clock.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    Future<void> pumpPlayer(WidgetTester tester) async {
      final session = PlaybackSession(
        backendFactory: (_) => _FakeBackend(),
      );
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: NativeVideoPlayerPage(
            detail: _threeEpisodeDetail(),
            session: session,
          ),
        ),
      );
      await settle(tester);
      await settle(tester);
    }

    Future<void> unmountPlayer(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await settle(tester);
    }

    Future<void> background(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      await settle(tester);
    }

    Future<void> foreground(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      await settle(tester);
    }

    testWidgets('dispose hands the brightness back to the system',
        (tester) async {
      await pumpPlayer(tester);
      expect(brightness.resetCount, 0);
      expect(brightness.sets, isEmpty);

      await unmountPlayer(tester);

      expect(brightness.resetCount, greaterThanOrEqualTo(1));
      // Leaving the player never writes a brightness value.
      expect(brightness.sets, isEmpty);
    });

    testWidgets(
        'background resets; foreground re-reads and never re-applies',
        (tester) async {
      await pumpPlayer(tester);
      final getsAfterOpen = brightness.getCount;
      expect(getsAfterOpen, greaterThanOrEqualTo(1));

      // The user moves brightness in Control Center while the app
      // is backgrounded — the old player value must not come back.
      await background(tester);
      expect(brightness.resetCount, greaterThanOrEqualTo(1));
      expect(brightness.sets, isEmpty);

      brightness.current = 0.8;
      await foreground(tester);

      // Foreground re-reads the current (system) brightness as the
      // next drag's seed, and never calls setBrightness.
      expect(brightness.getCount, greaterThan(getsAfterOpen));
      expect(brightness.sets, isEmpty);
      expect(brightness.resetCount, greaterThanOrEqualTo(1));

      await unmountPlayer(tester);
    });

    testWidgets(
        'vertical drag on the left half anchors to the freshly read brightness',
        (tester) async {
      await pumpPlayer(tester);
      // Player opened at 0.5; the user then moved brightness to
      // 0.8 in Control Center. The drag must anchor at 0.8, not
      // at the stale init-time 0.5.
      brightness.current = 0.8;

      await tester.timedDragFrom(
        const Offset(200, 300),
        const Offset(0, 90),
        const Duration(milliseconds: 300),
      );
      await tester.pump();

      expect(brightness.sets, isNotEmpty);
      // First write is near the fresh 0.8 anchor (first move is a
      // small delta down); a stale 0.5 anchor would start ~0.45.
      expect(brightness.sets.first, greaterThan(0.7));
      // 90 px down over a 300 px full range from 0.8.
      expect(brightness.sets.last, inInclusiveRange(0.5, 0.65));
      await unmountPlayer(tester);
    });
  });

  group('LiveRoomPage brightness', () {
    late _BrightnessMock brightness;

    setUp(() {
      brightness = _BrightnessMock()..install();
    });

    tearDown(() {
      brightness.uninstall();
    });

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    Future<void> pumpRoom(WidgetTester tester) async {
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
              watching: 1234,
            ),
            site: _FakeSite(),
            backendFactory: (_) => _FakeBackend(),
          ),
        ),
      );
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
    }

    Future<void> disposeRoom(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await settle(tester);
    }

    Future<void> background(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      await settle(tester);
    }

    Future<void> foreground(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      await settle(tester);
    }

    testWidgets('dispose hands the brightness back to the system',
        (tester) async {
      await pumpRoom(tester);
      expect(brightness.resetCount, 0);

      await disposeRoom(tester);

      expect(brightness.resetCount, greaterThanOrEqualTo(1));
      expect(brightness.sets, isEmpty);
    });

    testWidgets(
        'background resets; foreground never re-applies a brightness value',
        (tester) async {
      await pumpRoom(tester);

      await background(tester);
      expect(brightness.resetCount, greaterThanOrEqualTo(1));
      expect(brightness.sets, isEmpty);

      await foreground(tester);
      // Foreground restores the video track and resumes — but must
      // not write any brightness value.
      expect(brightness.sets, isEmpty);

      await disposeRoom(tester);
    });
  });
}
