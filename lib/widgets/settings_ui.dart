// Shared settings visuals — grouped frosted-glass cards, section titles,
// intro hints, chevrons. Visual only: no state, no navigation, no logic.
//
// Every colour comes from HaoTheme (4 themes x light/dark = 8 combos);
// no hardcoded colours anywhere here. The card shadow is a neutral
// black alpha (a shadow, not a surface colour) and is lighter in light
// mode so it never muddies a light glass card.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/theme/glass.dart';

import '../core/theme/hao_radius.dart';
import '../core/theme/hao_themes.dart';
import 'hao_inset_grouped.dart';
import 'hao_pressable.dart';

/// Borderless input decoration for grouped-list form rows (iOS
/// Settings style: the row IS the field — label left, value right,
/// no pill, no outline).
///
/// Why this exists instead of [InputDecoration.collapsed]: collapsed
/// only sets `border = InputBorder.none` and leaves `enabledBorder`
/// / `focusedBorder` null — [InputDecoration.applyDefaults] then
/// fills them from the theme's `inputDecorationTheme`, whose
/// enabled/focused borders are pill [OutlineInputBorder]s
/// (hao_themes.dart). Every collapsed field in the app therefore
/// rendered a pill outline (the Emby page in build 29). This
/// decoration pins every border state to none, so the theme can
/// never re-add a pill.
InputDecoration haoFormFieldDecoration({
  required String? hint,
  TextStyle? hintStyle,
}) =>
    InputDecoration(
      hintText: hint,
      hintStyle: hintStyle,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
      contentPadding: EdgeInsets.zero,
      isDense: true,
      filled: false,
    );

/// Big group title (settings page `_SectionTitle`, 2026-11-23
/// extracted to shared): Apple Title 2, 22 semibold, primary text,
/// padding fromLTRB(4, 0, 4, 10). One title style for every top-level
/// group on settings-style pages — the small 13pt [HaoSectionTitle]
/// is only for sub-headers inside a page, never for a group.
class HaoGroupTitle extends StatelessWidget {
  const HaoGroupTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Text(
        title,
        style: TextStyle(
          color: HaoTheme.of(context).textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w600,
          shadows: HaoTheme.legibilityShadows(context),
        ),
      ),
    );
  }
}

/// One collapsible settings group (settings page
/// `_CollapsibleSection`, 2026-11-23 extracted to shared): big
/// [HaoGroupTitle] + animated chevron (16pt, rotates 90° when
/// collapsed, 300ms) + [AnimatedSize] expand/collapse (300ms
/// easeInOut). Groups are separated by 14px, rows inside a group by
/// 12px — the caller keeps those gaps. The chevron rotation uses a
/// plain easeOut curve (unslop motion: no bouncy overshoot on
/// simple UI — the old easeOutBack is gone).
class HaoCollapsibleSection extends StatelessWidget {
  const HaoCollapsibleSection({
    super.key,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.children,
  });

  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: HaoPressable(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(HaoRadius.panel),
            child: Row(
              children: [
                Expanded(child: HaoGroupTitle(title)),
                AnimatedRotation(
                  turns: expanded ? 0 : -0.25,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  child: Icon(
                    CupertinoIcons.chevron_down,
                    size: 16,
                    color: theme.textMuted.withValues(alpha: 0.8),
                    shadows: HaoTheme.legibilityShadows(context),
                  ),
                ),
              ],
            ),
          ),
        ),
        ClipRect(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: expanded
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ..._withGaps(children),
                      // 6px breathing room inside the clip: the last
                      // card's drop shadow / backdrop blur reaches
                      // ~3px below the card; without this the ClipRect
                      // (and AnimatedSize's own clip) cuts the shadow
                      // exactly at the card edge and the bottom 3px
                      // render 1-4 units off in light mode (golden
                      // diff, invisible to the eye but real). The
                      // inter-section gap below is 14 instead of 20,
                      // so last-row-to-next-header stays 20 in total.
                      const SizedBox(height: 6),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  /// 组内行之间 12px, 和原来平铺时的行间距一致.
  static List<Widget> _withGaps(List<Widget> rows) {
    final out = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) out.add(const SizedBox(height: 12));
      out.add(rows[i]);
    }
    return out;
  }
}

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
          // Apple grouped-list section header = Footnote 13 regular,
          // secondary label (build-29 typography: was 13 w700,
          // letterSpacing 0.6 — heavier than any iOS section header).
          color: theme.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w400,
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
          // Footnote leading 18/13 = 1.38 (was 1.55).
          height: 1.38,
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
      Icons.chevron_right, shadows: HaoTheme.legibilityShadows(context), 
      color: HaoTheme.of(context).textMuted,
      size: 20,
    );
  }
}

/// One frosted-glass card: theme surface + blur + hairline border +
/// [HaoRadius.panel] radius (the token scale's card step — the old
/// literal 24 was a second card radius next to GlassCard's own
/// default panel 20, so settings cards and every other card in the
/// app disagreed by 4pt) + a soft neutral shadow (stronger in dark
/// mode, where a glass card over a near-black scaffold needs the
/// lift to separate).
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
        radius: HaoRadius.panel,
        shadow: GlassShadow.card,
        padding: padding,
        quality: quality,
        // Transparent Material inside the glass: ListTile rows
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

/// A grouped card of settings rows (ListTile / HaoSwitchRow /
/// RadioListTile / slider rows): hairline dividers between rows only,
/// no divider above the first or below the last row. The group takes
/// any children, so existing rows move in unchanged — no logic moves.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // build-29 adoption: grouped settings sections render as iOS
    // inset grouped sections (solid, 10pt radius, hairline, no
    // shadow) instead of frosted-glass cards. Children are Material
    // ListTile / HaoSwitchRow / RadioListTile rows — no glass
    // controls inside, so no nesting issue.
    return HaoInsetGroupedSection(
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
