// GlassTabBar drag-to-switch (Beans KumoneGlassTabBar dragGesture)
// + settle spring (GlassTabBar.swift:36 spring(0.35, 0.82))
// + Kumone pill, restored 2026-11-21 (chen: Kumone那种，不要文字，
// 不要影子）: faint-tint pill, cellW - 8 = 84 wide, slides as one
// piece (no lens, no stretch, no magnification); icon-only tabs;
// selected icon = theme accent, unselected = primary 0.8; no shadow
// on the bar or the mini player.
//
// Geometry at a 400pt-wide viewport: outer Padding 12 + GlassCard
// inset 4 leaves 368pt for 4 cells -> cellW 92, cell centres (global)
// 62 / 154 / 246 / 338, bar height 56 + 8 inset at the top. The pill
// is 84 wide, so its settled left edge (global) is
// 20 / 112 / 204 / 296 for tabs 0..3, top edge 4.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
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

    await tester.tapAt(const Offset(246, 32));
    await tester.pumpAndSettle();
    expect(tapped, [2]);
    expect(current, 2);
  });

  test('settle spring is a real underdamped spring (Kumone 0.35/0.82)', () {
    // SpringDescription from GlassTabBar.swift:36 response 0.35,
    // dampingFraction 0.82: ω = 2π/0.35, stiffness = ω²,
    // damping = 2·ζ·ω. ζ < 1, so the simulation must overshoot its
    // target slightly and then converge — an ease curve cannot do
    // either of these, which is what distinguishes the real spring.
    final sim = SpringSimulation(GlassTabBarState.settleSpring, 0.0, 1.0, 0.0);
    var max = 0.0;
    for (var t = 0.0; t <= 1.0; t += 0.001) {
      max = math.max(max, sim.x(t));
    }
    expect(max, greaterThan(1.002));
    expect(sim.x(1.0), closeTo(1.0, 0.002));
  });

  testWidgets('tap settles the pill on the tapped tab with the spring',
      (tester) async {
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
                onTap: (i) => setState(() => current = i),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Exact Offset equality is too strict here: the spring settles
    // to within simulation tolerance, not to the exact double.
    var topLeft = tester.getTopLeft(find.byKey(GlassTabBarState.pillKey));
    expect(topLeft.dx, closeTo(20, 0.5));
    expect(topLeft.dy, closeTo(4, 0.5));

    await tester.tapAt(const Offset(246, 32));
    await tester.pumpAndSettle();
    expect(current, 2);
    topLeft = tester.getTopLeft(find.byKey(GlassTabBarState.pillKey));
    expect(topLeft.dx, closeTo(204, 0.5));
    expect(topLeft.dy, closeTo(4, 0.5));
  });

  testWidgets('drag tracks the finger, release settles on the tab',
      (tester) async {
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
                onTap: (i) => setState(() => current = i),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(62, 32));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    // The first move only wins the gesture arena: the drag starts at
    // the post-move finger position, so this move's own update is
    // below the 8pt threshold and the pill has not moved yet.
    expect(
      tester.getTopLeft(find.byKey(GlassTabBarState.pillKey)).dx,
      closeTo(20, 0.5),
    );
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    // Finger at global x 162 (content-local 146): the pill's left
    // edge follows it exactly (146 - 42 = 104 content-local, 120
    // global) — no 350ms ease lag while dragging.
    expect(
      tester.getTopLeft(find.byKey(GlassTabBarState.pillKey)).dx,
      closeTo(120, 1.0),
    );
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(current, 2);
    final topLeft = tester.getTopLeft(find.byKey(GlassTabBarState.pillKey));
    expect(topLeft.dx, closeTo(204, 0.5));
    expect(topLeft.dy, closeTo(4, 0.5));
  });

  testWidgets('tap on the current tab does nothing', (tester) async {
    final tapped = <int>[];
    await pumpBar(
      tester,
      currentIndex: 1,
      onTap: tapped.add,
    );

    await tester.tapAt(const Offset(154, 32));
    await tester.pump();
    expect(tapped, isEmpty);
  });

  testWidgets('drag across cells switches per cell crossed', (tester) async {
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

    final gesture = await tester.startGesture(const Offset(62, 32));
    // The first 40pt move only wins the gesture arena (the drag
    // starts at the post-move finger position, still in cell 0 ->
    // no switch), then each cell crossing switches.
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tapped, [1, 2]);
    expect(current, 2);
  });

  testWidgets('drag under 8pt does not switch', (tester) async {
    final tapped = <int>[];
    await pumpBar(
      tester,
      currentIndex: 0,
      onTap: tapped.add,
    );

    final gesture = await tester.startGesture(const Offset(62, 32));
    await gesture.moveBy(const Offset(5, 0));
    await gesture.up();
    await tester.pump();
    expect(tapped, isEmpty);
  });

  testWidgets('rest width is cellW - 8', (tester) async {
    await pumpBar(
      tester,
      currentIndex: 1,
      onTap: (_) {},
    );

    final size = tester.getSize(find.byKey(GlassTabBarState.pillKey));
    expect(size.width, closeTo(84, 1.0)); // cellW 92 - 8
    expect(size.height, closeTo(56, 0.5));
    final topLeft = tester.getTopLeft(find.byKey(GlassTabBarState.pillKey));
    expect(topLeft.dx, closeTo(112, 0.5));
    expect(topLeft.dy, closeTo(4, 0.5));
  });

  testWidgets('slide does not stretch mid-flight', (tester) async {
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
                onTap: (i) => setState(() => current = i),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // One-cell slide (tab 0 -> 1): the Kumone pill slides as ONE
    // piece on a single spring — no leading/trailing stagger, so its
    // width stays cellW - 8 = 84 throughout the flight.
    await tester.tapAt(const Offset(154, 32));
    await tester.pump();
    var maxWidth = 0.0;
    var minWidth = 1000.0;
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final w = tester.getSize(find.byKey(GlassTabBarState.pillKey)).width;
      maxWidth = math.max(maxWidth, w);
      minWidth = math.min(minWidth, w);
    }
    expect(maxWidth, closeTo(84, 1.0));
    expect(minWidth, closeTo(84, 1.0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(GlassTabBarState.pillKey)).width,
      closeTo(84, 1.0),
    );
    expect(current, 1);
  });

  testWidgets('selected icon is the theme accent, others primary 0.8',
      (tester) async {
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
                onTap: (i) => setState(() => current = i),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final hao =
        HaoThemes.of(HaoThemeId.appleGlass).light.extension<HaoTheme>()!;

    Color iconColor(int i) =>
        tester.widget<Icon>(find.byType(Icon).at(i)).color!;
    // At rest the selected tab (0) is the theme accent, the rest are
    // primary at 0.8 — the pill + the accent together mark the
    // selection (Kumone).
    expect(iconColor(0), hao.accent);
    expect(iconColor(1), hao.textPrimary.withValues(alpha: 0.8));
    // Mid-slide (tab 0 -> 1): the tap already moved the selection
    // (onTap fires on tapUp; only the pill animates), so the colours
    // have already switched — icon 1 is the accent, icon 0 is 0.8.
    await tester.tapAt(const Offset(154, 32));
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

  testWidgets('theme matrix: pill + icons readable in all 8 combos',
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
        // The pill is present and every tab icon follows the Kumone
        // rule (selected = accent, unselected = primary 0.8) in
        // every combination.
        expect(
          find.byKey(GlassTabBarState.pillKey),
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
        // The pill is the Kumone faint tint (white 0.10 dark /
        // black 0.075 light) — the exact value, not a luminance
        // threshold: the tint is faint by design.
        final pillDecoration = tester
            .widget<Container>(find.byKey(GlassTabBarState.pillKey))
            .decoration as BoxDecoration;
        expect(
          pillDecoration.color,
          mode == Brightness.dark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.black.withValues(alpha: 0.075),
          reason: '$id $mode: pill tint',
        );
        expect(tester.takeException(), isNull);
      }
    }
  });
}
