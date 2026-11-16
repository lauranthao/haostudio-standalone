// Regression tests for the 2026-11-17 video audit fixes.
//
// - fromJson leniency (video_models.dart): one malformed element in a
//   persisted cache entry must not throw and discard the whole entry.
// - fetchFresh cache-write failure (video_home_service.dart): a Hive
//   failure while saving the cache must not turn a good fetch into
//   an error for the caller.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/features/video/video_home_service.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/video/cms_client.dart';

void main() {
  group('video_models fromJson leniency (audit)', () {
    test('home data with one malformed row keeps the good rows', () {
      final data = VideoHomeData.fromJson({
        'rows': [
          {
            'name': '电影',
            'count': 1,
            'items': [
              {
                'source': 12,
                'sourceName': '金鹰资源',
                'vodId': '1',
                'name': '流浪地球2',
              },
            ],
          },
          'this row is a string, not a map',
          {'name': '连续剧', 'count': 0, 'items': ['not a map', 42]},
        ],
        'fetchedAt': 0,
      });
      expect(data.rows.length, 2);
      expect(data.rows[0].name, '电影');
      expect(data.rows[0].items.length, 1);
      expect(data.rows[1].name, '连续剧');
      expect(data.rows[1].items, isEmpty);
    });

    test('detail with missing meta does not throw', () {
      final detail = VideoDetail.fromJson({
        'source': 12,
        'vodId': '1',
        'lines': [],
      });
      expect(detail.meta.name, '');
      expect(detail.lines, isEmpty);
    });

    test('detail with malformed lines/episodes keeps the good ones', () {
      final detail = VideoDetail.fromJson({
        'source': 12,
        'vodId': '1',
        'meta': {'name': '流浪地球2'},
        'lines': [
          {
            'name': '线路1',
            'episodes': [
              {'name': '第1集', 'url': 'https://example.com/1.m3u8'},
              'not a map',
              {'name': '第2集', 'url': 'https://example.com/2.m3u8'},
            ],
          },
          42,
        ],
      });
      expect(detail.lines.length, 1);
      expect(detail.lines[0].episodes.length, 2);
      expect(detail.lines[0].episodes[1].name, '第2集');
    });

    test('meta with non-map douban does not throw', () {
      final meta = VideoMeta.fromJson({
        'name': '流浪地球2',
        'douban': 'garbage, not a map',
      });
      expect(meta.douban, isNull);
    });
  });

  group('video_home_service fetchFresh (audit)', () {
    test('returns fresh data even when the cache write fails', () async {
      // Hive is never initialised in this test process, so the cache
      // write inside fetchFresh throws LateInitializationError — the
      // fetch must still return the data, not propagate the error.
      final canned = VideoHomeData(
        rows: const [
          VideoHomeRow(name: '电影', count: 1, items: []),
        ],
        fetchedAt: DateTime.now(),
      );
      final service = VideoHomeService(cms: _FakeCms(canned));
      expect(await service.fetchFresh(), isNotNull);
      expect((await service.fetchFresh())!.rows.single.name, '电影');
    });
  });
}

class _FakeCms extends CmsClient {
  _FakeCms(this._home);

  final VideoHomeData _home;

  @override
  Future<VideoHomeData> home() async => _home;
}
