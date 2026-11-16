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
  }) async {
    openedUrls.add(url);
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

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  tearDown(() async {
    Get.reset();
    await HiveStore.delete(HiveKeys.videoAutoNext);
    await HiveStore.delete(HiveKeys.videoHistory);
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
    }) async {
      backends.clear();
      session = PlaybackSession(
        backendFactory: (_) {
          final b = _FakeBackend();
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
  });
}
