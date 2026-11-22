// 1.1.6 iOS native feel — A 组 (N-1 / N-2 / N-7 / N-10 / N-14 / N-20).
//
// Before → after, per item (measured in this file unless noted):
// - N-1: 27 MaterialPageRoute had no iOS swipe-back. 20 swapped to
//   CupertinoPageRoute here (music_navigation, video_detail_router,
//   song_search x5, music_player_sheet, track_more_sheet x2,
//   artist_detail, charts x2, daily, favourites, playlist_detail,
//   plaza, accent_color_sheet). The player_expand_route no-MediaQuery
//   fallback is CupertinoPageRoute too, but has no widget test:
//   flutter_test always injects a MediaQuery, so the branch is
//   unreachable in tests (and in the app); grep-verified instead. The
//   other 7 (video_tab_page x5, emby_tab_page x2) sit in files owned
//   by other groups — NOT touched, left for the coordinator.
// - N-2: bottom bar + back chevrons + player/search nav icons are
//   CupertinoIcons now (see hao_icon_map.dart for the table).
// - N-7: sub-page AppBars carry HaoAppBarGlass (BackdropFilter) as
//   flexibleSpace; title stays 17 w700 in all 8 combinations.
// - N-10: the 6 grabber-less sheets get showDragHandle + the settle
//   spring rise; all sheet top corners are HaoRadius.sheet == 14.
// - N-14: player close uses the same settle spring as open (the
//   mid-close offset test lives in player_expand_route_test.dart —
//   it needs that file's shell harness); sheets rise on the same
//   spring via sheetAnimationStyle. See the curve-shape test below.
// - N-20: tab PageView uses AppShell.tabPagePhysics (page snap +
//   Bouncing parent). Scratch measurement before the change: a +200
//   drag on the first page left the offset at 0.0 (stops dead);
//   after: -180.1 (overscroll with friction), settling back to 0.
//
// The two native-player sheets (episode / audio+subtitle) have no
// widget-test harness for the player page, so their grabber is
// verified by the accent/picker/track-more/version sheet tests plus
// code review of the two call sites — see the report.

import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/native/now_playing.dart';
import 'package:standalone/core/theme/glass.dart';
import 'package:standalone/core/theme/hao_icon_map.dart';
import 'package:standalone/core/theme/hao_radius.dart';
import 'package:standalone/core/theme/hao_settle_spring.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/music/music_navigation.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/song_search_page.dart';
import 'package:standalone/features/music/widgets/track_more_sheet.dart';
import 'package:standalone/features/settings/accent_color_sheet.dart';
import 'package:standalone/features/video/video_detail_router.dart';
import 'package:standalone/features/video/video_detail_service.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/features/video/video_smart_groups.dart';
import 'package:standalone/features/video/video_version_sheet.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/widgets/app_shell.dart';

import 'helpers/hive_test_setup.dart';

/// Records routes as the Navigator pushes them (N-1: the pushed
/// route's TYPE is the assertion — no page needs to build for it).
class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

/// The framework drag handle rendered by showDragHandle: true —
/// a 32x4 rounded Container (see bottom_sheet.dart _DragHandle).
/// `Container` does not expose width/height, so the match is on the
/// tight constraints the 32x4 size folds into, plus the rounded
/// decoration.
// The iOS sheet grabber: HaoSheet's 36x5 pill (was the framework
// Material handle, 32x4, before the b30 sheet unification).
final Finder dragHandleFinder = find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.constraints?.maxWidth == 36 &&
      w.constraints?.maxHeight == 5 &&
      w.decoration is BoxDecoration,
);

Song _song(String id, String title) => Song(
      songId: id,
      title: title,
      artist: 'Artist $id',
      cover: '',
      platform: MusicPlatform.wy,
      dur: 200,
    );

/// Controller that never writes Hive from playNext (copied from
/// music_quick_menu_test.dart — a Hive write in the fake-async zone
/// wedges the box queue).
class _MenuTestController extends MusicPlayerController {
  @override
  Future<bool> playNext(Song song) async {
    final at = currentIndex.value < 0 ? 0 : currentIndex.value + 1;
    queue.insert(at, song);
    return true;
  }
}

VideoItem _item({
  required dynamic source,
  required String vodId,
  required String name,
  String year = '',
  String score = '',
  String pic = '',
  String remarks = '',
  String sourceName = '',
}) =>
    VideoItem(
      source: source,
      sourceName: sourceName,
      vodId: vodId,
      name: name,
      pic: pic,
      year: year,
      score: score,
      remarks: remarks,
    );

VideoDetail _cannedDetail() => VideoDetail(
      source: 12,
      vodId: 'v1',
      meta: VideoMeta(name: '庆余年', pic: '', year: '2019', score: '8.0'),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: [
            const PlayEpisode(name: '第1集', url: 'https://example.com/1.m3u8'),
          ],
        ),
      ],
    );

VideoDetailService _fakeDetailService() => VideoDetailService(
      fetchDetail: (source, vodId, {cancelToken}) async => _cannedDetail(),
      findAlts: (title, year, exclude, {cancelToken}) =>
          const Stream<AltVideoSource>.empty(),
    );

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init(prefix: 'hao-a1-native-');
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  setUp(() {
    HaoHaptics.debugEnabledOverride = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(nowPlayingChannelName),
          (call) async => null,
        );
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(nowPlayingChannelName),
          null,
        );
    Get.reset();
  });

  /// Pump a bare MaterialApp and capture a descendant context for
  /// route pushes that must not build the destination page.
  Future<BuildContext> pumpContext(
    WidgetTester tester,
    NavigatorObserver observer,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        navigatorObservers: [observer],
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();
    return ctx;
  }

  group('N-1 swipe-back routes', () {
    testWidgets('pushMusicSubPage pushes CupertinoPageRoute tagged music',
        (tester) async {
      final observer = _RecordingObserver();
      final ctx = await pumpContext(tester, observer);
      unawaited(pushMusicSubPage<void>(ctx, const Text('sub')));
      await tester.pump();
      expect(observer.pushed.last, isA<CupertinoPageRoute<void>>());
      final route = observer.pushed.last as CupertinoPageRoute<void>;
      expect(route, isA<CupertinoPageRoute<void>>());
      // Mini-player visibility depends on this name — unchanged.
      expect(route.settings.name, musicSubPageRouteName);
      Navigator.of(ctx).pop();
      await tester.pump();
    });

    testWidgets('openVideoDetail CMS branch pushes CupertinoPageRoute',
        (tester) async {
      final observer = _RecordingObserver();
      final ctx = await pumpContext(tester, observer);
      unawaited(
        openVideoDetail<void>(
          ctx,
          source: 12,
          vodId: '1',
          detailService: _fakeDetailService(),
        ),
      );
      // No pump: the pushed route is recorded synchronously and the
      // page is never built, so its Douban timers never start.
      expect(observer.pushed.last, isA<CupertinoPageRoute<void>>());
      Navigator.of(ctx).pop();
      await tester.pump();
    });

    testWidgets('openVideoDetail Emby branch pushes CupertinoPageRoute',
        (tester) async {
      final observer = _RecordingObserver();
      final ctx = await pumpContext(tester, observer);
      unawaited(openVideoDetail<void>(ctx, source: 'emby', vodId: 'e1'));
      // No pump: same reason as the CMS branch — the page is never
      // built, so no Emby fetch runs.
      expect(observer.pushed.last, isA<CupertinoPageRoute<void>>());
      Navigator.of(ctx).pop();
      await tester.pump();
    });

  });

  group('N-2 Cupertino icons', () {
    testWidgets('tab bar uses CupertinoIcons, no Material tab icons',
        (tester) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: GlassTabBar(currentIndex: 0, onTap: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(CupertinoIcons.film), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.tv), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.music_note), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.settings), findsOneWidget);
      expect(find.byIcon(Icons.movie), findsNothing);
      expect(find.byIcon(Icons.live_tv), findsNothing);
      expect(find.byIcon(Icons.settings), findsNothing);
    });

    test('icon map records the swapped set', () {
      expect(haoCupertinoIconMap[Icons.movie], CupertinoIcons.film);
      expect(haoCupertinoIconMap[Icons.live_tv], CupertinoIcons.tv);
      expect(
        haoCupertinoIconMap[Icons.keyboard_arrow_down],
        CupertinoIcons.chevron_down,
      );
      expect(haoCupertinoIconMap[Icons.arrow_back], CupertinoIcons.back);
      expect(haoCupertinoIconMap[Icons.tune], CupertinoIcons.slider_horizontal_3);
    });
  });

  group('N-7 AppBar frosted glass', () {
    test('appBarTheme title stays 17 w700 in all 8 combinations', () {
      for (final id in HaoThemeId.values) {
        final pair = HaoThemes.of(id);
        for (final theme in [pair.light, pair.dark]) {
          final style = theme.appBarTheme.titleTextStyle!;
          expect(style.fontSize, 17, reason: '$id');
          expect(style.fontWeight, FontWeight.w700, reason: '$id');
        }
      }
    });

    testWidgets('HaoAppBarGlass renders a BackdropFilter in the AppBar',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            appBar: AppBar(
              title: const Text('排行榜'),
              flexibleSpace: const HaoAppBarGlass(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
    });
  });

  group('N-10 sheets: grabber + 14pt top corner + spring rise', () {
    test('HaoRadius.sheet is 14 (D-7)', () {
      expect(HaoRadius.sheet, 14);
    });

    test('settle spring is ahead of easeOutCubic mid-flight', () {
      const curve = HaoSettleSpringCurve();
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
      // Spring at t=0.5 is ~0.95; easeOutCubic is 0.875, the old
      // sheet curve (legacyDecelerate) lower still. The >0.9 bound
      // separates the spring from both.
      final mid = curve.transform(0.5);
      expect(mid, greaterThan(0.9));
      expect(mid, lessThan(1.0));
    });

    testWidgets('GlassSheetBackground defaults to the 14pt top corner',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const Scaffold(
            body: GlassSheetBackground(child: Text('x')),
          ),
        ),
      );
      await tester.pump();
      final clip = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
      expect(
        clip.borderRadius,
        BorderRadius.vertical(top: Radius.circular(HaoRadius.sheet)),
      );
    });

    testWidgets('accent sheet has the framework grabber', (tester) async {
      Get.delete<ThemeController>(force: true);
      final themeController = Get.put(ThemeController());
      await tester.pumpWidget(
        Obx(
          () => GetMaterialApp(
            theme: themeController.lightTheme,
            home: Scaffold(
              body: Center(
                child: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showAccentColorSheet(context),
                    child: const Text('open sheet'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open sheet'));
      await tester.pumpAndSettle();
      expect(find.text('网格'), findsOneWidget);
      expect(dragHandleFinder, findsOneWidget);
    });

    testWidgets('platform picker has the framework grabber',
        (tester) async {
      Get.put(MusicPlayerController());
      await tester.pumpWidget(
        GetMaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const SongSearchPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('网易云').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('选择平台'), findsOneWidget);
      expect(dragHandleFinder, findsOneWidget);
    });

    testWidgets('track-more sheet has the framework grabber',
        (tester) async {
      Get.put<MusicPlayerController>(_MenuTestController());
      final song = _song('a', 'Song A');
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showTrackMoreSheet(context, song),
                  child: const Text('open sheet'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open sheet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Song A'), findsWidgets);
      expect(dragHandleFinder, findsOneWidget);
    });

    testWidgets('version sheet has the framework grabber', (tester) async {
      final group = GroupedVideoItem(
        key: '庆余年|2019',
        representative: _item(
          source: 12,
          vodId: '1001',
          name: '庆余年',
          year: '2019',
          score: '8.0',
          remarks: '更新至第46集',
          sourceName: '金鹰',
        ),
        versions: [
          _item(
            source: 12,
            vodId: '1001',
            name: '庆余年',
            year: '2019',
            score: '8.0',
            remarks: '更新至第46集',
            sourceName: '金鹰',
          ),
          _item(
            source: 5,
            vodId: '2002',
            name: '庆余年',
            year: '2019',
            score: '7.5',
            remarks: '高清',
            sourceName: '非凡',
          ),
        ],
      );
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showVideoVersionsSheet(
                    context,
                    group: group,
                    detailService: _fakeDetailService(),
                  ),
                  child: const Text('打开版本'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开版本'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('金鹰'), findsOneWidget);
      expect(dragHandleFinder, findsOneWidget);
    });
  });

  group('N-20 tab PageView end bounce', () {
    Future<PageController> pumpPages(WidgetTester tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: PageView(
            controller: controller,
            physics: AppShell.tabPagePhysics,
            children: const [
              ColoredBox(color: Colors.red),
              ColoredBox(color: Colors.green),
              ColoredBox(color: Colors.blue),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('first page overscrolls with friction, then springs back',
        (tester) async {
      final controller = await pumpPages(tester);
      expect(controller.offset, 0.0);
      await tester.drag(find.byType(PageView), const Offset(200, 0));
      await tester.pump();
      // Before the change this was 0.0 (stops dead); the Bouncing
      // parent lets it overscroll, damped (200 in, ~180 out).
      expect(controller.offset, lessThan(0));
      expect(controller.offset, greaterThan(-200));
      await tester.pumpAndSettle();
      expect(controller.offset, 0.0);
    });

    testWidgets('last page overscrolls, then springs back', (tester) async {
      final controller = await pumpPages(tester);
      controller.jumpToPage(2);
      await tester.pumpAndSettle();
      expect(controller.offset, 1600.0);
      await tester.drag(find.byType(PageView), const Offset(-200, 0));
      await tester.pump();
      expect(controller.offset, greaterThan(1600.0));
      expect(controller.offset, lessThan(1800.0));
      await tester.pumpAndSettle();
      expect(controller.offset, 1600.0);
    });

    test('fling threshold is the stock one (tab swipe feel unchanged)', () {
      expect(
        AppShell.tabPagePhysics.minFlingVelocity,
        kMinFlingVelocity,
      );
    });

    testWidgets('a normal swipe still changes page', (tester) async {
      final controller = await pumpPages(tester);
      await tester.fling(
        find.byType(PageView),
        const Offset(-400, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(controller.page?.round(), 1);
    });
  });
}
