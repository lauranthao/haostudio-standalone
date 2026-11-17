// Stage 2 item 3 — single-platform capsule store + filtered search.
//
// Store: default wy, persist + round-trip, mg refused, a stored
// platform disabled in 音源管理 falls back to the first enabled one.
// Service: searchAllStream(onlyPlatform:) queries ONLY that platform
// (fake API legs per platform, fakeAsync timing like
// music_search_stream_test.dart).

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/search_platform_store.dart';
import 'package:standalone/services/music/song_search_service.dart';

Song _song(String id, String title, MusicPlatform pf) =>
    Song(songId: id, title: title, artist: 'A', platform: pf);

class _FakeApi extends MusicApi {
  _FakeApi({required this.results});

  final Map<MusicPlatform, List<Song>> results;

  @override
  Future<List<Song>> searchOne(MusicPlatform pf, String q) async {
    return List.of(results[pf] ?? const []);
  }
}

class _FakeEngine extends LxScriptEngine {
  @override
  Future<void> ensureInitialized() async {}

  @override
  List<({String scriptId, String scriptName})> searchLegsFor(
    MusicPlatform platform,
  ) => [];
}

void main() {
  group('SearchPlatformStore', () {
    late Box<dynamic> box;

    setUp(() async {
      Hive.init('test/.hive-stage2-platform');
      box = await Hive.openBox<dynamic>('stage2_platform_test');
      await box.clear();
      HiveStore.setTestBox(box);
    });

    tearDown(() async {
      await box.close();
      await Hive.deleteBoxFromDisk('stage2_platform_test');
    });

    test('defaults to wy and round-trips the choice', () async {
      expect(SearchPlatformStore.current(), MusicPlatform.wy);
      expect(await SearchPlatformStore.set(MusicPlatform.tx), isTrue);
      expect(SearchPlatformStore.current(), MusicPlatform.tx);
      expect(await SearchPlatformStore.set(MusicPlatform.kg), isTrue);
      expect(SearchPlatformStore.current(), MusicPlatform.kg);
    });

    test('mg (no search) is refused and never stored', () async {
      expect(await SearchPlatformStore.set(MusicPlatform.mg), isFalse);
      expect(SearchPlatformStore.current(), MusicPlatform.wy);
    });

    test('options() excludes platforms disabled in 音源管理', () async {
      await box.put(
        HiveKeys.musicSources,
        jsonEncode(['tx', 'kw']),
      );
      expect(SearchPlatformStore.options(), [
        MusicPlatform.tx,
        MusicPlatform.kw,
      ]);
      // Stored wy is no longer offered -> falls back to first enabled.
      expect(SearchPlatformStore.current(), MusicPlatform.tx);
      // Setting a disabled platform is refused.
      expect(await SearchPlatformStore.set(MusicPlatform.wy), isFalse);
    });

    test('corrupt stored value falls back to wy', () async {
      await box.put(HiveKeys.musicSearchPlatform, 'nonsense');
      expect(SearchPlatformStore.current(), MusicPlatform.wy);
    });
  });

  group('SongSearchService.onlyPlatform', () {
    // The store group above closed its box in tearDown; this group
    // needs its own open box because the aggregated path reads
    // MusicSourcesStore.enabled() (the onlyPlatform path does not).
    late Box<dynamic> box;

    setUp(() async {
      Hive.init('test/.hive-stage2-platform-svc');
      box = await Hive.openBox<dynamic>('stage2_platform_svc_test');
      await box.clear();
      HiveStore.setTestBox(box);
    });

    tearDown(() async {
      await box.close();
      await Hive.deleteBoxFromDisk('stage2_platform_svc_test');
    });

    test('only tx: only the tx leg runs, only tx songs emit', () {
      fakeAsync((async) {
        final service = SongSearchService(
          api: _FakeApi(results: {
            MusicPlatform.wy: [_song('1', 'A', MusicPlatform.wy)],
            MusicPlatform.tx: [_song('2', 'B', MusicPlatform.tx)],
            MusicPlatform.kg: [_song('3', 'C', MusicPlatform.kg)],
            MusicPlatform.kw: [_song('4', 'D', MusicPlatform.kw)],
          }),
          scriptEngine: _FakeEngine(),
        );
        SearchStreamUpdate? last;
        var done = false;
        service
            .searchAllStream('test', onlyPlatform: MusicPlatform.tx)
            .listen((u) => last = u, onDone: () => done = true);
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(last, isNotNull);
        expect(
          last!.songs.map((s) => s.platform).toSet(),
          {MusicPlatform.tx},
        );
        expect(last!.songs.map((s) => s.title).toList(), ['B']);
      });
    });

    test('no onlyPlatform: all four legs still run (aggregated)', () {
      fakeAsync((async) {
        final service = SongSearchService(
          api: _FakeApi(results: {
            MusicPlatform.wy: [_song('1', 'A', MusicPlatform.wy)],
            MusicPlatform.tx: [_song('2', 'B', MusicPlatform.tx)],
          }),
          scriptEngine: _FakeEngine(),
        );
        SearchStreamUpdate? last;
        service.searchAllStream('test').listen((u) => last = u);
        async.flushMicrotasks();
        expect(last, isNotNull);
        expect(last!.songs.length, 2);
      });
    });
  });
}
