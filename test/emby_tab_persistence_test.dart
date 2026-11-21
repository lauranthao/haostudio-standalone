// T12 — video tab mode persistence (audit §6.1).
//
// Contract under test (video_tab_page.dart + emby_models.dart):
// - storing 'emby' under hao_video_tab_mode survives a dispose +
//   rebuild of VideoTabPage (the Emby branch is still shown);
// - a dirty stored value reads back as 'cms';
// - stored 'emby' + unconfigured Emby shows the unconfigured empty
//   state — it never silently jumps back to the CMS branch.
//
// Only the Emby branch is asserted at widget level: it returns
// before any network (unconfigured => empty state). The CMS branch
// is asserted for its SELECTED segment only, then disposed
// immediately — VideoTabPage builds its own VideoHomeService with
// no injection point (see tab_keep_alive_scope_test.dart), so the
// CMS branch must never be left mounted at the end of a test.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/video/video_tab_page.dart';
import 'package:standalone/services/video/emby_models.dart';
import 'package:standalone/widgets/hao_segmented_control.dart';

import 'helpers/hive_test_setup.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init();
    // Memory-backed box: a Hive file write issued inside a widget
    // test's fake-async zone never completes there and wedges the
    // box's write queue (same reason as music_home_sections_persist).
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  setUp(() async {
    HaoHaptics.debugEnabledOverride = false;
    // Clean slate per test: no mode, no Emby config, no Emby cache.
    await HiveStore.delete(HiveKeys.videoTabMode);
    await HiveStore.delete(HiveKeys.embyConfig);
    await HiveStore.delete(HiveKeys.embyHomeCache);
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
  });

  Future<void> pumpTab(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: const VideoTabPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Dispose the page the way a tab switch does, so the CMS branch's
  /// in-flight fetches are cancelled via its dispose().
  Future<void> disposeTab(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: const SizedBox(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  VideoTabMode selectedMode(WidgetTester tester) {
    // 1.1.6: the tab switch is HaoSegmentedControl, not Material
    // SegmentedButton — read its value field.
    final control = tester.widget<HaoSegmentedControl<VideoTabMode>>(
      find.byType(HaoSegmentedControl<VideoTabMode>),
    );
    return control.value;
  }

  testWidgets(
    "stored 'emby' survives dispose + rebuild",
    (tester) async {
      await HiveStore.put(HiveKeys.videoTabMode, 'emby');
      await pumpTab(tester);
      expect(selectedMode(tester), VideoTabMode.emby);
      expect(find.text('还没有连接 Emby'), findsOneWidget);

      await disposeTab(tester);
      await pumpTab(tester);
      expect(selectedMode(tester), VideoTabMode.emby);
      expect(find.text('还没有连接 Emby'), findsOneWidget);
      // The rebuild did not rewrite the stored value.
      expect(HiveStore.getString(HiveKeys.videoTabMode, 'cms'), 'emby');
      await disposeTab(tester);
    },
  );

  testWidgets(
    'dirty stored value reads back as cms',
    (tester) async {
      await HiveStore.put(HiveKeys.videoTabMode, 'bogus');
      await pumpTab(tester);
      expect(selectedMode(tester), VideoTabMode.cms);
      expect(find.text('还没有连接 Emby'), findsNothing);
      await disposeTab(tester);
    },
  );

  testWidgets(
    "stored 'emby' + unconfigured Emby shows the empty state, "
    'not a silent jump back',
    (tester) async {
      await HiveStore.put(HiveKeys.videoTabMode, 'emby');
      // No Emby config anywhere: EmbyConfigStore.load() is null.
      expect(EmbyConfigStore.load(), isNull);
      await pumpTab(tester);
      expect(selectedMode(tester), VideoTabMode.emby);
      expect(find.text('还没有连接 Emby'), findsOneWidget);
      expect(find.text('在设置里填入服务器地址和密钥即可连接'), findsOneWidget);
      expect(find.text('去设置连接'), findsOneWidget);
      await disposeTab(tester);
    },
  );
}
