// Emby client tests (build 28, audit §6.1 T1–T11 + T14).
//
// Hermetic: every test drives EmbyClient with an injected fetcher
// returning canned JSON — zero network. Fixture shapes come from the
// Emby API docs + the audit report (§2.2); the apiKey below is a
// FAKE fixture value ('test-key-123'), never a real credential.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/player/kernel/player_kernel.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';

const _config = EmbyServerConfig(
  baseUrl: 'http://127.0.0.1:8096',
  apiKey: 'test-key-123',
  userId: 'user-1',
);

/// Canned item JSON (Emby BaseItemDto shape, audit §2.2).
Map<String, dynamic> embyItem({
  required String id,
  required String type,
  String name = 'Test Film',
  int? year,
  double? rating,
  List<String>? genres,
  String? primaryTag,
  int? childCount,
  int? indexNumber,
  String? overview,
  int? runTimeTicks,
}) {
  return <String, dynamic>{
    'Id': id,
    'Name': name,
    'Type': type,
    'ProductionYear': ?year,
    'CommunityRating': ?rating,
    'Genres': ?genres,
    'ImageTags': ?(primaryTag == null ? null : {'Primary': primaryTag}),
    'ChildCount': ?childCount,
    'IndexNumber': ?indexNumber,
    'Overview': ?overview,
    'RunTimeTicks': ?runTimeTicks,
  };
}

/// Fetcher that answers by URL substring. Unmatched URLs 404.
/// Records every URL + the headers it was called with.
class CannedEmbyFetcher {
  CannedEmbyFetcher(this._answers);

  final Map<String, EmbyResponse> _answers;
  final List<String> seenUrls = [];
  final List<Map<String, String>?> seenHeaders = [];

  Future<EmbyResponse> call(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 8),
    CancelToken? cancelToken,
  }) async {
    seenUrls.add(url);
    seenHeaders.add(headers);
    if (cancelToken?.isCancelled == true) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.cancel,
      );
    }
    for (final entry in _answers.entries) {
      if (url.contains(entry.key)) return entry.value;
    }
    return const EmbyResponse(statusCode: 404, json: {});
  }
}

EmbyResponse okJson(dynamic json) =>
    EmbyResponse(statusCode: 200, json: json);

void main() {
  group('T1 probe three states', () {
    test('200 + ServerName/Version + users => ok', () async {
      final fetcher = CannedEmbyFetcher({
        '/System/Info': okJson({'ServerName': 'Home', 'Version': '4.8.0'}),
        '/Users': okJson({
          'Items': [
            {'Id': 'user-1', 'Name': 'chen'},
          ],
        }),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final result = await client.probe();
      expect(result.ok, isTrue);
      expect(result.serverName, 'Home');
      expect(result.version, '4.8.0');
      expect(result.users.map((u) => u.id), ['user-1']);
      // /emby prefix is tried first (official API root).
      expect(fetcher.seenUrls.first, contains('/emby/System/Info'));
      // Auth rides the header, never the URL.
      expect(fetcher.seenHeaders.first?['X-Emby-Token'], 'test-key-123');
      expect(fetcher.seenUrls.every((u) => !u.contains('api_key')), isTrue);
    });

    test('401 => key wrong, distinct message', () async {
      final fetcher = CannedEmbyFetcher({
        '/System/Info': const EmbyResponse(statusCode: 401, json: {}),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final result = await client.probe();
      expect(result.ok, isFalse);
      expect(result.errorKind, EmbyErrorKind.unauthorized);
      expect(result.errorMessage, 'Emby 密钥不对，请在设置里重新填写');
    });

    test('connection failure => unreachable, distinct message', () async {
      Future<EmbyResponse> failing(
        String url, {
        Map<String, String>? headers,
        Duration timeout = const Duration(seconds: 8),
        CancelToken? cancelToken,
      }) async {
        throw EmbyException.unreachable();
      }

      final client = EmbyClient(config: _config, fetcher: failing);
      final result = await client.probe();
      expect(result.ok, isFalse);
      expect(result.errorKind, EmbyErrorKind.unreachable);
      expect(result.errorMessage, '连不上 Emby 服务器，检查地址和网络');
    });

    test('404 on /emby falls back to root', () async {
      final fetcher = CannedEmbyFetcher({
        '/emby/System/Info':
            const EmbyResponse(statusCode: 404, json: {}),
        '/System/Info': okJson({'ServerName': 'Root', 'Version': '4.7.0'}),
        '/Users': okJson({'Items': []}),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final result = await client.probe();
      expect(result.ok, isTrue);
      expect(result.serverName, 'Root');
      expect(fetcher.seenUrls.any((u) => u.contains('/emby/System/Info')),
          isTrue);
      expect(
        fetcher.seenUrls.any(
          (u) => !u.contains('/emby') && u.contains('/System/Info'),
        ),
        isTrue,
      );
    });
  });

  group('T2 Views filter', () {
    test('only movies/tvshows libraries survive', () async {
      final fetcher = CannedEmbyFetcher({
        '/Views': okJson({
          'Items': [
            {'Id': 'm1', 'Name': '电影', 'CollectionType': 'movies'},
            {'Id': 't1', 'Name': '剧集', 'CollectionType': 'tvshows'},
            {'Id': 'mu1', 'Name': '音乐', 'CollectionType': 'music'},
            {'Id': 'p1', 'Name': '照片', 'CollectionType': 'photos'},
            {'Id': 'x1', 'Name': '无类型'},
          ],
        }),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final libs = await client.libraries();
      expect(libs.map((l) => l.id), ['m1', 't1']);
    });
  });

  group('T3/T4 type mapping + missing-field tolerance', () {
    test('unknown Type skipped, missing fields do not throw', () async {
      final fetcher = CannedEmbyFetcher({
        '/Items': okJson({
          'Items': [
            embyItem(id: 'a', type: 'Movie', primaryTag: 'tag-a'),
            // No ImageTags / Overview / rating / ChildCount at all.
            embyItem(id: 'b', type: 'Series'),
            embyItem(id: 'c', type: 'Trailer'),
            embyItem(id: 'd', type: 'Weird'),
          ],
          'TotalRecordCount': 4,
        }),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final page = await client.movies();
      expect(page.items.map((i) => i.vodId), ['a', 'b']);
      expect(page.items.first.pic, contains('maxWidth=400'));
      expect(page.items.first.pic, contains('tag-a'));
      final bare = page.items[1];
      expect(bare.pic, isEmpty);
      expect(bare.score, isEmpty);
      expect(bare.year, isEmpty);
      expect(bare.type, isEmpty);
    });
  });

  group('T5 season/episode sort', () {
    test('IndexNumber order, missing goes last', () async {
      final fetcher = CannedEmbyFetcher({
        '/Items/series-1': okJson(
          embyItem(id: 'series-1', type: 'Series', name: '剧'),
        ),
        '/Seasons': okJson({
          'Items': [
            embyItem(id: 's3', type: 'Season', name: '第三季', indexNumber: 3),
            embyItem(id: 's1', type: 'Season', name: '第一季', indexNumber: 1),
            embyItem(id: 'sX', type: 'Season', name: '特别篇'),
            embyItem(id: 's2', type: 'Season', name: '第二季', indexNumber: 2),
          ],
        }),
        'seasonId=s1': okJson({
          'Items': [
            embyItem(id: 'e2', type: 'Episode', name: '第二集', indexNumber: 2),
            embyItem(id: 'e1', type: 'Episode', name: '第一集', indexNumber: 1),
            embyItem(id: 'eX', type: 'Episode', name: '彩蛋'),
          ],
        }),
        'seasonId=s2': okJson({'Items': []}),
        'seasonId=s3': okJson({'Items': []}),
        'seasonId=sX': okJson({'Items': []}),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final detail = await client.detail('series-1');
      // Lazy (1.1.6): every season gets a line, but only the first
      // season with episodes is fetched eagerly — the other seasons'
      // lines start empty ("not loaded yet", not "missing") and the
      // detail page loads them on demand. Empty seasons are no
      // longer dropped from the line list.
      expect(
        detail.lines.map((l) => l.name),
        ['第 1 季', '第 2 季', '第 3 季', '特别篇'],
      );
      expect(
        detail.lines.first.episodes.map((e) => e.name),
        ['第一集', '第二集', '彩蛋'],
      );
      expect(detail.lines[1].episodes, isEmpty);
      expect(detail.usable, isTrue);
    });
  });

  group('T6 detail mapping', () {
    test('movie => 1 line 直链 + 1 episode 正片', () async {
      final fetcher = CannedEmbyFetcher({
        '/Items/movie-1': okJson(
          embyItem(
            id: 'movie-1',
            type: 'Movie',
            name: '片名',
            year: 2024,
            rating: 8.5,
            genres: ['剧情', '爱情'],
            primaryTag: 'tag-m',
            overview: '简介',
            runTimeTicks: 600000000 * 125,
          ),
        ),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final detail = await client.detail('movie-1');
      expect(detail.source, EmbyClient.sourceId);
      expect(detail.meta.name, '片名');
      expect(detail.meta.year, '2024');
      expect(detail.meta.score, '8.5');
      expect(detail.meta.content, '简介');
      expect(detail.meta.runtime, 125);
      expect(detail.meta.pic, contains('maxWidth=800'));
      expect(detail.lines.length, 1);
      expect(detail.lines.first.name, '直链');
      expect(detail.lines.first.episodes.length, 1);
      expect(detail.lines.first.episodes.first.name, '正片');
      expect(
        detail.lines.first.episodes.first.url,
        contains('/Videos/movie-1/stream?static=true'),
      );
      expect(detail.usable, isTrue);
    });

    test('detail 404 => film-gone message, not the CMS wording', () async {
      final fetcher = CannedEmbyFetcher({
        '/Items/gone': const EmbyResponse(statusCode: 404, json: {}),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      await expectLater(
        client.detail('gone'),
        throwsA(
          isA<EmbyException>()
              .having((e) => e.kind, 'kind', EmbyErrorKind.notFound)
              .having(
                (e) => e.message,
                'message',
                '这部影片在 Emby 里找不到了',
              ),
        ),
      );
    });
  });

  group('T7 search', () {
    test('searchTerm in URL, title results back', () async {
      final fetcher = CannedEmbyFetcher({
        '/Items': okJson({
          'Items': [
            embyItem(id: 'm1', type: 'Movie', name: '流浪地球'),
          ],
          'TotalRecordCount': 1,
        }),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      final results = await client.search('流浪地球');
      expect(results.map((i) => i.vodId), ['m1']);
      expect(fetcher.seenUrls.single, contains('searchTerm='));
      expect(
        fetcher.seenUrls.single,
        contains(Uri.encodeComponent('流浪地球')),
      );
      expect(
        fetcher.seenUrls.single,
        contains('IncludeItemTypes=Movie%2CSeries%2CEpisode'),
      );
    });
  });

  group('T8 image URLs', () {
    test('sizes per surface, no tag param without tag, no api_key',
        () async {
      final client = EmbyClient(config: _config, fetcher: (url,
          {headers, timeout = const Duration(seconds: 8), cancelToken}) async {
        throw UnimplementedError('no network in this test');
      });
      final list = client.imageUrl('abc', maxWidth: 400, tag: 't1');
      expect(list, contains('maxWidth=400'));
      expect(list, contains('tag=t1'));
      expect(list, isNot(contains('api_key')));

      final noTag = client.imageUrl('abc', maxWidth: 400);
      expect(noTag, isNot(contains('tag=')));

      final detail = client.imageUrl('abc', maxWidth: 800, tag: 't1');
      expect(detail, contains('maxWidth=800'));

      final backdrop = client.imageUrl(
        'abc',
        maxWidth: 1280,
        tag: 'tb',
        type: 'Backdrop',
      );
      expect(backdrop, contains('Images/Backdrop'));
      expect(backdrop, contains('maxWidth=1280'));
      expect(backdrop, isNot(contains('api_key')));
    });
  });

  group('T9 stream URL', () {
    test('static direct-stream shape, format unknown, all engines can play',
        () {
      final client = EmbyClient(config: _config, fetcher: (url,
          {headers, timeout = const Duration(seconds: 8), cancelToken}) async {
        throw UnimplementedError('no network in this test');
      });
      final url = client.streamUrl('movie-1');
      expect(
        url,
        'http://127.0.0.1:8096/emby/Videos/movie-1/stream'
        '?static=true&api_key=test-key-123',
      );
      expect(formatOf(url: url), StreamFormat.unknown);
      for (final engine in PlayerEngine.values) {
        expect(engineCanPlay(engine, StreamFormat.unknown), isTrue);
      }
    });
  });

  group('T10 cancel is not a failure', () {
    test('cancelled fetch rethrows Dio cancel, not EmbyException',
        () async {
      Future<EmbyResponse> cancelling(
        String url, {
        Map<String, String>? headers,
        Duration timeout = const Duration(seconds: 8),
        CancelToken? cancelToken,
      }) async {
        throw DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
        );
      }

      final client = EmbyClient(config: _config, fetcher: cancelling);
      await expectLater(
        client.movies(),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
    });
  });

  group('T11 timeout surfaces as unreachable, never hangs', () {
    test('transport timeout => human unreachable error', () async {
      Future<EmbyResponse> timingOut(
        String url, {
        Map<String, String>? headers,
        Duration timeout = const Duration(seconds: 8),
        CancelToken? cancelToken,
      }) async {
        // What defaultEmbyFetcher throws on a Dio timeout.
        throw EmbyException.unreachable();
      }

      final client = EmbyClient(config: _config, fetcher: timingOut);
      await expectLater(
        client.movies(),
        throwsA(
          isA<EmbyException>()
              .having((e) => e.kind, 'kind', EmbyErrorKind.unreachable)
              .having(
                (e) => e.message,
                'message',
                '连不上 Emby 服务器，检查地址和网络',
              ),
        ),
      );
    });
  });

  group('T14 credentials never leak', () {
    test('config toString, exceptions and image URLs carry no key',
        () async {
      expect(_config.toString(), isNot(contains('test-key-123')));
      expect(
        EmbyException.unreachable().toString(),
        isNot(contains('test-key-123')),
      );
      expect(
        EmbyException.unauthorized().toString(),
        isNot(contains('test-key-123')),
      );

      final fetcher = CannedEmbyFetcher({
        '/Items/gone': const EmbyResponse(statusCode: 404, json: {}),
      });
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      try {
        await client.detail('gone');
        fail('expected EmbyException');
      } on EmbyException catch (e) {
        expect(e.message, isNot(contains('test-key-123')));
        expect(e.message, isNot(contains('api_key')));
        expect(e.toString(), isNot(contains('test-key-123')));
      }
      // Every URL the client asked for (except the stream URL, which
      // is never fetched by the client and never logged) is key-free.
      expect(
        fetcher.seenUrls.every((u) => !u.contains('test-key-123')),
        isTrue,
      );
    });
  });
}
