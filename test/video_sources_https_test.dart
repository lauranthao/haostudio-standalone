// CMS sources https upgrade tests (P1-10).
//
// Proves, after the 2026-11-19 curl verification (all three http
// hosts answer real CMS requests over https):
// - all 18 default sources are https (no http default left);
// - the plain-http helper used by the settings page to warn before
//   adding a user-typed http source;
// - the rev-3 merge upgrades a stored http twin to its https twin IN
//   PLACE: same id, the user's sort and enabled toggle untouched, no
//   duplicate source appended, and the revision stored as 5.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/video/cms_sources.dart';
import 'package:standalone/features/video/video_history_store.dart';
import 'package:standalone/features/video/video_models.dart';

void main() {
  test('all 18 default sources are https', () {
    expect(kDefaultVideoSources.length, 18);
    for (final s in kDefaultVideoSources) {
      expect(
        s.apiUrl.startsWith('https://'),
        isTrue,
        reason: '${s.name} still uses ${s.apiUrl}',
      );
    }
    expect(
      kDefaultVideoSources.firstWhere((s) => s.name == '金鹰资源').apiUrl,
      'https://jyzyapi.com/api.php/provide/vod',
    );
    expect(
      kDefaultVideoSources.firstWhere((s) => s.name == '非凡资源').apiUrl,
      'https://ffzy5.tv/api.php/provide/vod',
    );
    expect(
      kDefaultVideoSources.firstWhere((s) => s.name == '非凡主站').apiUrl,
      'https://cj.ffzyapi.com/api.php/provide/vod',
    );
    expect(kVideoSourcesRevision, 5);
  });

  test('isPlainHttpVideoSourceUrl', () {
    expect(
      isPlainHttpVideoSourceUrl('http://jyzyapi.com/api.php/provide/vod'),
      isTrue,
    );
    expect(
      isPlainHttpVideoSourceUrl('HTTP://example.com/api.php/provide/vod'),
      isTrue,
    );
    expect(isPlainHttpVideoSourceUrl('  http://example.com/x'), isTrue);
    expect(
      isPlainHttpVideoSourceUrl('https://jyzyapi.com/api.php/provide/vod'),
      isFalse,
    );
    expect(isPlainHttpVideoSourceUrl('ftp://example.com/x'), isFalse);
    expect(isPlainHttpVideoSourceUrl(''), isFalse);
  });

  group('rev-4 merge upgrades stored http twins in place', () {
    late Directory hiveDir;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      hiveDir = await Directory.systemTemp.createTemp('hao-sources-https-');
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
      await HiveStore.box.delete(HiveKeys.videoSources);
      await HiveStore.box.delete(HiveKeys.videoSourcesRevision);
    });

    Future<void> seedSources(List<VideoSource> sources) async {
      await HiveStore.put(
        HiveKeys.videoSources,
        jsonEncode(sources.map((s) => s.toJson()).toList()),
      );
    }

    test(
      'http twins become https, user sort/enabled kept, no duplicates',
      () async {
        await seedSources(const [
          VideoSource(
            id: 12,
            name: '金鹰资源',
            apiUrl: 'http://jyzyapi.com/api.php/provide/vod',
            enabled: false, // user disabled it
            sort: 0, // user moved it to the top
          ),
          VideoSource(
            id: 18,
            name: '非凡主站',
            apiUrl: 'http://cj.ffzyapi.com/api.php/provide/vod',
            sort: 3, // user-moved order
          ),
          VideoSource(
            id: 8,
            name: '极速资源',
            apiUrl: 'https://jszyapi.com/api.php/provide/vod',
            sort: 14, // stale: current default is 10
          ),
        ]);
        final list = VideoSourcesStore.getAll();
        expect(list.length, 18);
        // No http apiUrl survives, and no source appears twice.
        expect(list.any((s) => s.apiUrl.startsWith('http://')), isFalse);
        expect(list.map((s) => s.apiUrl).toSet().length, list.length);
        final jinying = list.firstWhere((s) => s.name == '金鹰资源');
        expect(jinying.apiUrl, 'https://jyzyapi.com/api.php/provide/vod');
        expect(jinying.sort, 0); // user's order, not reset to default 5
        expect(jinying.enabled, isFalse); // user's toggle kept
        final feifanMain = list.firstWhere((s) => s.name == '非凡主站');
        expect(feifanMain.apiUrl, 'https://cj.ffzyapi.com/api.php/provide/vod');
        expect(feifanMain.sort, 3); // user's order, not reset to default 7
        // An exact https match still gets its sort refreshed per the
        // standing merge rule.
        final jisu = list.firstWhere((s) => s.name == '极速资源');
        expect(jisu.sort, 10);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(HiveStore.box.get(HiveKeys.videoSourcesRevision), 5);
      },
    );
  });
}
