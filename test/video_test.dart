// Video feature tests — CMS parsing, detail race/timeout, Douban
// id resolution parsing, episode parsing, title helpers.
//
// Pure-Dart rules that must never regress:
// - CMS list/detail parsing from canned JSON (no network).
// - Detail race: slow first source + fast alt wins; nothing usable
//   within the windows -> null (error card at ~4 s, never 12 s).
// - Douban id resolution: suggest JSON, desktop search HTML, abstract
//   JSON, mobile page HTML; verified fixture 流浪地球2 -> 35267208 (8.3).
// - Episode parsing: $$$ / # / first-$ split, m3u8 preference,
//   empty name -> 正片, non-CJK line name -> 线路N.
// - Title helpers: normTitle / stripSeasonSuffix / rankSort parity.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/features/video/video_detail_service.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/features/video/video_title_helpers.dart';
import 'package:standalone/services/video/cms_client.dart';
import 'package:standalone/services/video/douban_parsers.dart';
import 'package:standalone/services/video/douban_service.dart';

const _goldSource = VideoSource(
  id: 12,
  name: '金鹰资源',
  apiUrl: 'http://jyzyapi.com/api.php/provide/vod',
  kind: 'play',
  sort: 5,
);

/// Canned CMS search-list JSON (shape from a real 金鹰 response).
Map<String, dynamic> cannedSearchJson() => {
      'code': 1,
      'msg': '数据列表',
      'page': '1',
      'pagecount': 1,
      'limit': '20',
      'total': 2,
      'list': [
        {
          'vod_id': 93344,
          'type_id': 31,
          'vod_name': '流浪地球2',
          'vod_pic': 'https://image.example.com/cover.jpg',
          'type_name': '科幻片',
          'vod_year': '2023',
          'vod_area': '大陆',
          'vod_score': '8.3',
          'vod_total': '1',
          'vod_remarks': '正片',
          'vod_hits': 12345,
        },
        {
          'vod_id': 93345,
          'type_id': 31,
          'vod_name': '流浪地球2(2023)',
          'vod_pic': 'https://image.example.com/cover2.jpg',
          'type_name': '科幻片',
          'vod_year': '2023',
          'vod_area': '大陆',
          'vod_score': '9.1',
          'vod_total': '1',
          'vod_remarks': '正片',
          'vod_hits': 99,
        },
      ],
    };

/// Canned CMS detail JSON: two lines, one m3u8, one mp4.
Map<String, dynamic> cannedDetailJson() => {
      'code': 1,
      'list': [
        {
          'vod_id': 93344,
          'vod_name': '流浪地球2',
          'vod_pic': 'https://image.example.com/cover.jpg',
          'type_name': '科幻片',
          'vod_year': '2023',
          'vod_area': '大陆',
          'vod_score': '8.3',
          'vod_actor': '吴京,刘德华',
          'vod_director': '郭帆',
          'vod_content': '<p>太阳即将毁灭，人类开启流浪地球计划。</p>',
          'vod_play_from': '线路1\$\$\$线路2',
          'vod_play_url':
              '正片\$https://cdn.example.com/wandering2.m3u8\$\$\$正片\$https://cdn.example.com/wandering2.mp4',
        },
      ],
    };

VideoDetail usableDetail(dynamic source, String vodId) => VideoDetail(
      source: source,
      vodId: vodId,
      meta: VideoMeta(name: '流浪地球2', year: '2023'),
      lines: const [
        PlayLine(
          name: '线路1',
          episodes: [
            PlayEpisode(name: '正片', url: 'https://cdn.example.com/1.m3u8'),
          ],
        ),
      ],
    );

void main() {
  group('CMS list parsing (canned JSON)', () {
    test('search list maps vod_* fields', () {
      final json = cannedSearchJson();
      final items = (json['list'] as List)
          .map((x) => parseCmsVideoItem(_goldSource, x as Map<String, dynamic>))
          .toList();
      expect(items, hasLength(2));
      expect(items[0].vodId, '93344');
      expect(items[0].name, '流浪地球2');
      expect(items[0].pic, 'https://image.example.com/cover.jpg');
      expect(items[0].type, '科幻片');
      expect(items[0].year, '2023');
      expect(items[0].score, '8.3');
      expect(items[0].hits, 12345);
      expect(items[0].source, 12);
      expect(items[0].sourceName, '金鹰资源');
    });

    test('probe accepts list[] / class[] / code 0', () {
      expect(isCmsProbeOk(cannedSearchJson()), isTrue);
      expect(isCmsProbeOk({'code': 0}), isTrue);
      expect(isCmsProbeOk({'class': []}), isTrue);
      expect(isCmsProbeOk({'code': 1, 'list': []}), isTrue);
      expect(isCmsProbeOk({'code': 1, 'msg': 'err'}), isFalse);
    });

    test('search dedupe + rank: exact title wins, higher score kept', () {
      final json = cannedSearchJson();
      final raw = (json['list'] as List)
          .map((x) => parseCmsVideoItem(_goldSource, x as Map<String, dynamic>))
          .toList();
      final out = CmsClient.dedupeAndRankSearch(raw, '流浪地球2');
      // Same normTitle|year -> one item; the exact-title duplicate
      // replaces the kept item's source fields, keeping higher score.
      expect(out, hasLength(1));
      expect(out[0].name, '流浪地球2');
      expect(out[0].score, '9.1');
    });
  });

  group('CMS detail parsing (canned JSON)', () {
    test('detail maps meta + prefers m3u8 lines', () {
      final detail = parseCmsDetail(_goldSource, '93344', cannedDetailJson());
      expect(detail, isNotNull);
      expect(detail!.meta.name, '流浪地球2');
      expect(detail.meta.actor, '吴京,刘德华');
      expect(detail.meta.director, '郭帆');
      // Only the m3u8 line survives the preference filter.
      expect(detail.lines, hasLength(1));
      expect(detail.lines[0].name, '线路1');
      expect(detail.lines[0].episodes, hasLength(1));
      expect(detail.lines[0].episodes[0].url,
          'https://cdn.example.com/wandering2.m3u8');
      expect(detail.usable, isTrue);
    });

    test('detail returns null when no lines parse', () {
      final detail = parseCmsDetail(_goldSource, '1', {
        'list': [
          {
            'vod_id': 1,
            'vod_name': '空片',
            'vod_play_from': '',
            'vod_play_url': '',
            'vod_content': 'no stream here',
          },
        ],
      });
      expect(detail, isNull);
    });

    test('content m3u8 fallback synthesises a 直链 line', () {
      final detail = parseCmsDetail(_goldSource, '1', {
        'list': [
          {
            'vod_id': 1,
            'vod_name': '直链片',
            'vod_play_from': '',
            'vod_play_url': '',
            'vod_content': 'see https://cdn.example.com/x.m3u8 here',
          },
        ],
      });
      expect(detail, isNotNull);
      expect(detail!.lines, hasLength(1));
      expect(detail.lines[0].name, '直链');
      expect(detail.lines[0].episodes[0].url,
          'https://cdn.example.com/x.m3u8');
    });
  });

  group('Episode / line parsing (parsePlayLines)', () {
    test('splits \$\$\$ lines, # episodes, first \$', () {
      final lines = parsePlayLines(
        '第01集\$https://a.com/1.mp4#第02集\$https://a.com/2.mp4\$\$\$第01集\$https://b.com/1.mp4',
        '线路A\$\$\$线路B',
      );
      expect(lines, hasLength(2));
      expect(lines[0].name, '线路A');
      expect(lines[0].episodes, hasLength(2));
      expect(lines[0].episodes[1].name, '第02集');
      // URL containing $ splits on the FIRST $ only.
      final tricky = parsePlayLines(
        '正片\$https://a.com/x\$y.mp4',
        '线路1',
      );
      expect(tricky[0].episodes[0].url, 'https://a.com/x\$y.mp4');
    });

    test('empty episode name becomes 正片', () {
      final lines = parsePlayLines('\$https://a.com/1.mp4', '线路1');
      expect(lines[0].episodes[0].name, '正片');
    });

    test('non-CJK line name becomes 线路N', () {
      final lines = parsePlayLines(
        '第01集\$https://a.com/1.mp4',
        'HD',
      );
      expect(lines[0].name, '线路1');
    });

    test('m3u8 lines win over mp4-only lines', () {
      final lines = parsePlayLines(
        '第01集\$https://a.com/1.mp4\$\$\$第01集\$https://b.com/1.m3u8',
        '线路1\$\$\$线路2',
      );
      expect(lines, hasLength(1));
      expect(lines[0].name, '线路2');
    });

    test('all-mp4 returns all lines', () {
      final lines = parsePlayLines(
        '第01集\$https://a.com/1.mp4\$\$\$第01集\$https://b.com/1.mp4',
        '线路1\$\$\$线路2',
      );
      expect(lines, hasLength(2));
    });

    test('episodes without \$ are skipped', () {
      final lines = parsePlayLines('garbage#第01集\$https://a.com/1.mp4', '线路1');
      expect(lines[0].episodes, hasLength(1));
    });
  });

  group('Title helpers', () {
    test('videoNormTitle strips parenthesised year + bare quality', () {
      expect(videoNormTitle('流浪地球2 (2023)'), '流浪地球2');
      expect(videoNormTitle('哪吒之魔童闹海（2025）'), '哪吒之魔童闹海');
      expect(videoNormTitle('狂飙 4K'), '狂飙');
      expect(videoNormTitle('庆余年 高清'), '庆余年');
      expect(videoNormTitle('流浪地球2'), '流浪地球2');
    });

    test('videoQueryParts extracts trailing year', () {
      final p = videoQueryParts('流浪地球2 2023');
      expect(p.qn, '流浪地球2');
      expect(p.year, 2023);
      final p2 = videoQueryParts('庆余年');
      expect(p2.qn, '庆余年');
      expect(p2.year, 0);
    });

    test('vodStripSeasonSuffix strips season markers (search only)', () {
      expect(vodStripSeasonSuffix('庆余年 第一季').base, '庆余年');
      expect(vodStripSeasonSuffix('庆余年第二季').base, '庆余年');
      expect(vodStripSeasonSuffix('庆余年 (第2季)').base, '庆余年');
      expect(vodStripSeasonSuffix('Show Season 2').base, 'Show');
      expect(vodStripSeasonSuffix('Show S2').base, 'Show');
      expect(vodStripSeasonSuffix('庆余年').stripped, isFalse);
    });

    test('videoRankSort: exact match first, then year desc', () {
      final items = [
        VideoItem(
          source: 12,
          sourceName: '金鹰',
          vodId: '2',
          name: '流浪地球2前传',
          year: '2024',
          score: '9.9',
        ),
        VideoItem(
          source: 12,
          sourceName: '金鹰',
          vodId: '1',
          name: '流浪地球2',
          year: '2023',
          score: '8.3',
        ),
        VideoItem(
          source: 12,
          sourceName: '金鹰',
          vodId: '3',
          name: '流浪地球',
          year: '2019',
          score: '7.9',
        ),
      ];
      videoRankSort(items, '流浪地球2');
      expect(items[0].vodId, '1');
      expect(items[1].vodId, '2');
    });
  });

  group('Detail race / timeout (VideoDetailService)', () {
    test('fast first fetch wins immediately', () async {
      final service = VideoDetailService(
        fetchDetail: (s, v) async => usableDetail(s, v),
        findAlts: (_, _, _) async => [],
      );
      final r = await service.loadWithRace(12, '1');
      expect(r, isNotNull);
      expect(r!.switchedSource, isFalse);
      expect(r.detail.meta.name, '流浪地球2');
    });

    test('slow first + fast alt: alt wins, result cached', () async {
      final service = VideoDetailService(
        fetchDetail: (s, v) async {
          if (s.toString() == '12') {
            await Future<void>.delayed(const Duration(seconds: 4));
            return usableDetail(s, v);
          }
          return usableDetail(s, v);
        },
        findAlts: (_, _, _) async =>
            [const AltVideoSource(source: 6, vodId: '2')],
      );
      final stopwatch = Stopwatch()..start();
      final r = await service.loadWithRace(
        12,
        '1',
        preload: const VideoItem(
          source: 12,
          sourceName: '金鹰',
          vodId: '1',
          name: '流浪地球2',
          year: '2023',
        ),
      );
      stopwatch.stop();
      expect(r, isNotNull);
      expect(r!.switchedSource, isTrue);
      expect(r.sourceId.toString(), '6');
      expect(r.vodId, '2');
      // Won inside the race windows (~3.5 s + alt fetch), not after a
      // 12 s stare.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 8)));
    });

    test('nothing usable within the windows -> null (error card)', () async {
      final service = VideoDetailService(
        fetchDetail: (_, _) async {
          throw StateError('boom');
        },
        findAlts: (_, _, _) async => [],
      );
      final stopwatch = Stopwatch()..start();
      final r = await service.loadWithRace(
        12,
        '1',
        preload: const VideoItem(
          source: 12,
          sourceName: '金鹰',
          vodId: '1',
          name: '不存在的片',
        ),
      );
      stopwatch.stop();
      expect(r, isNull);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 8)));
    });

    test('result cache: second get reuses the first fetch', () async {
      var calls = 0;
      final service = VideoDetailService(
        fetchDetail: (s, v) async {
          calls++;
          return usableDetail(s, v);
        },
        findAlts: (_, _, _) async => [],
      );
      final a = await service.get(12, '1');
      final b = await service.get(12, '1');
      expect(identical(a, b), isTrue);
      expect(calls, 1);
    });

    test('pending cache: concurrent gets share one fetch', () async {
      var calls = 0;
      final service = VideoDetailService(
        fetchDetail: (s, v) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return usableDetail(s, v);
        },
        findAlts: (_, _, _) async => [],
      );
      final results = await Future.wait([
        service.get(12, '1'),
        service.get(12, '1'),
      ]);
      expect(results[0], same(results[1]));
      expect(calls, 1);
    });
  });

  group('Douban id resolution parsing', () {
    test('suggest JSON: first id wins', () {
      final json = [
        {
          'id': '35267208',
          'title': '流浪地球2',
          'type': 'movie',
          'year': '2023',
        },
      ];
      expect(parseDoubanSuggestId(json), '35267208');
      expect(parseDoubanSuggestId([]), isNull);
      expect(parseDoubanSuggestId({'id': '1'}), isNull);
    });

    test('desktop search HTML: sid: first, then subject URL', () {
      expect(
        parseDoubanSearchPageId('<div>sid: 25853071</div>'),
        '25853071',
      );
      expect(
        parseDoubanSearchPageId(
          '<a href="https://movie.douban.com/subject/1292052/">x</a>',
        ),
        '1292052',
      );
      expect(parseDoubanSearchPageId('<div>nothing here</div>'), isNull);
    });

    test('abstract JSON: 流浪地球2 -> 35267208, 8.3, 郭帆', () {
      final d = parseDoubanAbstract({
        'r': 0,
        'subject': {
          'id': 35267208,
          'title': '流浪地球2',
          'rate': '8.3',
          'release_year': '2023',
          'is_tv': false,
          'episodes_count': '',
          'directors': ['郭帆'],
          'actors': ['吴京', '刘德华'],
          'types': ['科幻', '冒险', '灾难'],
          'region': '中国大陆',
          'duration': '172分钟',
        },
      });
      expect(d, isNotNull);
      expect(d!.id, '35267208');
      expect(d.score, '8.3');
      expect(d.year, '2023');
      expect(d.media, 'movie');
      expect(d.director, '郭帆');
      expect(d.castNames, ['吴京', '刘德华']);
      expect(d.genres, ['科幻', '冒险', '灾难']);
      expect(d.countries, ['中国大陆']);
      expect(d.runtime, 172);
    });

    test('abstract returns null on r=error or missing subject', () {
      expect(parseDoubanAbstract({'r': 'error'}), isNull);
      expect(parseDoubanAbstract({}), isNull);
      expect(parseDoubanAbstract(null), isNull);
    });

    test('mobile page HTML: poster + overview + score', () {
      const html = '''
<html><head>
<meta property="og:image" content="https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2916835424.jpg">
<meta itemprop="description" content="豆瓣评分：8.3 简介：太阳即将毁灭，人类开启流浪计划。">
<meta itemprop="ratingValue" content="8.3">
</head><body>
<img src="https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2916835424.jpg">
</body></html>''';
      final mp = parseDoubanMPage(html);
      expect(
        mp.poster,
        'https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2916835424.jpg',
      );
      expect(mp.overview, '太阳即将毁灭，人类开启流浪计划。');
      expect(mp.score, '8.3');
    });

    test('mobile page falls back to raw og:image when no s_ratio match',
        () {
      const html = '''
<meta property="og:image" content="https://img1.doubanio.com/view/photo/m/public/p123.jpg">
''';
      final mp = parseDoubanMPage(html);
      expect(
        mp.poster,
        'https://img1.doubanio.com/view/photo/m/public/p123.jpg',
      );
      expect(mp.overview, '');
      expect(mp.score, isNull);
    });

    test('doubanTitleKey: season-stripped, no spaces, lowercase', () {
      expect(doubanTitleKey('庆余年 第一季'), '庆余年');
      expect(doubanTitleKey('The Wandering Earth 2'), 'thewanderingearth2');
    });

    test('mergeDoubanIntoMeta: score/poster win, rest fills gaps', () {
      final meta = VideoMeta(
        name: '流浪地球2',
        pic: 'https://cms.example.com/cover.jpg',
        year: '',
        type: '',
        actor: '',
        content: '短',
      );
      final dd = DoubanDetail(
        id: '35267208',
        media: 'movie',
        title: '流浪地球2',
        year: '2023',
        poster: 'https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2916835424.jpg',
        overview: '太阳即将毁灭，人类开启流浪计划。',
        score: '8.3',
        genres: ['科幻', '冒险'],
        director: '郭帆',
        castNames: ['吴京', '刘德华'],
      );
      mergeDoubanIntoMeta(meta, dd);
      expect(meta.score, '8.3');
      expect(meta.pic, dd.poster);
      expect(meta.picAlt, 'https://cms.example.com/cover.jpg');
      expect(meta.year, '2023');
      expect(meta.type, '科幻/冒险');
      expect(meta.director, '郭帆');
      expect(meta.actor, '吴京,刘德华');
      expect(meta.content, '太阳即将毁灭，人类开启流浪计划。');
      expect(meta.douban?.id, '35267208');
    });

    test('merge does not overwrite existing CMS content', () {
      final meta = VideoMeta(
        name: '流浪地球2',
        pic: 'https://cms.example.com/cover.jpg',
        year: '2023',
        type: '科幻片',
        actor: '吴京',
        content: '这是一段超过二十个字的 CMS 剧情简介内容文本。',
      );
      final dd = DoubanDetail(
        id: '35267208',
        media: 'movie',
        title: '流浪地球2',
        year: '2022',
        overview: '豆瓣简介。',
        score: '8.3',
        genres: ['科幻'],
        director: '郭帆',
        castNames: ['刘德华'],
      );
      mergeDoubanIntoMeta(meta, dd);
      expect(meta.score, '8.3'); // score always wins
      expect(meta.year, '2023'); // fill-when-missing only
      expect(meta.type, '科幻片');
      expect(meta.actor, '吴京');
      expect(meta.content, '这是一段超过二十个字的 CMS 剧情简介内容文本。');
    });
  });

  group('Douban service (fake transport + memory cache)', () {
    test('resolveId: suggest -> cached; detail merges abstract + mpage',
        () async {
      var calls = 0;
      Future<({int status, String body})> fetcher(
        String url,
        Map<String, String> headers, {
        Duration timeout = const Duration(seconds: 10),
      }) async {
        calls++;
        if (url.contains('subject_suggest')) {
          return (
            status: 200,
            body:
                '[{"id":"35267208","title":"流浪地球2","type":"movie","year":"2023"}]',
          );
        }
        if (url.contains('subject_abstract')) {
          return (
            status: 200,
            body:
                '{"r":0,"subject":{"id":35267208,"title":"流浪地球2","rate":"8.3","release_year":"2023","is_tv":false,"directors":["郭帆"],"actors":["吴京"],"types":["科幻"],"region":"中国大陆","duration":"172分钟"}}',
          );
        }
        if (url.contains('m.douban.com')) {
          return (
            status: 200,
            body:
                '<meta property="og:image" content="https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2916835424.jpg"><meta itemprop="description" content="豆瓣评分：8.3 简介：太阳即将毁灭。"><meta itemprop="ratingValue" content="8.3">',
          );
        }
        return (status: 404, body: '');
      }

      final service = DoubanService(
        fetcher: fetcher,
        cache: MemoryDoubanCache(),
      );
      final id = await service.resolveId('流浪地球2');
      expect(id, '35267208');
      final callsAfterResolve = calls;
      // Second resolve hits the title->id cache: no new fetch.
      expect(await service.resolveId('流浪地球2'), '35267208');
      expect(calls, callsAfterResolve);

      final d = await service.detail('流浪地球2', '2023');
      expect(d, isNotNull);
      expect(d!.id, '35267208');
      expect(d.score, '8.3');
      expect(d.poster, contains('p2916835424.jpg'));
      expect(d.overview, '太阳即将毁灭。');
      expect(d.director, '郭帆');
    });

    test('403 blocks further Douban calls for 60 s', () async {
      var calls = 0;
      Future<({int status, String body})> fetcher(
        String url,
        Map<String, String> headers, {
        Duration timeout = const Duration(seconds: 10),
      }) async {
        calls++;
        return (status: 403, body: '');
      }

      final service = DoubanService(
        fetcher: fetcher,
        cache: MemoryDoubanCache(),
      );
      // Suggest returns null on 403 (no throw); abstract then 403s.
      final d = await service.detail('流浪地球2', '2023');
      expect(d, isNull);
      expect(service.blocked, isTrue);
      final callsAfterFirst = calls;
      // While blocked, detail() returns null without fetching.
      expect(await service.detail('流浪地球2', '2023'), isNull);
      expect(calls, callsAfterFirst);
    });
  });
}
