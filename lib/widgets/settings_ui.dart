// Shared settings visuals — grouped frosted-glass cards, section titles,
// intro hints, chevrons. Visual only: no state, no navigation, no logic.
//
// Every colour comes from HaoTheme (4 themes x light/dark = 8 combos);
// no hardcoded colours anywhere here. The card shadow is a neutral
// black alpha (a shadow, not a surface colour) and is lighter in light
// mode so it never muddies a light glass card.

import 'package:flutter/material.dart';

import '../core/theme/glass.dart';

import '../core/theme/hao_themes.dart';

/// Section heading: 13 / w700 / muted, with a little tracking.
/// Same on every settings page (settings tab, danmaku, sources...).
class HaoSectionTitle extends StatelessWidget {
  const HaoSectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Text(
        title,
        style: TextStyle(
          color: theme.textMuted,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// Intro / explainer paragraph under a page title: 13 / secondary,
/// generous line height so it stays readable in every theme and mode.
class HaoHint extends StatelessWidget {
  const HaoHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: TextStyle(
          color: theme.textSecondary,
          fontSize: 13,
          height: 1.55,
        ),
      ),
    );
  }
}

/// Trailing chevron for push rows: muted, 20pt — quieter than the
/// default icon colour so rows read as calm lists, not button grids.
class HaoChevron extends StatelessWidget {
  const HaoChevron({super.key});

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.chevron_right,
      color: HaoTheme.of(context).textMuted,
      size: 20,
    );
  }
}

/// One frosted-glass card: theme surface + blur + hairline border +
/// 24pt radius (Beans `GlassCard` default cornerRadius, Components.swift)
/// + a soft neutral shadow (stronger in dark mode, where
/// a glass card over a near-black scaffold needs the lift to separate).
class HaoGlassCard extends StatelessWidget {
  const HaoGlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(4),
    this.margin,
    this.quality = GlassCardQuality.frosted,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  /// Forwards to [GlassCard.quality] (Phase B). Default frosted.
  final GlassCardQuality quality;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: GlassCard(
        radius: 24,
        shadow: GlassShadow.card,
        padding: padding,
        quality: quality,
        // Transparent Material inside the glass: ListTile/SwitchListTile
        // paint their ink splashes on the nearest Material ancestor —
        // without this Flutter asserts ("ink splashes may be invisible")
        // and taps show no ripple. The Material is transparent, so the
        // glass surface and blur behind it are untouched. The outer
        // GlassCard clips, so no clipBehavior is needed here.
        child: Material(color: Colors.transparent, child: child),
      ),
    );
  }
}

/// A grouped card of settings rows (ListTile / SwitchListTile /
/// RadioListTile / slider rows): hairline dividers between rows only,
/// no divider above the first or below the last row. The group takes
/// any children, so existing rows move in unchanged — no logic moves.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // Phase B: grouped settings sections render as standard liquid
    // glass (library shader, built for scrolling lists). Children are
    // Material ListTile/SwitchListTile/RadioListTile rows — no glass
    // controls inside, so no nesting issue.
    return HaoGlassCard(
      quality: GlassCardQuality.standard,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            children[i],
          ],
        ],
      ),
    );
  }
}
