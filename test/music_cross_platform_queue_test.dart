// Cross-platform queue (audit item 7) + queue/resume store + sleep
// timer deadline checks.
//
// A mixed queue [网易 + QQ + 酷狗] must play in order, and every song
// must resolve through ITS OWN platform — never through the previous
// song's platform. Same harness as music_trial_clip_test.dart: fake
// API / fake resolvers, controller constructed directly (no Get.put,
// no native players), and _openOn throwing LateInitializationError
// is the observable proof the open was attempted.
//
// The store group covers the two music_store.dart fixes in this audit:
// getQueue() recovers an out-of-range index to 0 when songs exist
// (instead of -1 with a queue but no current song), and saveResume()
// refreshes recency so the 200-cap evicts the truly-oldest entry.
// The sleep group covers the deadline-based countdown in
// sleep_timer.dart (remaining is recomputed from a deadline, so a
// stalled tick cannot leave the timer firing late).

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';
import 'package:standalone/services/music/music_store.dart';
import 'package:standalone/services/music/sleep_timer.dart';

Song _wy(String id, String title) =>
    Song(songId: id, title: title, artist: '陈奕迅', platform: MusicPlatform.wy, dur: 240);

Song _tx(String id, String title) =>
    Song(songId: id, title: title, artist: '陈奕迅', platform: MusicPlatform.tx, dur: 240);

Song _kg(String id, String title) =>
    Song(songId: id, title: title, artist: '陈奕迅', platform: MusicPlatform.kg, dur: 240);

class _FakeApi extends MusicApi {
  @override
  Future<List<LyricLine>> lyrics(Song song) async => [];

  @override
  Future<Song?> findAltPlatform(
    String title,
    String artist,
    MusicPlatform excludePf,
    String album,
  ) async =>
      null;
}

class _FakeResolvers extends MusicResolvers {
  final List<(String, MusicPlatform)> calls = [];

  @override
  void evictPlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
  ) {}

  @override
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
    String artist = '',
  }) async {
    calls.add((songId, platform));
    final url = 'https://example.com/$songId.mp3';
    return PlayUrlResult(
      url: url,
      candidates: [url],
      quality: quality,
      via: 'test',
    );
  }
}

/// The open attempt throws LateInitializationError on the uninitialised
/// player in this harness — that throw is the proof the song was
/// opened. Anything else (or no throw) fails the test.
Future<void> _expectOpenAttempted(Future<void> Function() f) async {
  try {
    await f();
  } catch (e) {
    expect(e.runtimeType.toString(), 'LateError');
    return;
  }
  fail('expected the open to be attempted (LateError)');
}

void main() {
  group('cross-platform queue', () {
    late Box<dynamic> box;
    late _FakeApi api;
    late _FakeResolvers resolvers;
    late MusicPlayerController c;

    final queue = [
      _wy('wy-1', '孤勇者'),
      _tx('tx-1', '孤勇者'),
      _kg('kg-1', '孤勇者'),
    ];

    setUp(() async {
      Hive.init('test/.hive-cross-platform-queue-test');
      box = await Hive.openBox<dynamic>('cross_platform_queue_test');
      await box.clear();
      HiveStore.setTestBox(box);
      api = _FakeApi();
      resolvers = _FakeResolvers();
      c = MusicPlayerController(api: api, resolvers: resolvers);
      c.queue.clear();
      c.queue.addAll(queue);
      c.currentIndex.value = -1;
    });

    tearDown(() async {
      await box.close();
      await Hive.deleteBoxFromDisk('cross_platform_queue_test');
    });

    test('mixed wy/tx/kg queue resolves each song on its own platform, in order',
        () async {
      await _expectOpenAttempted(() => c.playQueue(queue, 0));
      expect(c.currentIndex.value, 0);
      expect(resolvers.calls, [('wy-1', MusicPlatform.wy)]);

      await _expectOpenAttempted(() => c.next());
      expect(c.currentIndex.value, 1);
      expect(resolvers.calls, [
        ('wy-1', MusicPlatform.wy),
        ('tx-1', MusicPlatform.tx),
      ]);

      await _expectOpenAttempted(() => c.next());
      expect(c.currentIndex.value, 2);
      expect(resolvers.calls, [
        ('wy-1', MusicPlatform.wy),
        ('tx-1', MusicPlatform.tx),
        ('kg-1', MusicPlatform.kg),
      ]);

      // Queue order itself is untouched by the platform switches.
      expect(c.queue.map((s) => s.songId).toList(), ['wy-1', 'tx-1', 'kg-1']);
      expect(
        c.queue.map((s) => s.platform).toList(),
        [MusicPlatform.wy, MusicPlatform.tx, MusicPlatform.kg],
      );
    });

    test('sequential mode stops at the end of a mixed queue', () async {
      await _expectOpenAttempted(() => c.playQueue(queue, 2));
      expect(c.currentIndex.value, 2);
      expect(resolvers.calls, [('kg-1', MusicPlatform.kg)]);
      // No throw (nothing to open) and no extra resolve.
      await c.next();
      expect(c.currentIndex.value, 2);
      expect(resolvers.calls, [('kg-1', MusicPlatform.kg)]);
    });

    test('prev walks back across platforms', () async {
      await _expectOpenAttempted(() => c.playQueue(queue, 2));
      expect(resolvers.calls, [('kg-1', MusicPlatform.kg)]);
      await _expectOpenAttempted(() => c.prev());
      expect(c.currentIndex.value, 1);
      expect(resolvers.calls.last, ('tx-1', MusicPlatform.tx));
    });
  });

  group('queue / resume store', () {
    late Box<dynamic> box;

    setUp(() async {
      Hive.init('test/.hive-cross-platform-queue-test');
      box = await Hive.openBox<dynamic>('cross_platform_queue_test');
      await box.clear();
      HiveStore.setTestBox(box);
    });

    tearDown(() async {
      await box.close();
      await Hive.deleteBoxFromDisk('cross_platform_queue_test');
    });

    test('saveQueue/getQueue round-trips order + index', () async {
      final songs = [_wy('1', 'A'), _tx('2', 'B'), _kg('3', 'C')];
      await MusicStore.saveQueue(songs, 1);
      final saved = MusicStore.getQueue();
      expect(saved.songs.map((s) => s.songId).toList(), ['1', '2', '3']);
      expect(saved.index, 1);
    });

    test('out-of-range index recovers to 0 when songs exist', () async {
      await MusicStore.saveQueue([_wy('1', 'A'), _wy('2', 'B')], 99);
      expect(MusicStore.getQueue().index, 0);
      await MusicStore.saveQueue([_wy('1', 'A')], -1);
      expect(MusicStore.getQueue().index, 0);
    });

    test('empty queue still round-trips as empty / -1', () async {
      await MusicStore.saveQueue([], -1);
      final saved = MusicStore.getQueue();
      expect(saved.songs, isEmpty);
      expect(saved.index, -1);
    });

    test('corrupt queue JSON returns empty, never throws', () async {
      await HiveStore.put(HiveKeys.musicQueue, 'not json{{{');
      final saved = MusicStore.getQueue();
      expect(saved.songs, isEmpty);
      expect(saved.index, -1);
      await HiveStore.put(HiveKeys.musicQueue, '{"songs": "nope"}');
      expect(MusicStore.getQueue().songs, isEmpty);
    });

    test('resume map caps at 200 and re-saving refreshes recency', () async {
      for (var i = 0; i < 200; i++) {
        await MusicStore.saveResume('k$i', 10 + i);
      }
      expect(MusicStore.getResumeMap().length, 200);
      // k0 is re-saved (listened again) — it must survive the next
      // eviction while the truly-oldest (k1) goes.
      await MusicStore.saveResume('k0', 999);
      await MusicStore.saveResume('k200', 10);
      final map = MusicStore.getResumeMap();
      expect(map.length, 200);
      expect(map.containsKey('k0'), isTrue);
      expect(map['k0'], 999);
      expect(map.containsKey('k1'), isFalse);
      expect(map.containsKey('k200'), isTrue);
    });

    test('clearResume drops only that song', () async {
      await MusicStore.saveResume('wy|1', 120);
      await MusicStore.saveResume('tx|2', 60);
      await MusicStore.clearResume('wy|1');
      expect(MusicStore.resumeFor('wy|1'), 0);
      expect(MusicStore.resumeFor('tx|2'), 60);
    });
  });

  group('sleep timer deadline countdown', () {
    test('fires once at the deadline and clears itself', () {
      var fired = 0;
      fakeAsync((async) {
        final timer = SleepTimer(onFire: () => fired++);
        timer.start(SleepTimerOption.min5);
        expect(timer.remaining, const Duration(minutes: 5));
        async.elapse(const Duration(minutes: 4, seconds: 59));
        expect(fired, 0);
        expect(timer.remaining, const Duration(seconds: 1));
        async.elapse(const Duration(seconds: 1));
        expect(fired, 1);
        expect(timer.isActive, isFalse);
        expect(timer.remaining, isNull);
        async.elapse(const Duration(minutes: 10));
        expect(fired, 1);
      });
    });

    test('custom minutes clamp 1..720, bad input falls back to 30', () {
      expect(clampSleepCustomMinutes(null), 30);
      expect(clampSleepCustomMinutes(0), 1);
      expect(clampSleepCustomMinutes(9999), 720);
      expect(clampSleepCustomMinutes(45), 45);
    });

    test('queue-end has no clock and reports isQueueEnd', () {
      final timer = SleepTimer(onFire: () {});
      timer.start(SleepTimerOption.queueEnd);
      expect(timer.isActive, isTrue);
      expect(timer.isQueueEnd, isTrue);
      expect(timer.remaining, isNull);
      expect(timer.remainingText, '');
      timer.cancel();
      expect(timer.isActive, isFalse);
    });
  });
}
