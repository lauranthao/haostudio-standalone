// 1.1.6 书签 — BookmarksStore (Hive 表 hao_music_bookmarks).
//
// Covers: add / list (position order) / dedupe same second /
// per-song cap 10 (oldest-created dropped) / delete one keeps the
// others / clear / isolation between songs (identityKey) / label
// format / corrupt rows tolerated. The controller half (add at the
// current position, jump + load + seek) lives in
// v16_music_sleep_norm_bookmark_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/bookmarks_store.dart';

void main() {
  late Box<dynamic> box;

  setUp(() async {
    Hive.init('test/.hive-v16-bookmarks');
    box = await Hive.openBox<dynamic>('v16_bookmarks_test');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('v16_bookmarks_test');
  });

  group('formatLabel', () {
    test('m:ss, zero-padded seconds', () {
      expect(BookmarksStore.formatLabel(0), '0:00');
      expect(BookmarksStore.formatLabel(5), '0:05');
      expect(BookmarksStore.formatLabel(83), '1:23');
      expect(BookmarksStore.formatLabel(600), '10:00');
      expect(BookmarksStore.formatLabel(-3), '0:00');
    });
  });

  group('add / list', () {
    test('multiple bookmarks per song, listed earliest position first',
        () async {
      await BookmarksStore.add('wy|1', 200);
      await BookmarksStore.add('wy|1', 30);
      await BookmarksStore.add('wy|1', 90);
      final marks = BookmarksStore.forSong('wy|1');
      expect(marks.map((m) => m.position).toList(), [30, 90, 200]);
      expect(marks.map((m) => m.label).toList(), ['0:30', '1:30', '3:20']);
      expect(BookmarksStore.countFor('wy|1'), 3);
    });

    test('adding the same second twice does not duplicate', () async {
      final first = await BookmarksStore.add('wy|1', 90);
      final second = await BookmarksStore.add('wy|1', 90);
      expect(second, isNotNull);
      expect(second!.position, 90);
      expect(BookmarksStore.countFor('wy|1'), 1);
      expect(second.createdAt, first!.createdAt);
    });

    test('bad key / negative position return null and store nothing',
        () async {
      expect(await BookmarksStore.add('', 90), isNull);
      expect(await BookmarksStore.add('wy|1', -1), isNull);
      expect(BookmarksStore.countFor('wy|1'), 0);
      expect(BookmarksStore.forSong(''), isEmpty);
    });

    test('bookmarks survive a box reopen (persisted)', () async {
      await BookmarksStore.add('wy|1', 90);
      await box.close();
      box = await Hive.openBox<dynamic>('v16_bookmarks_test');
      HiveStore.setTestBox(box);
      expect(
        BookmarksStore.forSong('wy|1').map((m) => m.position).toList(),
        [90],
      );
    });
  });

  group('caps', () {
    test('per-song cap 10 drops the oldest-created bookmark', () async {
      for (var i = 0; i < 11; i++) {
        await BookmarksStore.add('wy|1', (i + 1) * 10);
      }
      final marks = BookmarksStore.forSong('wy|1');
      expect(marks.length, BookmarksStore.maxPerSong);
      // The first-created (10 s) is gone; the rest remain.
      expect(marks.map((m) => m.position).toList(),
          [20, 30, 40, 50, 60, 70, 80, 90, 100, 110]);
    });
  });

  group('delete', () {
    test('deleting one keeps the others', () async {
      await BookmarksStore.add('wy|1', 30);
      final mid = await BookmarksStore.add('wy|1', 90);
      await BookmarksStore.add('wy|1', 200);
      await BookmarksStore.remove('wy|1', mid!);
      expect(
        BookmarksStore.forSong('wy|1').map((m) => m.position).toList(),
        [30, 200],
      );
    });

    test('clear removes only that song', () async {
      await BookmarksStore.add('wy|1', 30);
      await BookmarksStore.add('wy|2', 40);
      await BookmarksStore.clear('wy|1');
      expect(BookmarksStore.forSong('wy|1'), isEmpty);
      expect(
        BookmarksStore.forSong('wy|2').map((m) => m.position).toList(),
        [40],
      );
    });
  });

  group('isolation', () {
    test('same title on another platform / version keeps its own list',
        () async {
      await BookmarksStore.add('wy|1', 30);
      await BookmarksStore.add('tx|1', 90);
      await BookmarksStore.add('wy|2', 120);
      expect(
        BookmarksStore.forSong('wy|1').map((m) => m.position).toList(),
        [30],
      );
      expect(
        BookmarksStore.forSong('tx|1').map((m) => m.position).toList(),
        [90],
      );
      expect(
        BookmarksStore.forSong('wy|2').map((m) => m.position).toList(),
        [120],
      );
    });
  });

  group('corrupt data', () {
    test('corrupt table reads as empty (bad JSON, wrong shape)', () async {
      await HiveStore.put(HiveKeys.musicBookmarks, 'not-json{{{');
      expect(BookmarksStore.forSong('wy|1'), isEmpty);
      // A top-level list is not the stored map shape either.
      await HiveStore.put(
        HiveKeys.musicBookmarks,
        '[{"position": 30, "label": "0:30", "createdAt": 1}]',
      );
      expect(BookmarksStore.forSong('wy|1'), isEmpty);
    });

    test('corrupt rows inside a well-formed table are skipped', () async {
      await HiveStore.put(
        HiveKeys.musicBookmarks,
        '{"wy|1": ['
            '{"position": 30, "label": "0:30", "createdAt": 1}, '
            '{"position": -5, "createdAt": 2}, '
            '{"label": "x", "createdAt": 3}, '
            '{"position": 90, "label": "1:30", "createdAt": 4}'
            ']}',
      );
      expect(
        BookmarksStore.forSong('wy|1').map((m) => m.position).toList(),
        [30, 90],
      );
    });

    test('missing label falls back to the position text', () async {
      await HiveStore.put(
        HiveKeys.musicBookmarks,
        '{"wy|1": [{"position": 83, "createdAt": 1}]}',
      );
      final marks = BookmarksStore.forSong('wy|1');
      expect(marks.single.label, '1:23');
    });
  });
}
