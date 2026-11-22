// b30: detail pages must always have a visible exit.
//
// Regression for "有些画面打开就关不上了": the video and Emby
// detail pages' only back button lived inside the scrolling cover
// hero, so once the user scrolled down there was no visible exit
// (only the edge-swipe gesture) — and the load-failed card had no
// exit at all. Both pages now carry one fixed HaoCoverBackButton
// over the body, in every state (loading / loaded / failed) at any
// scroll offset. These tests open each page, scroll it down (or
// fail its load), and prove the button is still there and really
// pops the page.

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/video/emby_detail_page.dart';
import 'package:standalone/features/video/video_detail_page.dart';
import 'package:standalone/features/video/video_detail_service.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';
import 'package:standalone/widgets/hao_nav_bar.dart';

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
            PlayEpisode(name: '第3集', url: 'https://example.com/ep3.mp4'),
            PlayEpisode(name: '第4集', url: 'https://example.com/ep4.mp4'),
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

// Fixture key: explicitly fake, never a real credential.
const _config = EmbyServerConfig(
  baseUrl: 'http://127.0.0.1:8096',
  apiKey: 'test-key',
  userId: 'user-1',
);

Map<String, dynamic> _movie1() => <String, dynamic>{
      'Id': 'm1',
      'Name': '流浪地球2',
      'Type': 'Movie',
      'ProductionYear': 2023,
      'CommunityRating': 8.3,
      'Genres': const ['科幻'],
      'Overview': '太阳即将毁灭，人类开启流浪地球计划，带着地球逃离太阳系。',
    };

Future<EmbyResponse> _cannedFetcher(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 8),
  CancelToken? cancelToken,
}) async {
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
      ],
    });
  }
  if (url.contains('/Items/m1')) {
    return EmbyResponse(statusCode: 200, json: _movie1());
  }
  if (url.contains('IncludeItemTypes=Movie')) {
    return EmbyResponse(statusCode: 200, json: {
      'Items': [_movie1()],
      'TotalRecordCount': 1,
    });
  }
  return const EmbyResponse(statusCode: 404, json: {});
}

EmbyClient _cannedClient() =>
    EmbyClient(config: _config, fetcher: _cannedFetcher);

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-b30-back-');
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
  });

  ThemeData light() => HaoThemes.of(HaoThemeId.appleGlass).light;

  void setPhoneSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  /// Pump a home page with an opener button, then push [page] onto
  /// it (CupertinoPageRoute, as production does).
  Future<void> pushPage(WidgetTester tester, Widget page) async {
    setPhoneSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  CupertinoPageRoute<void>(builder: (_) => page),
                ),
                child: const Text('HOME'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('HOME'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Tap the one fixed back button and prove the page really pops.
  Future<void> tapBackAndExpectPop(
    WidgetTester tester,
    Type pageType,
  ) async {
    expect(find.byType(HaoCoverBackButton), findsOneWidget);
    await tester.tap(find.byType(HaoCoverBackButton));
    await tester.pump();
    // CupertinoPageRoute's transition is 500 ms: pumping exactly
    // 500 ms leaves the outgoing route in the tree (boundary).
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(pageType), findsNothing);
    expect(find.text('HOME'), findsOneWidget);
  }

  /// Bounded wait (never pumpAndSettle: live timers never let it
  /// return). The detail load's 7 s deadline timer is flushed by
  /// the final 8 s pump, same as render_video_detail_test.dart.
  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder,
  ) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('expected $finder to appear after the load');
  }

  testWidgets('video detail: back button stays after scrolling and pops',
      (tester) async {
    final service = VideoDetailService(
      fetchDetail: (_, _, {CancelToken? cancelToken}) async =>
          _cannedDetail(),
      findAlts: (_, _, _, {CancelToken? cancelToken}) =>
          const Stream.empty(),
    );
    await pushPage(
      tester,
      VideoDetailPage(
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
    );
    await pumpUntilFound(tester, find.text('第1集'));
    await tester.pump(const Duration(seconds: 8));
    // Scroll the cover (and its old back button) off the screen.
    await tester.fling(
      find.byType(CustomScrollView).first,
      const Offset(0, -900),
      1000,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tapBackAndExpectPop(tester, VideoDetailPage);
  });

  testWidgets('video detail: failed load still has a back button and pops',
      (tester) async {
    final service = VideoDetailService(
      fetchDetail: (_, _, {CancelToken? cancelToken}) async =>
          throw Exception('no network'),
      findAlts: (_, _, _, {CancelToken? cancelToken}) =>
          const Stream.empty(),
    );
    await pushPage(
      tester,
      VideoDetailPage(
        sourceId: 12,
        vodId: '93344',
        detailService: service,
      ),
    );
    await pumpUntilFound(tester, find.text('影片加载失败'));
    await tester.pump(const Duration(seconds: 8));
    await tapBackAndExpectPop(tester, VideoDetailPage);
  });

  testWidgets('emby detail: back button stays after scrolling and pops',
      (tester) async {
    final preload =
        (await _cannedClient().movies(libraryId: 'lib-m')).items.first;
    await pushPage(
      tester,
      EmbyDetailPage(
        itemId: 'm1',
        preload: preload,
        client: _cannedClient(),
      ),
    );
    await pumpUntilFound(tester, find.text('正片'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.fling(
      find.byType(CustomScrollView).first,
      const Offset(0, -900),
      1000,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tapBackAndExpectPop(tester, EmbyDetailPage);
  });

  testWidgets('emby detail: failed load still has a back button and pops',
      (tester) async {
    final failing = EmbyClient(
      config: _config,
      fetcher: (_, {headers, timeout = const Duration(seconds: 8),
              cancelToken}) async =>
          const EmbyResponse(statusCode: 404, json: {}),
    );
    await pushPage(
      tester,
      EmbyDetailPage(itemId: 'm1', client: failing),
    );
    await pumpUntilFound(tester, find.text('加载失败'));
    await tester.pump(const Duration(milliseconds: 500));
    await tapBackAndExpectPop(tester, EmbyDetailPage);
  });
}
