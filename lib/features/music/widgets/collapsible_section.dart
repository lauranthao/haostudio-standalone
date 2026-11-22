// Collapsible section (fixes 5 + 11) — shared head + chevron + body.
//
// Tapping the head collapses/expands the body; the chevron rotates 90°
// over 0.2 s. State is per-section and independent; navigating away and
// back keeps the user's last state for the session (the owning page holds
// the state — this widget is stateless and driven by [expanded]).
//
// The [trailing] widget (e.g. the music home's 「播放全部」 capsule)
// sits OUTSIDE the head HaoPressable: a button nested inside another
// button's tap area competes in the gesture arena, and the head toggle
// would swallow the trailing's tap. Tapping the title area toggles;
// tapping the trailing acts only on the trailing.

import 'package:flutter/material.dart';
import '../../../widgets/hao_pressable.dart';

import '../../../core/theme/hao_themes.dart';

class CollapsibleSection extends StatelessWidget {
  const CollapsibleSection({
    super.key,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.child,
    this.trailing,
    this.titleStyle,
    this.showLeadingChevron = true,
    this.horizontalPadding = 16,
    this.verticalPadding = 14,
  });

  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;
  final Widget? trailing;
  final TextStyle? titleStyle;

  /// Kumone `SectionHeader` (Components.swift:100-130) has no leading
  /// chevron — the title alone is the head. Defaults to true so the
  /// artist pages that share this widget keep their chevron; the music
  /// home passes false.
  final bool showLeadingChevron;

  /// Head horizontal padding. Kumone `Theme.Layout.contentInset` = 24
  /// (Theme.swift:20); the music home passes 24, other users keep 16.
  final double horizontalPadding;

  /// Head vertical padding. Kumone iOS `sectionHeaderSpacing` = 10
  /// (Theme.swift:64) is the gap from head to content; the music home
  /// passes 10, other users keep 14.
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: HaoPressable(
                onTap: onToggle,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: horizontalPadding,
                    vertical: verticalPadding,
                  ),
                  child: Row(
                    children: [
                      if (showLeadingChevron) ...[
                        AnimatedRotation(
                          turns: expanded ? 0.25 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.chevron_right,
                            color: theme.textSecondary,
                            size: 22,
                            shadows:
                                HaoTheme.legibilityShadows(context),
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          title,
                          style:
                              (titleStyle ??
                                      TextStyle(
                                        // Title 3 20 semibold (was 18
                                        // w800 — 18 is not an Apple
                                        // text style; Title 3 is 20).
                                        color: theme.textPrimary,
                                        fontSize: 20,
                                        fontWeight: FontWeight.w600,
                                      ))
                                  .copyWith(
                                    shadows:
                                        HaoTheme.legibilityShadows(context),
                                  ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (trailing != null)
              Padding(
                padding: EdgeInsets.only(right: horizontalPadding),
                child: trailing,
              ),
          ],
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: child,
          crossFadeState: expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }
}
