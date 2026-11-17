// Video history dedup tests (chen 2026-11-17: one film showed two
// rows in 继续观看 — ep1 and ep3 of the same show).
//
// The dedup key is the film itself (normalised title), NOT source+vodId:
// the same show on different CMS sources has different vodIds, and the
// detail page switches to a faster source, so source+vodId dedup let
// the same film in twice.
//
// - record() on another source / another episode updates the same row
//   (episode, progress, time all take the latest).
// - getAll() merges legacy duplicates on read (latest `at` wins), so
//   pre-fix duplicates disappear without the user deleting anything.
// - Different films stay separate; title normalisation merges
//   "霓裳尽欢 (2024)" with "霓裳尽欢".

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/video/video_history_store.dart';
import 'package:standalone/features/video/video_models.dart';

WatchHistoryEntry _entry({
  required dynamic source,
  required String vodId,
  required String title,
  required int epIdx,
  required String epName,
  required DateTime at,
}) =>
    WatchHistoryEntry(
      source: source,
      vodId: vodId,
      title: title,
      pic: 'https://example.com/cover-$vodId.jpg',
      lineIdx: 0,
      epIdx: epIdx,
      epName: epName,
      position: 600,
      duration: 1800,
      at: at,
    );

Map<String, dynamic> _entryJson({
  required dynamic source,
  required String vodId,
  required String title,
  required int epIdx,
  required String epName,
  required DateTime at,
}) =>
    {
      'source': source,
      'vodId': vodId,
      'title': title,
      'pic': 'https://example.com/cover-$vodId.jpg',
      'picAlt': '',
      'lineIdx': 0,
      'epIdx': epIdx,
      'epName': epName,
      'position': 600,
      'duration': 1800,
      'at': at.millisecondsSinceEpoch,
    };

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-hist-dedup-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  tearDown(() async {
    Get.reset();
    await HiveStore.delete(HiveKeys.videoHistory);
  });

  test('record same film on another source updates the same row',
      () async {
    // ep1 watched on 金鹰 (source 12, vodId 1001) …
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1001',
        title: '霓裳尽欢',
        epIdx: 0,
        epName: '第1集',
        at: DateTime(2026, 11, 17, 10),
      ),
    );
    // … then ep3 on 非凡 (source 5, vodId 2002): same film, new row
    // would be the bug — it must update the ep1 row instead.
    await VideoHistoryStore.record(
      _entry(
        source: 5,
        vodId: '2002',
        title: '霓裳尽欢',
        epIdx: 2,
        epName: '第3集',
        at: DateTime(2026, 11, 17, 12),
      ),
    );

    final list = VideoHistoryStore.getAll();
    expect(list.length, 1);
    expect(list.first.epIdx, 2);
    expect(list.first.epName, '第3集');
    expect(list.first.vodId, '2002');
    expect(list.first.at, DateTime(2026, 11, 17, 12));
  });

  test('record same film same source, new episode updates the row',
      () async {
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1001',
        title: '霓裳尽欢',
        epIdx: 0,
        epName: '第1集',
        at: DateTime(2026, 11, 17, 10),
      ),
    );
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1001',
        title: '霓裳尽欢',
        epIdx: 2,
        epName: '第3集',
        at: DateTime(2026, 11, 17, 12),
      ),
    );

    final list = VideoHistoryStore.getAll();
    expect(list.length, 1);
    expect(list.first.epName, '第3集');
  });

  test('getAll merges legacy duplicates, keeping the latest watch',
      () async {
    // Pre-fix storage: the same film under two source+vodId keys.
    await HiveStore.put(
      HiveKeys.videoHistory,
      jsonEncode([
        _entryJson(
          source: 12,
          vodId: '1001',
          title: '霓裳尽欢',
          epIdx: 0,
          epName: '第1集',
          at: DateTime(2026, 11, 17, 10),
        ),
        _entryJson(
          source: 5,
          vodId: '2002',
          title: '霓裳尽欢',
          epIdx: 2,
          epName: '第3集',
          at: DateTime(2026, 11, 17, 12),
        ),
      ]),
    );

    final list = VideoHistoryStore.getAll();
    expect(list.length, 1);
    expect(list.first.epName, '第3集');
    expect(list.first.vodId, '2002');
  });

  test('different films stay separate', () async {
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1001',
        title: '霓裳尽欢',
        epIdx: 2,
        epName: '第3集',
        at: DateTime(2026, 11, 17, 12),
      ),
    );
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1002',
        title: '庆余年',
        epIdx: 0,
        epName: '第1集',
        at: DateTime(2026, 11, 17, 13),
      ),
    );

    final list = VideoHistoryStore.getAll();
    expect(list.length, 2);
    expect(list.first.title, '庆余年');
    expect(list.last.title, '霓裳尽欢');
  });

  test('title normalisation merges year-suffixed variants', () async {
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1001',
        title: '霓裳尽欢 (2024)',
        epIdx: 0,
        epName: '第1集',
        at: DateTime(2026, 11, 17, 10),
      ),
    );
    await VideoHistoryStore.record(
      _entry(
        source: 5,
        vodId: '2002',
        title: '霓裳尽欢',
        epIdx: 2,
        epName: '第3集',
        at: DateTime(2026, 11, 17, 12),
      ),
    );

    final list = VideoHistoryStore.getAll();
    expect(list.length, 1);
    expect(list.first.epName, '第3集');
  });

  test('findByTitle finds the film whatever source it was watched on',
      () async {
    await VideoHistoryStore.record(
      _entry(
        source: 5,
        vodId: '2002',
        title: '霓裳尽欢',
        epIdx: 2,
        epName: '第3集',
        at: DateTime(2026, 11, 17, 12),
      ),
    );

    final found = VideoHistoryStore.findByTitle('霓裳尽欢');
    expect(found, isNotNull);
    expect(found!.epName, '第3集');
    expect(VideoHistoryStore.findByTitle('不存在的剧'), isNull);
    expect(VideoHistoryStore.findByTitle(''), isNull);
  });

  test('untitled entries never merge into each other', () async {
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1001',
        title: '',
        epIdx: 0,
        epName: '第1集',
        at: DateTime(2026, 11, 17, 10),
      ),
    );
    await VideoHistoryStore.record(
      _entry(
        source: 5,
        vodId: '2002',
        title: '',
        epIdx: 0,
        epName: '第1集',
        at: DateTime(2026, 11, 17, 12),
      ),
    );

    expect(VideoHistoryStore.getAll().length, 2);
  });
}
