// K 组 (build 29) — VOD player gaps landed by this group.
//
//  (2) L 缺口: a movie never gets a "下一集" history row
//      (kVideoMovieRe on meta.type in _recordHistory).
//  (3) C 缺口: Emby reportPlaybackProgress — 15 s forward-playback
//      throttle + exit/completion report, via the injected client.
//  (4) 对白增强后端: mpv volume-max=300 + centre fold consts +
//      MpvBackend implements DialogueBoostCapableBackend.
//  (5) AVPlayer PiP: session forwards to a capable backend, false
//      for a bare backend / before open (MPV/IJK never implement
//      the capability interface).
//
// Harness copied from b29_vod_player_features_test.dart (Hive temp
// box, fake backends, no native player, no network — the Emby
// client uses a canned mutator).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/player/kernel/avplayer_backend.dart';
import 'package:standalone/core/player/kernel/mpv_backend.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_history_store.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';

import 'helpers/hive_test_setup.dart';

VideoDetail _movieDetail() => VideoDetail(
      source: 12,
      vodId: 'k-movie-1',
      meta: VideoMeta(name: 'K电影', type: '电影', year: '2024'),
      lines: const [
        PlayLine(name: '正片', episodes: [
          PlayEpisode(name: '正片', url: 'https://example.com/m1.mp4'),
          PlayEpisode(name: '花絮', url: 'https://example.com/m2.mp4'),
        ]),
      ],
    );

VideoDetail _seriesDetail() => VideoDetail(
      source: 12,
      vodId: 'k-series-1',
      meta: VideoMeta(name: 'K剧集', type: '电视剧', year: '2024'),
      lines: const [
        PlayLine(name: '线路1', episodes: [
          PlayEpisode(name: '第1集', url: 'https://example.com/s1.mp4'),
          PlayEpisode(name: '第2集', url: 'https://example.com/s2.mp4'),
        ]),
      ],
    );

VideoDetail _embyDetail() => VideoDetail(
      source: 'emby',
      vodId: 'movie1',
      meta: VideoMeta(name: 'Emby Film', type: '动作 / 科幻'),
      lines: const [
        PlayLine(name: '正片', episodes: [
          PlayEpisode(
            name: '正片',
            url:
                'http://127.0.0.1:8096/emby/Videos/ep123/stream?api_key=test-key',
          ),
        ]),
      ],
    );

class _FakeBackend implements PlayerBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();
  bool _disposed = false;

  void emitPosition(Duration p) => _position.add(p);
  void emitDuration(Duration d) => _duration.add(d);

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

/// PiP-capable fake: the AVPlayer shape (only engine that can do
/// system PiP) for the session-forwarding test.
class _FakePipBackend extends _FakeBackend
    implements PictureInPictureCapableBackend {
  int pipCalls = 0;

  @override
  Future<bool> enterPictureInPicture() async {
    pipCalls++;
    return true;
  }
}

/// Compile-time conformance: this only compiles if MpvBackend
/// implements DialogueBoostCapableBackend (no instance is ever
/// built — constructing one would initialise the native player).
DialogueBoostCapableBackend _mpvAsCapable(MpvBackend backend) => backend;

/// Compile-time conformance for PiP: same shape for AVPlayer.
PictureInPictureCapableBackend _avAsCapable(AvPlayerBackend backend) =>
    backend;

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-b29-vod-k-');
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

  // -- (3) pure throttle ---------------------------------------------

  group('shouldReportEmbyProgress', () {
    test('first report at 15 s of forward playback', () {
      expect(
        shouldReportEmbyProgress(lastReportedPosition: 0, position: 14),
        isFalse,
      );
      expect(
        shouldReportEmbyProgress(lastReportedPosition: 0, position: 15),
        isTrue,
      );
    });

    test('no report for a small advance or a seek backwards', () {
      expect(
        shouldReportEmbyProgress(lastReportedPosition: 100, position: 110),
        isFalse,
      );
      expect(
        shouldReportEmbyProgress(lastReportedPosition: 100, position: 90),
        isFalse,
      );
      expect(
        shouldReportEmbyProgress(lastReportedPosition: 100, position: 115),
        isTrue,
      );
    });
  });

  // -- (4) dialogue-boost consts --------------------------------------

  group('dialogue boost backend consts', () {
    test('volume-max is 300', () {
      expect(kMpvVolumeMax, '300');
    });

    test('centre filter folds the centre + surrounds into stereo', () {
      expect(kDialogueBoostCentreFilter, contains('pan=stereo'));
      expect(kDialogueBoostCentreFilter, contains('c2'));
      expect(kDialogueBoostCentreFilter, contains('c4'));
      expect(kDialogueBoostCentreFilter, contains('c0=1.0*c0'));
    });

    test('conformance helpers compile (see file scope)', () {
      // The _mpvAsCapable / _avAsCapable functions above are the
      // test: this file fails to compile if either backend drops
      // its capability interface.
      expect(_mpvAsCapable, isNotNull);
      expect(_avAsCapable, isNotNull);
    });
  });

  // -- (5) session PiP forwarding (no widget needed) ------------------

  group('PlaybackSession.enterPictureInPicture', () {
    test('false before any backend is installed', () async {
      final session = PlaybackSession(backendFactory: (_) => _FakeBackend());
      expect(await session.enterPictureInPicture(), isFalse);
      await session.dispose();
    });

    test('true on a capable backend, false on a bare one', () async {
      final capable = _FakePipBackend();
      final session =
          PlaybackSession(backendFactory: (_) => capable);
      expect(
        await session.open(url: 'https://example.com/f.mp4', isLive: false),
        isTrue,
      );
      expect(await session.enterPictureInPicture(), isTrue);
      expect(capable.pipCalls, 1);
      await session.dispose();

      final bare = _FakeBackend();
      final bareSession = PlaybackSession(backendFactory: (_) => bare);
      expect(
        await bareSession.open(
          url: 'https://example.com/f.mp4',
          isLive: false,
        ),
        isTrue,
      );
      expect(await bareSession.enterPictureInPicture(), isFalse);
      await bareSession.dispose();
    });
  });

  // -- (2) + (3) player page ------------------------------------------

  late PlaybackSession session;
  late _FakeBackend backend;

  Future<void> pumpPlayer(
    WidgetTester tester,
    VideoDetail detail, {
    _FakeBackend Function()? factory,
    EmbyClient Function(EmbyServerConfig config)? embyFactory,
  }) async {
    backend = factory?.call() ?? _FakeBackend();
    session = PlaybackSession(backendFactory: (_) => backend);
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: NativeVideoPlayerPage(
          detail: detail,
          session: session,
          embyClientFactory: embyFactory,
        ),
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
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await drainHiveWrites(tester);
  }

  WatchHistoryEntry? historyFor(String title) {
    final rows = VideoHistoryStore.getAll();
    for (final e in rows) {
      if (e.title == title) return e;
    }
    return null;
  }

  testWidgets('movie history has no next episode; series keeps it',
      (tester) async {
    await pumpPlayer(tester, _movieDetail());
    await drainHiveWrites(tester);
    await tester.pump();
    final movie = historyFor('K电影');
    expect(movie, isNotNull, reason: 'open records history');
    expect(movie!.nextEpName, isEmpty, reason: 'a film has no 下一集');
    await unmountPlayer(tester);

    await pumpPlayer(tester, _seriesDetail());
    await drainHiveWrites(tester);
    await tester.pump();
    final series = historyFor('K剧集');
    expect(series, isNotNull);
    expect(series!.nextEpName, '第2集');
    await unmountPlayer(tester);
  });

  testWidgets('Emby progress: 15 s throttle + exit report',
      (tester) async {
    // Recording mutator: no network, every call observed.
    final calls = <({String method, String url})>[];
    Future<EmbyResponse> recorder(
      String method,
      String url, {
      Map<String, String>? headers,
      Map<String, dynamic>? jsonBody,
      Duration timeout = const Duration(seconds: 8),
      CancelToken? cancelToken,
    }) async {
      calls.add((method: method, url: url));
      return const EmbyResponse(statusCode: 200, json: null);
    }

    final config = const EmbyServerConfig(
      baseUrl: 'http://127.0.0.1:8096',
      apiKey: 'test-key',
      userId: 'u1',
    );
    await drainHiveWrites(tester);
    await tester.runAsync(
      () => HiveStore.put(
        HiveKeys.embyConfig,
        jsonEncode(config.toJson()),
      ),
    );
    await drainHiveWrites(tester);

    EmbyClient factory(EmbyServerConfig c) =>
        EmbyClient(config: c, mutator: recorder);
    await pumpPlayer(tester, _embyDetail(), embyFactory: factory);
    await drainHiveWrites(tester);
    await tester.pump();

    // Start is reported once at open (no /Progress suffix).
    final starts = calls
        .where((c) => c.url.contains('/PlayingItems/ep123'))
        .where((c) => !c.url.contains('/Progress'))
        .toList();
    expect(starts, hasLength(1));

    Future<void> emitAndSettle(Duration p) async {
      backend.emitDuration(const Duration(seconds: 600));
      backend.emitPosition(p);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    List<({String method, String url})> progressCalls() => calls
        .where((c) => c.url.contains('/PlayingItems/ep123/Progress'))
        .toList();

    await emitAndSettle(const Duration(seconds: 10));
    expect(progressCalls(), isEmpty, reason: '10 s < 15 s throttle');
    await emitAndSettle(const Duration(seconds: 16));
    expect(progressCalls(), hasLength(1));
    expect(progressCalls().single.url, contains('PositionTicks=160000000'));
    await emitAndSettle(const Duration(seconds: 20));
    expect(progressCalls(), hasLength(1), reason: '20 - 16 < 15');
    await emitAndSettle(const Duration(seconds: 31));
    expect(progressCalls(), hasLength(2));
    expect(progressCalls().last.url, contains('PositionTicks=310000000'));

    // Exit (dispose) sends exactly one final report at the last
    // position — and the flag stops a second one.
    await unmountPlayer(tester);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(progressCalls(), hasLength(3));
    expect(progressCalls().last.url, contains('PositionTicks=310000000'));

    await drainHiveWrites(tester);
    await tester.runAsync(() => HiveStore.delete(HiveKeys.embyConfig));
    await drainHiveWrites(tester);
  });

  // -- (7) top bar fits 390 px portrait; 更多 holds the rest -------

  testWidgets('top bar fits 390 px portrait; 更多 menu runs an action',
      (tester) async {
    // iPhone-ish 390x844 logical @2x — the geometry that used to
    // overflow by 114 px (10 x 48 px buttons vs 366 px usable).
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await drainHiveWrites(tester);
    await tester.runAsync(() => VideoPlaybackSettings.setAutoNext(true));
    await drainHiveWrites(tester);

    await pumpPlayer(tester, _seriesDetail());
    await drainHiveWrites(tester);
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'top bar must not overflow in portrait');

    // The seven secondary actions are gone from the bar…
    expect(find.byIcon(Icons.more_horiz), findsOneWidget);
    expect(find.byIcon(Icons.lock_open), findsNothing);
    expect(find.byIcon(Icons.headphones), findsNothing);
    expect(find.byIcon(Icons.photo_camera), findsNothing);
    expect(find.byIcon(Icons.bedtime), findsNothing);
    // …and present in the 更多 menu.
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('自动连播：开'), findsOneWidget);
    expect(find.text('音轨与字幕'), findsOneWidget);
    expect(find.text('画面比例：自动'), findsOneWidget);
    expect(find.text('锁定屏幕'), findsOneWidget);
    expect(find.text('纯音频播放'), findsOneWidget);
    expect(find.text('睡眠定时'), findsOneWidget);
    expect(find.text('截图'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // The action actually runs: auto-next flips off and persists.
    await tester.tap(find.text('自动连播：开'));
    await tester.pump();
    await drainHiveWrites(tester);
    expect(VideoPlaybackSettings.autoNext, isFalse);
    await tester.runAsync(() => VideoPlaybackSettings.setAutoNext(true));
    await drainHiveWrites(tester);

    await unmountPlayer(tester);
  });
}
