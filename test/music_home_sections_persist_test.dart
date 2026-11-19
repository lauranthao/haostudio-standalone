// Music home section collapse persistence.
//
// chen reported: on the music home, 最近播放 and 我的歌单 reopen by
// themselves after being collapsed (tab switch / restart).
//
// Hypothesis under test: the two expanded flags are in-memory setState
// only (music_tab_page.dart:155-156), and the bottom tab is a PageView
// with no AutomaticKeepAlive, so switching 2 tabs away disposes the
// music page State and re-entering resets both flags to true. Restart
// resets them the same way.
//
// The test collapses a section, disposes the page, pumps a fresh
// MusicTabPage, and asserts the section is STILL collapsed. Before the
// fix this fails (flags reset to true); after the fix it passes.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:standalone/features/music/widgets/collapsible_section.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-sections-test-');
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
    // box's write queue — a later awaited put (test 3's runAsync
    // write) then waits forever (the full-file run hung in test 3
    // for 3+ min on exactly this). The memory backend's writeFrames
    // is Future.value(), no file I/O, no wedge.
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
    // Distinct songs per section so a body row identifies its section.
    await MusicStore.saveLists([
      UserPlaylist(
        id: 'p1',
        name: '我喜欢的音乐',
        tracks: [
          Song(
            songId: 'wy-1',
            title: '富士山下',
            artist: '陈奕迅',
            album: "What's Going On...?",
            platform: MusicPlatform.wy,
            dur: 245,
          ),
        ],
      ),
    ]);
    await MusicStore.addRecent(
      Song(
        songId: 'wy-2',
        title: '孤勇者',
        artist: '陈奕迅',
        album: '孤勇者',
        platform: MusicPlatform.wy,
        dur: 256,
      ),
    );
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
    // Each test starts from the default (expanded) state. Tests 1-3
    // leave the keys false (collapsed) behind, so reset them here —
    // otherwise test 4 would start collapsed and its first "collapse"
    // tap would expand instead.
    await HiveStore.put(HiveKeys.musicRecentExpanded, true);
    await HiveStore.put(HiveKeys.musicPlaylistsExpanded, true);
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Get.put(MusicPlayerController());
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: const MusicTabPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Dispose the page the way a tab switch does (PageView drops the
  /// State) and pump a fresh MusicTabPage.
  Future<void> disposeAndRebuild(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: const SizedBox(),
      ),
    );
    await tester.pump();
    await pumpHome(tester);
  }

  /// Hive writes must run in the real zone (runAsync); they hang
  /// inside the fake-async zone. Drain real async work after a tap so
  /// the page's setState and the fire-and-forget Hive put have landed.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  bool sectionExpanded(WidgetTester tester, String title) {
    final section = tester.widget<CollapsibleSection>(
      find.byWidgetPredicate(
        (w) => w is CollapsibleSection && w.title == title,
      ),
    );
    return section.expanded;
  }

  Future<void> toggleSection(WidgetTester tester, String title) async {
    await tester.ensureVisible(find.text(title));
    await tester.pump();
    await tester.tap(find.text(title));
    await settle(tester);
  }

  Future<void> collapseSection(WidgetTester tester, String title) async {
    await toggleSection(tester, title);
    expect(sectionExpanded(tester, title), isFalse);
  }

  testWidgets('最近播放 stays collapsed after the page is disposed and rebuilt',
      (tester) async {
    await pumpHome(tester);
    expect(sectionExpanded(tester, '最近播放'), isTrue);
    await collapseSection(tester, '最近播放');
    await disposeAndRebuild(tester);
    expect(sectionExpanded(tester, '最近播放'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('我的歌单 stays collapsed after the page is disposed and rebuilt',
      (tester) async {
    await pumpHome(tester);
    expect(sectionExpanded(tester, '我的歌单'), isTrue);
    await collapseSection(tester, '我的歌单');
    await disposeAndRebuild(tester);
    expect(sectionExpanded(tester, '我的歌单'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a collapsed section stays collapsed on a fresh read from Hive',
      (tester) async {
    // Restart path: the key is already false before the page exists.
    await tester.runAsync(() async {
      await HiveStore.put(HiveKeys.musicRecentExpanded, false);
      await HiveStore.put(HiveKeys.musicPlaylistsExpanded, false);
    });
    await pumpHome(tester);
    expect(sectionExpanded(tester, '最近播放'), isFalse);
    expect(sectionExpanded(tester, '我的歌单'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('re-expanding a section persists expanded', (tester) async {
    await pumpHome(tester);
    await collapseSection(tester, '最近播放');
    await toggleSection(tester, '最近播放');
    expect(sectionExpanded(tester, '最近播放'), isTrue);
    await disposeAndRebuild(tester);
    expect(sectionExpanded(tester, '最近播放'), isTrue);
    expect(tester.takeException(), isNull);
  });
}
