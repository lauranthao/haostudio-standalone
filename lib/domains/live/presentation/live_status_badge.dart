// Shared live-status badge (L01 history cards + L03 follow cards).
//
// LIVE is the only red in the app; offline / unknown use a muted dark
// pill so a failed check is never shown as live.

import 'package:flutter/material.dart';

import '../../../core/theme/hao_themes.dart';
import '../live_status.dart';

class LiveStatusBadge extends StatelessWidget {
  const LiveStatusBadge({super.key, required this.status});

  final LiveStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    switch (status) {
      case LiveStatus.live:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: theme.liveRed,
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.30),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: const Text(
            'LIVE',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        );
      case LiveStatus.offline:
        return const _MutedPill(label: '已下播');
      case LiveStatus.unknown:
        return const _MutedPill(label: '状态未知');
    }
  }
}

class _MutedPill extends StatelessWidget {
  const _MutedPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    // Muted pill sits ON cover artwork: black-alpha is deliberate —
    // a theme surface would be white in light mode and unreadable.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xA6000000),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}
