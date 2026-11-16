// Video source defaults merge tests.
//
// Proves VideoSourcesStore.getAll() merges new defaults into an
// already-persisted source list, once per kVideoSourcesRevision:
// - a new default source (非凡主站, rev 2) is appended for existing
//   installs without a "reset to defaults";
// - matched defaults get their `sort` refreshed from the current
//   defaults (fast first, slow last) while the user's `enabled`
//   toggle is never touched;
// - a source the user deliberately deleted is never resurrected by
//   a later load (revision guard).

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
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-sources-test-');
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

  test('no persisted list returns the 18 defaults incl. 非凡主站', () {
    final list = VideoSourcesStore.getAll();
    expect(list.length, 18);
    expect(
      list.any((s) => s.apiUrl == 'http://cj.ffzyapi.com/api.php/provide/vod'),
      isTrue,
    );
    expect(
      VideoSourcesStore.getEnabled().first.apiUrl,
      'http://jyzyapi.com/api.php/provide/vod',
    );
  });

  test('merge appends missing defaults, refreshes sort, keeps enabled', () async {
    await seedSources(const [
      VideoSource(
        id: 12,
        name: '金鹰资源',
        apiUrl: 'http://jyzyapi.com/api.php/provide/vod',
        sort: 5,
      ),
      VideoSource(
        id: 8,
        name: '极速资源',
        apiUrl: 'https://jszyapi.com/api.php/provide/vod',
        sort: 14, // stale: current default is 10
      ),
      VideoSource(
        id: 16,
        name: '如意资源',
        apiUrl: 'https://cj.rycjapi.com/api.php/provide/vod',
        enabled: false, // user disabled it
        sort: 15, // stale: current default is 21
      ),
    ]);
    final list = VideoSourcesStore.getAll();
    expect(list.length, 18);
    final feifanMain = list.firstWhere(
      (s) => s.apiUrl == 'http://cj.ffzyapi.com/api.php/provide/vod',
    );
    expect(feifanMain.name, '非凡主站');
    expect(feifanMain.sort, 7);
    final jisu = list.firstWhere(
      (s) => s.apiUrl == 'https://jszyapi.com/api.php/provide/vod',
    );
    expect(jisu.sort, 10);
    final ruyi = list.firstWhere(
      (s) => s.apiUrl == 'https://cj.rycjapi.com/api.php/provide/vod',
    );
    expect(ruyi.enabled, isFalse);
    expect(ruyi.sort, 21);
    // Fire-and-forget persist from the merge must have landed.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(HiveStore.box.get(HiveKeys.videoSourcesRevision), 2);
  });

  test('a user-deleted source is not resurrected on the next load', () async {
    await seedSources(kDefaultVideoSources);
    // First load runs the merge and bumps the revision.
    expect(VideoSourcesStore.getAll().length, 18);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // User deletes 360 in settings.
    final kept = VideoSourcesStore.getAll()
        .where((s) => s.apiUrl != 'https://360zy.com/api.php/provide/vod')
        .toList();
    await VideoSourcesStore.save(kept);
    final again = VideoSourcesStore.getAll();
    expect(again.length, 17);
    expect(
      again.any((s) => s.apiUrl == 'https://360zy.com/api.php/provide/vod'),
      isFalse,
    );
  });
}
