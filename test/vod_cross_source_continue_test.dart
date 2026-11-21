// VOD cross-source auto-continuation (1.1.6, _onEpisodeEnded).
//
// When the last episode of a line ends, the player looks for the
// NEXT episode number elsewhere before settling on the end state:
// same detail's other lines, then other sources with the same title
// (STRONG match only: same normalised title + EXACT episode number).
// With autoNext ON the found candidate gets a 5 s cancellable
// countdown, then plays in this same player — no fake player, no
// detail reload.
//
// This pins the cross-source branch (branch 2) end to end: the
// detail service is injected with canned findAlts/fetchDetail
// callbacks (VideoDetailService takes both), the fake backend
// records every open URL and can emit completion, so no network
// and no native player are involved. The same-line branch and the
// "no candidate -> end state" case are NOT covered here — the
// same-line path is the plain autoNextEpisodeIndex step, and the
// no-candidate case is just the absence of the SnackBar below.

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
import 'package:standalone/features/video/video_detail_service.dart';
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

VideoDetail _altDetail() => VideoDetail(
      source: 99,
      vodId: 'alt-1',
      meta: VideoMeta(name: '流浪地球2'),
      lines: [
        PlayLine(
          name: '线路A',
          episodes: const [
            PlayEpisode(name: '第1集', url: 'https://example.com/alt-ep1.mp4'),
            PlayEpisode(name: '第2集', url: 'https://example.com/alt-ep2.mp4'),
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
  final List<String> openUrls = [];
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
    openUrls.add(url);
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

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp
        .createTemp('hao-cross-source-continue-test-');
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
    final service = VideoDetailService(
      findAlts: (title, year, exclude, {cancelToken}) async* {
        yield const AltVideoSource(source: 99, vodId: 'alt-1');
      },
      fetchDetail: (sourceId, vodId, {cancelToken}) async => _altDetail(),
    );
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: NativeVideoPlayerPage(
          detail: _detail(),
          detailService: service,
          session: session,
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
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('last episode ends -> cross-source 第2集 counts down, then plays',
      (tester) async {
    await pumpPlayer(tester);
    expect(backend.openUrls, ['https://example.com/ep1.mp4'],
        reason: 'starts on the tapped episode');

    // Episode ends: same line has no next episode, so the player
    // searches cross-source instead of settling on the end state.
    backend.emitCompleted();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(find.textContaining('下一集在99 · 第 2 集，即将播放'), findsOneWidget,
        reason: 'strong match prompts the 5 s countdown');
    expect(backend.openUrls, hasLength(1),
        reason: 'nothing plays before the countdown ends');

    // The 5 s countdown elapses without a cancel tap: the candidate
    // plays in this same player.
    // The 5 s countdown elapses, plus a small epsilon so a timer
    // due exactly on the 5 s boundary is not left for the next pump.
    await tester.pump(const Duration(seconds: 5, milliseconds: 100));
    // The jump chain has several real-clock hops (Hive history
    // record in playTarget, then the session open ladder): one
    // 200 ms window + one frame is not enough for all of them.
    // Settle repeatedly — repo pattern from video_autoplay_test.
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }
    expect(backend.openUrls,
        contains('https://example.com/alt-ep2.mp4'),
        reason: 'cross-source 第2集 opens after the countdown');
    await unmountPlayer(tester);
  });

  testWidgets('no alt with the next number -> end state, no prompt',
      (tester) async {
    backend = _FakeBackend();
    session = PlaybackSession(backendFactory: (_) => backend);
    final service = VideoDetailService(
      // Alt exists but has no 第2集: the strong match fails.
      findAlts: (title, year, exclude, {cancelToken}) async* {
        yield const AltVideoSource(source: 99, vodId: 'alt-1');
      },
      fetchDetail: (sourceId, vodId, {cancelToken}) async => VideoDetail(
        source: 99,
        vodId: 'alt-1',
        meta: VideoMeta(name: '流浪地球2'),
        lines: [
          PlayLine(
            name: '线路A',
            episodes: const [
              PlayEpisode(
                  name: '第1集', url: 'https://example.com/alt-ep1.mp4'),
            ],
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: NativeVideoPlayerPage(
          detail: _detail(),
          detailService: service,
          session: session,
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

    backend.emitCompleted();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(find.textContaining('即将播放'), findsNothing,
        reason: 'weak/absent match never prompts');
    expect(backend.openUrls, hasLength(1),
        reason: 'nothing auto-plays without a strong match');
    await unmountPlayer(tester);
  });
}
