// I-影视 (build 29) — widget tests for items 4 / 5 / 10 / 11.
//
//  (4) metadata correction dialog on the detail page (Cupertino
//      fields + Cupertino buttons — chen 铁律：新增界面一律 iOS 原生);
//  (5) spoiler protection on the detail page (hidden synopsis /
//      blurred unwatched cover, tap to reveal);
// (10) category show/hide editor page (rows render from the cached
//      home rows; a switch hides a category and persists the pref);
// (11) single-source rescan (VideoHomeService.rescanSource with a
//      fake CmsClient — the sources page calls it with the real
//      client, so the service test is the hermetic seam).
//
// Harness copied from render_video_detail_test.dart: the detail
// comes from a canned VideoDetailService (no network, no CMS, no
// Douban) and Hive runs on an in-memory test box, so the page's
// fire-and-forget Hive writes resolve without disk I/O in the
// fake zone. The categories page is seeded through the Hive home
// cache, so its real CmsClient is never called (typeMap's cache is
// in-memory only and cannot be seeded — the no-cache empty state
// is therefore NOT widget-tested here; it would hit the live CMS).

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/player/vod_features.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/settings/video_categories_page.dart';
import 'package:standalone/features/video/video_detail_page.dart';
import 'package:standalone/features/video/video_detail_service.dart';
import 'package:standalone/features/video/video_home_service.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/video/cms_client.dart';

VideoDetail _cannedDetail() => VideoDetail(
      source: 12,
      vodId: '93344',
      meta: VideoMeta(
        name: '流浪地球2',
        year: '2023',
        type: '科幻',
        area: '中国大陆',
        score: '8.3',
        actor: '吴京 / 刘德华',
        director: '郭帆',
        content: '太阳即将毁灭，人类开启流浪地球计划，带着地球逃离太阳系。',
      ),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: const [
            PlayEpisode(name: '第1集', url: 'https://example.com/ep1.mp4'),
            PlayEpisode(name: '第2集', url: 'https://example.com/ep2.mp4'),
          ],
        ),
        PlayLine(
          name: '线路2',
          episodes: const [
            PlayEpisode(name: '第1集', url: 'https://example.com/ep1b.mp4'),
            PlayEpisode(name: '第2集', url: 'https://example.com/ep2b.mp4'),
          ],
        ),
      ],
    );

/// Fake CmsClient for item 11: type map + per-row fetch are canned,
/// no network. [failRows] names rows whose re-fetch throws (the old
/// items must survive); [homeData] is what a no-cache rescan falls
/// back to via fetchFresh.
class _FakeCmsClient extends CmsClient {
  _FakeCmsClient({
    required this.typeEntries,
    required this.freshRows,
    this.failRows = const {},
    this.homeData,
  }) : super(sources: const []);

  final Map<String, CmsTypeEntry> typeEntries;
  final Map<String, VideoHomeRow> freshRows;
  final Set<String> failRows;
  final VideoHomeData? homeData;

  @override
  Future<Map<String, CmsTypeEntry>> typeMap({
    CancelToken? cancelToken,
  }) async =>
      typeEntries;

  @override
  Future<VideoHomeRow?> homeRowOne(
    String typeName,
    CmsTypeEntry entry, {
    CancelToken? cancelToken,
  }) async {
    if (failRows.contains(typeName)) throw StateError('fetch failed');
    return freshRows[typeName];
  }

  @override
  Future<VideoHomeData> home({CancelToken? cancelToken}) async =>
      homeData ??
      VideoHomeData(
        rows: const [],
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
}

VideoItem _item(String id, String name) => VideoItem(
      source: 12,
      sourceName: '金鹰',
      vodId: id,
      name: name,
    );

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-b29-voddetail-');
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
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    HaoHaptics.debugEnabledOverride = false;
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  Future<void> pumpDetail(
    WidgetTester tester, {
    String title = '流浪地球2',
  }) async {
    // iPhone-ish 390x844 logical @2x (same as render_video_detail_test).
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final service = VideoDetailService(
      fetchDetail: (_, _, {CancelToken? cancelToken}) async =>
          _cannedDetail(),
      findAlts: (_, _, _, {CancelToken? cancelToken}) =>
          const Stream.empty(),
    );
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: VideoDetailPage(
          sourceId: 12,
          vodId: '93344',
          preload: const VideoItem(
            source: 12,
            sourceName: '金鹰',
            vodId: '93344',
            name: '流浪地球2',
            year: '2023',
          ),
          detailService: service,
        ),
      ),
    );
    // Direct fetch settles immediately; the 0.35 s fade-in + a frame
    // for the applied detail, then the 8 s pump flushes the race's
    // 7 s deadline timer (cancelled on settle, but the test binding
    // fails on any Timer still pending at test end).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 8));
    expect(find.text(title), findsWidgets);
    expect(find.text('第1集'), findsWidgets);
  }

  /// Clear every VOD pref this file touches, so no test inherits
  /// the previous test's override / spoiler switch / category
  /// prefs (the in-memory box is shared by the whole file).
  /// RunAsync: a Hive write awaited directly in the fake zone
  /// never resolves.
  Future<void> resetVodPrefs(WidgetTester tester) async {
    await tester.runAsync(
      () => Future.wait([
        HiveStore.delete(HiveKeys.vodMetadataOverrides),
        HiveStore.delete(HiveKeys.vodSpoilerHideSynopsis),
        HiveStore.delete(HiveKeys.vodSpoilerBlurUnwatched),
        HiveStore.delete(HiveKeys.vodCategoryPrefs),
      ]),
    );
  }

  /// Open the 纠错 dialog (edit circle, Icons.edit) and settle the
  /// glass dialog's entrance.
  Future<void> openCorrectionDialog(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.edit));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('纠错'), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsNWidgets(3));
  }

  /// Close the dialog by tapping a Cupertino button label, then let
  /// the pop animation finish (same two-pump rule as the VOD sleep
  /// sheet: the tap fires during the first pump).
  Future<void> tapDialogButton(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('纠错'), findsNothing);
  }

  group('4. metadata correction dialog', () {
    testWidgets('edit title + save: page shows it, override persists',
        (tester) async {
      await resetVodPrefs(tester);
      await pumpDetail(tester);
      await openCorrectionDialog(tester);
      // Fields are title / year / poster, in order.
      await tester.enterText(
        find.byType(CupertinoTextField).first,
        '流浪地球3',
      );
      await tapDialogButton(tester, '保存');
      await tester.pump();
      expect(find.text('流浪地球3'), findsWidgets);
      expect(find.text('流浪地球2'), findsNothing);
      final saved = metadataOverrideFor(12, '93344');
      expect(saved, isNotNull);
      expect(saved!.title, '流浪地球3');
    });

    testWidgets('restore default clears the override',
        (tester) async {
      await resetVodPrefs(tester);
      // Seed a correction first (runAsync: Hive write in the
      // fake zone must go through the real zone).
      await tester.runAsync(
        () => saveMetadataOverride(
          source: 12,
          vodId: '93344',
          override: const VodMetadataOverride(title: '流浪地球3'),
        ),
      );
      await pumpDetail(tester, title: '流浪地球3');
      await openCorrectionDialog(tester);
      await tapDialogButton(tester, '恢复默认');
      await tester.pump();
      expect(find.text('流浪地球2'), findsWidgets);
      expect(metadataOverrideFor(12, '93344'), isNull);
    });

    testWidgets('blank title keeps the source value', (tester) async {
      await resetVodPrefs(tester);
      await pumpDetail(tester);
      await openCorrectionDialog(tester);
      await tester.enterText(find.byType(CupertinoTextField).first, '');
      await tapDialogButton(tester, '保存');
      await tester.pump();
      expect(find.text('流浪地球2'), findsWidgets);
      expect(metadataOverrideFor(12, '93344')?.title, isNull);
    });
  });

  group('5. spoiler protection', () {
    testWidgets('hide synopsis: placeholder + tap to reveal',
        (tester) async {
      await resetVodPrefs(tester);
      await tester.runAsync(
        () => HiveStore.put(HiveKeys.vodSpoilerHideSynopsis, true),
      );
      await pumpDetail(tester);
      expect(find.text('简介已隐藏（防剧透）'), findsOneWidget);
      expect(find.textContaining('太阳即将毁灭'), findsNothing);
      // The synopsis sits below the fold on the 390x844 surface:
      // scroll it into view first, or the tap hits nothing (same
      // off-screen-tap trap as the VOD sleep sheet rows).
      await tester.ensureVisible(find.text('查看简介'));
      await tester.pump();
      await tester.tap(find.text('查看简介'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('太阳即将毁灭'), findsOneWidget);
      expect(find.text('简介已隐藏（防剧透）'), findsNothing);
    });

    testWidgets('blur unwatched cover: tap to reveal', (tester) async {
      await resetVodPrefs(tester);
      await tester.runAsync(
        () => HiveStore.put(HiveKeys.vodSpoilerBlurUnwatched, true),
      );
      await pumpDetail(tester);
      // Fresh Hive = no watch history, so the cover is blurred.
      expect(find.text('点按查看海报'), findsOneWidget);
      await tester.tap(find.text('点按查看海报'));
      await tester.pump();
      expect(find.text('点按查看海报'), findsNothing);
    });

    testWidgets('spoiler off: synopsis shows directly', (tester) async {
      await resetVodPrefs(tester);
      await pumpDetail(tester);
      expect(find.textContaining('太阳即将毁灭'), findsOneWidget);
      expect(find.text('简介已隐藏（防剧透）'), findsNothing);
      expect(find.text('点按查看海报'), findsNothing);
    });
  });

  group('10. category editor page', () {
    Future<void> seedHomeCache(WidgetTester tester) async {
      final data = VideoHomeData(
        rows: [
          VideoHomeRow(name: '电影', count: 2, items: [
            _item('1', '片一'),
            _item('2', '片二'),
          ]),
          VideoHomeRow(name: '电视剧', count: 1, items: [
            _item('3', '剧一'),
          ]),
          VideoHomeRow(name: '综艺', count: 1, items: [
            _item('4', '综一'),
          ]),
        ],
        fetchedAt: DateTime.now(),
      );
      await tester.runAsync(
        () => HiveStore.put(
          HiveKeys.videoHomeCache,
          jsonEncode(data.toJson()),
        ),
      );
    }

    Future<void> pumpCategories(WidgetTester tester) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const VideoCategoriesPage(),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    testWidgets('rows render from cache; switch hides + persists',
        (tester) async {
      await resetVodPrefs(tester);
      await seedHomeCache(tester);
      await pumpCategories(tester);
      expect(find.text('电影'), findsOneWidget);
      expect(find.text('电视剧'), findsOneWidget);
      expect(find.text('综艺'), findsOneWidget);
      // Switches are in row order: 电影 / 电视剧 / 综艺.
      final switches = find.byType(CupertinoSwitch);
      expect(switches, findsNWidgets(3));
      expect(tester.widget<CupertinoSwitch>(switches.at(1)).value, isTrue);
      await tester.tap(switches.at(1));
      await tester.pump();
      // The page persists fire-and-forget: let the write land.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(tester.widget<CupertinoSwitch>(switches.at(1)).value, isFalse);
      expect(readCategoryPrefs().hidden, contains('电视剧'));
      expect(
        readCategoryPrefs().hidden,
        isNot(contains('电影')),
      );
      // Reset for the next test (same in-memory box).
      await tester.runAsync(
        () => HiveStore.delete(HiveKeys.vodCategoryPrefs),
      );
    });

    testWidgets('hidden pref hides the row on next open',
        (tester) async {
      await resetVodPrefs(tester);
      await seedHomeCache(tester);
      await tester.runAsync(
        () => saveCategoryPrefs(
          const VideoCategoryPrefs(hidden: {'综艺'}),
        ),
      );
      await pumpCategories(tester);
      expect(find.text('电影'), findsOneWidget);
      expect(find.text('电视剧'), findsOneWidget);
      expect(find.text('综艺'), findsOneWidget,
          reason: 'the editor lists hidden rows too (switch off)');
      expect(
        tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch).at(2))
            .value,
        isFalse,
      );
      await tester.runAsync(
        () => HiveStore.delete(HiveKeys.vodCategoryPrefs),
      );
    });
  });

  group('11. single-source rescan', () {
    const source12 = VideoSource(
      id: 12,
      name: '金鹰',
      apiUrl: 'https://example.com/api.php/provide/vod',
    );

    Map<String, CmsTypeEntry> typeMapFor({required List<String> owned}) =>
        {
          for (final name in owned)
            name: CmsTypeEntry(
              source: 12,
              sourceName: '金鹰',
              typeId: 't-$name',
            ),
        };

    Future<void> seedCache(List<VideoHomeRow> rows) async {
      final data = VideoHomeData(rows: rows, fetchedAt: DateTime.now());
      await HiveStore.put(
        HiveKeys.videoHomeCache,
        jsonEncode(data.toJson()),
      );
    }

    test('replaces owned rows, keeps order + other rows', () async {
      await seedCache([
        VideoHomeRow(name: '电影', count: 1, items: [_item('1', '旧片')]),
        VideoHomeRow(name: '电视剧', count: 1, items: [_item('3', '旧剧')]),
        VideoHomeRow(name: '综艺', count: 1, items: [_item('4', '旧综')]),
      ]);
      final cms = _FakeCmsClient(
        typeEntries: typeMapFor(owned: ['电影', '电视剧']),
        freshRows: {
          '电影': VideoHomeRow(name: '电影', count: 1, items: [
            _item('10', '新片'),
          ]),
          '电视剧': VideoHomeRow(name: '电视剧', count: 1, items: [
            _item('30', '新剧'),
          ]),
        },
      );
      final updated =
          await VideoHomeService(cms: cms).rescanSource(source12);
      expect(updated, isNotNull);
      expect(
        updated!.rows.map((r) => r.name).toList(),
        ['电影', '电视剧', '综艺'],
      );
      expect(updated.rows[0].items.single.name, '新片');
      expect(updated.rows[1].items.single.name, '新剧');
      expect(updated.rows[2].items.single.name, '旧综');
      // And the merged data was saved to the cache.
      final cached = VideoHomeService(cms: cms).loadCached();
      expect(cached!.rows[0].items.single.name, '新片');
    });

    test('failed row keeps its old items', () async {
      await seedCache([
        VideoHomeRow(name: '电影', count: 1, items: [_item('1', '旧片')]),
        VideoHomeRow(name: '电视剧', count: 1, items: [_item('3', '旧剧')]),
      ]);
      final cms = _FakeCmsClient(
        typeEntries: typeMapFor(owned: ['电影', '电视剧']),
        freshRows: {
          '电影': VideoHomeRow(name: '电影', count: 1, items: [
            _item('10', '新片'),
          ]),
        },
        failRows: {'电视剧'},
      );
      final updated =
          await VideoHomeService(cms: cms).rescanSource(source12);
      expect(updated, isNotNull);
      expect(updated!.rows[0].items.single.name, '新片');
      expect(updated.rows[1].items.single.name, '旧剧');
    });

    test('source owns no home row -> null', () async {
      await seedCache([
        VideoHomeRow(name: '电影', count: 1, items: [_item('1', '旧片')]),
      ]);
      final cms = _FakeCmsClient(
        typeEntries: typeMapFor(owned: ['电影']),
        freshRows: const {},
      );
      const other = VideoSource(
        id: 99,
        name: '仅搜索源',
        apiUrl: 'https://example.com/other',
      );
      expect(
        await VideoHomeService(cms: cms).rescanSource(other),
        isNull,
      );
    });

    test('no cache -> falls back to a fresh fetch', () async {
      await HiveStore.delete(HiveKeys.videoHomeCache);
      final cms = _FakeCmsClient(
        typeEntries: const {},
        freshRows: const {},
        homeData: VideoHomeData(
          rows: [
            VideoHomeRow(name: '电影', count: 1, items: [_item('1', '片一')]),
          ],
          fetchedAt: DateTime.now(),
        ),
      );
      final updated =
          await VideoHomeService(cms: cms).rescanSource(source12);
      expect(updated, isNotNull);
      expect(updated!.rows.single.name, '电影');
    });
  });
}
