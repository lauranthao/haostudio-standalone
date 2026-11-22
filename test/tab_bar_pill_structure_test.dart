// Structural tests — Apple-native tab bar (build-29 adoption, chen
// 2026-11-22: “都要原生效果”). The Kumone bar is void.
//
// Skia goldens CANNOT prove no-doubling (they passed twice while
// chen's phone doubled), so these widget-tree assertions are the
// primary proof of the bar's structure:
//  1. one pill only: a plain Container with pillKey, transparent
//     tint (theme accentSoft), width cellW - 8; no lens
//     GlassContainer, no resting-pill Opacity, no clip split;
//  2. one icon+label row only: 4 icons + 4 visible labels, selected
//     = theme accent, unselected = primary 0.8;
//  3. no shadow: no BoxDecoration with a boxShadow anywhere in the
//     bar subtree (the mini player's shadow is gone too —
//     mini_player_overlay_test covers that bar separately);
//  4. no drag: a finger drag moves neither the pill nor the selection.
// Asserted at rest, mid-slide and settled, in light and dark.
// Goldens in render_tab_bar_pill_test.dart are only a secondary
// visual check, not the proof.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/widgets/app_shell.dart';

void main() {
  setUp(() {
    HaoHaptics.debugEnabledOverride = false;
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  /// Minimal bar-only harness (glass_tab_bar_test.dart geometry):
  /// 400pt viewport, full-width bar, 4 cells -> cellW 100, pill 92
  /// wide. Settled pill left edges (global): 4 / 104 / 204 / 304 for
  /// tabs 0..3. Cell centres (global): 50 / 150 / 250 / 350, bar
  /// height 64, centre y = 32.
  Future<void> pumpBar(
    WidgetTester tester, {
    required int currentIndex,
    required ValueChanged<int> onTap,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        theme: theme ?? HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: GlassTabBar(currentIndex: currentIndex, onTap: onTap),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Pump the bar with a live currentIndex so taps actually move it.
  Future<void> pumpLiveBar(
    WidgetTester tester, {
    int start = 2,
    ThemeData? theme,
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
        theme: theme ?? HaoThemes.of(HaoThemeId.appleGlass).light,
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

  double pillLeft(WidgetTester tester) =>
      tester.getTopLeft(find.byKey(GlassTabBar.pillKey)).dx;

  double pillWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(GlassTabBar.pillKey)).width;

  /// The pill is one plain Container with the transparent accent tint.
  void expectTintPill(WidgetTester tester, ThemeData theme) {
    final hao = theme.extension<HaoTheme>()!;
    final decoration = tester
        .widget<Container>(find.byKey(GlassTabBar.pillKey))
        .decoration as BoxDecoration;
    expect(decoration.color, hao.accentSoft);
    expect(pillWidth(tester), closeTo(92, 0.5));
  }

  /// Exactly one icon+label row, 4 icons, 4 visible labels, selected
  /// = accent.
  void expectIconLabelRow(
    WidgetTester tester,
    ThemeData theme, {
    required int selected,
  }) {
    expect(
      find.descendant(
        of: find.byType(GlassTabBar),
        matching: find.byType(Row),
      ),
      findsOneWidget,
    );
    expect(find.byType(Icon), findsNWidgets(4));
    for (final label in ['影视', '直播', '音乐', '设置']) {
      expect(
        find.descendant(
          of: find.byType(GlassTabBar),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
    final hao = theme.extension<HaoTheme>()!;
    expect(
      tester.widget<Icon>(find.byType(Icon).at(selected)).color,
      hao.accent,
    );
    for (var i = 0; i < 4; i++) {
      if (i == selected) continue;
      expect(
        tester.widget<Icon>(find.byType(Icon).at(i)).color,
        hao.textPrimary.withValues(alpha: 0.8),
      );
    }
  }

  /// No shadow anywhere in the bar subtree: no Container /
  /// DecoratedBox carries a BoxDecoration with a boxShadow.
  void expectNoShadow(WidgetTester tester) {
    var found = false;
    for (final e in find
        .descendant(
          of: find.byType(GlassTabBar),
          matching: find.byType(Container),
        )
        .evaluate()) {
      final d = (e.widget as Container).decoration;
      if (d is BoxDecoration && d.boxShadow != null && d.boxShadow!.isNotEmpty) {
        found = true;
      }
    }
    for (final e in find
        .descendant(
          of: find.byType(GlassTabBar),
          matching: find.byType(DecoratedBox),
        )
        .evaluate()) {
      final d = (e.widget as DecoratedBox).decoration;
      if (d is BoxDecoration && d.boxShadow != null && d.boxShadow!.isNotEmpty) {
        found = true;
      }
    }
    expect(found, isFalse, reason: 'the bar must cast no shadow');
  }

  void expectAtRest(
    WidgetTester tester,
    ThemeData theme, {
    int selected = 2,
  }) {
    expectTintPill(tester, theme);
    expectIconLabelRow(tester, theme, selected: selected);
    expectNoShadow(tester);
  }

  testWidgets('native pill at rest, light', (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light;
    await pumpBar(tester, currentIndex: 2, onTap: (_) {}, theme: theme);
    expectAtRest(tester, theme);
    // 音乐 (index 2): settled left edge 204 global.
    expect(pillLeft(tester), closeTo(204.0, 0.5));
  });

  testWidgets('native pill at rest, dark', (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).dark;
    await pumpBar(tester, currentIndex: 2, onTap: (_) {}, theme: theme);
    expectAtRest(tester, theme);
    expect(pillLeft(tester), closeTo(204.0, 0.5));
  });

  testWidgets('pill mid-slide to 设置 keeps its width', (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light;
    await pumpLiveBar(tester, start: 2, theme: theme);
    expectAtRest(tester, theme);
    await tester.tapAt(const Offset(350, 32));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 600ms bouncy slide still mid-flight: the pill has left rest
    // (204) towards 设置 (304) at the same 92 width — no stretch.
    // The upper bound allows the elastic curve's small overshoot
    // past the target.
    expect(pillLeft(tester), inInclusiveRange(204.0, 308.0));
    expect(pillWidth(tester), closeTo(92, 0.5));
    expectTintPill(tester, theme);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('pill settled on 设置', (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light;
    await pumpLiveBar(tester, start: 2, theme: theme);
    await tester.tapAt(const Offset(350, 32));
    await tester.pumpAndSettle();
    expectAtRest(tester, theme, selected: 3);
    expect(pillLeft(tester), closeTo(304.0, 1.0));
  });

  testWidgets('drag moves neither the pill nor the selection',
      (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light;
    await pumpLiveBar(tester, start: 2, theme: theme);
    expectAtRest(tester, theme);
    // Kumone drag is void: a drag across a cell boundary switches
    // nothing and the pill stays put.
    final gesture = await tester.startGesture(const Offset(250, 32));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(pillLeft(tester), closeTo(204.0, 0.5));
    expectAtRest(tester, theme);
  });

  testWidgets('all four tabs settle at cellW - 8', (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light;
    await pumpLiveBar(tester, start: 2, theme: theme);
    const expectedLeft = [4.0, 104.0, 204.0, 304.0];
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(Offset(50 + 100.0 * i, 32));
      await tester.pumpAndSettle();
      expectAtRest(tester, theme, selected: i);
      expect(pillLeft(tester), closeTo(expectedLeft[i], 1.0));
      expect(pillWidth(tester), closeTo(92, 0.5));
    }
  });

  testWidgets('native bar: labels visible, selected is the accent',
      (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light;
    await pumpBar(tester, currentIndex: 2, onTap: (_) {}, theme: theme);
    expectIconLabelRow(tester, theme, selected: 2);
    expectNoShadow(tester);
  });
}
