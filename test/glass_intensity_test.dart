// build 27 general group — glass intensity (G-P1-3, G-P2-4, G-P2-6).
//
// - G-P1-3: the frosted GlassCard's border + shadow scale with the
//   intensity (0% = transparent border, no shadow), not just the
//   blur / fill / highlight.
// - G-P2-6: _scale also fades the optics at 0 — refractiveIndex to
//   1.0 (no bending), glow / light / chromatic aberration to 0.
// - G-P2-4: chromeSettings / ios27Settings / GlassCard /
//   GlassSheetBackground render under a bare ThemeData (no HaoTheme
//   extension) instead of throwing on HaoTheme.of.
//
// Goldens (run with --update-goldens to regenerate):
// - glass_card_intensity_0/1.png: frosted card over a coloured
//   backdrop; 0% must show no border and no shadow.
// - glass_container_intensity_0/1.png: library glass over the same
//   backdrop; 0% must read as the bare backdrop.
// - glass_no_glass_baseline.png: the backdrop with no glass at all,
//   for eyeballing the 0% frames against.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    hide GlassCard, GlassShadow;
import 'package:standalone/core/theme/glass.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/liquid_glass_theme.dart';

const _backdrop = BoxDecoration(
  gradient: LinearGradient(
    colors: [Color(0xFF3A7BD5), Color(0xFF00D2FF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
);

ThemeData _themeWithIntensity(double intensity) =>
    HaoThemes.of(HaoThemeId.appleGlass, glassIntensity: intensity).light;

Future<void> _pumpCard(WidgetTester tester, double intensity) async {
  // Explicit view like the repo's render tests: without it the
  // BackdropFilter subtree does not rasterise into the golden.
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    GetMaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _themeWithIntensity(intensity),
      home: Scaffold(
        body: Container(
          decoration: _backdrop,
          child: const Center(
            child: GlassCard(
              radius: 20,
              child: SizedBox(
                width: 200,
                height: 120,
                child: Center(child: Text('glass')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The glass fill Container: the one whose BoxDecoration carries a
/// border (the outer shadow box has no border).
BoxDecoration _glassDeco(WidgetTester tester) {
  final found = find.descendant(
    of: find.byType(GlassCard),
    matching: find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).border != null,
    ),
  );
  expect(found, findsOneWidget);
  return tester.widget<Container>(found).decoration as BoxDecoration;
}

/// The outer shadow Container: the one whose BoxDecoration carries a
/// boxShadow (the glass fill has none).
BoxDecoration _shadowDeco(WidgetTester tester) {
  final found = find.descendant(
    of: find.byType(GlassCard),
    matching: find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).boxShadow != null,
    ),
  );
  expect(found, findsOneWidget);
  return tester.widget<Container>(found).decoration as BoxDecoration;
}

Future<LiquidGlassSettings> _settingsAt(
  WidgetTester tester,
  double intensity,
  LiquidGlassSettings Function(BuildContext) read,
) async {
  LiquidGlassSettings? out;
  await tester.pumpWidget(
    MaterialApp(
      theme: _themeWithIntensity(intensity),
      home: Builder(
        builder: (context) {
          out = read(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return out!;
}

Future<void> _pumpContainer(WidgetTester tester, double intensity) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    LiquidGlassWidgets.wrap(
      brightnessResolver: Theme.maybeBrightnessOf,
      child: GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _themeWithIntensity(intensity),
        home: Scaffold(
          body: Container(
            decoration: _backdrop,
            child: Center(
              child: Builder(
                builder: (context) => GlassContainer(
                  shape: const LiquidRoundedSuperellipse(borderRadius: 20),
                  settings: HaoLiquidGlass.ios27Settings(context),
                  useOwnLayer: true,
                  quality: GlassQuality.standard,
                  child: const SizedBox(
                    width: 200,
                    height: 120,
                    child: Center(child: Text('glass')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('G-P1-3 frosted border + shadow scale with intensity', () {
    testWidgets('intensity 0: transparent border, no shadow, no fill', (
      tester,
    ) async {
      await _pumpCard(tester, 0.0);
      final theme = HaoTheme.of(tester.element(find.text('glass')));
      final glass = _glassDeco(tester);
      final shadow = _shadowDeco(tester);
      expect(glass.color!.a, 0.0);
      expect((glass.border as Border).top.color.a, 0.0);
      expect(shadow.boxShadow!.single.color.a, 0.0);
      expect(theme.glassIntensity, 0.0);
    });

    testWidgets('intensity 1: hairline border, Beans shadow, full fill', (
      tester,
    ) async {
      await _pumpCard(tester, 1.0);
      final theme = HaoTheme.of(tester.element(find.text('glass')));
      final glass = _glassDeco(tester);
      final shadow = _shadowDeco(tester);
      expect(glass.color, theme.surface);
      expect((glass.border as Border).top.color, theme.hairline);
      // Light-mode Beans card shadow: black 0.08.
      expect(shadow.boxShadow!.single.color.a, closeTo(0.08, 0.001));
      expect(shadow.boxShadow!.single.blurRadius, 9);
    });

    // One scene per testWidgets: pumping a 0% glass and then a 1% glass
    // in the same test leaves the golden rasterisation stuck on the
    // 0% frame (the library's Opacity/BackdropFilter layers do not
    // re-rasterise across pumpWidget replacements in the capture
    // path). Fresh trees render correctly (see the scratch runs).
    testWidgets('golden: intensity 0', (tester) async {
      // Whole app, like the repo's render tests: capturing from the
      // Scaffold down loses the BackdropFilter's backdrop in the
      // golden rasterisation, so the frosted card paints nothing.
      await _pumpCard(tester, 0.0);
      await expectLater(
        find.byType(GetMaterialApp),
        matchesGoldenFile('goldens/glass_card_intensity_0.png'),
      );
    });

    testWidgets('golden: intensity 1', (tester) async {
      await _pumpCard(tester, 1.0);
      await expectLater(
        find.byType(GetMaterialApp),
        matchesGoldenFile('goldens/glass_card_intensity_1.png'),
      );
    });
  });

  group('G-P2-6 _scale fades the optics at intensity 0', () {
    testWidgets('ios27Settings at 0: no refraction, glow, light or dispersion', (
      tester,
    ) async {
      final atZero = await _settingsAt(
        tester,
        0.0,
        HaoLiquidGlass.ios27Settings,
      );
      expect(atZero.refractiveIndex, 1.0);
      expect(atZero.glowIntensity, 0.0);
      expect(atZero.lightIntensity, 0.0);
      expect(atZero.chromaticAberration, 0.0);
      // b28 — visibility stays 1.0 at 0%: the library wraps the
      // GlassContainer CHILD in Opacity(visibility)
      // (liquid_glass.dart:216), so scaling it to 0 hid the child
      // (tab bar icons, card titles) along with the glass — the
      // 0% legibility bug's third root cause. The body wash is
      // killed by zeroing the optics instead: saturation back to
      // 1.0 (ios27 light is 2.1), bodyShade to 0 (ios27 dark 0.28),
      // the preset shadow alphas to 0, edge absorption to 0.
      expect(atZero.visibility, 1.0);
      expect(atZero.thickness, 1.0);
      expect(atZero.blur, 0.0);
      expect(atZero.frostOpacity, 0.0);
      expect(atZero.glassColor.a, 0.0);
      expect(atZero.rimLight, 0.0);
      expect(atZero.rimShade, 0.0);
      expect(atZero.saturation, 1.0);
      expect(atZero.bodyShade, 0.0);
      expect(atZero.edgeAbsorption, 0.0);
      expect(atZero.shadow!.single.color.a, 0.0);
      // b28: at exactly 0% the body compositing is clear mode, or
      // the adaptive body lift leaves a bright wash over the card
      // (~12% white, 4.7% of pixels differ from the bare backdrop).
      expect(atZero.bodyMode, GlassBodyMode.clear);
    });

    testWidgets('ios27Settings at 1 is the untouched ios27 preset', (
      tester,
    ) async {
      final atOne = await _settingsAt(
        tester,
        1.0,
        HaoLiquidGlass.ios27Settings,
      );
      expect(atOne, LiquidGlassSettings.ios27Light);
    });

    testWidgets('chromeSettings at 0 fades tint/frost/rim to nothing', (
      tester,
    ) async {
      final atZero = await _settingsAt(
        tester,
        0.0,
        HaoLiquidGlass.chromeSettings,
      );
      expect(atZero.glassColor.a, 0.0);
      expect(atZero.frostOpacity, 0.0);
      expect(atZero.rimLight, 0.0);
      expect(atZero.thickness, 1.0);
      // Same optical leftovers as _scale (G-P2-6 sibling).
      expect(atZero.refractiveIndex, 1.0);
      expect(atZero.glowIntensity, 0.0);
      expect(atZero.lightIntensity, 0.0);
      expect(atZero.chromaticAberration, 0.0);
      // b28 (see the ios27 test above): visibility stays 1.0 — the
      // child must stay opaque at 0%. The chrome's own wash fields
      // are already neutral (saturation 1.0, bodyShade 0, shadow
      // []); the fields the audit found unscaled here (blur, frost,
      // rimShade) are scaled now, or the bar would keep a blur /
      // frost cloud and a rim outline at 0%.
      expect(atZero.visibility, 1.0);
      expect(atZero.blur, 0.0);
      expect(atZero.frost, 0.0);
      expect(atZero.rimShade, 0.0);
      expect(atZero.edgeAbsorption, 0.0);
      expect(atZero.saturation, 1.0);
      expect(atZero.bodyShade, 0.0);
      expect(atZero.shadow, isEmpty);
      expect(atZero.bodyMode, GlassBodyMode.clear);
    });

    testWidgets("chromeSettings at 1 is today's chrome, unchanged", (
      tester,
    ) async {
      final atOne = await _settingsAt(
        tester,
        1.0,
        HaoLiquidGlass.chromeSettings,
      );
      expect(atOne.glassColor.a, closeTo(0.12, 0.001));
      expect(atOne.frostOpacity, closeTo(0.55, 0.001));
      expect(atOne.refractiveIndex, closeTo(1.24, 0.001));
      expect(atOne.visibility, 1.0);
    });

    // One scene per testWidgets: a 0% -> 1% glass transition inside one
    // test leaves the golden rasterisation stuck on the 0% frame (see
    // the card golden note above). Fresh trees render correctly.
    //
    // b28 — warm-up: the very first GlassContainer render in a
    // process still paints the adaptive body wash even in clear
    // bodyMode (measured: first test wash 4.7%, second test clean
    // 0.14%, same settings), and the same first-frame artifact
    // shifts the 100% render too (reordering 1-before-0 changed
    // glass_container_intensity_1.png by 4.7% vs HEAD). So a
    // throwaway library render runs first, with no golden of its
    // own; the goldens below are all warmed renders. On device the
    // shader is warm long before the user can reach 0%, so this
    // only matters to golden order, not to the shipped look.
    testWidgets('warm-up: first library glass render (no golden)', (
      tester,
    ) async {
      await _pumpContainer(tester, 1.0);
      expect(find.text('glass'), findsOneWidget);
    });

    testWidgets('golden: GlassContainer intensity 0', (tester) async {
      await _pumpContainer(tester, 0.0);
      await expectLater(
        find.byType(GetMaterialApp),
        matchesGoldenFile('goldens/glass_container_intensity_0.png'),
      );
    });

    testWidgets('golden: GlassContainer intensity 1', (tester) async {
      await _pumpContainer(tester, 1.0);
      await expectLater(
        find.byType(GetMaterialApp),
        matchesGoldenFile('goldens/glass_container_intensity_1.png'),
      );
    });

    testWidgets('golden: bare baseline', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        GetMaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _themeWithIntensity(1.0),
          home: Scaffold(
            body: Container(
              decoration: _backdrop,
              child: const Center(
                child: SizedBox(
                  width: 200,
                  height: 120,
                  child: Center(child: Text('glass')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await expectLater(
        find.byType(GetMaterialApp),
        matchesGoldenFile('goldens/glass_no_glass_baseline.png'),
      );
    });
  });

  group('G-P2-4 bare ThemeData (no HaoTheme extension) does not throw', () {
    testWidgets('chrome/ios27 settings read as intensity 1.0', (
      tester,
    ) async {
      LiquidGlassSettings? chrome;
      LiquidGlassSettings? ios27;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Builder(
            builder: (context) {
              chrome = HaoLiquidGlass.chromeSettings(context);
              ios27 = HaoLiquidGlass.ios27Settings(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(ios27, LiquidGlassSettings.ios27Light);
      // Intensity 1.0 default: today's chrome tint (page colour at
      // 0.12) and frost 0.55.
      expect(chrome!.glassColor.a, closeTo(0.12, 0.001));
      expect(chrome!.frostOpacity, closeTo(0.55, 0.001));
    });

    testWidgets('frosted card + sheet background + library glass render', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Scaffold(
            body: Column(
              children: [
                const GlassCard(
                  radius: 20,
                  child: SizedBox(
                    width: 200,
                    height: 60,
                    child: Text('card'),
                  ),
                ),
                GlassSheetBackground(
                  child: Container(
                    height: 60,
                    alignment: Alignment.center,
                    child: const Text('sheet'),
                  ),
                ),
                Builder(
                  builder: (context) => GlassContainer(
                    shape: const LiquidRoundedSuperellipse(borderRadius: 20),
                    settings: HaoLiquidGlass.chromeSettings(context),
                    useOwnLayer: true,
                    quality: GlassQuality.standard,
                    child: const SizedBox(
                      width: 200,
                      height: 60,
                      child: Center(child: Text('chrome')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('card'), findsOneWidget);
      expect(find.text('sheet'), findsOneWidget);
      expect(find.text('chrome'), findsOneWidget);
    });
  });
}
