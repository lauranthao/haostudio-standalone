// Tab pages stay alive across tab switches (stutter fix, chen
// 2026-11-20).
//
// Root cause: the bottom tab is a PageView with no AutomaticKeepAlive,
// so every tab switch disposed the target page's State and the page
// rebuilt from scratch (lists, images, Hive) on the UI thread while
// the pill was dragging/springing — dropped frames, a choppy slide.
// With AutomaticKeepAliveClientMixin on all four tab pages, a switch
// is just a page flip: the off-screen page's State is kept in the
// sliver's keep-alive bucket instead of being disposed, so nothing
// rebuilds on return.
//
// The test pumps a PageView (music page + a dummy page), jumps away
// and back, and asserts the music page's State is the SAME object —
// i.e. it was never disposed. MusicTabPage is the representative
// case (the heaviest page); the other three pages carry the identical
// one-line mixin (live/video/settings), verified by code inspection +
// analyze. The music page's section-collapse persistence is covered
// separately by music_home_sections_persist_test.dart (Hive-backed).

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

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-keepalive-test-');
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
  });

  // NOTE: do NOT await the Hive box close here. Pending Hive writes
  // from fire-and-forget puts never resolve in the widget-test fake
  // zone, so awaiting close() hangs tearDownAll forever.
  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    HaoHaptics.debugEnabledOverride = false;
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  testWidgets('music page State survives a PageView switch away and back',
      (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    Get.put(MusicPlayerController());
    final controller = PageController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: PageView(
          controller: controller,
          children: [
            MusicTabPage(api: _EmptyCoverApi()),
            const Scaffold(body: Center(child: Text('dummy'))),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final before = tester.state(find.byType(MusicTabPage));
    expect(find.byType(MusicTabPage), findsOneWidget);

    // Switch away and back. NOTE: while off-screen the page is NOT
    // findable (a kept-alive element sits in the sliver's keep-alive
    // bucket, detached from the element tree) — that is normal. The
    // proof of keep-alive is that the State coming back is the SAME
    // object: without the mixin the PageView disposes it on the
    // switch away and a fresh State is built on return.
    controller.jumpToPage(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('dummy'), findsOneWidget);

    controller.jumpToPage(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.state(find.byType(MusicTabPage)),
      same(before),
      reason: 'the State must not have been disposed + rebuilt',
    );
    expect(find.text('我喜欢的音乐'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
