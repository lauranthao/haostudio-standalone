// Playback + search smoothness fixes (chen 2026-11-17: "歌曲播放和搜索
// 一定要好好检查，一定要流畅播放、流畅搜索").
//
// Covers the fixes from the smoothness audit:
//  1. findAltPlatform 5 s cap — a hanging platform leg must not hold
//     the error path hostage for the leg's 10 s timeout.
//  2. isResolving loading flag — true while a URL is being resolved,
//     false afterwards even if the open throws (try/finally).
//  3. setQuality (P1-4) — a failed resolve must NOT write the new
//     tier into the preference; success writes it.
//  4. AvMusicPlayer.processingState — the P1-3 guard's input: idle
//     with no source loaded (a fresh failure leaves the player idle;
//     a stale error arrives while the new source is loading/ready).
//
// The controller is constructed directly (no Get.put, no onInit), so
// there are no native players on Linux: any path that reaches
// _openOn throws LateInitializationError on the uninitialised
// _active player. Tests that go through _openOn catch that throw
// (same pattern as music_same_song_tap_test.dart) and assert on the
// state around it.
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
import 'package:standalone/services/music/music_store.dart';

Song _song(String id, String title) =>
    Song(songId: id, title: title, artist: 'Singer $id');

/// searchOne legs that never answer — without the 5 s cap,
/// findAltPlatform would hang on them forever.
class _HangingApi extends MusicApi {
  _HangingApi() : super(dio: Dio());

  @override
  Future<List<Song>> searchOne(MusicPlatform pf, String q, {CancelToken? cancelToken}) =>
      Completer<List<Song>>().future;
}

/// Resolver that never answers, so the test can observe isResolving
/// mid-flight and then release it.
class _DeferredResolvers extends MusicResolvers {
  _DeferredResolvers() : super(dio: Dio());

  final completer = Completer<PlayUrlResult?>();

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
  }) =>
      completer.future;
}

/// Resolver that always fails (P1-4 negative case).
class _NullResolvers extends MusicResolvers {
  _NullResolvers() : super(dio: Dio());

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
  }) async =>
      null;
}

/// Resolver that always succeeds (P1-4 positive case).
class _UrlResolvers extends MusicResolvers {
  _UrlResolvers() : super(dio: Dio());

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
  }) async =>
      PlayUrlResult(
        url: 'https://example.com/a.flac',
        candidates: const ['https://example.com/a.flac'],
        quality: quality,
        via: 'test',
      );
}

void main() {
  late Box<dynamic> box;

  setUp(() async {
    Hive.init('test/.hive-smooth-test');
    box = await Hive.openBox<dynamic>('smooth_test');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('smooth_test');
  });

  group('findAltPlatform timeout (fix 1)', () {
    test('hanging legs return null after the 5 s cap, not 10 s', () async {
      final api = _HangingApi();
      final sw = Stopwatch()..start();
      final alt = await api.findAltPlatform(
        'Some Song',
        'Singer',
        MusicPlatform.wy,
        '',
      );
      sw.stop();
      expect(alt, isNull);
      // The cap is 5 s; the legs' own timeout is 10 s. Generous upper
      // bound so a slow VM does not flake the test — the point is it
      // returns at all (without the cap it would hang forever on the
      // never-completing legs).
      expect(sw.elapsed.inSeconds, lessThan(9));
    });
  });

  group('isResolving loading flag (fix 2)', () {
    test('true during resolve, false after even when open throws',
        () async {
      final resolvers = _DeferredResolvers();
      final c = MusicPlayerController(resolvers: resolvers);
      c.queue.clear();
      c.queue.addAll([_song('1', 'A')]);
      c.currentIndex.value = 0;
      expect(c.isResolving.value, isFalse);

      final load = c.playIndex(0);
      // Let the load reach the pending resolve.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.isResolving.value, isTrue);

      resolvers.completer.complete(
        PlayUrlResult(
          url: 'https://example.com/a.flac',
          candidates: const ['https://example.com/a.flac'],
          quality: AudioQuality.hires,
          via: 'test',
        ),
      );
      // _openOn throws LateInitializationError (no native player on
      // Linux); the flag must still clear via try/finally.
      var threw = false;
      try {
        await load;
      } catch (_) {
        threw = true;
      }
      expect(threw, isTrue);
      expect(c.isResolving.value, isFalse);
    });
  });

  group('setQuality preference write (P1-4)', () {
    test('failed resolve does not change the quality preference',
        () async {
      final c = MusicPlayerController(resolvers: _NullResolvers());
      c.queue.clear();
      c.queue.addAll([_song('1', 'A')]);
      c.currentIndex.value = 0;
      expect(c.userQuality.value, AudioQuality.hires);
      expect(MusicStore.quality, AudioQuality.hires);

      final ok = await c.setQuality(AudioQuality.master);
      expect(ok, isFalse);
      // The UI must keep showing the tier that is actually playing.
      expect(c.userQuality.value, AudioQuality.hires);
      expect(MusicStore.quality, AudioQuality.hires);
    });

    test('successful resolve writes the new tier', () async {
      final c = MusicPlayerController(resolvers: _UrlResolvers());
      c.queue.clear();
      c.queue.addAll([_song('1', 'A')]);
      c.currentIndex.value = 0;

      // The open itself throws LateInitializationError (no native
      // player on Linux); the preference is written before the open,
      // so it must still be the new tier afterwards.
      try {
        await c.setQuality(AudioQuality.master);
      } catch (_) {}
      expect(c.userQuality.value, AudioQuality.master);
      expect(MusicStore.quality, AudioQuality.master);
    });
  });

  group('AvMusicPlayer.processingState (P1-3 guard input)', () {
    test('idle with no source loaded', () {
      // AudioPlayer() touches the method channel at construction.
      TestWidgetsFlutterBinding.ensureInitialized();
      final player = AvMusicPlayer();
      expect(player.processingState, ProcessingState.idle);
    });
  });
}
