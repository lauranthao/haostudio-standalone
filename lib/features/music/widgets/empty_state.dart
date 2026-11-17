// Empty state — Kumone `EmptyStateView` (Cards.swift:180-198),
// ported as values, not code (Kumone is LGPL-3.0; this app is closed
// source, so only the design values and behaviour are borrowed):
// icon 40 tertiary, title headline (17 semibold), subtitle subheadline
// (15 secondary), spacing 12. [minHeight] is 300 on full-page empty
// states (Kumone `LibraryPages.swift:52-55`); compact uses (playlists
// section) pass null and the state sizes to its content.

import 'package:flutter/material.dart';

import '../../../core/theme/hao_themes.dart';

class HaoEmptyState extends StatelessWidget {
  const HaoEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.minHeight,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final double? minHeight;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return SizedBox(
      width: double.infinity,
      height: minHeight,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: theme.textMuted),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 12),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textSecondary, fontSize: 15),
            ),
          ],
        ],
      ),
    );
  }
}
