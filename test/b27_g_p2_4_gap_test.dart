// G-P2-4 gap fix (coordinator): the two real consumers of
// chromeSettings — GlassTabBar (app_shell.dart) and MiniPlayerBar
// (mini_player_bar.dart) — still called the throwing HaoTheme.of().
// Both now read via HaoTheme.ofOrDefault(); these tests prove they
// render under a bare ThemeData (no HaoTheme extension) instead of
// throwing. Production always carries the extension, so the look is
// unchanged there.

import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/music/widgets/mini_player_bar.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/widgets/app_shell.dart';

void main() {
  late Directory hiveDir;

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
    hiveDir = await Directory.systemTemp.createTemp('hao-gp24-gap-test-');
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

  setUp(() {
    HaoHaptics.debugEnabledOverride = false;
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  testWidgets('GlassTabBar renders under a bare ThemeData',
      (tester) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // No HaoTheme extension anywhere: a throwing read would fail here.
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData.light(),
        home: Scaffold(
          body: GlassTabBar(currentIndex: 0, onTap: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GlassTabBar), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.film), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.tv), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.music_note), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.settings), findsOneWidget);
  });

  testWidgets('MiniPlayerBar renders under a bare ThemeData',
      (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = Get.put(MusicPlayerController());
    player.queue.assignAll([testSong]);
    player.currentIndex.value = 0;
    final themeController = Get.put(ThemeController());
    themeController.loadFromBox(HiveStore.box);
    // No HaoTheme extension anywhere: a throwing read would fail here.
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData.light(),
        home: Scaffold(
          body: MiniPlayerBar(onOpenPlayer: (_) {}),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('富士山下'), findsOneWidget);
  });
}
