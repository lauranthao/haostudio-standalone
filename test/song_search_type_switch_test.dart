// Song search type switching (chen 2026-11-19): after searching
// songs, tapping the 歌单 / 歌手 / 专辑 segment showed nothing until
// search was tapped again — the segment only flipped _type, it never
// re-ran the search for the new type.
//
// Proves: switching to a type auto-searches it when there is no cached
// result for the current query + platform, and switching back shows
// the cached results without a second search. A new query invalidates
// the cache, so switching back re-searches instead of showing the old
// query's rows. The platform capsule is the sibling case: switching
// platform re-runs the current query (verified here too).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/song_search_page.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/song_search_service.dart';

Song _song(String id, String title) => Song(
  songId: id,
  title: title,
  artist: '测试歌手',
  album: '测试专辑',
  platform: MusicPlatform.wy,
  dur: 200,
  // Empty cover on purpose: a real URL would start a Dio load with
  // an 8 s timeout timer pending at test end (see the render tests).
  cover: '',
);

/// Fake search service: canned results per type, counts calls so the
/// test can prove a switch did (or did not) re-search.
class _FakeSearchService extends SongSearchService {
  int songSearches = 0;
  int playlistSearches = 0;
  int artistSearches = 0;

  @override
  Stream<SearchStreamUpdate> searchAllStream(
    String query, {
    MusicPlatform? onlyPlatform,
  }) {
    songSearches++;
    return Stream.value(
      SearchStreamUpdate(
        songs: [_song('s1', '测试歌曲一'), _song('s2', '测试歌曲二')],
        pending: const {},
      ),
    );
  }

  @override
  Stream<PlaylistSearchUpdate> searchPlaylistsStream(
    String query, {
    MusicPlatform? onlyPlatform,
  }) {
    playlistSearches++;
    return Stream.value(
      PlaylistSearchUpdate(
        items: [
          PlaylistSummary(id: 'p1', name: '测试歌单一'),
          PlaylistSummary(id: 'p2', name: '测试歌单二'),
        ],
        pending: const {},
      ),
    );
  }

  @override
  Stream<ArtistSearchUpdate> searchArtistsStream(
    String query, {
    MusicPlatform? onlyPlatform,
  }) {
    artistSearches++;
    return Stream.value(
      ArtistSearchUpdate(
        items: [
          ArtistSummary(id: 'a1', name: '测试歌手甲'),
          ArtistSummary(id: 'a2', name: '测试歌手乙'),
        ],
        pending: const {},
      ),
    );
  }
}

class _FakeApi extends MusicApi {
  int albumSearches = 0;

  @override
  Future<List<AlbumSummary>> searchAlbums(
    MusicPlatform pf,
    String q,
  ) async {
    albumSearches++;
    return [
      AlbumSummary(id: 'al1', name: '测试专辑一'),
      AlbumSummary(id: 'al2', name: '测试专辑二'),
    ];
  }
}

void main() {
  late Directory hiveDir;
  late _FakeSearchService service;
  late _FakeApi api;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-type-switch-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    // Memory-backed box: a Hive file write issued inside a widget
    // test's fake-async zone never completes there — the memory
    // backend's writeFrames is Future.value(), no file I/O, no wedge.
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  // NEVER await HiveStore.box.close() here — the pending write queue
  // in the fake zone makes close() never return.
  tearDownAll(() {
    unawaited(HiveStore.box.close());
    unawaited(hiveDir.delete(recursive: true));
  });

  setUp(() {
    HaoHaptics.debugEnabledOverride = false;
    service = _FakeSearchService();
    api = _FakeApi();
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Get.put(MusicPlayerController());
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: SongSearchPage(searchService: service, api: api),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Drain real async work (fake streams, fire-and-forget Hive
  /// writes) after an interaction so the page's setState has landed.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> searchFor(WidgetTester tester, String q) async {
    await tester.enterText(find.byType(TextField).first, q);
    await tester.tap(find.text('搜索'));
    await settle(tester);
  }

  Future<void> switchType(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await settle(tester);
  }

  testWidgets('switching to 歌单 auto-searches it without tapping 搜索',
      (tester) async {
    await pumpPage(tester);
    await searchFor(tester, '测试');
    expect(find.text('测试歌曲一'), findsOneWidget);
    expect(service.songSearches, 1);

    await switchType(tester, '歌单');
    expect(find.text('测试歌单一'), findsOneWidget);
    expect(service.playlistSearches, 1);
    expect(service.songSearches, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching back to 歌曲 shows the cache, no second search',
      (tester) async {
    await pumpPage(tester);
    await searchFor(tester, '测试');
    expect(find.text('测试歌曲一'), findsOneWidget);

    await switchType(tester, '歌单');
    expect(find.text('测试歌单一'), findsOneWidget);
    await switchType(tester, '歌手');
    expect(find.text('测试歌手甲'), findsOneWidget);
    await switchType(tester, '专辑');
    expect(find.text('测试专辑一'), findsOneWidget);

    await switchType(tester, '歌曲');
    expect(find.text('测试歌曲一'), findsOneWidget);
    expect(service.songSearches, 1);
    expect(service.playlistSearches, 1);
    expect(service.artistSearches, 1);
    expect(api.albumSearches, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new query invalidates the cache, switching back re-searches',
      (tester) async {
    await pumpPage(tester);
    await searchFor(tester, '测试');
    await switchType(tester, '歌单');
    expect(find.text('测试歌单一'), findsOneWidget);

    // New query while on 歌单: playlists re-searched, songs cache
    // dropped (a new query clears all four lists).
    await searchFor(tester, '另一');
    expect(service.playlistSearches, 2);
    await switchType(tester, '歌曲');
    expect(find.text('测试歌曲一'), findsOneWidget);
    expect(service.songSearches, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching platform re-runs the current query (sibling case)',
      (tester) async {
    await pumpPage(tester);
    await searchFor(tester, '测试');
    expect(find.text('测试歌曲一'), findsOneWidget);
    expect(service.songSearches, 1);

    await tester.tap(find.text('网易云'));
    await settle(tester);
    await tester.tap(find.text('QQ音乐'));
    await settle(tester);
    expect(find.text('测试歌曲一'), findsOneWidget);
    expect(service.songSearches, 2);
    expect(tester.takeException(), isNull);
  });
}
