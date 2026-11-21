// 1.1.6 音乐 — 控制器级测试：睡眠定时三模式 / 音量归一化 /
// 书签 + 断点续播.
//
// Harness: fake players through the constructor seam (same pattern
// as music_crossfade_lost_error_test.dart) + scripted resolvers +
// a fake API (lyrics []). The fake players expose controllable
// streams, so completion events and durations can be driven
// deterministically — no native audio on Linux, no network.
//
// Sibling checks pinned here:
// - 手动切歌不计入 N；失败跳过不计入 N（失败路径不走 _onTrackCompleted）。
// - 单曲循环下“播完本首后停止”也停（不 replay）。
// - 计满即停时下一首尚未开播（crossfade 只在下一首 _loadCurrent 里启动）。
// - 归一化默认关、关时增益恒 1.0、只衰减不抬升、强度切换只影响下一首。
// - 断点续播只读杀 app 时存的断点（保存规则未扩——见红线）；书签跳
//   转优先于断点；离结尾 < 10 s 的断点不续播（旧规则回归）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:just_audio/just_audio.dart' show AudioPlayer, ProcessingState;
import 'package:standalone/core/native/now_playing.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/music/av_music_player.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/widgets/track_more_sheet.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';
import 'package:standalone/services/music/music_store.dart';
import 'package:standalone/services/music/sleep_timer.dart';

Song _song(String id, String title, {int dur = 260}) => Song(
      songId: id,
      title: title,
      artist: 'Singer $id',
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

/// Resolvers that answer instantly with a URL per song id.
class _UrlResolvers extends MusicResolvers {
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
    return PlayUrlResult(
      url: _url(songId),
      candidates: [_url(songId)],
      quality: quality,
      via: 'test',
    );
  }
}

/// Controllable streams for a fake player: completion events and
/// durations are driven by the test. Broadcast: the duration stream
/// has two listeners (_attach + the resume-seek firstWhere).
class _FakeStreams extends AvMusicPlayerStreams {
  _FakeStreams() : super(AudioPlayer());

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Stream<Duration> get duration => _duration.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Stream<String> get error => _error.stream;

  @override
  Stream<bool> get completed => _completed.stream;
}

class _FakePlayer extends AvMusicPlayer {
  _FakePlayer() : streams = _FakeStreams();

  final _FakeStreams streams;
  final List<String> openedUrls = [];
  final List<double> volumes = [];
  final List<Duration> seekCalls = [];
  var playCalls = 0;
  var pauseCalls = 0;

  @override
  AvMusicPlayerStreams get stream => streams;

  @override
  Future<bool> open(String url, {bool play = true}) async {
    openedUrls.add(url);
    return true;
  }

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
  }

  @override
  Future<void> dispose() async {}
}

/// Sheet-test controller: the bookmark dialog's jump is recorded
/// instead of loading (no playback in the widget test).
class _SheetTestController extends MusicPlayerController {
  final List<Duration> jumped = [];

  @override
  Future<void> jumpToBookmark(Song song, int seconds) async {
    jumped.add(Duration(seconds: seconds));
  }
}

void main() {
  late Box<dynamic> box;
  late _FakePlayer playerA;
  late _FakePlayer playerB;
  late MusicPlayerController c;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Hive.init('test/.hive-v16-snb');
    box = await Hive.openBox<dynamic>('v16_snb_test');
    await box.clear();
    HiveStore.setTestBox(box);
    playerA = _FakePlayer();
    playerB = _FakePlayer();
    c = MusicPlayerController(
      api: _FakeApi(),
      resolvers: _UrlResolvers(),
      playerA: playerA,
      playerB: playerB,
    );
    c.onInit();
    c.queue.assignAll([_song('1', 'A'), _song('2', 'B'), _song('3', 'C')]);
    c.currentIndex.value = 0;
  });

  tearDown(() async {
    c.onClose();
    Get.reset();
    await box.close();
    await Hive.deleteBoxFromDisk('v16_snb_test');
  });

  /// Poll until [check] holds (up to ~10 s). Fixed short delays flake
  /// when the VM is loaded — parallel agents starve the event loop
  /// and a 300 ms wait can fire before the completion handler runs
  /// (seen 2026-11-21: "changing N mid-run" timed out, count still
  /// 0). Polling only makes the test slower, never wrong.
  /// (Declared before loadA: Dart local functions must be declared
  /// before their first use in the same block.)
  Future<void> waitForCondition(bool Function() check) async {
    for (var i = 0; i < 200; i++) {
      if (check()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(check(), isTrue);
  }

  /// Load A through the normal manual path and wait for the open.
  Future<void> loadA() async {
    await c.playQueue([_song('1', 'A'), _song('2', 'B'), _song('3', 'C')], 0);
    await waitForCondition(() => playerA.openedUrls.isNotEmpty);
  }

  group('sleep: currentTrackEnd', () {
    test('stops at the first completion, even under single-loop', () async {
      await loadA();
      c.playMode.value = 'one'; // single loop — must NOT replay.
      c.setSleepTimer(SleepTimerOption.currentTrackEnd);
      expect(c.sleepOption.value, SleepTimerOption.currentTrackEnd);
      expect(c.sleepLabel, '播完本首后停止');

      playerA.streams._completed.add(true);
      await waitForCondition(() => c.sleepOption.value == SleepTimerOption.off);

      expect(c.sleepOption.value, SleepTimerOption.off);
      expect(c.currentIndex.value, 0); // no advance, no replay
      expect(playerA.playCalls, 0); // _replayCurrent never ran
      expect(playerA.pauseCalls, greaterThanOrEqualTo(1));
    });
  });

  group('sleep: afterNTracks', () {
    test('N=2 stops after the second natural completion', () async {
      await loadA();
      c.setSleepTimerAfterNTracks(2);
      expect(c.sleepLabel, '播完 2 首后停止');

      // First completion: counted, advances to B.
      playerA.streams._completed.add(true);
      await waitForCondition(
        () => c.currentIndex.value == 1 && c.sleepTracksCompleted.value == 1,
      );
      expect(c.currentIndex.value, 1);
      expect(c.sleepOption.value, SleepTimerOption.afterNTracks);
      expect(c.sleepTracksCompleted.value, 1);

      // Second completion: reached — stops, C never starts.
      playerB.streams._completed.add(true);
      await waitForCondition(() => c.sleepOption.value == SleepTimerOption.off);
      expect(c.sleepOption.value, SleepTimerOption.off);
      expect(c.currentIndex.value, 1);
      expect(playerB.openedUrls, [_url('2')]);
      expect(playerA.openedUrls, [_url('1')]);
    });

    test('manual next does not count', () async {
      await loadA();
      c.setSleepTimerAfterNTracks(2);

      await c.next(); // manual: B loads, count stays 0.
      await waitForCondition(() => c.currentIndex.value == 1);
      expect(c.currentIndex.value, 1);
      expect(c.sleepTracksCompleted.value, 0);
      expect(c.sleepOption.value, SleepTimerOption.afterNTracks);

      // B completes: count 1, advances to C (not a stop).
      playerA.streams._completed.add(true);
      await waitForCondition(
        () => c.currentIndex.value == 2 && c.sleepTracksCompleted.value == 1,
      );
      expect(c.currentIndex.value, 2);
      expect(c.sleepTracksCompleted.value, 1);
    });

    test('changing N mid-run recounts from zero', () async {
      await loadA();
      c.setSleepTimerAfterNTracks(2);

      playerA.streams._completed.add(true);
      await waitForCondition(
        () => c.currentIndex.value == 1 && c.sleepTracksCompleted.value == 1,
      );
      expect(c.currentIndex.value, 1);
      expect(c.sleepTracksCompleted.value, 1);

      // Change N to 1: the counted track does not carry over.
      c.setSleepTrackCount(1);
      expect(c.sleepTrackCount.value, 1);
      expect(c.sleepTracksCompleted.value, 0);

      playerB.streams._completed.add(true);
      await waitForCondition(() => c.sleepOption.value == SleepTimerOption.off);
      expect(c.sleepOption.value, SleepTimerOption.off);
      expect(c.currentIndex.value, 1);
    });
  });

  group('sleep: wall-clock fire fades out over 1 s', () {
    test('volume ramps down, then pauses and restores the gain', () async {
      await loadA();
      playerA.volumes.clear();
      playerA.pauseCalls = 0;
      playerB.pauseCalls = 0;

      c.simulateSleepTimerFiredForTest();
      // The 1 s fade is 10 x 100 ms timer steps; under load the steps
      // fire late, so wait for the fade's end state, not a fixed time.
      await waitForCondition(
        () =>
            playerA.volumes.any((v) => v < 0.5) &&
            playerA.volumes.last == 1.0 &&
            playerA.pauseCalls >= 1 &&
            playerB.pauseCalls >= 1,
      );

      // Mid-fade volumes went well below full, and the last write
      // restores the sounding gain so a manual resume is not silent.
      expect(playerA.volumes.any((v) => v < 0.5), isTrue);
      expect(playerA.volumes.last, closeTo(1.0, 0.001));
      expect(playerA.pauseCalls, greaterThanOrEqualTo(1));
      // The standby is paused too (mid-crossfade fire safety).
      expect(playerB.pauseCalls, greaterThanOrEqualTo(1));
    });
  });

  group('normalisation (strategy A)', () {
    test('defaults: off, standard strength', () {
      expect(c.normalizationEnabled.value, isFalse);
      expect(c.normalizationStrength.value, 1);
      expect(
        HiveStore.getBool(HiveKeys.musicNormalizationEnabled, false),
        isFalse,
      );
      expect(
        HiveStore.getInt(HiveKeys.musicNormalizationStrength, 1),
        1,
      );
    });

    test('gain math: attenuation only, per strength, never boosts', () {
      // -8 LUFS vs -14 target = -6 dB at standard (max cut 6).
      expect(
        MusicPlayerController.normalizationGainLinear(
          lufs: -8,
          strength: 1,
        ),
        closeTo(0.5012, 0.001),
      );
      // Light strength caps the cut at 3 dB.
      expect(
        MusicPlayerController.normalizationGainLinear(
          lufs: -8,
          strength: 0,
        ),
        closeTo(0.7079, 0.001),
      );
      // Strong strength caps at 12 dB.
      expect(
        MusicPlayerController.normalizationGainLinear(
          lufs: -2,
          strength: 2,
        ),
        closeTo(0.2512, 0.001),
      );
      // Quieter than target: no boost, gain stays 1.0.
      expect(
        MusicPlayerController.normalizationGainLinear(
          lufs: -20,
          strength: 2,
        ),
        1.0,
      );
      expect(
        MusicPlayerController.normalizationGainLinear(
          lufs: -14,
          strength: 1,
        ),
        1.0,
      );
      // Strength clamps; non-finite loudness is ignored.
      expect(
        MusicPlayerController.normalizationGainLinear(
          lufs: -2,
          strength: 99,
        ),
        closeTo(0.2512, 0.001),
      );
      expect(
        MusicPlayerController.normalizationGainLinear(
          lufs: double.nan,
          strength: 1,
        ),
        1.0,
      );
    });

    test('second-play effect: unmeasured plays at 1.0, measured is cut',
        () async {
      final b = _song('2', 'B');
      expect(c.normalizationGainFor(b), 1.0);
      await c.setNormalizationEnabled(true);
      // Still 1.0: no measurement yet (first play is never changed).
      expect(c.normalizationGainFor(b), 1.0);
      // Tap measured -8 LUFS during playback: next load attenuates.
      c.noteMeasuredLoudness(b.identityKey, -8);
      expect(c.normalizationGainFor(b), closeTo(0.5012, 0.001));
      // Off again: the measured value is ignored, gain back to 1.0.
      await c.setNormalizationEnabled(false);
      expect(c.normalizationGainFor(b), 1.0);
      // Prefs persist.
      expect(
        HiveStore.getBool(HiveKeys.musicNormalizationEnabled, true),
        isFalse,
      );
    });

    test('strength persists and clamps', () async {
      await c.setNormalizationStrength(2);
      expect(c.normalizationStrength.value, 2);
      expect(HiveStore.getInt(HiveKeys.musicNormalizationStrength, 1), 2);
      await c.setNormalizationStrength(99);
      expect(c.normalizationStrength.value, 2);
      await c.setNormalizationStrength(-1);
      expect(c.normalizationStrength.value, 0);
    });

    test('manual load opens at the measured gain', () async {
      await c.setNormalizationEnabled(true);
      c.noteMeasuredLoudness(_song('2', 'B').identityKey, -8);
      await c.playQueue(
        [_song('1', 'A'), _song('2', 'B'), _song('3', 'C')],
        1,
      );
      await waitForCondition(
        () =>
            playerA.volumes.isNotEmpty &&
            (playerA.volumes.last - 0.5012).abs() < 0.001,
      );
      expect(playerA.volumes.last, closeTo(0.5012, 0.001));
    });

    test('crossfade lands the incoming track at its measured gain',
        () async {
      await loadA();
      await c.setNormalizationEnabled(true);
      c.noteMeasuredLoudness(_song('2', 'B').identityKey, -8);
      playerB.volumes.clear();

      await c.next(auto: true);
      // The crossfade is timer-driven (~2.8 s of steps); under load
      // the steps fire late, so wait for its end state.
      await waitForCondition(
        () =>
            playerA.volumes.isNotEmpty &&
            playerA.volumes.last == 0.0 &&
            playerB.volumes.isNotEmpty &&
            (playerB.volumes.last - 0.5012).abs() < 0.001,
      );

      expect(playerB.volumes.last, closeTo(0.5012, 0.001));
      expect(playerA.volumes.last, 0.0); // outgoing faded to silence
    });

    test('strength change does not jump the sounding track', () async {
      await c.setNormalizationEnabled(true);
      c.noteMeasuredLoudness(_song('2', 'B').identityKey, -8);
      await c.playQueue(
        [_song('1', 'A'), _song('2', 'B'), _song('3', 'C')],
        1,
      );
      await waitForCondition(
        () =>
            playerA.volumes.isNotEmpty &&
            (playerA.volumes.last - 0.5012).abs() < 0.001,
      );
      expect(playerA.volumes.last, closeTo(0.5012, 0.001));

      final writesBefore = playerA.volumes.length;
      await c.setNormalizationStrength(0);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // No volume write to the sounding player: the new strength
      // applies from the next load.
      expect(playerA.volumes.length, writesBefore);

      c.noteMeasuredLoudness(_song('3', 'C').identityKey, -8);
      await c.playQueue(
        [_song('1', 'A'), _song('2', 'B'), _song('3', 'C')],
        2,
      );
      await waitForCondition(
        () =>
            playerA.volumes.isNotEmpty &&
            (playerA.volumes.last - 0.7079).abs() < 0.001,
      );
      expect(playerA.volumes.last, closeTo(0.7079, 0.001));
    });
  });

  group('bookmarks (controller)', () {
    test('add at the current position; other songs / position 0 refuse',
        () async {
      await loadA();
      c.position.value = const Duration(seconds: 90);
      final mark = await c.addBookmark(_song('1', 'A'));
      expect(mark, isNotNull);
      expect(mark!.position, 90);
      expect(mark.label, '1:30');
      expect(
        c.bookmarksFor(_song('1', 'A')).map((m) => m.position).toList(),
        [90],
      );
      // Not the current song: no position to save.
      expect(await c.addBookmark(_song('2', 'B')), isNull);
      // Position 0 is not a bookmark.
      c.position.value = Duration.zero;
      expect(await c.addBookmark(_song('1', 'A')), isNull);
      expect(c.bookmarksFor(_song('1', 'A')).length, 1);
    });

    test('delete removes only that bookmark', () async {
      await loadA();
      c.position.value = const Duration(seconds: 30);
      await c.addBookmark(_song('1', 'A'));
      c.position.value = const Duration(seconds: 90);
      final mid = await c.addBookmark(_song('1', 'A'));
      c.position.value = const Duration(seconds: 200);
      await c.addBookmark(_song('1', 'A'));
      await c.deleteBookmark(_song('1', 'A'), mid!);
      expect(
        c.bookmarksFor(_song('1', 'A')).map((m) => m.position).toList(),
        [30, 200],
      );
    });

    test('jump to a bookmark of the loaded song seeks immediately',
        () async {
      await loadA();
      await c.jumpToBookmark(_song('1', 'A'), 120);
      expect(playerA.seekCalls, [const Duration(seconds: 120)]);
    });

    test('jump to a bookmark of an unloaded song loads it, then seeks',
        () async {
      await loadA();
      final jump = c.jumpToBookmark(_song('3', 'C'), 60);
      // The load resolves instantly; the seek waits for the duration.
      // Wait for the URL open, not just the index: the index is set
      // before _loadCurrent runs, and the duration listener is only
      // registered after the open — adding the duration event any
      // earlier loses it on the broadcast stream (the load then
      // times out after 5 s with no seek).
      await waitForCondition(
        () =>
            playerA.openedUrls.contains(_url('3')) ||
            playerB.openedUrls.contains(_url('3')),
      );
      playerA.streams._duration.add(const Duration(seconds: 200));
      await jump;
      await waitForCondition(
        () => playerA.seekCalls.contains(const Duration(seconds: 60)),
      );
      expect(c.currentIndex.value, 2);
      expect(playerA.seekCalls, contains(const Duration(seconds: 60)));
    });
  });

  group('breakpoint resume (read path, unchanged rules)', () {
    test('kill-saved breakpoint seeks after the duration is known',
        () async {
      await MusicStore.saveResume(_song('1', 'A').identityKey, 90);
      final load = c.playQueue([_song('1', 'A')], 0);
      await waitForCondition(() => playerA.openedUrls.isNotEmpty);
      playerA.streams._duration.add(const Duration(seconds: 200));
      await load;
      await waitForCondition(
        () => playerA.seekCalls.contains(const Duration(seconds: 90)),
      );
      expect(playerA.seekCalls, contains(const Duration(seconds: 90)));
    });

    test('breakpoint within 10 s of the end does not resume (old rule)',
        () async {
      await MusicStore.saveResume(_song('1', 'A').identityKey, 195);
      final load = c.playQueue([_song('1', 'A')], 0);
      await waitForCondition(() => playerA.openedUrls.isNotEmpty);
      playerA.streams._duration.add(const Duration(seconds: 200));
      await load;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        playerA.seekCalls,
        isNot(contains(const Duration(seconds: 195))),
      );
    });

    test('a bookmark jump wins over the kill-saved breakpoint', () async {
      await MusicStore.saveResume(_song('1', 'A').identityKey, 90);
      await loadA();
      final jump = c.jumpToBookmark(_song('1', 'A'), 30);
      // Already loaded: immediate seek, no duration wait.
      await jump;
      expect(playerA.seekCalls, contains(const Duration(seconds: 30)));
      expect(
        playerA.seekCalls,
        isNot(contains(const Duration(seconds: 90))),
      );
    });
  });

  group('··· sheet bookmark row (widget)', () {
    // Read-only widget coverage: the sheet renders the 书签 row and
    // the dialog opens with its empty state. The dialog's add /
    // jump wiring is covered at controller level
    // (addBookmark / jumpToBookmark / deleteBookmark tests above):
    // driving a Hive write from inside a testWidgets dialog
    // callback leaves a pending write future that the fake-async
    // zone never resolves, which hangs the run's teardown — a
    // harness limit, not a product bug (on a real phone the write
    // lands in ms and the list refreshes via setState).
    testWidgets('sheet shows the bookmark row; dialog opens empty',
        (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(nowPlayingChannelName),
        (call) async => null,
      );
      try {
        final sc = Get.put<MusicPlayerController>(_SheetTestController());
        final song = _song('1', 'A');
        sc.queue.assignAll([song]);
        sc.currentIndex.value = 0;
        sc.position.value = const Duration(seconds: 90);
        await tester.pumpWidget(
          GetMaterialApp(
            theme: HaoThemes.of(HaoThemeId.appleGlass).light,
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () =>
                      openTrackMoreSheet(ctx, song, fromPlayer: true),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        // Manual pumps only (no pumpAndSettle: the player controller
        // owns timers that never settle in the fake-async zone —
        // see render_music_player_test.dart).
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('书签'), findsOneWidget);
        expect(find.text('添加书签'), findsOneWidget);

        // The sheet is a SingleChildScrollView and the row can sit
        // below the fold in the 800x600 test viewport (its position
        // depends on the rows above it); scroll it into view first.
        await tester.ensureVisible(find.text('书签'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.text('书签'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('添加书签（1:30）'), findsOneWidget);
        expect(find.text('暂无书签'), findsOneWidget);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel(nowPlayingChannelName),
          null,
        );
      }
    });
  });
}
