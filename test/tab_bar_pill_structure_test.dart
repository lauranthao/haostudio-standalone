// Structural tests — GlassTabBar pill, one copy by construction
// (bug 6 v2, chen 2026-11-20).
//
// Skia goldens CANNOT prove no-doubling (they passed twice while
// chen's phone doubled), so these widget-tree assertions are the
// primary proof that the pill region contains exactly one copy of
// the selected item:
//  1. the icon layer is split into two complementary clips by the
//     pill rect (inverse outside + normal inside, same rect, like
//     the library's own GlassTabBar);
//  2. the lens fades through `settings.visibility`, NEVER through an
//     Opacity wrapper (build 21's Opacity fade made the lens layer
//     semi-transparent, so the direct row bled through next to the
//     refracted copy on every fade);
//  3. the resting pill is the iOS-27 colorBurn painter, not a flat
//     faint fill (build 21's was nearly invisible).
// Asserted at rest, mid-slide, settled and mid-drag, in light and
// dark. Goldens in render_tab_bar_pill_test.dart are only a
// secondary visual check, not the proof.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    hide GlassTabBar;
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
  /// cells -> cellW 92, pill 1.5 cells = 138 wide. Settled pill
  /// left edges (content space, i.e. minus the 16pt outer offset):
  /// 0 / 69 / 161 / 230 for tabs 0..3. Cell centres (global):
  /// 62 / 154 / 246 / 338, bar height 64, centre y = 32.
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

  PillClipper unselectedClip(WidgetTester tester) =>
      tester.widget<ClipPath>(find.byKey(GlassTabBarState.unselectedClipKey))
          .clipper as PillClipper;
  PillClipper selectedClip(WidgetTester tester) =>
      tester.widget<ClipPath>(find.byKey(GlassTabBarState.selectedClipKey))
          .clipper as PillClipper;

  double lensVisibility(WidgetTester tester) =>
      tester
          .widget<GlassContainer>(find.byKey(GlassTabBarState.pillKey))
          .settings
          ?.visibility ??
      -1;

  double restPillOpacity(WidgetTester tester) =>
      tester.widget<Opacity>(
        find.byKey(GlassTabBarState.restPillOpacityKey),
      ).opacity;

  /// The lens's nearest Positioned ancestor (its own Positioned in
  /// the content Stack): its left edge is the pill's left edge.
  double lensLeft(WidgetTester tester) {
    var found = -1.0;
    tester
        .element(find.byKey(GlassTabBarState.pillKey))
        .visitAncestorElements((e) {
      if (e.widget is Positioned) {
        found = (e.widget as Positioned).left ?? -1.0;
        return false;
      }
      return true;
    });
    return found;
  }

  /// No Opacity widget between the lens and the GlassTabBar: the lens
  /// must fade through settings.visibility, never through a composited
  /// semi-transparent layer (that was build 21's doubling).
  void expectNoOpacityOverLens(WidgetTester tester) {
    var found = false;
    tester
        .element(find.byKey(GlassTabBarState.pillKey))
        .visitAncestorElements((e) {
      if (e.widget is GlassTabBar) return false;
      if (e.widget is Opacity) found = true;
      return true;
    });
    expect(found, isFalse,
        reason: 'no Opacity may wrap the lens (visibility fade only)');
  }

  /// The split invariant, at any pill position: the two clips cover
  /// the same pill rect with opposite polarity, and that rect is
  /// exactly the lens rect.
  void expectClipsMatchLens(WidgetTester tester) {
    final un = unselectedClip(tester);
    final sel = selectedClip(tester);
    expect(un.inverse, isTrue);
    expect(sel.inverse, isFalse);
    expect(un.left, sel.left);
    expect(un.right, sel.right);
    expect(lensLeft(tester), closeTo(un.left, 0.5));
    expect(
      tester.getSize(find.byKey(GlassTabBarState.pillKey)).width,
      closeTo(un.right - un.left, 0.5),
    );
    // Each clip paints the icon row exactly once.
    expect(
      find.descendant(
        of: find.byKey(GlassTabBarState.unselectedClipKey),
        matching: find.byType(Row),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(GlassTabBarState.selectedClipKey),
        matching: find.byType(Row),
      ),
      findsOneWidget,
    );
  }

  void expectAtRest(WidgetTester tester) {
    expect(lensVisibility(tester), 0.0);
    expect(restPillOpacity(tester), 1.0);
    expectClipsMatchLens(tester);
    expectNoOpacityOverLens(tester);
  }

  void expectInMotion(WidgetTester tester) {
    expect(lensVisibility(tester), 1.0);
    expect(restPillOpacity(tester), 0.0);
    expectClipsMatchLens(tester);
    expectNoOpacityOverLens(tester);
  }

  testWidgets('clip split at rest, light', (tester) async {
    await pumpBar(tester, currentIndex: 2, onTap: (_) {});
    expectAtRest(tester);
    // 音乐 (index 2): content-space pill 161..299.
    expect(unselectedClip(tester).left, closeTo(161.0, 0.5));
    expect(unselectedClip(tester).right, closeTo(299.0, 0.5));
    // Resting pill is the iOS-27 colorBurn painter, light mode.
    final painter =
        tester.widget<CustomPaint>(find.byKey(GlassTabBarState.restPillKey))
            .painter as RestPillPainter;
    expect(painter.isDark, isFalse);
  });

  testWidgets('clip split at rest, dark', (tester) async {
    await pumpBar(
      tester,
      currentIndex: 2,
      onTap: (_) {},
      theme: HaoThemes.of(HaoThemeId.appleGlass).dark,
    );
    expectAtRest(tester);
    expect(unselectedClip(tester).left, closeTo(161.0, 0.5));
    expect(unselectedClip(tester).right, closeTo(299.0, 0.5));
    final painter =
        tester.widget<CustomPaint>(find.byKey(GlassTabBarState.restPillKey))
            .painter as RestPillPainter;
    expect(painter.isDark, isTrue);
  });

  testWidgets('clip split mid-slide to 设置', (tester) async {
    await pumpLiveBar(tester, start: 2);
    expectAtRest(tester);
    await tester.tapAt(const Offset(338, 32));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 180ms visibility forward done (lens fully up) while the 350ms
    // settle spring is still mid-flight.
    expectInMotion(tester);
    // The pill has left rest (161) towards 设置 (230) and the clips
    // track it exactly.
    expect(lensLeft(tester), inInclusiveRange(161.0, 230.0));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('clip split settled on 设置', (tester) async {
    await pumpLiveBar(tester, start: 2);
    await tester.tapAt(const Offset(338, 32));
    await tester.pumpAndSettle();
    expectAtRest(tester);
    expect(unselectedClip(tester).left, closeTo(230.0, 1.0));
    expect(unselectedClip(tester).right, closeTo(368.0, 1.0));
  });

  testWidgets('clip split mid-drag', (tester) async {
    await pumpLiveBar(tester, start: 2);
    expectAtRest(tester);
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
    // Finger owns the pill: lens up, rest pill out, clips track it.
    expectInMotion(tester);
    expect(lensLeft(tester), inInclusiveRange(161.0, 230.0));
    await gesture.up();
    await tester.pumpAndSettle();
    expectAtRest(tester);
  });

  testWidgets('all four tabs settle with matching clips', (tester) async {
    await pumpLiveBar(tester, start: 2);
    const expectedLeft = [0.0, 69.0, 161.0, 230.0];
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(Offset(62 + 92.0 * i, 32));
      await tester.pumpAndSettle();
      expectAtRest(tester);
      expect(unselectedClip(tester).left, closeTo(expectedLeft[i], 1.0));
      expect(
        unselectedClip(tester).right,
        closeTo(expectedLeft[i] + 138.0, 1.0),
      );
    }
  });
}
