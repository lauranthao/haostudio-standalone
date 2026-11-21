// VOD skip intro/outro + subtitle overlay (1.1.6) — widget tests.
//
// Driven by a fake TrackCapableBackend (no native player):
// - autoNow: entering the intro window seeks to the intro end once.
// - manual: a "跳过片头" pill shows inside the window; tapping seeks.
// - auto3s: the pill counts down 3/2/1, then auto-seeks.
// - off: no pill, no seek.
// - credits: auto mode advances to the next episode at CreditsStart;
//   manual shows a "跳过片尾" pill that advances on tap.
// - CMS custom seconds (no Emby markers): the per-episode Hive value
//   drives the same pill.
// - subtitle overlay: text lines from the session appear, and the
//   overlay sits AFTER the danmaku layer in the page Stack (so it
//   paints above danmaku).
// - session: subtitle delay is clamped to ±10 s, remembered, and
//   re-applied to a swapped-in backend, like the track ids.
//
// NOT covered here (needs chen's iPhone): whether the skip feels
// right mid-playback on a real stream, and whether the overlay text
// is legible over real frames.

import 'dart:async';
import 'dart:io';

import 'package:flame_barrage/flame_barrage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/player/vod_controls.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/settings/source_stores.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/video/vod_danmaku_client.dart';

import 'helpers/hive_test_setup.dart' as hive_setup;

/// MPV-shaped fake: records seeks/opens, drives position/duration,
/// and emits text subtitle lines.
class _FakeVodBackend implements TrackCapableBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _subtitleLines = StreamController<List<String>>.broadcast();

  final List<Duration> seekCalls = [];
  final List<double> subtitleDelayCalls = [];
  final List<String> secondarySubtitleCalls = [];
  final List<String> subtitleAppearanceCalls = [];
  var openCalls = 0;
  bool _disposed = false;

  void emitPosition(double seconds) {
    _position.add(Duration(milliseconds: (seconds * 1000).round()));
  }

  void emitDuration(double seconds) {
    _duration.add(Duration(milliseconds: (seconds * 1000).round()));
  }

  void emitSubtitles(List<String> lines) => _subtitleLines.add(lines);

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
    openCalls++;
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
  Future<void> seekTo(Duration position) async {
    seekCalls.add(position);
  }

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Future<List<PlaybackTrack>> audioTracks() async => const [];

  @override
  Future<List<PlaybackTrack>> subtitleTracks() async => const [];

  @override
  Future<void> setAudioTrack(String id) async {}

  @override
  Future<void> setSubtitleTrack(String id) async {}

  @override
  Future<void> setSubtitleDelay(double seconds) async {
    subtitleDelayCalls.add(seconds);
  }

  @override
  Future<void> setSecondarySubtitleTrack(String id) async {
    secondarySubtitleCalls.add(id);
  }

  @override
  Future<void> setSubtitleAppearance({
    required int fontSize,
    required String color,
    required double position,
  }) async {
    subtitleAppearanceCalls.add('$fontSize|$color|$position');
  }

  @override
  Stream<List<String>> get subtitleStream => _subtitleLines.stream;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _error.close();
    await _completed.close();
    await _subtitleLines.close();
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-vod-skip-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    // Memory-backed box: file-backed Hive writes issued inside a
    // test's fake-async zone wedge hive_ce's serialized write lock
    // (product code records history/progress during pump/tap), so a
    // later awaited put hangs until the 10-min timeout and the next
    // test fails with reentrant runAsync. Same pattern as
    // emby_tab_persistence_test.dart.
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
  });

  VideoDetail detail({bool withMarkers = true}) => VideoDetail(
    source: 12,
    vodId: '93344',
    meta: VideoMeta(name: '狂飙', year: '2023'),
    lines: [
      PlayLine(
        name: '线路1',
        episodes: [
          PlayEpisode(
            name: '第1集',
            url: 'https://example.com/ep1.mp4',
            introStart: withMarkers ? 0 : null,
            introEnd: withMarkers ? 90 : null,
            creditsStart: withMarkers ? 100 : null,
          ),
          PlayEpisode(
            name: '第2集',
            url: 'https://example.com/ep2.mp4',
            introStart: withMarkers ? 0 : null,
            introEnd: withMarkers ? 60 : null,
            creditsStart: withMarkers ? 100 : null,
          ),
        ],
      ),
    ],
  );

  late PlaybackSession session;
  late _FakeVodBackend backend;

  Future<void> pumpPlayer(
    WidgetTester tester, {
    VodDanmakuClient? danmakuClient,
  }) async {
    backend = _FakeVodBackend();
    session = PlaybackSession(backendFactory: (_) => backend);
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: NativeVideoPlayerPage(
          detail: detail(),
          session: session,
          danmakuClient: danmakuClient,
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Real-async drain + a bounded fake-time advance.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> setMode(WidgetTester tester, String mode) async {
    await tester.runAsync(
      () => HiveStore.put(HiveKeys.vodSkipIntroMode, mode),
    );
  }

  Future<void> unmountPlayer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await hive_setup.drainHiveWrites(tester);
  }

  testWidgets('autoNow: entering the intro window seeks to the end once',
      (tester) async {
    await setMode(tester, 'autoNow');
    await pumpPlayer(tester);
    backend.emitDuration(1200);
    backend.emitPosition(5);
    await settle(tester);
    expect(backend.seekCalls, [const Duration(seconds: 90)]);
    expect(find.text('跳过片头'), findsNothing);
    // A second position event inside the window does NOT re-seek.
    backend.emitPosition(6);
    await settle(tester);
    expect(backend.seekCalls, [const Duration(seconds: 90)]);
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
  });

  testWidgets('manual: pill shows in the window, tap seeks', (tester) async {
    await setMode(tester, 'manual');
    await pumpPlayer(tester);
    backend.emitDuration(1200);
    backend.emitPosition(5);
    await settle(tester);
    expect(find.text('跳过片头'), findsOneWidget);
    expect(backend.seekCalls, isEmpty);
    await tester.tap(find.text('跳过片头'));
    await settle(tester);
    expect(backend.seekCalls, [const Duration(seconds: 90)]);
    expect(find.text('跳过片头'), findsNothing);
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
  });

  testWidgets('auto3s: pill counts down 3/2/1, then auto-seeks',
      (tester) async {
    await setMode(tester, 'auto3s');
    await pumpPlayer(tester);
    backend.emitDuration(1200);
    backend.emitPosition(5);
    await settle(tester);
    expect(find.text('跳过片头 3'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('跳过片头 2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('跳过片头 1'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(backend.seekCalls, [const Duration(seconds: 90)]);
    expect(find.text('跳过片头'), findsNothing);
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
  });

  testWidgets('off: no pill, no seek', (tester) async {
    await setMode(tester, 'off');
    await pumpPlayer(tester);
    backend.emitDuration(1200);
    backend.emitPosition(5);
    await settle(tester);
    expect(find.text('跳过片头'), findsNothing);
    expect(backend.seekCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
  });

  testWidgets('autoNow credits: reaching CreditsStart advances episode',
      (tester) async {
    await setMode(tester, 'autoNow');
    await pumpPlayer(tester);
    backend.emitDuration(200);
    // Position 5 first: intro auto-skips to 90 (episode 1 window).
    backend.emitPosition(5);
    await settle(tester);
    expect(backend.seekCalls, [const Duration(seconds: 90)]);
    backend.emitPosition(100);
    await settle(tester);
    // Episode 2 opened (second open call) and its label shows.
    expect(backend.openCalls, 2);
    expect(find.text('第2集'), findsWidgets);
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
  });

  testWidgets('manual credits: pill shows, tap advances episode',
      (tester) async {
    await setMode(tester, 'manual');
    await pumpPlayer(tester);
    backend.emitDuration(200);
    backend.emitPosition(100);
    await settle(tester);
    expect(find.text('跳过片尾'), findsOneWidget);
    await tester.tap(find.text('跳过片尾'));
    await settle(tester);
    expect(backend.openCalls, 2);
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
  });

  testWidgets('CMS custom seconds drive the same pill (no markers)',
      (tester) async {
    await setMode(tester, 'manual');
    await tester.runAsync(
      () => saveSkipIntroDuration(
        title: '狂飙',
        episodeName: '第1集',
        seconds: 60,
      ),
    );
    backend = _FakeVodBackend();
    session = PlaybackSession(backendFactory: (_) => backend);
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: NativeVideoPlayerPage(
          detail: detail(withMarkers: false),
          session: session,
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    backend.emitDuration(1200);
    backend.emitPosition(5);
    await settle(tester);
    expect(find.text('跳过片头'), findsOneWidget);
    await tester.tap(find.text('跳过片头'));
    await settle(tester);
    expect(backend.seekCalls, [const Duration(seconds: 60)]);
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
    await tester.runAsync(
      () => saveSkipIntroDuration(
        title: '狂飙',
        episodeName: '第1集',
        seconds: 0,
      ),
    );
  });

  testWidgets('subtitle overlay shows text lines, hides when empty',
      (tester) async {
    await setMode(tester, 'off');
    await pumpPlayer(tester);
    expect(find.text('你好\nHello'), findsNothing);
    backend.emitSubtitles(['你好', 'Hello']);
    await settle(tester);
    expect(find.text('你好\nHello'), findsOneWidget);
    backend.emitSubtitles(['', '']);
    await settle(tester);
    expect(find.text('你好\nHello'), findsNothing);
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
  });

  testWidgets('subtitle overlay sits above the danmaku layer in the Stack',
      (tester) async {
    await setMode(tester, 'off');
    await tester.runAsync(
      () => DanmakuSettings.setEnabled(DanmakuSettings.vodSiteId, true),
    );
    // Fake fetcher: no network — candidates resolve to null.
    await pumpPlayer(
      tester,
      danmakuClient: VodDanmakuClient(fetcher: (_) async => null),
    );
    await settle(tester);
    expect(find.byType(FlameBarrageWidget), findsOneWidget);
    backend.emitSubtitles(['弹幕之上']);
    await settle(tester);
    expect(find.text('弹幕之上'), findsOneWidget);

    // The page Stack is NOT found by fit alone: the app Overlay
    // above it is also a Stack(fit: StackFit.expand), and it is
    // visited first (ancestor). Identify the page Stack by the
    // overlay child it carries (the ValueKey below).
    final stack = tester.widget<Stack>(
      find.byWidgetPredicate(
        (w) =>
            w is Stack &&
            w.fit == StackFit.expand &&
            w.children.any(
              (c) =>
                  c is Positioned &&
                  c.key == const ValueKey('vod-subtitle-overlay'),
            ),
      ),
    );
    var overlayIndex = -1;
    var danmakuIndex = -1;
    for (var i = 0; i < stack.children.length; i++) {
      final child = stack.children[i];
      if (child is Positioned &&
          child.key == const ValueKey('vod-subtitle-overlay')) {
        overlayIndex = i;
      }
      // Danmaku: the Positioned child whose subtree holds the
      // barrage widget. Do NOT type-match the layers in between —
      // the danmaku group wraps it (DanmakuOcclusionMask today)
      // and that wrapper is their business.
      // Positioned.child is non-nullable in this Flutter SDK
      // (required super.child), so no null guard is needed here —
      // the descendant check below already skips childless layers.
      if (child is Positioned) {
        final descendant = find.descendant(
          of: find.byWidget(child),
          matching: find.byType(FlameBarrageWidget),
        );
        if (descendant.evaluate().isNotEmpty) danmakuIndex = i;
      }
    }
    expect(danmakuIndex, greaterThanOrEqualTo(0));
    expect(overlayIndex, greaterThan(danmakuIndex));
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
    await tester.runAsync(
      () => DanmakuSettings.setEnabled(DanmakuSettings.vodSiteId, false),
    );
  });

  // NOTE: the session-side delay/secondary re-apply test lives in
  // vod_subtitle_session_test.dart (no player-page import), so it
  // keeps running even when another group's file breaks the page's
  // import chain.
}
