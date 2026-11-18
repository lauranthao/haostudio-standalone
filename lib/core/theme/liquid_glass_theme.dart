// Mapping between our 4-theme system (HaoTheme) and
// `liquid_glass_widgets` (v1.17.5).
//
// What the library's theme actually controls (GlassThemeData /
// LiquidGlassSettings): glass OPTICS — blur, thickness, chromatic
// aberration, light intensity, saturation, refractive index, glow
// colours, quality tier. It has NO surface-tint knob: the glass
// colour comes from whatever is behind it plus the glow colours.
//
// So the mapping is deliberately thin:
// - Wrap-level theme: library ios27 defaults (`GlassThemeData()`).
//   No global quality override (SKILL.md Rule 5: never set a global
//   standard — premium stays the default for floating chrome and
//   transient overlays; widgets that need a lower tier pass it
//   per-widget). Our 4 themes do NOT define a glass glow colour, so
//   the library's tuned glow defaults stay.
// - Light/dark follows our Material theme through
//   `brightnessResolver: Theme.maybeBrightnessOf` (passed in main);
//   the library resolves `GlassTheme.brightnessOf` from it, so our
//   light/dark/system modes flow through unchanged.
// - Accent mapping happens at the WIDGET level, where the API
//   exposes it (e.g. `GlassSwitch.activeColor: theme.accent`). Our
//   accent is black/grey/gold/teal per theme/mode — never the
//   library's blue.
// - Tab bar optics follow the library demo (`GlassTabBar.bottom`
//   passes no settings, so it renders the ambient ios27 defaults):
//   per-widget `LiquidGlassSettings.ios27(context)` +
//   `useOwnLayer: true` (per-widget settings are ignored in grouped
//   mode without it — GlassContainer docs) + `GlassQuality.premium`,
//   wrapped in a `GlassAdaptiveScope(minQuality: premium)` floor so
//   the adaptive monitor can never demote the chrome to frosted
//   standard/minimal on a busy phone. The rest of the app keeps
//   ios27 defaults.
//
// Our own GlassCard (BackdropFilter + hairline + highlight) stays
// for content rows (chen: search-result rows are glass; SKILL.md
// Rule 1 would make them solid — chen wins) and for surfaces the
// library cannot express in our colours (dialogs: its primary
// action forces a blue glow, destructive forces red).

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

class HaoLiquidGlass {
  HaoLiquidGlass._();

  /// Wrap-level theme: library ios27 defaults.
  static const GlassThemeData themeData = GlassThemeData();

  /// iOS 27 preset for the tab bar shell — the demo's glass, copied
  /// verbatim: the demo's `GlassTabBar.bottom` passes no `settings`,
  /// so it renders the ambient ios27 defaults (`GlassThemeData()`).
  /// Light: glassColor 0x87 (0.53), frostOpacity 0.73, rimShade 1;
  /// dark: glassColor 0x1F (0.12), frostOpacity 0.85, rimLight 1.15,
  /// rimShade 1, bodyShade 0.28. (The old ios26 preset was whiter
  /// and more frosted in light — 0x9E/0.62, frost 0.82, rimShade 0 —
  /// and dimmer-rimmed in dark — rimLight 0.22 — which is why the
  /// bar read as frosted glass instead of clear Apple glass.)
  /// Resolves light/dark from the ambient glass brightness.
  static LiquidGlassSettings ios27Settings(BuildContext context) =>
      LiquidGlassSettings.ios27(context);
}
