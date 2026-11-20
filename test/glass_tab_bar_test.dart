// GlassTabBar drag-to-switch (Beans KumoneGlassTabBar dragGesture)
// + settle spring (GlassTabBar.swift:36 spring(0.35, 0.82))
// + Muse pill: solid matte oval, 1 cell wide at rest, stretches
// mid-slide (leading edge on the settle spring, trailing edge on a
// 110ms-delayed spring), icon-only tabs, all icons theme text.
//
// Geometry at a 400pt-wide viewport: outer Padding 12 + GlassCard
// inset 4 leaves 368pt for 4 cells -> cellW 92, cell centres (global)
// 62 / 154 / 246 / 338, bar height 56 + 8 inset at the top. The pill
// is 1 cell = 92 wide, so its settled left edge (global) is
// 16 / 108 / 200 / 292 for tabs 0..3, top edge 4.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/core/theme/tab_bar_accent.dart';
import 'package:standalone/widgets/app_shell.dart';

void main() {
  setUp(() {
    // Haptics are irrelevant here and Hive is not initialised in this
    // test — silence the entry point via the test override.
    HaoHaptics.debugEnabledOverride = false;
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    // The accent controller is a Get singleton (created by the
    // tests that touch it); reset it so a colour set in one test
    // cannot leak into the next.
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
    expect(topLeft.dx, closeTo(16, 0.5));
    expect(topLeft.dy, closeTo(4, 0.5));

    await tester.tapAt(const Offset(246, 32));
    await tester.pumpAndSettle();
    expect(current, 2);
    topLeft = tester.getTopLeft(find.byKey(GlassTabBarState.pillKey));
    expect(topLeft.dx, closeTo(200, 0.5));
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
      closeTo(16, 0.5),
    );
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    // Finger at global x 162 (content-local 146): the pill's left
    // edge follows it exactly (146 - 46 = 100 content-local, 116
    // global) — no 350ms ease lag while dragging.
    expect(
      tester.getTopLeft(find.byKey(GlassTabBarState.pillKey)).dx,
      closeTo(116, 1.0),
    );
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(current, 2);
    final topLeft = tester.getTopLeft(find.byKey(GlassTabBarState.pillKey));
    expect(topLeft.dx, closeTo(200, 0.5));
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

  testWidgets('rest width is 1 cell', (tester) async {
    await pumpBar(
      tester,
      currentIndex: 1,
      onTap: (_) {},
    );

    final size = tester.getSize(find.byKey(GlassTabBarState.pillKey));
    expect(size.width, closeTo(92, 1.0)); // cellW 92 x 1.0
    expect(size.height, closeTo(56, 0.5));
    final topLeft = tester.getTopLeft(find.byKey(GlassTabBarState.pillKey));
    expect(topLeft.dx, closeTo(108, 0.5));
    expect(topLeft.dy, closeTo(4, 0.5));
  });

  testWidgets('slide stretches mid-flight then shrinks to 1 cell',
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

    // One-cell slide (tab 0 -> 1): the leading edge springs ahead
    // of the trailing edge, so the pill stretches mid-flight.
    await tester.tapAt(const Offset(154, 32));
    await tester.pump();
    var maxWidth = 0.0;
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      maxWidth = math.max(
        maxWidth,
        tester.getSize(find.byKey(GlassTabBarState.pillKey)).width,
      );
    }
    // Mid-flight the pill spans from->to: the 110ms trailing-edge
    // stagger on this spring (ω = 2π/0.35, ζ = 0.82) opens a ~64pt
    // gap on a 1-cell slide, so the sampled peak (50ms pumps) is
    // ~153pt ≈ 1.67 cells — the Muse reference width. The 145
    // threshold leaves margin for pump granularity.
    expect(maxWidth, greaterThan(145.0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(GlassTabBarState.pillKey)).width,
      closeTo(92, 1.0),
    );
  });

  testWidgets('icons are theme text in every state (Muse bar)',
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
    final textPrimary =
        HaoThemes.of(HaoThemeId.appleGlass).light.extension<HaoTheme>()!.textPrimary;

    Color iconColor(int i) =>
        tester.widget<Icon>(find.byType(Icon).at(i)).color!;
    // At rest every tab icon is the theme text colour — the pill
    // alone marks the selection, no accent, no red.
    expect(iconColor(0), textPrimary);
    expect(iconColor(1), textPrimary);
    // Mid-slide (tab 0 -> 1) the icons still do not change colour.
    await tester.tapAt(const Offset(154, 32));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 100));
    expect(iconColor(0), textPrimary);
    expect(iconColor(1), textPrimary);
    // Settled on tab 1: still theme text.
    await tester.pumpAndSettle();
    expect(iconColor(1), textPrimary);
    expect(iconColor(0), textPrimary);
  });

  testWidgets('custom accent does not change the tab icons',
      (tester) async {
    const blue = Color(0xFF2563EB);
    await pumpBar(
      tester,
      currentIndex: 0,
      onTap: (_) {},
    );
    final textPrimary =
        HaoThemes.of(HaoThemeId.appleGlass).light.extension<HaoTheme>()!.textPrimary;
    expect(
      tester.widget<Icon>(find.byType(Icon).at(0)).color,
      textPrimary,
    );

    // The accent is still stored and applied app-wide (switches,
    // buttons — see custom_accent_theme_test.dart); the tab bar
    // just no longer reads it (Muse bar: black icons).
    await TabBarAccentController.ensure().setColor(blue);
    await tester.pump();
    expect(TabBarAccentController.ensure().color.value, blue);
    expect(tester.widget<Icon>(find.byType(Icon).at(0)).color, textPrimary);
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
        // The lens is present and every tab icon is the theme text
        // colour (never the accent) in every combination.
        expect(
          find.byKey(GlassTabBarState.pillKey),
          findsOneWidget,
          reason: '$id $mode: pill missing',
        );
        expect(
          tester.widget<Icon>(find.byType(Icon).at(2)).color,
          hao.textPrimary,
          reason: '$id $mode: selected tab icon is not theme text',
        );
        // The resting pill is the theme's matte colour and is
        // visibly distinct from the page background: darker in
        // light mode, lighter in dark mode.
        final painter = tester
                .widget<CustomPaint>(find.byKey(GlassTabBarState.restPillKey))
                .painter as RestPillPainter;
        expect(painter.color, hao.tabPill, reason: '$id $mode: pill colour');
        final pillLum = hao.tabPill.computeLuminance();
        final bgLum = hao.scaffoldBackground.computeLuminance();
        if (mode == Brightness.light) {
          expect(bgLum - pillLum, greaterThan(0.05),
              reason: '$id $mode: pill too faint against the bar');
        } else {
          expect(pillLum - bgLum, greaterThan(0.02),
              reason: '$id $mode: pill too faint against the bar');
        }
        expect(tester.takeException(), isNull);
      }
    }
  });
}
