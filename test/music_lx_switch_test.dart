// LX switch logic (chen 2026-11-17: "你就看lxmusic的播放逻辑").
//
// LX (lx-music-mobile src/core/player/player.ts) switches songs as:
//   handlePlay (~230): `await setStop()` FIRST — old song stops, timers
//     cleared — then debouncePlay (200 ms) -> setMusicUrl.
//   setMusicUrl (~135): entry check `if (!diffCurrentMusicInfo) return`,
//     stamp `gettingUrlId = createGettingUrlId(musicInfo)`, fetch the
//     URL, and only `setResource` it when the song is still current.
//   getMusicPlayUrl (~96): after the URL arrives, re-check
//     `if (isPlayedStop || diffCurrentMusicInfo) return null` — a URL
//     fetched for a song the user already left is DISCARDED, never
//     pasted onto the new song.
//   diffCurrentMusicInfo (~69): gettingUrlId + song id + isPlay.
//   Pic/lyric callbacks: `if (musicInfo.id != playMusicInfo...) return`.
//
// Ours (v1.0.9) did the opposite: the old song kept playing while the
// new one resolved, the UI switched immediately, and a slow resolve
// left the old song sounding under the new song's name (the video bug:
// UI on 蜜蜂, audio still 生而为人, duration stuck at -0:00, position
// ticking from the old player's playhead). A stale crossfade could
// also steal _active back after a newer manual load, and stale lyrics
// / prefetch / duration callbacks had no identity check at all.
//
// These tests drive the controller with fake players + a controllable
// resolver (same seam as music_crossfade_lost_error_test.dart) and
// fail on the pre-fix controller, pass after the LX-style fix.
import 'dart:async';

import 'package:dio/dio.dart';
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

Song _song(String id, String title, {int dur = 240}) =>
    Song(songId: id, title: title, artist: 'Singer $title', dur: dur);

String _urlForTitle(String title) => 'https://example.com/$title.flac';

/// Fake player: tracks whether it is actually sounding, so the test
/// can tell "old song still playing" from "old song stopped".
class _FakePlayer extends AvMusicPlayer {
  _FakePlayer({this.slowOpenTitles = const {}});

  /// Titles whose open() waits for [_slowOpenGate] (a crossfade open
  /// in flight while the user taps next).
  final Set<String> slowOpenTitles;
  final Completer<void> slowOpenGate = Completer<void>();

  final List<String> openedUrls = [];
  var playCalls = 0;
  var pauseCalls = 0;
  var playing = false;

  @override
  Future<bool> open(String url, {bool play = true}) async {
    openedUrls.add(url);
    final title = Uri.parse(url).pathSegments.last.split('.').first;
    if (slowOpenTitles.contains(title)) {
      await slowOpenGate.future;
    }
    playing = play;
    return true;
  }

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Future<void> play() async {
    playCalls++;
    playing = true;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playing = false;
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

/// Resolver whose per-title answers the test controls: a title with a
/// pending completer does not resolve until the test completes it.
class _ControlledResolvers extends MusicResolvers {
  _ControlledResolvers() : super(dio: Dio());

  final List<String> resolvedTitles = [];
  final List<String> evicted = [];
  final Map<String, Completer<PlayUrlResult?>> pending = {};

  void pend(String title) {
    pending[title] = Completer<PlayUrlResult?>();
  }

  void resolve(String title, {String? url}) {
    final c = pending.remove(title);
    c?.complete(
      PlayUrlResult(
        url: url ?? _urlForTitle(title),
        candidates: [url ?? _urlForTitle(title)],
        quality: AudioQuality.hires,
        via: 'test',
      ),
    );
  }

  @override
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
  }) async {
    resolvedTitles.add(title);
    final c = pending[title];
    if (c != null) return c.future;
    return PlayUrlResult(
      url: _urlForTitle(title),
      candidates: [_urlForTitle(title)],
      quality: quality,
      via: 'test',
    );
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

/// Fake API: controllable lyrics + no alt platform (trial path falls
/// through to the next song).
class _FakeApi extends MusicApi {
  _FakeApi() : super(dio: Dio());

  final Map<String, Completer<List<LyricLine>>> pendingLyrics = {};

  void pendLyrics(String title) {
    pendingLyrics[title] = Completer<List<LyricLine>>();
  }

  void answerLyrics(String title, List<LyricLine> lines) {
    pendingLyrics.remove(title)?.complete(lines);
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async {
    final c = pendingLyrics[song.title];
    if (c != null) return c.future;
    return [LyricLine(t: 0, text: '${song.title}-line')];
  }

  @override
  Future<Song?> findAltPlatform(
    String title,
    String artist,
    MusicPlatform excludePf,
    String album,
  ) async =>
      null;
}

void main() {
  late Box<dynamic> box;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Hive.init('test/.hive-lx-switch-test');
    box = await Hive.openBox<dynamic>('lx_switch_test');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('lx_switch_test');
  });

  MusicPlayerController makeController({
    required _FakePlayer playerA,
    required _FakePlayer playerB,
    required _ControlledResolvers resolvers,
    required _FakeApi api,
    required List<Song> songs,
  }) {
    final c = MusicPlayerController(
      api: api,
      resolvers: resolvers,
      playerA: playerA,
      playerB: playerB,
    );
    c.queue.clear();
    c.queue.addAll(songs);
    c.currentIndex.value = 0;
    return c;
  }

  group('LX: stop the old song first (the v1.0.9 video bug)', () {
    test('manual next pauses the old song while the new one resolves',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _ControlledResolvers();
      final api = _FakeApi();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        api: api,
        songs: [_song('1', 'A'), _song('2', 'B'), _song('3', 'C')],
      );
      resolvers.pend('B');

      await c.playIndex(0);
      expect(playerA.openedUrls, [_urlForTitle('A')]);
      expect(playerA.playing, isTrue);
      final pausesAfterPlay = playerA.pauseCalls;

      // Tap next while B's resolve is still in flight (the video:
      // UI already on the new song, resolve slow).
      unawaited(c.next());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(c.currentIndex.value, 1);
      expect(c.isResolving.value, isTrue);
      // LX handlePlay: the old song is stopped FIRST. Pre-fix the old
      // player kept sounding here (pauseCalls unchanged, playing true)
      // while the UI already showed B.
      expect(playerA.pauseCalls, greaterThan(pausesAfterPlay));
      expect(playerA.playing, isFalse);

      // The resolve lands: B opens on the same player and plays.
      resolvers.resolve('B');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(playerA.openedUrls.last, _urlForTitle('B'));
      expect(playerA.playing, isTrue);
      expect(c.isResolving.value, isFalse);
    });

    test('empty songId songs never share a cached URL', () async {
      // Two different songs with songId '' on the same platform share
      // the cache key '|wy|hires'. Pre-fix, the second song's load hit
      // the first song's prefetched URL and played the wrong song.
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _ControlledResolvers();
      final api = _FakeApi();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        api: api,
        songs: [
          _song('1', 'A'),
          _song('', 'B'),
          _song('', 'C'),
        ],
      );
      resolvers.pend('B');
      resolvers.pend('C');

      await c.playIndex(0);
      // The prefetch for B is in flight; load B before it lands.
      unawaited(c.next());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.currentIndex.value, 1);
      resolvers.resolve('B');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(playerA.openedUrls.last, _urlForTitle('B'));

      // C's prefetch is still pending; C's load must NOT take B's
      // cached URL from the shared empty-id key.
      unawaited(c.next());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.currentIndex.value, 2);
      expect(c.isResolving.value, isTrue);
      expect(playerA.openedUrls.last, _urlForTitle('B'));

      resolvers.resolve('C');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(playerA.openedUrls.last, _urlForTitle('C'));
    });
  });

  group('LX: a stale crossfade never steals the active player', () {
    test('manual next during a crossfade open wins', () async {
      final playerA = _FakePlayer();
      // B's crossfade open on playerB hangs until the test releases it.
      final playerB = _FakePlayer(slowOpenTitles: {'B'});
      final resolvers = _ControlledResolvers();
      final api = _FakeApi();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        api: api,
        songs: [
          _song('1', 'A'),
          _song('2', 'B'),
          _song('3', 'C'),
          _song('4', 'D'),
        ],
      );

      await c.playIndex(0);
      expect(playerA.openedUrls, [_urlForTitle('A')]);

      // Auto-advance to B: the crossfade open on playerB is in flight.
      unawaited(c.next(auto: true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(playerB.openedUrls, [_urlForTitle('B')]);

      // Manual next to C while B's open is still pending: C opens on
      // the still-active playerA and plays.
      await c.next();
      expect(c.currentIndex.value, 2);
      expect(playerA.openedUrls.last, _urlForTitle('C'));
      expect(playerA.playing, isTrue);
      final pausesAfterC = playerA.pauseCalls;

      // The stale crossfade's open finally completes. Pre-fix it
      // swapped _active to playerB and started a fade that silenced
      // playerA (C); the next manual cut then opened on playerB.
      playerB.slowOpenGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await c.next();
      expect(c.currentIndex.value, 3);
      expect(
        playerA.openedUrls.last,
        _urlForTitle('D'),
        reason: 'D must open on playerA — the stale crossfade to B '
            'must not have stolen _active',
      );
      expect(playerB.openedUrls, [_urlForTitle('B')]);
      // No stale fade paused C's player after the manual cut.
      expect(playerA.pauseCalls, pausesAfterC + 1);
    });
  });

  group('LX: stale async results are discarded', () {
    test('late lyrics for the previous song do not overwrite', () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _ControlledResolvers();
      final api = _FakeApi();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        api: api,
        songs: [_song('1', 'A'), _song('2', 'B'), _song('3', 'C')],
      );
      api.pendLyrics('B');

      await c.playIndex(0);
      await c.next();
      expect(c.currentIndex.value, 1);
      expect(c.lyrics.map((l) => l.text), isEmpty);

      await c.next();
      expect(c.currentIndex.value, 2);
      expect(
        c.lyrics.map((l) => l.text).toList(),
        ['C-line'],
      );

      // B's lyrics arrive late: pre-fix they overwrote C's lyrics.
      api.answerLyrics('B', [LyricLine(t: 0, text: 'B-line')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        c.lyrics.map((l) => l.text).toList(),
        ['C-line'],
      );
    });

    test('late duration event during a resolve does not trip trial',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _ControlledResolvers();
      final api = _FakeApi();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        api: api,
        songs: [_song('1', 'A'), _song('2', 'B', dur: 300), _song('3', 'C')],
      );
      resolvers.pend('B');

      await c.playIndex(0);
      unawaited(c.next());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.currentIndex.value, 1);
      expect(c.isResolving.value, isTrue);

      // A 15 s duration event arriving now belongs to the OLD song
      // (its item was still loading when the user switched). Pre-fix
      // it ran trial handling for B and advanced to C.
      c.onRealDuration(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.currentIndex.value, 1);
      expect(resolvers.evicted, isEmpty);
      expect(c.isResolving.value, isTrue);

      resolvers.resolve('B');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(playerA.openedUrls.last, _urlForTitle('B'));
    });
  });
}
