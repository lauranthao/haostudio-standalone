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
// - radii: cards 24, rows 16, mini player 18, floating panels 22
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

import 'hao_themes.dart';

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

/// A liquid-glass container: backdrop blur + low-alpha theme surface +
/// hairline border + top highlight + soft shadow.
///
/// The child is laid out with [padding] inside the glass. Set [radius]
/// per Beans' scale (cards 24, rows 16, floating panels 22); [shadow]
/// picks the card or panel shadow. The glass is transparent by design
/// — over a flat scaffold background it reads as a tinted card; over
/// varied content (cover art, lists) the blur shows.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding = const EdgeInsets.all(16),
    this.shadow = GlassShadow.card,
    this.margin,
    this.borderColor,
  });

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
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: switch (shadow) {
          GlassShadow.none => null,
          GlassShadow.card => glassCardShadow(context),
          GlassShadow.panel => glassPanelShadow(context),
          GlassShadow.tabBar => glassTabBarShadow(context),
          GlassShadow.miniPlayer => glassMiniPlayerShadow(context),
          GlassShadow.small => glassSmallShadow(context),
        },
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
    this.radius = 12,
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
    this.radius = 24,
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
