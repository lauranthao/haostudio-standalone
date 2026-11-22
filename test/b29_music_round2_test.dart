// Round-2 music playback investigation (chen 2026-11-22 18:45: sleep
// timer was never on, so round-1's sleep suspects are excluded; his
// phone runs shipped 1.1.6+28).
//
// Repro tests: each test FAILS on the 1.1.6 code and PASSES after the
// fix. Written red-first; the fixes land in the same change.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/av_music_player.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_downloads.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';
import 'package:standalone/services/music/music_store.dart';
import 'package:standalone/services/music/play_mode.dart';

Song _song(String id, String title, {int dur = 200}) =>
    Song(songId: id, title: title, artist: 'Singer $id', dur: dur);

String _url(String id) => 'https://example.com/$id.flac';

/// Fake AvMusicPlayer: records every call so the test can tell what
/// the controller did to each half of the A/B pair.
class _FakePlayer extends AvMusicPlayer {
  final List<String> openedUrls = [];
  final List<double> volumeLog = [];
  final List<Duration> seekCalls = [];
  var playCalls = 0;
  var pauseCalls = 0;
  var preloadCalls = 0;

  /// Override the synchronous processing state (the real just_audio
  /// player reports `completed` once a track ends).
  ProcessingState? processingStateOverride;

  /// One-shot hook run inside open() — lets the test fire an event
  /// (e.g. a duration event) during the open's own await.
  void Function()? onFirstOpen;

  @override
  Future<bool> open(String url, {bool play = true}) async {
    openedUrls.add(url);
    final hook = onFirstOpen;
    onFirstOpen = null;
    hook?.call();
    return true;
  }

  @override
  ProcessingState get processingState =>
      processingStateOverride ?? ProcessingState.ready;

  @override
  Future<bool> preload(String url) async {
    preloadCalls++;
    return true;
  }

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
    volumeLog.add(volume);
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

/// Resolver that answers instantly. [qualityById] lets a song resolve
/// at a different tier than requested (badge tests). [urlFor] lets a
/// re-resolve return a different URL (trial retry).
class _InstantResolvers extends MusicResolvers {
  _InstantResolvers() : super(dio: Dio());

  Map<String, AudioQuality> qualityById = {};
  String Function(String songId, int callNo)? urlFor;
  final List<String> resolvedIds = [];
  final List<Set<String>> excludeJobsSeen = [];
  final Map<String, int> resolveCounts = {};

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
    resolvedIds.add(songId);
    excludeJobsSeen.add(Set.of(excludeJobs));
    final n = (resolveCounts[songId] ?? 0) + 1;
    resolveCounts[songId] = n;
    return PlayUrlResult(
      url: urlFor?.call(songId, n) ?? _url(songId),
      candidates: [urlFor?.call(songId, n) ?? _url(songId)],
      quality: qualityById[songId] ?? quality,
      via: 'test',
    );
  }
}

/// Resolver that holds chosen songs until the test releases them, so
/// a load can be kept in flight while the test fires other events.
class _DelayedResolvers extends MusicResolvers {
  _DelayedResolvers({this.holdIds = const {}}) : super(dio: Dio());

  final Set<String> holdIds;
  final Map<String, Completer<PlayUrlResult?>> _held = {};
  final List<String> resolvedIds = [];

  void release(String songId, [PlayUrlResult? result]) {
    final c = _held[songId];
    if (c != null && !c.isCompleted) {
      c.complete(result ??
          PlayUrlResult(
            url: _url(songId),
            candidates: [_url(songId)],
            quality: AudioQuality.hires,
            via: 'test',
          ));
    }
  }

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
    resolvedIds.add(songId);
    if (!holdIds.contains(songId)) {
      return PlayUrlResult(
        url: _url(songId),
        candidates: [_url(songId)],
        quality: quality,
        via: 'test',
      );
    }
    final c = _held.putIfAbsent(
      songId,
      () => Completer<PlayUrlResult?>(),
    );
    return c.future;
  }
}

/// Resolver that answers null for chosen songs (no source) so the
/// alt-platform fallback runs.
class _NullResolvers extends MusicResolvers {
  _NullResolvers({this.nullIds = const {}}) : super(dio: Dio());

  final Set<String> nullIds;
  final List<String> resolvedIds = [];

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
    resolvedIds.add(songId);
    if (nullIds.contains(songId)) return null;
    return PlayUrlResult(
      url: _url(songId),
      candidates: [_url(songId)],
      quality: quality,
      via: 'test',
    );
  }
}

class _FakeApi extends MusicApi {
  _FakeApi() : super(dio: Dio());

  Song? altToReturn;

  @override
  Future<Song?> findAltPlatform(
    String title,
    String artist,
    MusicPlatform excludePf,
    String album, {
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      altToReturn;
}

class _FakeDownloads extends MusicDownloadService {
  Map<String, String> paths = {};
  Map<String, AudioQuality> tiers = {};

  @override
  String? localPathFor(Song song) => paths[song.identityKey];

  @override
  AudioQuality? tierFor(Song song) => tiers[song.identityKey];
}

Future<void> _pump([int ms = 100]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late Box<dynamic> box;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Hive.init('test/.hive-round2-test');
    box = await Hive.openBox<dynamic>('round2_test');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('round2_test');
  });

  MusicPlayerController makeController({
    required _FakePlayer playerA,
    required _FakePlayer playerB,
    required MusicResolvers resolvers,
    MusicApi? api,
    MusicDownloadService? downloads,
    List<Song> songs = const [],
  }) {
    final c = MusicPlayerController(
      api: api,
      resolvers: resolvers,
      downloads: downloads,
      playerA: playerA,
      playerB: playerB,
    );
    c.queue.clear();
    c.queue.addAll(songs);
    c.currentIndex.value = songs.isEmpty ? -1 : 0;
    return c;
  }

  group('F1: completion during a manual load (A2a)', () {
    test('old song completing mid-resolve does not skip the tapped song',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _DelayedResolvers(holdIds: {'2'});
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B'), _song('3', 'C')],
      );
      await c.playIndex(0);
      expect(c.currentIndex.value, 0);

      // Tap B: its resolve is held, so the load is in flight.
      final loadB = c.playIndex(1);
      await _pump();
      expect(c.isResolving.value, isTrue);

      // The old song A finishes while B is still resolving.
      c.simulateTrackCompletedForTest();
      await _pump();

      resolvers.release('2');
      await loadB;
      await _pump();

      // B plays; C was never loaded (a skip would have crossfaded
      // it onto the standby player). The prefetch of C after B lands
      // is normal and does not count as a skip.
      expect(c.currentIndex.value, 1);
      expect(playerA.openedUrls, contains(_url('2')));
      expect(playerB.openedUrls, isEmpty);
    });

    test('single-loop: old song completing mid-resolve does not restart A',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _DelayedResolvers(holdIds: {'2'});
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B'), _song('3', 'C')],
      );
      c.playMode.value = 'one';
      await c.playIndex(0);

      final loadB = c.playIndex(1);
      await _pump();
      expect(c.isResolving.value, isTrue);

      c.simulateTrackCompletedForTest();
      await _pump();

      resolvers.release('2');
      await loadB;
      await _pump();

      // No replay of A (no seek-to-zero on the active player) while
      // B was loading; B lands normally.
      expect(c.currentIndex.value, 1);
      expect(playerA.seekCalls, isNot(contains(Duration.zero)));
    });
  });

  group('F2a: crossfade fade-in after the old song already ended (A1a)',
      () {
    test('auto-advance starts the new song at full volume, no 2.5 s ramp',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _InstantResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B')],
      );
      await c.playIndex(0);
      // The manual load pauses the active player once before opening.
      final pausesBefore = playerA.pauseCalls;
      // The old song ended: the real just_audio player reports
      // `completed` once a track ends.
      playerA.processingStateOverride = ProcessingState.completed;

      await c.next(auto: true);
      await _pump(300);

      expect(c.currentIndex.value, 1);
      expect(playerB.openedUrls, [_url('2')]);
      // No ramp: the incoming volume is the target from the start.
      expect(playerB.volumeLog.last, 1.0);
      // The outgoing is paused promptly, not after a 2.5 s timer.
      expect(playerA.pauseCalls, pausesBefore + 1);
    });

    test('live fade still ramps when the outgoing is still sounding',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _InstantResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B')],
      );
      await c.playIndex(0);
      final pausesBefore = playerA.pauseCalls;
      // Outgoing still playing (early crossfade): the ramp overlaps.
      playerA.processingStateOverride = ProcessingState.ready;

      await c.next(auto: true);
      await _pump(300);

      expect(c.currentIndex.value, 1);
      expect(playerB.volumeLog.first, 0.0);
      expect(playerB.volumeLog.last, lessThan(1.0));
      expect(playerA.pauseCalls, pausesBefore);
    });
  });

  group('F2b: early crossfade trigger (true overlap)', () {
    test('crossfade starts before the end when the next track is prefetched',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _InstantResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B'), _song('3', 'C')],
      );
      await c.playIndex(0);
      // Let the prefetch for B land in _nextCache.
      await _pump(200);
      c.duration.value = const Duration(seconds: 180);
      c.isPlaying.value = true;

      // 2 s left of a 180 s track: inside the 2.5 s crossfade window.
      c.simulatePositionForTest(const Duration(seconds: 178));
      await _pump(200);

      expect(c.currentIndex.value, 1);
      expect(playerB.openedUrls, contains(_url('2')));
    });

    test('no early trigger when the next track was not prefetched',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      // B's resolve is held, so the prefetch never lands.
      final resolvers = _DelayedResolvers(holdIds: {'2'});
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B'), _song('3', 'C')],
      );
      await c.playIndex(0);
      await _pump(200);
      c.duration.value = const Duration(seconds: 180);
      c.isPlaying.value = true;

      c.simulatePositionForTest(const Duration(seconds: 178));
      await _pump(200);

      expect(c.currentIndex.value, 0);
      expect(playerB.openedUrls, isEmpty);
    });

    test('no early trigger in single-loop mode', () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _InstantResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B')],
      );
      c.playMode.value = 'one';
      await c.playIndex(0);
      await _pump(200);
      c.duration.value = const Duration(seconds: 180);
      c.isPlaying.value = true;

      c.simulatePositionForTest(const Duration(seconds: 178));
      await _pump(200);

      expect(c.currentIndex.value, 0);
    });
  });

  group('F3: manual load during a live fade (A1c)', () {
    test('tapping another song mid-fade stops the fading outgoing player',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _InstantResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B'), _song('3', 'C')],
      );
      await c.playIndex(0);
      // Live fade: outgoing still sounding, ramp running.
      playerA.processingStateOverride = ProcessingState.ready;
      await c.next(auto: true);
      final pausesBefore = playerA.pauseCalls;

      // While the fade is still running, tap song C manually.
      await c.playIndex(2);
      await _pump();

      expect(c.currentIndex.value, 2);
      // The frozen mid-fade outgoing player is stopped.
      expect(playerA.pauseCalls, pausesBefore + 1);
    });
  });

  group('F4: pause during a live fade (A1d)', () {
    test('pause silences both players and snaps the incoming to full volume',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _InstantResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B')],
      );
      await c.playIndex(0);
      playerA.processingStateOverride = ProcessingState.ready;
      await c.next(auto: true);
      await _pump(150);
      // The incoming is mid-ramp (quiet); the outgoing still fades.
      expect(playerB.volumeLog.last, lessThan(1.0));
      final pausesABefore = playerA.pauseCalls;
      final pausesBBefore = playerB.pauseCalls;

      c.isPlaying.value = true;
      await c.pause();

      expect(playerA.pauseCalls, pausesABefore + 1);
      expect(playerB.pauseCalls, pausesBBefore + 1);
      // Resuming later plays at full volume, not frozen mid-ramp.
      expect(playerB.volumeLog.last, 1.0);
    });

    test('togglePlayPause during a live fade stops the outgoing too',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _InstantResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B')],
      );
      await c.playIndex(0);
      playerA.processingStateOverride = ProcessingState.ready;
      await c.next(auto: true);
      final pausesABefore = playerA.pauseCalls;
      final pausesBBefore = playerB.pauseCalls;

      c.isPlaying.value = true;
      await c.togglePlayPause();

      expect(playerA.pauseCalls, pausesABefore + 1);
      expect(playerB.pauseCalls, pausesBBefore + 1);
    });
  });

  group('F5: resolve-window desync + swallowed intents (C1a/C1b)', () {
    test('progress keeps showing the sounding song while the next resolves',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _DelayedResolvers(holdIds: {'2'});
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B')],
      );
      await c.playIndex(0);
      // Mid-song: 90 s into a 180 s track.
      c.position.value = const Duration(seconds: 90);
      c.duration.value = const Duration(seconds: 180);

      final loadB = c.playIndex(1);
      await _pump();
      expect(c.isResolving.value, isTrue);

      // Still resolving: the old song is what is sounding, so its
      // progress stays on screen (not zeroed).
      expect(c.position.value, const Duration(seconds: 90));
      expect(c.duration.value, const Duration(seconds: 180));

      resolvers.release('2');
      await loadB;
      await _pump();

      // Once the new song opens, progress resets for it.
      expect(c.position.value, Duration.zero);
    });

    test('seek during resolve applies to the new song, not the old one',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _DelayedResolvers(holdIds: {'2'});
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B')],
      );
      await c.playIndex(0);
      c.position.value = const Duration(seconds: 90);

      final loadB = c.playIndex(1);
      await _pump();
      expect(c.isResolving.value, isTrue);

      await c.seek(const Duration(seconds: 60));
      // Optimistic UI: the bar jumps at once; the old player is
      // untouched (the seek belongs to the song still loading).
      expect(c.position.value, const Duration(seconds: 60));
      expect(playerA.seekCalls, isEmpty);

      resolvers.release('2');
      await loadB;
      await _pump();

      expect(playerA.seekCalls, [const Duration(seconds: 60)]);
    });

    test('pause during resolve sticks after the new song lands', () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _DelayedResolvers(holdIds: {'2'});
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B')],
      );
      await c.playIndex(0);
      c.isPlaying.value = true;

      final loadB = c.playIndex(1);
      await _pump();
      expect(c.isResolving.value, isTrue);

      // Pause while the new song is still resolving.
      await c.togglePlayPause();
      final pausesDuringResolve = playerA.pauseCalls;

      resolvers.release('2');
      await loadB;
      await _pump();

      // The landed song is paused too — one more pause than the
      // pre-open stop of the old song alone.
      expect(playerA.pauseCalls, greaterThan(pausesDuringResolve + 1));
    });

    test('seek outside resolve updates position immediately', () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _InstantResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B')],
      );
      await c.playIndex(0);
      c.position.value = const Duration(seconds: 90);

      await c.seek(const Duration(seconds: 60));

      // No jump-back to the pre-drag position while the native
      // position stream catches up.
      expect(c.position.value, const Duration(seconds: 60));
      expect(playerA.seekCalls, [const Duration(seconds: 60)]);
    });
  });

  group('F6: next/prev symmetry + single-song loop (C1e/A2d)', () {
    test('prev stops at the first song in sequential/single modes', () {
      expect(prevTrackIndex(PlayMode.sequential, 0, 5), -1);
      expect(prevTrackIndex(PlayMode.single, 0, 5), -1);
      expect(prevTrackIndex(PlayMode.listLoop, 0, 5), 4);
      expect(prevTrackIndex(PlayMode.singleLoop, 0, 5), 4);
      expect(prevTrackIndex(PlayMode.sequential, 2, 5), 1);
    });

    test('prev on the first song does not wrap to the last', () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _InstantResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B'), _song('3', 'C')],
      );
      await c.playIndex(0);
      c.position.value = Duration.zero;

      await c.prev();

      expect(c.currentIndex.value, 0);
    });

    test('list-loop with one song replays it instead of stopping',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _InstantResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A')],
      );
      c.playMode.value = 'loop';
      await c.playIndex(0);
      expect(playerA.openedUrls, [_url('1')]);

      // Auto-advance at the end of a one-song loop queue replays it
      // (driven here via next() — the completion event itself routes
      // through the same _peekNextIndex; firing it directly needs
      // onInit for the sleep timer, which this test does not run).
      await c.next(auto: true);
      await _pump();

      expect(c.currentIndex.value, 0);
      expect(playerA.openedUrls.length + playerB.openedUrls.length, 2);
    });
  });

  group('F7: alt-platform song enters Recent (C2a)', () {
    test('a song rescued from another platform shows in Recent', () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final api = _FakeApi();
      final alt = _song('b-alt', 'A');
      api.altToReturn = alt;
      final resolvers = _NullResolvers(nullIds: {'1'});
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        api: api,
        songs: [_song('1', 'A')],
      );

      await c.playIndex(0);
      await _pump();

      // The alt song replaced the queue slot and is sounding.
      expect(c.queue[0].songId, 'b-alt');
      expect(playerA.openedUrls, contains(_url('b-alt')));
      // …and it is in Recent, like any other played song.
      expect(
        MusicStore.getRecent().map((s) => s.identityKey),
        contains(alt.identityKey),
      );
    });
  });

  group('F9: local/downloaded badge shows the file tier (B2)', () {
    test('downloaded song badge follows the file, not the user tier',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final downloads = _FakeDownloads();
      final song = _song('d1', 'D');
      downloads.paths[song.identityKey] = '/tmp/fake.flac';
      downloads.tiers[song.identityKey] = AudioQuality.hires;
      final resolvers = _InstantResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        downloads: downloads,
        songs: [song],
      );
      // The user asked for Master, but the file is Hi-Res.
      c.userQuality.value = AudioQuality.master;

      await c.playIndex(0);

      expect(c.actualQuality.value, AudioQuality.hires);
    });

    test('setQuality on a local file does not relabel its badge', () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final downloads = _FakeDownloads();
      final song = _song('d1', 'D');
      downloads.paths[song.identityKey] = '/tmp/fake.flac';
      downloads.tiers[song.identityKey] = AudioQuality.hires;
      final resolvers = _InstantResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        downloads: downloads,
        songs: [song],
      );
      await c.playIndex(0);
      expect(c.actualQuality.value, AudioQuality.hires);

      await c.setQuality(AudioQuality.master);

      // Preference moves (next online song asks Master); the file's
      // badge stays Hi-Res.
      expect(c.userQuality.value, AudioQuality.master);
      expect(c.actualQuality.value, AudioQuality.hires);
    });
  });

  group('F11: badge residue during resolve (C1f)', () {
    test('badge shows the requested tier while resolving, not the old song',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _DelayedResolvers(holdIds: {'2'});
      // Wire instant answers for the first song through the delayed
      // resolver's non-held path; B resolves at flac, A at master.
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [_song('1', 'A'), _song('2', 'B')],
      );
      await c.playIndex(0);
      // A resolved at the requested tier (hires default); force the
      // residue scenario by pretending A was Master.
      c.actualQuality.value = AudioQuality.master;

      final loadB = c.playIndex(1);
      await _pump();
      expect(c.isResolving.value, isTrue);

      // Resolving B: the badge must not still read A's Master.
      expect(c.actualQuality.value, c.userQuality.value);

      resolvers.release('2');
      await loadB;
      await _pump();
      expect(c.actualQuality.value, AudioQuality.hires);
    });
  });

  group('F12: trial duration arriving during the open (B1c)', () {
    test('trial clip found during the open await is retried, not played out',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _InstantResolvers();
      // First resolve serves the trial URL; a re-resolve serves the
      // full track from another source.
      resolvers.urlFor = (id, callNo) =>
          callNo == 1 ? _url(id) : _url('$id-full');
      final song = _song('t1', 'Trial', dur: 200);
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [song],
      );
      // The real 15 s duration arrives while the open is in flight.
      playerA.onFirstOpen = () =>
          c.onRealDuration(const Duration(seconds: 15));

      await c.playIndex(0);
      await _pump(300);

      expect(resolvers.resolveCounts['t1'], 2);
      expect(playerA.openedUrls, [_url('t1'), _url('t1-full')]);
    });

    test('duration event from the old song during resolve is dropped',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final resolvers = _DelayedResolvers(holdIds: {'t1'});
      final song = _song('t1', 'Trial', dur: 200);
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
        songs: [song],
      );

      final load = c.playIndex(0);
      await _pump();
      expect(c.isResolving.value, isTrue);
      // Belongs to the previous song's item, still loading when the
      // user switched: never a trial for this song.
      c.onRealDuration(const Duration(seconds: 15));

      resolvers.release('t1');
      await load;
      await _pump(300);

      expect(resolvers.resolvedIds.where((id) => id == 't1').length, 1);
      expect(playerA.openedUrls, [_url('t1')]);
    });
  });

  group('F13: resume seek must not override a manual seek (C1c)', () {
    test('manual seek wins over the kill-saved resume position', () {
      // The user dragged within the first seconds: no jump back.
      expect(
        MusicPlayerController.shouldApplyResumeSeek(
          userSeekedSinceOpen: true,
          position: const Duration(seconds: 3),
          total: const Duration(seconds: 200),
          seekSec: 120,
          fromBookmark: false,
        ),
        isFalse,
      );
      // No manual seek: the resume applies as before.
      expect(
        MusicPlayerController.shouldApplyResumeSeek(
          userSeekedSinceOpen: false,
          position: Duration.zero,
          total: const Duration(seconds: 200),
          seekSec: 120,
          fromBookmark: false,
        ),
        isTrue,
      );
      // Already past the first seconds: no resume jump either.
      expect(
        MusicPlayerController.shouldApplyResumeSeek(
          userSeekedSinceOpen: false,
          position: const Duration(seconds: 10),
          total: const Duration(seconds: 200),
          seekSec: 120,
          fromBookmark: false,
        ),
        isFalse,
      );
    });
  });

  group('F14: kuwo lyrics sorted by time (C1d)', () {
    test('lrclist lines come back in time order', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.contains('songinfoandlrc')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'data': {
                      'lrclist': [
                        {'time': 30.0, 'lineLyric': 'third'},
                        {'time': 10.0, 'lineLyric': 'first'},
                        {'time': 20.0, 'lineLyric': 'second'},
                      ],
                    },
                  },
                ),
              );
            } else {
              handler.next(options);
            }
          },
        ),
      );
      final api = MusicApi(dio: dio);
      final lines = await api.lyrics(
        Song(
          songId: 'kw1',
          title: 'K',
          artist: 'S',
          platform: MusicPlatform.kw,
          dur: 200,
        ),
      );

      expect(lines.map((l) => l.t).toList(), [10.0, 20.0, 30.0]);
      expect(lines.map((l) => l.text).toList(),
          ['first', 'second', 'third']);
    });
  });
}
