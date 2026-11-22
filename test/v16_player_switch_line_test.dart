// 1.1.6 换源链路 — player-page line switch (widget, fake backend).
//
// Pins the fail-back rule at the UI level, where the session tests
// cannot reach it:
// - tapping a dead line leaves the player on the old line (chip
//   still selected, session URL unchanged) + the "stayed on the
//   current line" toast — never a failure card, never a silent
//   jump to another line/source;
// - tapping a working line switches (chip + session URL follow)
//   with no failure card.
//
// Pattern copied from vod_track_selector_test.dart (same pump /
// settle / unmount helpers): fake backend via backendFactory,
// GetMaterialApp, real-async drain via runAsync.

import 'dart:async';
import 'dart:io';

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

/// Fake backend: instant open/first-frame, except URLs in
/// [failUrls] (first frame never arrives — a dead line).
class _FakeBackend implements PlayerBackend {
  _FakeBackend({required this.failUrls});

  final Set<String> failUrls;
  String? openedUrl;
  bool disposed = false;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  @override
  Widget buildVideoWidget() => const SizedBox(key: ValueKey('fake-video'));

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    openedUrl = url;
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      openedUrl != null && !failUrls.contains(openedUrl);

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

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
    if (disposed) return;
    disposed = true;
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-v16-switch-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    // Memory-backed box: _switchLine awaits a Hive put
    // (_saveProgress) before doing anything visible, and a Hive
    // file write issued inside a widget test's fake-async zone
    // never completes in time (proven in live_quality_line_test) —
    // the switch would stall at its first await. The memory
    // backend's writes are Future.value(): no file I/O, no wedge.
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

  const line1Url = 'https://example.com/ep1-line1.mp4';
  const line2Url = 'https://example.com/ep1-line2.mp4';

  VideoDetail detail() => VideoDetail(
        source: 12,
        vodId: '93344',
        meta: VideoMeta(name: '狂飙', year: '2023'),
        lines: const [
          PlayLine(
            name: '线路1',
            episodes: [
              PlayEpisode(name: '第1集', url: line1Url),
              PlayEpisode(name: '第2集', url: 'https://example.com/ep2.mp4'),
            ],
          ),
          PlayLine(
            name: '线路2',
            episodes: [
              PlayEpisode(name: '第1集', url: line2Url),
              PlayEpisode(name: '第2集', url: 'https://example.com/ep2b.mp4'),
            ],
          ),
        ],
      );

  late PlaybackSession session;

  Future<void> pumpPlayer(
    WidgetTester tester, {
    Set<String> failUrls = const {},
  }) async {
    session = PlaybackSession(
      backendFactory: (_) => _FakeBackend(failUrls: failUrls),
    );
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: NativeVideoPlayerPage(detail: detail(), session: session),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> unmountPlayer(WidgetTester tester) async {
    Get.closeAllSnackbars();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  /// Whether the line pill for [label] is selected: the selected pill
  /// is the one carrying the white check (H build 29: the player's
  /// ChoiceChip was replaced by the opaque _LinePill — same tap target,
  /// same _switchLine; the pill type itself is private to the page).
  bool pillSelected(WidgetTester tester, String label) {
    final pill = find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color != null,
      ),
    );
    expect(pill, findsOneWidget, reason: label);
    return find
        .descendant(of: pill, matching: find.byIcon(Icons.check))
        .evaluate()
        .isNotEmpty;
  }

  group('_switchLine fail-back', () {
    testWidgets('dead line: stays on line 1 + toast, no failure card',
        (tester) async {
      await pumpPlayer(tester, failUrls: {line2Url});
      expect(session.currentUrl, line1Url);
      expect(pillSelected(tester, '线路1'), isTrue);

      await tester.tap(find.text('线路2'));
      await settle(tester);

      expect(pillSelected(tester, '线路1'), isTrue);
      expect(pillSelected(tester, '线路2'), isFalse);
      expect(session.currentUrl, line1Url);
      expect(
        find.text('该线路暂时打不开，已留在当前线路'),
        findsOneWidget,
      );
      await unmountPlayer(tester);
    });

    testWidgets('working line: switches, no failure card', (tester) async {
      await pumpPlayer(tester);
      expect(session.currentUrl, line1Url);

      await tester.tap(find.text('线路2'));
      await settle(tester);

      expect(pillSelected(tester, '线路2'), isTrue);
      expect(session.currentUrl, line2Url);
      expect(
        find.text('该线路暂时打不开，已留在当前线路'),
        findsNothing,
      );
      await unmountPlayer(tester);
    });
  });
}
