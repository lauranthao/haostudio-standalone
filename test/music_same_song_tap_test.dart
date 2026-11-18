// Tapping the song that is already playing must not restart it.
//
// Regression (chen 2026-11-17, v1.0.8 phone): tap a song, it plays;
// tap the same song again and it replays from the beginning. The
// expected behaviour is: tapping the currently playing song only
// opens the player, it does not reload the track.
//
// Root cause: playQueue / playIndex unconditionally replace the
// queue and call _loadCurrent, which resets position to zero and
// re-opens the URL. There was no same-song guard anywhere on the
// tap path (playNext already has one — identityKey comparison —
// but playQueue / playIndex never got it).
//
// The controller is constructed directly (no Get.put, so onInit
// never runs and no native players exist), exactly like
// music_queue_test.dart. The guard path must not touch the player
// at all, so the positive tests run without native audio.
//
// The negative tests ("different song", "not loaded") prove the
// guard does NOT over-trigger: the reload path is taken. To keep
// them fast and deterministic they seed songs B and C as
// downloaded (real empty files + the Hive downloads index), so
// _loadCurrent takes the local-file branch and throws immediately
// on the uninitialised player instead of doing real network
// resolve. The throw is the observable proof the reload was
// attempted.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/music_downloads.dart';
import 'package:standalone/services/music/music_models.dart';

Song _song(String id, String title) =>
    Song(songId: id, title: title, artist: 'Singer $id');

List<Song> _makeList() => [
      _song('1', 'A'),
      _song('2', 'B'),
      _song('3', 'C'),
      _song('4', 'D'),
    ];

void main() {
  late Box<dynamic> box;
  late MusicPlayerController c;
  late Directory tmpDir;

  setUp(() async {
    Hive.init('test/.hive-same-song-test');
    box = await Hive.openBox<dynamic>('same_song_test');
    await box.clear();
    HiveStore.setTestBox(box);
    // Seed B and C as downloaded so the reload path takes the
    // local-file branch (fast throw, no network). Written before
    // the controller is built so the downloads service reads it
    // fresh on its first localPathFor call.
    tmpDir = await Directory.systemTemp.createTemp('same_song_test');
    final bFile = File('${tmpDir.path}/B.mp3')..writeAsStringSync('');
    final cFile = File('${tmpDir.path}/C.mp3')..writeAsStringSync('');
    await HiveStore.put(
      HiveKeys.musicDownloads,
      jsonEncode([
        DownloadedSong(
          song: _song('2', 'B'),
          filePath: bFile.path,
          sizeBytes: 0,
          downloadedAt: 0,
        ).toJson(),
        DownloadedSong(
          song: _song('3', 'C'),
          filePath: cFile.path,
          sizeBytes: 0,
          downloadedAt: 0,
        ).toJson(),
      ]),
    );
    c = MusicPlayerController();
    c.queue.clear();
    c.queue.addAll(_makeList());
    c.currentIndex.value = 1; // B is the current song
    c.isPlaying.value = true;
    c.position.value = const Duration(seconds: 90); // 1:30 into B
    c.duration.value = const Duration(seconds: 200);
    // The loaded identity is the fourth piece of the simulated
    // "B is loaded and playing" state (the controller records it
    // when a real load opens; this harness loads nothing, so the
    // seam sets it directly).
    c.loadedIdentityKeyForTest = _song('2', 'B').identityKey;
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('same_song_test');
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  group('tapping the currently playing song', () {
    test('playQueue with the same song does not restart it', () async {
      await c.playQueue(_makeList(), 1); // tap B again, same list
      expect(c.position.value, const Duration(seconds: 90));
      expect(c.currentIndex.value, 1);
      expect(c.queue.map((s) => s.title).toList(), ['A', 'B', 'C', 'D']);
    });

    test('playQueue with the same song from another list keeps playing',
        () async {
      final other = [_song('9', 'X'), _song('2', 'B'), _song('8', 'Y')];
      await c.playQueue(other, 1); // tap B in a different list
      expect(c.position.value, const Duration(seconds: 90));
      // The queue switches to the tapped list, index follows B.
      expect(c.queue.map((s) => s.title).toList(), ['X', 'B', 'Y']);
      expect(c.currentIndex.value, 1);
    });

    test('playIndex on the current song does not restart it', () async {
      await c.playIndex(1); // tap B in the play queue panel
      expect(c.position.value, const Duration(seconds: 90));
      expect(c.currentIndex.value, 1);
    });

    test('tapping a different song still goes through the load path',
        () async {
      // A different song must NOT take the guard path: it falls
      // through to _loadCurrent, which in this harness (no native
      // players) throws on the uninitialised player. That throw is
      // the observable proof the reload was attempted.
      var threw = false;
      try {
        await c.playQueue(_makeList(), 2); // tap C, a different song
      } catch (_) {
        threw = true;
      }
      expect(threw, isTrue);
      expect(c.currentIndex.value, 2);
    });
  });

  group('paused mid-song', () {
    test('tapping the paused current song does not restart it', () async {
      c.isPlaying.value = false; // paused at 1:30
      await c.playQueue(_makeList(), 1);
      expect(c.position.value, const Duration(seconds: 90));
      expect(c.currentIndex.value, 1);
    });
  });

  group('not loaded', () {
    test('a failed / never-loaded current song still reloads', () async {
      // Same song, but nothing is loaded: not playing and position
      // is zero (e.g. the resolve failed). Tapping it must retry the
      // load instead of silently doing nothing.
      c.isPlaying.value = false;
      c.position.value = Duration.zero;
      var threw = false;
      try {
        await c.playQueue(_makeList(), 1);
      } catch (_) {
        threw = true;
      }
      expect(threw, isTrue); // reload attempted
      expect(c.currentIndex.value, 1);
    });
  });
}
