// Collapsible section (fixes 5 + 11) — shared head + chevron + body.
//
// Tapping the head collapses/expands the body; the chevron rotates 90°
// over 0.2 s. State is per-section and independent; navigating away and
// back keeps the user's last state for the session (the owning page holds
// the state — this widget is stateless and driven by [expanded]).

import 'package:flutter/material.dart';

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
  });

  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;
  final Widget? trailing;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.chevron_right,
                    color: theme.textSecondary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    title,
                    style: titleStyle ??
                        TextStyle(
                          color: theme.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: child,
          crossFadeState:
              expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }
}
