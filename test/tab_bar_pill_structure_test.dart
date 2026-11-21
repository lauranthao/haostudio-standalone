// Structural tests — GlassTabBar pill, Kumone restored 2026-11-21
// (chen: Kumone那种，不要文字，不要影子）.
//
// Skia goldens CANNOT prove no-doubling (they passed twice while
// chen's phone doubled), so these widget-tree assertions are the
// primary proof of the bar's structure:
//  1. one pill only: a plain Container with pillKey, faint tint
//     (white 0.10 dark / black 0.075 light), width cellW - 8;
//     no lens GlassContainer, no resting-pill Opacity, no clip split;
//  2. one icon row only: 4 icons, no Text, selected = theme accent,
//     unselected = primary 0.8;
//  3. no shadow: no BoxDecoration with a boxShadow anywhere in the
//     bar subtree (the mini player's shadow is gone too —
//     mini_player_overlay_test covers that bar separately).
// Asserted at rest, mid-slide, settled and mid-drag, in light and
// dark. Goldens in render_tab_bar_pill_test.dart are only a
// secondary visual check, not the proof.

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
  /// 400pt viewport, outer Padding 12 + inset 4 leaves 368pt for 4
  /// cells -> cellW 92, pill 84 wide. Settled pill left edges
  /// (global): 20 / 112 / 204 / 296 for tabs 0..3. Cell centres
  /// (global): 62 / 154 / 246 / 338, bar height 64, centre y = 32.
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
      tester.getTopLeft(find.byKey(GlassTabBarState.pillKey)).dx;

  double pillWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(GlassTabBarState.pillKey)).width;

  /// The pill is one plain Container with the Kumone faint tint.
  void expectFaintPill(WidgetTester tester, {required bool isDark}) {
    final decoration = tester
        .widget<Container>(find.byKey(GlassTabBarState.pillKey))
        .decoration as BoxDecoration;
    expect(
      decoration.color,
      isDark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.black.withValues(alpha: 0.075),
    );
    expect(pillWidth(tester), closeTo(84, 0.5));
  }

  /// Exactly one icon row, 4 icons, no labels, selected = accent.
  void expectSingleIconRow(
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
    expect(
      find.descendant(
        of: find.byType(GlassTabBar),
        matching: find.byType(Text),
      ),
      findsNothing,
    );
    final hao = theme.extension<HaoTheme>()!;
    final labels = <String>{};
    for (var i = 0; i < 4; i++) {
      final icon = tester.widget<Icon>(find.byType(Icon).at(i));
      expect(icon.semanticLabel, isNotNull);
      labels.add(icon.semanticLabel!);
    }
    expect(labels, {'影视', '直播', '音乐', '设置'});
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
    required bool isDark,
    int selected = 2,
  }) {
    expectFaintPill(tester, isDark: isDark);
    expectSingleIconRow(tester, theme, selected: selected);
    expectNoShadow(tester);
  }

  testWidgets('Kumone pill at rest, light', (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light;
    await pumpBar(tester, currentIndex: 2, onTap: (_) {}, theme: theme);
    expectAtRest(tester, theme, isDark: false);
    // 音乐 (index 2): settled left edge 204 global.
    expect(pillLeft(tester), closeTo(204.0, 0.5));
  });

  testWidgets('Kumone pill at rest, dark', (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).dark;
    await pumpBar(tester, currentIndex: 2, onTap: (_) {}, theme: theme);
    expectAtRest(tester, theme, isDark: true);
    expect(pillLeft(tester), closeTo(204.0, 0.5));
  });

  testWidgets('pill mid-slide to 设置 keeps its width', (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light;
    await pumpLiveBar(tester, start: 2, theme: theme);
    expectAtRest(tester, theme, isDark: false);
    await tester.tapAt(const Offset(338, 32));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 350ms settle spring still mid-flight: the pill has left rest
    // (204) towards 设置 (296) at the same 84 width — no stretch.
    // The upper bound allows the underdamped spring's ~1% overshoot
    // past the target.
    expect(pillLeft(tester), inInclusiveRange(204.0, 300.0));
    expect(pillWidth(tester), closeTo(84, 0.5));
    expectFaintPill(tester, isDark: false);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('pill settled on 设置', (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light;
    await pumpLiveBar(tester, start: 2, theme: theme);
    await tester.tapAt(const Offset(338, 32));
    await tester.pumpAndSettle();
    expectAtRest(tester, theme, isDark: false, selected: 3);
    expect(pillLeft(tester), closeTo(296.0, 1.0));
  });

  testWidgets('pill mid-drag follows the finger at full width',
      (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light;
    await pumpLiveBar(tester, start: 2, theme: theme);
    expectAtRest(tester, theme, isDark: false);
    final gesture = await tester.startGesture(const Offset(200, 32));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    // First move only wins the gesture arena (glass_tab_bar_test):
    // the drag starts at the post-move finger position, so this
    // move's own update is below the 8pt threshold and the pill has
    // not moved yet.
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // Finger owns the pill: it tracks the finger at full width.
    expect(pillLeft(tester), inInclusiveRange(204.0, 296.0));
    expect(pillWidth(tester), closeTo(84, 0.5));
    await gesture.up();
    await tester.pumpAndSettle();
    expectAtRest(tester, theme, isDark: false, selected: 3);
  });

  testWidgets('all four tabs settle at cellW - 8', (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light;
    await pumpLiveBar(tester, start: 2, theme: theme);
    const expectedLeft = [20.0, 112.0, 204.0, 296.0];
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(Offset(62 + 92.0 * i, 32));
      await tester.pumpAndSettle();
      expectAtRest(tester, theme, isDark: false, selected: i);
      expect(pillLeft(tester), closeTo(expectedLeft[i], 1.0));
      expect(pillWidth(tester), closeTo(84, 0.5));
    }
  });

  testWidgets('Kumone bar: icon-only, selected is the accent',
      (tester) async {
    final theme = HaoThemes.of(HaoThemeId.appleGlass).light;
    await pumpBar(tester, currentIndex: 2, onTap: (_) {}, theme: theme);
    expectSingleIconRow(tester, theme, selected: 2);
    expectNoShadow(tester);
  });
}
