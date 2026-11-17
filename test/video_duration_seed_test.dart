// VOD progress bar missing entirely — reproduction + fix verification.
//
// chen (v1.0.8 phone, 2026-11-17): "影视的影片还是不能滑播放进度" — corrected:
// "不是进度条拖不动，是根本没有进度条". The Slider is not in the tree at
// all while the film plays.
//
// Root cause (proven, see the test below): the Slider only renders when
// `_duration > 0` (native_video_player_page.dart, `if (_duration > 0)`),
// and `_duration` only comes from the backend durationStream. But the
// duration is a ONE-SHOT signal: mpv reports it once, when the playlist
// is parsed — during `candidate.open()` + `waitForFirstFrame()`, BEFORE
// the session's `_swapBackend` -> `_attachBackend` subscribes to
// `backend.durationStream`. media_kit's durationController is a plain
// broadcast StreamController (platform_player.dart: `StreamController
// .broadcast()` — no replay), so the event is dropped. A VOD duration
// never changes, so no later event ever arrives: `_duration` stays 0
// forever and the Slider never renders. Position works because it fires
// continuously; duration fires once.
//
// The previous test (video_controls_show_test.dart) never covered this:
// it calls `backend.emitDuration(45 min)` AFTER the page is built —
// i.e. after subscription — so the Slider appears in tests. On the
// phone the event fires BEFORE subscription. That is the test-vs-phone
// gap.
//
// The fix: backends seed the already-known duration when the stream is
// first listened to (`seedKnownDuration` in player_backend.dart; MPV
// reads `_player.state.duration`, AVPlayer its `_lastDuration`; IJK
// already re-polls the value every 500 ms and needs no change).
//
// Tests here:
//  (1) helper unit tests — the seed is emitted first, then live events
//      flow; a zero/unknown duration seeds nothing;
//  (2) phone reproduction — a backend that KNOWS the duration at open
//      (45 min, like mpv's state.duration after parsing the playlist)
//      but whose stream never re-emits it after subscription (the raw
//      broadcast behaviour) shows NO Slider — chen's phone, in a test;
//  (3) fixed behaviour — the same backend, but its stream seeds the
//      known duration via the helper, shows the Slider and a drag
//      seeks.

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
            PlayEpisode(name: '第1集', url: 'https://example.com/ep1.m3u8'),
          ],
        ),
      ],
    );

/// Fake backend that mimics the real MPV backend's duration behaviour:
/// the duration is KNOWN internally at open time (like mpv's
/// `state.duration` after the playlist is parsed), but the stream only
/// emits what is explicitly pushed into it after subscription.
class _PhoneLikeBackend implements PlayerBackend {
  _PhoneLikeBackend({required this.knownDuration, required this.seed});

  /// The duration the backend already knows (mpv state.duration).
  final Duration knownDuration;

  /// When true, the stream seeds the known duration on subscribe (the
  /// fix). When false, the stream stays silent (the bug).
  final bool seed;

  final _position = StreamController<Duration>.broadcast();
  final _liveDuration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();
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
  }) async {
    // Position moves so the session verifies the first frame and the
    // page leaves the loading state, exactly like a real playing film.
    _position.add(const Duration(seconds: 12));
  }

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
  Future<void> setRate(double rate) async {}

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => seed
      ? seedKnownDuration(knownDuration, _liveDuration.stream)
      : _liveDuration.stream;

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
    await _liveDuration.close();
    await _playing.close();
    await _error.close();
    await _completed.close();
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-duration-test-');
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

  // NOTE: do NOT await the Hive box close here. Pending Hive deletes
  // from tearDown never resolve in the widget-test fake zone, so
  // awaiting close() hangs tearDownAll forever (same trap as awaiting
  // Hive Futures in tearDown). Fire-and-forget.
  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
    unawaited(HiveStore.delete(HiveKeys.videoHistory));
    unawaited(HiveStore.delete(HiveKeys.vodPlaybackRate));
  });

  group('seedKnownDuration helper', () {
    test('seeds the known duration first, then forwards live events',
        () async {
      final live = StreamController<Duration>();
      final out = seedKnownDuration(
        const Duration(minutes: 45),
        live.stream,
      );
      final seen = <Duration>[];
      final sub = out.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      live.add(const Duration(minutes: 46));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      await live.close();
      expect(seen, [
        const Duration(minutes: 45),
        const Duration(minutes: 46),
      ]);
    });

    test('a zero/unknown duration seeds nothing', () async {
      final live = StreamController<Duration>();
      final out = seedKnownDuration(Duration.zero, live.stream);
      final seen = <Duration>[];
      final sub = out.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      await live.close();
      expect(seen, isEmpty);
    });
  });

  _PhoneLikeBackend? lastBackend;

  Future<void> pumpPlayer(
    WidgetTester tester, {
    required bool seed,
  }) async {
    final backend = _PhoneLikeBackend(
      knownDuration: const Duration(minutes: 45),
      seed: seed,
    );
    lastBackend = backend;
    final session = PlaybackSession(backendFactory: (_) => backend);
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

  testWidgets(
      'REPRODUCTION (chen phone): duration known at open but stream '
      'silent after subscribe -> NO Slider', (tester) async {
    await pumpPlayer(tester, seed: false);
    // The film is playing and the controls are up, but the duration
    // event was already lost before subscription.
    expect(controlsVisible(tester), isTrue,
        reason: 'controls are up — only the progress bar is missing');
    expect(find.byType(Slider), findsNothing,
        reason: 'no duration delivered -> no progress bar at all');
    await unmountPlayer(tester);
  });

  testWidgets('FIXED: backend seeds its known duration -> Slider present '
      'and a drag seeks', (tester) async {
    await pumpPlayer(tester, seed: true);
    expect(controlsVisible(tester), isTrue);
    expect(find.byType(Slider), findsOneWidget,
        reason: 'seeded duration builds the progress bar');

    final center = tester.getCenter(find.byType(Slider));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump();
    expect(lastBackend!.seeks, isNotEmpty, reason: 'release seeks');
    // 45 min film, drag right from the start must land well past 0.
    expect(lastBackend!.seeks.last,
        greaterThan(const Duration(seconds: 60)));
    await unmountPlayer(tester);
  });
}
