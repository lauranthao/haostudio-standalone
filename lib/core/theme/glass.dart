// Shared liquid-glass containers (Beans-Music glass system, ported to
// the HAo Studio theme system — chen 2026-11-17: Beans' whole-app
// liquid glass is the look he wants).
//
// Beans' recipe (Beans/Components.swift `BeansGlass` / `GlassCard`,
// Beans/Theme.swift `BeansCardShadowModifier`):
// - fill: ultra-thin material (low-alpha surface) + strong backdrop blur
// - border: white gradient 0.45 (top) -> 0.08 (bottom) — a 1pt hairline
//   in practice, brightest at the top edge
// - top highlight: white 0.25 gradient over the top of the card
// - shadow: light mode black 0.08 / dark mode black 0.35, radius 9 y 3
//   for cards, radius 14 y 8 for floating panels
// - radii (HaoRadius, 定稿): badge 4, small 6, standard 8, large 12,
//   panel 20, sheet 24 — see lib/core/theme/hao_radius.dart. Beans'
//   own recipe numbers (cards 24, rows 16, mini player 18, floating
//   panels 22) are NOT used; the defaults below are the HaoRadius
//   values (GlassCard radius = panel 20).
//
// Mapping onto our themes (no Beans colour is copied — every value
// below is derived from the active [HaoTheme], so all 4 themes x
// light/dark keep working):
// - fill: theme.surface (already low-alpha in all 8 combinations)
// - border: theme.hairline (per-theme tinted, same role as Beans'
//   white gradient border — a single-colour hairline is what Flutter
//   borders support; the top highlight below carries the gradient)
// - top highlight: white gradient, stronger in dark (surface is dark
//   there) than in light (surface is already near-white)
// - shadow: black, alpha 0.08 light / 0.35 dark (Beans' values)
// - blur: theme.glassBlurSigma (24 everywhere — higher transparency
//   stays readable via blur, never by darkening, per standing rule)
//
// Use [GlassCard] for cards, sheets, panels and floating bars instead
// of hand-rolling BackdropFilter + Container at each call site, so the
// glass stays consistent when the theme changes. [GlassPressScale]
// is Beans' press feedback (GlassPressButtonStyle: scale 0.94-0.97,
// spring 0.24s) for tappable glass children.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'hao_radius.dart';
import 'hao_themes.dart';
import 'liquid_glass_theme.dart';

/// Shadow for a glass card (Beans `beansCardShadow` defaults).
List<BoxShadow> glassCardShadow(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
      blurRadius: 9,
      offset: const Offset(0, 3),
    ),
  ];
}

/// Shadow for a floating glass panel (Beans more-actions panel,
/// mini player: radius 14, y 8).
List<BoxShadow> glassPanelShadow(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.16),
      blurRadius: 14,
      offset: const Offset(0, 8),
    ),
  ];
}

/// Shadow for the floating tab bar (Kumone `GlassTabBar.swift`:
/// shadow black 0.10 light / 0.28 dark, radius 12, y 4).
List<BoxShadow> glassTabBarShadow(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.10),
      blurRadius: 12,
      offset: const Offset(0, 4),
    ),
  ];
}

/// Shadow for the mini player capsule (Kumone `IOSMiniPlayerBar`,
/// IOSMainWindow.swift `playerBarSurface`: shadow black 0.12, radius 10,
/// y 4 — legacyOverlay branch. Was Beans' 0.16 / r12 / y6.)
List<BoxShadow> glassMiniPlayerShadow(BuildContext context) {
  return const [
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, 0.12),
      blurRadius: 10,
      offset: Offset(0, 4),
    ),
  ];
}

/// Small shadow for the search field (Beans `SearchView.searchField`:
/// beansCardShadow(radius: 4, y: 2) — same black 0.08 light / 0.35
/// dark alphas as the card shadow, smaller radius/offset).
List<BoxShadow> glassSmallShadow(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
      blurRadius: 4,
      offset: const Offset(0, 2),
    ),
  ];
}

/// Which glass a [GlassCard] renders with (Phase B, 2026-11-19).
///
/// - [frosted] (default): the hand-rolled look — BackdropFilter blur +
///   theme surface + hairline + top sheen. Byte-identical to the old
///   GlassCard, so dense list rows and inputs keep exactly their
///   current look (and chen's "search-result rows are glass" stays).
/// - [standard]: the library's lightweight single-pass shader
///   (`GlassQuality.standard`, ios27 preset) — real liquid glass
///   built for scrollable lists (library docs: 5-10x faster than
///   BackdropFilter). Content cards, grouped section cards, scrolled
///   controls.
/// - [premium]: the library's full multi-pass shader
///   (`GlassQuality.premium`, ios27 preset) with the
///   `GlassAdaptiveScope(minQuality: premium)` floor, same as the tab
///   bar / mini player. Floating panels, dialogs, sheet roots and
///   single focal controls in STATIC (non-scrollable) layouts only —
///   the library warns premium "may not render correctly in
///   scrollable contexts".
///
/// The library branches draw their rim from the ios27 settings, so
/// they take no [GlassCard.borderColor]: passing one with
/// [standard]/[premium] is a debug assert. The shadow is the same
/// Beans shadow on every branch (the library paints no shadow, so
/// the outer Container keeps it — same pattern as the mini player).
///
/// A [GlassCard.tint] wash (FM / heartbeat cards, 2026-11-19) is
/// painted as the child background inside the library branches only
/// — the frosted branch owns its own surface, so tint + frosted is
/// a debug assert. The tint is a caller-built gradient (per-mode
/// alphas live at the call site, next to the colours they tint).
enum GlassCardQuality { frosted, standard, premium }

/// A liquid-glass container: backdrop blur + low-alpha theme surface +
/// hairline border + top highlight + soft shadow.
///
/// The child is laid out with [padding] inside the glass. Set [radius]
/// per Beans' scale (cards 24, rows 16, floating panels 22); [shadow]
/// picks the card or panel shadow. The glass is transparent by design
/// — over a flat scaffold background it reads as a tinted card; over
/// varied content (cover art, lists) the blur shows.
///
/// [quality] selects the rendering (see [GlassCardQuality]). Default
/// is [GlassCardQuality.frosted] — the old look, unchanged.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.radius = HaoRadius.panel,
    this.padding = const EdgeInsets.all(16),
    this.shadow = GlassShadow.card,
    this.margin,
    this.borderColor,
    this.quality = GlassCardQuality.frosted,
    this.tint,
  }) : assert(
         borderColor == null || quality == GlassCardQuality.frosted,
         'borderColor is only supported by the frosted branch — the '
         'library branches draw their rim from the ios27 settings',
       ),
       assert(
         tint == null || quality != GlassCardQuality.frosted,
         'tint is only supported by the library branches — the '
         'frosted branch paints its own theme surface',
       );

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final GlassShadow shadow;
  final EdgeInsetsGeometry? margin;

  /// Border colour override. Null = theme.hairline (the default for
  /// every card). The floating tab bar used to pass Kumone's
  /// white-based stroke (white 0.22 light / 0.08 dark,
  /// GlassTabBar.swift) here; the bar now draws that stroke as an
  /// overlay above the library glass instead.
  ///
  /// Frosted only: the library branches ignore it (see
  /// [GlassCardQuality] — debug assert if combined with them).
  final Color? borderColor;

  /// Which glass this card renders with. Default frosted (old look).
  final GlassCardQuality quality;

  /// Tint wash painted as the child background inside the library
  /// branches (standard / premium only — see the assert above).
  /// The gradient is the caller's: e.g. the FM / heartbeat cards
  /// wash their own gradient colour at low alpha so the card reads
  /// as coloured glass instead of a flat fill. Library branches
  /// only — never a second glass implementation.
  final LinearGradient? tint;

  /// The Beans shadow for [shadow] (glass.dart header: card r9 y3,
  /// panel r14 y8, tab bar r12 y4, mini player r10 y4, small r4 y2;
  /// black 0.08 light / 0.35 dark, panel 0.16 light).
  List<BoxShadow>? _shadowFor(BuildContext context) {
    switch (shadow) {
      case GlassShadow.none:
        return null;
      case GlassShadow.card:
        return glassCardShadow(context);
      case GlassShadow.panel:
        return glassPanelShadow(context);
      case GlassShadow.tabBar:
        return glassTabBarShadow(context);
      case GlassShadow.miniPlayer:
        return glassMiniPlayerShadow(context);
      case GlassShadow.small:
        return glassSmallShadow(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (quality) {
      case GlassCardQuality.frosted:
        return _buildFrosted(context);
      case GlassCardQuality.standard:
        return _buildLibrary(context, GlassQuality.standard);
      case GlassCardQuality.premium:
        // Same floor as the tab bar / mini player: the adaptive
        // monitor can never demote this panel to frosted standard.
        return GlassAdaptiveScope(
          minQuality: GlassQuality.premium,
          child: _buildLibrary(context, GlassQuality.premium),
        );
    }
  }

  /// Library-backed card (standard / premium): ios27 preset +
  /// own layer (per-widget settings are ignored in grouped mode
  /// without it — GlassContainer docs) + the Beans shadow on an
  /// outer Container (the library paints no shadow — same pattern
  /// as the mini player). The shape is Apple's continuous corner
  /// (LiquidRoundedSuperellipse) at the same radius number.
  ///
  /// With [tint] the wash is the child background: the gradient
  /// Container wraps the padded child, and the GlassContainer
  /// padding is zeroed so the wash reaches the card edge (the
  /// padding lives inside the wash instead). `clipBehavior:
  /// Clip.antiAlias` is required there — the library defaults to
  /// Clip.none, and the square-cornered wash would otherwise stick
  /// out of the superellipse at the corners.
  Widget _buildLibrary(BuildContext context, GlassQuality quality) {
    final borderRadius = BorderRadius.circular(radius);
    final tint = this.tint;
    final Widget content = tint == null
        ? child
        : Container(
            decoration: BoxDecoration(gradient: tint),
            child: Padding(padding: padding, child: child),
          );
    final glass = GlassContainer(
      shape: LiquidRoundedSuperellipse(borderRadius: radius),
      settings: HaoLiquidGlass.ios27Settings(context),
      useOwnLayer: true,
      quality: quality,
      padding: tint == null ? padding : EdgeInsets.zero,
      clipBehavior: tint == null ? Clip.none : Clip.antiAlias,
      child: content,
    );
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: _shadowFor(context),
      ),
      child: glass,
    );
  }

  /// The original hand-rolled frosted card, unchanged (Phase B kept
  /// it as the default branch so the 28 frosted sites render exactly
  /// as before).
  Widget _buildFrosted(BuildContext context) {
    final theme = HaoTheme.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: _shadowFor(context),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: theme.glassBlurSigma,
            sigmaY: theme.glassBlurSigma,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: theme.surface,
              borderRadius: borderRadius,
              border: Border.all(color: borderColor ?? theme.hairline),
            ),
            child: Stack(
              children: [
                // Top highlight: white sheen fading out ~45% down, the
                // gradient half of Beans' border/highlight recipe.
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: borderRadius,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.center,
                        colors: [
                          Colors.white.withValues(alpha: isDark ? 0.14 : 0.30),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.45],
                      ),
                    ),
                  ),
                ),
                Padding(padding: padding, child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum GlassShadow { none, card, panel, tabBar, miniPlayer, small }

/// Dark glass for elements floating over video / a dark scene (player
/// hint pills, live-room HUD, stall notice): BackdropFilter blurs the
/// video behind the pill, so white text stays legible over any frame.
/// Theme GlassCard is NOT used here — the player is a dark scene in
/// both modes and GlassCard's light-mode fill (near-white) would make
/// the white text unreadable.
class DarkGlass extends StatelessWidget {
  const DarkGlass({
    super.key,
    required this.child,
    this.radius = HaoRadius.large,
    this.sigma = 20,
    this.color = Colors.black54,
  });

  final Widget child;
  final double radius;
  final double sigma;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: Container(color: color, child: child),
      ),
    );
  }
}

/// Glass background for a modal bottom sheet: clips the top corners
/// and blurs the content behind the sheet, then paints the theme's
/// strong glass surface. Use as the root of a showModalBottomSheet
/// builder with backgroundColor: Colors.transparent (the sheet's own
/// shape/background would otherwise paint an opaque slab over the
/// blur). [radius] matches the sheet's existing top radius.
class GlassSheetBackground extends StatelessWidget {
  const GlassSheetBackground({
    super.key,
    required this.child,
    this.radius = HaoRadius.sheet,
  });

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: theme.glassBlurSigma,
          sigmaY: theme.glassBlurSigma,
        ),
        child: Container(
          color: theme.surfaceStrong,
          // Transparent Material between the fill and the content: the
          // sheets hold ListTiles, and a ListTile paints its ink on
          // the nearest Material ancestor — without this the ColoredBox
          // fill hides the ripples (debug assertion in tests, dead
          // taps visually on device).
          child: Material(color: Colors.transparent, child: child),
        ),
      ),
    );
  }
}

/// Press feedback for tappable glass children (Beans'
/// `GlassPressButtonStyle`: scale 0.94–0.97 while pressed, spring
/// back). Wrap the tappable child; the tap handling itself stays with
/// the inner GestureDetector / InkWell / button.
class GlassPressScale extends StatefulWidget {
  const GlassPressScale({
    super.key,
    required this.child,
    this.pressedScale = 0.97,
  });

  final Widget child;

  /// Scale while pressed (Beans uses 0.94 for rows, 0.97 for cards).
  final double pressedScale;

  @override
  State<GlassPressScale> createState() => _GlassPressScaleState();
}

class _GlassPressScaleState extends State<GlassPressScale> {
  var _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
