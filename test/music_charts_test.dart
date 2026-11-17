// NetEase charts tests (Beans Discover charts port).
//
// toplist API is real and verified live 2026-11-17 (curl: code 200,
// 65 charts; 飙升/新歌/原创/热歌 are the first four). The page reuses
// PlazaDetailPage — a chart IS a NetEase playlist id — so no new
// track-loading path is tested here; only parse order, the API call,
// the list UI, tap navigation and the error/retry states.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:hive_ce/hive_ce.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/music/charts_page.dart';
import 'package:standalone/features/music/plaza_page.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';

Map<String, dynamic> _toplistJson({bool withCovers = true}) => {
  'code': 200,
  'list': [
    {
      'id': 3778678,
      'name': '热歌榜',
      'coverImgUrl': withCovers ? 'https://127.0.0.1:1/hot.jpg' : '',
      'trackCount': 200,
      'updateFrequency': '每天更新',
    },
    {
      'id': 19723756,
      'name': '飙升榜',
      'coverImgUrl': withCovers ? 'https://127.0.0.1:1/rise.jpg' : '',
      'trackCount': 100,
      'updateFrequency': '刚刚更新',
    },
    {
      'id': 71384707,
      'name': '网易云古典榜',
      'coverImgUrl': withCovers ? 'https://127.0.0.1:1/classic.jpg' : '',
      'trackCount': 100,
      'updateFrequency': '每周四更新',
    },
    {'id': 999, 'name': '', 'coverImgUrl': '', 'trackCount': 0},
    {'id': '', 'name': '无名榜', 'coverImgUrl': '', 'trackCount': 0},
    {
      'id': 2884035,
      'name': '原创榜',
      'coverImgUrl': withCovers ? 'https://127.0.0.1:1/orig.jpg' : '',
      'trackCount': 100,
      'updateFrequency': '每周四更新',
    },
    {
      'id': 3779629,
      'name': '新歌榜',
      'coverImgUrl': withCovers ? 'https://127.0.0.1:1/new.jpg' : '',
      'trackCount': 100,
      'updateFrequency': '每天更新',
    },
  ],
};

MusicApi _fakeApi({int failTimes = 0, bool withCovers = true}) {
  final dio = Dio();
  var calls = 0;
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        calls++;
        if (calls <= failTimes) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.unknown,
            ),
          );
          return;
        }
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: _toplistJson(withCovers: withCovers),
          ),
        );
      },
    ),
  );
  return MusicApi(dio: dio);
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-charts-test-');
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
      'test_charts',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    // Trap (2026-11-17): never `await` box.close() in tearDownAll.
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  group('parseNeteaseCharts', () {
    test('pins 飙升/新歌/原创/热歌 first, rest keep API order', () {
      final charts = MusicApi.parseNeteaseCharts(_toplistJson());
      expect(charts.map((c) => c.name).toList(), [
        '飙升榜',
        '新歌榜',
        '原创榜',
        '热歌榜',
        '网易云古典榜',
      ]);
    });

    test('drops empty id/name, maps cover/desc/trackCount', () {
      final charts = MusicApi.parseNeteaseCharts(_toplistJson());
      expect(charts.length, 5);
      final hot = charts[3];
      expect(hot.id, '3778678');
      expect(hot.cover, 'https://127.0.0.1:1/hot.jpg');
      expect(hot.desc, '每天更新');
      expect(hot.trackCount, 200);
      expect(hot.platform.code, 'wy');
    });
  });

  group('neteaseCharts', () {
    test('fake Dio returns the pinned list', () async {
      final charts = await _fakeApi().neteaseCharts();
      expect(charts.map((c) => c.name).toList(), [
        '飙升榜',
        '新歌榜',
        '原创榜',
        '热歌榜',
        '网易云古典榜',
      ]);
    });

    test('network failure returns empty, never throws', () async {
      final charts = await _fakeApi(failTimes: 99).neteaseCharts();
      expect(charts, isEmpty);
    });
  });

  group('ChartsPage', () {
    Future<void> pumpPage(WidgetTester tester, {MusicApi? api}) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          // No covers in widget tests: MusicImageProvider fetches via
          // Dio with an 8s receive-timeout Timer, which is still pending
          // at test end ("Timer is still pending"). Cover mapping is
          // covered by the parse tests above; rows render the fallback
          // icon container here.
          home: ChartsPage(api: api ?? _fakeApi(withCovers: false)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('rows render with name + update frequency + count', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(find.text('飙升榜'), findsOneWidget);
      expect(find.text('新歌榜'), findsOneWidget);
      expect(find.text('刚刚更新 · 100首'), findsOneWidget);
      expect(find.text('每天更新 · 200首'), findsOneWidget);
    });

    testWidgets('tap a chart pushes PlazaDetailPage', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('飙升榜'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PlazaDetailPage), findsOneWidget);
    });

    testWidgets('failure shows retry; retry reloads the list', (tester) async {
      await pumpPage(tester, api: _fakeApi(failTimes: 1, withCovers: false));
      expect(find.text('排行榜加载失败'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('排行榜加载失败'), findsNothing);
      expect(find.text('飙升榜'), findsOneWidget);
    });
  });
}
