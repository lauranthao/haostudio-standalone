// Search-result cover backfill tests: coverless Kuwo/Kugou rows get
// their cover from NetEase ("加一个源", chen 2026-11-17), one serial
// lookup per song, first title+artist match wins.
//
// A fake MusicApi answers searchWy from canned candidates, so the
// matching rules are tested without network: the first result alone
// is NOT trusted (measured 2026-11-17, "季候风 张学友" returns 王菲's
// 季候风 first, "越吻越伤心 张学友" returns a medley first).
// Run:
//   TMPDIR=$PWD/.tmp flutter test --concurrency=1
//   test/music_cover_backfill_test.dart
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';
import 'package:standalone/services/music/search_cover_backfill.dart';

Song _song(String id, String title, String artist) => Song(
      songId: id,
      title: title,
      artist: artist,
      platform: MusicPlatform.kw,
      dur: 200,
    );

Song _wy(String title, String artist, String cover) => Song(
      songId: 'wy_$title',
      title: title,
      artist: artist,
      platform: MusicPlatform.wy,
      cover: cover,
      dur: 200,
    );

class FakeCoverApi extends MusicApi {
  FakeCoverApi() : super(dio: Dio());

  final calls = <String>[];
  var delay = Duration.zero;
  final throwOnQuery = <String>{};
  Map<String, List<Song>> answers = {};

  @override
  Future<List<Song>> searchWy(String q, int limit) async {
    calls.add(q);
    if (throwOnQuery.contains(q)) throw StateError('boom');
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    return answers[q] ?? const [];
  }
}

Future<void> _waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw StateError('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-cover-');
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
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    await HiveStore.put(HiveKeys.musicCoverCache, '{}');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  group('matching (fake NetEase)', () {
    test('wrong-singer first result is skipped, same-singer wins', () async {
      final api = FakeCoverApi()
        ..answers = {
          '季候风 张学友': [
            _wy('季候风', '王菲', 'https://example.com/wangfei.jpg'),
            _wy('季候风', '张学友', 'https://example.com/zhangxueyou.jpg'),
          ],
        };
      final backfill = SearchCoverBackfill(api: api);
      final filled = <Song>[];
      backfill.fill([_song('1', '季候风', '张学友')], filled.add);
      await _waitUntil(() => filled.isNotEmpty);
      expect(filled.single.cover, 'https://example.com/zhangxueyou.jpg');
      expect(api.calls, ['季候风 张学友']);
    });

    test('DJ suffix stripped: 吻别 (DJ萧子枫版) matches 吻别', () async {
      final api = FakeCoverApi()
        ..answers = {
          '吻别 张学友': [_wy('吻别', '张学友', 'https://example.com/wenbie.jpg')],
        };
      final backfill = SearchCoverBackfill(api: api);
      final filled = <Song>[];
      backfill.fill([_song('1', '吻别 (DJ萧子枫版)', '张学友')], filled.add);
      await _waitUntil(() => filled.isNotEmpty);
      expect(filled.single.cover, 'https://example.com/wenbie.jpg');
    });

    test('chorus: 群星 result matches multi-singer target', () async {
      final api = FakeCoverApi()
        ..answers = {
          '明天会更好 梅艳芳': [
            _wy('明天会更好', '群星', 'https://example.com/qunxing.jpg'),
          ],
        };
      final backfill = SearchCoverBackfill(api: api);
      final filled = <Song>[];
      backfill.fill(
        [_song('1', '明天会更好-1985 TVB十大劲歌金曲颁奖典礼现场',
            '梅艳芳&张学友&张国荣&谭咏麟&苏芮')],
        filled.add,
      );
      await _waitUntil(() => filled.isNotEmpty);
      expect(filled.single.cover, 'https://example.com/qunxing.jpg');
    });

    test('medley + wrong singer: no fill, miss cached, no re-query',
        () async {
      final api = FakeCoverApi()
        ..answers = {
          '越吻越伤心 张学友': [
            _wy('MEDLEY : 越吻越伤心 / 原来你什么都不要 (Live)', '张学友',
                'https://example.com/medley.jpg'),
            _wy('越吻越伤心', '苏永康', 'https://example.com/suyongkang.jpg'),
          ],
        };
      final backfill = SearchCoverBackfill(api: api);
      final filled = <Song>[];
      final song = _song('1', '越吻越伤心', '张学友');
      backfill.fill([song], filled.add);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(filled, isEmpty);
      expect(api.calls, ['越吻越伤心 张学友']);
      // Second fill for the same song does not re-query (miss cached).
      backfill.fill([song], filled.add);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(api.calls, ['越吻越伤心 张学友']);
      expect(filled, isEmpty);
    });

    test('throwing lookup does not break the next song', () async {
      final api = FakeCoverApi()
        ..throwOnQuery.add('吻别 张学友')
        ..answers = {
          '偷心 张学友': [_wy('偷心', '张学友', 'https://example.com/touxin.jpg')],
        };
      final backfill = SearchCoverBackfill(api: api);
      final filled = <Song>[];
      backfill.fill(
        [
          _song('1', '吻别', '张学友'),
          _song('2', '偷心', '张学友'),
        ],
        filled.add,
      );
      await _waitUntil(() => filled.isNotEmpty);
      expect(filled.single.title, '偷心');
      expect(filled.single.cover, 'https://example.com/touxin.jpg');
    });

    test('timeout moves on: slow song skipped, next song still filled',
        () async {
      final api = FakeCoverApi()
        ..delay = const Duration(milliseconds: 500)
        ..answers = {
          '吻别 张学友': [_wy('吻别', '张学友', 'https://example.com/wenbie.jpg')],
        };
      final backfill = SearchCoverBackfill(
        api: api,
        lookupTimeout: const Duration(milliseconds: 50),
      );
      final filled = <Song>[];
      backfill.fill(
        [
          _song('1', '吻别', '张学友'),
          _song('2', '偷心', '张学友'),
        ],
        filled.add,
      );
      // 偷心 has no canned answer, so nothing is ever delivered; the
      // test passes when the run finishes without hanging — both
      // lookups hit the 50 ms timeout instead of the 500 ms delay.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(filled, isEmpty);
      expect(api.calls, ['吻别 张学友', '偷心 张学友']);
    });
  });

  group('scope, cancel, cache', () {
    test('only the first 20 visible rows are looked up', () async {
      final api = FakeCoverApi();
      final songs = List.generate(
        25,
        (i) => _song('$i', '歌$i', '张学友'),
      );
      for (final s in songs) {
        api.answers['${s.title} 张学友'] = [
          _wy(s.title, '张学友', 'https://example.com/$s.jpg'),
        ];
      }
      final backfill = SearchCoverBackfill(api: api);
      final filled = <Song>[];
      backfill.fill(songs, filled.add);
      await _waitUntil(() => filled.length == 20);
      expect(api.calls.length, 20);
    });

    test('cancel abandons the run: no delivery after cancel', () async {
      final api = FakeCoverApi()
        ..delay = const Duration(milliseconds: 200)
        ..answers = {
          '吻别 张学友': [_wy('吻别', '张学友', 'https://example.com/wenbie.jpg')],
          '偷心 张学友': [_wy('偷心', '张学友', 'https://example.com/touxin.jpg')],
        };
      final backfill = SearchCoverBackfill(api: api);
      final filled = <Song>[];
      backfill.fill(
        [_song('1', '吻别', '张学友'), _song('2', '偷心', '张学友')],
        filled.add,
      );
      backfill.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(filled, isEmpty);
      expect(api.calls, ['吻别 张学友']);
    });

    test('reorder mid-lookup: new fill takes over the in-flight lookup',
        () async {
      // Regression: a reorder (new fill) landing while 吻别's lookup
      // is in flight used to lose the cover — the new run skipped
      // the song as in-flight, the old run's result was dropped by
      // the generation check, and the cover only surfaced on the
      // next emission/scroll via applyCached. Now the new run takes
      // over the in-flight lookup's callback, so the cover is
      // delivered to the current list with no further fill/emit.
      final api = FakeCoverApi()
        ..delay = const Duration(milliseconds: 300)
        ..answers = {
          '吻别 张学友': [_wy('吻别', '张学友', 'https://example.com/wenbie.jpg')],
        };
      final backfill = SearchCoverBackfill(api: api);
      final filledOld = <Song>[];
      final filledNew = <Song>[];
      final song = _song('1', '吻别', '张学友');
      backfill.fill([song], filledOld.add);
      // Lookup in flight, not finished yet.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Reorder: same song, now first in a re-emitted list.
      backfill.fill([song, _song('2', '偷心', '张学友')], filledNew.add);
      await _waitUntil(() => filledNew.isNotEmpty);
      expect(filledNew.single.cover, 'https://example.com/wenbie.jpg');
      // The stale run never delivers through its own callback.
      expect(filledOld, isEmpty);
      // One lookup for 吻别 only — the new run did not start a
      // duplicate (偷心's own lookup is separate and finds nothing).
      expect(api.calls.where((c) => c == '吻别 张学友'), hasLength(1));
    });

    test('cancel after takeover: no delivery to either run', () async {
      final api = FakeCoverApi()
        ..delay = const Duration(milliseconds: 300)
        ..answers = {
          '吻别 张学友': [_wy('吻别', '张学友', 'https://example.com/wenbie.jpg')],
        };
      final backfill = SearchCoverBackfill(api: api);
      final filledOld = <Song>[];
      final filledNew = <Song>[];
      final song = _song('1', '吻别', '张学友');
      backfill.fill([song], filledOld.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      backfill.fill([song], filledNew.add);
      backfill.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(filledOld, isEmpty);
      expect(filledNew, isEmpty);
      // The cover still landed in the cache for the next applyCached.
      expect(
        MusicStore.getCoverCache()['吻别|张学友'],
        'https://example.com/wenbie.jpg',
      );
    });

    test('filled cover lands in Hive; a new instance applies it offline',
        () async {
      final api = FakeCoverApi()
        ..answers = {
          '偷心 张学友': [_wy('偷心', '张学友', 'https://example.com/touxin.jpg')],
        };
      final first = SearchCoverBackfill(api: api);
      final filled = <Song>[];
      first.fill([_song('1', '偷心', '张学友')], filled.add);
      await _waitUntil(() => filled.isNotEmpty);
      // Let the fire-and-forget Hive write land.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        MusicStore.getCoverCache()['偷心|张学友'],
        'https://example.com/touxin.jpg',
      );
      // A fresh instance with a counting API fills from Hive alone.
      final api2 = FakeCoverApi();
      final second = SearchCoverBackfill(api: api2);
      final out = second.applyCached([_song('1', '偷心', '张学友')]);
      expect(out.single.cover, 'https://example.com/touxin.jpg');
      expect(api2.calls, isEmpty);
    });

    test('applyCached is a no-op when nothing is cached', () {
      final backfill = SearchCoverBackfill(api: FakeCoverApi());
      final songs = [_song('1', '吻别', '张学友')];
      expect(identical(backfill.applyCached(songs), songs), isTrue);
    });
  });
}
