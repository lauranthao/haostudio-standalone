// Play-open serialisation (v1.1.3: stale error-stream race, P1-3 class).
//
// The race: _loadCurrent bumps _playGen on every tap, and every await
// after the resolve checks it — EXCEPT the error stream. _onStreamError
// called _onPlayError with no gen (gen -1 = unchecked), and its only
// guard was the idle-state check. That check has a hole: while a NEWER
// load is still RESOLVING, the active player is still the OLD one —
// idle after its failure — so a stale error from the old song passed
// the check and failed the NEW song (alt-swap / give-up on a song that
// never failed, wrong notice, _loadFailed set so the new song never
// counted as loaded).
//
// The fix stamps the error with the gen of the load whose audio is in
// the active player (_activeGen, set on every _openOn and on the
// crossfade swap): a stale error's gen no longer matches _playGen and
// _onPlayError drops it; a genuine error of the current load still
// matches and runs the normal failure path.
//
// Harness: fake players through the constructor seam (same pattern as
// music_crossfade_lost_error_test.dart), scripted resolvers that can
// park a resolve mid-flight, and a controllable error stream per
// player (the base stream is just_audio's — no way to inject an error
// into it — so the fake overrides `stream` with a subclass that
// replays the real position/duration/playing/completed streams and
// exposes a broadcast error stream).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:just_audio/just_audio.dart' show AudioPlayer, ProcessingState;
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/av_music_player.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

Song _song(String id, String title) =>
    Song(songId: id, title: title, artist: 'Singer $id', dur: 260);

String _url(String id) => 'https://example.com/$id.mp3';

/// Controllable error stream: the real just_audio streams for
/// position/duration/playing/completed (never emit in tests), plus a
/// broadcast error stream the test drives.
class _ControllableStreams extends AvMusicPlayerStreams {
  _ControllableStreams() : super(AudioPlayer());

  final _errorController = StreamController<String>.broadcast();

  @override
  Stream<String> get error => _errorController.stream;

  void emitError(String message) => _errorController.add(message);
}

class _FakePlayer extends AvMusicPlayer {
  _FakePlayer();

  final List<String> openedUrls = [];
  final _streams = _ControllableStreams();

  /// True once the native side has gone idle after a load failure
  /// (the error event itself is still in the async pipe — the test
  /// delivers it later via [emitError]).
  var forceIdle = false;

  _ControllableStreams get streams => _streams;

  @override
  AvMusicPlayerStreams get stream => _streams;

  @override
  Future<bool> open(String url, {bool play = true}) async {
    openedUrls.add(url);
    return true;
  }

  @override
  ProcessingState get processingState =>
      forceIdle ? ProcessingState.idle : ProcessingState.ready;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> dispose() async {}
}

class _FakeApi extends MusicApi {
  @override
  Future<Song?> findAltPlatform(
    String title,
    String artist,
    MusicPlatform excludePf,
    String album, {
    Duration timeout = const Duration(seconds: 5),
  }) async => null;

  @override
  Future<List<LyricLine>> lyrics(Song song) async => [];
}

/// Resolvers driven by a per-test script: the function receives the
/// song id and returns the result — or a parked Completer, so a
/// resolve can be held mid-flight while the test taps the next song.
class _ScriptedResolvers extends MusicResolvers {
  _ScriptedResolvers(this.script);

  final FutureOr<PlayUrlResult?> Function(String songId) script;
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
    return await script(songId);
  }
}

PlayUrlResult _result(String songId) => PlayUrlResult(
  url: _url(songId),
  candidates: [_url(songId)],
  quality: AudioQuality.hires,
  via: 'test',
);

void main() {
  late Box<dynamic> box;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Hive.init('test/.hive-play-open-serial-test');
    box = await Hive.openBox<dynamic>('play_open_serial_test');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('play_open_serial_test');
  });

  group('stale error-stream race (P1-3)', () {
    test('stale error during the next load resolve is dropped', () async {
      // C's resolve parks mid-flight; A and B resolve instantly.
      final cCompleter = Completer<PlayUrlResult?>();
      final resolvers = _ScriptedResolvers((songId) {
        if (songId == 'c-id') return cCompleter.future;
        return _result(songId);
      });
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final c = MusicPlayerController(
        api: _FakeApi(),
        resolvers: resolvers,
        playerA: playerA,
        playerB: playerB,
      );
      final songs = [_song('a-id', 'A歌'), _song('b-id', 'B歌'), _song('c-id', 'C歌')];
      c.queue.addAll(songs);

      await c.playQueue(songs, 0);
      expect(playerA.openedUrls, [_url('a-id')]);
      await c.next(auto: true);
      expect(c.currentIndex.value, 1);
      expect(playerB.openedUrls, [_url('b-id')]);

      // B failed natively: the player went idle, its error event is
      // still in the async pipe. The user taps C before it lands.
      playerB.forceIdle = true;
      final loadC = c.playIndex(2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.isResolving.value, isTrue, reason: 'C resolve parked');
      expect(resolvers.resolvedIds, contains('c-id'));

      // The stale B error lands while C is still resolving.
      playerB.streams.emitError('native load failed');
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Let C's resolve land.
      cCompleter.complete(_result('c-id'));
      await loadC;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // C loaded normally: the stale error did not fail it, did not
      // alt-swap it, did not leave a failure notice on it.
      expect(c.currentIndex.value, 2);
      expect(playerB.openedUrls, [_url('b-id'), _url('c-id')]);
      expect(c.loadError.value, isNull);
      expect(c.lastNotice.value, isEmpty);
      expect(c.isResolving.value, isFalse);
    });

    test('genuine error of the current load still runs the failure path',
        () async {
      final resolvers = _ScriptedResolvers(
        (songId) => _result(songId),
      );
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final c = MusicPlayerController(
        api: _FakeApi(),
        resolvers: resolvers,
        playerA: playerA,
        playerB: playerB,
      );
      final songs = [_song('a-id', 'A歌'), _song('b-id', 'B歌'), _song('c-id', 'C歌')];
      c.queue.addAll(songs);

      await c.playQueue(songs, 0);
      await c.next(auto: true);
      expect(c.currentIndex.value, 1);

      // B genuinely fails while it is the current load: no newer
      // load exists, so the error's gen matches and the auto
      // failure path must advance to C with a notice naming B.
      playerB.forceIdle = true;
      playerB.streams.emitError('native load failed');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(c.currentIndex.value, 2);
      expect(playerA.openedUrls, contains(_url('c-id')));
      expect(c.lastNotice.value, contains('B歌'));
      expect(c.lastNotice.value, contains('已跳到下一首'));
    });
  });

  group('rapid consecutive taps', () {
    test('two fast playIndex calls: only the last one opens', () async {
      final aCompleter = Completer<PlayUrlResult?>();
      final bCompleter = Completer<PlayUrlResult?>();
      final resolvers = _ScriptedResolvers((songId) {
        if (songId == 'a-id') return aCompleter.future;
        return bCompleter.future;
      });
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final c = MusicPlayerController(
        api: _FakeApi(),
        resolvers: resolvers,
        playerA: playerA,
        playerB: playerB,
      );
      final songs = [_song('a-id', 'A歌'), _song('b-id', 'B歌')];
      c.queue.addAll(songs);

      // Two taps in quick succession, neither awaited: both loads
      // run concurrently, both resolves park.
      final loadA = c.playIndex(0);
      final loadB = c.playIndex(1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(resolvers.resolvedIds, containsAll(['a-id', 'b-id']));

      // The OLD load's resolve lands first: it must not open.
      aCompleter.complete(_result('a-id'));
      await loadA;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(playerA.openedUrls, isEmpty);

      // The NEW load's resolve lands: it opens.
      bCompleter.complete(_result('b-id'));
      await loadB;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(playerA.openedUrls, [_url('b-id')]);
      expect(c.currentIndex.value, 1);
      expect(c.loadError.value, isNull);
      expect(c.lastNotice.value, isEmpty);
    });
  });
}
