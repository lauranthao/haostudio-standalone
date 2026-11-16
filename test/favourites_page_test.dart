// Favourites page storage (M-P0-7) — Hive-backed through an injected
// test box (no HiveStore.init, no platform channels).
//
// Covers: toggle stores the full Song JSON, getFavSongs lists songs
// newest-first, unfavourite removes, legacy key-only entries still
// count as favourites and resolve from recent history, unresolvable
// legacy keys are dropped (no fake data), duplicate keys dedupe.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

Song _song(String id, String title, {MusicPlatform pf = MusicPlatform.wy}) =>
    Song(songId: id, title: title, artist: 'Singer $id', platform: pf);

void main() {
  late Box<dynamic> box;

  setUp(() async {
    Hive.init('test/.hive-fav-test');
    box = await Hive.openBox<dynamic>('fav_test');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('fav_test');
  });

  group('toggleFav / getFavSongs', () {
    test('favouriting stores the full song; page lists it', () async {
      final song = _song('1', 'A');
      expect(await MusicStore.toggleFav(song), isTrue);
      expect(MusicStore.getFavIds(), {'wy|1'});
      final songs = MusicStore.getFavSongs();
      expect(songs.length, 1);
      expect(songs.first.title, 'A');
      expect(songs.first.artist, 'Singer 1');
      expect(songs.first.platform, MusicPlatform.wy);
    });

    test('toggling again removes the song', () async {
      final song = _song('1', 'A');
      await MusicStore.toggleFav(song);
      expect(await MusicStore.toggleFav(song), isFalse);
      expect(MusicStore.getFavIds(), isEmpty);
      expect(MusicStore.getFavSongs(), isEmpty);
    });

    test('newest favourite first', () async {
      await MusicStore.toggleFav(_song('1', 'A'));
      await MusicStore.toggleFav(_song('2', 'B'));
      await MusicStore.toggleFav(_song('3', 'C'));
      expect(
        MusicStore.getFavSongs().map((s) => s.title).toList(),
        ['C', 'B', 'A'],
      );
    });

    test('re-favouriting after removal goes to the front', () async {
      await MusicStore.toggleFav(_song('1', 'A'));
      await MusicStore.toggleFav(_song('2', 'B'));
      await MusicStore.toggleFav(_song('1', 'A')); // remove
      await MusicStore.toggleFav(_song('1', 'A')); // add again
      expect(
        MusicStore.getFavSongs().map((s) => s.title).toList(),
        ['A', 'B'],
      );
    });

    test('different platforms are different favourites', () async {
      await MusicStore.toggleFav(_song('1', 'A', pf: MusicPlatform.wy));
      await MusicStore.toggleFav(_song('1', 'A', pf: MusicPlatform.tx));
      expect(MusicStore.getFavIds().length, 2);
      expect(MusicStore.getFavSongs().length, 2);
    });
  });

  group('legacy key-only entries', () {
    test('legacy key still counts as favourite', () async {
      await box.put(HiveKeys.musicFav, jsonEncode([{'key': 'wy|9'}]));
      expect(MusicStore.getFavIds(), {'wy|9'});
    });

    test('legacy key resolves from recent history', () async {
      await MusicStore.addRecent(_song('9', 'Legacy Song'));
      await box.put(HiveKeys.musicFav, jsonEncode([{'key': 'wy|9'}]));
      final songs = MusicStore.getFavSongs();
      expect(songs.length, 1);
      expect(songs.first.title, 'Legacy Song');
    });

    test('legacy key with no history is dropped, not faked', () async {
      await box.put(HiveKeys.musicFav, jsonEncode([{'key': 'wy|404'}]));
      expect(MusicStore.getFavSongs(), isEmpty);
      // ...but the id itself is still remembered as favourited.
      expect(MusicStore.getFavIds(), {'wy|404'});
    });

    test('mixed stored + legacy entries keep stored order', () async {
      final stored = _song('1', 'Stored');
      await MusicStore.toggleFav(stored);
      await MusicStore.addRecent(_song('2', 'From Recent'));
      final raw = jsonDecode(box.get(HiveKeys.musicFav) as String) as List;
      raw.add({'key': 'wy|2'});
      await box.put(HiveKeys.musicFav, jsonEncode(raw));
      expect(
        MusicStore.getFavSongs().map((s) => s.title).toList(),
        ['Stored', 'From Recent'],
      );
    });

    test('duplicate keys dedupe to one song', () async {
      await box.put(
        HiveKeys.musicFav,
        jsonEncode([
          {'key': 'wy|1', 'song': _song('1', 'A').toJson()},
          {'key': 'wy|1', 'song': _song('1', 'A').toJson()},
        ]),
      );
      expect(MusicStore.getFavSongs().length, 1);
      expect(MusicStore.getFavIds().length, 1);
    });
  });
}
