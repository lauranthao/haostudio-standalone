// VOD controls reveal + Slider drag vs the auto-hide timer.
//
// chen (v1.0.7 phone):
//  (1) after watching a while the bottom progress bar + control frame
//      disappear and the player cannot be exited;
//  (2) dragging the progress bar sometimes does nothing.
//
// Root causes (proven by the repro run that preceded this file):
//  (1) A press-hold (>500 ms) wins the long-press recognizer over
//      onTap, so it starts 2x speed instead of revealing the
//      controls — the natural "wake" press is exactly the one that
//      fails, and the controls stay hidden with no way out. A quick
//      tap does reveal them, but nothing tells the user that.
//  (2) A Slider drag never cancels the hide timer (the outer
//      seek/brightness drags do). If the timer fires mid-drag, the
//      whole control bar — Slider included — unmounts, the drag is
//      cancelled and onChangeEnd never runs, so no seek happens.
//
// Fixes in native_video_player_page.dart:
//  - hold while hidden -> reveal controls (no 2x); hold while shown
//    -> 2x as before; hide delay 3 s -> 5 s (Pure Live's value);
//  - Slider onChangeStart cancels the hide timer (onChangeEnd
//    already re-arms it).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
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

  void emitDuration(Duration duration) => _duration.add(duration);

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

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-controls-test-');
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

  // NOTE: do NOT await the Hive box close here. Pending Hive deletes from
  // tearDown never resolve in the widget-test fake zone, so awaiting close()
  // hangs tearDownAll forever (same trap as awaiting Hive Futures in
  // tearDown). Fire-and-forget: the temp dir is deleted right after anyway.
  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
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

  // Controls visible = back arrow + fullscreen-exit present.
  bool controlsVisible(WidgetTester tester) =>
      find.byIcon(Icons.arrow_back).evaluate().isNotEmpty &&
      find.byIcon(Icons.fullscreen_exit).evaluate().isNotEmpty;

  testWidgets('quick tap after auto-hide shows controls', (tester) async {
    await pumpPlayer(tester);
    expect(controlsVisible(tester), isTrue, reason: 'start visible');
    await tester.pump(const Duration(seconds: 6));
    expect(controlsVisible(tester), isFalse, reason: 'timer hid controls');
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    expect(controlsVisible(tester), isTrue, reason: 'quick tap shows');
    await unmountPlayer(tester);
  });

  testWidgets('hold after auto-hide reveals controls, does NOT start 2x',
      (tester) async {
    await pumpPlayer(tester);
    await tester.pump(const Duration(seconds: 6));
    expect(controlsVisible(tester), isFalse, reason: 'timer hid controls');
    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 600));
    // Long-press fired, but with controls hidden it must reveal the
    // UI instead of speeding up.
    expect(controlsVisible(tester), isTrue, reason: 'hold reveals controls');
    expect(backend.rates, isEmpty, reason: 'no 2x while hidden');
    await gesture.up();
    await tester.pump();
    expect(controlsVisible(tester), isTrue, reason: 'still shown');
    expect(backend.rates, isEmpty);
    await unmountPlayer(tester);
  });

  testWidgets('hold while controls are shown still does 2x', (tester) async {
    await pumpPlayer(tester);
    expect(controlsVisible(tester), isTrue, reason: 'start visible');
    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 600));
    expect(backend.rates, contains(2.0), reason: '2x while shown');
    expect(controlsVisible(tester), isTrue, reason: 'controls stay up');
    await gesture.up();
    await tester.pump();
    expect(backend.rates.last, 1.0, reason: 'release restores rate');
    await unmountPlayer(tester);
  });

  testWidgets('tap with slight movement after auto-hide shows controls',
      (tester) async {
    await pumpPlayer(tester);
    await tester.pump(const Duration(seconds: 6));
    expect(controlsVisible(tester), isFalse, reason: 'timer hid controls');
    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(5, 3));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump();
    expect(controlsVisible(tester), isTrue);
    await unmountPlayer(tester);
  });

  testWidgets('Slider drag across the hide-timer boundary still seeks',
      (tester) async {
    await pumpPlayer(tester);
    // Duration known -> the Slider is in the tree.
    backend.emitDuration(const Duration(minutes: 45));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(find.byType(Slider), findsOneWidget);
    expect(controlsVisible(tester), isTrue);

    // Start the Slider drag before the 5 s hide timer fires, then
    // hold it well past the timer: without the onChangeStart cancel
    // the timer would fire mid-drag, unmount the control bar and
    // swallow the seek.
    await tester.pump(const Duration(seconds: 2));
    final center = tester.getCenter(find.byType(Slider));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 6));
    expect(
      controlsVisible(tester),
      isTrue,
      reason: 'drag cancels the hide timer; controls must stay up',
    );
    expect(find.byType(Slider), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(backend.seeks, isNotEmpty, reason: 'release seeks');
    await unmountPlayer(tester);
  });
}
