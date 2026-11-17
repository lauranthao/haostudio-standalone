// Stage 2 item 1 — clearQueue (Beans `PlayerManager.clearQueue`,
// PlayerManager.swift:364-375: keep only the current song).
//
// The controller is constructed directly (no Get.put, so onInit never
// runs and no native players are created), the same pattern as
// music_queue_test.dart. Queue ops only touch the RxList + Hive.

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

Song _song(String id, String title) =>
    Song(songId: id, title: title, artist: 'Singer $id');

void main() {
  late Box<dynamic> box;
  late MusicPlayerController c;

  setUp(() async {
    Hive.init('test/.hive-stage2-clear-queue');
    box = await Hive.openBox<dynamic>('stage2_clear_queue_test');
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
    await Hive.deleteBoxFromDisk('stage2_clear_queue_test');
  });

  test('clearQueue keeps only the playing song, index reset to 0', () {
    c.clearQueue();
    expect(c.queue.map((s) => s.title).toList(), ['B']);
    expect(c.currentIndex.value, 0);
    expect(c.currentSong?.title, 'B');
  });

  test('clearQueue on an empty queue is a no-op', () {
    c.queue.clear();
    c.currentIndex.value = -1;
    c.clearQueue();
    expect(c.queue, isEmpty);
    expect(c.currentIndex.value, -1);
  });

  test('clearQueue with a single song leaves it untouched', () {
    c.queue.clear();
    c.queue.add(_song('2', 'B'));
    c.currentIndex.value = 0;
    c.clearQueue();
    expect(c.queue.map((s) => s.title).toList(), ['B']);
    expect(c.currentIndex.value, 0);
  });

  test('clearQueue with no current song clears everything', () {
    c.currentIndex.value = -1;
    c.clearQueue();
    expect(c.queue, isEmpty);
    expect(c.currentIndex.value, -1);
  });

  test('clearQueue persists the kept song so a restart keeps it', () async {
    c.clearQueue();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final saved = MusicStore.getQueue();
    expect(saved.songs.map((s) => s.title).toList(), ['B']);
    expect(saved.index, 0);
  });
}
