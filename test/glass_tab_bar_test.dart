// Apple-native tab bar (build-29 adoption, chen 2026-11-22: “都要原生
// 效果”): glassy_ui_ios GlassTabBar on iOS, the Flutter
// _AppleTabBarFallback on this host — labels under every icon,
// transparent tint pill (theme accentSoft), .bouncy slide, tap only,
// NO drag, NO Kumone settle spring.
//
// Geometry at a 400pt-wide viewport: full-width bar, 4 cells ->
// cellW 100, pill cellW - 8 = 92 wide, 56 high, top 4. Settled pill
// left edges (global): 4 / 104 / 204 / 304 for tabs 0..3. Cell
// centres (global): 50 / 150 / 250 / 350, bar height 64, centre y = 32.

import 'dart:math' as math;

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
    // Reset Get singletons between tests.
    Get.reset();
  });

  Future<void> pumpBar(
    WidgetTester tester, {
    required int currentIndex,
    required ValueChanged<int> onTap,
  }) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: GlassTabBar(currentIndex: currentIndex, onTap: onTap),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpLiveBar(
    WidgetTester tester, {
    int start = 0,
  }) async {
    var current = start;
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return GlassTabBar(
                currentIndex: current,
                onTap: (i) => setState(() => current = i),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('every tab shows its label', (tester) async {
    await pumpBar(tester, currentIndex: 0, onTap: (_) {});
    for (final label in ['影视', '直播', '音乐', '设置']) {
      expect(
        find.descendant(
          of: find.byType(GlassTabBar),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
    expect(find.byType(Icon), findsNWidgets(4));
  });

  testWidgets('tap switches to the tapped tab', (tester) async {
    final tapped = <int>[];
    var current = 0;
    await pumpBar(
      tester,
      currentIndex: current,
      onTap: (i) {
        tapped.add(i);
        current = i;
      },
    );

    await tester.tapAt(const Offset(250, 32));
    await tester.pumpAndSettle();
    expect(tapped, [2]);
    expect(current, 2);
  });

  testWidgets('tap settles the pill on the tapped tab', (tester) async {
    await pumpLiveBar(tester, start: 0);

    var topLeft = tester.getTopLeft(find.byKey(GlassTabBar.pillKey));
    expect(topLeft.dx, closeTo(4, 0.5));
    expect(topLeft.dy, closeTo(4, 0.5));

    await tester.tapAt(const Offset(250, 32));
    await tester.pumpAndSettle();
    topLeft = tester.getTopLeft(find.byKey(GlassTabBar.pillKey));
    expect(topLeft.dx, closeTo(204, 0.5));
    expect(topLeft.dy, closeTo(4, 0.5));
  });

  testWidgets('drag across cells switches nothing', (tester) async {
    final tapped = <int>[];
    var current = 0;
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return GlassTabBar(
                currentIndex: current,
                onTap: (i) {
                  tapped.add(i);
                  setState(() => current = i);
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Kumone drag is void: a finger drag across two cells must not
    // switch tabs and must not move the pill. Only taps switch.
    final gesture = await tester.startGesture(const Offset(50, 32));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tapped, isEmpty);
    expect(current, 0);
    expect(
      tester.getTopLeft(find.byKey(GlassTabBar.pillKey)).dx,
      closeTo(4, 0.5),
    );
  });

  testWidgets('rest pill is cellW - 8 with the tint', (tester) async {
    await pumpBar(
      tester,
      currentIndex: 1,
      onTap: (_) {},
    );

    final size = tester.getSize(find.byKey(GlassTabBar.pillKey));
    expect(size.width, closeTo(92, 1.0)); // cellW 100 - 8
    expect(size.height, closeTo(56, 0.5));
    final topLeft = tester.getTopLeft(find.byKey(GlassTabBar.pillKey));
    expect(topLeft.dx, closeTo(104, 0.5));
    expect(topLeft.dy, closeTo(4, 0.5));
    final decoration = tester
        .widget<Container>(find.byKey(GlassTabBar.pillKey))
        .decoration as BoxDecoration;
    final hao =
        HaoThemes.of(HaoThemeId.appleGlass).light.extension<HaoTheme>()!;
    expect(decoration.color, hao.accentSoft);
  });

  testWidgets('slide does not stretch mid-flight', (tester) async {
    await pumpLiveBar(tester, start: 0);

    // One-cell slide (tab 0 -> 1): the pill slides as ONE piece —
    // no leading/trailing stagger, so its width stays cellW - 8 = 92
    // throughout the flight.
    await tester.tapAt(const Offset(150, 32));
    await tester.pump();
    var maxWidth = 0.0;
    var minWidth = 1000.0;
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final w = tester.getSize(find.byKey(GlassTabBar.pillKey)).width;
      maxWidth = math.max(maxWidth, w);
      minWidth = math.min(minWidth, w);
    }
    expect(maxWidth, closeTo(92, 1.0));
    expect(minWidth, closeTo(92, 1.0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(GlassTabBar.pillKey)).width,
      closeTo(92, 1.0),
    );
  });

  testWidgets('selected icon is the theme accent, others primary 0.8',
      (tester) async {
    await pumpLiveBar(tester, start: 0);
    final hao =
        HaoThemes.of(HaoThemeId.appleGlass).light.extension<HaoTheme>()!;

    Color iconColor(int i) =>
        tester.widget<Icon>(find.byType(Icon).at(i)).color!;
    // At rest the selected tab (0) is the theme accent, the rest are
    // primary at 0.8 — the pill + the accent together mark the
    // selection.
    expect(iconColor(0), hao.accent);
    expect(iconColor(1), hao.textPrimary.withValues(alpha: 0.8));
    // Mid-slide (tab 0 -> 1): the tap already moved the selection
    // (onTap fires on tapUp; only the pill animates), so the colours
    // have already switched — icon 1 is the accent, icon 0 is 0.8.
    await tester.tapAt(const Offset(150, 32));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 100));
    expect(iconColor(0), hao.textPrimary.withValues(alpha: 0.8));
    expect(iconColor(1), hao.accent);
    // Settled on tab 1: the accent moves with the selection.
    await tester.pumpAndSettle();
    expect(iconColor(1), hao.accent);
    expect(iconColor(0), hao.textPrimary.withValues(alpha: 0.8));
  });

  testWidgets('theme matrix: pill + icons + labels in all 8 combos',
      (tester) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    for (final id in HaoThemeId.values) {
      for (final mode in [Brightness.light, Brightness.dark]) {
        final pair = HaoThemes.of(id);
        final themeData = mode == Brightness.light ? pair.light : pair.dark;
        await tester.pumpWidget(
          GetMaterialApp(
            theme: themeData,
            home: Scaffold(
              body: GlassTabBar(currentIndex: 2, onTap: (_) {}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final hao = themeData.extension<HaoTheme>()!;
        // The tint pill is present and every tab icon follows the
        // rule (selected = accent, unselected = primary 0.8) in
        // every combination — and every label is drawn.
        expect(
          find.byKey(GlassTabBar.pillKey),
          findsOneWidget,
          reason: '$id $mode: pill missing',
        );
        expect(
          tester.widget<Icon>(find.byType(Icon).at(2)).color,
          hao.accent,
          reason: '$id $mode: selected tab icon is not the accent',
        );
        expect(
          tester.widget<Icon>(find.byType(Icon).at(0)).color,
          hao.textPrimary.withValues(alpha: 0.8),
          reason: '$id $mode: unselected tab icon is not primary 0.8',
        );
        final pillDecoration = tester
            .widget<Container>(find.byKey(GlassTabBar.pillKey))
            .decoration as BoxDecoration;
        expect(
          pillDecoration.color,
          hao.accentSoft,
          reason: '$id $mode: pill is not the transparent accent tint',
        );
        for (final label in ['影视', '直播', '音乐', '设置']) {
          expect(
            find.text(label),
            findsOneWidget,
            reason: '$id $mode: label $label missing',
          );
        }
        expect(tester.takeException(), isNull);
      }
    }
  });
}
