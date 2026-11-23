// Regression tests for the hardened network parsers (build 31 crash
// hunt). Each test feeds a server response whose values are the WRONG
// type — the exact shape that used to throw TypeError via
// `(x['f'] as num?)` / `(x['f'] as String?)` inside a parse that the
// callers only guard with `on DioException` / `on EmbyException`
// (so the TypeError escaped and killed the page load).

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/video/cms_client.dart';
import 'package:standalone/services/video/douban_parsers.dart';
import 'package:standalone/services/video/vod_danmaku_client.dart';

void main() {
  group('parseCmsDetail', () {
    test('list rows of the wrong type return null, never throw', () {
      const src = VideoSource(id: 1, name: 't', apiUrl: 'https://x');
      expect(parseCmsDetail(src, 'v1', {'list': 'nope'}), isNull);
      expect(parseCmsDetail(src, 'v1', {'list': ['not a map']}), isNull);
      expect(parseCmsDetail(src, 'v1', {'list': [42]}), isNull);
      expect(parseCmsDetail(src, 'v1', {'list': []}), isNull);
    });

    test('wrong-typed fields inside a row fall back', () {
      const src = VideoSource(id: 1, name: 't', apiUrl: 'https://x');
      final d = parseCmsDetail(src, 'v1', {
        'list': [
          {
            'vod_name': 123,
            'vod_pic': true,
            'vod_hits': '100',
            'vod_play_url': 'ep1\$http://x/1.m3u8',
            'vod_play_from': 'play',
            'vod_content': 5,
          },
        ],
      });
      expect(d, isNotNull);
      expect(d!.meta.name, '');
      expect(d.meta.score, '');
      expect(d.lines.length, 1);
      expect(d.lines.first.episodes.length, 1);
    });
  });

  group('MusicApi album parsers', () {
    test('parseWyAlbums with wrong-typed fields never throws', () {
      final out = MusicApi.parseWyAlbums({
        'albums': [
          {
            'id': 123,
            'name': 456,
            'picUrl': true,
            'artist': 'not a map',
            'publishTime': 'bad',
            'size': '10',
          },
          {
            'id': 'a2',
            'name': 'Good',
            'publishTime': 1700000000000,
            'size': 12,
          },
          'not a map',
        ],
      });
      expect(out.length, 2);
      // Numeric id/name stringify to non-empty, so the row survives
      // with defaulted numerics.
      expect(out.first.id, '123');
      expect(out.first.publishTime, 0);
      expect(out.first.songCount, 0);
      expect(out[1].id, 'a2');
      expect(out[1].publishTime, 1700000000000);
      expect(out[1].songCount, 12);
    });

    test('parseTxAlbums with wrong-typed fields never throws', () {
      final out = MusicApi.parseTxAlbums({
        'album': {
          'list': [
            {
              'name': 5,
              'mid': 6,
              'singer': 'not a list',
              'id': 'bad',
              'total': '3',
            },
            {
              'name': 'Good',
              'mid': 'm1',
              'id': 77,
              'total': 4,
            },
          ],
        },
      });
      expect(out.length, 2);
      expect(out.first.name, '5');
      expect(out.first.songCount, 0);
      expect(out[1].name, 'Good');
      expect(out[1].songCount, 4);
      expect(MusicApi.parseTxAlbums({'album': 'not a map'}), isEmpty);
      expect(MusicApi.parseTxAlbums({}), isEmpty);
    });
  });

  group('parseDoubanAbstract', () {
    test('subject of the wrong type returns null, never throws', () {
      expect(parseDoubanAbstract({'subject': 'not a map'}), isNull);
      expect(parseDoubanAbstract({'subject': 42}), isNull);
      expect(parseDoubanAbstract(null), isNull);
      expect(parseDoubanAbstract({'r': 'error'}), isNull);
    });

    test('wrong-typed subject fields fall back', () {
      final d = parseDoubanAbstract({
        'subject': {
          'id': 123,
          'title': 5,
          'duration': 120,
          'directors': 'one person',
          'actors': [1, 2],
          'types': 'drama',
          'rate': 8.3,
          'release_year': 2024,
        },
      });
      expect(d, isNotNull);
      expect(d!.id, '123');
      expect(d.title, '');
      expect(d.director, '');
      expect(d.castNames, ['1', '2']);
      expect(d.genres, isEmpty);
      expect(d.score, '8.3');
    });
  });

  group('parseVodDanmakuCommentsJson', () {
    test('unparseable body returns [], never throws', () {
      expect(parseVodDanmakuCommentsJson('not json{'), isEmpty);
      expect(parseVodDanmakuCommentsJson('[]'), isEmpty);
      expect(parseVodDanmakuCommentsJson('{"count": 1}'), isEmpty);
    });

    test('bad comment entries are dropped, good ones kept', () {
      final out = parseVodDanmakuCommentsJson(
        '{"count": 3, "comments": ['
        '"not a map", '
        '{"m": 123, "t": "bad"}, '
        '{"m": "hello", "t": 1.5}'
        ']}',
      );
      expect(out.length, 1);
      expect(out.first.text, 'hello');
      expect(out.first.time, 1.5);
    });
  });
}
