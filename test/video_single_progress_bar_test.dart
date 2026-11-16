// VOD player: exactly ONE progress bar, and the functions on the
// remaining control bar must still work.
//
// chen (v1.0.6 phone test): "看电影为什么有两个进度条" — watching a
// film showed two progress bars. Root cause: media_kit's Video widget
// defaults `controls` to AdaptiveVideoControls, which draws its own
// seek bar + play/pause + fullscreen button UNDERNEATH the app's own
// Pure Live-style control bar (seek Slider, speed, exit-fullscreen).
// The fix (MpvBackend.buildVideoWidget) suppresses the built-in
// controls for VOD, so only the app's bar remains.
//
// These tests guard the app's own bar (the fake backend renders no
// video widget, so they assert the page itself has exactly one Slider
// and that seek / speed / exit-fullscreen on it still work). The
// backend-side suppression itself is verified by code inspection +
// analyze: constructing a real MpvBackend needs the native libmpv,
// which the Linux test harness cannot load.

import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_models.dart';

/// Fake backend that emits a real duration/position and records every
/// seek + rate change, so the tests can prove the remaining control
/// bar still drives playback.
class _SeekRecordingFakeBackend implements PlayerBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  bool _disposed = false;
  final seeks = <Duration>[];
  final rates = <double>[];

  void emitPosition(Duration p) => _position.add(p);
  void emitDuration(Duration d) => _duration.add(d);

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  @override
  Widget buildVideoWidget() => const SizedBox.shrink();

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
  Future<void> setRate(double rate) async => rates.add(rate);

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Future<void> seekTo(Duration position) async => seeks.add(position);

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

VideoDetail _detail() => VideoDetail(
      source: 1,
      vodId: 'v1',
      meta: VideoMeta(name: '测试影片'),
      lines: const [
        PlayLine(name: '线路1', episodes: [
          PlayEpisode(name: '第01集', url: 'https://example.com/ep1.mp4'),
        ]),
      ],
    );

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-one-bar-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
  });

  /// Pump the app, push the real player page, and feed it a 1-hour
  /// film at 2:00 so the seek Slider renders.
  Future<_SeekRecordingFakeBackend> openPlayer(
    WidgetTester tester,
  ) async {
    final created = <_SeekRecordingFakeBackend>[];
    final session = PlaybackSession(
      backendFactory: (engine) {
        final b = _SeekRecordingFakeBackend();
        created.add(b);
        return b;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open'),
                onPressed: () {
                  Navigator.of(context).push(
                    CupertinoPageRoute<void>(
                      builder: (_) => NativeVideoPlayerPage(
                        detail: _detail(),
                        session: session,
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    // Let the Cupertino push transition FINISH (300 ms): tapping
    // right-side controls at 100 ms misses — the page is still
    // sliding in and the buttons sit past the 800 px test surface.
    await tester.pump(const Duration(milliseconds: 500));
    final backend = created.single;
    backend.emitDuration(const Duration(seconds: 3600));
    backend.emitPosition(const Duration(seconds: 120));
    await tester.pump();
    return backend;
  }

  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('VOD player shows exactly one progress bar (Slider)',
      (tester) async {
    await openPlayer(tester);
    // The page's own seek Slider — and no second bar anywhere.
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await drain(tester);
  });

  testWidgets('dragging the remaining seek bar seeks forward',
      (tester) async {
    final backend = await openPlayer(tester);
    await tester.drag(find.byType(Slider), const Offset(200, 0));
    await tester.pump();
    expect(backend.seeks, isNotEmpty,
        reason: 'dragging the seek bar must seek');
    expect(backend.seeks.last, greaterThan(const Duration(seconds: 120)),
        reason: 'dragging right must seek forward from 2:00');
    await drain(tester);
  });

  testWidgets('speed button still cycles the rate', (tester) async {
    final backend = await openPlayer(tester);
    expect(find.text('1.0x'), findsOneWidget);
    await tester.tap(find.text('1.0x'));
    await tester.pump();
    expect(find.text('1.25x'), findsOneWidget,
        reason: 'tap must cycle 1.0x -> 1.25x (Pure Live rates)');
    expect(backend.rates, contains(1.25));
    await drain(tester);
  });

  testWidgets('exit-fullscreen button still pops the page',
      (tester) async {
    await openPlayer(tester);
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pump();
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(NativeVideoPlayerPage).evaluate().isEmpty) break;
    }
    expect(find.byType(NativeVideoPlayerPage), findsNothing,
        reason: 'exit-fullscreen must leave the player page');
    await drain(tester);
  });
}
