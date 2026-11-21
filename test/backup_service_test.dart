// Backup service tests (step 7): export is a stable whole-box dump,
// import validates before writing anything, and a round-trip restores
// every entry.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/services/backup_service.dart';

void main() {
  late Box<dynamic> box;

  setUp(() async {
    Hive.init('test/.hive-backup-test');
    box = await Hive.openBox<dynamic>('backup_test');
    await box.clear();
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('backup_test');
  });

  group('BackupService', () {
    test('export includes every key, sorted', () {
      box.put('videoPlayerKey', 'mpv');
      box.put('preferResolution', '原画');
      box.put('liveCrashStage', 'live-playing');
      final service = BackupService(box: box);
      final json = service.exportJson(now: DateTime.utc(2026, 11, 16));
      expect(json.contains('"schema":1'), isTrue);
      expect(json.contains('"version":"1.0.4"'), isTrue);
      expect(json.contains('"entries":3'), isTrue);
      expect(
        json.indexOf('liveCrashStage') < json.indexOf('preferResolution'),
        isTrue,
      );
      expect(
        json.indexOf('preferResolution') < json.indexOf('videoPlayerKey'),
        isTrue,
      );
    });

    test('round-trip restores all entries', () async {
      box.put('videoPlayerKey', 'ijk');
      box.put('skippedVersion', '1.0.3');
      final service = BackupService(box: box);
      final json = service.exportJson();
      box.put('videoPlayerKey', 'mpv');
      box.delete('skippedVersion');
      final (result, count) = await service.importJson(json);
      expect(result, BackupImportResult.ok);
      expect(count, 2);
      expect(box.get('videoPlayerKey'), 'ijk');
      expect(box.get('skippedVersion'), '1.0.3');
    });

    test('invalid JSON writes nothing', () async {
      box.put('videoPlayerKey', 'mpv');
      final service = BackupService(box: box);
      final (result, count) = await service.importJson('not json{');
      expect(result, BackupImportResult.invalidJson);
      expect(count, 0);
      expect(box.get('videoPlayerKey'), 'mpv');
    });

    test('wrong schema writes nothing', () async {
      box.put('videoPlayerKey', 'mpv');
      final service = BackupService(box: box);
      final (result, count) = await service.importJson(
        '{"schema":99,"data":{"videoPlayerKey":"ijk"}}',
      );
      expect(result, BackupImportResult.wrongSchema);
      expect(count, 0);
      expect(box.get('videoPlayerKey'), 'mpv');
    });

    test('empty data writes nothing', () async {
      final service = BackupService(box: box);
      final (result, count) = await service.importJson(
        '{"schema":1,"data":{}}',
      );
      expect(result, BackupImportResult.emptyData);
      expect(count, 0);
    });

    test('top-level array JSON writes nothing', () async {
      box.put('videoPlayerKey', 'mpv');
      final service = BackupService(box: box);
      final (result, count) = await service.importJson(
        '[{"schema":1,"data":{}}]',
      );
      expect(result, BackupImportResult.invalidJson);
      expect(count, 0);
      expect(box.get('videoPlayerKey'), 'mpv');
    });

    test('non-integer schema writes nothing', () async {
      box.put('videoPlayerKey', 'mpv');
      final service = BackupService(box: box);
      final (result, count) = await service.importJson(
        '{"schema":"1","data":{"videoPlayerKey":"ijk"}}',
      );
      expect(result, BackupImportResult.wrongSchema);
      expect(count, 0);
      expect(box.get('videoPlayerKey'), 'mpv');
    });

    test('round-trip preserves nested playlist-like data', () async {
      box.put('hao_lists', [
        {
          'id': 'l1',
          'name': '我的歌单',
          'songs': [
            {'platform': 'wy', 'songId': '123'},
            {'platform': 'tx', 'songId': '456'},
          ],
        },
      ]);
      box.put('hao_fav', ['wy|123', 'kg|789']);
      box.put('musicVolume', 0.8);
      final service = BackupService(box: box);
      final json = service.exportJson();
      await box.clear();
      final (result, count) = await service.importJson(json);
      expect(result, BackupImportResult.ok);
      expect(count, 3);
      final lists = box.get('hao_lists') as List;
      expect(lists.length, 1);
      expect((lists.first as Map)['name'], '我的歌单');
      expect(box.get('hao_fav'), ['wy|123', 'kg|789']);
      expect(box.get('musicVolume'), 0.8);
    });

    test('write failure mid-import rolls back to the snapshot (P1-L4)',
        () async {
      box.put('a', 'old-a');
      box.put('b', 'old-b');
      const json = '{"schema":1,"data":{"a":"new-a","c":"new-c"}}';
      // The 2nd put throws (disk error): the 1st write already
      // landed, so without a rollback the box would be half-imported.
      final service = BackupService(box: _FailingBox(box, 2));
      final (result, count) = await service.importJson(json);
      expect(result, BackupImportResult.writeFailed);
      expect(count, 0);
      expect(box.get('a'), 'old-a');
      expect(box.get('b'), 'old-b');
      expect(box.containsKey('c'), isFalse);
    });

    group('zip export/import (P1-L3)', () {
      late Directory docs;

      setUp(() async {
        docs = await Directory.systemTemp.createTemp('hao-backup-test-');
      });

      tearDown(() async {
        if (await docs.exists()) await docs.delete(recursive: true);
      });

      Future<void> seedFiles() async {
        final dl = Directory('${docs.path}/music_downloads');
        await dl.create(recursive: true);
        await File('${dl.path}/song.mp3').writeAsBytes([1, 2, 3, 4]);
        final wp = Directory('${docs.path}/wallpapers');
        await wp.create(recursive: true);
        await File(
          '${wp.path}/bg.jpg',
        ).writeAsBytes([9, 8, 7]);
        final nested = Directory('${docs.path}/local_music/sub');
        await nested.create(recursive: true);
        await File('${nested.path}/track.flac').writeAsBytes([5, 5, 5]);
      }

      test('zip round-trip restores entries AND files', () async {
        box.put('videoPlayerKey', 'ijk');
        box.put('music_downloads_index', ['music_downloads/song.mp3']);
        await seedFiles();
        final service = BackupService(box: box);
        final zip = await service.exportZip(documentsDir: docs);
        // Wipe everything: box + files.
        await box.clear();
        await docs.delete(recursive: true);
        await docs.create();
        final (result, entries, files) = await service.importZip(
          zip,
          documentsDir: docs,
        );
        expect(result, BackupImportResult.ok);
        expect(entries, 2);
        expect(files, 3);
        expect(box.get('videoPlayerKey'), 'ijk');
        expect(
          await File(
            '${docs.path}/music_downloads/song.mp3',
          ).readAsBytes(),
          [1, 2, 3, 4],
        );
        expect(
          await File('${docs.path}/wallpapers/bg.jpg').readAsBytes(),
          [9, 8, 7],
        );
        expect(
          await File(
            '${docs.path}/local_music/sub/track.flac',
          ).readAsBytes(),
          [5, 5, 5],
        );
      });

      test('zip without files still imports the JSON', () async {
        box.put('videoPlayerKey', 'ijk');
        final service = BackupService(box: box);
        final zip = await service.exportZip(documentsDir: docs);
        await box.clear();
        final (result, entries, files) = await service.importZip(
          zip,
          documentsDir: docs,
        );
        expect(result, BackupImportResult.ok);
        expect(entries, 1);
        expect(files, 0);
        expect(box.get('videoPlayerKey'), 'ijk');
      });

      test('garbage bytes are invalid, zip without backup.json too',
          () async {
        final service = BackupService(box: box);
        final (r1, _, _) = await service.importZip(
          [0, 1, 2, 3],
          documentsDir: docs,
        );
        expect(r1, BackupImportResult.invalidJson);
        final archive = Archive();
        archive.addFile(ArchiveFile('other.txt', 3, [1, 2, 3]));
        final zip = ZipEncoder().encode(archive);
        final (r2, _, _) = await service.importZip(
          zip,
          documentsDir: docs,
        );
        expect(r2, BackupImportResult.invalidJson);
        expect(box.isEmpty, isTrue);
      });

      test('zip-slip entries are never written', () async {
        box.put('videoPlayerKey', 'ijk');
        final service = BackupService(box: box);
        final zip = await service.exportZip(documentsDir: docs);
        // Rebuild the zip with a hostile entry added.
        final archive = ZipDecoder().decodeBytes(zip);
        archive.addFile(
          ArchiveFile('../evil.txt', 4, [1, 2, 3, 4]),
        );
        archive.addFile(
          ArchiveFile('/abs.txt', 4, [1, 2, 3, 4]),
        );
        final hostile = ZipEncoder().encode(archive);
        await box.clear();
        final (result, _, files) = await service.importZip(
          hostile,
          documentsDir: docs,
        );
        expect(result, BackupImportResult.ok);
        expect(files, 0);
        expect(await File('${docs.path}/evil.txt').exists(), isFalse);
        expect(box.get('videoPlayerKey'), 'ijk');
      });

      test('large package: 50 downloaded songs round-trip (G-P1-5)',
          () async {
        box.put('videoPlayerKey', 'ijk');
        final dl = Directory('${docs.path}/music_downloads');
        await dl.create(recursive: true);
        // 50 songs x 256 KiB of patterned bytes (~12.5 MiB): enough
        // deflate work that the old main-thread encode was visibly
        // slow. The encode/decode now run in a worker isolate, so
        // the wall clock below is off-thread time, not UI jank.
        final pattern = List<int>.generate(256 * 1024, (i) => (i * 7) % 251);
        for (var i = 0; i < 50; i++) {
          await File('${dl.path}/song_$i.mp3').writeAsBytes(pattern);
        }
        final service = BackupService(box: box);
        final stopwatch = Stopwatch()..start();
        final zip = await service.exportZip(documentsDir: docs);
        final exportMs = stopwatch.elapsedMilliseconds;
        stopwatch.reset();
        await box.clear();
        await docs.delete(recursive: true);
        await docs.create();
        final (result, entries, files) = await service.importZip(
          zip,
          documentsDir: docs,
        );
        final importMs = stopwatch.elapsedMilliseconds;
        expect(result, BackupImportResult.ok);
        expect(entries, 1);
        expect(files, 50);
        expect(
          await File(
            '${docs.path}/music_downloads/song_49.mp3',
          ).readAsBytes(),
          pattern,
        );
        // Timing is informational (isolate wall clock, not a jank
        // proof): the assertion is the round-trip, not the clock.
        // ignore: avoid_print
        print(
          'G-P1-5 large package: export ${exportMs}ms, import '
          '${importMs}ms, zip ${zip.length} bytes',
        );
      });
    });
  });
}

/// A box that throws on the Nth put (simulates a disk error
/// mid-import). Everything the service touches forwards to the real
/// box; anything else falls through to Fake's noSuchMethod.
class _FailingBox extends Fake implements Box<dynamic> {
  _FailingBox(this._inner, this.failOnPut);

  final Box<dynamic> _inner;
  final int failOnPut;
  var _puts = 0;

  @override
  Iterable<dynamic> get keys => _inner.keys;

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _inner.get(key, defaultValue: defaultValue);

  @override
  Future<void> put(dynamic key, dynamic value) async {
    if (++_puts == failOnPut) throw StateError('disk full (test)');
    await _inner.put(key, value);
  }

  @override
  Future<void> delete(dynamic key) => _inner.delete(key);
}
