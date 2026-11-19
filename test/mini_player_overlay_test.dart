// Mini player overlay on every music page.
//
// chen: 音乐界面不论在哪个页面，mini 播放器都要一直在。
//
// The overlay lives above the root Navigator (GetMaterialApp builder,
// main.dart) and shows only while the top route is a music sub-page
// (tagged `music`), a song is loaded, and the keyboard is hidden.
// The home keeps its own embedded bar (key homeMiniPlayer); the
// overlay bar has key overlayMiniPlayer.
//
// Tests (each pumps the real AppShell):
// 1. opening a music sub-page (收藏) shows the overlay bar;
// 2. opening the full player from the overlay hides it, popping the
//    player brings it back;
// 3. on the video tab (and on the music home) the overlay is hidden
//    even with a song loaded, and the home bar is present on the music
//    home but gone after switching to video.

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
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/music/favourites_page.dart';
import 'package:standalone/features/music/mini_player_overlay.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/widgets/app_shell.dart';

void main() {
  late Directory hiveDir;
  late MusicRouteObserver observer;

  const overlayBar = ValueKey('overlayMiniPlayer');
  const homeBar = ValueKey('homeMiniPlayer');
  final testSong = Song(
    songId: 'wy-1',
    title: '富士山下',
    artist: '陈奕迅',
    album: "What's Going On...?",
    platform: MusicPlatform.wy,
    dur: 245,
  );

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-overlay-test-');
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
    // test's fake-async zone never completes there and wedges the
    // box's write queue (see music_home_sections_persist_test.dart).
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  // NOTE: do NOT await the Hive box close here. Pending Hive writes
  // from fire-and-forget puts never resolve in the widget-test fake
  // zone, so awaiting close() hangs tearDownAll forever.
  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    HaoHaptics.debugEnabledOverride = false;
    observer = MusicRouteObserver();
    await HiveStore.put(HiveKeys.musicRecentExpanded, true);
    await HiveStore.put(HiveKeys.musicPlaylistsExpanded, true);
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  /// Pump the real shell with the production overlay wiring, and load
  /// one song into the queue (directly — no network, no audio — so
  /// currentSong is non-null and the bar renders).
  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = Get.put(MusicPlayerController());
    player.queue.assignAll([testSong]);
    player.currentIndex.value = 0;
    final themeController = Get.put(ThemeController());
    themeController.loadFromBox(HiveStore.box);
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        navigatorObservers: [observer],
        builder: (context, child) => Stack(
          children: [
            child ?? const SizedBox.shrink(),
            MiniPlayerOverlay(observer: observer),
          ],
        ),
        home: const AppShell(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Hive writes and post-frame work must run in the real zone; they
  /// hang inside the fake-async zone.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Tap a bottom tab by its label (the tab bar is the last thing in
  /// the tree, so .last is the tab item, not page content).
  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await settle(tester);
  }

  /// From the music home, open the 收藏 sub-page.
  Future<void> openFavourites(WidgetTester tester) async {
    expect(find.text('我的收藏'), findsOneWidget);
    await tester.ensureVisible(find.text('我的收藏'));
    await tester.pump();
    await tester.tap(find.text('我的收藏'));
    await settle(tester);
    expect(find.byType(FavouritesPage), findsOneWidget);
  }

  testWidgets('overlay shows on a music sub-page', (tester) async {
    await pumpShell(tester);
    // Video tab, song loaded: no overlay (top route is the home
    // route, not a music sub-page).
    expect(find.byKey(overlayBar), findsNothing);

    await tapTab(tester, '音乐');
    expect(find.text('我的歌单'), findsOneWidget);
    // Music home: the embedded bar shows, the overlay does not.
    expect(find.byKey(homeBar), findsOneWidget);
    expect(find.byKey(overlayBar), findsNothing);

    await openFavourites(tester);
    expect(find.byKey(overlayBar), findsOneWidget);
    // The bar shows the loaded song (the favourites list itself is
    // empty in this test, so the title inside the overlay bar can
    // only come from the bar). The home bar underneath shows the same
    // title, so scope the finder to the overlay bar.
    expect(
      find.descendant(
        of: find.byKey(overlayBar),
        matching: find.text('富士山下'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('full player hides the overlay, popping brings it back',
      (tester) async {
    await pumpShell(tester);
    await tapTab(tester, '音乐');
    await openFavourites(tester);
    expect(find.byKey(overlayBar), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(overlayBar),
        matching: find.text('富士山下'),
      ),
    );
    await settle(tester);
    // The full player is open (its own title row) and the overlay is
    // gone above it.
    expect(find.byKey(overlayBar), findsNothing);

    Get.back();
    await settle(tester);
    expect(find.byKey(overlayBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(overlayBar),
        matching: find.text('富士山下'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('video tab hides the overlay and disposes the home bar',
      (tester) async {
    await pumpShell(tester);
    expect(find.byKey(overlayBar), findsNothing);

    await tapTab(tester, '音乐');
    expect(find.byKey(homeBar), findsOneWidget);
    await openFavourites(tester);
    expect(find.byKey(overlayBar), findsOneWidget);

    // Back to the music home: overlay gone, embedded bar back.
    Get.back();
    await settle(tester);
    expect(find.byKey(overlayBar), findsNothing);
    expect(find.byKey(homeBar), findsOneWidget);

    // Video tab: the music page is disposed, so the embedded bar is
    // gone too — nothing floats over video.
    await tapTab(tester, '影视');
    expect(find.byKey(overlayBar), findsNothing);
    expect(find.byKey(homeBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
