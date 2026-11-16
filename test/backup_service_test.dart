// Backup service tests (step 7): export is a stable whole-box dump,
// import validates before writing anything, and a round-trip restores
// every entry.

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

    test('round-trip restores all entries', () {
      box.put('videoPlayerKey', 'ijk');
      box.put('skippedVersion', '1.0.3');
      final service = BackupService(box: box);
      final json = service.exportJson();
      box.put('videoPlayerKey', 'mpv');
      box.delete('skippedVersion');
      final (result, count) = service.importJson(json);
      expect(result, BackupImportResult.ok);
      expect(count, 2);
      expect(box.get('videoPlayerKey'), 'ijk');
      expect(box.get('skippedVersion'), '1.0.3');
    });

    test('invalid JSON writes nothing', () {
      box.put('videoPlayerKey', 'mpv');
      final service = BackupService(box: box);
      final (result, count) = service.importJson('not json{');
      expect(result, BackupImportResult.invalidJson);
      expect(count, 0);
      expect(box.get('videoPlayerKey'), 'mpv');
    });

    test('wrong schema writes nothing', () {
      box.put('videoPlayerKey', 'mpv');
      final service = BackupService(box: box);
      final (result, count) = service.importJson(
        '{"schema":99,"data":{"videoPlayerKey":"ijk"}}',
      );
      expect(result, BackupImportResult.wrongSchema);
      expect(count, 0);
      expect(box.get('videoPlayerKey'), 'mpv');
    });

    test('empty data writes nothing', () {
      final service = BackupService(box: box);
      final (result, count) = service.importJson(
        '{"schema":1,"data":{}}',
      );
      expect(result, BackupImportResult.emptyData);
      expect(count, 0);
    });

    test('top-level array JSON writes nothing', () {
      box.put('videoPlayerKey', 'mpv');
      final service = BackupService(box: box);
      final (result, count) = service.importJson(
        '[{"schema":1,"data":{}}]',
      );
      expect(result, BackupImportResult.invalidJson);
      expect(count, 0);
      expect(box.get('videoPlayerKey'), 'mpv');
    });

    test('non-integer schema writes nothing', () {
      box.put('videoPlayerKey', 'mpv');
      final service = BackupService(box: box);
      final (result, count) = service.importJson(
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
      final (result, count) = service.importJson(json);
      expect(result, BackupImportResult.ok);
      expect(count, 3);
      final lists = box.get('hao_lists') as List;
      expect(lists.length, 1);
      expect((lists.first as Map)['name'], '我的歌单');
      expect(box.get('hao_fav'), ['wy|123', 'kg|789']);
      expect(box.get('musicVolume'), 0.8);
    });
  });
}
