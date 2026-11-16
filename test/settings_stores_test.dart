// Settings stores tests — music / live / danmaku source settings and
// cache sizes, all Hive-backed through an injected test box (no
// HiveStore.init, no platform channels). Also covers the uninitialised
//-Hive fallback: services that read the stores before HiveStore.init
// (e.g. CmsClient in unit tests) get shipped defaults, never a crash.

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/settings/cache_service.dart';
import 'package:standalone/features/settings/source_stores.dart';
import 'package:standalone/features/video/cms_sources.dart';
import 'package:standalone/features/video/video_history_store.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/video/cms_client.dart';
import 'package:standalone/shared/platforms/sites.dart';

void main() {
  late Box<dynamic> box;

  setUp(() async {
    Hive.init('test/.hive-settings-test');
    box = await Hive.openBox<dynamic>('settings_test');
    await box.clear();
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('settings_test');
  });

  group('MusicSourcesStore', () {
    test('defaults to all four search platforms', () {
      expect(MusicSourcesStore.enabled(box: box), kSearchPlatforms);
    });

    test('disabling one platform persists', () async {
      expect(
        await MusicSourcesStore.setEnabled(MusicPlatform.kg, false, box: box),
        isTrue,
      );
      expect(MusicSourcesStore.enabled(box: box), [
        MusicPlatform.wy,
        MusicPlatform.tx,
        MusicPlatform.kw,
      ]);
      expect(MusicSourcesStore.isEnabled(MusicPlatform.kg, box: box), isFalse);
      // Re-enabling restores merge order.
      await MusicSourcesStore.setEnabled(MusicPlatform.kg, true, box: box);
      expect(MusicSourcesStore.enabled(box: box), kSearchPlatforms);
    });

    test('disabling the last platform is refused', () async {
      for (final pf in [MusicPlatform.wy, MusicPlatform.tx, MusicPlatform.kg]) {
        expect(await MusicSourcesStore.setEnabled(pf, false, box: box), isTrue);
      }
      expect(
        await MusicSourcesStore.setEnabled(MusicPlatform.kw, false, box: box),
        isFalse,
      );
      expect(MusicSourcesStore.enabled(box: box), [MusicPlatform.kw]);
    });

    test('corrupt stored value falls back to defaults', () async {
      await box.put(HiveKeys.musicSources, 'not json{');
      expect(MusicSourcesStore.enabled(box: box), kSearchPlatforms);
      await box.put(HiveKeys.musicSources, '[]');
      expect(MusicSourcesStore.enabled(box: box), kSearchPlatforms);
      await box.put(HiveKeys.musicSources, '["bogus","wy"]');
      expect(MusicSourcesStore.enabled(box: box), [MusicPlatform.wy]);
    });
  });

  group('LiveSourcesStore', () {
    test('defaults to all five platforms', () {
      expect(LiveSourcesStore.enabledIds(box: box), Sites.supportedSiteIds);
    });

    test('disabling one platform persists', () async {
      expect(
        await LiveSourcesStore.setEnabled('douyin', false, box: box),
        isTrue,
      );
      expect(LiveSourcesStore.enabledIds(box: box), [
        'bilibili',
        'douyu',
        'huya',
        'kuaishou',
      ]);
    });

    test('disabling the last platform is refused', () async {
      for (final id in ['bilibili', 'douyu', 'huya', 'douyin']) {
        expect(await LiveSourcesStore.setEnabled(id, false, box: box), isTrue);
      }
      expect(
        await LiveSourcesStore.setEnabled('kuaishou', false, box: box),
        isFalse,
      );
      expect(LiveSourcesStore.enabledIds(box: box), ['kuaishou']);
    });

    test('corrupt stored value falls back to defaults', () async {
      await box.put(HiveKeys.liveSources, '{"x":1}');
      expect(LiveSourcesStore.enabledIds(box: box), Sites.supportedSiteIds);
    });
  });

  group('DanmakuSettings', () {
    test('defaults: all platforms on, size 14, opacity 1.0', () {
      for (final id in Sites.supportedSiteIds) {
        expect(DanmakuSettings.isEnabled(id, box: box), isTrue);
      }
      expect(DanmakuSettings.fontSize(box: box), 14);
      expect(DanmakuSettings.opacity(box: box), 1.0);
    });

    test('per-platform toggle persists', () async {
      await DanmakuSettings.setEnabled('huya', false, box: box);
      expect(DanmakuSettings.isEnabled('huya', box: box), isFalse);
      expect(DanmakuSettings.isEnabled('douyu', box: box), isTrue);
    });

    test('font size and opacity clamp to range', () async {
      await DanmakuSettings.setFontSize(99, box: box);
      expect(DanmakuSettings.fontSize(box: box), 20);
      await DanmakuSettings.setFontSize(1, box: box);
      expect(DanmakuSettings.fontSize(box: box), 12);
      await DanmakuSettings.setOpacity(0, box: box);
      expect(DanmakuSettings.opacity(box: box), 0.3);
      await DanmakuSettings.setOpacity(2, box: box);
      expect(DanmakuSettings.opacity(box: box), 1.0);
    });
  });

  group('CacheService', () {
    test('section sizes come from stored values', () async {
      await box.put(HiveKeys.videoHomeCache, '{"rows":[]}');
      await box.put(HiveKeys.doubanDetail, '{"a":1}');
      expect(CacheService.sizeOf(CacheSection.videoHome, box: box), 11);
      expect(CacheService.sizeOf(CacheSection.douban, box: box), 7);
      expect(CacheService.sizeOf(CacheSection.daily, box: box), 0);
      await box.put('hao_daily_2026-11-16', 'xxx');
      expect(CacheService.sizeOf(CacheSection.daily, box: box), 3);
      expect(CacheService.totalSize(box: box), 21);
    });

    test('clearSection deletes only that section', () async {
      await box.put(HiveKeys.videoHomeCache, '{"rows":[]}');
      await box.put(HiveKeys.doubanDetail, '{"a":1}');
      await box.put(HiveKeys.videoHistory, '[{"x":1}]');
      final freed = await CacheService.clearSection(
        CacheSection.videoHome,
        box: box,
      );
      expect(freed, 11);
      expect(box.get(HiveKeys.videoHomeCache), isNull);
      expect(box.get(HiveKeys.doubanDetail), isNotNull);
      // User data (history) is untouched.
      expect(box.get(HiveKeys.videoHistory), isNotNull);
    });

    test('clearAll frees everything cache, keeps user data', () async {
      await box.put(HiveKeys.videoHomeCache, '12345');
      await box.put(HiveKeys.doubanIdmap, '12');
      await box.put('hao_daily_2026-11-16', '123');
      await box.put(HiveKeys.musicFav, '["wy|1"]');
      final freed = await CacheService.clearAll(box: box);
      expect(freed, 10);
      expect(box.get(HiveKeys.videoHomeCache), isNull);
      expect(box.get(HiveKeys.doubanIdmap), isNull);
      expect(box.get('hao_daily_2026-11-16'), isNull);
      expect(box.get(HiveKeys.musicFav), isNotNull);
    });

    test('formatBytes', () {
      expect(CacheService.formatBytes(512), '512 B');
      expect(CacheService.formatBytes(2048), '2.0 KB');
      expect(CacheService.formatBytes(3 * 1024 * 1024), '3.00 MB');
    });
  });

  group('uninitialised-Hive fallback', () {
    test('VideoSourcesStore.getAll returns shipped defaults', () {
      // HiveStore.init was never called in this process.
      final sources = VideoSourcesStore.getAll();
      expect(sources.length, kDefaultVideoSources.length);
      expect(sources.first.name, '金鹰资源');
    });

    test('CmsClient defaults to shipped enabled sources', () {
      final client = CmsClient();
      expect(client.sources.length, defaultEnabledVideoSources().length);
      expect(
        client.sources.map((s) => s.name),
        defaultEnabledVideoSources().map((s) => s.name),
      );
    });
  });
}
