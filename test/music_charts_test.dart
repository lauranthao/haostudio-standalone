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
import 'package:standalone/services/music/music_store.dart';

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
        final path = options.uri.path;
        if (path.contains('v6/playlist/detail')) {
          // Chart detail: the v6 shape importWyPlaylist expects.
          // Empty covers here: the tap-navigation test must not
          // start MusicImageProvider fetches (their 8s timeout
          // timer would still be pending at test end).
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'playlist': {
                  'name': '飙升榜',
                  'trackIds': [
                    {'id': 111},
                    {'id': 222},
                  ],
                },
              },
            ),
          );
          return;
        }
        if (path.contains('song/detail')) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'songs': [
                  {
                    'id': 111,
                    'name': 'First Song',
                    'ar': [
                      {'name': 'Singer'},
                    ],
                    'al': {'name': 'Album', 'picUrl': ''},
                    'dt': 200000,
                  },
                  {
                    'id': 222,
                    'name': 'Second Song',
                    'ar': [
                      {'name': 'Singer2'},
                    ],
                    'al': {'name': 'Album2', 'picUrl': ''},
                    'dt': 180000,
                  },
                ],
              },
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

  group('charts cover cache refresh (v1.1.5)', () {
    /// Fake Dio that answers the toplist AND the playlist-detail chain
    /// (v6 detail -> trackIds, song detail -> songs with covers), so a
    /// chart detail page loads end to end without network.
    MusicApi detailApi() {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final path = options.uri.path;
            if (path.contains('toplist')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: _toplistJson(withCovers: false),
                ),
              );
            } else if (path.contains('v6/playlist/detail')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'playlist': {
                      'name': '飙升榜',
                      'trackIds': [
                        {'id': 111},
                        {'id': 222},
                      ],
                    },
                  },
                ),
              );
            } else if (path.contains('song/detail')) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'songs': [
                      {
                        'id': 111,
                        'name': 'First Song',
                        'ar': [
                          {'name': 'Singer'},
                        ],
                        'al': {
                          'name': 'Album',
                          'picUrl': 'https://127.0.0.1:1/cover1.jpg',
                        },
                        'dt': 200000,
                      },
                      {
                        'id': 222,
                        'name': 'Second Song',
                        'ar': [
                          {'name': 'Singer2'},
                        ],
                        'al': {
                          'name': 'Album2',
                          'picUrl': 'https://127.0.0.1:1/cover2.jpg',
                        },
                        'dt': 180000,
                      },
                    ],
                  },
                ),
              );
            } else {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.unknown,
                ),
              );
            }
          },
        ),
      );
      return MusicApi(dio: dio);
    }

    Future<void> pumpCharts(WidgetTester tester, MusicApi api) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: ChartsPage(api: api),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('opening a chart refreshes a stale cached cover', (
      tester,
    ) async {
      final api = detailApi();
      // Seed a STALE cover: the old code only filled the cache when
      // it was empty, so a weekly #1 change never showed. The
      // expected cover is the fake detail's first song cover
      // (coverHi leaves this URL unchanged). NOTE: do NOT call
      // api.importPlaylist directly here — awaiting a Dio call in a
      // testWidgets body hangs in the fake-async zone; the page
      // drives the same call through pump() below.
      const expected = 'https://127.0.0.1:1/cover1.jpg';
      await MusicStore.setFeatureCover(
        HiveKeys.featureCoverCharts,
        'https://127.0.0.1:1/stale.jpg',
      );
      await pumpCharts(tester, api);
      await tester.tap(find.text('飙升榜'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PlazaDetailPage), findsOneWidget);
      expect(find.text('First Song'), findsOneWidget);
      // The detail page writes the first song's cover on load; let
      // the fire-and-forget Hive put land before asserting.
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        MusicStore.getFeatureCover(HiveKeys.featureCoverCharts),
        expected,
      );
      // Let the cover image's 8s receive-timeout timer fire, or the
      // test ends with a timer still pending.
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a plaza detail open does not touch the charts cache', (
      tester,
    ) async {
      final api = detailApi();
      await MusicStore.setFeatureCover(
        HiveKeys.featureCoverCharts,
        'https://127.0.0.1:1/stale.jpg',
      );
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: PlazaDetailPage(
            playlist: PlaylistSummary(id: '19723756', name: '飙升榜'),
            api: api,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('First Song'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        MusicStore.getFeatureCover(HiveKeys.featureCoverCharts),
        'https://127.0.0.1:1/stale.jpg',
      );
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
