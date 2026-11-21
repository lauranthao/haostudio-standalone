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
// 5. top-bar swipe-down (build 28): a long drag / fast fling closes
//    the page downward, a short slow drag springs back; the lyrics
//    face, progress bar and cover tap are untouched; a swipe-down
//    with the queue open closes the queue first; a no-rect open
//    closes the same way.
import 'package:standalone/features/music/widgets/play_queue_panel.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
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

  /// Tap a bottom tab by its icon, scoped to the bar (the bar is
  /// icon-only, so there is no label text to tap; each icon exists
  /// exactly once in the tree).
  const tabIcons = {
    '影视': CupertinoIcons.film,
    '直播': CupertinoIcons.tv,
    '音乐': CupertinoIcons.music_note,
    '设置': CupertinoIcons.settings,
  };

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(GlassTabBar),
        matching: find.byIcon(tabIcons[label]!),
      ),
    );
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

  /// Open the player from the overlay bar (favourites sub-page), the
  /// shared setup for the swipe-down tests. pumpPush + settle: the
  /// 400ms expand must be fully complete before a swipe, or the
  /// top-bar strip (gated on animation.status == completed) is not
  /// mounted yet and the drag hits nothing.
  Future<void> openFromOverlay(WidgetTester tester) async {
    await pumpShell(tester);
    await tapTab(tester, '音乐');
    await openFavourites(tester);
    await tapBar(tester, overlayBar);
    await pumpPush(tester);
    await settle(tester);
    expect(find.byType(MusicPlayerPage), findsOneWidget);
  }

  /// Top-left of the player page in global coordinates. A swipe-down
  /// in progress moves it down; at rest it is (0, 0).
  Offset pageTopLeft(WidgetTester tester) =>
      tester.getTopLeft(find.byType(MusicPlayerPage));

  /// Start point of a top-bar swipe-down: middle of the top bar
  /// (SafeArea top + 76pt bar, no SafeArea padding in tests).
  const topBarPoint = Offset(195, 60);

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

  testWidgets('plain open (no rect) also uses the expand route',
      (tester) async {
    await pumpShell(tester);
    await tapTab(tester, '音乐');
    final context = tester.element(find.byType(AppShell));
    unawaited(openPlayerPage<void>(context));
    // Mid-transition: the bottom slide-in sheet is a capsule, like
    // the bar expansion — the no-rect path is the same route with a
    // fallback rect, not a plain Material slide.
    await pumpPush(tester, const Duration(milliseconds: 16));
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(transitionClip(tester), findsOneWidget);
    expect(clipRadius(tester), greaterThan(100));
    expect(tester.takeException(), isNull);

    await settle(tester);
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(transitionClip(tester), findsOneWidget);
    expect(clipRadius(tester), 0);
    expect(tester.takeException(), isNull);

    Get.back();
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('N-14 close uses the settle spring, not easeOutCubic',
      (tester) async {
    await openFromOverlay(tester);
    expect(pageTopLeft(tester), Offset.zero);

    Get.back();
    await tester.pump();
    // Mid-close (175/350ms): the spring is at ~0.95 of the slide,
    // easeOutCubic would be at 0.875. On the 390pt logical width
    // (780 @2.0) that is ~372pt vs ~341pt, so 0.91x separates them.
    await tester.pump(const Duration(milliseconds: 175));
    final width =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(pageTopLeft(tester).dx, greaterThan(0.91 * width));

    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('T1 top-bar swipe-down closes the player', (tester) async {
    await openFromOverlay(tester);
    expect(pageTopLeft(tester), Offset.zero);

    await tester.timedDragFrom(
      topBarPoint,
      const Offset(0, 300),
      const Duration(milliseconds: 300),
    );
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
    expect(find.byKey(overlayBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('T1b swipe-down follows the finger mid-drag', (tester) async {
    await openFromOverlay(tester);
    // Hold the finger 120px down: the page must sit exactly 120px
    // lower (pure translation, no scale / corner / fade), and the
    // release past the threshold must close it downward.
    final gesture = await tester.startGesture(topBarPoint);
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    expect(pageTopLeft(tester), const Offset(0, 120));
    expect(tester.takeException(), isNull);
    await gesture.up();
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
    expect(find.byKey(overlayBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('T2 top-bar short slow swipe springs back', (tester) async {
    await openFromOverlay(tester);
    final before = pageTopLeft(tester);

    // 60px at 120px/s: below the 100px / 600px/s thresholds.
    await tester.timedDragFrom(
      topBarPoint,
      const Offset(0, 60),
      const Duration(milliseconds: 500),
    );
    await settle(tester);
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(pageTopLeft(tester), before);
    expect(find.byKey(overlayBar), findsNothing);
    expect(tester.takeException(), isNull);

    // Leave no player open: the single-player guard (claimPlayerPage)
    // is only released when the route pops, so a player left open
    // here would make every later test's open a no-op.
    Get.back();
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
  });

  testWidgets('T3 top-bar swipe-down fling closes (velocity branch)',
      (tester) async {
    await openFromOverlay(tester);

    await tester.flingFrom(topBarPoint, const Offset(0, 200), 1000);
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
    expect(find.byKey(overlayBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('T4 lyrics-face swipe-down scrolls lyrics, never closes',
      (tester) async {
    await openFromOverlay(tester);
    Get.find<MusicPlayerController>().lyrics.assignAll([
      LyricLine(t: 10, text: '第一句'),
      LyricLine(t: 25.5, text: '第二句'),
      LyricLine(t: 40, text: '第三句'),
    ]);
    // Flip to the lyrics face.
    await tester.tap(find.byKey(const ValueKey('playerCover')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('playerLyrics')), findsOneWidget);

    Finder lyricsScroll() => find.descendant(
          of: find.byKey(const ValueKey('playerLyrics')),
          matching: find.byType(Scrollable),
        );
    double scrollPixels() =>
        tester.state<ScrollableState>(lyricsScroll()).position.pixels;
    final lyricsCenter =
        tester.getCenter(find.byKey(const ValueKey('playerLyrics')));

    // Drag up first: the list starts at offset 0, so a downward drag
    // alone has nowhere to scroll. Up 200px, then down 150px — the
    // offset must shrink, proving the ListView owns the gesture.
    await tester.timedDragFrom(
      lyricsCenter,
      const Offset(0, -200),
      const Duration(milliseconds: 300),
    );
    await settle(tester);
    final afterUp = scrollPixels();
    expect(afterUp, greaterThan(0));

    await tester.timedDragFrom(
      lyricsCenter,
      const Offset(0, 150),
      const Duration(milliseconds: 300),
    );
    await settle(tester);
    expect(scrollPixels(), lessThan(afterUp));
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(pageTopLeft(tester), Offset.zero);
    expect(tester.takeException(), isNull);

    Get.back();
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
  });

  testWidgets('T5 cover tap still flips to lyrics', (tester) async {
    await openFromOverlay(tester);

    await tester.tap(find.byKey(const ValueKey('playerCover')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('playerLyrics')), findsOneWidget);
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(tester.takeException(), isNull);

    Get.back();
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
  });

  testWidgets('T6 progress-bar horizontal drag never closes',
      (tester) async {
    await openFromOverlay(tester);
    final barCenter =
        tester.getCenter(find.byKey(const ValueKey('progressBar')));

    await tester.timedDragFrom(
      barCenter,
      const Offset(100, 0),
      const Duration(milliseconds: 300),
    );
    await settle(tester);
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(pageTopLeft(tester), Offset.zero);
    expect(tester.takeException(), isNull);

    Get.back();
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
  });

  testWidgets('T7 swipe-down with queue open closes the queue first',
      (tester) async {
    await openFromOverlay(tester);
    await tester.tap(find.byIcon(Icons.queue_music));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PlayQueuePanel), findsOneWidget);

    // First swipe-down: only the queue closes, the player stays.
    await tester.timedDragFrom(
      topBarPoint,
      const Offset(0, 300),
      const Duration(milliseconds: 300),
    );
    await settle(tester);
    expect(find.byType(PlayQueuePanel), findsNothing);
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    expect(pageTopLeft(tester), Offset.zero);
    expect(tester.takeException(), isNull);

    // Second swipe-down: now the player itself closes.
    await tester.timedDragFrom(
      topBarPoint,
      const Offset(0, 300),
      const Duration(milliseconds: 300),
    );
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
    expect(find.byKey(overlayBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('T8 no-rect open also closes on top-bar swipe-down',
      (tester) async {
    await pumpShell(tester);
    await tapTab(tester, '音乐');
    final context = tester.element(find.byType(AppShell));
    unawaited(openPlayerPage<void>(context));
    await pumpPush(tester);
    await settle(tester);
    expect(find.byType(MusicPlayerPage), findsOneWidget);

    await tester.timedDragFrom(
      topBarPoint,
      const Offset(0, 300),
      const Duration(milliseconds: 300),
    );
    await pumpClose(tester);
    expect(find.byType(MusicPlayerPage), findsNothing);
    expect(find.byKey(homeBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
