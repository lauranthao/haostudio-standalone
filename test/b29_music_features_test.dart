// Build-29 music features — pure-logic tests (no native audio, no
// network, no Hive init: every test here runs on plain Dart data).
//
// Coverage map (12 items):
// 1. 变速不变调 — clampSpeed 0.5..2.0 + speedPresets (the pitch half
//    is native: UriAudioSource.m:95 pins AVAudioTimePitchAlgorithmTimeDomain).
// 2. 淡入淡出 — VolumeFader gain math + ramp + cancel; the resume
//    fade-in seam (no players -> no-op, never throws).
// 3+12. 多队列 / 按专辑分组队列 — MultiQueueStore remember/resume.
// 4. A-B 循环 — AbLoop.
// 5. 歌词偏移/翻译 — LyricDisplay (逐字: no word timing in any
//    source — live probe 2026-11-22, see lyric_tools.dart).
// 6. Smart Rules — SmartRules.build, all five rules.
// 7. 每日一 Pick — DailyService.pickOfDay determinism.
// 8. Zap — ZapPool build + nextIndex.
// 9. 年度回顾 — YearReview.compute.
// 10. 播放缓存 — PlaybackCache file naming + prune + clear.
// 11. AutoEq — preset tables (Crossfeed: needs native tap DSP, not
//    built — see autoeq_presets.dart).

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/ab_loop.dart';
import 'package:standalone/services/music/autoeq_presets.dart';
import 'package:standalone/services/music/daily_service.dart';
import 'package:standalone/services/music/lyric_tools.dart';
import 'package:standalone/services/music/multi_queue_store.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/playback_cache.dart';
import 'package:standalone/services/music/smart_rules.dart';
import 'package:standalone/services/music/volume_fader.dart';
import 'package:standalone/services/music/year_review.dart';
import 'package:standalone/services/music/zap.dart';

Song song(
  String id,
  String title, {
  String artist = 'A',
  String album = '',
  MusicPlatform pf = MusicPlatform.wy,
}) => Song(songId: id, title: title, artist: artist, album: album, platform: pf);

ListenEvent ev(
  String id,
  String title, {
  String artist = 'A',
  int dur = 180,
  int at = 0,
  MusicPlatform pf = MusicPlatform.wy,
}) => ListenEvent(
  songId: id,
  title: title,
  artist: artist,
  dur: dur,
  totalDur: dur,
  at: at,
  platform: pf,
);

void main() {
  group('1. 变速不变调', () {
    test('clampSpeed allows 0.5..2.0', () {
      expect(MusicPlayerController.clampSpeed(0.5), 0.5);
      expect(MusicPlayerController.clampSpeed(2.0), 2.0);
      expect(MusicPlayerController.clampSpeed(0.1), 0.5);
      expect(MusicPlayerController.clampSpeed(3.0), 2.0);
      expect(MusicPlayerController.clampSpeed(1.25), 1.25);
    });

    test('speedPresets span 0.5..2.0 in order', () {
      expect(MusicPlayerController.speedPresets.first, 0.5);
      expect(MusicPlayerController.speedPresets.last, 2.0);
      expect(
        MusicPlayerController.speedPresets,
        orderedEquals([0.5, 0.75, 1.0, 1.25, 1.5, 2.0]),
      );
    });
  });

  group('2. 淡入淡出', () {
    test('fadeInGain ramps 0..1, fadeOutGain ramps 1..0', () {
      const total = Duration(milliseconds: 600);
      expect(VolumeFader.fadeInGain(Duration.zero, total), 0.0);
      expect(
        VolumeFader.fadeInGain(const Duration(milliseconds: 300), total),
        0.5,
      );
      expect(VolumeFader.fadeInGain(total, total), 1.0);
      expect(VolumeFader.fadeOutGain(Duration.zero, total), 1.0);
      expect(
        VolumeFader.fadeOutGain(const Duration(milliseconds: 300), total),
        0.5,
      );
      expect(VolumeFader.fadeOutGain(total, total), 0.0);
    });

    test('zero duration applies the endpoint at once', () {
      expect(VolumeFader.fadeInGain(Duration.zero, Duration.zero), 1.0);
      expect(VolumeFader.fadeOutGain(Duration.zero, Duration.zero), 0.0);
    });

    test('ramp walks from -> to in ascending steps', () async {
      final seen = <double>[];
      await VolumeFader.ramp(
        setVolume: (v) async => seen.add(v),
        from: 0,
        to: 1.0,
        duration: const Duration(milliseconds: 200),
      );
      expect(seen.length, greaterThan(1));
      expect(seen.last, 1.0);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
    });

    test('ramp stops early when cancelled', () async {
      final seen = <double>[];
      var calls = 0;
      await VolumeFader.ramp(
        setVolume: (v) async {
          seen.add(v);
          calls++;
        },
        from: 0,
        to: 1.0,
        duration: const Duration(milliseconds: 500),
        isCancelled: () => calls >= 2,
      );
      expect(seen.length, 2);
      expect(seen.last, lessThan(1.0));
    });
  });

  group('3+12. 多队列 / 按专辑分组队列', () {
    test('remember + resumeIndexFor returns the saved index', () {
      final store = MultiQueueStore();
      final songs = [song('1', 'A'), song('2', 'B'), song('3', 'C')];
      store.remember('album:X|Y', songs, 2);
      expect(store.resumeIndexFor('album:X|Y', songs), 2);
    });

    test('changed song order does not resume', () {
      final store = MultiQueueStore();
      final songs = [song('1', 'A'), song('2', 'B')];
      store.remember('playlist:p1', songs, 1);
      expect(
        store.resumeIndexFor('playlist:p1', [song('2', 'B'), song('1', 'A')]),
        isNull,
      );
    });

    test('unknown source does not resume', () {
      final store = MultiQueueStore();
      expect(
        store.resumeIndexFor('album:Nope|', [song('1', 'A')]),
        isNull,
      );
    });

    test('empty key / empty songs are ignored', () {
      final store = MultiQueueStore();
      store.remember('', [song('1', 'A')], 0);
      store.remember('x', [], 0);
      expect(store.entries, isEmpty);
    });

    test('eviction drops the stalest source first', () {
      final store = MultiQueueStore();
      for (var i = 0; i < MultiQueueStore.maxSources + 2; i++) {
        store.remember('s$i', [song('$i', 'T$i')], 0);
      }
      expect(store.entries.length, MultiQueueStore.maxSources);
      expect(store.entries.containsKey('s0'), isFalse);
      expect(store.entries.containsKey('s1'), isFalse);
      expect(store.entries.containsKey('s11'), isTrue);
    });

    test('QueueSource keys are distinct per source', () {
      expect(QueueSource.album('A', 'X'), isNot(QueueSource.album('A', 'Y')));
      expect(QueueSource.album('A', 'X'), isNot(QueueSource.playlist('A')));
      expect(QueueSource.artist('X'), isNot(QueueSource.album('X', '')));
    });
  });

  group('4. A-B 循环', () {
    test('inactive until both points set, B after A', () {
      final loop = AbLoop();
      expect(loop.isActive, isFalse);
      loop.setA(const Duration(seconds: 10));
      expect(loop.isActive, isFalse);
      loop.setB(const Duration(seconds: 5));
      expect(loop.isActive, isFalse);
      loop.setB(const Duration(seconds: 20));
      expect(loop.isActive, isTrue);
    });

    test('seekTarget returns A at/past B, null before', () {
      final loop = AbLoop();
      loop.setA(const Duration(seconds: 10));
      loop.setB(const Duration(seconds: 20));
      expect(
        loop.seekTarget(const Duration(seconds: 19)),
        isNull,
      );
      expect(
        loop.seekTarget(const Duration(seconds: 20)),
        const Duration(seconds: 10),
      );
      expect(
        loop.seekTarget(const Duration(seconds: 25)),
        const Duration(seconds: 10),
      );
    });

    test('moving A past B drops B; clear resets', () {
      final loop = AbLoop();
      loop.setA(const Duration(seconds: 10));
      loop.setB(const Duration(seconds: 20));
      loop.setA(const Duration(seconds: 25));
      expect(loop.isActive, isFalse);
      expect(loop.hasB, isFalse);
      loop.clear();
      expect(loop.hasA, isFalse);
    });

    test('label describes the state', () {
      final loop = AbLoop();
      expect(loop.label, isEmpty);
      loop.setA(const Duration(seconds: 83));
      expect(loop.label, 'A 点 1:23');
      loop.setB(const Duration(seconds: 105));
      expect(loop.label, 'A-B 循环 1:23–1:45');
    });
  });

  group('5. 歌词偏移 / 翻译', () {
    final lines = [
      LyricLine(t: 0, text: 'a', translation: '甲'),
      LyricLine(t: 10, text: 'b', translation: '乙'),
      LyricLine(t: 20, text: 'c'),
    ];

    test('no offset: classic line index', () {
      expect(
        LyricDisplay.lyricIndexFor(lines, const Duration(seconds: 15), 0),
        1,
      );
      expect(
        LyricDisplay.lyricIndexFor(lines, const Duration(seconds: 9), 0),
        0,
      );
    });

    test('positive offset pulls the next line early', () {
      expect(
        LyricDisplay.lyricIndexFor(
          lines,
          const Duration(seconds: 9),
          2000,
        ),
        1,
      );
    });

    test('negative offset holds the current line longer', () {
      expect(
        LyricDisplay.lyricIndexFor(
          lines,
          const Duration(seconds: 10),
          -2000,
        ),
        0,
      );
    });

    test('clampOffsetMs caps at ±5 s', () {
      expect(LyricDisplay.clampOffsetMs(99999), 5000);
      expect(LyricDisplay.clampOffsetMs(-99999), -5000);
      expect(LyricDisplay.clampOffsetMs(1500), 1500);
    });

    test('offsetLabel formats +1.5s / -0.5s / 0s', () {
      expect(LyricDisplay.offsetLabel(1500), '+1.5s');
      expect(LyricDisplay.offsetLabel(-500), '-0.5s');
      expect(LyricDisplay.offsetLabel(0), '0s');
      expect(LyricDisplay.offsetLabel(2000), '+2s');
    });

    test('controller lyricIndexFor applies its offset', () {
      final c = MusicPlayerController();
      c.lyrics
        ..clear()
        ..addAll(lines);
      c.lyricOffsetMs.value = 2000;
      expect(c.lyricIndexFor(const Duration(seconds: 9)), 1);
      c.lyricOffsetMs.value = 0;
      expect(c.lyricIndexFor(const Duration(seconds: 9)), 0);
    });
  });

  group('6. Smart Rules', () {
    final now = DateTime(2026, 11, 22, 12);
    final nowMs = now.millisecondsSinceEpoch;
    final dayMs = 86400000;
    final favs = [
      song('1', '常听一', artist: '周杰伦'),
      song('2', '常听二', artist: '周杰伦'),
      song('3', '冷门', artist: '陈奕迅'),
    ];
    final recent = [song('4', '最近', artist: '林俊杰')];
    List<ListenEvent> logFor(Map<String, int> plays, {int? lastAt}) {
      final out = <ListenEvent>[];
      plays.forEach((id, n) {
        for (var i = 0; i < n; i++) {
          out.add(
            ev(
              id,
              't$id',
              artist: id == '1' || id == '2' ? '周杰伦' : '陈奕迅',
              at: lastAt ?? nowMs,
            ),
          );
        }
      });
      return out;
    }

    test('recentFavourites sorts by play count', () {
      final out = SmartRules.build(
        SmartRule.recentFavourites,
        favourites: favs,
        recent: recent,
        listenLog: logFor({'1': 5, '2': 2}),
        now: now,
      );
      expect(out.map((s) => s.songId), ['1', '2']);
    });

    test('recentFavourites falls back to all favourites', () {
      final out = SmartRules.build(
        SmartRule.recentFavourites,
        favourites: favs,
        recent: recent,
        listenLog: const [],
        now: now,
      );
      expect(out.length, 3);
    });

    test('unplayedFavourites keeps only unplayed / stale songs', () {
      final out = SmartRules.build(
        SmartRule.unplayedFavourites,
        favourites: favs,
        recent: recent,
        listenLog: logFor({'1': 3}),
        now: now,
      );
      expect(out.map((s) => s.songId), containsAll(['2', '3']));
      expect(out.map((s) => s.songId), isNot(contains('1')));
    });

    test('sameArtistDeepDive picks the top artist pool', () {
      final diveFavs = [
        song('1', '常听一', artist: '周杰伦'),
        song('2', '常听二', artist: '周杰伦'),
        song('5', '常听三', artist: '周杰伦'),
        song('3', '冷门', artist: '陈奕迅'),
      ];
      final out = SmartRules.build(
        SmartRule.sameArtistDeepDive,
        favourites: diveFavs,
        recent: recent,
        listenLog: logFor({'1': 9, '3': 1}),
        now: now,
      );
      expect(out.map((s) => s.songId), ['1', '2', '5']);
    });

    test('sameArtistDeepDive falls back when the pool is too thin', () {
      final out = SmartRules.build(
        SmartRule.sameArtistDeepDive,
        favourites: favs,
        recent: recent,
        listenLog: logFor({'1': 9, '3': 1}),
        now: now,
      );
      // Only 2 songs by the top artist: falls back to the
      // most-played favourites instead of a 2-song "dive".
      expect(out.map((s) => s.songId), ['1', '3']);
    });

    test('longUnplayed returns oldest-heard first, 30d+ only', () {
      final log = [
        ev('old', '老', at: nowMs - 60 * dayMs),
        ev('mid', '中', at: nowMs - 40 * dayMs),
        ev('new', '新', at: nowMs - 5 * dayMs),
      ];
      final out = SmartRules.build(
        SmartRule.longUnplayed,
        favourites: const [],
        recent: const [],
        listenLog: log,
        now: now,
      );
      expect(out.map((s) => s.songId), ['old', 'mid']);
    });

    test('dailyMix is deterministic per day, deduped', () {
      final a = SmartRules.build(
        SmartRule.dailyMix,
        favourites: favs,
        recent: recent,
        listenLog: const [],
        now: now,
      );
      final b = SmartRules.build(
        SmartRule.dailyMix,
        favourites: favs,
        recent: recent,
        listenLog: const [],
        now: now,
      );
      expect(a.map((s) => s.songId), b.map((s) => s.songId));
      expect(a.map((s) => s.songId).toSet().length, a.length);
    });
  });

  group('7. 每日一 Pick', () {
    test('null on an empty list', () {
      expect(DailyService.pickOfDay(const []), isNull);
    });

    test('same day -> same pick, pick is in the list', () {
      final tracks = List.generate(20, (i) => song('$i', 'T$i'));
      final day = DateTime(2026, 11, 22);
      final a = DailyService.pickOfDay(tracks, now: day);
      final b = DailyService.pickOfDay(tracks, now: day);
      expect(a, isNotNull);
      expect(a!.songId, b!.songId);
      expect(tracks.map((s) => s.songId), contains(a.songId));
    });

    test('different days usually differ (seeded, not list order)', () {
      final tracks = List.generate(20, (i) => song('$i', 'T$i'));
      final picks = <String>{
        for (var d = 1; d <= 10; d++)
          DailyService.pickOfDay(
            tracks,
            now: DateTime(2026, 11, d),
          )!.songId,
      };
      expect(picks.length, greaterThan(1));
    });
  });

  group('8. Zap 快速发现', () {
    test('pool dedupes and caps at 30', () {
      final pool = ZapPool.build(
        favourites: [song('1', 'A'), song('2', 'B')],
        recent: [song('2', 'B'), song('3', 'C')],
        daily: List.generate(40, (i) => song('d$i', 'D$i')),
      );
      expect(pool.length, ZapPool.maxPool);
      expect(pool.map((s) => s.identityKey).toSet().length, pool.length);
    });

    test('preview is 5 seconds', () {
      expect(ZapPool.previewSeconds, 5);
    });

    test('nextIndex never repeats the current song when possible', () {
      final rng = Random(42);
      for (var i = 0; i < 50; i++) {
        final next = ZapPool.nextIndex(
          current: 3,
          length: 10,
          random: rng,
        );
        expect(next, isNot(3));
        expect(next, inInclusiveRange(0, 9));
      }
    });

    test('nextIndex on a one-song pool returns 0', () {
      expect(ZapPool.nextIndex(current: 0, length: 1), 0);
    });
  });

  group('9. 年度回顾', () {
    test('totals, monthly split, top month, days listened', () {
      final y2026 = DateTime(2026, 3, 5).millisecondsSinceEpoch;
      final y2026b = DateTime(2026, 3, 6).millisecondsSinceEpoch;
      final y2026jan = DateTime(2026, 1, 10).millisecondsSinceEpoch;
      final y2025 = DateTime(2025, 12, 31).millisecondsSinceEpoch;
      final review = YearReview.compute([
        ev('1', 'A', dur: 180, at: y2026),
        ev('1', 'A', dur: 180, at: y2026b),
        ev('2', 'B', artist: 'B-artist', dur: 240, at: y2026jan),
        ev('9', 'Old', dur: 999, at: y2025),
      ], 2026);
      expect(review.totalPlays, 3);
      expect(review.totalSeconds, 600);
      expect(review.totalMinutes, 10);
      expect(review.monthlyPlays[2], 2);
      expect(review.monthlyPlays[0], 1);
      expect(review.monthlyPlays[11], 0);
      expect(review.topMonth, 3);
      expect(review.daysListened, 3);
      expect(review.topSongs.first.song.songId, '1');
      expect(review.topSongs.first.plays, 2);
    });

    test('empty year reports zeros', () {
      final review = YearReview.compute(const [], 2026);
      expect(review.totalPlays, 0);
      expect(review.topMonth, 0);
      expect(review.daysListened, 0);
      expect(review.monthlyPlays, List.filled(12, 0));
    });
  });

  group('10. 播放缓存', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('hao-cache-test-');
      PlaybackCache.directoryOverrideForTest = tmp;
    });

    tearDown(() async {
      PlaybackCache.directoryOverrideForTest = null;
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('fileNameForUrl is stable and distinct per URL', () {
      const a = 'https://cdn.example.com/a.mp3?token=1';
      const b = 'https://cdn.example.com/a.mp3?token=2';
      expect(PlaybackCache.fileNameForUrl(a),
          PlaybackCache.fileNameForUrl(a));
      expect(PlaybackCache.fileNameForUrl(a),
          isNot(PlaybackCache.fileNameForUrl(b)));
      expect(PlaybackCache.fileNameForUrl(a), endsWith('.cache'));
    });

    test('sizeBytes sums the files', () async {
      await File('${tmp.path}/x.cache').writeAsBytes(List.filled(100, 0));
      await File('${tmp.path}/y.cache').writeAsBytes(List.filled(50, 0));
      expect(await PlaybackCache.sizeBytes(), 150);
    });

    test('prune deletes oldest first until under the cap', () async {
      final old = File('${tmp.path}/old.cache')
        ..writeAsBytesSync(List.filled(100, 0));
      final mid = File('${tmp.path}/mid.cache')
        ..writeAsBytesSync(List.filled(100, 0));
      final fresh = File('${tmp.path}/new.cache')
        ..writeAsBytesSync(List.filled(100, 0));
      await old.setLastModified(DateTime(2026, 1, 1));
      await mid.setLastModified(DateTime(2026, 2, 1));
      await fresh.setLastModified(DateTime(2026, 3, 1));
      final freed = await PlaybackCache.prune(capBytes: 150);
      expect(freed, 200);
      expect(await old.exists(), isFalse);
      expect(await mid.exists(), isFalse);
      expect(await fresh.exists(), isTrue);
      expect(await PlaybackCache.sizeBytes(), 100);
    });

    test('prune is a no-op under the cap; clear empties', () async {
      await File('${tmp.path}/a.cache').writeAsBytes(List.filled(10, 0));
      expect(await PlaybackCache.prune(capBytes: 1000), 0);
      expect(await PlaybackCache.clear(), 10);
      expect(await PlaybackCache.sizeBytes(), 0);
    });
  });

  group('11. AutoEq 预设库', () {
    test('8 presets, 10 gains each, within ±12 dB, unique ids', () {
      expect(kAutoEqPresets.length, 8);
      final ids = <String>{};
      for (final p in kAutoEqPresets) {
        expect(p.gains.length, 10, reason: p.name);
        expect(ids.add(p.id), isTrue, reason: p.id);
        for (final g in p.gains) {
          expect(g.abs(), lessThanOrEqualTo(12.0));
        }
      }
      expect(autoEqPresetById('airpods-pro-2')?.name, 'AirPods Pro 2');
      expect(autoEqPresetById('nope'), isNull);
    });
  });

  group('controller seams', () {
    test('startZap with an empty pool returns false', () async {
      final c = MusicPlayerController();
      expect(await c.startZap(const []), isFalse);
      expect(c.zapActive.value, isFalse);
    });

    test('A-B loop methods drive the loop state', () {
      final c = MusicPlayerController();
      c.position.value = const Duration(seconds: 30);
      c.setAbPointA();
      expect(c.abLoop.a, const Duration(seconds: 30));
      c.position.value = const Duration(seconds: 45);
      c.setAbPointB();
      expect(c.abLoop.isActive, isTrue);
      c.clearAbLoop();
      expect(c.abLoop.isActive, isFalse);
    });

    test('resume with no players is a no-op, never throws', () async {
      // Regression (build 29 relay): the resume path used to call
      // the late [_active] bare, which throws LateInitializationError
      // on a controller without onInit; _fadeInThenPlay guards it.
      final c = MusicPlayerController();
      await c.togglePlayPause();
      expect(c.isPlaying.value, isFalse);
    });
  });
}
