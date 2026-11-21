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
//   library's blue — unless the user picked a custom accent
//   (ThemeController), which replaces it app-wide.
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
// Our own GlassCard stays the single card widget, now with a quality
// parameter (Phase B): frosted (default, the old BackdropFilter +
// hairline + highlight) for content rows (chen: search-result rows
// are glass; SKILL.md Rule 1 would make them solid — chen wins),
// standard/premium library glass for content cards, floating panels
// and dialog shells. The dialog note below concerns the library's
// GlassDialog widget (its primary action forces a blue glow,
// destructive forces red) — a GlassContainer SHELL for our own
// dialog content is fine, because the caller's buttons carry the
// theme colours, not the library's actions.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'hao_themes.dart';

class HaoLiquidGlass {
  HaoLiquidGlass._();

  /// Wrap-level theme: library ios27 defaults.
  static const GlassThemeData themeData = GlassThemeData();

  /// Scale the library optics by the user's glass intensity
  /// (chen 2026-11-21, Settings → 外观）: 1.0 is identity (today's
  /// glass, byte for byte), 0.0 fades thickness / blur / frost /
  /// tint / rim to nothing. Only the optics move — never the layout.
  /// Thickness floors at 1.0 so the refraction pass never sees a
  /// zero depth. The optical leftovers scale too (G-P2-6): at 0 the
  /// refractive index eases to 1.0 (no bending) and glow / light /
  /// chromatic aberration fade to zero — and `visibility` scales with
  /// the intensity as well, because the library still paints a faint
  /// body wash at 0 with visibility left at 1.0 (measured: 5.0% of
  /// pixels differ from the bare backdrop without it, ~0.2% — text
  /// antialiasing only — with it). So 0% glass is optically clear,
  /// not just visually faint.
  static LiquidGlassSettings _scale(
    LiquidGlassSettings base,
    double intensity,
  ) {
    final i = intensity.clamp(0.0, 1.0);
    if (i >= 1.0) return base;
    return base.copyWith(
      thickness: math.max(1.0, base.thickness * i),
      blur: base.blur * i,
      frost: base.frost * i,
      frostOpacity: base.frostOpacity * i,
      glassColor: base.glassColor.withValues(alpha: base.glassColor.a * i),
      rimLight: base.rimLight * i,
      rimShade: base.rimShade * i,
      refractiveIndex: 1.0 + (base.refractiveIndex - 1.0) * i,
      glowIntensity: base.glowIntensity * i,
      lightIntensity: base.lightIntensity * i,
      chromaticAberration: base.chromaticAberration * i,
      visibility: base.visibility * i,
    );
  }

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
  /// Scaled by the user's glass intensity (see [_scale]).
  /// No [HaoTheme] extension in the ambient theme (plain
  /// ThemeData, e.g. a test harness) reads as intensity 1.0 —
  /// today's glass — instead of crashing on the null extension.
  static LiquidGlassSettings ios27Settings(BuildContext context) => _scale(
    LiquidGlassSettings.ios27(context),
    Theme.of(context).extension<HaoTheme>()?.glassIntensity ?? 1.0,
  );

  /// Floating-chrome glass (tab bar shell + mini player bar) for the
  /// unified page (chen 2026-11-19: "不要有那种分开的感觉，就是一个
  /// 页面连在一起的" — NetEase 漫游页参考：整页同一底色，顶栏 /
  /// mini 播放器 / 底栏都是同色胶囊）.
  ///
  /// The ios27 preset's own tint (light glassColor 0x87F8F8F8 ≈ 53%
  /// near-white + frostOpacity 0.73) washes the chrome toward white
  /// whatever the page behind it is — over the theme scaffold colour
  /// it reads as a separate light slab, over a wallpaper as a milky
  /// slab breaking the photo. This preset keeps the ios27 optics
  /// (thickness 32, frost 14, paraxial lens, rim) and only re-tints:
  /// - glassColor = the page's own background (theme scaffold
  ///   colour) at 0.12 — on a solid page the bar IS the page colour
  ///   (the backdrop behind it is the same colour, so any alpha
  ///   blends); over a wallpaper it is only a 12% wash, so the photo
  ///   reads through continuously;
  /// - frostOpacity 0.55 (from 0.73/0.85, raised from 0.40 in the
  ///   bug-4 fix) — the frost cloud is thinner than the ios27 slab
  ///   but thick enough that content scrolling under the bar visibly
  ///   diffuses instead of showing through sharp: that diffusion IS
  ///   the glass cue. 0.40 (the §4 value) left the bar reading as a
  ///   flat strip — chen 2026-11-20: "菜单的那个玻璃也没有了".
  ///   Over a perfectly uniform backdrop frost changes nothing (the
  ///   pill lens is the cue there: it magnifies the icons); over
  ///   real content the 0.55 frost is what makes the bar read glass.
  /// - saturation 1.0 (from 2.1/1.4) — the backdrop inside the bar
  ///   must not be more saturated than the page around it;
  /// - bodyShade 0 (dark was 0.28) — no extra darkening of the body,
  ///   or the dark-mode bar would read darker than its page.
  /// Theme-only (no appearance state): the same settings blend on a
  /// solid page and stay transparent over a wallpaper, so no reactive
  /// rebuild is needed when the wallpaper toggles. The pill does NOT
  /// inherit this preset any more: it is a plain matte Container
  /// (see app_shell.dart), not a glass layer — no lens/magnification
  /// is wired in. Wiring a lens would change the tab-bar look, so it
  /// waits on chen's phone verdict (G-P1-4, build 27: the old pill
  /// lens settings definition was dead code with zero callers and
  /// was deleted; its "verified in the zz_pill_experiment goldens"
  /// note described an experiment, not the shipped bar).
  static LiquidGlassSettings chromeSettings(BuildContext context) {
    final base = LiquidGlassSettings.ios27(context);
    // G-P2-4: same nullable read as ios27Settings — no HaoTheme
    // extension in the ambient theme (plain ThemeData, e.g. a test
    // harness) reads as intensity 1.0 — today's chrome — instead of
    // crashing on the `!` in HaoTheme.of. The page colour falls back
    // to the Material scaffold colour in that case.
    final theme = Theme.of(context).extension<HaoTheme>();
    final page =
        theme?.scaffoldBackground ??
        Theme.of(context).scaffoldBackgroundColor;
    // Glass intensity (chen 2026-11-21): 1.0 is identity — the values
    // below are today's chrome; lower values fade the frost / tint /
    // rim / thickness toward clear glass.
    final intensity = (theme?.glassIntensity ?? 1.0).clamp(0.0, 1.0);
    return base.copyWith(
      glassColor: page.withValues(alpha: 0.12 * intensity),
      frostOpacity: 0.55 * intensity,
      saturation: 1.0,
      rimLight: 1.5 * intensity,
      thickness: math.max(1.0, base.thickness * intensity),
      bodyShade: 0.0,
      // G-P2-6, same as _scale: at 0 the chrome must be optically
      // clear too — refractive index to 1.0, glow / light /
      // chromatic aberration to zero, visibility to zero (the
      // library paints a body wash at 0 with visibility left at
      // 1.0). All five are identity at 1.0, so today's chrome is
      // untouched.
      refractiveIndex: 1.0 + (base.refractiveIndex - 1.0) * intensity,
      glowIntensity: base.glowIntensity * intensity,
      lightIntensity: base.lightIntensity * intensity,
      chromaticAberration: base.chromaticAberration * intensity,
      visibility: base.visibility * intensity,
      // chen 2026-11-21: 不要有影子了 — the ios27 preset carries an
      // explicit light-mode drop shadow (0x0F000000, r12, y6) in its
      // `shadow` list, which IGNORES shadowElevation (the library's
      // effectiveShadow returns the list verbatim when non-null).
      // An empty list is the only way to turn it off; the 0
      // elevation covers the built-in fallback as well. Flat glass,
      // no shadow (tab bar + mini player are the only callers).
      shadow: const [],
      shadowElevation: 0,
    );
  }
}
