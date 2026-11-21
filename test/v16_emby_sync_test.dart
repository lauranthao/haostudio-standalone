// 1.1.6 换源链路 — Emby Direct Mode server sync (mock fetcher /
// mock mutator, zero network).
//
// Pins, against the official Emby API endpoints (verified in the
// audit: GET /Users/{UserId}/Items/Resume, GET /Shows/NextUp,
// POST /Users/{UserId}/PlayingItems/{Id}[/Progress],
// DELETE /Users/{UserId}/PlayingItems/{Id},
// POST /Users/{UserId}/PlayedItems/{Id},
// POST/DELETE /Users/{UserId}/FavoriteItems/{Id},
// POST /Users/{UserId}/Items/{Id}/Rating):
// - UserData is no longer dropped: resume position / played /
//   favorite / rating ride on VideoItem;
// - detail() is lazy: a series detail fetches only the first
//   season with episodes, never a full-season sweep;
// - every mutating call carries the key in the HEADER, never the
//   URL, and returns false (never throws) on failure.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';

const _config = EmbyServerConfig(
  baseUrl: 'http://127.0.0.1:8096',
  apiKey: 'test-key-123',
  userId: 'user-1',
);

/// Canned GET fetcher answering by URL substring (same shape as
/// emby_client_test.dart's CannedEmbyFetcher).
class _CannedFetcher {
  _CannedFetcher(this._answers);

  final Map<String, EmbyResponse> _answers;
  final List<String> seenUrls = [];

  Future<EmbyResponse> call(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 8),
    CancelToken? cancelToken,
  }) async {
    seenUrls.add(url);
    for (final entry in _answers.entries) {
      if (url.contains(entry.key)) return entry.value;
    }
    return const EmbyResponse(statusCode: 404, json: {});
  }
}

EmbyResponse okJson(dynamic json) =>
    EmbyResponse(statusCode: 200, json: json);

/// Canned mutator: records method + URL + headers, answers 200
/// unless told otherwise.
class _CannedMutator {
  _CannedMutator({this.statusCode = 200});

  final int statusCode;
  final List<(String, String)> seen = [];
  final List<Map<String, String>?> seenHeaders = [];

  Future<EmbyResponse> call(
    String method,
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? jsonBody,
    Duration timeout = const Duration(seconds: 8),
    CancelToken? cancelToken,
  }) async {
    seen.add((method, url));
    seenHeaders.add(headers);
    return EmbyResponse(statusCode: statusCode, json: {});
  }
}

Map<String, dynamic> embyItem({
  required String id,
  required String type,
  String name = 'Test Film',
  int? indexNumber,
  int? parentIndexNumber,
  String? seriesId,
  String? seriesName,
  Map<String, dynamic>? userData,
  int? runTimeTicks,
}) {
  return <String, dynamic>{
    'Id': id,
    'Name': name,
    'Type': type,
    'IndexNumber': ?indexNumber,
    'ParentIndexNumber': ?parentIndexNumber,
    'SeriesId': ?seriesId,
    'SeriesName': ?seriesName,
    'UserData': ?userData,
    'RunTimeTicks': ?runTimeTicks,
  };
}

void main() {
  group('UserData is kept on VideoItem', () {
    test('resume position / played / favorite / likes / series link',
        () async {
      final fetcher = _CannedFetcher({
        '/Items': okJson({
          'Items': [
            embyItem(
              id: 'ep-5',
              type: 'Episode',
              name: '第五集',
              indexNumber: 5,
              parentIndexNumber: 2,
              seriesId: 'series-1',
              seriesName: '狂飙',
              runTimeTicks: 600000000 * 100,
              userData: {
                'PlaybackPositionTicks': 600000000, // 60 s
                'PlayedPercentage': 25.0,
                'Played': false,
                'IsFavorite': true,
                'Likes': true,
              },
            ),
          ],
          'TotalRecordCount': 1,
        }),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final page = await client.movies();
      final item = page.items.single;
      expect(item.progressSeconds, 60);
      expect(item.progressFraction, 0.25);
      expect(item.played, isFalse);
      expect(item.isFavorite, isTrue);
      expect(item.likes, isTrue);
      expect(item.mediaType, 'Episode');
      expect(item.seriesId, 'series-1');
      expect(item.seriesName, '狂飙');
      expect(item.seasonIndex, 2);
      expect(item.episodeIndex, 5);
    });

    test('fraction falls back to ticks/runtime when no percentage',
        () async {
      final fetcher = _CannedFetcher({
        '/Items': okJson({
          'Items': [
            embyItem(
              id: 'm1',
              type: 'Movie',
              runTimeTicks: 600000000 * 100,
              userData: {'PlaybackPositionTicks': 1500000000}, // 150 s
            ),
          ],
          'TotalRecordCount': 1,
        }),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final item = (await client.movies()).items.single;
      expect(item.progressSeconds, 150);
      expect(item.progressFraction, closeTo(0.025, 0.001));
    });

    test('no UserData at all stays at the never-watched defaults',
        () async {
      final fetcher = _CannedFetcher({
        '/Items': okJson({
          'Items': [embyItem(id: 'm1', type: 'Movie')],
          'TotalRecordCount': 1,
        }),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final item = (await client.movies()).items.single;
      expect(item.progressSeconds, 0);
      expect(item.progressFraction, 0);
      expect(item.played, isFalse);
      expect(item.isFavorite, isFalse);
      expect(item.likes, isNull);
    });
  });

  group('resumeItems / nextUp', () {
    test('resume hits /Items/Resume and carries progress', () async {
      final fetcher = _CannedFetcher({
        '/Items/Resume': okJson({
          'Items': [
            embyItem(
              id: 'm1',
              type: 'Movie',
              name: '流浪地球',
              userData: {
                'PlaybackPositionTicks': 1200000000,
                'PlayedPercentage': 50.0,
              },
            ),
          ],
          'TotalRecordCount': 1,
        }),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final items = await client.resumeItems();
      expect(items.single.name, '流浪地球');
      expect(items.single.progressSeconds, 120);
      expect(items.single.progressFraction, 0.5);
      expect(fetcher.seenUrls.single, contains('/Items/Resume'));
    });

    test('nextUp hits /Shows/NextUp with seriesId + userId', () async {
      final fetcher = _CannedFetcher({
        '/Shows/NextUp': okJson({
          'Items': [
            embyItem(
              id: 'ep-6',
              type: 'Episode',
              name: '第六集',
              indexNumber: 6,
              parentIndexNumber: 1,
              seriesId: 'series-1',
              seriesName: '狂飙',
            ),
          ],
          'TotalRecordCount': 1,
        }),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final items = await client.nextUp(seriesId: 'series-1');
      expect(items.single.vodId, 'ep-6');
      expect(items.single.episodeIndex, 6);
      expect(items.single.seriesName, '狂飙');
      expect(fetcher.seenUrls.single, contains('/Shows/NextUp'));
      expect(fetcher.seenUrls.single, contains('seriesId=series-1'));
      expect(fetcher.seenUrls.single, contains('userId=user-1'));
    });
  });

  group('detail() lazy season load', () {
    test('only the first season with episodes is fetched', () async {
      final fetcher = _CannedFetcher({
        '/Items/series-1': okJson(
          embyItem(id: 'series-1', type: 'Series', name: '剧'),
        ),
        '/Seasons': okJson({
          'Items': [
            embyItem(id: 's1', type: 'Season', name: '第一季', indexNumber: 1),
            embyItem(id: 's2', type: 'Season', name: '第二季', indexNumber: 2),
            embyItem(id: 's3', type: 'Season', name: '第三季', indexNumber: 3),
          ],
        }),
        'seasonId=s1': okJson({
          'Items': [
            embyItem(id: 'e1', type: 'Episode', name: '第一集', indexNumber: 1),
            embyItem(id: 'e2', type: 'Episode', name: '第二集', indexNumber: 2),
          ],
        }),
        // No answers for seasonId=s2 / s3: if detail() fetched
        // them, the canned fetcher would 404 and detail() throw.
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final detail = await client.detail('series-1');
      expect(detail.lines.map((l) => l.name), ['第 1 季', '第 2 季', '第 3 季']);
      expect(
        detail.lines[0].episodes.map((e) => e.name),
        ['第一集', '第二集'],
      );
      expect(detail.lines[1].episodes, isEmpty);
      expect(detail.lines[2].episodes, isEmpty);
      expect(detail.usable, isTrue);
      expect(
        fetcher.seenUrls.any((u) => u.contains('seasonId=s2')),
        isFalse,
      );
      expect(
        fetcher.seenUrls.any((u) => u.contains('seasonId=s3')),
        isFalse,
      );
    });

    test('seasonEpisodes loads one season on demand', () async {
      final fetcher = _CannedFetcher({
        'seasonId=s2': okJson({
          'Items': [
            embyItem(id: 'e3', type: 'Episode', name: '第三集', indexNumber: 3),
          ],
        }),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final eps = await client.seasonEpisodes('series-1', 's2');
      expect(eps.map((e) => e.name), ['第三集']);
      expect(eps.single.url, contains('/Videos/e3/stream?static=true'));
    });

    test('empty first season falls through to the next one', () async {
      final fetcher = _CannedFetcher({
        '/Items/series-1': okJson(
          embyItem(id: 'series-1', type: 'Series', name: '剧'),
        ),
        '/Seasons': okJson({
          'Items': [
            embyItem(id: 's1', type: 'Season', name: '第一季', indexNumber: 1),
            embyItem(id: 's2', type: 'Season', name: '第二季', indexNumber: 2),
          ],
        }),
        'seasonId=s1': okJson({'Items': []}),
        'seasonId=s2': okJson({
          'Items': [
            embyItem(id: 'e1', type: 'Episode', name: '第一集', indexNumber: 1),
          ],
        }),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final detail = await client.detail('series-1');
      expect(detail.lines[0].episodes, isEmpty);
      expect(detail.lines[1].episodes.map((e) => e.name), ['第一集']);
      expect(detail.usable, isTrue);
    });
  });

  group('server sync writes', () {
    test('progress/start/stop/played/favorite/rating endpoints + header auth',
        () async {
      final mutator = _CannedMutator();
      final client = EmbyClient(
        config: _config,
        fetcher: _CannedFetcher({}).call,
        mutator: mutator.call,
      );
      expect(
        await client.reportPlaybackStart('ep-1', positionSeconds: 30),
        isTrue,
      );
      expect(
        await client.reportPlaybackProgress(
          'ep-1',
          positionSeconds: 90,
        ),
        isTrue,
      );
      expect(await client.reportPlaybackStopped('ep-1'), isTrue);
      expect(await client.markPlayed('ep-1'), isTrue);
      expect(await client.setFavorite('m1', true), isTrue);
      expect(await client.setFavorite('m1', false), isTrue);
      expect(await client.rateItem('m1', likes: true), isTrue);
      expect(await client.rateItem('m1', likes: false), isTrue);
      expect(await client.clearRating('m1'), isTrue);

      final urls = mutator.seen.map((s) => s.$2).toList();
      final methods = mutator.seen.map((s) => s.$1).toList();
      expect(urls[0], contains('/Users/user-1/PlayingItems/ep-1?'));
      expect(urls[0], contains('PositionTicks=300000000'));
      expect(urls[1], contains('/PlayingItems/ep-1/Progress?'));
      expect(urls[1], contains('PositionTicks=900000000'));
      expect(methods[2], 'DELETE');
      expect(urls[2], contains('/PlayingItems/ep-1'));
      expect(urls[3], contains('/PlayedItems/ep-1'));
      expect(methods[4], 'POST');
      expect(urls[4], contains('/FavoriteItems/m1'));
      expect(methods[5], 'DELETE');
      expect(urls[5], contains('/FavoriteItems/m1'));
      expect(urls[6], contains('/Items/m1/Rating?likes=true'));
      expect(urls[7], contains('/Items/m1/Rating?likes=false'));
      expect(methods[8], 'DELETE');
      expect(urls[8], contains('/Items/m1/Rating'));
      // Key in the header, never in any mutating URL.
      expect(urls.every((u) => !u.contains('test-key-123')), isTrue);
      expect(
        mutator.seenHeaders.every(
          (h) => h?['X-Emby-Token'] == 'test-key-123',
        ),
        isTrue,
      );
    });

    test('server error => false, never throws', () async {
      final mutator = _CannedMutator(statusCode: 500);
      final client = EmbyClient(
        config: _config,
        fetcher: _CannedFetcher({}).call,
        mutator: mutator.call,
      );
      expect(await client.reportPlaybackProgress('ep-1', positionSeconds: 5),
          isFalse);
      expect(await client.markPlayed('ep-1'), isFalse);
      expect(await client.setFavorite('m1', true), isFalse);
    });

    test('userData: 200 parses, 404 returns null', () async {
      final fetcher = _CannedFetcher({
        '/Items/m1': okJson({
          'UserData': {
            'PlaybackPositionTicks': 600000000,
            'Played': true,
            'IsFavorite': true,
          },
        }),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final data = await client.userData('m1');
      expect(data?.playbackPositionSeconds, 60);
      expect(data?.played, isTrue);
      expect(data?.isFavorite, isTrue);
      expect(await client.userData('gone'), isNull);
    });

    test('episodeIdFromStreamUrl parses our own stream URLs', () {
      expect(
        EmbyClient.episodeIdFromStreamUrl(
          'http://127.0.0.1:8096/emby/Videos/abc-123/stream?static=true&api_key=x',
        ),
        'abc-123',
      );
      expect(
        EmbyClient.episodeIdFromStreamUrl('https://example.com/ep1.mp4'),
        isNull,
      );
      expect(EmbyClient.episodeIdFromStreamUrl('not a url'), isNull);
    });
  });
}
