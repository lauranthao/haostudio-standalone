// Music progress stall regressions (chen 2026-11-23: 进度条全是 0).
//
// Root cause (code-traced): a track whose AVPlayerItem never reaches
// ready sits in `buffering` forever — just_audio reports playing ==
// true (optimistic, set by play()) while position stays 0 (it only
// advances when the state is ready) and duration stays null → 0.
// The controller never observed the processing state, there was no
// timeout after open, and the sheet showed 0:00 / -0:00 with a pause
// glyph and no spinner. The watchdog watches the user-visible
// progress itself and treats a stall as a play failure (next
// candidate → alt → give-up with a notice).
//
// Covers:
// 1. Load stall (no progress at all) fires the watchdog → manual
//    give-up records loadError instead of sitting at 0:00 forever.
// 2. Healthy playback (positions advancing) never fires it.
// 3. Mid-play stall (played, then frozen) fires it too.
// 4. A track frozen at its own end recovers as a completion
//    (advances) instead of replaying as a failure.
// 5. displayDuration falls back to the metadata duration, and is
//    zero only when nothing is known.
// 6. waitingForFirstProgress is true only while playing with no
//    progress yet.
// 7. prev() restart zeroes the bar at once, even while paused.
// 8. Sheet: metadata total renders as -m:ss (not -0:00), unknown
//    total renders --:--, loadError shows a retry line, and the
//    waiting state shows a spinner instead of the pause glyph.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:just_audio/just_audio.dart'
    show AudioPlayer, ProcessingState;
import 'package:standalone/core/native/now_playing.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/music/av_music_player.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/music_player_sheet.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

Song _wy(String id, String title, {int dur = 260}) => Song(
      songId: id,
      title: title,
      artist: '陈奕迅',
      platform: MusicPlatform.wy,
      dur: dur,
    );

String _url(String id) => 'https://example.com/$id.mp3';

class _FakeApi extends MusicApi {
  @override
  Future<Song?> findAltPlatform(
    String title,
    String artist,
    MusicPlatform excludePf,
    String album, {
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      null;

  @override
  Future<List<LyricLine>> lyrics(Song song) async => [];
}

/// Resolvers driven by a per-test script. Returning null for
/// background resolves disables prefetch (the early crossfade needs
/// a cached next URL, and the completion-recovery test must not
/// advance early for that reason instead of through the watchdog).
class _ScriptedResolvers extends MusicResolvers {
  _ScriptedResolvers(this.script);

  final PlayUrlResult? Function(String songId) script;

  @override
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
    String artist = '',
    bool background = false,
    Duration totalBudget = const Duration(seconds: 8),
  }) async {
    if (background) return null;
    return script(songId);
  }

  @override
  void evictPlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
  ) {}
}

/// Fake player whose streams the test drives by hand: position and
/// duration only move when the test adds them, so a stall is exactly
/// reproducible. `open` succeeds without emitting anything (like a
/// native load that never becomes ready).
class _FakeStreams extends AvMusicPlayerStreams {
  _FakeStreams({
    required this.positionCtrl,
    required this.durationCtrl,
    required this.playingCtrl,
    required this.errorCtrl,
    required this.completedCtrl,
  }) : super(AudioPlayer());

  final StreamController<Duration> positionCtrl;
  final StreamController<Duration> durationCtrl;
  final StreamController<bool> playingCtrl;
  final StreamController<String> errorCtrl;
  final StreamController<bool> completedCtrl;

  @override
  Stream<Duration> get position => positionCtrl.stream;
  @override
  Stream<Duration> get duration => durationCtrl.stream;
  @override
  Stream<bool> get playing => playingCtrl.stream;
  @override
  Stream<String> get error => errorCtrl.stream;
  @override
  Stream<bool> get completed => completedCtrl.stream;
}

class _StallFakePlayer extends AvMusicPlayer {
  final List<String> openedUrls = [];
  final List<String> preloadedUrls = [];
  var playCalls = 0;
  var pauseCalls = 0;

  final positionCtrl = StreamController<Duration>.broadcast();
  final durationCtrl = StreamController<Duration>.broadcast();
  final playingCtrl = StreamController<bool>.broadcast();
  final errorCtrl = StreamController<String>.broadcast();
  final completedCtrl = StreamController<bool>.broadcast();

  @override
  AvMusicPlayerStreams get stream => _FakeStreams(
        positionCtrl: positionCtrl,
        durationCtrl: durationCtrl,
        playingCtrl: playingCtrl,
        errorCtrl: errorCtrl,
        completedCtrl: completedCtrl,
      );

  @override
  Future<bool> open(String url, {bool play = true}) async {
    openedUrls.add(url);
    if (play) await this.play();
    return true;
  }

  @override
  Future<bool> preload(String url) async {
    preloadedUrls.add(url);
    return true;
  }

  @override
  bool isPreloadedFor(String url) => preloadedUrls.contains(url);

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Future<void> play() async {
    playCalls++;
    playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playingCtrl.add(false);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> seek(Duration position) async {
    positionCtrl.add(position);
  }

  @override
  Future<void> dispose() async {}
}

MusicPlayerController _stallController({
  required _StallFakePlayer a,
  required _StallFakePlayer b,
  Duration loadStall = const Duration(milliseconds: 400),
  Duration midPlayStall = const Duration(milliseconds: 600),
}) =>
    Get.put(
      MusicPlayerController(
        api: _FakeApi(),
        resolvers: _ScriptedResolvers(
          (id) => PlayUrlResult(
            url: _url(id),
            candidates: [_url(id)],
            quality: AudioQuality.hires,
            via: 'test',
          ),
        ),
        playerA: a,
        playerB: b,
        loadStallTimeout: loadStall,
        midPlayStallTimeout: midPlayStall,
      ),
    );

void main() {
  late Box<dynamic> box;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(nowPlayingChannelName),
          (call) async => null,
        );
    // In-memory box (same pattern as music_player_layout_test):
    // a DISK box hangs testWidgets — Hive's disk-IO Futures never
    // resolve inside the FakeAsync zone — the memory backend has no
    // disk IO, so puts complete via microtask.
    Hive.init('test/.hive-music-progress-stall');
    box = await Hive.openBox<dynamic>(
      'music_progress_stall',
      bytes: Uint8List(0),
    );
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    Get.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(nowPlayingChannelName),
          null,
        );
    await box.close();
  });

  group('stall watchdog (controller, fake AVPlayer)', () {
    test('load stall: playing with no progress gives up with loadError',
        () async {
      final a = _StallFakePlayer();
      final b = _StallFakePlayer();
      final c = _stallController(a: a, b: b);
      final song = _wy('s1', 'Stalled Song');
      await c.playQueue([song], 0);
      // The fake open landed and the fake reports playing — exactly
      // the state chen's phone was in: position 0, duration 0.
      expect(c.isPlaying.value, isTrue);
      expect(c.position.value, Duration.zero);
      expect(c.duration.value, Duration.zero);
      // Wait past the 400 ms load stall budget + the 500 ms tick.
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(c.loadError.value, isNotNull);
      expect(c.loadError.value!.reason, contains('无法播放'));
      expect(c.lastNotice.value, contains('无法播放'));
      // It fires once: the give-up disarms the watch.
      final firstError = c.loadError.value;
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(identical(c.loadError.value, firstError), isTrue);
      c.stopStallWatchdogForTest();
    });

    test('healthy playback: advancing positions never fire the watchdog',
        () async {
      final a = _StallFakePlayer();
      final b = _StallFakePlayer();
      final c = _stallController(a: a, b: b);
      await c.playQueue([_wy('s1', 'Healthy Song')], 0);
      a.durationCtrl.add(const Duration(seconds: 260));
      for (var i = 1; i <= 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        a.positionCtrl.add(Duration(seconds: i));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(c.loadError.value, isNull);
      expect(c.position.value.inSeconds, greaterThanOrEqualTo(5));
      expect(c.duration.value.inSeconds, 260);
      c.stopStallWatchdogForTest();
    });

    test('mid-play stall: frozen after real progress gives up too',
        () async {
      final a = _StallFakePlayer();
      final b = _StallFakePlayer();
      final c = _stallController(a: a, b: b);
      await c.playQueue([_wy('s1', 'Mid Song')], 0);
      a.durationCtrl.add(const Duration(seconds: 260));
      for (var i = 1; i <= 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        a.positionCtrl.add(Duration(seconds: i));
      }
      // The last position event is delivered in a microtask — let it
      // land before asserting.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.position.value.inSeconds, 5);
      // No more position events: the 600 ms mid-play budget fires.
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(c.loadError.value, isNotNull);
      expect(c.loadError.value!.reason, contains('无法播放'));
      c.stopStallWatchdogForTest();
    });

    test(
        'frozen at the end recovers as a completion (advances), '
        'not as a failure', () async {
      final a = _StallFakePlayer();
      final b = _StallFakePlayer();
      // Long load budget for the recovered song: it lands with no
      // progress of its own, and the test must assert on it before
      // its own stall budget fires.
      final c = _stallController(
        a: a,
        b: b,
        loadStall: const Duration(milliseconds: 1500),
      );
      final songs = [_wy('s1', 'First'), _wy('s2', 'Second')];
      await c.playQueue(songs, 0);
      a.durationCtrl.add(const Duration(seconds: 10));
      for (var i = 1; i <= 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        a.positionCtrl.add(Duration(seconds: i));
      }
      // The last position event is delivered in a microtask — let it
      // land before asserting.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.position.value.inSeconds, 10);
      // Position == duration and frozen: the watch treats it as a
      // missed completion, so the queue advances to song 2.
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(c.currentIndex.value, 1);
      expect(c.loadError.value, isNull);
      c.stopStallWatchdogForTest();
    });
  });

  group('displayDuration / waitingForFirstProgress / prev()', () {
    test('displayDuration falls back to metadata, zero when unknown',
        () {
      final c = MusicPlayerController(
        api: _FakeApi(),
        resolvers: _ScriptedResolvers(
          (id) => PlayUrlResult(
            url: _url(id),
            candidates: [_url(id)],
            quality: AudioQuality.hires,
            via: 'test',
          ),
        ),
      );
      c.queue.assignAll([_wy('s1', 'Meta Song', dur: 260)]);
      c.currentIndex.value = 0;
      // No real duration yet: the metadata 260 s is the display total.
      expect(c.displayDuration, const Duration(seconds: 260));
      // A real duration overrides the metadata.
      c.duration.value = const Duration(seconds: 200);
      expect(c.displayDuration, const Duration(seconds: 200));
      // No metadata either: zero (the sheet renders --:-- for it).
      c.queue.assignAll([_wy('s2', 'Unknown Song', dur: 0)]);
      c.currentIndex.value = 0;
      c.duration.value = Duration.zero;
      expect(c.displayDuration, Duration.zero);
    });

    test('waitingForFirstProgress only while playing with no progress',
        () {
      final c = MusicPlayerController(api: _FakeApi());
      c.queue.assignAll([_wy('s1', 'Wait Song')]);
      c.currentIndex.value = 0;
      // Paused at 0: not waiting (nothing is expected to move).
      c.isPlaying.value = false;
      expect(c.waitingForFirstProgress, isFalse);
      // Playing, still no position and no duration: waiting.
      c.isPlaying.value = true;
      expect(c.waitingForFirstProgress, isTrue);
      // A real duration arrived (buffering, not yet playing
      // through): still waiting only if no position either.
      c.duration.value = const Duration(seconds: 260);
      expect(c.waitingForFirstProgress, isFalse);
      // Any position: not waiting.
      c.duration.value = Duration.zero;
      c.position.value = const Duration(seconds: 3);
      expect(c.waitingForFirstProgress, isFalse);
      // A recorded load error: the failure line shows instead.
      c.position.value = Duration.zero;
      c.loadError.value = (
        song: _wy('s1', 'Wait Song'),
        reason: '无可用音源',
      );
      expect(c.waitingForFirstProgress, isFalse);
    });

    test('prev() restart zeroes the bar at once, even while paused',
        () async {
      final a = _StallFakePlayer();
      final b = _StallFakePlayer();
      final c = _stallController(a: a, b: b);
      await c.playQueue([_wy('s1', 'Restart Song')], 0);
      a.durationCtrl.add(const Duration(seconds: 260));
      a.positionCtrl.add(const Duration(seconds: 45));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.position.value.inSeconds, 45);
      await c.pause();
      await c.prev();
      // Optimistic reset: the bar shows 0 immediately, not the stale
      // 0:45 — while paused no position event arrives to correct it.
      expect(c.position.value, Duration.zero);
      c.stopStallWatchdogForTest();
    });
  });

  group('sheet: progress bar never shows a fake 0:00', () {
    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1260, 2736);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const MusicPlayerPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('metadata total renders as -m:ss, never -0:00', (
      tester,
    ) async {
      final c = Get.put(MusicPlayerController());
      c.queue.assignAll([_wy('s1', 'Meta Song', dur: 260)]);
      c.currentIndex.value = 0;
      c.duration.value = Duration.zero;
      c.position.value = Duration.zero;
      await pumpPage(tester);
      expect(find.text('0:00'), findsOneWidget);
      expect(find.text('-4:20'), findsOneWidget);
      expect(find.text('-0:00'), findsNothing);
    });

    testWidgets('unknown total renders --:--', (tester) async {
      final c = Get.put(MusicPlayerController());
      c.queue.assignAll([_wy('s1', 'Unknown Song', dur: 0)]);
      c.currentIndex.value = 0;
      c.duration.value = Duration.zero;
      c.position.value = Duration.zero;
      await pumpPage(tester);
      expect(find.text('--:--'), findsOneWidget);
      expect(find.text('-0:00'), findsNothing);
    });

    testWidgets('loadError shows a retry line that retries on tap', (
      tester,
    ) async {
      final a = _StallFakePlayer();
      final b = _StallFakePlayer();
      // Long stall budgets: the reload the tap triggers must not
      // fire the watchdog mid-test (its give-up notice shows a
      // HaoToast whose 4 s timer would still be pending at the end).
      final c = _stallController(
        a: a,
        b: b,
        loadStall: const Duration(seconds: 10),
        midPlayStall: const Duration(seconds: 10),
      );
      final song = _wy('s1', 'Failed Song');
      c.queue.assignAll([song]);
      c.currentIndex.value = 0;
      c.loadError.value = (song: song, reason: '无可用音源');
      await pumpPage(tester);
      expect(find.textContaining('无法播放：无可用音源'), findsOneWidget);
      expect(find.textContaining('点按重试'), findsOneWidget);
      await tester.tap(find.textContaining('点按重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // retryCurrent clears the error at once, then reloads.
      expect(c.loadError.value, isNull);
      expect(find.textContaining('点按重试'), findsNothing);
      // Drain the fade-in timer (600 ms) before the test ends, and
      // stop the watchdog the reload armed, so no timer is pending.
      await tester.pump(const Duration(seconds: 1));
      c.stopStallWatchdogForTest();
    });

    testWidgets('waiting for first progress shows a spinner, not pause',
        (tester) async {
      final c = Get.put(MusicPlayerController());
      c.queue.assignAll([_wy('s1', 'Wait Song')]);
      c.currentIndex.value = 0;
      c.isPlaying.value = true;
      c.position.value = Duration.zero;
      c.duration.value = Duration.zero;
      await pumpPage(tester);
      expect(find.byIcon(Icons.pause), findsNothing);
      expect(
        find.byType(CupertinoActivityIndicator),
        findsWidgets,
      );
      // Once progress exists, the pause glyph is back.
      c.position.value = const Duration(seconds: 3);
      c.duration.value = const Duration(seconds: 260);
      await tester.pump();
      expect(find.byIcon(Icons.pause), findsOneWidget);
    });
  });
}
