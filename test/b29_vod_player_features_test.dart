// I-影视 (build 29) — VOD player widget tests.
//
// Pins the player-page wiring for items 1/2/3/6/7/8/9 with fake
// backends (no native player, no network):
//  (1) double-tap right/left seeks ± the settings step;
//  (2) two-finger tap toggles play/pause;
//  (3) dialogue boost is forwarded to a capable backend at open;
//  (6) screenshot (MPV frame-capable fake) saves a JPEG file;
//  (7) lock blocks surface gestures and always offers unlock;
//  (8) sleep "播完本集后停止" pauses at episode end instead of
//      auto-advancing;
//  (9) pure-audio toggle calls setAudioOnly + persists the key.
// Pinch-to-fit is covered at the pure level (pinchFitTarget in
// b29_vod_features_test.dart); driving a two-pointer scale through
// the test binding is flaky and adds no signal beyond it.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/player/kernel/frame_capable_backend.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/storage/local_paths.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_models.dart';

import 'helpers/hive_test_setup.dart';

VideoDetail _detail() => VideoDetail(
      source: 12,
      vodId: '93344',
      meta: VideoMeta(name: '流浪地球2'),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: const [
            PlayEpisode(name: '第1集', url: 'https://example.com/ep1.mp4'),
            PlayEpisode(name: '第2集', url: 'https://example.com/ep2.mp4'),
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
  final List<bool> audioOnlyCalls = [];
  int playCount = 0;
  int pauseCount = 0;
  bool _disposed = false;

  void emitPosition(Duration p) => _position.add(p);
  void emitDuration(Duration d) => _duration.add(d);
  void emitCompleted() => _completed.add(null);

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
  Future<void> play() async {
    playCount++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _playing.add(false);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {
    audioOnlyCalls.add(audioOnly);
  }

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

/// MPV-shaped fake: frame-capable (screenshot) + dialogue-boost
/// capable. No real backend implements the boost yet (K 组) — the
/// fake proves the session forwards the switch.
class _FakeCapableBackend extends _FakeBackend
    implements FrameCapableBackend, DialogueBoostCapableBackend {
  final List<bool> dialogueBoostCalls = [];

  @override
  Future<Uint8List?> captureFrameJpeg() async =>
      Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

  @override
  Future<void> setDialogueBoost(bool enabled) async {
    dialogueBoostCalls.add(enabled);
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-b29-vodplay-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    LocalPaths.setDocumentsPathForTest(hiveDir.path);
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    LocalPaths.resetForTest();
    await hiveDir.delete(recursive: true);
  });

  // No Hive deletes here: a Hive write started in the fake zone
  // leaves hive_ce's ReadWriteSync queue stuck and the NEXT test's
  // first Hive write hangs forever (see helpers/hive_test_setup.dart).
  // Tests that write prefs reset them inside their own body with
  // runAsync + drainHiveWrites, before the fake zone is discarded.
  tearDown(() {
    Get.reset();
  });

  late PlaybackSession session;
  late _FakeBackend backend;

  Future<void> pumpPlayer(
    WidgetTester tester, {
    _FakeBackend Function()? factory,
  }) async {
    backend = factory?.call() ?? _FakeBackend();
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

  Future<void> pumpPlaying(
    WidgetTester tester, {
    _FakeBackend Function()? factory,
    double positionSeconds = 100,
  }) async {
    await pumpPlayer(tester, factory: factory);
    backend.emitDuration(const Duration(seconds: 600));
    backend.emitPosition(Duration(seconds: positionSeconds.round()));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  Future<void> unmountPlayer(WidgetTester tester) async {
    // Let HaoToast's 2.5 s dismiss timer fire first: a toast shown
    // by the test's last action (e.g. the pure-audio toggle) leaves
    // a pending FakeTimer, and the framework fails the test at
    // teardown ("A Timer is still pending"). 3 s of fake time is
    // shorter than the 5 s controls auto-hide, so nothing else
    // fires that the test cares about.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // Drain the page's fire-and-forget Hive writes (history record
    // on open, progress save on dispose): a write left pending when
    // this test ends stalls hive_ce's queue and the NEXT test's
    // first Hive write hangs forever, even through runAsync
    // (see helpers/hive_test_setup.dart). Runs inside the body,
    // before the fake zone is discarded.
    await drainHiveWrites(tester);
  }

  bool controlsVisible(WidgetTester tester) =>
      find.byIcon(Icons.arrow_back).evaluate().isNotEmpty;

  testWidgets('double-tap right seeks +10 s (default step)',
      (tester) async {
    await pumpPlaying(tester);
    expect(controlsVisible(tester), isTrue);
    backend.seeks.clear();
    await tester.tapAt(const Offset(700, 300));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(700, 300));
    await tester.pump();
    expect(backend.seeks, isNotEmpty, reason: 'double-tap seeks');
    expect(backend.seeks.last, const Duration(seconds: 110));
    await unmountPlayer(tester);
  });

  testWidgets('double-tap left seeks -10 s', (tester) async {
    await pumpPlaying(tester);
    backend.seeks.clear();
    await tester.tapAt(const Offset(100, 300));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(100, 300));
    await tester.pump();
    expect(backend.seeks, isNotEmpty);
    expect(backend.seeks.last, const Duration(seconds: 90));
    await unmountPlayer(tester);
  });

  testWidgets('double-tap step follows the settings value (30 s)',
      (tester) async {
    // Hive does real disk I/O: a box.put awaited directly in the
    // fake-async zone never resolves (see helpers/hive_test_setup.dart)
    // — this line hung the test forever before the runAsync wrap.
    // Drain first: earlier tests' pumpPlaying left fire-and-forget
    // history writes in hive_ce's queue, and a write queued behind
    // them cannot complete until a drain lets their I/O land.
    await drainHiveWrites(tester);
    await tester.runAsync(
      () => HiveStore.put(HiveKeys.vodDoubleTapSeekSeconds, 30),
    );
    await pumpPlaying(tester);
    backend.seeks.clear();
    await tester.tapAt(const Offset(700, 300));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(700, 300));
    await tester.pump();
    expect(backend.seeks, isNotEmpty);
    expect(backend.seeks.last, const Duration(seconds: 130));
    // Reset the key in the real zone and drain, so the next test's
    // first Hive write does not hit a stuck queue. Drain FIRST:
    // pumpPlaying's _recordHistory issued a fire-and-forget Hive
    // write in the fake zone, which stalls hive_ce's queue until
    // a drain lets its I/O land (see helpers/hive_test_setup.dart).
    await drainHiveWrites(tester);
    await tester.runAsync(
      () => HiveStore.delete(HiveKeys.vodDoubleTapSeekSeconds),
    );
    await drainHiveWrites(tester);
    await unmountPlayer(tester);
  });

  testWidgets('two-finger tap toggles play/pause', (tester) async {
    await pumpPlaying(tester);
    final before = backend.pauseCount;
    final g1 = await tester.startGesture(const Offset(400, 300));
    final g2 = await tester.startGesture(const Offset(500, 300));
    await tester.pump(const Duration(milliseconds: 50));
    await g1.up();
    await g2.up();
    await tester.pump();
    expect(backend.pauseCount, before + 1,
        reason: 'two-finger tap pauses a playing film');
    await unmountPlayer(tester);
  });

  testWidgets('lock blocks surface taps, overlay unlock restores',
      (tester) async {
    await pumpPlaying(tester);
    expect(controlsVisible(tester), isTrue);
    // Build 29 (K): the lock action lives in the 更多 menu now —
    // two 500 ms pumps let the action sheet settle (same entrance
    // rule as the sleep sheet below), then tap the action.
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('锁定屏幕'));
    await tester.pump();
    expect(find.text('已锁定，点右上角锁图标解锁'), findsOneWidget);
    expect(controlsVisible(tester), isFalse, reason: 'bars hide when locked');
    // A surface tap while locked must NOT wake the controls.
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controlsVisible(tester), isFalse, reason: 'locked: no wake');
    // The persistent overlay lock button unlocks. (The top bar no
    // longer has a lock icon — it moved into the 更多 menu — so
    // tap the overlay by key.)
    await tester.tap(find.byKey(const ValueKey('vod_lock_overlay')));
    await tester.pump();
    expect(controlsVisible(tester), isTrue, reason: 'unlock restores bars');
    expect(find.text('已锁定，点右上角锁图标解锁'), findsNothing);
    await unmountPlayer(tester);
  });

  testWidgets('pure-audio toggle calls setAudioOnly + persists',
      (tester) async {
    await pumpPlaying(tester);
    // Build 29 (K): audio-only lives in the 更多 menu now.
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('纯音频播放'));
    await tester.pump();
    await tester.pump();
    expect(backend.audioOnlyCalls, contains(true));
    expect(HiveStore.getBool(HiveKeys.vodAudioOnly, false), isTrue);
    // The chip (by key): the toggle toast says the same words, so
    // a plain text finder is ambiguous.
    expect(
      find.byKey(const ValueKey('vod_audio_only_hint')),
      findsOneWidget,
    );
    // The toggle's Hive put is fire-and-forget in the page: drain
    // it (and reset the key) inside the body, before the fake zone
    // is discarded, or the next test's first Hive write hangs.
    // Drain FIRST — pumpPlaying's _recordHistory already stalled
    // the queue (see the 30 s step test).
    await drainHiveWrites(tester);
    await tester.runAsync(
      () => HiveStore.delete(HiveKeys.vodAudioOnly),
    );
    await drainHiveWrites(tester);
    await unmountPlayer(tester);
  });

  testWidgets('dialogue boost is forwarded to a capable backend at open',
      (tester) async {
    // Same fake-zone rule as the 30 s step test: real-zone write.
    // Drain first — earlier tests' history writes stall the queue.
    await drainHiveWrites(tester);
    await tester.runAsync(
      () => HiveStore.put(HiveKeys.vodDialogueBoost, true),
    );
    late _FakeCapableBackend capable;
    await pumpPlaying(
      tester,
      factory: () => capable = _FakeCapableBackend(),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(capable.dialogueBoostCalls, contains(true));
    // Drain first (pumpPlaying's _recordHistory stalled the queue),
    // then reset the key, then drain again — see the 30 s step test.
    await drainHiveWrites(tester);
    await tester.runAsync(
      () => HiveStore.delete(HiveKeys.vodDialogueBoost),
    );
    await drainHiveWrites(tester);
    await unmountPlayer(tester);
  });

  testWidgets('screenshot saves a JPEG under screenshots/',
      (tester) async {
    await pumpPlaying(
      tester,
      factory: () => _FakeCapableBackend(),
    );
    // Build 29 (K): screenshot lives in the 更多 menu now.
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('截图'));
    // Pump FIRST: the tap's _takeScreenshot runs until its first
    // await (captureFrameJpeg) and parks the continuation in the
    // fake microtask queue — runAsync alone never flushes that
    // queue, so without this pump the file I/O never even starts
    // (probed: no toast, no dir).
    await tester.pump();
    // _takeScreenshot's chain crosses the fake/real async boundary
    // once per step (capture → dir.create → writeAsBytes → share):
    // each step's real I/O only lands during runAsync, and its
    // continuation only runs on the next pump. One pump + one
    // runAsync leaves dir.create() unlanded (probed on an isolated
    // dir: the old sequence → no dir; +1 cycle → dir, 0 files;
    // +2 cycles → 1 file). Drain until the file appears AND is
    // non-empty (writeAsBytes creates the entry before its bytes
    // land — a bare existence check reads 0 bytes), then assert
    // exactly as before — same assertions, no weakening, no timeout.
    File? shot;
    for (var i = 0; i < 8 && shot == null; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      final dir = Directory('${hiveDir.path}/screenshots');
      if (dir.existsSync()) {
        final files = dir.listSync().whereType<File>().toList();
        if (files.isNotEmpty && files.first.lengthSync() > 0) {
          shot = files.first;
        }
      }
    }
    final dir = Directory('${hiveDir.path}/screenshots');
    expect(dir.existsSync(), isTrue);
    final files = dir.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.first.path, endsWith('.jpg'));
    // Real I/O read: same fake-zone rule — through runAsync.
    final bytes = await tester.runAsync(() => files.first.readAsBytes());
    expect(bytes, [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
    expect(shot, isNotNull);
    await unmountPlayer(tester);
  });

  testWidgets('sleep "播完本集后停止" pauses at episode end',
      (tester) async {
    await pumpPlaying(tester);
    // Build 29 (K): sleep lives in the 更多 menu now — open the
    // menu first (two 500 ms pumps for its entrance), then tap the
    // action; the sleep sheet itself opens one microtask after the
    // menu pops, so the two pumps below still cover its entrance.
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('睡眠定时'));
    // Two pumps, not one — probed (probe D, row-top trace):
    // the menu action tap fires only when the next pump flushes the
    // gesture arena (the player surface's double-tap recognizer
    // holds it), and the sheet's 250 ms entrance then needs its
    // own pump. After one pump the sheet is still at its start
    // position — fully below the screen (row top 1845 at +250 ms
    // on a 1400-tall surface, settled at 872 at +500 ms) — so a
    // row tap then hits nothing and _pop never runs. The _SleepRow
    // tap chain itself is fine; the old test tapped too early.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('播完本集后停止'), findsOneWidget);
    await tester.tap(find.text('播完本集后停止'));
    // Same two-pump rule on the way out: the row tap fires during
    // the first pump and the 200 ms exit animation needs the
    // second (probed: title still present after tap + 1x500 ms,
    // gone after 2x500 ms). (No pumpAndSettle — the sheet's 1 s
    // clock ticks forever.)
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('睡眠定时'), findsNothing,
        reason: 'sheet closes after picking');
    final pausesBefore = backend.pauseCount;
    backend.emitCompleted();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(backend.pauseCount, pausesBefore + 1,
        reason: 'sleep stops instead of auto-advancing');
    expect(find.text('已播完'), findsOneWidget,
        reason: 'end state, not episode 2');
    // The sheet choice issues two fire-and-forget Hive puts in the
    // page: drain them inside the body (see the pure-audio test).
    // Drain first — pumpPlaying's _recordHistory stalled the queue.
    await drainHiveWrites(tester);
    await tester.runAsync(() {
      return Future.wait([
        HiveStore.delete(HiveKeys.vodSleepCustomMinutes),
        HiveStore.delete(HiveKeys.vodSleepEpisodeCount),
      ]);
    });
    await drainHiveWrites(tester);
    await unmountPlayer(tester);
  });
}
