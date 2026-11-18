// liquid_glass_widgets mapping contract (see
// lib/core/theme/liquid_glass_theme.dart).
//
// - Wrap-level theme is ios27 defaults with NO global quality
//   override (SKILL.md Rule 5: never set a global standard —
//   premium stays the default for floating chrome).
// - The tab bar uses the demo's glass verbatim (ios27 preset,
//   resolved from the ambient brightness: light -> ios27Light,
//   dark -> ios27Dark).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:standalone/core/theme/liquid_glass_theme.dart';

void main() {
  test('wrap theme is ios27 defaults with no global quality override', () {
    expect(HaoLiquidGlass.themeData.style, GlassStyle.ios27);
    expect(HaoLiquidGlass.themeData.light.quality, isNull);
    expect(HaoLiquidGlass.themeData.dark.quality, isNull);
  });

  testWidgets('ios27Settings resolves ios27Light for a light ambient theme', (
    tester,
  ) async {
    LiquidGlassSettings? light;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            light = HaoLiquidGlass.ios27Settings(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(light, LiquidGlassSettings.ios27Light);
  });

  testWidgets('ios27Settings resolves ios27Dark for a dark ambient theme', (
    tester,
  ) async {
    // The dark case must go through the production path:
    // LiquidGlassWidgets.wrap with brightnessResolver, because without
    // wrap the library's cascade falls back to the OS brightness
    // (light in tests) and ignores the Material ThemeMode.
    // Kept in its own testWidgets so the mount is fresh: switching an
    // already-mounted MaterialApp from light to dark goes through
    // AnimatedTheme's 200ms tween, so the first frame after the
    // switch still reads the old (light) theme.
    LiquidGlassSettings? dark;
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        brightnessResolver: Theme.maybeBrightnessOf,
        child: MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: ThemeMode.dark,
          home: Builder(
            builder: (context) {
              dark = HaoLiquidGlass.ios27Settings(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(dark, LiquidGlassSettings.ios27Dark);
  });
}
