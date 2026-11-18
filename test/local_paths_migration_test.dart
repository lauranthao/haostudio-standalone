// Regression tests for the 1.1.0 -> 1.1.1 data loss (chen 2026-11-18):
// upgrading without uninstalling changed the iOS container UUID, so
// every absolute path stored in Hive died — and the old list() /
// refresh() pruned the index itself on first launch. The index now
// stores relative names only (`<subdir>/<file>`); old absolute
// entries are repaired on read, and the directory is rescanned
// BEFORE anything is pruned, so a user whose index was already
// pruned by 1.1.1 gets the files back as long as they are still in
// the new container directory.
//
// Covered per store (local files, downloads, wallpaper, custom
// font): (a) old-container absolute path + file in the new container
// -> repaired and returned; (b) index pruned empty + file still on
// disk -> rescan re-adds it; (c) file gone everywhere -> empty, no
// error, no crash; (d) a newly imported entry stores a relative
// name and reads back after the Documents directory "moves".

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/storage/local_paths.dart';
import 'package:standalone/core/theme/appearance_store.dart';
import 'package:standalone/services/custom_font_service.dart';
import 'package:standalone/services/music/local_music_store.dart';
import 'package:standalone/services/music/music_downloads.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

void main() {
  late Box<dynamic> box;
  late Directory docsA; // old container (1.1.0)
  late Directory docsB; // new container (1.1.1)

  setUp(() async {
    Hive.init('test/.hive-local-paths-migration');
    box = await Hive.openBox<dynamic>('local_paths_migration_test');
    await box.clear();
    HiveStore.setTestBox(box);
    docsA = await Directory.systemTemp.createTemp('hao_docs_old_');
    docsB = await Directory.systemTemp.createTemp('hao_docs_new_');
  });

  tearDown(() async {
    LocalPaths.resetForTest();
    await box.close();
    await Hive.deleteBoxFromDisk('local_paths_migration_test');
    if (await docsA.exists()) await docsA.delete(recursive: true);
    if (await docsB.exists()) await docsB.delete(recursive: true);
  });

  Future<Directory> ensureSub(Directory docs, String sub) async {
    final d = Directory('${docs.path}/$sub');
    await d.create(recursive: true);
    return d;
  }

  Future<File> writeFile(Directory dir, String name, String bytes) async {
    final f = File('${dir.path}/$name');
    await f.writeAsString(bytes);
    return f;
  }

  Song localSong(String oldAbsPath) => Song(
    songId: 'local:123_周杰伦 - 晴天.mp3',
    title: '晴天',
    artist: '周杰伦',
    platform: MusicPlatform.wy,
    localPath: oldAbsPath,
  );

  group('local music', () {
    test('(a) old-container absolute path is repaired and returned', () async {
      final dirB = await ensureSub(docsB, 'local_music');
      await writeFile(dirB, '123_周杰伦 - 晴天.mp3', 'fake-audio');
      final oldPath =
          '${docsA.path}/local_music/123_周杰伦 - 晴天.mp3';
      await HiveStore.put(
        HiveKeys.musicLocalFiles,
        jsonEncode([localSong(oldPath).toJson()]),
      );
      final store = LocalMusicStore(directory: dirB);
      final listed = await store.list();
      expect(listed.length, 1);
      expect(listed.first.title, '晴天');
      // Repaired in place: the entry now stores the relative name.
      expect(listed.first.localPath, 'local_music/123_周杰伦 - 晴天.mp3');
      final stored =
          jsonDecode(HiveStore.getString(HiveKeys.musicLocalFiles, '[]'))
              as List;
      expect(stored.length, 1);
      expect(stored.first['localPath'], 'local_music/123_周杰伦 - 晴天.mp3');
    });

    test('(b) pruned index + file still on disk: rescan re-adds it', () async {
      final dirB = await ensureSub(docsB, 'local_music');
      await writeFile(dirB, '456_陈奕迅 - 孤勇者.mp3', 'fake-audio');
      // The index is empty — 1.1.1 already pruned it.
      final store = LocalMusicStore(directory: dirB);
      final listed = await store.list();
      expect(listed.length, 1);
      expect(listed.first.title, '孤勇者');
      expect(listed.first.artist, '陈奕迅');
      expect(listed.first.localPath, 'local_music/456_陈奕迅 - 孤勇者.mp3');
      // And the rebuilt entry is written back to the index.
      expect((await store.list()).length, 1);
    });

    test('(c) file gone everywhere: empty list, no error', () async {
      final dirB = await ensureSub(docsB, 'local_music');
      final song = Song(
        songId: 'local:999_xxx.mp3',
        title: 'X',
        platform: MusicPlatform.wy,
        localPath: '${docsA.path}/local_music/999_xxx.mp3',
      );
      await HiveStore.put(
        HiveKeys.musicLocalFiles,
        jsonEncode([song.toJson()]),
      );
      final store = LocalMusicStore(directory: dirB);
      expect(await store.list(), isEmpty);
    });

    test('(d) newly imported entry stores a relative name and reads '
        'after a move', () async {
      final dirA = await ensureSub(docsA, 'local_music');
      final srcDir = await Directory.systemTemp.createTemp('hao_local_src_');
      try {
        final src = File('${srcDir.path}/moved.mp3');
        await src.writeAsString('bytes');
        final storeA = LocalMusicStore(directory: dirA);
        final song = await storeA.importFile(src);
        expect(song, isNotNull);
        expect(song!.localPath.startsWith('local_music/'), isTrue);
        expect(song.localPath, isNot(contains('/var/')));
        // Simulate the reinstall: the file moves to the new container.
        final dirB = await ensureSub(docsB, 'local_music');
        final name = song.localPath.split('/').last;
        await File('${dirA.path}/$name').copy('${dirB.path}/$name');
        final storeB = LocalMusicStore(directory: dirB);
        final listed = await storeB.list();
        expect(listed.length, 1);
        expect(listed.first.identityKey, song.identityKey);
      } finally {
        if (await srcDir.exists()) await srcDir.delete(recursive: true);
      }
    });
  });

  group('downloads', () {
    Song dlSong() => Song(
      songId: '442867526',
      title: 'Die For You',
      artist: 'The Weeknd',
      platform: MusicPlatform.wy,
      dur: 260,
    );

    test('(a) old-container absolute filePath is repaired on refresh',
        () async {
      final dirB = await ensureSub(docsB, 'music_downloads');
      await writeFile(dirB, 'wy_442867526.mp3', 'fake-audio');
      final entry = DownloadedSong(
        song: dlSong(),
        filePath: '${docsA.path}/music_downloads/wy_442867526.mp3',
        sizeBytes: 10,
        downloadedAt: 1,
      );
      await HiveStore.put(
        HiveKeys.musicDownloads,
        jsonEncode([entry.toJson()]),
      );
      final svc = MusicDownloadService(dio: Dio(), directory: dirB);
      final entries = await svc.refresh();
      expect(entries.length, 1);
      expect(entries.first.filePath, 'music_downloads/wy_442867526.mp3');
      expect(svc.localPathFor(dlSong()), '${dirB.path}/wy_442867526.mp3');
    });

    test('(b) pruned index + file still on disk: rescan re-adds it',
        () async {
      final dirB = await ensureSub(docsB, 'music_downloads');
      await writeFile(dirB, 'wy_442867526.mp3', 'fake-audio');
      final svc = MusicDownloadService(dio: Dio(), directory: dirB);
      final entries = await svc.refresh();
      expect(entries.length, 1);
      expect(entries.first.song.identityKey, 'wy|442867526');
      expect(entries.first.filePath, 'music_downloads/wy_442867526.mp3');
      // Title falls back to the song id when the song is nowhere on
      // record (recent list / queue empty) — never invented.
      expect(entries.first.song.title, '442867526');
      expect(svc.localPathFor(entries.first.song), isNotNull);
    });

    test('(b2) rescan recovers the title from the recent list', () async {
      final dirB = await ensureSub(docsB, 'music_downloads');
      await writeFile(dirB, 'wy_442867526.mp3', 'fake-audio');
      await MusicStore.addRecent(dlSong());
      final svc = MusicDownloadService(dio: Dio(), directory: dirB);
      final entries = await svc.refresh();
      expect(entries.length, 1);
      expect(entries.first.song.title, 'Die For You');
      expect(entries.first.song.artist, 'The Weeknd');
    });

    test('(c) file gone everywhere: empty list, no error', () async {
      final dirB = await ensureSub(docsB, 'music_downloads');
      final entry = DownloadedSong(
        song: dlSong(),
        filePath: '${docsA.path}/music_downloads/wy_442867526.mp3',
        sizeBytes: 10,
        downloadedAt: 1,
      );
      await HiveStore.put(
        HiveKeys.musicDownloads,
        jsonEncode([entry.toJson()]),
      );
      final svc = MusicDownloadService(dio: Dio(), directory: dirB);
      expect(await svc.refresh(), isEmpty);
      expect(svc.localPathFor(dlSong()), isNull);
    });
  });

  group('wallpaper', () {
    test('(a) old-container absolute path is repaired and resolves',
        () async {
      final dirB = await ensureSub(docsB, 'wallpapers');
      await writeFile(dirB, '123_pic.jpg', 'fake-jpeg');
      await HiveStore.put(
        HiveKeys.wallpaperPaths,
        jsonEncode(['${docsA.path}/wallpapers/123_pic.jpg']),
      );
      final store = AppearanceStore(documentsDir: docsB);
      expect(store.wallpaperPaths, ['${dirB.path}/123_pic.jpg']);
      // The repair write is fire-and-forget from the getter; give
      // the Hive put a beat to land before asserting the stored form.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final stored =
          jsonDecode(HiveStore.getString(HiveKeys.wallpaperPaths, '[]'))
              as List;
      expect(stored, ['wallpapers/123_pic.jpg']);
    });

    test('(a2) current wallpaper repairs to the relative form', () async {
      final dirB = await ensureSub(docsB, 'wallpapers');
      await writeFile(dirB, '123_pic.jpg', 'fake-jpeg');
      await HiveStore.put(
        HiveKeys.wallpaperPaths,
        jsonEncode(['${docsA.path}/wallpapers/123_pic.jpg']),
      );
      await HiveStore.put(
        HiveKeys.wallpaperCurrent,
        '${docsA.path}/wallpapers/123_pic.jpg',
      );
      final store = AppearanceStore(documentsDir: docsB);
      expect(store.currentWallpaper, '${dirB.path}/123_pic.jpg');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        HiveStore.getString(HiveKeys.wallpaperCurrent, ''),
        'wallpapers/123_pic.jpg',
      );
    });

    test('(b) pruned list + image still on disk: rescan re-adds it',
        () async {
      final dirB = await ensureSub(docsB, 'wallpapers');
      await writeFile(dirB, 'orphan.png', 'fake-png');
      final store = AppearanceStore(documentsDir: docsB);
      expect(store.wallpaperPaths, ['${dirB.path}/orphan.png']);
    });

    test('(c) file gone everywhere: empty list, no error', () async {
      await ensureSub(docsB, 'wallpapers');
      await HiveStore.put(
        HiveKeys.wallpaperPaths,
        jsonEncode(['${docsA.path}/wallpapers/gone.jpg']),
      );
      await HiveStore.put(
        HiveKeys.wallpaperCurrent,
        '${docsA.path}/wallpapers/gone.jpg',
      );
      final store = AppearanceStore(documentsDir: docsB);
      expect(store.wallpaperPaths, isEmpty);
      expect(store.currentWallpaper, isEmpty);
      expect(store.hasActiveWallpaper, isFalse);
    });
  });

  group('custom font', () {
    test('(a) old-container absolute path loads from the new container',
        () async {
      final fontsB = await ensureSub(docsB, 'fonts');
      await writeFile(fontsB, 'MyFont.ttf', 'fake-font');
      await HiveStore.put(
        HiveKeys.customFontFamily,
        CustomFontService.family,
      );
      await HiveStore.put(HiveKeys.customFontName, 'MyFont.ttf');
      await HiveStore.put(
        HiveKeys.customFontPath,
        '${docsA.path}/fonts/MyFont.ttf',
      );
      final registered = <String>[];
      final service = CustomFontService(
        documentsDir: docsB,
        register: (family, _) async => registered.add(family),
      );
      expect(await service.loadPersisted(), isTrue);
      expect(registered, [CustomFontService.family]);
      expect(
        HiveStore.getString(HiveKeys.customFontPath, ''),
        'fonts/MyFont.ttf',
      );
    });

    test('(c) file gone everywhere: loadPersisted is false, no error',
        () async {
      await HiveStore.put(
        HiveKeys.customFontFamily,
        CustomFontService.family,
      );
      await HiveStore.put(HiveKeys.customFontName, 'Gone.ttf');
      await HiveStore.put(
        HiveKeys.customFontPath,
        '${docsA.path}/fonts/Gone.ttf',
      );
      final service = CustomFontService(documentsDir: docsB);
      expect(await service.loadPersisted(), isFalse);
    });
  });
}
