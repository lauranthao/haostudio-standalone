// Music home — Kumone redo (P0+P1) regression tests.
//
// - Sections default EXPANDED (P0-2); tapping a head still collapses.
// - No AppBar; the greeting is the one large title, 34 bold (P0-4).
// - Feature shelf present (P0-1); library rows are plain 32-cover
//   rows in one container (P0-3); slim import row (P1-9).
// - Mini player has FOUR 44x44 controls (mode / prev / play / next)
//   and fits 390pt without overflow (P1-6, iron rule: mode button
//   must not be deleted).
// - 「播放全部」 capsule plays the whole recent queue from index 0
//   and does NOT toggle the section (P1-10).
// - Empty states are the Kumone empty-state component (P1-12).
//
// The player controller is doubled: playQueue / prev / next /
// togglePlayPause / cyclePlayMode are recorded no-ops, so no audio
// URL is ever resolved in the test zone.

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
import 'package:standalone/features/music/music_player_sheet.dart';
import 'package:standalone/features/music/music_tab_page.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

/// Offline cover fetch for the home's lazy first-cover fill: the
/// home must never hit the real network from a test (flaky + slow).
/// Empty lists keep every card on its gradient.
class _EmptyCoverApi extends MusicApi {
  @override
  Future<List<PlaylistSummary>> plaza(MusicPlatform pf) async => [];

  @override
  Future<List<PlaylistSummary>> neteaseCharts() async => [];
}

class _NoLoadController extends MusicPlayerController {
  final List<(List<Song>, int)> playQueueCalls = [];
  var prevCalls = 0;
  var nextCalls = 0;
  var toggleCalls = 0;
  var cycleModeCalls = 0;

  @override
  Future<void> playQueue(
    List<Song> songs,
    int index, {
    String label = '',
  }) async {
    playQueueCalls.add((songs, index));
    queue.assignAll(songs);
    currentIndex.value = index;
  }

  @override
  Future<void> prev() async {
    prevCalls++;
  }

  @override
  Future<void> next({bool auto = false}) async {
    nextCalls++;
  }

  @override
  Future<void> togglePlayPause() async {
    toggleCalls++;
  }

  @override
  Future<void> cyclePlayMode() async {
    cycleModeCalls++;
  }
}

List<Song> _sampleSongs() => [
  // Song.dur is SECONDS (formatDuration takes seconds; the APIs
  // convert ms -> s on parse).
  Song(
    songId: 'wy-1',
    title: '富士山下',
    artist: '陈奕迅',
    album: "What's Going On...?",
    platform: MusicPlatform.wy,
    dur: 245,
  ),
  Song(
    songId: 'wy-2',
    title: '孤勇者',
    artist: '陈奕迅',
    album: '孤勇者',
    platform: MusicPlatform.wy,
    dur: 256,
  ),
  Song(
    songId: 'tx-1',
    title: '晴天',
    artist: '周杰伦',
    album: '叶惠美',
    platform: MusicPlatform.tx,
    dur: 269,
  ),
];

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-music-home-kumone-');
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
      'test_music_home_kumone',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    HaoHaptics.debugEnabledOverride = false;
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  Future<_NoLoadController> pumpHome(
    WidgetTester tester, {
    bool seedLists = true,
    bool seedRecents = true,
    bool seedQueue = false,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final songs = _sampleSongs();
    await MusicStore.saveLists(
      seedLists
          ? [
              UserPlaylist(id: 'p1', name: '我喜欢的音乐', tracks: songs),
              UserPlaylist(id: 'p2', name: '粤语经典', tracks: songs.sublist(0, 2)),
            ]
          : [],
    );
    // Clear recents from earlier tests, then seed if asked.
    await MusicStore.clearRecent();
    if (seedRecents) {
      for (final s in songs) {
        await MusicStore.addRecent(s);
      }
    }
    // Register under the BASE type: MusicPlayerController.ensure()
    // looks up MusicPlayerController, and Get.put(double) alone would
    // register under the subclass type, leaving ensure() to build a
    // second, real controller with an empty queue.
    final controller = _NoLoadController();
    Get.put<MusicPlayerController>(controller);
    if (seedQueue) {
      controller.queue.assignAll(songs);
      controller.currentIndex.value = 0;
    }
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme ?? HaoThemes.of(HaoThemeId.appleGlass).light,
        home: MusicTabPage(api: _EmptyCoverApi()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    return controller;
  }

  testWidgets('sections default expanded, no AppBar, no greeting', (
    tester,
  ) async {
    await pumpHome(tester);
    expect(find.byType(AppBar), findsNothing);
    // Greeting/date header removed (clean pass 2026-11-19): no
    // time-of-day greeting anywhere on the page; the feature shelf
    // is the page's visual anchor.
    expect(find.text('早上好'), findsNothing);
    expect(find.text('下午好'), findsNothing);
    expect(find.text('晚上好'), findsNothing);
    // Both sections open without any tap: rows, import box, 新建 button.
    expect(find.text('我喜欢的音乐'), findsOneWidget);
    expect(find.text('粤语经典'), findsOneWidget);
    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.text('已下载'), findsOneWidget);
    expect(find.text('本地文件'), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);
    expect(find.text('新建歌单'), findsOneWidget);
    expect(find.text('富士山下'), findsOneWidget);
    expect(find.text('播放全部'), findsOneWidget);
    // Feature shelf: all five entries, Kumone FeatureCard titles.
    for (final label in ['搜歌', '每日推荐', '歌单广场', '排行榜', '听歌报告']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a head still collapses and re-expands', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.text('我的歌单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // AnimatedCrossFade keeps the hidden child in the tree (opacity
    // 0), so plain find.text still matches it — hitTestable() is the
    // assertion that the rows are really gone from the screen.
    expect(find.text('我喜欢的音乐').hitTestable(), findsNothing);
    expect(find.text('导入').hitTestable(), findsNothing);
    // The other section is independent.
    expect(find.text('富士山下').hitTestable(), findsOneWidget);
    await tester.tap(find.text('我的歌单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('我喜欢的音乐').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mini player: 4x44 controls fit 390pt, mode kept', (
    tester,
  ) async {
    // No recents seeded: the only play_arrow on the page is the mini
    // player's, so the icon finders below are unambiguous.
    final controller = await pumpHome(
      tester,
      seedRecents: false,
      seedQueue: true,
    );
    // All four controls present: mode (keyed — the bar has no tooltips:
    // Tooltip needs an Overlay ancestor and the overlay placement sits
    // above the root Navigator), prev, play, next.
    // The 「播放全部」 capsule also uses a play_arrow (size 13), so
    // the mini player's play button is identified by its size 15.
    // getRect on an icon/tooltip measures the glyph, not the button:
    // resolve each control to its IconButton for the 44x44 check.
    final miniPlay = find.byWidgetPredicate(
      (w) => w is Icon && w.icon == Icons.play_arrow && w.size == 15,
    );
    Finder controlButton(Finder inner) =>
        find.ancestor(of: inner, matching: find.byType(IconButton));
    final modeButton = find.byKey(const ValueKey('mini-mode'));
    final prevButton = controlButton(find.byIcon(Icons.skip_previous));
    final playButton = controlButton(miniPlay);
    final nextButton = controlButton(find.byIcon(Icons.skip_next));
    expect(modeButton, findsOneWidget);
    expect(prevButton, findsOneWidget);
    expect(playButton, findsOneWidget);
    expect(nextButton, findsOneWidget);
    // Every control is 44x44 and inside the 390pt screen.
    for (final finder in [modeButton, prevButton, playButton, nextButton]) {
      final rect = tester.getRect(finder);
      expect(rect.width, 44);
      expect(rect.height, 44);
      expect(rect.left, greaterThanOrEqualTo(0.0));
      expect(rect.right, lessThanOrEqualTo(390.0));
    }
    // No overflow from the 4-button row.
    expect(tester.takeException(), isNull);
    // Controls work through the controller double (no audio load).
    await tester.tap(modeButton);
    await tester.pump();
    expect(controller.cycleModeCalls, 1);
    await tester.tap(prevButton);
    await tester.pump();
    expect(controller.prevCalls, 1);
    await tester.tap(nextButton);
    await tester.pump();
    expect(controller.nextCalls, 1);
    await tester.tap(playButton);
    await tester.pump();
    expect(controller.toggleCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('play-all plays the recent queue and does not collapse', (
    tester,
  ) async {
    final controller = await pumpHome(tester);
    await tester.tap(find.text('播放全部'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.playQueueCalls, hasLength(1));
    expect(controller.playQueueCalls.single.$1.length, 3);
    expect(controller.playQueueCalls.single.$2, 0);
    // The tap opened the player page; popping back, the section is
    // still expanded — the capsule tap must not also toggle collapse.
    expect(find.byType(MusicPlayerPage), findsOneWidget);
    // No system back button on the player page (custom chrome), so
    // pop through the Navigator directly.
    Navigator.of(tester.element(find.byType(MusicPlayerPage))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The third recent row sits below the fold once the mini player
    // appears (play-all started playback, so the bar is showing):
    // scroll it into view before asserting it is tappable.
    await tester.ensureVisible(find.text('富士山下').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('富士山下').hitTestable(), findsOneWidget);
    expect(find.text('我喜欢的音乐').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty states use the Kumone empty-state component', (
    tester,
  ) async {
    await pumpHome(tester, seedLists: false, seedRecents: false);
    expect(find.text('还没有歌单'), findsOneWidget);
    expect(find.text('暂无播放记录'), findsOneWidget);
    // Subtitles removed (clean pass 2026-11-19): icon + title only.
    expect(find.text('搜一首歌加进来吧'), findsNothing);
    expect(find.text('搜首歌播一下吧'), findsNothing);
    // Play-all capsule is present but disabled with nothing to play.
    expect(find.text('播放全部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all 4 themes x light/dark render without overflow', (
    tester,
  ) async {
    // Every colour on the page comes from HaoTheme (no hardcoded
    // colours); this pumps all 8 combinations with a queued song so
    // the mini player renders too, and asserts nothing overflows.
    for (final id in HaoThemeId.values) {
      for (final mode in [Brightness.light, Brightness.dark]) {
        final pair = HaoThemes.of(id);
        await pumpHome(
          tester,
          seedQueue: true,
          theme: mode == Brightness.light ? pair.light : pair.dark,
        );
        expect(find.text('我的歌单'), findsOneWidget);
        expect(find.text('搜歌'), findsOneWidget);
        expect(find.byIcon(Icons.skip_next), findsOneWidget);
        expect(tester.takeException(), isNull);
        Get.reset();
      }
    }
  });
}
