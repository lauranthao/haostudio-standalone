// Playlist import cap tests (chen 2026-11-17: 导入歌单最多只能进 200 首).
//
// Root cause: `_importLink` (music_tab_page), `_addSongsTo`
// (album_detail_page) and `_importAll` (plaza_page) all had an inline
// `if (list.tracks.length >= 200) break` — an arbitrary cap from the
// original "max 10 lists, max 200 tracks each" comment, not a platform
// limit — and the success toast never mentioned the dropped songs.
// All three now share `MusicStore.addTracks` (cap 1000, honest counts).
//
// Fetch side, verified live 2026-11-17 (curl, real APIs):
// - wy: v6 detail returns ALL trackIds (836-song playlist -> 836 ids;
//   the `tracks` array only carries 10). Complete.
// - kw: paginates pn 0..9 x rn=100 -> up to 1000. Complete to the cap.
// - tx: single detail call, no pagination params exist — complete by
//   design (no live >200 playlist verified from the VM: no dissid).
// - wy fallback (old api/playlist/detail) truncates to ~10 for big
//   playlists (836 -> 10, no trackIds); importWyPlaylist now retries
//   v6 once when it answered but gave no ids, before falling back.
//
// Hive setup mirrors music_search_history_test.dart: temp dir + mocked
// path_provider + HiveStore.init + a MEMORY-backed test box.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

Song fakeSong(int i, {MusicPlatform platform = MusicPlatform.wy, String? id}) => Song(
  songId: id ?? 'id$i',
  title: '歌名$i',
  artist: '歌手${i % 10}',
  album: '专辑$i',
  cover: 'https://example.com/cover$i.jpg',
  platform: platform,
  dur: 200 + i,
);

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-playlist-import-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return hiveDir.path;
          }
          return null;
        });
    await HiveStore.init();
    final memBox = await Hive.openBox<dynamic>(
      'test_playlist_import',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    // Trap (2026-11-17): never `await` box.close() in tearDownAll —
    // a pending Hive write queue in the fake zone makes close() never
    // return and hangs the whole file. Fire-and-forget is enough here.
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    await MusicStore.saveLists([]);
  });

  group('MusicStore.addTracks', () {
    test('250 new songs all go in (the reported bug: old cap stopped at 200)', () {
      final list = UserPlaylist(id: 'l1', name: '我的歌单');
      final res = MusicStore.addTracks(
        list,
        List.generate(250, fakeSong),
      );
      expect(res.added, 250);
      expect(res.dropped, 0);
      expect(res.dupes, 0);
      expect(list.tracks.length, 250);
    });

    test('1000 boundary: 950 existing + 100 new -> 50 in, 50 dropped', () {
      final list = UserPlaylist(
        id: 'l1',
        name: '我的歌单',
        tracks: List.generate(950, fakeSong),
      );
      final res = MusicStore.addTracks(
        list,
        List.generate(100, (i) => fakeSong(1000 + i)),
      );
      expect(res.added, 50);
      expect(res.dropped, 50);
      expect(res.dupes, 0);
      expect(list.tracks.length, MusicStore.maxTracksPerList);
      expect(MusicStore.maxTracksPerList, 1000);
    });

    test('list already at cap: 10 new songs all dropped, none added', () {
      final list = UserPlaylist(
        id: 'l1',
        name: '我的歌单',
        tracks: List.generate(1000, fakeSong),
      );
      final res = MusicStore.addTracks(
        list,
        List.generate(10, (i) => fakeSong(2000 + i)),
      );
      expect(res.added, 0);
      expect(res.dropped, 10);
      expect(res.dupes, 0);
      expect(list.tracks.length, 1000);
    });

    test('dedup: existing song + repeats in the batch count as dupes', () {
      final list = UserPlaylist(
        id: 'l1',
        name: '我的歌单',
        tracks: [fakeSong(0)],
      );
      final res = MusicStore.addTracks(list, [
        fakeSong(0), // already in the list
        fakeSong(0), // repeat within the batch
        fakeSong(1), // new
        fakeSong(1), // repeat of the just-added song
      ]);
      expect(res.added, 1);
      expect(res.dupes, 3);
      expect(res.dropped, 0);
      expect(list.tracks.length, 2);
    });

    test('same title/artist, different songId (different version) is kept', () {
      final list = UserPlaylist(id: 'l1', name: '我的歌单');
      final a = fakeSong(0, id: 'wy_1');
      final b = Song(
        songId: 'wy_2',
        title: a.title,
        artist: a.artist,
        platform: MusicPlatform.wy,
        dur: 180,
      );
      final res = MusicStore.addTracks(list, [a, b]);
      expect(res.added, 2);
      expect(res.dupes, 0);
      expect(list.tracks.length, 2);
    });

    test('empty incoming is a no-op', () {
      final list = UserPlaylist(id: 'l1', name: '我的歌单');
      final res = MusicStore.addTracks(list, []);
      expect(res, (added: 0, dropped: 0, dupes: 0));
      expect(list.tracks, isEmpty);
    });
  });

  group('Hive round-trip at the new cap', () {
    test('1000-song playlist persists whole and in order', () async {
      final list = UserPlaylist(
        id: 'l1',
        name: '大歌单',
        tracks: List.generate(1000, fakeSong),
      );
      final sw = Stopwatch()..start();
      await MusicStore.saveLists([list]);
      final saveMs = sw.elapsedMilliseconds;
      sw.reset();
      final back = MusicStore.getLists();
      final loadMs = sw.elapsedMilliseconds;
      expect(back.length, 1);
      expect(back.first.tracks.length, 1000);
      expect(back.first.tracks.first.songId, 'id0');
      expect(back.first.tracks.last.songId, 'id999');
      // Size evidence for the 1000 cap: one full list must stay small.
      final bytes = utf8.encode(jsonEncode(list.toJson())).length;
      // ignore: avoid_print
      print('1000-song list JSON: $bytes bytes, save ${saveMs}ms, load ${loadMs}ms');
      expect(bytes, lessThan(1024 * 1024));
      expect(saveMs, lessThan(2000));
      expect(loadMs, lessThan(2000));
    });
  });
}
