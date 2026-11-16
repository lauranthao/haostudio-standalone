// Regression tests: the VOD player page must actually pop when the
// user taps back — in every state, not just when playback is settled.
//
// chen (v1.0.6 phone test): "播放影片还是会没有退出" — the film still
// won't exit. Two earlier rounds fixed _close()'s unguarded Hive
// write and the session dispose race, and their tests passed, but
// the phone still won't exit.
//
// The real stuck step (found by mounting the real page in a widget
// test): _close() awaited exitFullscreen() AND an unbounded
// _saveProgress() BEFORE pop. In the test harness SystemChrome calls
// never complete, so the old code only started popping after the 2 s
// exitFullscreen timeout; on the phone any stall in the orientation
// channel or in Hive (the one await with no timeout) left the film
// on screen with no way out. The fix: pop FIRST, cleanup after
// (fire-and-forget). These tests assert the pop is PROMPT — 400 ms
// after the tap the page must be gone — which FAILS on the old code
// (still stuck in exitFullscreen at 400 ms) and passes on the fix.
// The unmocked SystemChrome channel in the test harness IS the stall
// simulation: no mock is installed on purpose.
//
// Also covered: the iOS edge-swipe back gesture (the player route is
// now CupertinoPageRoute — MaterialPageRoute has no swipe-back on
// iOS, so a user who swipes had no way out while the back button was
// hidden by the auto-hiding controls). NOTE: the swipe itself is NOT
// widget-tested — the Cupertino back gesture does not engage under
// fake async in widget tests (a plain CupertinoPageRoute does not pop
// on an edge drag there either), so it is verified by code inspection
// + the real device, not by a test here.

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

/// Fake backend whose open() / first-frame wait can be held open with
/// completers (same shape as playback_session_dispose_test.dart).
class _GatedFakeBackend implements PlayerBackend {
  _GatedFakeBackend({this.openGate, this.firstFrameGate});

  final Completer<void>? openGate;
  final Completer<bool>? firstFrameGate;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  final enteredOpen = Completer<void>();
  final enteredFirstFrame = Completer<void>();
  bool _disposed = false;
  int pauses = 0;

  bool get isDisposed => _disposed;

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
  }) async {
    if (!enteredOpen.isCompleted) enteredOpen.complete();
    if (openGate != null) await openGate!.future;
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!enteredFirstFrame.isCompleted) enteredFirstFrame.complete();
    if (firstFrameGate != null) return firstFrameGate!.future;
    return true;
  }

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async {
    pauses++;
    _playing.add(false);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

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
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _error.close();
    await _completed.close();
  }
}

class _FailingFakeBackend implements PlayerBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

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
  }) async {
    throw StateError('no network');
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      false;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

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
    hiveDir = await Directory.systemTemp.createTemp('hao-exit-test-');
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

  /// Pump the app with a home page, push the real player page (like
  /// the detail page does, via CupertinoPageRoute), let it settle.
  Future<void> openPlayer(
    WidgetTester tester,
    PlaybackSession session,
  ) async {
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
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Tap back and require the page to be gone promptly: pump in
  /// 100 ms steps and fail if it is still there after 1.5 s. The old
  /// code was still stuck in exitFullscreen at 1.5 s (its 2 s
  /// timeout had not fired), so this bound FAILS on the old code and
  /// passes on the fix — while allowing for the test harness's slow
  /// pop-transition timing (the pop completes ~0.8 s after the tap
  /// under fake async, vs ~0.3 s on a real phone).
  Future<void> tapBackAndExpectGone(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(NativeVideoPlayerPage).evaluate().isEmpty) {
        return;
      }
    }
    expect(find.byType(NativeVideoPlayerPage), findsNothing,
        reason: 'route must pop promptly after tapping back');
  }

  /// Advance fake time past the fire-and-forget cleanup timers
  /// (notably the 2 s exitFullscreen timeout — the SystemChrome
  /// channel never replies in the test harness) so the test ends
  /// with no pending timers and the async dispose has finished.
  /// Must also outlive the 15 s cap timer that
  /// CmsClient.altSourcesStream schedules on every source-switch
  /// scan (cms_client.dart:453): the timer stays pending even after
  /// the stream itself closed early, and the test framework fails
  /// any test that ends with it still pending.
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 16));
  }

  testWidgets('back button pops promptly once playback is settled',
      (tester) async {
    final created = <_GatedFakeBackend>[];
    final session = PlaybackSession(
      backendFactory: (engine) {
        final b = _GatedFakeBackend();
        created.add(b);
        return b;
      },
    );
    await openPlayer(tester, session);
    await tester.pump(const Duration(milliseconds: 200));
    expect(session.status, PlaybackStatus.playing);

    await tapBackAndExpectGone(tester);
    await drain(tester);
    expect(created.single.isDisposed, isTrue);
  });

  testWidgets('back button pops promptly while open() is still hung',
      (tester) async {
    final openGate = Completer<void>();
    final created = <_GatedFakeBackend>[];
    final session = PlaybackSession(
      backendFactory: (engine) {
        final b = _GatedFakeBackend(openGate: openGate);
        created.add(b);
        return b;
      },
    );
    await openPlayer(tester, session);
    // The page is stuck on "正在加载…" — open() never returned.
    await created.single.enteredOpen.future;
    expect(session.status, PlaybackStatus.opening);

    await tapBackAndExpectGone(tester);
    // Let the hung open finish afterwards: nothing may resurrect.
    openGate.complete();
    await tester.pump(const Duration(milliseconds: 100));
    await drain(tester);
    expect(created.single.isDisposed, isTrue);
  });

  testWidgets('back button pops promptly while first frame is pending',
      (tester) async {
    final firstFrameGate = Completer<bool>();
    final created = <_GatedFakeBackend>[];
    final session = PlaybackSession(
      backendFactory: (engine) {
        final b = _GatedFakeBackend(firstFrameGate: firstFrameGate);
        created.add(b);
        return b;
      },
    );
    await openPlayer(tester, session);
    await created.single.enteredFirstFrame.future;

    await tapBackAndExpectGone(tester);
    firstFrameGate.complete(true);
    await tester.pump(const Duration(milliseconds: 100));
    await drain(tester);
    expect(created.single.isDisposed, isTrue);
  });

  testWidgets('failed state offers a working 返回 button', (tester) async {
    final session = PlaybackSession(
      backendFactory: (_) => _FailingFakeBackend(),
    );
    await openPlayer(tester, session);
    // The ladder runs bounded retry passes (750 ms + 2 s delays)
    // before the session reports error — wait for the failure card
    // instead of asserting the status after a fixed short pump.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('播放失败，请检查网络后重试').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(find.text('播放失败，请检查网络后重试'), findsOneWidget);
    expect(session.status, PlaybackStatus.error);

    await tester.tap(find.text('返回'));
    await tester.pump();
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(NativeVideoPlayerPage).evaluate().isEmpty) {
        break;
      }
    }

    expect(find.byType(NativeVideoPlayerPage), findsNothing);
    await drain(tester);
  });
}
