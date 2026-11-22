// 1.1.6 browse tests (Smart Groups / poster patch / Emby specs /
// aggregated continue-watching).
//
// - Pure tests: grouping key, history fields, next-episode helper,
//   Emby spec parse/format/filter, poster candidate gate.
// - Service tests (testWidgets + Hive temp box): poster patch cache
//   + Bangumi/Bilibili fallback with fake fetchers (no network).
// - Widget tests: version sheet (rows, spec filter, alt append),
//   aggregated bar (two separate rows, no mixing).
//
// The player-page wiring for `totalEpisodes`/`nextEpName` lives in
// native_video_player_page.dart (fenced off in this merge): the
// model + helper + bar filtering are tested here end to end, and the
// 4-line call-site patch is handed to the coordinator.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/video/emby_spec.dart';
import 'package:standalone/features/video/video_detail_page.dart';
import 'package:standalone/features/video/video_detail_service.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/features/video/video_smart_groups.dart';
import 'package:standalone/features/video/video_tab_page.dart';
import 'package:standalone/features/video/video_version_sheet.dart';
import 'package:standalone/services/video/emby_models.dart';
import 'package:standalone/services/video/poster_patch_service.dart';

import 'helpers/hive_test_setup.dart';

VideoItem _item({
  required dynamic source,
  required String vodId,
  required String name,
  String year = '',
  String score = '',
  String pic = '',
  String remarks = '',
  String sourceName = '',
}) =>
    VideoItem(
      source: source,
      sourceName: sourceName,
      vodId: vodId,
      name: name,
      pic: pic,
      year: year,
      score: score,
      remarks: remarks,
    );

WatchHistoryEntry _history({
  required dynamic source,
  required String vodId,
  required String title,
  double position = 600,
  double duration = 1800,
  String nextEpName = '',
  String year = '',
}) =>
    WatchHistoryEntry(
      source: source,
      vodId: vodId,
      title: title,
      year: year,
      lineIdx: 0,
      epIdx: 2,
      epName: '第3集',
      position: position,
      duration: duration,
      nextEpName: nextEpName,
      at: DateTime(2026, 11, 22),
    );

VideoDetail _cannedDetail() => VideoDetail(
      source: 12,
      vodId: 'v1',
      meta: VideoMeta(name: '庆余年', pic: '', year: '2019', score: '8.0'),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: [
            const PlayEpisode(name: '第1集', url: 'https://example.com/1.m3u8'),
          ],
        ),
      ],
    );

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init(prefix: 'hao-b16-test-');
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  tearDown(() {
    Get.reset();
  });

  group('Smart Groups', () {
    test('same title + year on two sources groups into one card', () {
      final groups = groupVideoItems([
        _item(source: 12, vodId: '1001', name: '庆余年', year: '2019', score: '7.5', sourceName: '金鹰'),
        _item(source: 5, vodId: '2002', name: '庆余年', year: '2019', score: '8.0', sourceName: '非凡'),
      ]);
      expect(groups.length, 1);
      expect(groups.first.versions.length, 2);
      // Representative = highest score.
      expect(groups.first.representative.source, 5);
      expect(groups.first.representative.score, '8.0');
    });

    test('same title, different known year never groups (remake)', () {
      final groups = groupVideoItems([
        _item(source: 12, vodId: '1', name: '流浪地球', year: '2019'),
        _item(source: 5, vodId: '2', name: '流浪地球', year: '2026'),
      ]);
      expect(groups.length, 2);
    });

    test('missing year merges into the same-title row', () {
      final groups = groupVideoItems([
        _item(source: 12, vodId: '1', name: '庆余年', year: '2019'),
        _item(source: 5, vodId: '2', name: '庆余年（高清）', year: ''),
      ]);
      expect(groups.length, 1);
      expect(groups.first.versions.length, 2);
    });

    test('different seasons never group', () {
      final groups = groupVideoItems([
        _item(source: 12, vodId: '1', name: '庆余年', year: '2019'),
        _item(source: 12, vodId: '2', name: '庆余年第二季', year: '2024'),
      ]);
      expect(groups.length, 2);
    });

    test('bare sequel number does not merge (U1-3)', () {
      final groups = groupVideoItems([
        _item(source: 12, vodId: '1', name: '庆余年', year: '2019'),
        _item(source: 12, vodId: '2', name: '庆余年 2', year: '2024'),
      ]);
      expect(groups.length, 2);
    });

    test('empty title never groups', () {
      final groups = groupVideoItems([
        _item(source: 12, vodId: '1', name: ''),
        _item(source: 5, vodId: '2', name: ''),
      ]);
      expect(groups.length, 2);
    });

    test('Emby items pass through as singletons (v1: never grouped)',
        () {
      final groups = groupVideoItems([
        _item(source: 'emby', vodId: 'e1', name: '庆余年', year: '2019'),
        _item(source: 12, vodId: '1', name: '庆余年', year: '2019'),
      ]);
      expect(groups.length, 2);
      expect(groups.first.isEmby, isTrue);
      expect(groups.first.isSingle, isTrue);
    });

    test('representative falls back to a sibling poster', () {
      final groups = groupVideoItems([
        _item(source: 12, vodId: '1', name: '庆余年', year: '2019', score: '9.0', pic: ''),
        _item(source: 5, vodId: '2', name: '庆余年', year: '2019', score: '7.0', pic: 'https://example.com/p.jpg'),
      ]);
      expect(groups.first.representative.pic, 'https://example.com/p.jpg');
    });

    test('filmMatches mirrors the history rule', () {
      expect(filmMatches('庆余年', '2019', '庆余年', '2019'), isTrue);
      expect(filmMatches('庆余年', '2019', '庆余年', '2024'), isFalse);
      expect(filmMatches('庆余年', '', '庆余年', '2019'), isTrue);
      expect(filmMatches('庆余年', '2019', '庆余年第二季', '2019'), isFalse);
    });
  });

  group('WatchHistoryEntry next-episode fields', () {
    test('round-trips totalEpisodes / nextEpName', () {
      final e = _history(
        source: 12,
        vodId: '1',
        title: '庆余年',
        nextEpName: '第4集',
      );
      final back = WatchHistoryEntry.fromJson(
        jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>,
      );
      expect(back.nextEpName, '第4集');
      expect(back.hasNextEpisode, isTrue);
    });

    test('rows written before 1.1.6 read back as no-next-episode', () {
      final raw = <String, dynamic>{
        'source': 12,
        'vodId': '1',
        'title': '流浪地球2',
        'pic': '',
        'picAlt': '',
        'year': '2023',
        'lineIdx': 0,
        'epIdx': 0,
        'epName': '正片',
        'position': 600,
        'duration': 1800,
        'at': DateTime(2026, 11, 22).millisecondsSinceEpoch,
      };
      final back = WatchHistoryEntry.fromJson(raw);
      expect(back.totalEpisodes, isNull);
      expect(back.nextEpName, '');
      expect(back.hasNextEpisode, isFalse);
    });

    test('historyNextEpisode: same-line next, last ep, cross-season',
        () {
      final lines = [
        PlayLine(name: '第 1 季', episodes: const [
          PlayEpisode(name: '第1集', url: 'u1'),
          PlayEpisode(name: '第2集', url: 'u2'),
        ]),
        PlayLine(name: '第 2 季', episodes: const [
          PlayEpisode(name: '第1集', url: 'u3'),
        ]),
      ];
      final mid = historyNextEpisode(
        lines: lines,
        lineIdx: 0,
        epIdx: 0,
        allowCrossLine: false,
      );
      expect(mid, (totalEpisodes: 2, nextEpName: '第2集'));
      final lastCms = historyNextEpisode(
        lines: lines,
        lineIdx: 0,
        epIdx: 1,
        allowCrossLine: false,
      );
      expect(lastCms.nextEpName, '');
      expect(lastCms.totalEpisodes, 2);
      final lastEmby = historyNextEpisode(
        lines: lines,
        lineIdx: 0,
        epIdx: 1,
        allowCrossLine: true,
      );
      expect(lastEmby.nextEpName, '第1集');
      final lastOfAll = historyNextEpisode(
        lines: lines,
        lineIdx: 1,
        epIdx: 0,
        allowCrossLine: true,
      );
      expect(lastOfAll.nextEpName, '');
      expect(
        historyNextEpisode(lines: const [], lineIdx: 0, epIdx: 0, allowCrossLine: true),
        (totalEpisodes: 0, nextEpName: ''),
      );
    });

    test('findEpisodeByName searches across lines, null when absent',
        () {
      final lines = [
        PlayLine(name: '第 1 季', episodes: const [
          PlayEpisode(name: '第1集', url: 'u1'),
        ]),
        PlayLine(name: '第 2 季', episodes: const [
          PlayEpisode(name: '第1集', url: 'u3'),
          PlayEpisode(name: '第2集', url: 'u4'),
        ]),
      ];
      expect(findEpisodeByName(lines, '第2集'), (lineIdx: 1, epIdx: 1));
      expect(findEpisodeByName(lines, '第9集'), isNull);
      expect(findEpisodeByName(lines, ''), isNull);
    });

    test('historyNextEpisode: a movie\'s dub variants are not a next episode',
        () {
      // 《空枪》 case: one CMS line whose "episodes" are dubs of the
      // same film — watching 粤语 must NOT yield 国语 as 下一集.
      final movieLines = [
        PlayLine(name: '线路1', episodes: const [
          PlayEpisode(name: '粤语', url: 'u1'),
          PlayEpisode(name: '国语', url: 'u2'),
        ]),
      ];
      expect(
        historyNextEpisode(
          lines: movieLines,
          lineIdx: 0,
          epIdx: 0,
          allowCrossLine: false,
        ).nextEpName,
        '',
      );
      // Suffixed variants (国语版 / 粤语中字) are the same entry.
      expect(isVersionEpisodeName('国语版'), isTrue);
      expect(isVersionEpisodeName('粤语中字'), isTrue);
      expect(isVersionEpisodeName('国语中字版'), isTrue);
      // A film split into parts is still one film.
      final parts = [
        PlayLine(name: '线路1', episodes: const [
          PlayEpisode(name: '上集', url: 'u1'),
          PlayEpisode(name: '下集', url: 'u2'),
        ]),
      ];
      expect(
        historyNextEpisode(
          lines: parts,
          lineIdx: 0,
          epIdx: 0,
          allowCrossLine: false,
        ).nextEpName,
        '',
      );
      // A cross-line first entry that is only a dub is skipped too.
      final crossDub = [
        PlayLine(name: '线路1', episodes: const [
          PlayEpisode(name: '正片', url: 'u1'),
        ]),
        PlayLine(name: '线路2', episodes: const [
          PlayEpisode(name: '国语', url: 'u2'),
        ]),
      ];
      expect(
        historyNextEpisode(
          lines: crossDub,
          lineIdx: 0,
          epIdx: 0,
          allowCrossLine: true,
        ).nextEpName,
        '',
      );
      // And a series is untouched: 第1集 → 第2集, with the right name.
      final series = [
        PlayLine(name: '线路1', episodes: const [
          PlayEpisode(name: '第1集', url: 'u1'),
          PlayEpisode(name: '第2集', url: 'u2'),
        ]),
      ];
      final next = historyNextEpisode(
        lines: series,
        lineIdx: 0,
        epIdx: 0,
        allowCrossLine: false,
      );
      expect(next.nextEpName, '第2集');
      expect(next.totalEpisodes, 2);
      expect(isVersionEpisodeName('第2集'), isFalse);
      expect(isVersionEpisodeName('Pilot'), isFalse);
    });

    test('splitContinueWatching: one work in one bar only', () {
      final split = splitContinueWatching([
        _history(source: 12, vodId: 'a', title: '在看无下一集'),
        _history(source: 'emby', vodId: 'b', title: '在看有下一集', nextEpName: '第2集'),
        _history(source: 12, vodId: 'c', title: '看完有下一集', position: 1790, nextEpName: '第4集'),
        _history(source: 12, vodId: 'd', title: '看完电影', position: 1790),
        // Stale row from before the fix: finished film whose stored
        // next name is only a dub — in neither bar.
        _history(source: 12, vodId: 'e', title: '看完旧电影', position: 1790, nextEpName: '国语'),
        // Same film twice (two languages / sources): the unfinished
        // row keeps the film in 在看, the finished twin stays out
        // of 下一集.
        _history(source: 12, vodId: 'f', title: '同片双语', year: '2024'),
        _history(source: 5, vodId: 'g', title: '同片双语', year: '2024', position: 1790, nextEpName: '第2集'),
      ]);
      expect(
        split.watching.map((e) => e.title).toList(),
        ['在看无下一集', '在看有下一集', '同片双语'],
      );
      expect(
        split.nextUp.map((e) => e.title).toList(),
        ['看完有下一集'],
      );
    });
  });

  group('Emby specs (BitRate / Size)', () {
    test('parses BitRate + Size, null when the server omits them', () {
      final facts = EmbyStreamFacts.fromMediaSources([
        {
          'Container': 'mkv',
          'Size': 2147483648,
          'MediaStreams': [
            {
              'Type': 'Video',
              'Codec': 'hevc',
              'Width': 3840,
              'Height': 2160,
              'BitRate': 25000000,
              'VideoRange': 'DolbyVision',
              'ExtendedVideoType': 'DolbyVision',
              'ExtendedVideoSubType': 'DoviProfile81',
            },
            {'Type': 'Audio', 'Codec': 'truehd', 'IsDefault': true},
          ],
        },
      ]);
      expect(facts.bitRate, 25000000);
      expect(facts.size, 2147483648);
      expect(facts.width, 3840);
      expect(facts.dolbyVision, isTrue);
      expect(facts.isEmpty, isFalse);
      expect(facts.toQueryParams()['hao_bitrate'], '25000000');
      expect(facts.toQueryParams()['hao_size'], '2147483648');

      final bare = EmbyStreamFacts.fromMediaSources([
        {
          'Container': 'mp4',
          'MediaStreams': [
            {'Type': 'Video', 'Codec': 'h264'},
          ],
        },
      ]);
      expect(bare.bitRate, isNull);
      expect(bare.size, isNull);
      expect(bare.toQueryParams()['hao_bitrate'], isNull);
      expect(bare.toQueryParams()['hao_size'], isNull);
    });

    test('format helpers', () {
      expect(formatEmbyBytes(2147483648), '2.0 GB');
      expect(formatEmbyBytes(850 * 1024 * 1024), '850 MB');
      expect(formatEmbyBytes(null), '');
      expect(formatEmbyBitrate(25000000), '25.0 Mbps');
      expect(formatEmbyBitrate(null), '');
    });

    test('spec filter: 4K / DV / HDR only on signal', () {
      const facts4k = EmbyStreamFacts(width: 3840, height: 2160);
      expect(embySpecMatchesFilter(facts4k, EmbySpecFilter.fourK), isTrue);
      expect(
        embySpecMatchesFilter(facts4k, EmbySpecFilter.dolbyVision),
        isFalse,
      );
      expect(
        embySpecMatchesFilter(facts4k, EmbySpecFilter.hdr),
        isFalse,
      );
      expect(
        embySpecMatchesFilter(
          facts4k,
          EmbySpecFilter.hdr,
          videoRange: 'HDR10',
        ),
        isTrue,
      );
      // Dolby Vision alone is NOT an HDR match (no range signal).
      const factsDv = EmbyStreamFacts(dolbyVision: true);
      expect(
        embySpecMatchesFilter(factsDv, EmbySpecFilter.dolbyVision),
        isTrue,
      );
      expect(
        embySpecMatchesFilter(factsDv, EmbySpecFilter.hdr),
        isFalse,
      );
      expect(
        embySpecLabels(factsDv),
        ['DV'],
      );
    });
  });

  group('Poster patch', () {
    test('candidate gate: title must contain, year must agree', () {
      expect(
        PosterPatchService.candidatePasses(
          candidateName: '葬送的芙莉莲',
          candidateYear: '2023',
          queryTitle: '葬送的芙莉莲',
          queryYear: '2023',
        ),
        isTrue,
      );
      expect(
        PosterPatchService.candidatePasses(
          candidateName: '葬送的芙莉莲',
          candidateYear: '2021',
          queryTitle: '葬送的芙莉莲',
          queryYear: '2023',
        ),
        isFalse,
      );
      expect(
        PosterPatchService.candidatePasses(
          candidateName: '庆余年 第二季',
          queryTitle: '庆余年',
          queryYear: '2019',
        ),
        isTrue,
      );
      expect(
        PosterPatchService.candidatePasses(
          candidateName: '流浪地球',
          queryTitle: '庆余年',
          queryYear: '2019',
        ),
        isFalse,
      );
    });

    testWidgets('Bangumi hit is cached; second lookup is 0-network',
        (tester) async {
      var calls = 0;
      final service = PosterPatchService(
        fetcher: (url, {headers, queryParameters}) async {
          calls++;
          return {
            'list': [
              {
                'name': '葬送的芙莉莲',
                'name_cn': '葬送的芙莉莲',
                'air_date': '2023-09-29',
                'images': {'large': 'https://lain.bgm.tv/pic/cover/l/x.jpg'},
              },
            ],
          };
        },
      );
      final first = await service.patchFor('葬送的芙莉莲', '2023');
      expect(first, 'https://lain.bgm.tv/pic/cover/l/x.jpg');
      final second = await service.patchFor('葬送的芙莉莲', '2023');
      expect(second, first);
      expect(calls, 1);
      await drainHiveWrites(tester);
    });

    testWidgets('Bangumi wrong year falls through to Bilibili PGC',
        (tester) async {
      // NOTE: a different title from the Bangumi-hit test above —
      // both tests share one Hive box, so reusing the title would
      // read the first test's cached poster instead of exercising
      // the fallback.
      final service = PosterPatchService(
        fetcher: (url, {headers, queryParameters}) async {
          if (url.contains('api.bgm.tv')) {
            return {
              'list': [
                {
                  'name': '间谍过家家',
                  'name_cn': '间谍过家家',
                  'air_date': '2021-01-01',
                  'images': {
                    'large': 'https://lain.bgm.tv/pic/cover/l/wrong.jpg',
                  },
                },
              ],
            };
          }
          if (url.contains('finger/spi')) {
            return {
              'data': {'b_3': 'b3-test', 'b_4': 'b4-test'},
            };
          }
          return {
            'code': 0,
            'data': {
              'result': [
                {
                  'cover': 'https://i0.hdslb.com/bfs/bangumi/ok.jpg',
                  'title': '间谍过家家',
                },
              ],
            },
          };
        },
        wbiSign: (url) async => <String, String>{
          'wts': '1',
          'w_rid': 'fake',
        },
      );
      final url = await service.patchFor('间谍过家家', '2022');
      expect(url, 'https://i0.hdslb.com/bfs/bangumi/ok.jpg');
      await drainHiveWrites(tester);
    });

    testWidgets('all providers failing caches the failure for 1 h',
        (tester) async {
      var calls = 0;
      final service = PosterPatchService(
        fetcher: (url, {headers, queryParameters}) async {
          calls++;
          return null;
        },
        wbiSign: (url) async => <String, String>{},
      );
      expect(await service.patchFor('不存在的片名xyz', ''), isNull);
      final callsAfterFirst = calls;
      expect(callsAfterFirst, greaterThan(0));
      expect(await service.patchFor('不存在的片名xyz', ''), isNull);
      expect(calls, callsAfterFirst);
      await drainHiveWrites(tester);
    });

    testWidgets('withCachedPatches only touches poster-less items',
        (tester) async {
      final service = PosterPatchService(
        fetcher: (url, {headers, queryParameters}) async => {
          'list': [
            {
              'name': '庆余年',
              'name_cn': '庆余年',
              'air_date': '2019-11-26',
              'images': {'large': 'https://lain.bgm.tv/pic/cover/l/q.jpg'},
            },
          ],
        },
      );
      await service.patchFor('庆余年', '2019');
      final patched = service.withCachedPatches([
        _item(source: 12, vodId: '1', name: '庆余年', year: '2019'),
        _item(
          source: 12,
          vodId: '2',
          name: '庆余年',
          year: '2019',
          pic: 'https://example.com/keep.jpg',
        ),
        _item(source: 12, vodId: '3', name: '流浪地球2', year: '2023'),
      ]);
      expect(patched[0].pic, 'https://lain.bgm.tv/pic/cover/l/q.jpg');
      expect(patched[1].pic, 'https://example.com/keep.jpg');
      expect(patched[2].pic, '');
      await drainHiveWrites(tester);
    });
  });

  group('Version sheet', () {
    VideoDetailService fakeService({bool withAlt = false}) {
      return VideoDetailService(
        fetchDetail: (source, vodId, {cancelToken}) async =>
            _cannedDetail(),
        findAlts: (title, year, exclude, {cancelToken}) => withAlt
            ? Stream.value(
                const AltVideoSource(source: 99, vodId: 'v99'),
              )
            : const Stream<AltVideoSource>.empty(),
      );
    }

    Future<void> pumpSheet(
      WidgetTester tester, {
      bool withAlt = false,
    }) async {
      final group = GroupedVideoItem(
        key: '庆余年|2019',
        representative: _item(
          source: 12,
          vodId: '1001',
          name: '庆余年',
          year: '2019',
          score: '8.0',
          remarks: '更新至第46集',
          sourceName: '金鹰',
        ),
        versions: [
          _item(
            source: 12,
            vodId: '1001',
            name: '庆余年',
            year: '2019',
            score: '8.0',
            remarks: '更新至第46集',
            sourceName: '金鹰',
          ),
          _item(
            source: 5,
            vodId: '2002',
            name: '庆余年',
            year: '2019',
            score: '7.5',
            remarks: '高清',
            sourceName: '非凡',
          ),
        ],
      );
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showVideoVersionsSheet(
                    context,
                    group: group,
                    detailService: fakeService(withAlt: withAlt),
                  ),
                  child: const Text('打开版本'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开版本'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('shows versions + remarks as source label, no badges',
        (tester) async {
      await pumpSheet(tester);
      expect(find.text('庆余年'), findsWidgets);
      expect(find.text('金鹰'), findsOneWidget);
      expect(find.text('非凡'), findsOneWidget);
      expect(find.text('首选'), findsOneWidget);
      expect(find.text('来源标注：更新至第46集'), findsOneWidget);
      expect(find.text('来源标注：高清'), findsOneWidget);
      // No quality badges on CMS rows (H1).
      expect(find.text('4K'), findsOneWidget); // the filter chip only
      expect(find.text('杜比视界'), findsOneWidget); // the filter chip only
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
    });

    testWidgets('spec filter hides CMS rows with an honest empty state',
        (tester) async {
      await pumpSheet(tester);
      await tester.tap(find.text('4K'));
      await tester.pump();
      expect(find.text('金鹰'), findsNothing);
      expect(find.text('CMS 源无画质信息，已隐藏'), findsOneWidget);
      await tester.tap(find.text('全部'), warnIfMissed: false);
      await tester.pump();
      expect(find.text('金鹰'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
    });

    testWidgets('alt stream appends a discovered version', (tester) async {
      await pumpSheet(tester, withAlt: true);
      await settle(tester);
      expect(find.text('源 99'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
    });

    testWidgets('tapping a version opens its detail page', (tester) async {
      await pumpSheet(tester);
      await tester.tap(find.text('非凡'));
      await tester.pump();
      await settle(tester);
      expect(find.byType(VideoDetailPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(VideoDetailPage))).pop();
      await tester.pump();
      await pumpFor(tester, const Duration(seconds: 16));
      // Drain: the opened detail page fires Douban enrichment +
      // poster-patch writes fire-and-forget in the fake zone; a
      // write left pending sticks the Hive ReadWriteSync queue for
      // the next test (see hive_test_setup.dart).
      await drainHiveWrites(tester);
    });
  });

  group('Aggregated continue-watching bar', () {
    Future<void> seedHistory() async {
      await HiveStore.put(
        HiveKeys.videoHistory,
        jsonEncode([
          {
            'source': 12,
            'vodId': 'a',
            'title': '在看无下一集',
            'pic': '',
            'picAlt': '',
            'year': '2023',
            'lineIdx': 0,
            'epIdx': 2,
            'epName': '第3集',
            'position': 600,
            'duration': 1800,
            'at': DateTime(2026, 11, 22).millisecondsSinceEpoch,
          },
          {
            'source': 'emby',
            'vodId': 'b',
            'title': '在看有下一集',
            'pic': '',
            'picAlt': '',
            'year': '2024',
            'lineIdx': 0,
            'epIdx': 0,
            'epName': '第1集',
            'position': 600,
            'duration': 1800,
            'nextEpName': '第2集',
            'at': DateTime(2026, 11, 22).millisecondsSinceEpoch,
          },
          {
            'source': 12,
            'vodId': 'c',
            'title': '看完有下一集',
            'pic': '',
            'picAlt': '',
            'year': '2023',
            'lineIdx': 0,
            'epIdx': 2,
            'epName': '第3集',
            'position': 1790,
            'duration': 1800,
            'nextEpName': '第4集',
            'at': DateTime(2026, 11, 22).millisecondsSinceEpoch,
          },
        ]),
      );
    }

    Future<void> pumpBar(
      WidgetTester tester, {
      List<(WatchHistoryEntry, String?)>? calls,
    }) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: AggregatedContinueBar(
              onOpen: calls == null
                  ? null
                  : (entry, {startEpName}) async {
                      calls.add((entry, startEpName));
                    },
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('CMS + Emby rows aggregate; the two bars stay separate',
        (tester) async {
      await tester.runAsync(seedHistory);
      await pumpBar(tester);
      // Watching bar: A + B (C is finished). Next bar: C only — B's
      // episode is still unfinished, so it stays out of 下一集 (b29:
      // one work, one bar).
      expect(find.text('继续观看'), findsOneWidget);
      expect(find.text('下一集'), findsOneWidget);
      expect(find.text('在看无下一集'), findsOneWidget);
      expect(find.text('在看有下一集'), findsOneWidget);
      expect(find.text('看完有下一集'), findsOneWidget);
      expect(find.text('下一集 · 第2集'), findsNothing);
      expect(find.text('下一集 · 第4集'), findsOneWidget);
      // Drain: the seeded Hive write must not leave the
      // ReadWriteSync queue stuck for the next test (see
      // hive_test_setup.dart — a stuck queue hangs the next test's
      // first Hive write forever, even through runAsync).
      await drainHiveWrites(tester);
    });

    testWidgets('watching tap resumes; next tap starts the next episode',
        (tester) async {
      await tester.runAsync(seedHistory);
      final calls = <(WatchHistoryEntry, String?)>[];
      await pumpBar(tester, calls: calls);
      await tester.tap(find.text('在看无下一集'));
      await tester.pump();
      expect(calls.length, 1);
      expect(calls.first.$1.title, '在看无下一集');
      expect(calls.first.$2, isNull);
      await tester.tap(find.text('看完有下一集'));
      await tester.pump();
      expect(calls.length, 2);
      expect(calls.last.$1.title, '看完有下一集');
      expect(calls.last.$2, '第4集');
      await drainHiveWrites(tester);
    });

    testWidgets('empty history renders nothing', (tester) async {
      await tester.runAsync(
        () => HiveStore.put(HiveKeys.videoHistory, '[]'),
      );
      await pumpBar(tester);
      expect(find.text('继续观看'), findsNothing);
      expect(find.text('下一集'), findsNothing);
      await drainHiveWrites(tester);
    });
  });
}
