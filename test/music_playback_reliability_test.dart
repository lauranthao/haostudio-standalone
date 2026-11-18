// Music playback reliability regressions (chen 2026-11-18: "现在全是
// 音乐播放上的问题，你全部查出来，包括我没查到的，细查，全部解决").
//
// 1. Trial clip must retry the SAME song from another source (exclude
//    the job that served the trial URL), not silently skip to the next
//    song. chen's phone case: Die For You — oiapi served a 30 s clip
//    while lzm/zddyr/gd had the full track.
// 2. A manually tapped song that fails to load must NOT auto-skip:
//    it stops on the song with a failure notice (retry / next).
//    Only auto-advance skips, with a notice naming the song + reason.
// 3. When a failure chain gives up at the queue end, the previous
//    song must be stopped — the old crossfade fallback left it
//    sounding ("加载不出来就直接放的还是上一首歌").
// 4. Single-loop auto failure must advance, not retry the dead song
//    forever (singleLoop's auto-replay returns the same index).
// 5. A stale crossfade's error must not skip the song the user moved
//    on to (gen guard on _onPlayError / _tryAltOrNext).
// 6. Prefetch pre-buffers the next song's audio; the crossfade reuses
//    the preload instead of opening cold.
// 7. Prefetch cache TTL (5 min): stale URLs resolve fresh.
// 8. Two songs with an empty songId must not share an identityKey:
//    tapping the second must load it, not resume the first.
// 9. Switching platform then tapping result #1 (index 0) must load
//    it: after playQueue replaces the queue, the old index still
//    points at the new list, so the same-song shortcut must NOT
//    compare against queue[currentIndex] (chen 2026-11-18).
// 10. Sleep timer firing mid-resolve must silence the landing song:
//     the old player is already stopped, so onFire's pause is a
//     no-op and the new song would otherwise play past the deadline
//     (peripheral audit 2026-11-18).
//
// Harness: controller constructed directly (no Get.put, no onInit),
// fake players through the constructor seam (same pattern as
// music_crossfade_lost_error_test.dart), scripted resolvers.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/av_music_player.dart';
import 'package:standalone/features/music/music_player_controller.dart';
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
  Song? alt;
  Completer<Song?>? altCompleter;
  final List<String> altLookups = [];

  @override
  Future<Song?> findAltPlatform(
    String title,
    String artist,
    MusicPlatform excludePf,
    String album,
  ) async {
    altLookups.add(title);
    if (altCompleter != null) return altCompleter!.future;
    return alt;
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => [];
}

/// Resolvers driven by a per-test script: the function receives the
/// song id and the exclusion set for the call and returns the result
/// (null = no source). Every call is logged for assertions. The
/// script may return a Future (a parked Completer) so a resolve can
/// be held mid-flight — e.g. the sleep-timer resolve-window test.
class _ScriptedResolvers extends MusicResolvers {
  _ScriptedResolvers(this.script);

  final FutureOr<PlayUrlResult?> Function(
    String songId,
    Set<String> excludeJobs,
  ) script;
  final List<({String songId, String title, Set<String> excludeJobs})>
      calls = [];
  final List<String> evicted = [];

  @override
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
  }) async {
    calls.add((
      songId: songId,
      title: title,
      excludeJobs: Set.of(excludeJobs),
    ));
    return await script(songId, excludeJobs);
  }

  @override
  void evictPlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
  ) {
    evicted.add('$songId|${platform.code}|${quality.code}');
  }
}

class _FakePlayer extends AvMusicPlayer {
  _FakePlayer({required this.failUrls});

  final Set<String> failUrls;
  final List<String> openedUrls = [];
  final List<String> preloadedUrls = [];
  var playCalls = 0;
  var pauseCalls = 0;
  var _failed = false;

  @override
  Future<bool> open(String url, {bool play = true}) async {
    openedUrls.add(url);
    _failed = failUrls.contains(url);
    return true;
  }

  @override
  Future<bool> preload(String url) async {
    // A URL that cannot load fails the preload too (it must not
    // poison the crossfade into trusting a dead buffer).
    if (failUrls.contains(url)) return false;
    preloadedUrls.add(url);
    return true;
  }

  @override
  bool isPreloadedFor(String url) => preloadedUrls.contains(url);

  @override
  ProcessingState get processingState =>
      _failed ? ProcessingState.idle : ProcessingState.ready;

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> dispose() async {}
}

/// Runs [body] in a zone that captures unhandled async errors instead
/// of failing the test on them (same pattern as
/// music_trial_clip_test.dart).
Future<List<Object>> _runCatchingAsyncErrors(
  Future<void> Function() body,
) async {
  final errors = <Object>[];
  await runZonedGuarded(() async {
    await body();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }, (e, _) => errors.add(e));
  return errors;
}

void main() {
  group('prefetch TTL (pure)', () {
    test('fresh within 5 min, stale after', () {
      final now = DateTime(2026, 11, 18, 8, 0);
      expect(
        MusicPlayerController.isPrefetchFresh(
          now.subtract(const Duration(minutes: 4, seconds: 59)),
          now,
        ),
        isTrue,
      );
      expect(
        MusicPlayerController.isPrefetchFresh(
          now.subtract(const Duration(minutes: 5)),
          now,
        ),
        isFalse,
      );
      expect(
        MusicPlayerController.isPrefetchFresh(
          now.subtract(const Duration(minutes: 60)),
          now,
        ),
        isFalse,
      );
    });
  });

  group('playback reliability (fake players)', () {
    late Box<dynamic> box;
    late _FakeApi api;
    late _ScriptedResolvers resolvers;
    late _FakePlayer playerA;
    late _FakePlayer playerB;
    late MusicPlayerController c;

    MusicPlayerController makeController({Set<String> failB = const {}}) {
      // Players are built here (inside the test body), not in setUp:
      // AvMusicPlayer constructs a real just_audio AudioPlayer, whose
      // AudioSession touches the platform channel — that needs the
      // test binding, which is only up once the test body runs.
      playerA = _FakePlayer(failUrls: const {});
      playerB = _FakePlayer(failUrls: failB);
      return MusicPlayerController(
        api: api,
        resolvers: resolvers,
        playerA: playerA,
        playerB: playerB,
      );
    }

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      Hive.init('test/.hive-playback-reliability-test');
      box = await Hive.openBox<dynamic>('playback_reliability_test');
      await box.clear();
      HiveStore.setTestBox(box);
      api = _FakeApi();
    });

    tearDown(() async {
      await box.close();
      await Hive.deleteBoxFromDisk('playback_reliability_test');
    });

    test('trial clip retries the SAME song from another source',
        () async {
      // chen's phone case: Die For You — oiapi serves a 30 s trial,
      // lzm has the full track. The retry must exclude oiapi and
      // open the full track on the SAME song, not skip.
      const trialUrl = 'https://example.com/die-trial.mp3';
      const fullUrl = 'https://example.com/die-full.mp3';
      resolvers = _ScriptedResolvers((songId, excludeJobs) {
        if (songId == 'die-id') {
          if (excludeJobs.contains('oiapi')) {
            return PlayUrlResult(
              url: fullUrl,
              candidates: [fullUrl],
              quality: AudioQuality.hires,
              via: 'lzm',
            );
          }
          return PlayUrlResult(
            url: trialUrl,
            candidates: [trialUrl],
            quality: AudioQuality.hires,
            via: 'oiapi',
          );
        }
        final url = _url(songId);
        return PlayUrlResult(
          url: url,
          candidates: [url],
          quality: AudioQuality.hires,
          via: 'test',
        );
      });
      c = makeController();
      final die = _wy('die-id', 'Die For You');
      final next = _wy('next-id', '下一首');
      final errors = await _runCatchingAsyncErrors(() async {
        await c.playQueue([die, next], 0);
        expect(playerA.openedUrls, [trialUrl]);
        c.onRealDuration(const Duration(seconds: 30));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(errors, isEmpty);
      // The retry re-resolved with oiapi excluded…
      final dieCalls =
          resolvers.calls.where((e) => e.songId == 'die-id').toList();
      expect(dieCalls.length, 2);
      expect(dieCalls[1].excludeJobs, {'oiapi'});
      // …and opened the full track on the SAME song (no skip).
      expect(c.currentIndex.value, 0);
      expect(c.queue.first.title, 'Die For You');
      expect(playerA.openedUrls, [trialUrl, fullUrl]);
      expect(c.lastNotice.value, isEmpty);
    });

    test('trial retries exhausted on a manual load stops on the song',
        () async {
      // Both retries return the same trial URL from another job:
      // the exclusion did not change the winner. A manual load must
      // then stop on the song with a notice, not skip.
      const trialUrl = 'https://example.com/die-trial.mp3';
      var n = 0;
      resolvers = _ScriptedResolvers((songId, excludeJobs) {
        if (songId == 'die-id') {
          n++;
          return PlayUrlResult(
            url: trialUrl,
            candidates: [trialUrl],
            quality: AudioQuality.hires,
            via: n == 1 ? 'oiapi' : (n == 2 ? 'lzm' : 'zddyr'),
          );
        }
        final url = _url(songId);
        return PlayUrlResult(
          url: url,
          candidates: [url],
          quality: AudioQuality.hires,
          via: 'test',
        );
      });
      c = makeController();
      final die = _wy('die-id', 'Die For You');
      final errors = await _runCatchingAsyncErrors(() async {
        await c.playQueue([die, _wy('next-id', '下一首')], 0);
        c.onRealDuration(const Duration(seconds: 30));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(errors, isEmpty);
      final dieCalls =
          resolvers.calls.where((e) => e.songId == 'die-id').toList();
      expect(dieCalls.length, 3);
      expect(dieCalls[1].excludeJobs, {'oiapi'});
      expect(dieCalls[2].excludeJobs, {'oiapi', 'lzm'});
      expect(c.currentIndex.value, 0);
      expect(c.loadError.value?.song.title, 'Die For You');
      expect(c.loadError.value?.reason, '只有试听片段');
      expect(c.lastNotice.value, contains('只有试听片段'));
    });

    test('manual load failure stops on the song, no silent skip',
        () async {
      resolvers = _ScriptedResolvers((songId, excludeJobs) {
        if (songId == 'b-id') return null;
        final url = _url(songId);
        return PlayUrlResult(
          url: url,
          candidates: [url],
          quality: AudioQuality.hires,
          via: 'test',
        );
      });
      c = makeController();
      final errors = await _runCatchingAsyncErrors(() async {
        await c.playQueue(
          [_wy('a-id', 'A歌'), _wy('b-id', 'B歌')],
          1,
        );
      });
      expect(errors, isEmpty);
      expect(c.currentIndex.value, 1);
      expect(c.queue[1].title, 'B歌');
      expect(c.loadError.value?.song.title, 'B歌');
      expect(c.loadError.value?.reason, '无可用音源');
      expect(c.lastNotice.value, contains('B歌'));
      expect(c.lastNotice.value, contains('无可用音源'));
      // Nothing else was opened: no skip to another song.
      expect(playerA.openedUrls, isEmpty);
      expect(playerB.openedUrls, isEmpty);
    });

    test('auto-advance failure skips with a notice', () async {
      resolvers = _ScriptedResolvers((songId, excludeJobs) {
        if (songId == 'b-id') return null;
        final url = _url(songId);
        return PlayUrlResult(
          url: url,
          candidates: [url],
          quality: AudioQuality.hires,
          via: 'test',
        );
      });
      c = makeController();
      final errors = await _runCatchingAsyncErrors(() async {
        await c.playQueue(
          [_wy('a-id', 'A歌'), _wy('b-id', 'B歌'), _wy('c-id', 'C歌')],
          0,
        );
        await c.next(auto: true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(errors, isEmpty);
      expect(c.currentIndex.value, 2);
      expect(c.queue[2].title, 'C歌');
      expect(c.lastNotice.value, contains('B歌'));
      expect(c.lastNotice.value, contains('已跳到下一首'));
    });

    test('give-up at the queue end stops the previous song', () async {
      resolvers = _ScriptedResolvers((songId, excludeJobs) {
        if (songId == 'b-id') return null;
        final url = _url(songId);
        return PlayUrlResult(
          url: url,
          candidates: [url],
          quality: AudioQuality.hires,
          via: 'test',
        );
      });
      c = makeController();
      final errors = await _runCatchingAsyncErrors(() async {
        await c.playQueue([_wy('a-id', 'A歌'), _wy('b-id', 'B歌')], 0);
        await c.next(auto: true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(errors, isEmpty);
      // Still on B (no next track) — and the previous song A, which
      // the crossfade fallback left sounding, is now paused: the
      // manual load paused it once up front, the give-up once.
      expect(c.currentIndex.value, 1);
      expect(playerA.pauseCalls, 2);
      expect(c.lastNotice.value, contains('已是最后一首'));
    });

    test('single-loop failure advances instead of looping the dead song',
        () async {
      // In singleLoop, auto-advance replays the SAME index — the old
      // failure path (next(auto: true)) retried the dead song forever.
      // The fix advances with manual index semantics.
      resolvers = _ScriptedResolvers((songId, excludeJobs) {
        if (songId == 'a-id') return null;
        final url = _url(songId);
        return PlayUrlResult(
          url: url,
          candidates: [url],
          quality: AudioQuality.hires,
          via: 'test',
        );
      });
      c = makeController();
      c.playMode.value = 'one';
      c.queue.addAll([_wy('a-id', 'A歌'), _wy('b-id', 'B歌')]);
      c.currentIndex.value = 0;
      final errors = await _runCatchingAsyncErrors(() async {
        // Completing this call at all is the proof: the old code
        // retried A forever (singleLoop auto-replay = same index).
        await c.next(auto: true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(errors, isEmpty);
      expect(c.currentIndex.value, 1);
      expect(c.lastNotice.value, contains('A歌'));
      expect(c.lastNotice.value, contains('已跳到下一首'));
    });

    test('stale crossfade error does not skip the new song', () async {
      resolvers = _ScriptedResolvers((songId, excludeJobs) {
        final url = _url(songId);
        return PlayUrlResult(
          url: url,
          candidates: [url],
          quality: AudioQuality.hires,
          via: 'test',
        );
      });
      c = makeController(failB: {_url('b-id')});
      api.altCompleter = Completer<Song?>();
      final songs = [
        _wy('a-id', 'A歌'),
        _wy('b-id', 'B歌'),
        _wy('c-id', 'C歌'),
      ];
      final errors = await _runCatchingAsyncErrors(() async {
        await c.playQueue(songs, 0);
        // B's crossfade fails at the idle check; the alt lookup parks
        // on the completer.
        final advance = c.next(auto: true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(api.altLookups, ['B歌']);
        // The user taps C while B's failure path is still parked.
        await c.playQueue(songs, 2);
        expect(c.currentIndex.value, 2);
        // Now let the stale alt lookup finish: it must not skip C.
        api.altCompleter!.complete(null);
        await advance;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(errors, isEmpty);
      expect(c.currentIndex.value, 2);
      expect(c.queue[2].title, 'C歌');
      expect(playerA.openedUrls, contains(_url('c-id')));
      expect(c.lastNotice.value, isEmpty);
    });

    test('prefetch pre-buffers and the crossfade reuses it', () async {
      resolvers = _ScriptedResolvers((songId, excludeJobs) {
        final url = _url(songId);
        return PlayUrlResult(
          url: url,
          candidates: [url],
          quality: AudioQuality.hires,
          via: 'test',
        );
      });
      c = makeController();
      final errors = await _runCatchingAsyncErrors(() async {
        await c.playQueue([_wy('a-id', 'A歌'), _wy('b-id', 'B歌')], 0);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // The next song's audio was pre-buffered on the standby.
        expect(playerB.preloadedUrls, [_url('b-id')]);
        await c.next(auto: true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(errors, isEmpty);
      expect(c.currentIndex.value, 1);
      // The crossfade reused the preload: no second open of B's URL.
      expect(playerB.openedUrls, isEmpty);
      expect(playerB.playCalls, 1);
    });

    test('two empty-id songs do not share an identity', () async {
      resolvers = _ScriptedResolvers((songId, excludeJobs) {
        return PlayUrlResult(
          url: 'https://example.com/empty.mp3',
          candidates: const ['https://example.com/empty.mp3'],
          quality: AudioQuality.hires,
          via: 'test',
        );
      });
      c = makeController();
      final a = Song(
        songId: '',
        title: '空一',
        artist: '甲',
        platform: MusicPlatform.wy,
      );
      final b = Song(
        songId: '',
        title: '空二',
        artist: '乙',
        platform: MusicPlatform.wy,
      );
      c.queue.addAll([a, b]);
      c.currentIndex.value = 0;
      c.isPlaying.value = true;
      c.position.value = const Duration(seconds: 30);
      final errors = await _runCatchingAsyncErrors(() async {
        await c.playQueue([a, b], 1);
      });
      expect(errors, isEmpty);
      // Tapping B loads B (a resolve happened for it) instead of
      // resuming A as "the same song".
      expect(
        resolvers.calls.any((e) => e.title == '空二'),
        isTrue,
      );
      expect(playerA.openedUrls, ['https://example.com/empty.mp3']);
    });

    test('switch-platform tap on new-list index 0 loads the song',
        () async {
      // chen 2026-11-18: play song A → switch platform (capsule) →
      // search → tap result #1 → nothing plays. Root cause: after
      // playQueue replaced the queue, playIndex's _isLoadedCurrent
      // compared the tapped song against queue[oldIndex] — the
      // tapped song itself — while the old song was still playing,
      // so the same-song shortcut skipped the load entirely.
      resolvers = _ScriptedResolvers((songId, excludeJobs) {
        final url = _url(songId);
        return PlayUrlResult(
          url: url,
          candidates: [url],
          quality: AudioQuality.hires,
          via: 'test',
        );
      });
      c = makeController();
      final a = _wy('a-id', 'A歌');
      // B is on another platform (the platform switch): a different
      // song, a different identity — but the same list index (0).
      final b = Song(
        songId: 'b-id',
        title: 'B歌',
        artist: '周杰伦',
        platform: MusicPlatform.tx,
        dur: 200,
      );
      final errors = await _runCatchingAsyncErrors(() async {
        await c.playQueue([a], 0);
        expect(playerA.openedUrls, [_url('a-id')]);
        // Simulate A playing mid-song (no onInit in this harness,
        // so the streams never report it).
        c.isPlaying.value = true;
        c.position.value = const Duration(seconds: 30);
        c.duration.value = const Duration(seconds: 260);
        // New platform, new list, tap result #1 (index 0 — the same
        // index A had).
        await c.playQueue([b], 0);
      });
      expect(errors, isEmpty);
      // B's URL was opened: the tap loaded it instead of "resuming"
      // the song that was never loaded.
      expect(playerA.openedUrls, [_url('a-id'), _url('b-id')]);
      expect(c.currentSong?.title, 'B歌');
      expect(c.currentIndex.value, 0);
    });

    test('sleep timer firing mid-resolve silences the landing song',
        () async {
      // Peripheral audit (chen 2026-11-18): the timer fires while
      // the next song is still resolving — the old player is already
      // stopped, so onFire's pause is a no-op and the new song opens
      // and plays past the deadline. The landing load must pause.
      final bCompleter = Completer<PlayUrlResult?>();
      var bCalls = 0;
      resolvers = _ScriptedResolvers((songId, excludeJobs) {
        if (songId == 'b-id') {
          bCalls++;
          return bCompleter.future;
        }
        final url = _url(songId);
        return PlayUrlResult(
          url: url,
          candidates: [url],
          quality: AudioQuality.hires,
          via: 'test',
        );
      });
      c = makeController();
      final errors = await _runCatchingAsyncErrors(() async {
        await c.playQueue([_wy('a-id', 'A歌'), _wy('b-id', 'B歌')], 0);
        // A's load prefetches B: the prefetch also parks on the
        // same future (one Completer, awaited twice). The prefetch
        // kicks off async, so let it reach the resolve call first.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(bCalls, 1);
        // Auto-advance to B: its load parks in the resolve.
        final advance = c.next(auto: true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(bCalls, 2);
        // The timer fires while B is still resolving.
        c.fireSleepTimerForTest();
        // The resolve lands: B is loaded (pre-buffered on the
        // standby, reused by the crossfade) but must not sound.
        bCompleter.complete(PlayUrlResult(
          url: _url('b-id'),
          candidates: [_url('b-id')],
          quality: AudioQuality.hires,
          via: 'test',
        ));
        await advance;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(errors, isEmpty);
      expect(c.currentIndex.value, 1);
      // The prefetch for B is correctly dropped once B becomes
      // current (its resolve landed after the advance), so the
      // crossfade opens B directly on the standby instead.
      expect(playerB.openedUrls, [_url('b-id')]);
      // The landing load was paused by the fired timer (the standby,
      // now active, got exactly one pause from the sleep check).
      expect(playerB.pauseCalls, 1);
    });

    test('sleep timer firing mid-resolve silences a manual tap too',
        () async {
      // Same gap, manual flavour: the user taps B while its resolve
      // is still in flight and the timer fires in the window.
      final bCompleter = Completer<PlayUrlResult?>();
      resolvers = _ScriptedResolvers((songId, excludeJobs) {
        if (songId == 'b-id') return bCompleter.future;
        final url = _url(songId);
        return PlayUrlResult(
          url: url,
          candidates: [url],
          quality: AudioQuality.hires,
          via: 'test',
        );
      });
      c = makeController();
      final errors = await _runCatchingAsyncErrors(() async {
        await c.playQueue([_wy('a-id', 'A歌'), _wy('b-id', 'B歌')], 0);
        final tap = c.playQueue([_wy('a-id', 'A歌'), _wy('b-id', 'B歌')], 1);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        c.fireSleepTimerForTest();
        bCompleter.complete(PlayUrlResult(
          url: _url('b-id'),
          candidates: [_url('b-id')],
          quality: AudioQuality.hires,
          via: 'test',
        ));
        await tap;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(errors, isEmpty);
      expect(c.currentIndex.value, 1);
      expect(playerA.openedUrls, contains(_url('b-id')));
      // Three pauses on the active player: A's manual load up-front
      // pause, B's manual load up-front pause, then the sleep check
      // after the landing open. Without the fix the third pause is
      // missing (pauseCalls == 2) and the song sounds past the
      // deadline.
      expect(playerA.pauseCalls, 3);
    });
  });
}
