// Douban year-matching tests (P1-14).
//
// The old `_suggestId` took `arr[0].id` with no title/year check and
// the title→id map never expired, so one same-name mismatch (remake,
// sequel, same-name series) poisoned every later open. These tests
// prove, with a fake transport + memory cache (and a Hive box for the
// TTL / self-heal cases):
// - same title, different years: the id whose year matches wins,
//   whichever order suggest returns them;
// - a year gap > 1: no id is cached and detail() shows nothing
//   (both the suggest-stage and the abstract-stage guard);
// - no year info anywhere: title matching still works;
// - a normal exact title+year match behaves exactly as before
//   (cached second resolve does no new fetch);
// - a season title's CMS year belongs to the season, not the base
//   series, so it must not block the series entry;
// - the title→id TTL: legacy bare-String entries and entries older
//   than 7 days read as expired, fresh stamped entries read back,
//   and a legacy wrong entry self-heals on the next resolve.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/video/douban_parsers.dart';
import 'package:standalone/services/video/douban_service.dart';

typedef TestDoubanFetcher = Future<({int status, String body})> Function(
  String url,
  Map<String, String> headers, {
  Duration timeout,
});

const _abstract2020 =
    '{"r":0,"subject":{"id":222,"title":"同名片","rate":"8.0","release_year":"2020","is_tv":false,"directors":["导演甲"],"actors":["演员甲"],"types":["剧情"],"region":"中国大陆","duration":"100分钟"}}';
const _abstract1994 =
    '{"r":0,"subject":{"id":111,"title":"同名片","rate":"7.0","release_year":"1994","is_tv":false,"directors":["导演乙"],"actors":["演员乙"],"types":["剧情"],"region":"中国大陆","duration":"90分钟"}}';
const _mpage =
    '<meta property="og:image" content="https://img9.doubanio.com/view/photo/s_ratio_poster/public/p9.jpg"><meta itemprop="description" content="豆瓣评分：8.0 简介：简介。"><meta itemprop="ratingValue" content="8.0">';

TestDoubanFetcher fetcherFor({
  required String suggestBody,
  String abstractBody = _abstract2020,
}) {
  return (
    String url,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (url.contains('subject_suggest')) {
      return (status: 200, body: suggestBody);
    }
    if (url.contains('subject_abstract')) {
      return (status: 200, body: abstractBody);
    }
    if (url.contains('m.douban.com')) {
      return (status: 200, body: _mpage);
    }
    return (status: 404, body: '');
  };
}

void main() {
  group('Douban year matching (fake transport + memory cache)', () {
    test(
      'same title, different years: matching year wins, either order',
      () async {
        const wrongFirst =
            '[{"id":"111","title":"同名片","type":"movie","year":"1994"},'
            '{"id":"222","title":"同名片","type":"movie","year":"2020"}]';
        const rightFirst =
            '[{"id":"222","title":"同名片","type":"movie","year":"2020"},'
            '{"id":"111","title":"同名片","type":"movie","year":"1994"}]';
        final a = DoubanService(
          fetcher: fetcherFor(suggestBody: wrongFirst),
          cache: MemoryDoubanCache(),
        );
        expect(await a.resolveId('同名片', year: 2020), '222');
        final b = DoubanService(
          fetcher: fetcherFor(suggestBody: rightFirst),
          cache: MemoryDoubanCache(),
        );
        expect(await b.resolveId('同名片', year: 1994), '111');
      },
    );

    test(
      'year gap over 1: suggest mismatch resolves to null, caches nothing',
      () async {
        const only1994 =
            '[{"id":"111","title":"同名片","type":"movie","year":"1994"}]';
        final cache = MemoryDoubanCache();
        final service = DoubanService(
          fetcher: fetcherFor(suggestBody: only1994),
          cache: cache,
        );
        expect(await service.resolveId('同名片', year: 2020), isNull);
        expect(cache.idForTitle(doubanTitleKey('同名片')), isNull);
        // detail() also finds nothing (suggest no match → search 404 →
        // no builtin) and shows no wrong score/poster.
        expect(await service.detail('同名片', '2020'), isNull);
      },
    );

    test(
      'abstract year mismatch: not cached, not shown, link evicted',
      () async {
        // Suggest carries no year, so the title-only pick is the 1994
        // film; the abstract then proves it is the wrong year.
        const noYear = '[{"id":"111","title":"同名片","type":"movie"}]';
        final cache = MemoryDoubanCache();
        final service = DoubanService(
          fetcher: fetcherFor(suggestBody: noYear, abstractBody: _abstract1994),
          cache: cache,
        );
        final d = await service.detail('同名片', '2020');
        expect(d, isNull);
        // The wrong title→id link is dropped, and the wrong detail was
        // never cached: the next open re-resolves instead of repeating.
        expect(cache.idForTitle(doubanTitleKey('同名片')), isNull);
        expect(cache.detail('111'), isNull);
      },
    );

    test('no year anywhere: title matching still works', () async {
      const noYear = '[{"id":"222","title":"同名片","type":"movie"}]';
      final service = DoubanService(
        fetcher: fetcherFor(suggestBody: noYear),
        cache: MemoryDoubanCache(),
        castPhotoFetcher: (_) async => '',
      );
      expect(await service.resolveId('同名片'), '222');
      final d = await service.detail('同名片', '');
      expect(d, isNotNull);
      expect(d!.id, '222');
      expect(d.score, '8.0');
    });

    test('normal exact title+year match behaves as before', () async {
      var calls = 0;
      Future<({int status, String body})> counting(
        String url,
        Map<String, String> headers, {
        Duration timeout = const Duration(seconds: 10),
      }) async {
        calls++;
        return fetcherFor(
          suggestBody: '[{"id":"35267208","title":"流浪地球2","type":"movie","year":"2023"}]',
          abstractBody: '{"r":0,"subject":{"id":35267208,"title":"流浪地球2","rate":"8.3","release_year":"2023","is_tv":false,"directors":["郭帆"],"actors":["吴京"],"types":["科幻"],"region":"中国大陆","duration":"172分钟"}}',
        )(url, headers, timeout: timeout);
      }

      final cache = MemoryDoubanCache();
      final service = DoubanService(
        fetcher: counting,
        cache: cache,
        castPhotoFetcher: (_) async => '',
      );
      expect(await service.resolveId('流浪地球2', year: 2023), '35267208');
      final callsAfterResolve = calls;
      expect(await service.resolveId('流浪地球2', year: 2023), '35267208');
      expect(calls, callsAfterResolve);
      final d = await service.detail('流浪地球2', '2023');
      expect(d, isNotNull);
      expect(d!.score, '8.3');
      expect(d.poster, contains('p9.jpg'));
    });

    test(
      'season title: CMS season year does not block the series entry',
      () async {
        // 庆余年第二季 (CMS year 2024) resolves to the 庆余年 series
        // entry (2019) — the year belongs to the season, not the base.
        final service = DoubanService(
          fetcher: fetcherFor(
            suggestBody:
                '[{"id":"25853071","title":"庆余年","type":"tv","year":"2019"}]',
            abstractBody: '{"r":0,"subject":{"id":25853071,"title":"庆余年 第一季","rate":"7.9","release_year":"2019","is_tv":true,"directors":["孙皓"],"actors":["张若昀"],"types":["剧情"],"region":"中国大陆","duration":"45分钟"}}',
          ),
          cache: MemoryDoubanCache(),
          castPhotoFetcher: (_) async => '',
        );
        final d = await service.detail('庆余年第二季', '2024');
        expect(d, isNotNull);
        expect(d!.id, '25853071');
        expect(d.score, '7.9');
      },
    );
  });

  group('Douban title→id TTL + self-heal (Hive box)', () {
    late Directory hiveDir;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      hiveDir = await Directory.systemTemp.createTemp('hao-douban-ttl-');
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
      await HiveStore.box.delete(HiveKeys.doubanIdmap);
      await HiveStore.box.delete(HiveKeys.doubanDetail);
    });

    test('legacy bare-String entry reads as expired', () async {
      await HiveStore.put(
        HiveKeys.doubanIdmap,
        jsonEncode({doubanTitleKey('流浪地球2'): '35267208'}),
      );
      expect(HiveDoubanCache().idForTitle(doubanTitleKey('流浪地球2')), isNull);
    });

    test(
      'entry older than 7 days reads as expired, fresh one reads back',
      () async {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        await HiveStore.put(
          HiveKeys.doubanIdmap,
          jsonEncode({
            doubanTitleKey('流浪地球2'): {
              'id': '35267208',
              'at': nowMs - const Duration(days: 8).inMilliseconds,
            },
          }),
        );
        expect(HiveDoubanCache().idForTitle(doubanTitleKey('流浪地球2')), isNull);
        await HiveStore.put(
          HiveKeys.doubanIdmap,
          jsonEncode({
            doubanTitleKey('流浪地球2'): {'id': '35267208', 'at': nowMs},
          }),
        );
        expect(
          HiveDoubanCache().idForTitle(doubanTitleKey('流浪地球2')),
          '35267208',
        );
      },
    );

    test('legacy wrong entry self-heals on the next resolve', () async {
      // The permanently-cached P1-14 mismatch, as stored before the
      // TTL existed: a bare String with the wrong id.
      await HiveStore.put(
        HiveKeys.doubanIdmap,
        jsonEncode({doubanTitleKey('流浪地球2'): '999'}),
      );
      final service = DoubanService(
        fetcher: fetcherFor(
          suggestBody: '[{"id":"35267208","title":"流浪地球2","type":"movie","year":"2023"}]',
        ),
        cache: HiveDoubanCache(),
      );
      expect(await service.resolveId('流浪地球2', year: 2023), '35267208');
      // The re-resolved id is stored stamped, so the next read trusts
      // it (and the wrong '999' is gone).
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(HiveDoubanCache().idForTitle(doubanTitleKey('流浪地球2')), '35267208');
    });
  });
}
