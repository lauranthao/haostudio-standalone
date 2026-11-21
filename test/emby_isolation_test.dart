// T13 — Emby isolation (audit §6.1).
//
// Two contracts:
// 1. `VideoSourcesStore.resetToDefaults()` only clears the CMS
//    source list (`hao_sa_video`); the Emby config lives under its
//    own key (`hao_emby_config`) and survives the reset.
// 2. Source namespaces never collide: Emby rows carry the STRING
//    source 'emby' (`EmbyClient.sourceId`), CMS rows carry INT ids,
//    and both sides filter on `sourceKey` (source.toString()), so an
//    Emby row can never be mistaken for a CMS row even with the same
//    vodId — and vice versa.
//
// The second half of T13 ("all existing CMS video tests pass") is
// the coordinator's full regression run, not this file.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/video/video_history_store.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';

import 'helpers/hive_test_setup.dart';

// Fixture key: explicitly fake, never a real credential (same
// convention as emby_client_test.dart).
const _fakeKey = 'test-key-123';

const _embyConfig = EmbyServerConfig(
  baseUrl: 'http://192.168.1.10:8096',
  apiKey: _fakeKey,
  userId: 'user-1',
);

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init();
    // Memory-backed box (same reason as emby_tab_persistence_test:
    // Hive file writes wedge in the fake-async zone).
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  setUp(() async {
    await HiveStore.delete(HiveKeys.embyConfig);
    await HiveStore.delete(HiveKeys.videoSources);
    await HiveStore.delete(HiveKeys.videoHistory);
  });

  test('resetToDefaults leaves the Emby config intact', () async {
    expect(await EmbyConfigStore.save(_embyConfig), isTrue);
    expect(EmbyConfigStore.load()?.baseUrl, _embyConfig.baseUrl);

    await VideoSourcesStore.resetToDefaults();

    // The reset really ran: the CMS list is back to defaults.
    expect(VideoSourcesStore.getAll(), isNotEmpty);
    expect(HiveStore.box.get(HiveKeys.videoSources), isNull);
    // ...but the Emby config is untouched.
    final kept = EmbyConfigStore.load();
    expect(kept, isNotNull);
    expect(kept!.baseUrl, _embyConfig.baseUrl);
    expect(kept.apiKey, _fakeKey);
    expect(kept.userId, 'user-1');
  });

  test('Emby and CMS history rows never collide (same vodId)', () async {
    final now = DateTime.now();
    // Same vodId on both sides, different films so the film-dedup
    // in record() keeps both rows.
    await VideoHistoryStore.record(
      WatchHistoryEntry(
        source: 1,
        vodId: '42',
        title: 'CMS Film',
        year: '2024',
        at: now,
      ),
    );
    await VideoHistoryStore.record(
      WatchHistoryEntry(
        source: EmbyClient.sourceId,
        vodId: '42',
        title: 'Emby Film',
        year: '2024',
        at: now,
      ),
    );

    final all = VideoHistoryStore.getAll();
    expect(all.length, 2);

    // The namespace split: 'emby' vs int ids, compared as strings.
    expect(EmbyClient.sourceId, 'emby');
    final cmsRows = all
        .where((e) => e.sourceKey != EmbyClient.sourceId)
        .toList();
    final embyRows = all
        .where((e) => e.sourceKey == EmbyClient.sourceId)
        .toList();
    expect(cmsRows.length, 1);
    expect(cmsRows.single.title, 'CMS Film');
    expect(cmsRows.single.identityKey, '1|42');
    expect(embyRows.length, 1);
    expect(embyRows.single.title, 'Emby Film');
    expect(embyRows.single.identityKey, 'emby|42');

    // Per-source lookup finds the right row, not the other side's.
    expect(VideoHistoryStore.find(1, '42')?.title, 'CMS Film');
    expect(
      VideoHistoryStore.find(EmbyClient.sourceId, '42')?.title,
      'Emby Film',
    );

    // No CMS int id stringifies to 'emby' — the split is structural,
    // not a coincidence of the current defaults.
    for (final source in VideoSourcesStore.getAll()) {
      expect(source.idKey.toString(), isNot('emby'));
    }
  });
}
