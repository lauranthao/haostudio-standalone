// 1.1.6 missing-episode chips (缺集接续): pure merge + detail-page UI.
//
// - Pure: mergeEpisodeChips merges the current line with the union's
//   missing numbers in episode-number order, never inventing numbers.
// - Widget: the detail page renders a greyed "其他源" chip for a
//   missing episode; tapping it switches to the alt source carrying
//   that episode and plays it (asserted on the pushed player page);
//   a movie (single unnumbered episode) never starts the union scan.
//
// Harness copied from b16_browse_test.dart (Hive temp box; the page
// reads history/favs from Hive on apply). No network: the detail
// service is canned and the alt-details stream is a test-controlled
// StreamController.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/video/missing_episode_chips.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_detail_page.dart';
import 'package:standalone/features/video/video_detail_service.dart';
import 'package:standalone/features/video/video_models.dart';

import 'helpers/hive_test_setup.dart';

VideoDetail _baseDetail() => VideoDetail(
      source: 12,
      vodId: 'v1',
      meta: VideoMeta(name: '庆余年', pic: '', year: '2019', score: '8.0'),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: const [
            PlayEpisode(name: '第1集', url: 'https://example.com/1.m3u8'),
            PlayEpisode(name: '第2集', url: 'https://example.com/2.m3u8'),
            PlayEpisode(name: '第4集', url: 'https://example.com/4.m3u8'),
          ],
        ),
      ],
    );

VideoDetail _altDetail() => VideoDetail(
      source: 99,
      vodId: 'alt1',
      meta: VideoMeta(name: '庆余年', pic: '', year: '2019', score: '8.0'),
      lines: [
        PlayLine(
          name: '线路A',
          episodes: const [
            PlayEpisode(name: '第1集', url: 'https://example.com/a1.m3u8'),
            PlayEpisode(name: '第2集', url: 'https://example.com/a2.m3u8'),
            PlayEpisode(name: '第3集', url: 'https://example.com/a3.m3u8'),
            PlayEpisode(name: '第4集', url: 'https://example.com/a4.m3u8'),
          ],
        ),
      ],
    );

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init(prefix: 'hao-b16-missing-');
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  tearDown(() {
    Get.reset();
  });

  group('mergeEpisodeChips', () {
    test('missing number inserts before the next larger base episode', () {
      final union = buildEpisodeUnion(base: _baseDetail(), alts: [
        _altDetail(),
      ]);
      final chips = mergeEpisodeChips(
        base: _baseDetail().lines.first.episodes,
        union: union,
      );
      expect(chips.length, 4);
      expect(chips[0].isMissing, isFalse);
      expect(chips[0].epIdx, 0);
      expect(chips[1].isMissing, isFalse);
      expect(chips[1].epIdx, 1);
      expect(chips[2].isMissing, isTrue);
      expect(chips[2].episodeNumber, 3);
      expect(chips[2].target?.source, 99);
      expect(chips[2].target?.vodId, 'alt1');
      expect(chips[3].isMissing, isFalse);
      expect(chips[3].epIdx, 2);
    });

    test('missing number after the end appends', () {
      const base = [
        PlayEpisode(name: '第1集', url: ''),
        PlayEpisode(name: '第2集', url: ''),
      ];
      final union = buildEpisodeUnion(
        base: VideoDetail(
          source: 12,
          vodId: 'v1',
          meta: VideoMeta(name: '剧', year: '2019'),
          lines: const [PlayLine(name: '线路1', episodes: base)],
        ),
        alts: [
          VideoDetail(
            source: 99,
            vodId: 'a',
            meta: VideoMeta(name: '剧', year: '2019'),
            lines: const [
              PlayLine(name: '线路A', episodes: [
                PlayEpisode(name: '第1集', url: ''),
                PlayEpisode(name: '第2集', url: ''),
                PlayEpisode(name: '第3集', url: ''),
              ]),
            ],
          ),
        ],
      );
      final chips = mergeEpisodeChips(base: base, union: union);
      expect(chips.length, 3);
      expect(chips.last.isMissing, isTrue);
      expect(chips.last.episodeNumber, 3);
    });

    test('missing number before the start prepends', () {
      const base = [
        PlayEpisode(name: '第2集', url: ''),
        PlayEpisode(name: '第3集', url: ''),
      ];
      final union = buildEpisodeUnion(
        base: VideoDetail(
          source: 12,
          vodId: 'v1',
          meta: VideoMeta(name: '剧', year: '2019'),
          lines: const [PlayLine(name: '线路1', episodes: base)],
        ),
        alts: [
          VideoDetail(
            source: 99,
            vodId: 'a',
            meta: VideoMeta(name: '剧', year: '2019'),
            lines: const [
              PlayLine(name: '线路A', episodes: [
                PlayEpisode(name: '第1集', url: ''),
                PlayEpisode(name: '第2集', url: ''),
                PlayEpisode(name: '第3集', url: ''),
              ]),
            ],
          ),
        ],
      );
      final chips = mergeEpisodeChips(base: base, union: union);
      expect(chips.length, 3);
      expect(chips.first.isMissing, isTrue);
      expect(chips.first.episodeNumber, 1);
    });

    test('empty union leaves the base order untouched', () {
      final base = _baseDetail().lines.first.episodes;
      final chips = mergeEpisodeChips(base: base, union: const {});
      expect(chips.length, 3);
      expect(chips.map((c) => c.epIdx).toList(), [0, 1, 2]);
      expect(chips.every((c) => !c.isMissing), isTrue);
    });

    test('unparseable base names stay in place', () {
      const base = [
        PlayEpisode(name: '正片', url: ''),
        PlayEpisode(name: '第2集', url: ''),
      ];
      final union = buildEpisodeUnion(
        base: VideoDetail(
          source: 12,
          vodId: 'v1',
          meta: VideoMeta(name: '剧', year: '2019'),
          lines: const [PlayLine(name: '线路1', episodes: base)],
        ),
        alts: [
          VideoDetail(
            source: 99,
            vodId: 'a',
            meta: VideoMeta(name: '剧', year: '2019'),
            lines: const [
              PlayLine(name: '线路A', episodes: [
                PlayEpisode(name: '第1集', url: ''),
                PlayEpisode(name: '第2集', url: ''),
              ]),
            ],
          ),
        ],
      );
      final chips = mergeEpisodeChips(base: base, union: union);
      expect(chips.length, 3);
      expect(chips[0].isMissing, isFalse);
      expect(chips[0].epIdx, 0);
      expect(chips[1].isMissing, isTrue);
      expect(chips[1].episodeNumber, 1);
      expect(chips[2].isMissing, isFalse);
      expect(chips[2].epIdx, 1);
    });

    test('numbers the base already has never become missing chips', () {
      final union = buildEpisodeUnion(base: _baseDetail(), alts: [
        _baseDetail(),
      ]);
      final chips = mergeEpisodeChips(
        base: _baseDetail().lines.first.episodes,
        union: union,
      );
      expect(chips.length, 3);
      expect(chips.every((c) => !c.isMissing), isTrue);
    });
  });

  group('detail page missing chips', () {
    Future<void> pumpDetail(
      WidgetTester tester, {
      required VideoDetail base,
      required AltDetailsStreamer altDetails,
    }) async {
      // iPhone-ish 390x844 logical @2x (as in render_video_detail_
      // test.dart): at the default 800x600 viewport the episode row
      // sits below the fold and taps on it miss.
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final service = VideoDetailService(
        fetchDetail: (_, _, {CancelToken? cancelToken}) async => base,
        findAlts: (_, _, _, {CancelToken? cancelToken}) =>
            const Stream.empty(),
      );
      await tester.pumpWidget(
        GetMaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: VideoDetailPage(
            sourceId: base.source,
            vodId: base.vodId,
            detailService: service,
            altDetails: altDetails,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
    }

    // Flush the detail race's 7 s deadline timer (see
    // render_video_detail_test.dart): without this the binding fails
    // on a pending Timer at test end.
    Future<void> flushRace(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 8));
    }

    testWidgets('missing episode renders greyed with an 其他源 badge',
        (tester) async {
      final controller = StreamController<VideoDetail>.broadcast();
      addTearDown(controller.close);
      await pumpDetail(
        tester,
        base: _baseDetail(),
        altDetails: (_, _, _, {CancelToken? cancelToken}) =>
            controller.stream,
      );
      expect(find.text('第3集'), findsNothing);
      expect(find.text('其他源'), findsNothing);

      controller.add(_altDetail());
      // Two pumps: the first delivers the stream event + setState,
      // the second rebuilds with the missing chip.
      await tester.pump();
      await tester.pump();

      expect(find.text('第3集'), findsOneWidget);
      expect(find.text('其他源'), findsOneWidget);
      // Merged count: 3 base + 1 missing.
      expect(find.text('(4)'), findsOneWidget);
      // The missing chip shows its exact number; the gapped base
      // episode shows its own number too (第4集 is `04`, not its
      // row position `03` — otherwise the two cards collide).
      expect(find.text('03'), findsOneWidget);
      // The 4th card sits past the 390-wide fold (ListView builds
      // lazily): drag the episode row left to build it, then assert
      // its number. (scrollUntilVisible cannot be used here: the page
      // has several Scrollables and it requires exactly one.)
      final row = find.ancestor(
        of: find.text('第3集'),
        matching: find.byType(ListView),
      );
      await tester.drag(row, const Offset(-300, 0));
      await tester.pump();
      expect(find.text('04'), findsOneWidget);
      await flushRace(tester);
    });

    testWidgets('tapping a missing chip switches source and plays it',
        (tester) async {
      final controller = StreamController<VideoDetail>.broadcast();
      addTearDown(controller.close);
      await pumpDetail(
        tester,
        base: _baseDetail(),
        altDetails: (_, _, _, {CancelToken? cancelToken}) =>
            controller.stream,
      );
      controller.add(_altDetail());
      // Two pumps: the first delivers the stream event + setState,
      // the second rebuilds with the missing chip.
      await tester.pump();
      await tester.pump();
      expect(find.text('第3集'), findsOneWidget);

      await tester.tap(find.text('第3集'));
      // Build 29 (K): the top bar is fixed — the seven secondary
      // buttons moved into a 更多 CupertinoActionSheet, so the bar
      // is back + title + danmaku + episodes + more (~216 px) and
      // fits the 390 px portrait width. No rotation needed: the
      // player now genuinely renders in portrait.
      await tester.pump();
      await tester.pump();

      // The switch toast proves the tap resolved the episode on the
      // alt source; the player page proves it plays there.
      expect(find.text('已切换片源播放第3集'), findsOneWidget);
      expect(find.byType(NativeVideoPlayerPage), findsOneWidget);
      final player = tester.widget<NativeVideoPlayerPage>(
        find.byType(NativeVideoPlayerPage),
      );
      expect(player.detail.source, 99);
      expect(player.detail.vodId, 'alt1');
      expect(player.initialLineIndex, 0);
      expect(player.initialEpisodeIndex, 2);
      expect(player.initialPosition, 0);

      // Pop the player via the Navigator: the fullscreen player has
      // no back button of its own, so tester.pageBack() cannot find
      // one to tap.
      Navigator.of(tester.element(find.byType(NativeVideoPlayerPage)))
          .pop();
      await tester.pump();
      expect(find.text('已切换片源播放第3集'), findsOneWidget);
      // 30 s, not 8 s: the player opens a fake URL, fails, and its
      // play-time source switch starts a fresh 7 s race timer after
      // the failure surfaces — an 8 s flush can leave it pending.
      await tester.pump(const Duration(seconds: 30));
    });

    testWidgets('empty alt stream adds no chips and never crashes',
        (tester) async {
      await pumpDetail(
        tester,
        base: _baseDetail(),
        altDetails: (_, _, _, {CancelToken? cancelToken}) =>
            const Stream.empty(),
      );
      expect(find.text('第3集'), findsNothing);
      expect(find.text('其他源'), findsNothing);
      expect(find.text('(3)'), findsOneWidget);
      await flushRace(tester);
    });

    testWidgets('a movie never starts the union scan', (tester) async {
      var calls = 0;
      final movie = VideoDetail(
        source: 12,
        vodId: 'm1',
        meta: VideoMeta(name: '流浪地球', pic: '', year: '2019'),
        lines: const [
          PlayLine(name: '正片', episodes: [
            PlayEpisode(name: '正片', url: 'https://example.com/m.mp4'),
          ]),
        ],
      );
      await pumpDetail(
        tester,
        base: movie,
        altDetails: (_, _, _, {CancelToken? cancelToken}) {
          calls++;
          return const Stream.empty();
        },
      );
      expect(calls, 0);
      expect(find.text('正片'), findsWidgets);
      expect(find.text('其他源'), findsNothing);
      await flushRace(tester);
    });
  });
}
