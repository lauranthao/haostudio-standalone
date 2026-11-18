// Stage 2 item 4 — local audio import (LocalMusicStore).
//
// Import copies the picked file into an app-documents directory and
// indexes it in Hive; the list survives restarts (same box re-read);
// missing files are pruned; remove deletes file + index entry.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/storage/local_paths.dart';
import 'package:standalone/services/music/local_music_store.dart';

void main() {
  late Box<dynamic> box;
  late Directory dir;
  late Directory srcDir;
  late LocalMusicStore store;

  setUp(() async {
    Hive.init('test/.hive-stage2-local');
    box = await Hive.openBox<dynamic>('stage2_local_test');
    await box.clear();
    HiveStore.setTestBox(box);
    dir = await Directory.systemTemp.createTemp('hao_local_');
    srcDir = await Directory.systemTemp.createTemp('hao_local_src_');
    store = LocalMusicStore(directory: dir);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('stage2_local_test');
    if (await dir.exists()) await dir.delete(recursive: true);
    if (await srcDir.exists()) await srcDir.delete(recursive: true);
  });

  Future<File> srcFile(String name, String bytes) async {
    final f = File('${srcDir.path}/$name');
    await f.writeAsString(bytes);
    return f;
  }

  test('import copies the file, indexes it, and the entry plays local', () async {
    final src = await srcFile('周杰伦 - 晴天.mp3', 'fake-audio-bytes');
    final song = await store.importFile(src);
    expect(song, isNotNull);
    expect(song!.title, '晴天');
    expect(song.artist, '周杰伦');
    expect(song.isLocal, isTrue);
    expect(song.songId.startsWith('local:'), isTrue);
    // The copy lives in the app directory, not the picked location;
    // the index stores only the relative name (`local_music/<file>`)
    // — an absolute path would die with the old container UUID on
    // reinstall (1.1.0 -> 1.1.1 data loss, chen 2026-11-18).
    expect(song.localPath.startsWith('local_music/'), isTrue);
    expect(song.localPath.contains('/var/'), isFalse);
    final resolvedPath = LocalPaths.resolveSync(
      song.localPath,
      'local_music',
      directoryOverride: dir,
    );
    expect(resolvedPath, isNotNull);
    expect(await File(resolvedPath!).exists(), isTrue);
    // The original can disappear afterwards — the copy still plays.
    await src.delete();
    final listed = await store.list();
    expect(listed.length, 1);
    expect(listed.first.identityKey, song.identityKey);
  });

  test('filename without " - " keeps the whole name as title', () async {
    final song = await store.importFile(
      await srcFile('untitled.flac', 'x'),
    );
    expect(song!.title, 'untitled');
    expect(song.artist, isEmpty);
  });

  test('non-audio files are refused', () async {
    expect(await store.importFile(await srcFile('note.txt', 'x')), isNull);
    expect(await store.importFile(await srcFile('pic.jpg', 'x')), isNull);
    expect(await store.list(), isEmpty);
  });

  test('importing the same file twice returns the existing entry', () async {
    final src = await srcFile('song.mp3', 'same-bytes');
    final first = await store.importFile(src);
    final second = await store.importFile(src);
    expect(second!.identityKey, first!.identityKey);
    expect((await store.list()).length, 1);
    expect(await dir.list().length, 1);
  });

  test('list prunes entries whose file was deleted outside the app', () async {
    final song = await store.importFile(await srcFile('gone.mp3', 'x'));
    expect(song, isNotNull);
    final resolvedPath = LocalPaths.resolveSync(
      song!.localPath,
      'local_music',
      directoryOverride: dir,
    );
    expect(resolvedPath, isNotNull);
    await File(resolvedPath!).delete();
    expect(await store.list(), isEmpty);
    // The pruned index is written back — a fresh read stays empty.
    expect(await store.list(), isEmpty);
  });

  test('remove deletes the file and the index entry', () async {
    final song = await store.importFile(await srcFile('del.mp3', 'x'));
    expect(song, isNotNull);
    expect(await store.remove(song!), isTrue);
    expect(
      LocalPaths.resolveSync(
        song.localPath,
        'local_music',
        directoryOverride: dir,
      ),
      isNull,
    );
    expect(await store.list(), isEmpty);
    expect(await store.remove(song), isFalse);
  });

  test('songForFile parses "Artist - Title" and plain names', () {
    final a = LocalMusicStore.songForFile('/d/1_周杰伦 - 晴天.mp3');
    expect(a.title, '晴天');
    expect(a.artist, '周杰伦');
    final b = LocalMusicStore.songForFile('/d/2_plain.wav');
    expect(b.title, 'plain');
    expect(b.artist, isEmpty);
    expect(b.isLocal, isTrue);
  });
}
