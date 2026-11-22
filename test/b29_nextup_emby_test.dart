// b29 Next Up — Emby rails (emby_tab_page.dart pure helpers).
//
// - The local-history fallback for /Shows/NextUp takes series rows
//   only: a movie row's vodId is a movie id, never a series id.
// - A series already in 继续观看 stays out of 下一集 (one work,
//   one rail), and one series keeps a single NextUp entry.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/features/video/emby_tab_page.dart';
import 'package:standalone/features/video/video_models.dart';

WatchHistoryEntry _history({
  required String vodId,
  required String title,
  String nextEpName = '',
}) =>
    WatchHistoryEntry(
      source: 'emby',
      vodId: vodId,
      title: title,
      nextEpName: nextEpName,
      at: DateTime(2026, 11, 22),
    );

VideoItem _nextUp({
  required String vodId,
  required String seriesId,
  String seriesName = '',
}) =>
    VideoItem(
      source: 'emby',
      sourceName: 'Emby',
      vodId: vodId,
      name: seriesName.isEmpty ? '第2集' : seriesName,
      seriesId: seriesId,
      seriesName: seriesName,
      mediaType: 'Episode',
    );

void main() {
  group('embyFallbackNextUpSeriesIds', () {
    test('movie rows never feed a NextUp lookup', () {
      expect(
        embyFallbackNextUpSeriesIds([
          _history(vodId: 'movie-1', title: '空枪'),
          _history(vodId: 'series-1', title: '庆余年', nextEpName: '第2集'),
          _history(vodId: 'series-1', title: '庆余年', nextEpName: '第2集'),
        ]),
        ['series-1'],
      );
    });

    test('no series rows means no fallback lookup', () {
      expect(
        embyFallbackNextUpSeriesIds([
          _history(vodId: 'movie-1', title: '空枪'),
          _history(vodId: 'movie-2', title: '流浪地球2'),
        ]),
        isEmpty,
      );
    });
  });

  group('filterEmbyNextUp', () {
    test('a series in the resume rail stays out of 下一集', () {
      final out = filterEmbyNextUp(
        [
          _nextUp(vodId: 'ep-a2', seriesId: 'series-a', seriesName: '剧A'),
          _nextUp(vodId: 'ep-b2', seriesId: 'series-b', seriesName: '剧B'),
          _nextUp(vodId: 'ep-b3', seriesId: 'series-b', seriesName: '剧B'),
          _nextUp(vodId: 'ep-c2', seriesId: '', seriesName: '未知'),
        ],
        {'series-a'},
      );
      // series-a hidden (in 继续观看); series-b keeps one entry;
      // an item with no series id cannot be matched, so it is kept.
      expect(out.map((e) => e.vodId).toList(), ['ep-b2', 'ep-c2']);
    });

    test('a finished series (not in resume) keeps its next episode', () {
      final out = filterEmbyNextUp(
        [_nextUp(vodId: 'ep-b2', seriesId: 'series-b', seriesName: '剧B')],
        {},
      );
      expect(out.map((e) => e.vodId).toList(), ['ep-b2']);
    });
  });
}
