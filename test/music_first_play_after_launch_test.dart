// First play after launch (chen 2026-11-20 13:15): 刚进 app 点播放歌曲
// 不播放，要切到下一首歌才播放.
//
// Fresh-launch state: the queue + current index are restored from
// Hive (onInit), but NO audio is loaded yet (_loadedIdentityKey is
// '', both AVPlayers are fresh, isPlaying is false). Tapping a song
// must resolve it and open it on the active player — the tap must
// not be swallowed by the same-song shortcut (which only fires for
// a song whose audio is actually in the player) and must not end
// in a no-op play() on a sourceless player.
//
// Harness: fake players through the constructor seam (same pattern
// as music_play_open_serial_test.dart) + scripted resolvers + a
// fake API (no network, no lyrics). The fake records open() and
// play() calls, so the test observes exactly what the controller
// asked the player to do. (isPlaying is stream-driven via _attach,
// which only runs in onInit, so this harness asserts the recorded
// calls instead of the Rx flag.)

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

/// Streams the controller subscribes to: the real just_audio
/// position/duration/completed streams (never emit in tests) plus a
/// controllable playing stream the fake drives.
class _ControllableStreams extends AvMusicPlayerStreams {
  _ControllableStreams() : super(AudioPlayer());

  final _playingController = StreamController<bool>.broadcast();

  @override
  Stream<bool> get playing => _playingController.stream;

  void emitPlaying(bool value) => _playingController.add(value);
}

class _FakePlayer extends AvMusicPlayer {
  _FakePlayer();

  final List<String> openedUrls = [];
  final List<String> playedUrls = [];
  final _streams = _ControllableStreams();
  var _playing = false;

  _ControllableStreams get streams => _streams;

  @override
  AvMusicPlayerStreams get stream => _streams;

  @override
  Future<bool> open(String url, {bool play = true}) async {
    openedUrls.add(url);
    if (play) await this.play();
    return true;
  }

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Future<void> play() async {
    // Mirror AvMusicPlayer.play(): a sourceless play is a no-op.
    if (openedUrls.isEmpty) return;
    playedUrls.add(openedUrls.last);
    if (!_playing) {
      _playing = true;
      _streams.emitPlaying(true);
    }
  }

  @override
  Future<void> pause() async {
    if (_playing) {
      _playing = false;
      _streams.emitPlaying(false);
    }
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

class _FakeApi extends MusicApi {
  @override
  Future<Song?> findAltPlatform(
    String title,
    String artist,
    MusicPlatform excludePf,
    String album,
  ) async => null;

  @override
  Future<List<LyricLine>> lyrics(Song song) async => [];
}

class _ScriptedResolvers extends MusicResolvers {
  _ScriptedResolvers([this._script]);

  final FutureOr<PlayUrlResult?> Function(String songId)? _script;
  final List<String> resolvedIds = [];

  @override
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
  }) async {
    resolvedIds.add(songId);
    final script = _script;
    if (script != null) return await script(songId);
    return PlayUrlResult(
      url: _url(songId),
      candidates: [_url(songId)],
      quality: AudioQuality.hires,
      via: 'test',
    );
  }
}

void main() {
  late Box<dynamic> box;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Hive.init('test/.hive-first-play-test');
    box = await Hive.openBox<dynamic>('first_play_test');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('first_play_test');
  });

  group('first play after launch', () {
    test('tapping the restored current song opens and plays it', () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final c = MusicPlayerController(
        api: _FakeApi(),
        resolvers: _ScriptedResolvers(),
        playerA: playerA,
        playerB: playerB,
      );
      final songs = [_song('a-id', 'A歌'), _song('b-id', 'B歌'), _song('c-id', 'C歌')];
      // Fresh-launch state as onInit restores it: queue + index from
      // Hive, nothing loaded, not playing, position zero.
      c.queue.addAll(songs);
      c.currentIndex.value = 0;
      c.isPlaying.value = false;
      c.position.value = Duration.zero;

      await c.playQueue(songs, 0); // tap A, the restored current song
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(c.currentIndex.value, 0);
      expect(c.loadError.value, isNull);
      expect(playerA.openedUrls, [_url('a-id')],
          reason: 'first tap must open the song on the active player');
      expect(playerA.playedUrls, [_url('a-id')],
          reason: 'first tap must start playback, not a no-op play');
    });

    test('tapping a different song than the restored current plays it',
        () async {
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final c = MusicPlayerController(
        api: _FakeApi(),
        resolvers: _ScriptedResolvers(),
        playerA: playerA,
        playerB: playerB,
      );
      final songs = [_song('a-id', 'A歌'), _song('b-id', 'B歌'), _song('c-id', 'C歌')];
      c.queue.addAll(songs);
      c.currentIndex.value = 0; // restored current is A
      c.isPlaying.value = false;
      c.position.value = Duration.zero;

      await c.playQueue(songs, 1); // tap B
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(c.currentIndex.value, 1);
      expect(c.loadError.value, isNull);
      expect(playerA.openedUrls, [_url('b-id')]);
      expect(playerA.playedUrls, [_url('b-id')]);
    });

    test('play button with no loaded song loads the current song',
        () async {
      // The mini-player / player-sheet play button calls
      // togglePlayPause(). On a fresh launch nothing is loaded, so
      // a bare play() on the active player is a no-op — the button
      // must load the restored current song instead of doing nothing.
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final c = MusicPlayerController(
        api: _FakeApi(),
        resolvers: _ScriptedResolvers(),
        playerA: playerA,
        playerB: playerB,
      );
      final songs = [_song('a-id', 'A歌'), _song('b-id', 'B歌'), _song('c-id', 'C歌')];
      c.queue.addAll(songs);
      c.currentIndex.value = 0;
      c.isPlaying.value = false;
      c.position.value = Duration.zero;

      await c.togglePlayPause();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(playerA.openedUrls, [_url('a-id')],
          reason: 'play with nothing loaded must load the current song');
      expect(playerA.playedUrls, [_url('a-id')]);
    });

    test('play on a loaded-but-paused song resumes without reloading',
        () async {
      // Guard against over-triggering: a paused mid-song track must
      // resume on the player that already holds it, not re-resolve
      // and restart from the beginning.
      final playerA = _FakePlayer();
      final playerB = _FakePlayer();
      final c = MusicPlayerController(
        api: _FakeApi(),
        resolvers: _ScriptedResolvers(),
        playerA: playerA,
        playerB: playerB,
      );
      final songs = [_song('a-id', 'A歌'), _song('b-id', 'B歌'), _song('c-id', 'C歌')];
      // Simulate "A was loaded earlier": the player holds its audio,
      // the controller recorded it, playback is paused at 1:30.
      await playerA.open(_url('a-id'), play: false);
      c.queue.addAll(songs);
      c.currentIndex.value = 0;
      c.loadedIdentityKeyForTest = _song('a-id', 'A歌').identityKey;
      c.isPlaying.value = false;
      c.position.value = const Duration(seconds: 90);
      c.duration.value = const Duration(seconds: 200);
      final opensBefore = playerA.openedUrls.length;
      final playsBefore = playerA.playedUrls.length;

      await c.togglePlayPause();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(playerA.openedUrls.length, opensBefore,
          reason: 'resume must not re-open the song');
      expect(playerA.playedUrls.length, playsBefore + 1,
          reason: 'resume must play the loaded track');
      expect(c.position.value, const Duration(seconds: 90),
          reason: 'resume must not restart from the beginning');
    });

    test('play during an in-flight load does not start a second load',
        () async {
      // Impatient tap while the first song is still resolving: the
      // in-flight load will play when it lands, so the button must
      // not bump the gen and re-resolve the same song.
      final aCompleter = Completer<PlayUrlResult?>();
      final resolvers = _ScriptedResolvers((songId) {
        if (songId == 'a-id') return aCompleter.future;
        return PlayUrlResult(
          url: _url(songId),
          candidates: [_url(songId)],
          quality: AudioQuality.hires,
          via: 'test',
        );
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
      c.currentIndex.value = 0;
      c.isPlaying.value = false;
      c.position.value = Duration.zero;

      final load = c.playQueue(songs, 0); // resolve parks mid-flight
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.isResolving.value, isTrue);
      final resolvesBefore = resolvers.resolvedIds.length;

      await c.togglePlayPause();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(resolvers.resolvedIds.length, resolvesBefore,
          reason: 'no second resolve while one is in flight');

      aCompleter.complete(PlayUrlResult(
        url: _url('a-id'),
        candidates: [_url('a-id')],
        quality: AudioQuality.hires,
        via: 'test',
      ));
      await load;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(playerA.openedUrls, [_url('a-id')]);
      expect(playerA.playedUrls, [_url('a-id')]);
    });
  });
}
