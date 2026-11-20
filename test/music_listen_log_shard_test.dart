// Listen-log monthly sharding (P1-P4).
//
// The old single `hao_listen` list was read + JSON-rewritten whole
// (up to 3000 entries) on every finished session. Events now shard by
// month: a write only touches the current month's shard, and
// getListenLog merges shards + the frozen legacy list, newest first.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-listen-shard-');
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
      'test_listen_shard',
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

  ListenEvent event(String id, int atMs) => ListenEvent(
        songId: id,
        title: 'Song $id',
        artist: 'Singer',
        at: atMs,
        dur: 120,
      );

  test('events shard by month and merge newest-first', () async {
    final jan = DateTime(2026, 1, 15, 12).millisecondsSinceEpoch;
    final feb = DateTime(2026, 2, 3, 12).millisecondsSinceEpoch;
    await MusicStore.recordListenEvent(event('jan-1', jan));
    await MusicStore.recordListenEvent(event('feb-1', feb));
    await MusicStore.recordListenEvent(event('jan-2', jan + 1000));
    final log = MusicStore.getListenLog();
    expect(log.map((e) => e.songId).toList(), ['feb-1', 'jan-2', 'jan-1']);
    // One key per month shard, not a rewritten whole table.
    expect(HiveStore.box.containsKey('hao_listen_2026-01'), isTrue);
    expect(HiveStore.box.containsKey('hao_listen_2026-02'), isTrue);
    expect(HiveStore.box.containsKey('hao_listen'), isFalse);
  });

  test('legacy hao_listen events still read', () async {
    // Pre-shard install: events live under the single legacy key.
    await HiveStore.put(
      HiveKeys.musicListen,
      '[{"songId":"old-1","title":"Old","artist":"","platform":"wy","cover":"","dur":60,"totalDur":200,"at":1700000000000}]',
    );
    final now = DateTime(2026, 11, 21, 12).millisecondsSinceEpoch;
    await MusicStore.recordListenEvent(event('new-1', now));
    final log = MusicStore.getListenLog();
    expect(log.map((e) => e.songId).toList(), ['new-1', 'old-1']);
    // The legacy key is frozen: the new write did not rewrite it.
    expect(
      HiveStore.box.get(HiveKeys.musicListen) as String,
      contains('old-1'),
    );
  });
}
