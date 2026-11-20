// Lyrics cache (P1-P7).
//
// MusicApi.lyrics caches parsed lines in memory + Hive, keyed by
// identityKey. A second call for the same song must return the cached
// lines without touching the network — verified here by seeding the
// Hive cache (no HTTP is stubbed, so any real fetch would fail).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-lyrics-cache-');
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
      'test_lyrics_cache',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    await HiveStore.box.clear();
  });

  test('lyrics() returns Hive-cached lines without fetching', () async {
    final song = Song(songId: 's1', title: 'Cached Song', artist: 'A');
    final seeded = [
      LyricLine(t: 1.0, text: 'first line'),
      LyricLine(t: 5.5, text: 'second line', translation: '第二行'),
    ];
    await MusicStore.putLyrics(song.identityKey, seeded);

    // Fresh API instance: the Hive cache (not instance state) serves it.
    final lines = await MusicApi().lyrics(song);
    expect(lines.length, 2);
    expect(lines[0].text, 'first line');
    expect(lines[1].translation, '第二行');
    // Second call hits the memory cache.
    final again = await MusicApi().lyrics(song);
    expect(again.length, 2);
  });

  test('empty lyrics are not cached', () async {
    final song = Song(songId: 's2', title: 'No Lyrics', artist: 'A');
    await MusicStore.putLyrics(song.identityKey, []);
    expect(MusicStore.getLyrics(song.identityKey), isNull);
  });

  test('LyricLine round-trips through JSON', () {
    final line = LyricLine(t: 12.34, text: 'hi', translation: '你好');
    final back = LyricLine.fromJson(line.toJson());
    expect(back.t, 12.34);
    expect(back.text, 'hi');
    expect(back.translation, '你好');
    expect(LyricLine.fromJson(LyricLine(t: 0, text: 'x').toJson())
        .translation, isNull);
  });
}
