// VOD auto-play-next tests (V-P0-2).
//
// - Pure decision: completion -> next episode; toggle OFF -> stop;
//   last episode -> stop (end state, never loops).
// - Setting: default ON, persisted across reads.
// - Player widget (fake backend via the injected PlaybackSession):
//   completion advances to the next episode in the SAME player (new
//   open, label changes, no detail reload); toggle OFF or the last
//   episode shows the end state; advancing clears the resume
//   position (the new episode is NOT re-seeked to the old position).

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
import 'package:standalone/features/video/video_history_store.dart';
import 'package:standalone/features/video/video_models.dart';

VideoDetail _threeEpisodeDetail() => VideoDetail(
      source: 12,
      vodId: '93344',
      meta: VideoMeta(name: '流浪地球2'),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: const [
            PlayEpisode(
              name: '第1集',
              url: 'https://example.com/ep1.mp4',
            ),
            PlayEpisode(
              name: '第2集',
              url: 'https://example.com/ep2.mp4',
            ),
            PlayEpisode(
              name: '第3集',
              url: 'https://example.com/ep3.mp4',
            ),
          ],
        ),
      ],
    );

/// Minimal fake backend: instant open/first-frame, records opens +
/// seeks, completion fired on demand. No position ticker (keeps the
/// widget test's fake clock quiet).
class _FakeBackend implements PlayerBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  final List<String> openedUrls = [];
  final List<Duration> seeks = [];
  final List<double> rates = [];
  final List<double> volumes = [];
  bool failFirstFrame = false;
  bool _disposed = false;

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  void emitCompleted() => _completed.add(null);

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
  }) async {
    openedUrls.add(url);
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      !failFirstFrame;

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

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
    hiveDir = await Directory.systemTemp.createTemp('hao-autoplay-test-');
    // HiveStore.init() goes through path_provider; point it at a temp
    // dir so the player page + settings can use Hive in tests.
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
  // fire-and-forget deletes never resolve in the widget-test fake zone, so
  // awaiting close() hangs tearDownAll forever. Fire-and-forget: the temp
  // dir is deleted right after anyway.
  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
    // Fire-and-forget: a Hive delete/put Future started in the
    // widget-test fake zone stalls (its value lands in the box
    // synchronously, but the Future only resolves on the real
    // event loop — proven by the L05 follow-toggle case). Awaiting
    // these three deletes hangs tearDown forever and the test
    // never completes. The next test reads the deleted values
    // from memory, so fire-and-forget is correct here.
    unawaited(HiveStore.delete(HiveKeys.videoAutoNext));
    unawaited(HiveStore.delete(HiveKeys.videoHistory));
    unawaited(HiveStore.delete(HiveKeys.vodPlaybackRate));
  });

  group('autoNextEpisodeIndex (pure decision)', () {
    test('completion advances to the next episode', () {
      expect(
        autoNextEpisodeIndex(current: 0, total: 3, autoNext: true),
        1,
      );
      expect(
        autoNextEpisodeIndex(current: 1, total: 3, autoNext: true),
        2,
      );
    });

    test('toggle OFF stops at the end of the episode', () {
      expect(
        autoNextEpisodeIndex(current: 0, total: 3, autoNext: false),
        isNull,
      );
    });

    test('last episode stops — never loops', () {
      expect(
        autoNextEpisodeIndex(current: 2, total: 3, autoNext: true),
        isNull,
      );
    });

    test('single-episode video stops', () {
      expect(
        autoNextEpisodeIndex(current: 0, total: 1, autoNext: true),
        isNull,
      );
    });
  });

  group('VideoPlaybackSettings.autoNext', () {
    test('defaults to ON when nothing is stored', () {
      expect(VideoPlaybackSettings.autoNext, isTrue);
    });

    test('persists OFF then ON', () async {
      await VideoPlaybackSettings.setAutoNext(false);
      expect(VideoPlaybackSettings.autoNext, isFalse);
      await VideoPlaybackSettings.setAutoNext(true);
      expect(VideoPlaybackSettings.autoNext, isTrue);
    });
  });

  group('NativeVideoPlayerPage auto-play (fake backend)', () {
    late PlaybackSession session;
    final backends = <_FakeBackend>[];

    /// Fresh backend per ladder attempt, like production (a new
    /// backend per engine attempt). A shared singleton is wrong here:
    /// on auto-advance the session swaps in the "new" backend and
    /// disposes the old one — with one shared instance that closes
    /// the very streams the session just attached to.
    _FakeBackend currentBackend() => backends.last;
    List<String> openedUrls() =>
        backends.expand((b) => b.openedUrls).toList();
    List<Duration> seeks() => backends.expand((b) => b.seeks).toList();
    List<double> rates() => backends.expand((b) => b.rates).toList();
    List<double> volumes() => backends.expand((b) => b.volumes).toList();

    /// Real-zone settle (repo pattern: danmaku/live tests). The
    /// page's open chain awaits Hive I/O (history record,
    /// LiveBreadcrumb.write); real I/O hangs inside the fake-async
    /// zone, so let it land on the real clock, then pump a frame.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    Future<void> pumpPlayer(
      WidgetTester tester, {
      int initialEpisodeIndex = 0,
      double initialPosition = 0,
      bool failFirstFrame = false,
    }) async {
      backends.clear();
      session = PlaybackSession(
        backendFactory: (_) {
          final b = _FakeBackend()..failFirstFrame = failFirstFrame;
          backends.add(b);
          return b;
        },
      );
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: NativeVideoPlayerPage(
            detail: _threeEpisodeDetail(),
            initialEpisodeIndex: initialEpisodeIndex,
            initialPosition: initialPosition,
            session: session,
          ),
        ),
      );
      // Let the first open + first-frame verification + Hive record land.
      await settle(tester);
      await settle(tester);
    }

    /// Unmount the player so its session dispose (health-watch timer,
    /// backend dispose, Hive save) runs before the next test.
    Future<void> unmountPlayer(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    testWidgets('completion advances to the next episode in place',
        (tester) async {
      await pumpPlayer(tester);
      expect(openedUrls(), ['https://example.com/ep1.mp4']);
      expect(find.text('第1集'), findsOneWidget);

      currentBackend().emitCompleted();
      await settle(tester);

      expect(
        openedUrls(),
        ['https://example.com/ep1.mp4', 'https://example.com/ep2.mp4'],
      );
      expect(find.text('第2集'), findsOneWidget);
      expect(find.text('已播完'), findsNothing);
      await unmountPlayer(tester);
    });

    testWidgets('toggle OFF stops at the end of the episode',
        (tester) async {
      await VideoPlaybackSettings.setAutoNext(false);
      await pumpPlayer(tester);

      currentBackend().emitCompleted();
      await settle(tester);

      expect(openedUrls(), hasLength(1));
      expect(find.text('已播完'), findsOneWidget);
      await unmountPlayer(tester);
    });

    testWidgets('last episode stops at the end state', (tester) async {
      await pumpPlayer(tester, initialEpisodeIndex: 2);
      expect(find.text('第3集'), findsOneWidget);

      currentBackend().emitCompleted();
      await settle(tester);

      expect(openedUrls(), hasLength(1));
      expect(find.text('已播完'), findsOneWidget);
      await unmountPlayer(tester);
    });

    testWidgets('advancing clears the resume position', (tester) async {
      // Opened with a 500 s resume: the first episode seeks once.
      await pumpPlayer(tester, initialPosition: 500);
      expect(seeks(), [const Duration(seconds: 500)]);

      currentBackend().emitCompleted();
      await settle(tester);

      // The new episode opened but was NOT re-seeked to 500 s.
      expect(openedUrls(), hasLength(2));
      expect(seeks(), hasLength(1));
      expect(find.text('第2集'), findsOneWidget);
      await unmountPlayer(tester);
    });

    testWidgets('in-player toggle flips the persisted setting',
        (tester) async {
      await pumpPlayer(tester);
      expect(VideoPlaybackSettings.autoNext, isTrue);

      await tester.tap(find.byTooltip('自动连播'));
      await settle(tester);
      expect(VideoPlaybackSettings.autoNext, isFalse);

      await tester.tap(find.byTooltip('自动连播'));
      await settle(tester);
      expect(VideoPlaybackSettings.autoNext, isTrue);
      await unmountPlayer(tester);
    });

    testWidgets('speed button cycles 1.0x -> 1.25x and reaches the backend',
        (tester) async {
      await pumpPlayer(tester);
      expect(find.text('1.0x'), findsOneWidget);
      expect(rates(), isEmpty);

      await tester.tap(find.text('1.0x'));
      await tester.pump();

      expect(find.text('1.25x'), findsOneWidget);
      expect(rates(), contains(1.25));
      await unmountPlayer(tester);
    });

    testWidgets('long-press plays at 2x, release restores the user rate',
        (tester) async {
      await pumpPlayer(tester);
      expect(rates(), isEmpty);
      expect(find.text('1.0x'), findsOneWidget);

      final gesture = await tester.startGesture(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 600));

      // Long-press won the arena: 2x reached the backend, hint shows,
      // and the speed button also reads 2.0x while held.
      expect(rates(), contains(2.0));
      expect(find.byIcon(Icons.fast_forward), findsOneWidget);
      expect(find.text('2.0x'), findsNWidgets(2));

      await gesture.up();
      await tester.pump();

      // Release restores the user's rate; the persisted rate was never
      // touched by the temporary override.
      expect(rates().last, 1.0);
      expect(VideoPlaybackSettings.playbackRate, 1.0);
      expect(find.byIcon(Icons.fast_forward), findsNothing);
      expect(find.text('1.0x'), findsOneWidget);
      await unmountPlayer(tester);
    });

    testWidgets(
        'failed player still offers a way out — back button pops to home',
        (tester) async {
      // A home page underneath, so the pop has somewhere to go.
      backends.clear();
      session = PlaybackSession(
        backendFactory: (_) {
          final b = _FakeBackend()..failFirstFrame = true;
          backends.add(b);
          return b;
        },
      );
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NativeVideoPlayerPage(
                          detail: _threeEpisodeDetail(),
                          session: session,
                        ),
                      ),
                    );
                  },
                  child: const Text('open player'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open player'));
      await tester.pump();
      await settle(tester);
      await settle(tester);

      // Playback failed on every engine, but the way out is visible:
      // the v1.0.5 trap hid the back button exactly when failed.
      expect(find.text('播放失败，请检查网络后重试'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await settle(tester);
      // The failed open kicked off the fastest-first source sweep
      // (altSourcesStream, 15 s cap timer + Dio fetch timers). The
      // page is gone but the sweep is still awaiting the stream, so
      // its timers stay pending in the fake zone and the framework
      // fails the test ("a Timer is still pending"). Let the 15 s cap
      // fire so the stream closes and the sweep exits before the test
      // ends. On a real phone this is harmless background work (the
      // sweep checks `mounted` before touching anything).
      await tester.pump(const Duration(seconds: 16));

      expect(find.text('open player'), findsOneWidget);
      await unmountPlayer(tester);
    });

    testWidgets('horizontal drag seeks once on release', (tester) async {
      await pumpPlayer(tester);
      currentBackend().emitDuration(const Duration(minutes: 45));
      await settle(tester);

      // 800 px wide = 300 s span; 200 px right -> ~75 s from 0.
      await tester.timedDrag(
        find.byKey(const ValueKey('fake-video')),
        const Offset(200, 0),
        const Duration(milliseconds: 300),
      );
      await settle(tester);

      expect(seeks(), isNotEmpty);
      expect(seeks().last.inSeconds, inInclusiveRange(60, 90));
      await unmountPlayer(tester);
    });

    testWidgets('vertical drag on the right half adjusts volume',
        (tester) async {
      await pumpPlayer(tester);

      // timedDrag (not raw startGesture+moveBy): a bare moveBy
      // dispatches the move without a frame in between, so the
      // vertical-drag recogniser never gets its update before the
      // pointer goes up (proven by tmp_diag_vdrag: hint appears only
      // after up, volumes stays []). timedDrag pumps frames during
      // the drag, like a real finger.
      // 150 px down over a 300 px full range from 1.0 — the drag
      // recogniser only counts movement past the touch slop, so the
      // effective drop is ~125-130 px, not the full 150: expect a
      // range around 0.57, not exactly 0.5.
      await tester.timedDragFrom(
        const Offset(600, 300),
        const Offset(0, 150),
        const Duration(milliseconds: 300),
      );
      await tester.pump();

      expect(volumes(), isNotEmpty);
      expect(volumes().last, inInclusiveRange(0.45, 0.65));
      await unmountPlayer(tester);
    });

    testWidgets('vertical drag on the left half adjusts brightness',
        (tester) async {
      const channel =
          MethodChannel('github.com/aaassseee/screen_brightness');
      final brightnessCalls = <double>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getApplicationScreenBrightness') {
          return 0.5;
        }
        if (call.method == 'setApplicationScreenBrightness') {
          brightnessCalls.add(
            (call.arguments as Map)['brightness'] as double,
          );
        }
        return null;
      });
      try {
        await pumpPlayer(tester);

        // timedDragFrom, not raw startGesture+moveBy (see the volume
        // test above — a bare moveBy never delivers the update).
        // 90 px down from 0.5 over a 300 px full range; the drag
        // recogniser only counts movement past the touch slop, so the
        // effective drop is ~65-70 px: expect ~0.27, as a range.
        await tester.timedDragFrom(
          const Offset(200, 300),
          const Offset(0, 90),
          const Duration(milliseconds: 300),
        );
        await tester.pump();

        expect(brightnessCalls, isNotEmpty);
        expect(brightnessCalls.last, inInclusiveRange(0.2, 0.35));
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
      await unmountPlayer(tester);
    });
  });
}
