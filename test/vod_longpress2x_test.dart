// VOD long-press 2x (Bilibili-style hold to speed up).
//
// Pins the three behaviours of native_video_player_page.dart
// `_onLongPressStart` / `_onLongPressEnd` /
// `_restoreRateAfterLongPress`:
//  (1) hold while the controls are shown -> 2x + the rate label
//      reads 2.0x (the persisted rate is never changed — the hold
//      is a temporary override only);
//  (2) release -> the user's rate (1.0x) is restored;
//  (3) the haptic gate: the medium confirmation fires with the
//      master switch on and is silent with it off, while 2x still
//      applies in both cases (haptics off must never block speed).
//
// The hold-while-hidden case (reveal, no 2x) is pinned in
// video_controls_show_test.dart, not repeated here.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_models.dart';

VideoDetail _detail() => VideoDetail(
      source: 12,
      vodId: '93344',
      meta: VideoMeta(name: '流浪地球2'),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: const [
            PlayEpisode(name: '第1集', url: 'https://example.com/ep1.mp4'),
          ],
        ),
      ],
    );

class _FakeBackend implements PlayerBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final List<double> rates = [];
  final List<Duration> seeks = [];
  bool _disposed = false;

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
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
  }

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Future<void> seekTo(Duration position) async {
    seeks.add(position);
  }

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

void main() {
  late Directory hiveDir;

  // The platform channel `flutter/platform` records every
  // HapticFeedback call (same pattern as haptics_test.dart).
  const hapticChannel = MethodChannel('flutter/platform', JSONMethodCodec());
  final hapticCalls = <MethodCall>[];

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-longpress2x-test-');
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

  // NOTE: do NOT await the Hive box close here (same trap as
  // video_controls_show_test.dart — pending deletes never resolve
  // in the widget-test fake zone and hang tearDownAll).
  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    hapticCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hapticChannel, (call) async {
      hapticCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    Get.reset();
    HaoHaptics.debugEnabledOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hapticChannel, null);
    unawaited(HiveStore.delete(HiveKeys.videoHistory));
    unawaited(HiveStore.delete(HiveKeys.vodPlaybackRate));
  });

  late PlaybackSession session;
  late _FakeBackend backend;

  Future<void> pumpPlayer(WidgetTester tester) async {
    backend = _FakeBackend();
    session = PlaybackSession(backendFactory: (_) => backend);
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: NativeVideoPlayerPage(detail: _detail(), session: session),
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
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  // _fire is unawaited fire-and-forget; flush the microtask queue
  // so the platform call lands in hapticCalls before asserting.
  Future<void> flushHaptics(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  testWidgets('hold while controls shown plays at 2x, label reads 2.0x',
      (tester) async {
    await pumpPlayer(tester);
    expect(find.text('1.0x'), findsOneWidget, reason: 'user rate first');
    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 600));
    expect(backend.rates, contains(2.0), reason: 'hold -> 2x');
    // Two "2.0x" while held, both intended: the bottom-bar speed
    // button (14pt, _rateLabel) and the centre long-press hint
    // pill (16pt, _LongPressSpeedHint). Same as the autoplay test.
    expect(find.text('2.0x'), findsNWidgets(2), reason: 'label follows');
    await gesture.up();
    await tester.pump();
    await unmountPlayer(tester);
  });

  testWidgets('release restores the user rate', (tester) async {
    await pumpPlayer(tester);
    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 600));
    expect(backend.rates, contains(2.0));
    await gesture.up();
    await tester.pump();
    expect(backend.rates.last, 1.0, reason: 'release restores 1.0x');
    expect(find.text('1.0x'), findsOneWidget, reason: 'label restored');
    await unmountPlayer(tester);
  });

  testWidgets('haptics on: hold fires one mediumImpact', (tester) async {
    HaoHaptics.debugEnabledOverride = true;
    await pumpPlayer(tester);
    hapticCalls.clear();
    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 600));
    await flushHaptics(tester);
    expect(backend.rates, contains(2.0), reason: '2x still applies');
    final mediums = hapticCalls
        .where((c) => c.arguments == 'HapticFeedbackType.mediumImpact')
        .toList();
    expect(mediums, hasLength(1), reason: 'one medium confirmation');
    await gesture.up();
    await tester.pump();
    await unmountPlayer(tester);
  });

  testWidgets('haptics off: hold still plays 2x, fires no haptic',
      (tester) async {
    HaoHaptics.debugEnabledOverride = false;
    await pumpPlayer(tester);
    hapticCalls.clear();
    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 600));
    await flushHaptics(tester);
    expect(backend.rates, contains(2.0),
        reason: 'haptics off must never block speed');
    expect(hapticCalls, isEmpty, reason: 'gate silences the confirmation');
    await gesture.up();
    await tester.pump();
    expect(backend.rates.last, 1.0, reason: 'release still restores');
    await unmountPlayer(tester);
  });
}
