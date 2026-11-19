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
import 'package:standalone/features/video/video_detail_page.dart';
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

    test('search fans out in parallel: slow source cannot hold the search', () async {
      // 2026-11-17 (v1.0.6: 搜影片慢 + 片源不全): the old 3-worker
      // sequential queues made every search wait the full 6 s cap
      // and cut the tail sources off. Parallel fan-out returns on
      // the 3.5 s overall cap with whatever arrived.
      Map<String, dynamic> oneItem(String name, String id) => {
            'code': 1,
            'total': 1,
            'list': [
              {
                'vod_id': id,
                'vod_name': name,
                'vod_pic': 'https://image.example.com/$id.jpg',
                'type_name': '科幻片',
                'vod_year': '2023',
              },
            ],
          };
      final sources = [
        const VideoSource(id: 1, name: '快源A', apiUrl: 'https://a.example.com/api.php/provide/vod', sort: 1),
        const VideoSource(id: 2, name: '慢源', apiUrl: 'https://slow.example.com/api.php/provide/vod', sort: 2),
        const VideoSource(id: 3, name: '快源B', apiUrl: 'https://b.example.com/api.php/provide/vod', sort: 3),
      ];
      Future<Map<String, dynamic>> fetcher(String url, {Duration timeout = const Duration(seconds: 8)}) async {
        if (url.contains('slow.example.com')) {
          await Future<void>.delayed(const Duration(seconds: 10));
          return oneItem('慢片', '99');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (url.contains('a.example.com')) return oneItem('快片A', '1');
        return oneItem('快片B', '3');
      }

      final client = CmsClient(sources: sources, fetcher: fetcher);
      final stopwatch = Stopwatch()..start();
      final out = await client.search('快片');
      stopwatch.stop();
      // Returns on the overall cap, not after the 10 s slow source.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 6)));
      // Both fast sources consulted; the slow one's item never arrived.
      expect(out.map((v) => v.name).toSet(), {'快片A', '快片B'});
    });
  });

  group('CMS detail parsing (canned JSON)', () {
    test('detail maps meta + prefers m3u8 lines', () {
      final detail = parseCmsDetail(_goldSource, '93344', cannedDetailJson());
      expect(detail, isNotNull);
      expect(detail!.meta.name, '流浪地球2');
      expect(detail.meta.actor, '吴京,刘德华');
      expect(detail.meta.director, '郭帆');
      // P1-18: m3u8 lines sort first, non-m3u8 lines are kept
      // (no longer dropped) — both lines survive, m3u8 first.
      expect(detail.lines, hasLength(2));
      expect(detail.lines[0].name, '线路1');
      expect(detail.lines[0].episodes, hasLength(1));
      expect(detail.lines[0].episodes[0].url,
          'https://cdn.example.com/wandering2.m3u8');
      expect(detail.lines[1].name, '线路2');
      expect(detail.lines[1].episodes[0].url,
          'https://cdn.example.com/wandering2.mp4');
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

    test('m3u8 lines sort first, mp4-only lines are kept (P1-18)', () {
      final lines = parsePlayLines(
        '第01集\$https://a.com/1.mp4\$\$\$第01集\$https://b.com/1.m3u8',
        '线路1\$\$\$线路2',
      );
      expect(lines, hasLength(2));
      expect(lines[0].name, '线路2');
      expect(lines[1].name, '线路1');
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
        findAlts: (_, _, _) => Stream<AltVideoSource>.empty(),
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
        findAlts: (_, _, _) =>
            Stream.value(const AltVideoSource(source: 6, vodId: '2')),
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

    test('sweep starts at t=0: slow first + fast alt wins in < 2 s',
        () async {
      // Before 2026-11-17 the alt sweep only started after the 3.5 s
      // first window, so this case took ~3.5 s+ even though the
      // fastest source had the title immediately. Now the sweep races
      // from the start.
      final service = VideoDetailService(
        fetchDetail: (s, v) async {
          if (s.toString() == '12') {
            await Future<void>.delayed(const Duration(seconds: 6));
            return usableDetail(s, v);
          }
          return usableDetail(s, v);
        },
        findAlts: (_, _, _) async* {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          yield const AltVideoSource(source: 6, vodId: '2');
        },
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
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('keeps switching: first two alts unusable, third plays',
        () async {
      VideoDetail unusable(dynamic s, String v) => VideoDetail(
            source: s,
            vodId: v,
            meta: VideoMeta(name: '流浪地球2', year: '2023'),
            lines: const [],
          );
      final service = VideoDetailService(
        fetchDetail: (s, v) async {
          if (s.toString() == '12') {
            await Future<void>.delayed(const Duration(seconds: 6));
            return usableDetail(s, v);
          }
          if (v == 'a' || v == 'b') return unusable(s, v);
          return usableDetail(s, v);
        },
        findAlts: (_, _, _) => Stream.fromIterable(const [
          AltVideoSource(source: 6, vodId: 'a'),
          AltVideoSource(source: 7, vodId: 'b'),
          AltVideoSource(source: 8, vodId: 'c'),
        ]),
      );
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
      expect(r, isNotNull);
      expect(r!.switchedSource, isTrue);
      expect(r.sourceId.toString(), '8');
      expect(r.vodId, 'c');
    });

    test('slow first still wins when alts have nothing', () async {
      final service = VideoDetailService(
        fetchDetail: (s, v) async {
          if (s.toString() == '12') {
            await Future<void>.delayed(const Duration(seconds: 1));
            return usableDetail(s, v);
          }
          return usableDetail(s, v);
        },
        findAlts: (_, _, _) => Stream<AltVideoSource>.empty(),
      );
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
      expect(r, isNotNull);
      expect(r!.switchedSource, isFalse);
      expect(r.sourceId.toString(), '12');
    });

    test('nothing usable within the windows -> null (error card)', () async {
      final service = VideoDetailService(
        fetchDetail: (_, _) async {
          throw StateError('boom');
        },
        findAlts: (_, _, _) => Stream<AltVideoSource>.empty(),
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
        findAlts: (_, _, _) => Stream<AltVideoSource>.empty(),
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
        findAlts: (_, _, _) => Stream<AltVideoSource>.empty(),
      );
      final results = await Future.wait([
        service.get(12, '1'),
        service.get(12, '1'),
      ]);
      expect(results[0], same(results[1]));
      expect(calls, 1);
    });
  });

  group('Alt-source stream (CmsClient.altSourcesStream)', () {
    test('yields the fastest match first, without waiting for the scan',
        () async {
      final fast = VideoSource(
        id: 12,
        name: '金鹰',
        apiUrl: 'http://fast.example.com/api.php/provide/vod',
        kind: 'play',
        sort: 1,
      );
      final slow = VideoSource(
        id: 13,
        name: '慢源',
        apiUrl: 'http://slow.example.com/api.php/provide/vod',
        kind: 'play',
        sort: 2,
      );
      Future<Map<String, dynamic>> fakeFetcher(
        String url, {
        Duration timeout = const Duration(seconds: 8),
      }) async {
        if (url.contains('fast.example.com')) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return {
            'list': [
              {
                'vod_id': '99',
                'vod_name': '流浪地球2',
                'vod_year': '2023',
              },
            ],
          };
        }
        // Slow source: answers first but has no match.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return {
          'list': [
            {'vod_id': '1', 'vod_name': '别的片', 'vod_year': '2023'},
          ],
        };
      }

      final client = CmsClient(sources: [fast, slow], fetcher: fakeFetcher);
      final stopwatch = Stopwatch()..start();
      final alts = await client
          .altSourcesStream('流浪地球2', '2023', 99)
          .toList();
      stopwatch.stop();
      expect(alts.length, 1);
      expect(alts[0].source.toString(), '12');
      expect(alts[0].vodId, '99');
      // Yielded as soon as the fastest source answered (~100 ms),
      // not after a full multi-second scan.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('list form still returns up to 3 matches', () async {
      Future<Map<String, dynamic>> fakeFetcher(
        String url, {
        Duration timeout = const Duration(seconds: 8),
      }) async {
        return {
          'list': [
            {'vod_id': '7', 'vod_name': '流浪地球2', 'vod_year': '2023'},
          ],
        };
      }

      final sources = List.generate(
        4,
        (i) => VideoSource(
          id: 20 + i,
          name: '源$i',
          apiUrl: 'http://s$i.example.com/api.php/provide/vod',
          kind: 'play',
          sort: i,
        ),
      );
      final client = CmsClient(sources: sources, fetcher: fakeFetcher);
      final alts = await client.altSources('流浪地球2', '2023', 999);
      expect(alts.length, 3);
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

    test('merge aligns cast photos by name, never by index', () {
      // CMS actors (吴京 first) vs Douban cast (刘德华 first, with a
      // photo): zipping by index would put 刘德华's photo on 吴京.
      final meta = VideoMeta(
        name: '流浪地球2',
        pic: 'https://cms.example.com/cover.jpg',
        actor: '吴京,刘德华',
        content: '',
      );
      final dd = DoubanDetail(
        id: '35267208',
        media: 'movie',
        title: '流浪地球2',
        castNames: ['刘德华', '吴京'],
        castPhotos: [
          'https://bkimg.cdn.bcebos.com/liu.jpg',
          'https://bkimg.cdn.bcebos.com/wu.jpg',
        ],
      );
      mergeDoubanIntoMeta(meta, dd);
      expect(meta.douban?.castPhotos, [
        'https://bkimg.cdn.bcebos.com/wu.jpg',
        'https://bkimg.cdn.bcebos.com/liu.jpg',
      ]);
    });

    test('merge gives no photo to a CMS actor Douban does not list', () {
      final meta = VideoMeta(
        name: '流浪地球2',
        pic: 'https://cms.example.com/cover.jpg',
        actor: '吴京',
        content: '',
      );
      final dd = DoubanDetail(
        id: '35267208',
        media: 'movie',
        title: '流浪地球2',
        castNames: ['刘德华'],
        castPhotos: ['https://bkimg.cdn.bcebos.com/liu.jpg'],
      );
      mergeDoubanIntoMeta(meta, dd);
      expect(meta.douban?.castPhotos, ['']);
    });

    test('clampDetailIndices: stale history indices cannot crash', () {
      const lines = [
        PlayLine(
          name: '线路1',
          episodes: [
            PlayEpisode(name: '第1集', url: 'https://cdn.example.com/1.m3u8'),
            PlayEpisode(name: '第2集', url: 'https://cdn.example.com/2.m3u8'),
          ],
        ),
        PlayLine(
          name: '线路2',
          episodes: [
            PlayEpisode(name: '第1集', url: 'https://cdn.example.com/3.m3u8'),
          ],
        ),
      ];
      // Re-seed shrank the line list: persisted lineIdx 5 clamps to
      // the last valid line (1), epIdx 9 clamps to that line's only
      // episode (0).
      expect(clampDetailIndices(lines, 5, 9), (lineIdx: 1, epIdx: 0));
      // Valid indices pass through untouched.
      expect(clampDetailIndices(lines, 1, 0), (lineIdx: 1, epIdx: 0));
      // Episode index clamps to the chosen line's length.
      expect(clampDetailIndices(lines, 1, 7), (lineIdx: 1, epIdx: 0));
      // Negative indices clamp to 0.
      expect(clampDetailIndices(lines, -1, -2), (lineIdx: 0, epIdx: 0));
      // No lines at all: safe zero.
      expect(clampDetailIndices(const [], 3, 2), (lineIdx: 0, epIdx: 0));
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

    test('cast photos: desktop wall page -> Baike fallback fills them',
        () async {
      Future<({int status, String body})> fetcher(
        String url,
        Map<String, String> headers, {
        Duration timeout = const Duration(seconds: 10),
      }) async {
        if (url.contains('subject_suggest')) {
          return (
            status: 200,
            body:
                '[{"id":"25853071","title":"庆余年","type":"tv","year":"2019"}]',
          );
        }
        if (url.contains('subject_abstract')) {
          return (
            status: 200,
            body:
                '{"r":0,"subject":{"id":25853071,"title":"庆余年 第一季","rate":"7.9","release_year":"2019","is_tv":true,"directors":["孙皓"],"actors":["张若昀","李沁"],"types":["剧情"],"region":"中国大陆","duration":"45分钟"}}',
          );
        }
        if (url.contains('m.douban.com')) {
          return (
            status: 200,
            body:
                '<meta property="og:image" content="https://img9.doubanio.com/view/photo/s_ratio_poster/public/p1.jpg"><meta itemprop="description" content="豆瓣评分：7.9 简介：简介。"><meta itemprop="ratingValue" content="7.9">',
          );
        }
        if (url.contains('movie.douban.com/subject/')) {
          // What Dio actually returns after following the 302 to
          // sec.douban.com: the login-wall page, no celebrity blocks.
          return (
            status: 200,
            body: 'error code: 008, please Login and retry.',
          );
        }
        return (status: 404, body: '');
      }

      final service = DoubanService(
        fetcher: fetcher,
        cache: MemoryDoubanCache(),
        castPhotoFetcher: (name) async =>
            'https://bkimg.cdn.bcebos.com/pic/$name.jpg',
      );
      final d = await service.detail('庆余年第二季', '2024');
      expect(d, isNotNull);
      expect(d!.castNames, ['张若昀', '李沁']);
      expect(
        d.castPhotos,
        [
          'https://bkimg.cdn.bcebos.com/pic/张若昀.jpg',
          'https://bkimg.cdn.bcebos.com/pic/李沁.jpg',
        ],
      );
    });

    test('cast photos: desktop parse wins, Baike not called', () async {
      var baikeCalls = 0;
      Future<({int status, String body})> fetcher(
        String url,
        Map<String, String> headers, {
        Duration timeout = const Duration(seconds: 10),
      }) async {
        if (url.contains('subject_suggest')) {
          return (
            status: 200,
            body:
                '[{"id":"25853071","title":"庆余年","type":"tv","year":"2019"}]',
          );
        }
        if (url.contains('subject_abstract')) {
          return (
            status: 200,
            body:
                '{"r":0,"subject":{"id":25853071,"title":"庆余年 第一季","rate":"7.9","release_year":"2019","is_tv":true,"directors":["孙皓"],"actors":["张若昀"],"types":["剧情"],"region":"中国大陆","duration":"45分钟"}}',
          );
        }
        if (url.contains('m.douban.com')) {
          return (status: 200, body: '');
        }
        if (url.contains('movie.douban.com/subject/')) {
          return (
            status: 200,
            body:
                '<li class="celebrity"><a><img src="https://img1.doubanio.com/view/celebrity/s_ratio_celebrity/public/p123.jpg"></a><span class="name"><a>张若昀</a></span></li>',
          );
        }
        return (status: 404, body: '');
      }

      final service = DoubanService(
        fetcher: fetcher,
        cache: MemoryDoubanCache(),
        castPhotoFetcher: (name) async {
          baikeCalls++;
          return '';
        },
      );
      final d = await service.detail('庆余年', '2019');
      expect(d, isNotNull);
      expect(d!.castPhotos, [
        'https://img1.doubanio.com/view/celebrity/s_ratio_celebrity/public/p123.jpg',
      ]);
      expect(baikeCalls, 0);
    });

    test('cached detail with empty cast photos is re-fetched, not stale',
        () async {
      var baikeOn = false;
      Future<({int status, String body})> fetcher(
        String url,
        Map<String, String> headers, {
        Duration timeout = const Duration(seconds: 10),
      }) async {
        if (url.contains('subject_suggest')) {
          return (
            status: 200,
            body:
                '[{"id":"25853071","title":"庆余年","type":"tv","year":"2019"}]',
          );
        }
        if (url.contains('subject_abstract')) {
          return (
            status: 200,
            body:
                '{"r":0,"subject":{"id":25853071,"title":"庆余年 第一季","rate":"7.9","release_year":"2019","is_tv":true,"directors":["孙皓"],"actors":["张若昀"],"types":["剧情"],"region":"中国大陆","duration":"45分钟"}}',
          );
        }
        if (url.contains('m.douban.com')) {
          return (status: 200, body: '');
        }
        // Desktop wall page every time.
        return (
          status: 200,
          body: 'error code: 008, please Login and retry.',
        );
      }

      final cache = MemoryDoubanCache();
      final service = DoubanService(
        fetcher: fetcher,
        cache: cache,
        castPhotoFetcher: (name) async =>
            baikeOn ? 'https://bkimg.cdn.bcebos.com/pic/x.jpg' : '',
      );
      // First load: Baike "down" → photos empty, cached that way.
      final d1 = await service.detail('庆余年', '2019');
      expect(d1, isNotNull);
      expect(d1!.castPhotos, ['']);
      // Baike recovers: the stale empty-photos entry must be re-fetched.
      baikeOn = true;
      final d2 = await service.detail('庆余年', '2019');
      expect(d2, isNotNull);
      expect(d2!.castPhotos, ['https://bkimg.cdn.bcebos.com/pic/x.jpg']);
    });
  });

  group('parseBaikeCardPhoto (cast photo fallback)', () {
    test('accepts a matching actor card', () {
      expect(
        parseBaikeCardPhoto(
          {
            'title': '张若昀',
            'desc': '中国内地男演员',
            'image': 'https://bkimg.cdn.bcebos.com/pic/ae51.jpg',
          },
          '张若昀',
        ),
        'https://bkimg.cdn.bcebos.com/pic/ae51.jpg',
      );
    });

    test('rejects wrong title', () {
      expect(
        parseBaikeCardPhoto(
          {'title': '张若云', 'desc': '中国内地男演员', 'image': 'https://x/y.jpg'},
          '张若昀',
        ),
        isNull,
      );
    });

    test('rejects non-entertainer desc (e.g. 张三 人物泛称)', () {
      expect(
        parseBaikeCardPhoto(
          {'title': '张三', 'desc': '人物泛称', 'image': 'https://x/y.jpg'},
          '张三',
        ),
        isNull,
      );
    });

    test('rejects empty image, null-safe', () {
      expect(
        parseBaikeCardPhoto(
          {'title': '李沁', 'desc': '中国内地女演员', 'image': ''},
          '李沁',
        ),
        isNull,
      );
      expect(parseBaikeCardPhoto(null, '李沁'), isNull);
      expect(parseBaikeCardPhoto({'title': '李沁'}, ''), isNull);
    });
  });

  group('Video categories (type map / by-type) — 2026-11-17 分类乱 fix', () {
    // Real shapes, canned: A mirrors 金鹰 (jyzyapi), B mirrors 魔都
    // (moduapi). Parents hold ~0 items; items live under leaf ids.
    const sourceA = VideoSource(
      id: 12,
      name: '金鹰资源',
      apiUrl: 'http://a.example.com/api.php/provide/vod',
      kind: 'play',
      sort: 5,
    );
    const sourceB = VideoSource(
      id: 13,
      name: '魔都资源',
      apiUrl: 'http://b.example.com/api.php/provide/vod',
      kind: 'play',
      sort: 6,
    );

    Map<String, dynamic> classJson(List<Map<String, dynamic>> rows) =>
        {'code': 1, 'class': rows};

    Map<String, dynamic> cls(int id, int pid, String name) =>
        {'type_id': id, 'type_pid': pid, 'type_name': name};

    final classA = classJson([
      cls(1, 0, '电视剧'),
      cls(2, 0, '电影'),
      cls(3, 1, '欧美剧'),
      cls(5, 1, '韩剧'),
      cls(8, 2, '伦理片'),
      cls(9, 2, '动作片'),
      cls(11, 2, '喜剧片'),
      cls(14, 2, '剧情片'),
      cls(17, 0, '动漫'),
      cls(24, 17, '中国动漫'),
      cls(27, 0, '综艺'),
      cls(30, 27, '大陆综艺'),
    ]);
    final classB = classJson([
      cls(7, 0, '电影'),
      cls(8, 0, '连续剧'),
      cls(9, 0, '综艺'),
      cls(10, 7, '动作片'),
      cls(15, 7, '剧情片'),
      cls(26, 8, '国产剧'),
      cls(34, 9, '大陆综艺'),
    ]);

    Map<String, dynamic> item(
      String id,
      String name,
      String type, {
      String area = '大陆',
      String year = '2024',
    }) =>
        {
          'vod_id': id,
          'vod_name': name,
          'vod_pic': 'https://image.example.com/$id.jpg',
          'type_name': type,
          'vod_year': year,
          'vod_area': area,
        };

    Map<String, dynamic> listJson(
      List<Map<String, dynamic>> items, {
      int total = -1,
      int pagecount = 1,
    }) =>
        {
          'code': 1,
          'page': '1',
          'pagecount': pagecount,
          'total': total < 0 ? items.length : total,
          'list': items,
        };

    /// Fake fetcher: `lists` maps 'A:14' / 'B:15' … → list JSON for
    /// `?ac=videolist&t=<id>`; `classDelayA`/`classDelayB` simulate
    /// the old race (B's class table answers first); `fetchLog`
    /// records every fetched URL.
    CmsClient clientWith({
      Map<String, Map<String, dynamic>> lists = const {},
      Duration classDelayA = Duration.zero,
      Duration classDelayB = Duration.zero,
      bool throwLists = false,
      List<String>? fetchLog,
    }) {
      Future<Map<String, dynamic>> fetcher(
        String url, {
        Duration timeout = const Duration(seconds: 8),
      }) async {
        fetchLog?.add(url);
        if (url.contains('?ac=list')) {
          if (url.contains('a.example.com')) {
            await Future<void>.delayed(classDelayA);
            return classA;
          }
          await Future<void>.delayed(classDelayB);
          return classB;
        }
        if (throwLists) throw CmsException('boom');
        final uri = Uri.parse(url);
        final t = uri.queryParameters['t'] ?? '';
        final host = uri.host.startsWith('a.') ? 'A' : 'B';
        final doc = lists['$host:$t'];
        if (doc == null) return listJson(const []);
        return doc;
      }

      return CmsClient(
        sources: const [sourceA, sourceB],
        fetcher: fetcher,
      );
    }

    test('typeMap: priority order wins, not first answer (race fix)',
        () async {
      final client = clientWith(
        classDelayA: const Duration(milliseconds: 100),
        classDelayB: Duration.zero,
      );
      final map = await client.typeMap();
      // B answered first, but A is first in priority order.
      expect(map['剧情片']!.source, 12);
      expect(map['剧情片']!.typeId, '14');
      expect(map['剧情片']!.candidates.length, 1);
      expect(map['剧情片']!.candidates.first.source, 13);
      expect(map['剧情片']!.candidates.first.typeId, '15');
      expect(map['剧情片']!.isParent, isFalse);
      // Candidates carry their own children.
      expect(
        map['电影']!.candidates.first.childTypeIds,
        ['10', '15'],
      );
      // Parent children from A's own table; adult child excluded.
      expect(map['电影']!.isParent, isTrue);
      expect(map['电影']!.childTypeIds, ['9', '11', '14']);
      expect(map['电视剧']!.childTypeIds, ['3', '5']);
      expect(map['动漫']!.childTypeIds, ['24']);
      expect(map['综艺']!.childTypeIds, ['30']);
      // Only B carries 连续剧.
      expect(map['连续剧']!.source, 13);
      expect(map['连续剧']!.childTypeIds, ['26']);
      // Adult names never enter the map.
      expect(map.containsKey('伦理片'), isFalse);
    });

    test('typeMap caches for 10 minutes', () async {
      final log = <String>[];
      final client = clientWith(fetchLog: log);
      final m1 = await client.typeMap();
      final m2 = await client.typeMap();
      expect(identical(m1, m2), isTrue);
      expect(log.where((u) => u.contains('?ac=list')).length, 2);
    });

    test('byType parent fans out to children and merges', () async {
      final client = clientWith(lists: {
        'A:9': listJson([
          item('a1', '动作片A1', '动作片'),
          item('a2', '动作片A2', '动作片'),
        ], total: 100, pagecount: 5),
        'A:11': listJson([
          item('c1', '喜剧片C1', '喜剧片'),
          item('c2', '喜剧片C2', '喜剧片'),
        ], total: 50, pagecount: 3),
        'A:14': listJson([
          item('p1', '剧情片P1', '剧情片'),
        ], total: 30, pagecount: 2),
      });
      final r = await client.byType('电影', 1);
      // Round-robin interleave: one per child per round.
      expect(
        r.items.map((v) => v.name).toList(),
        ['动作片A1', '喜剧片C1', '剧情片P1', '动作片A2', '喜剧片C2'],
      );
      expect(r.total, 180);
      expect(r.pagecount, 5);
    });

    test('byType parent falls back to candidate when primary merge is empty',
        () async {
      final client = clientWith(lists: {
        // A's children all empty.
        'A:9': listJson(const []),
        'A:11': listJson(const []),
        'A:14': listJson(const []),
        // B's 电影 is a parent with one child that has content.
        'B:10': listJson(
          [item('b1', '动作片B1', '动作片')],
          total: 7,
          pagecount: 1,
        ),
      });
      final r = await client.byType('电影', 1);
      expect(r.items.map((v) => v.name).toList(), ['动作片B1']);
      expect(r.total, 7);
    });

    test('byType parent applies area filter after merging', () async {
      final client = clientWith(lists: {
        'A:9': listJson([
          item('a1', '动作片A1', '动作片', area: '大陆'),
          item('a2', '动作片A2', '动作片', area: '香港'),
        ], total: 100, pagecount: 5),
        'A:11': listJson([
          item('c1', '喜剧片C1', '喜剧片', area: '大陆'),
        ], total: 50, pagecount: 3),
        'A:14': listJson([
          item('p1', '剧情片P1', '剧情片', area: '香港'),
        ], total: 30, pagecount: 2),
      });
      final r = await client.byType('电影', 1, area: '大陆');
      expect(
        r.items.map((v) => v.name).toList(),
        ['动作片A1', '喜剧片C1'],
      );
      expect(r.total, 2);
    });

    test('byType leaf falls back on wrong-type content', () async {
      final client = clientWith(lists: {
        // Live case (iKun 2026-11-17): t=14 answers, but the items
        // carry another type's name.
        'A:14': listJson(
          [item('w1', '错片', '家庭片')],
          total: 96,
          pagecount: 1,
        ),
        'B:15': listJson(
          [item('g1', '剧情片G1', '剧情片')],
          total: 40,
          pagecount: 2,
        ),
      });
      final r = await client.byType('剧情片', 1);
      expect(r.items.map((v) => v.name).toList(), ['剧情片G1']);
      expect(r.total, 40);
    });

    test('byType leaf falls back on empty', () async {
      final client = clientWith(lists: {
        'A:14': listJson(const []),
        'B:15': listJson(
          [item('g1', '剧情片G1', '剧情片')],
          total: 40,
          pagecount: 2,
        ),
      });
      final r = await client.byType('剧情片', 1);
      expect(r.items.map((v) => v.name).toList(), ['剧情片G1']);
    });

    test('byType leaf does not consult candidates when primary is good',
        () async {
      final log = <String>[];
      final client = clientWith(
        fetchLog: log,
        lists: {
          'A:14': listJson(
            [item('g1', '剧情片G1', '剧情片')],
            total: 40,
            pagecount: 2,
          ),
          'B:15': listJson(
            [item('x1', '不应出现', '剧情片')],
            total: 1,
            pagecount: 1,
          ),
        },
      );
      final r = await client.byType('剧情片', 1);
      expect(r.items.map((v) => v.name).toList(), ['剧情片G1']);
      expect(
        log.where((u) => u.contains('b.example.com') && u.contains('t=15')),
        isEmpty,
      );
    });

    test('homeRowOne parent merges children; leaf falls back on wrong type',
        () async {
      final client = clientWith(lists: {
        'A:9': listJson(
          [item('a1', '动作片A1', '动作片')],
          total: 100,
          pagecount: 5,
        ),
        'A:11': listJson(
          [item('c1', '喜剧片C1', '喜剧片')],
          total: 50,
          pagecount: 3,
        ),
        'A:14': listJson(
          [item('w1', '错片', '家庭片')],
          total: 96,
          pagecount: 1,
        ),
        'B:15': listJson(
          [item('g1', '剧情片G1', '剧情片')],
          total: 40,
          pagecount: 2,
        ),
      });
      final map = await client.typeMap();
      final parentRow = await client.homeRowOne('电影', map['电影']!);
      expect(parentRow, isNotNull);
      expect(parentRow!.count, 246);
      expect(
        parentRow.items.map((v) => v.name).toList(),
        ['动作片A1', '喜剧片C1', '错片'],
      );
      final leafRow = await client.homeRowOne('剧情片', map['剧情片']!);
      expect(leafRow, isNotNull);
      expect(leafRow!.items.map((v) => v.name).toList(), ['剧情片G1']);
      expect(leafRow.count, 40);
    });

    test('byType unknown name throws; unreachable source throws', () async {
      final client = clientWith();
      expect(
        () => client.byType('不存在的分类', 1),
        throwsA(isA<CmsException>()),
      );
      final dead = clientWith(throwLists: true);
      expect(
        () => dead.byType('剧情片', 1),
        throwsA(isA<CmsException>()),
      );
    });
  });
}
