// Bottom-bar drag (b30, chen 2026-11-23: “底栏菜单都不可以拖动了”).
//
// Root cause: build 26's Kumone bar was one big GestureDetector —
// dragging across it switched tabs live, the pill following the
// finger. Build 29 replaced the bar with the real UITabBar and
// deleted that drag layer with it; UITabBar is tap-only, so dragging
// the bar did nothing at all. The content-area PageView swipe was
// never removed (app_shell.dart still has PageView + tabPagePhysics),
// but the bar itself lost its drag.
//
// Fix: TabBarDragLayer — a translucent overlay on top of the native
// bar. Horizontal drags switch tabs as the finger crosses each cell
// (8pt dead zone, same as the old bar); taps fall through to the
// native bar untouched (translucent + drag-only handlers — an opaque
// detector would swallow the tap).
//
// Geometry at a 400pt-wide viewport: 4 cells -> cellW 100, centres
// 50 / 150 / 250 / 350, bar height 64, drag y = 32.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/widgets/app_shell.dart';

void main() {
  setUp(() {
    // Haptics are irrelevant here and Hive is not initialised in this
    // test — silence the entry point via the test override.
    HaoHaptics.debugEnabledOverride = false;
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  /// Pumps the real bar wrapped in the drag layer, wired like
  /// AppShell does (same onSelect for tap and drag).
  Future<int Function()> pumpDragBar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    var current = 0;
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return TabBarDragLayer(
                currentIndex: current,
                onSelect: (i) => setState(() => current = i),
                child: GlassTabBar(
                  currentIndex: current,
                  onTap: (i) => setState(() => current = i),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return () => current;
  }

  testWidgets('drag right across the bar switches tabs live', (
    tester,
  ) async {
    final current = await pumpDragBar(tester);
    // Start on tab 0 (x=50), drag to x=250 (tab 2).
    await tester.dragFrom(const Offset(50, 32), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(current(), 2);
    // Keep dragging to the last tab.
    await tester.dragFrom(const Offset(250, 32), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(current(), 3);
  });

  testWidgets('drag left across the bar switches back', (tester) async {
    final current = await pumpDragBar(tester);
    await tester.dragFrom(const Offset(50, 32), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(current(), 3);
    await tester.dragFrom(const Offset(350, 32), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(current(), 0);
  });

  testWidgets('tap still switches tabs (native bar untouched)', (
    tester,
  ) async {
    final current = await pumpDragBar(tester);
    await tester.tapAt(const Offset(350, 32));
    await tester.pumpAndSettle();
    expect(current(), 3);
    await tester.tapAt(const Offset(150, 32));
    await tester.pumpAndSettle();
    expect(current(), 1);
  });

  testWidgets('movement under the 8pt dead zone does not switch', (
    tester,
  ) async {
    final current = await pumpDragBar(tester);
    await tester.dragFrom(const Offset(50, 32), const Offset(5, 0));
    await tester.pumpAndSettle();
    expect(current(), 0);
  });
}
