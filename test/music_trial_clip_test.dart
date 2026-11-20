// NetEase trial/preview clip: a VIP song whose resolver returned a
// ~15 s preview instead of the full song must switch sources, not
// play 15 s and "complete" into the next track.
//
// Regression (chen 2026-11-17, v1.0.8 phone): 网易云很多歌只能放十五秒.
// The preview URL looks exactly like a full-song URL and plays
// without error, so the old code had no signal at all — the track
// ended after 15 s and auto-advanced as if the song were over.
//
// The fix: when the player's real duration is first known, compare
// it with the metadata duration (Song.dur, seconds). A 15 s file
// for a 4-minute song is a preview → drop the cached URL and fall
// back exactly like a play error (alt platform first, else next
// song). See isTrialClip for the false-positive guards.
//
// The controller is constructed directly (no Get.put, so onInit
// never runs and no native players exist), exactly like
// music_same_song_tap_test.dart. The trial chain ends in _openOn,
// which throws LateInitializationError on the uninitialised player
// in this harness — that throw is the observable proof the fallback
// open was attempted, and it is captured by the zone helper below
// (an unawaited future's error would otherwise fail the test).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_downloads.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

Song _wy(String id, String title, {int dur = 256}) => Song(
      songId: id,
      title: title,
      artist: '陈奕迅',
      platform: MusicPlatform.wy,
      dur: dur,
    );

Song _tx(String id, String title, {int dur = 256}) => Song(
      songId: id,
      title: title,
      artist: '陈奕迅',
      platform: MusicPlatform.tx,
      dur: dur,
    );

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
}

class _FakeResolvers extends MusicResolvers {
  final List<String> evicted = [];
  PlayUrlResult? altResult;

  @override
  void evictPlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
  ) {
    evicted.add('$songId|${platform.code}|${quality.code}');
  }

  @override
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
    String artist = '',
  }) async {
    return altResult;
  }
}

/// Runs [body] in a zone that captures unhandled async errors instead
/// of failing the test on them. The trial chain ends in _openOn,
/// which throws LateInitializationError in this harness (no native
/// players) — the captured error is the proof the open was attempted.
Future<List<Object>> _runCatchingAsyncErrors(
  Future<void> Function() body,
) async {
  final errors = <Object>[];
  await runZonedGuarded(() async {
    await body();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }, (e, _) => errors.add(e));
  return errors;
}

void main() {
  group('isTrialClip', () {
    test('15 s file for a 4-minute song is a trial', () {
      expect(
        isTrialClip(metaDurSec: 256, actual: const Duration(seconds: 15)),
        isTrue,
      );
    });

    test('30 s file for a 4-minute song is a trial', () {
      expect(
        isTrialClip(metaDurSec: 256, actual: const Duration(seconds: 30)),
        isTrue,
      );
    });

    test('full-length file is not a trial', () {
      expect(
        isTrialClip(metaDurSec: 256, actual: const Duration(seconds: 256)),
        isFalse,
      );
    });

    test('unknown metadata duration never trips', () {
      expect(
        isTrialClip(metaDurSec: 0, actual: const Duration(seconds: 15)),
        isFalse,
      );
    });

    test('genuinely short song never trips', () {
      expect(
        isTrialClip(metaDurSec: 20, actual: const Duration(seconds: 15)),
        isFalse,
      );
    });

    test('file over 35 s is not a trial even when short of metadata', () {
      expect(
        isTrialClip(metaDurSec: 240, actual: const Duration(seconds: 60)),
        isFalse,
      );
    });

    test('different-version file (over half the metadata) never trips',
        () {
      expect(
        isTrialClip(metaDurSec: 240, actual: const Duration(seconds: 130)),
        isFalse,
      );
    });

    test('zero actual duration never trips', () {
      expect(
        isTrialClip(metaDurSec: 256, actual: Duration.zero),
        isFalse,
      );
    });
  });

  group('trial clip at playback', () {
    late Box<dynamic> box;
    late _FakeApi api;
    late _FakeResolvers resolvers;
    late MusicPlayerController c;
    late Directory tmpDir;

    final trial = _wy('1901371647', '孤勇者');
    final alt = _tx('qq-123', '孤勇者');

    setUp(() async {
      Hive.init('test/.hive-trial-clip-test');
      box = await Hive.openBox<dynamic>('trial_clip_test');
      await box.clear();
      HiveStore.setTestBox(box);
      tmpDir = await Directory.systemTemp.createTemp('trial_clip_test');
      api = _FakeApi();
      resolvers = _FakeResolvers();
      c = MusicPlayerController(api: api, resolvers: resolvers);
      c.queue.clear();
      c.queue.addAll([trial, _wy('449818741', '光年之外', dur: 236)]);
      c.currentIndex.value = 0;
      c.isPlaying.value = true;
    });

    tearDown(() async {
      await box.close();
      await Hive.deleteBoxFromDisk('trial_clip_test');
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    test('trial clip switches to the alt-platform version', () async {
      api.alt = alt;
      resolvers.altResult = PlayUrlResult(
        url: 'https://example.com/alt.mp3',
        candidates: ['https://example.com/alt.mp3'],
        quality: AudioQuality.hires,
        via: 'test',
      );
      final errors = await _runCatchingAsyncErrors(() async {
        c.onRealDuration(const Duration(seconds: 15));
        // Synchronous effects, before any await in the chain:
        expect(resolvers.evicted, ['1901371647|wy|hires']);
        expect(api.altLookups, ['孤勇者']);
      });
      // The alt replaced the trial in the queue, and the open was
      // attempted (LateInitializationError = no native player here).
      expect(c.queue.first.songId, 'qq-123');
      expect(c.queue.first.platform, MusicPlatform.tx);
      expect(errors, hasLength(1));
      // LateError is not nameable as a type in this Dart version;
      // compare the runtime type name instead.
      expect(errors.first.runtimeType.toString(), 'LateError');
    });

    test('trial clip with no alt advances to the next song', () async {
      api.alt = null;
      resolvers.altResult = null;
      final errors = await _runCatchingAsyncErrors(() async {
        c.onRealDuration(const Duration(seconds: 15));
        expect(resolvers.evicted, ['1901371647|wy|hires']);
      });
      expect(c.currentIndex.value, 1);
      expect(c.queue[1].title, '光年之外');
      expect(errors, isEmpty);
    });

    test('full-length track does not trigger the trial path', () async {
      c.onRealDuration(const Duration(seconds: 256));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(resolvers.evicted, isEmpty);
      expect(api.altLookups, isEmpty);
      expect(c.currentIndex.value, 0);
    });

    test('genuinely short song does not trigger the trial path', () async {
      c.queue[0] = _wy('999', '短歌', dur: 20);
      c.onRealDuration(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(resolvers.evicted, isEmpty);
      expect(api.altLookups, isEmpty);
    });

    test('unknown metadata duration does not trigger the trial path',
        () async {
      c.queue[0] = _wy('999', '未知时长', dur: 0);
      c.onRealDuration(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(resolvers.evicted, isEmpty);
      expect(api.altLookups, isEmpty);
    });

    test('downloaded track is never treated as a trial', () async {
      final file = File('${tmpDir.path}/trial.mp3')..writeAsStringSync('');
      await HiveStore.put(
        HiveKeys.musicDownloads,
        jsonEncode([
          DownloadedSong(
            song: trial,
            filePath: file.path,
            sizeBytes: 0,
            downloadedAt: 0,
          ).toJson(),
        ]),
      );
      c.onRealDuration(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(resolvers.evicted, isEmpty);
      expect(api.altLookups, isEmpty);
    });

    test('alt lookup finishing after a skip does not replace the new song',
        () async {
      api.altCompleter = Completer<Song?>();
      resolvers.altResult = PlayUrlResult(
        url: 'https://example.com/alt.mp3',
        candidates: ['https://example.com/alt.mp3'],
        quality: AudioQuality.hires,
        via: 'test',
      );
      c.onRealDuration(const Duration(seconds: 15));
      expect(api.altLookups, ['孤勇者']);
      // Skip to the next song while the alt lookup is still pending.
      // _loadCurrent throws on the uninitialised player (same
      // "throw is the proof" pattern as the same-song tests).
      var threw = false;
      try {
        await c.playQueue(
          [trial, _wy('449818741', '光年之外', dur: 236)],
          1,
        );
      } catch (_) {
        threw = true;
      }
      expect(threw, isTrue);
      expect(c.currentIndex.value, 1);
      // Now let the stale alt lookup finish: it must NOT replace
      // the song the user is on now.
      final errors = await _runCatchingAsyncErrors(() async {
        api.altCompleter!.complete(alt);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(c.queue[1].title, '光年之外');
      expect(c.queue[0].songId, '1901371647');
      expect(errors, isEmpty);
    });
  });
}
