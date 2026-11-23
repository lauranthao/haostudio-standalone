// Heartbeat multi-page bug (chen 2026-11-20): tapping 心动模式 and then
// switching songs opens multiple player pages (the full player pushed
// repeatedly, stacking routes).
//
// The card tap is async (similar-song search, then playQueue resolves
// the first URL) and the push at the end is unconditional, so a second
// open during that window — a double card tap, a mini-bar tap once the
// bar appears while the first URL is still resolving — stacks a second
// MusicPlayerPage. Every song-switch gesture after the player is open
// must only update the current player, never push another page.
//
// The controller here uses injected fake resolvers + fake players (same
// pattern as music_playback_reliability_test.dart) so playQueue runs to
// completion inside the widget-test zone — with the real resolvers the
// first URL resolution stalls there and the player page never opens.

import 'package:dio/dio.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/music/fm_service.dart';
import 'package:standalone/features/music/music_navigation.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/music_player_sheet.dart';
import 'package:standalone/features/music/music_tab_page.dart';
import 'package:standalone/features/music/widgets/play_queue_panel.dart';
import 'package:standalone/features/music/widgets/song_row.dart';
import 'package:standalone/features/music/av_music_player.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';
import 'package:standalone/services/music/music_store.dart';

Song _song(String id, String title) => Song(
  songId: id,
  title: title,
  artist: '陈奕迅',
  album: '专辑',
  platform: MusicPlatform.wy,
  dur: 200,
);

String _url(String id) => 'https://example.com/$id.mp3';

/// Fake search: canned similar songs per query; empty plaza/charts so
/// the home never hits the real network; no lyrics, no alt-platform.
class _FakeApi extends MusicApi {
  _FakeApi(this.byQuery);

  final Map<String, List<Song>> byQuery;

  /// Test gate: when set, searchOne waits for it — the slow-search
  /// window production has (seconds of network) during which the home
  /// is still visible and a second tap can land.
  Completer<void>? searchGate;

  @override
  Future<List<Song>> searchOne(MusicPlatform pf, String q, {CancelToken? cancelToken}) async {
    if (searchGate != null) await searchGate!.future;
    return byQuery[q] ?? [];
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => [];

  @override
  Future<Song?> findAltPlatform(
    String title,
    String artist,
    MusicPlatform excludePf,
    String album, {
    Duration timeout = const Duration(seconds: 5),
  }) async => null;

  @override
  Future<List<PlaylistSummary>> plaza(MusicPlatform pf) async => [];

  @override
  Future<List<PlaylistSummary>> neteaseCharts() async => [];
}

class _ScriptedResolvers extends MusicResolvers {
  @override
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
    String artist = '',
    bool background = false,
    Duration totalBudget = const Duration(seconds: 8),
  }) async => PlayUrlResult(
    url: _url(songId),
    candidates: [_url(songId)],
    quality: AudioQuality.hires,
    via: 'test',
  );
}

class _FakePlayer extends AvMusicPlayer {
  final List<String> openedUrls = [];

  @override
  Future<bool> open(String url, {bool play = true}) async {
    openedUrls.add(url);
    return true;
  }

  @override
  Future<bool> preload(String url) async => true;

  @override
  bool isPreloadedFor(String url) => false;

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory hiveDir;
  late MusicPlayerController controller;
  late _FakeApi fakeApi;

  final seed = _song('wy-seed', '富士山下');
  final similar = [_song('wy-s1', '孤勇者'), _song('wy-s2', '浮夸')];

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-heartbeat-test-');
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
    await HiveStore.put(HiveKeys.musicFav, '[]');
    await HiveStore.put(HiveKeys.musicRecent, '[]');
    await HiveStore.put(HiveKeys.fmDislikedIds, <String>[]);
    await HiveStore.put(HiveKeys.musicRecentExpanded, true);
    await HiveStore.put(HiveKeys.musicPlaylistsExpanded, true);
    fakeApi = _FakeApi({'陈奕迅': similar});
    controller = Get.put(
      MusicPlayerController(
        api: fakeApi,
        resolvers: _ScriptedResolvers(),
        playerA: _FakePlayer(),
        playerB: _FakePlayer(),
      ),
    );
    await MusicStore.toggleFav(seed);
    FmService.setTestInstance(FmService(api: fakeApi, player: controller));
  });

  tearDown(() {
    resetPlayerPageGuardForTest();
    FmService.resetForTest();
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  /// Hive writes must run in the real zone (runAsync); they hang
  /// inside the fake-async zone. Drain real async work after a tap so
  /// the page's setState and fire-and-forget Hive puts have landed.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: MusicTabPage(api: fakeApi),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Pump until the player page appears (or give up): the card tap is
  /// async — fake search, then playQueue resolves + opens on the fake
  /// player — so the push lands a few settles after the tap.
  Future<bool> waitForPlayer(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await settle(tester);
      if (find.byType(MusicPlayerPage).evaluate().isNotEmpty) return true;
    }
    return false;
  }

  int playerPages(WidgetTester tester) =>
      find.byType(MusicPlayerPage).evaluate().length;

  /// Controls inside the open player page: the home page (with its own
  /// mini bar, which carries the same skip icons) stays mounted under
  /// the player route, so bare icon finders are ambiguous.
  Finder inPlayer(Finder inner) =>
      find.descendant(of: find.byType(MusicPlayerPage), matching: inner);

  Finder inQueuePanel(String title) => find.descendant(
    of: find.byType(PlayQueuePanel),
    matching: find.text(title),
  );

  Future<void> closeSnackbars(WidgetTester tester) async {
    // b30: the music stall watchdog runs a periodic 500ms Timer;
    // the test framework fails the test if any Timer is still
    // pending after the tree is disposed, and tearDown's Get.reset
    // runs too late (invariants are checked first). Stop the watch
    // here, at the end of every test body, via the seam the
    // watchdog batch provided — the controller's onClose cancels it
    // too, but only when Get actually deletes the controller.
    controller.stopStallWatchdogForTest();
    Get.closeAllSnackbars();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('heartbeat card opens ONE player page; switching songs '
      'never stacks another', (tester) async {
    await pumpHome(tester);

    await tester.ensureVisible(find.text('心动模式'));
    await tester.pump();
    await tester.tap(find.text('心动模式'));
    expect(
      await waitForPlayer(tester),
      isTrue,
      reason: 'player page never opened after the heartbeat tap',
    );
    expect(playerPages(tester), 1);
    expect(controller.currentSong?.songId, 'wy-seed');

    // Manual next: only the song changes, no new page.
    await tester.tap(inPlayer(find.byIcon(Icons.skip_next)));
    await settle(tester);
    expect(controller.currentSong?.songId, 'wy-s1');
    expect(playerPages(tester), 1);

    // Manual prev: back to the seed, still one page.
    await tester.tap(inPlayer(find.byIcon(Icons.skip_previous)));
    await settle(tester);
    expect(controller.currentSong?.songId, 'wy-seed');
    expect(playerPages(tester), 1);

    // Queue panel: tap another song — still one page.
    await tester.tap(inPlayer(find.byIcon(Icons.queue_music)));
    await settle(tester);
    await tester.tap(inQueuePanel('浮夸'));
    await settle(tester);
    expect(controller.currentSong?.songId, 'wy-s2');
    expect(playerPages(tester), 1);

    // ⋯ sheet -> 播放列表 -> tap a song — still one page.
    await tester.tap(inPlayer(find.byIcon(CupertinoIcons.ellipsis)));
    await settle(tester);
    await tester.tap(find.text('播放列表'));
    await settle(tester);
    await tester.tap(inQueuePanel('孤勇者'));
    await settle(tester);
    expect(controller.currentSong?.songId, 'wy-s1');
    expect(playerPages(tester), 1);

    // Exactly one page was ever pushed: one pop returns to home.
    Get.back();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(playerPages(tester), 0);

    await closeSnackbars(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('double-tapping the heartbeat card still opens ONE player '
      'page', (tester) async {
    await pumpHome(tester);

    // Gate the similar-song search: production's search takes seconds,
    // and the home stays visible (and tappable) the whole time.
    final gate = Completer<void>();
    fakeApi.searchGate = gate;
    await tester.ensureVisible(find.text('心动模式'));
    await tester.pump();
    // Two taps with the search still gated: both land on the card
    // while the first tap's _startHeartbeat is still awaiting.
    await tester.tap(find.text('心动模式'));
    await tester.tap(find.text('心动模式'));
    // Release the search: both taps now race to _openPlayer().
    gate.complete();
    expect(
      await waitForPlayer(tester),
      isTrue,
      reason: 'player page never opened after the double tap',
    );
    await settle(tester);
    await settle(tester);
    // The stack must hold exactly ONE player page. Counting widgets
    // is racy here (a second route pushed mid-transition has no built
    // page yet), so pop once: with one page the home comes back; with
    // a stacked second page, one player page remains.
    Get.back();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
      playerPages(tester),
      0,
      reason: 'double tap stacked a second player page',
    );
    await closeSnackbars(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('double-tapping the FM card still opens ONE player page', (
    tester,
  ) async {
    await pumpHome(tester);
    await MusicStore.addRecent(seed);

    final gate = Completer<void>();
    fakeApi.searchGate = gate;
    await tester.ensureVisible(find.text('私人漫游'));
    await tester.pump();
    await tester.tap(find.text('私人漫游'));
    await tester.tap(find.text('私人漫游'));
    gate.complete();
    expect(
      await waitForPlayer(tester),
      isTrue,
      reason: 'player page never opened after the double tap',
    );
    await settle(tester);
    await settle(tester);
    // Same stack-depth assertion as the heartbeat double tap.
    Get.back();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
      playerPages(tester),
      0,
      reason: 'double tap stacked a second player page',
    );
    await closeSnackbars(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('after popping the player, tapping a recent song opens ONE '
      'player page', (tester) async {
    await MusicStore.addRecent(seed);
    await pumpHome(tester);

    // Play once from the heartbeat card, then pop back to home.
    await tester.ensureVisible(find.text('心动模式'));
    await tester.pump();
    await tester.tap(find.text('心动模式'));
    expect(await waitForPlayer(tester), isTrue);
    expect(playerPages(tester), 1);
    // Close the player (Get.back is the established way existing
    // player tests close the page; the chevron does the same pop).
    Get.back();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(playerPages(tester), 0);

    // The recent row (seeded before pump) opens the player once.
    await tester.ensureVisible(
      find.descendant(of: find.byType(SongRow), matching: find.text('富士山下')),
    );
    await tester.pump();
    await tester.tap(
      find.descendant(of: find.byType(SongRow), matching: find.text('富士山下')),
    );
    expect(await waitForPlayer(tester), isTrue);
    await settle(tester);
    expect(playerPages(tester), 1);
    await closeSnackbars(tester);
    expect(tester.takeException(), isNull);
  });
}
