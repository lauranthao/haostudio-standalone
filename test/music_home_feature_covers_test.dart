// Music-home feature-card first covers: 歌单广场 / 排行榜 / 听歌报告
// show their first item's cover (搜歌 and the FM / heartbeat glass
// cards keep their gradients), with a gradient fallback when there
// is no data, and a cached cover is used without re-fetching.

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
import 'package:standalone/features/music/music_tab_page.dart';
import 'package:standalone/features/music/widgets/music_image.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

const _plazaUrl = 'https://example.com/plaza-first.jpg';
const _chartArtUrl = 'https://example.com/chart-art.jpg';
const _chartSongUrl = 'https://example.com/chart-first-song.jpg';
const _reportUrl = 'https://example.com/report-top-song.jpg';

/// Canned plaza / charts / importPlaylist for the home's lazy
/// first-cover fill. The chart's OWN cover (_chartArtUrl) is
/// deliberately different from its #1 song's cover (_chartSongUrl):
/// the card must show the song, not the chart artwork.
class _CoverFakeApi extends MusicApi {
  _CoverFakeApi({this.plazaCover, this.chartSongCover, this.gate});

  final String? plazaCover;
  final String? chartSongCover;

  /// Test gate: when set, plaza / charts wait for it before
  /// returning, so the test can observe the gradient first and the
  /// swap-in after.
  final Completer<void>? gate;
  var plazaCalls = 0;
  var chartsCalls = 0;
  var importCalls = 0;

  @override
  Future<List<PlaylistSummary>> plaza(MusicPlatform pf) async {
    plazaCalls++;
    if (gate != null) await gate!.future;
    if (plazaCover == null) return [];
    return [
      PlaylistSummary(id: 'p1', name: '广场一', cover: plazaCover!),
    ];
  }

  @override
  Future<List<PlaylistSummary>> neteaseCharts() async {
    chartsCalls++;
    if (gate != null) await gate!.future;
    if (chartSongCover == null) return [];
    return [
      PlaylistSummary(id: 'c1', name: '飙升榜', cover: _chartArtUrl),
    ];
  }

  @override
  Future<({String name, List<Song> tracks})> importPlaylist(
    MusicPlatform pf,
    String id,
  ) async {
    importCalls++;
    if (chartSongCover == null) return (name: '', tracks: <Song>[]);
    return (
      name: '飙升榜',
      tracks: [
        Song(
          songId: 's1',
          title: '第一名',
          artist: 'A',
          platform: MusicPlatform.wy,
          cover: chartSongCover!,
          dur: 200,
        ),
      ],
    );
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-feature-covers-');
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
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    HaoHaptics.debugEnabledOverride = false;
    await HiveStore.delete(HiveKeys.featureCoverPlaza);
    await HiveStore.delete(HiveKeys.featureCoverCharts);
    // Listen log is sharded by month (P1-P4): clear the legacy key
    // AND every shard, not just `hao_listen`.
    await HiveStore.delete(HiveKeys.musicListen);
    for (final key in HiveStore.box.keys.toList()) {
      if (key is String && key.startsWith('${HiveKeys.musicListen}_')) {
        await HiveStore.delete(key);
      }
    }
    Get.put(MusicPlayerController());
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  Finder coverImage(String url) => find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is MusicImageProvider &&
            (w.image as MusicImageProvider).url == url,
      );

  /// The black scrim over a cover photo (top 0.1 -> bottom 0.68):
  /// one per cover card, keeping the white title readable. Matched
  /// on its exact gradient (topCenter -> bottomCenter, ending black
  /// 0.68) so the cards' own LinearGradient backgrounds (topLeft ->
  /// bottomRight, tile colours) and the FM / heartbeat glass washes
  /// do not count.
  Finder scrim() => find.byWidgetPredicate(
        (w) {
          if (w is! DecoratedBox) return false;
          final decoration = w.decoration;
          if (decoration is! BoxDecoration) return false;
          final gradient = decoration.gradient;
          if (gradient is! LinearGradient) return false;
          return gradient.begin == Alignment.topCenter &&
              gradient.end == Alignment.bottomCenter &&
              gradient.colors.contains(
                const Color.fromRGBO(0, 0, 0, 0.68),
              );
        },
      );

  Future<void> pumpHome(
    WidgetTester tester,
    _CoverFakeApi api, {
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme ?? HaoThemes.of(HaoThemeId.appleGlass).light,
        home: MusicTabPage(api: api),
      ),
    );
  }

  Future<void> seedReportTopSong() async {
    await MusicStore.recordListenEvent(
      ListenEvent(
        songId: 'r1',
        title: '报告第一',
        artist: 'A',
        platform: MusicPlatform.wy,
        cover: _reportUrl,
        dur: 200,
        totalDur: 200,
        at: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  testWidgets('cards show first covers when data exists', (tester) async {
    await seedReportTopSong();
    final api = _CoverFakeApi(
      plazaCover: _plazaUrl,
      chartSongCover: _chartSongUrl,
    );
    await pumpHome(tester, api);
    await tester.pumpAndSettle();

    expect(coverImage(_plazaUrl), findsOneWidget);
    expect(coverImage(_chartSongUrl), findsOneWidget);
    expect(coverImage(_reportUrl), findsOneWidget);
    // The chart's own artwork is NOT the card cover — the #1 song
    // is.
    expect(coverImage(_chartArtUrl), findsNothing);
    // Exactly three cover images on the page (搜歌 + FM/heartbeat
    // have none; no lists/recents are seeded).
    expect(find.byType(Image), findsNWidgets(3));
    // One scrim per cover card.
    expect(scrim(), findsNWidgets(3));
  });

  testWidgets('cards fall back to gradient when no data', (tester) async {
    final api = _CoverFakeApi();
    await pumpHome(tester, api);
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    // Titles still render on their gradients.
    expect(find.text('歌单广场'), findsOneWidget);
    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('听歌报告'), findsOneWidget);
    expect(find.text('搜歌'), findsOneWidget);
    expect(scrim(), findsNothing);
  });

  testWidgets('cover swaps in after the lazy fetch', (tester) async {
    // The fake waits on a gate, so the home renders its gradients
    // first and the covers swap in only when the fetch completes.
    final gate = Completer<void>();
    final api = _CoverFakeApi(
      plazaCover: _plazaUrl,
      chartSongCover: _chartSongUrl,
      gate: gate,
    );
    await pumpHome(tester, api);
    await tester.pump();
    expect(coverImage(_plazaUrl), findsNothing);
    expect(coverImage(_chartSongUrl), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(coverImage(_plazaUrl), findsOneWidget);
    expect(coverImage(_chartSongUrl), findsOneWidget);
    expect(api.plazaCalls, 1);
    expect(api.chartsCalls, 1);
    expect(api.importCalls, 1);
  });

  testWidgets('cached cover is used without re-fetching', (tester) async {
    await MusicStore.setFeatureCover(HiveKeys.featureCoverPlaza, _plazaUrl);
    await MusicStore.setFeatureCover(
      HiveKeys.featureCoverCharts,
      _chartSongUrl,
    );
    final api = _CoverFakeApi(
      plazaCover: 'https://example.com/fresh-plaza.jpg',
      chartSongCover: 'https://example.com/fresh-chart-song.jpg',
    );
    await pumpHome(tester, api);
    await tester.pumpAndSettle();

    // The cached URLs show — the fresh ones are never fetched.
    expect(coverImage(_plazaUrl), findsOneWidget);
    expect(coverImage(_chartSongUrl), findsOneWidget);
    expect(
      coverImage('https://example.com/fresh-plaza.jpg'),
      findsNothing,
    );
    expect(api.plazaCalls, 0);
    expect(api.chartsCalls, 0);
    expect(api.importCalls, 0);
  });

  testWidgets('covers + white titles in all 4 themes x light/dark',
      (tester) async {
    await seedReportTopSong();
    final api = _CoverFakeApi(
      plazaCover: _plazaUrl,
      chartSongCover: _chartSongUrl,
    );
    for (final id in HaoThemeId.values) {
      for (final dark in [false, true]) {
        final themes = HaoThemes.of(id);
        await pumpHome(
          tester,
          api,
          theme: dark ? themes.dark : themes.light,
        );
        await tester.pumpAndSettle();
        expect(
          coverImage(_plazaUrl),
          findsOneWidget,
          reason: 'plaza cover in $id ${dark ? 'dark' : 'light'}',
        );
        expect(
          coverImage(_chartSongUrl),
          findsOneWidget,
          reason: 'charts cover in $id ${dark ? 'dark' : 'light'}',
        );
        expect(
          coverImage(_reportUrl),
          findsOneWidget,
          reason: 'report cover in $id ${dark ? 'dark' : 'light'}',
        );
        expect(
          scrim(),
          findsNWidgets(3),
          reason: 'scrims in $id ${dark ? 'dark' : 'light'}',
        );
        // Titles stay white over the photo in every theme/mode.
        for (final title in ['歌单广场', '排行榜', '听歌报告']) {
          final text = tester.widget<Text>(find.text(title));
          expect(
            text.style?.color,
            Colors.white,
            reason: '$title title is white in $id ${dark ? 'dark' : 'light'}',
          );
        }
      }
    }
  });
}
