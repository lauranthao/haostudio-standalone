// Player expand transition (NetEase).
//
// Tapping a mini player bar expands the full player page from the
// bar's rect (rounded sheet growing to fill the screen); closing
// slides the page right and the bar fades back in. Video frames:
// netease_seq_010 (opening, mid-expansion), 016 (closing, sliding
// right), 017/019 (bar fading back in).
//
// Tests (each pumps the real AppShell — same harness as
// mini_player_overlay_test.dart):
// 1. opening from the overlay bar expands to the player, hides the
//    overlay, and popping brings the overlay back;
// 2. opening from the home bar expands to the player, popping brings
//    the home bar back;
// 3. expand geometry: the sheet is a capsule at the start of the
//    transition and square at rest;
// 4. edge swipe: a short drag returns the page, a long fling pops it.

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
import 'package:standalone/features/music/music_player_sheet.dart';
import 'package:standalone/features/music/player_expand_route.dart';
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
    hiveDir = await Directory.systemTemp.createTemp('hao-expand-test-');
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

  /// Two pumps after a push: the Navigator installs the route in a
  /// post-frame callback, so one pump alone leaves the new page out
  /// of the tree (diagnosed: a single pump after a tap-triggered push
  /// found no MusicPlayerPage, while pumpAndSettle did). The first
  /// pump runs the installation, the second builds the route and
  /// advances its animation by [duration].
  Future<void> pumpPush(
    WidgetTester tester, [
    Duration duration = const Duration(milliseconds: 120),
  ]) async {
    await tester.pump();
    await tester.pump(duration);
  }

  /// Two pumps after a close: the expand route's reverse is 350ms,
  /// so settle()'s 300ms leaves the page mid-slide (diagnosed: all
  /// four post-close expects failed with the player still in the
  /// tree). 400ms covers the reverse with margin; the overlay's
  /// 250ms fade-in is covered too.
  Future<void> pumpClose(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
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

  /// Tap the song title inside a mini player bar (the bar's InkWell).
  Future<void> tapBar(WidgetTester tester, Key barKey) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(barKey),
        matching: find.text('富士山下'),
      ),
    );
  }

  /// The transition's ClipRRect: the only ClipRRect that is an
  /// ancestor of the player page (the page's own clips are
  /// descendants, not ancestors).
  Finder transitionClip(WidgetTester tester) => find.ancestor(
        of: find.byType(MusicPlayerPage),
        matching: find.byType(ClipRRect),
      );

  double clipRadius(WidgetTester tester) {
    final clip = tester.widget<ClipRRect>(transitionClip(tester));
    return (clip.borderRadius as BorderRadius).topLeft.x;
  }

  testWidgets('overlay bar expands to the player and back',
      (tester) async {
    await pumpShell(tester);
    await tapTab(tester, '音乐');
    await openFavourites(tester);
    expect(find.byKey(overlayBar), findsOneWidget);

    await tapBar(tester, overlayBar);
    // Mid-transition: the player is already in the tree and nothing
    // overflows (the page compresses inside the growing sheet).
    await pumpPush(tester);
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(tester.takeException(), isNull);

    await settle(tester);
    // Fully open: the player is there and the overlay is gone.
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(find.byKey(overlayBar), findsNothing);
    expect(tester.takeException(), isNull);

    Get.back();
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
    expect(find.byKey(overlayBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home bar expands to the player and back', (tester) async {
    await pumpShell(tester);
    await tapTab(tester, '音乐');
    expect(find.byKey(homeBar), findsOneWidget);

    await tapBar(tester, homeBar);
    await pumpPush(tester);
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(tester.takeException(), isNull);

    await settle(tester);
    expect(find.byType(MusicPlayerPage), findsOneWidget);

    Get.back();
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
    expect(find.byKey(homeBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expand geometry: capsule at start, square at rest',
      (tester) async {
    await pumpShell(tester);
    await tapTab(tester, '音乐');
    await openFavourites(tester);

    await tapBar(tester, overlayBar);
    await pumpPush(tester, const Duration(milliseconds: 16));
    expect(transitionClip(tester), findsOneWidget);
    // One frame in the sheet is still capsule-like (radius in the
    // hundreds — the bar's 999 falling off as (1-t)^4).
    expect(clipRadius(tester), greaterThan(100));
    expect(tester.takeException(), isNull);

    await settle(tester);
    expect(transitionClip(tester), findsOneWidget);
    expect(clipRadius(tester), 0);
    expect(tester.takeException(), isNull);

    Get.back();
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edge swipe: short drag returns, long fling pops',
      (tester) async {
    await pumpShell(tester);
    await tapTab(tester, '音乐');
    await openFavourites(tester);
    await tapBar(tester, overlayBar);
    await settle(tester);
    expect(find.byType(MusicPlayerPage), findsOneWidget);

    // Short, slow drag from the left edge: below the 100px / 600px/s
    // thresholds, so the page springs back and stays.
    await tester.timedDragFrom(
      const Offset(5, 400),
      const Offset(60, 0),
      const Duration(milliseconds: 500),
    );
    await settle(tester);
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Long fling from the left edge: past the threshold, the page
    // slides right off and the overlay bar comes back.
    await tester.flingFrom(const Offset(5, 400), const Offset(300, 0), 1000);
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
    expect(find.byKey(overlayBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plain open (no rect) still uses the slide',
      (tester) async {
    await pumpShell(tester);
    await tapTab(tester, '音乐');
    final context = tester.element(find.byType(AppShell));
    unawaited(openPlayerPage<void>(context));
    await settle(tester);
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    // No expand sheet: the player page has no ClipRRect ancestor.
    expect(transitionClip(tester), findsNothing);
    expect(tester.takeException(), isNull);

    Get.back();
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
