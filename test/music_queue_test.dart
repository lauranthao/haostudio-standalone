// Queue reorder + "play next" (M-P0-4).
//
// Covers: move up / down, drag-to-reorder (moveQueueItem, with the
// ReorderableListView newIndex adjustment applied by the caller),
// "下一首播放" insertion right after the current track, the current
// index following the playing song across a move, and persistence of
// the queue order + current index in the player playlist (Hive).
//
// The controller is constructed directly (no Get.put, so onInit never
// runs and no native media_kit players are created). Queue ops only
// touch the RxList + Hive, so they are fully testable this way. The
// queue is seeded by direct assignment — playQueue would start real
// playback (network resolve) and is deliberately not used here.

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

Song _song(String id, String title) =>
    Song(songId: id, title: title, artist: 'Singer $id');

List<String> _titles(MusicPlayerController c) =>
    c.queue.map((s) => s.title).toList();

void main() {
  late Box<dynamic> box;
  late MusicPlayerController c;

  setUp(() async {
    Hive.init('test/.hive-queue-test');
    box = await Hive.openBox<dynamic>('queue_test');
    await box.clear();
    HiveStore.setTestBox(box);
    c = MusicPlayerController();
    c.queue.clear();
    c.queue.addAll([
      _song('1', 'A'),
      _song('2', 'B'),
      _song('3', 'C'),
      _song('4', 'D'),
    ]);
    c.currentIndex.value = 1; // B is playing
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('queue_test');
  });

  group('move up / down', () {
    test('moveQueueUp swaps with the previous row', () {
      c.moveQueueUp(2); // C up -> A C B D, C is now at 1
      expect(_titles(c), ['A', 'C', 'B', 'D']);
      expect(c.currentIndex.value, 2); // B moved down one slot
    });

    test('moveQueueDown swaps with the next row', () {
      c.moveQueueDown(1); // B (playing) down -> A C B D
      expect(_titles(c), ['A', 'C', 'B', 'D']);
      expect(c.currentIndex.value, 2); // playing song followed
    });

    test('move up at the top / down at the bottom are no-ops', () {
      c.moveQueueUp(0);
      expect(_titles(c), ['A', 'B', 'C', 'D']);
      expect(c.currentIndex.value, 1);
      c.moveQueueDown(3);
      expect(_titles(c), ['A', 'B', 'C', 'D']);
      expect(c.currentIndex.value, 1);
    });

    test('out-of-range indices are no-ops', () {
      c.moveQueueUp(-1);
      c.moveQueueUp(4);
      c.moveQueueDown(-1);
      c.moveQueueDown(4);
      expect(_titles(c), ['A', 'B', 'C', 'D']);
      expect(c.currentIndex.value, 1);
    });
  });

  group('drag-to-reorder (moveQueueItem)', () {
    test('dragging the first row to the end', () {
      // ReorderableListView reports newIndex 3 for a drop after D
      // when moving down (oldIndex < newIndex -> newIndex -= 1).
      var oldIndex = 0;
      var newIndex = 3;
      if (oldIndex < newIndex) newIndex -= 1;
      c.moveQueueItem(oldIndex, newIndex);
      expect(_titles(c), ['B', 'C', 'A', 'D']);
      expect(c.currentIndex.value, 0); // B is now first
    });

    test('dragging the last row to the front', () {
      c.moveQueueItem(3, 0);
      expect(_titles(c), ['D', 'A', 'B', 'C']);
      expect(c.currentIndex.value, 2); // B shifted right
    });

    test('dragging the playing song itself moves the index with it', () {
      c.moveQueueItem(1, 3);
      expect(_titles(c), ['A', 'C', 'D', 'B']);
      expect(c.currentIndex.value, 3);
    });

    test('dragging across the playing song shifts it by one', () {
      // A (0) -> 2 moves past B's slot, so B slides from 1 to 0.
      c.moveQueueItem(0, 2);
      expect(_titles(c), ['B', 'C', 'A', 'D']);
      expect(c.currentIndex.value, 0);
    });

    test('moving a row onto itself is a no-op', () {
      c.moveQueueItem(2, 2);
      expect(_titles(c), ['A', 'B', 'C', 'D']);
      expect(c.currentIndex.value, 1);
    });
  });

  group('playNext (下一首播放)', () {
    test('inserts right after the current track', () async {
      final ok = await c.playNext(_song('9', 'X'));
      expect(ok, isTrue);
      expect(_titles(c), ['A', 'B', 'X', 'C', 'D']);
      expect(c.currentIndex.value, 1); // still on B
    });

    test('inserting when the current track is last appends', () async {
      c.currentIndex.value = 3;
      final ok = await c.playNext(_song('9', 'X'));
      expect(ok, isTrue);
      expect(_titles(c), ['A', 'B', 'C', 'D', 'X']);
      expect(c.currentIndex.value, 3);
    });

    test('the currently playing song is not inserted after itself',
        () async {
      final ok = await c.playNext(_song('2', 'B'));
      expect(ok, isFalse);
      expect(_titles(c), ['A', 'B', 'C', 'D']);
      expect(c.currentIndex.value, 1);
    });

    test('no current track inserts at the front', () async {
      c.currentIndex.value = -1;
      final ok = await c.playNext(_song('9', 'X'));
      expect(ok, isTrue);
      expect(_titles(c), ['X', 'A', 'B', 'C', 'D']);
    });
  });

  group('persistence (player playlist)', () {
    test('reorder persists order + current index', () async {
      c.moveQueueItem(3, 0); // D to front
      final saved = MusicStore.getQueue();
      expect(saved.songs.map((s) => s.title).toList(), [
        'D',
        'A',
        'B',
        'C',
      ]);
      expect(saved.index, 2); // B is now at 2
    });

    test('playNext persists the inserted order', () async {
      await c.playNext(_song('9', 'X'));
      final saved = MusicStore.getQueue();
      expect(saved.songs.map((s) => s.title).toList(), [
        'A',
        'B',
        'X',
        'C',
        'D',
      ]);
      expect(saved.index, 1);
    });

    test('empty queue round-trips as empty', () {
      final saved = MusicStore.getQueue();
      expect(saved.songs, isEmpty);
      expect(saved.index, -1);
    });
  });
}
