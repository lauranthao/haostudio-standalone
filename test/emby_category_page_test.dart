// Emby tab + category page tests (build 30 audit §17/§18).
//
// Hermetic: the tab/category pages drive EmbyClient with an
// injected fetcher — zero network. The fetcher answers paged
// /Items slices from generated lists (130 movies, 5 series) so
// pagination totals are real, not canned constants.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/video/emby_category_page.dart';
import 'package:standalone/features/video/emby_tab_page.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';

import 'helpers/hive_test_setup.dart';

const _config = EmbyServerConfig(
  baseUrl: 'http://127.0.0.1:8096',
  apiKey: 'test-key-123',
  userId: 'user-1',
);

Map<String, dynamic> _movieJson(int i) => {
      'Id': 'm$i',
      'Name': '电影$i',
      'Type': 'Movie',
      'ProductionYear': 2024,
      'ImageTags': {'Primary': 'tag-m$i'},
    };

Map<String, dynamic> _seriesJson(int i) => {
      'Id': 's$i',
      'Name': '剧集$i',
      'Type': 'Series',
      'ProductionYear': 2023,
      'RecursiveItemCount': 12,
    };

/// Paged fetcher: slices the generated lists by the StartIndex /
/// Limit query params, so the server total (130 / 5) is honoured
/// across pages exactly like a real Emby.
class _PagedFetcher {
  _PagedFetcher({this.moviesFail = false, this.seriesFail = false});

  final bool moviesFail;
  final bool seriesFail;
  final List<String> seenUrls = [];

  static final _movies =
      List.generate(130, (i) => _movieJson(i + 1));
  static final _series = List.generate(5, (i) => _seriesJson(i + 1));

  Map<String, dynamic> _slice(List<Map<String, dynamic>> all, String url) {
    final q = Uri.parse(url).queryParameters;
    final start = int.tryParse(q['StartIndex'] ?? '0') ?? 0;
    final limit = int.tryParse(q['Limit'] ?? '50') ?? 50;
    final end = (start + limit).clamp(0, all.length);
    final items = start < all.length ? all.sublist(start, end) : const [];
    return {'Items': items, 'TotalRecordCount': all.length};
  }

  Future<EmbyResponse> call(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 8),
    CancelToken? cancelToken,
  }) async {
    seenUrls.add(url);
    if (url.contains('System/Info')) {
      return const EmbyResponse(
        statusCode: 200,
        json: {'ServerName': 'Test Emby', 'Version': '4.8.0.0'},
      );
    }
    if (url.contains('/Views')) {
      return const EmbyResponse(statusCode: 200, json: {
        'Items': [
          {'Id': 'lib-m', 'Name': '电影', 'CollectionType': 'movies'},
          {'Id': 'lib-t', 'Name': '剧集', 'CollectionType': 'tvshows'},
          {'Id': 'lib-x', 'Name': '混合', 'CollectionType': 'mixed'},
        ],
      });
    }
    // Library counts first: their URLs also carry IncludeItemTypes.
    if (url.contains('parentId=lib-m')) {
      return const EmbyResponse(
        statusCode: 200,
        json: {'Items': [], 'TotalRecordCount': 130},
      );
    }
    if (url.contains('parentId=lib-t')) {
      return const EmbyResponse(
        statusCode: 200,
        json: {'Items': [], 'TotalRecordCount': 5},
      );
    }
    if (url.contains('parentId=lib-x')) {
      return const EmbyResponse(
        statusCode: 200,
        json: {'Items': [], 'TotalRecordCount': 7},
      );
    }
    if (url.contains('IncludeItemTypes=Movie')) {
      if (moviesFail) {
        return const EmbyResponse(statusCode: 500, json: {});
      }
      return EmbyResponse(statusCode: 200, json: _slice(_movies, url));
    }
    if (url.contains('IncludeItemTypes=Series')) {
      if (seriesFail) {
        return const EmbyResponse(statusCode: 500, json: {});
      }
      return EmbyResponse(statusCode: 200, json: _slice(_series, url));
    }
    return const EmbyResponse(statusCode: 404, json: {});
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-emby-cat-');
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

  setUp(() async {
    HaoHaptics.debugEnabledOverride = false;
    await HiveStore.delete(HiveKeys.embyConfig);
    await HiveStore.delete(HiveKeys.videoTabMode);
    await HiveStore.delete(HiveKeys.embyHomeCache);
    await HiveStore.delete(HiveKeys.videoHistory);
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
  });

  void setPhoneSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder, {
    int tries = 20,
  }) async {
    for (var i = 0; i < tries; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('expected $finder to appear after the canned load');
  }

  Future<void> pumpTab(WidgetTester tester, _PagedFetcher fetcher) async {
    setPhoneSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: EmbyTabPage(
          client: EmbyClient(config: _config, fetcher: fetcher.call),
        ),
      ),
    );
  }

  group('§17 inventory + failure surfacing', () {
    testWidgets('inventory line lists every library with its count',
        (tester) async {
      final fetcher = _PagedFetcher();
      await pumpTab(tester, fetcher);
      await pumpUntilFound(tester, find.text('电影1'));
      await pumpUntilFound(
        tester,
        find.text('媒体库：电影（130） · 剧集（5） · 混合（7）'),
      );
    });

    testWidgets('refresh keeps the loaded depth (no shrink back to 60)',
        (tester) async {
      // Seed the cache with 120 movies, as if the user had already
      // tapped "加载更多" twice.
      final cached = VideoHomeData(
        rows: [
          VideoHomeRow(
            name: '电影',
            count: 120,
            items: List.generate(
              120,
              (i) => VideoItem(
                source: 'emby',
                sourceName: 'Emby',
                vodId: 'm${i + 1}',
                name: '电影${i + 1}',
              ),
            ),
          ),
        ],
        fetchedAt: DateTime.now(),
      );
      await HiveStore.put(
        HiveKeys.embyHomeCache,
        jsonEncode(cached.toJson()),
      );
      final fetcher = _PagedFetcher();
      await pumpTab(tester, fetcher);
      await pumpUntilFound(
        tester,
        find.text('加载更多（已显示 120 / 共 130 部）'),
      );
      // The fresh fetch asked for 120, not 60.
      expect(
        fetcher.seenUrls.any(
          (u) => u.contains('IncludeItemTypes=Movie') && u.contains('Limit=120'),
        ),
        isTrue,
      );
      // Drain the poster image loads (RefererImage → Dio, 8s timeout
      // timers): the test ends right after the row appears, while
      // 120 concurrent image requests are still in flight.
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('one failed rail marks the page stale, not empty',
        (tester) async {
      final fetcher = _PagedFetcher(moviesFail: true);
      await pumpTab(tester, fetcher);
      await pumpUntilFound(tester, find.text('剧集1'));
      expect(find.text('内容可能不是最新'), findsOneWidget);
      expect(find.text('电影1'), findsNothing);
    });

    testWidgets('both rails failed with nothing cached => error, not '
        '“片库是空的”', (tester) async {
      final fetcher = _PagedFetcher(moviesFail: true, seriesFail: true);
      await pumpTab(tester, fetcher);
      await pumpUntilFound(tester, find.text('Emby 加载失败'));
      expect(find.text('Emby 影片加载失败，下拉重试'), findsOneWidget);
      expect(find.text('Emby 片库是空的'), findsNothing);
    });
  });

  group('§18 category page', () {
    testWidgets('movies grid pages to the server total',
        (tester) async {
      final fetcher = _PagedFetcher();
      final client = EmbyClient(config: _config, fetcher: fetcher.call);
      setPhoneSize(tester);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: EmbyCategoryPage(
            client: client,
            kind: EmbyCategoryKind.movies,
            initialItems: (await client.movies(limit: 2)).items,
            total: 130,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('共 130 部'), findsOneWidget);
      expect(find.text('电影1'), findsOneWidget);
      // Fling to the bottom until the last page lands.
      for (var i = 0; i < 30; i++) {
        await tester.fling(
          find.byType(CustomScrollView),
          const Offset(0, -1200),
          3000,
        );
        await tester.pump(const Duration(milliseconds: 200));
        if (find.text('已显示全部 130 部').evaluate().isNotEmpty) break;
      }
      expect(find.text('已显示全部 130 部'), findsOneWidget);
      expect(find.text('电影130'), findsOneWidget);
      // The whole list came from paged fetches, not one giant load.
      expect(
        fetcher.seenUrls
            .where((u) => u.contains('IncludeItemTypes=Movie'))
            .length,
        greaterThan(2),
      );
    });

    testWidgets('tab rail 查看全部 opens the category page',
        (tester) async {
      final fetcher = _PagedFetcher();
      await pumpTab(tester, fetcher);
      await pumpUntilFound(tester, find.text('电影1'));
      await tester.tap(find.text('查看全部 ›').first);
      await tester.pump(const Duration(milliseconds: 200));
      await pumpUntilFound(tester, find.text('共 130 部'));
      expect(find.byType(EmbyCategoryPage), findsOneWidget);
    });

    testWidgets('resume 查看全部 opens Emby-only history (no clear)',
        (tester) async {
      await tester.runAsync(() async {
        await HiveStore.put(
          HiveKeys.videoHistory,
          jsonEncode([
            {
              'source': 'emby',
              'vodId': 'm1',
              'title': 'Emby片',
              'pic': '',
              'picAlt': '',
              'year': '2024',
              'lineIdx': 0,
              'epIdx': 0,
              'epName': '正片',
              'position': 600,
              'duration': 1800,
              'at': DateTime(2026, 11, 22).millisecondsSinceEpoch,
            },
            {
              'source': 12,
              'vodId': 'c1',
              'title': 'CMS片',
              'pic': '',
              'picAlt': '',
              'year': '2023',
              'lineIdx': 0,
              'epIdx': 0,
              'epName': '第1集',
              'position': 600,
              'duration': 1800,
              'at': DateTime(2026, 11, 22).millisecondsSinceEpoch,
            },
          ]),
        );
      });
      final fetcher = _PagedFetcher();
      await pumpTab(tester, fetcher);
      await pumpUntilFound(tester, find.text('Emby片'));
      await tester.tap(find.text('查看全部 ›').first);
      await tester.pump(const Duration(milliseconds: 200));
      await pumpUntilFound(tester, find.text('Emby片'));
      expect(find.text('CMS片'), findsNothing);
      // Filtered scope: no whole-history clear button.
      expect(find.byTooltip('清空历史记录'), findsNothing);
      await drainHiveWrites(tester);
    });
  });
}
