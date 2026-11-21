// Audio quality sheet — liquid-glass floating panel (fix 15/16 era).
//
// Centred floating card (not a bottom sheet): large rounded corners, high
// transparency + strong blur with a bright edge. Options stacked
// vertically, current choice marked with a check. Colours follow the
// active theme in both light and dark mode.
//
// The FIVE tiers (see music_quality.dart): Master on top, then Hi-Res,
// 无损 FLAC, 高音质 320k, 标准 128k. Rows come from [kQualityChain], so
// Master is first by construction. The badge in the player shows the
// tier ACTUALLY played (controller.actualQuality): if Master is
// unavailable the resolver downgrades and the badge shows hires (or
// whatever really played) — a hires stream is never labelled Master.

import '../../../core/theme/hao_radius.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/liquid_glass_theme.dart';
import '../../../services/music/music_quality.dart';

Future<AudioQuality?> showQualitySheet(
  BuildContext context,
  AudioQuality current,
) {
  final theme = HaoTheme.of(context);
  return showDialog<AudioQuality>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    // Material ancestor is required: the dialog route has none, and
    // without it Text falls back to the framework's debug style
    // (red monospace + double yellow underline). Transparent so the
    // glass panel's own surface stays visible (same fix as
    // glass_dialog.dart, commit 18b03fe).
    builder: (ctx) => Material(
      type: MaterialType.transparency,
      child: Center(
        // Kumone redo: library glass (standard — the rows are a dense
        // list, never premium shader) instead of the self-made GlassCard.
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 24),
          // Intensity-scaled optics (chen 2026-11-21): explicit
          // settings so the sheet follows the slider instead of
          // the ambient theme.
          settings: HaoLiquidGlass.ios27Settings(ctx),
          quality: GlassQuality.standard,
          useOwnLayer: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: SizedBox(
            width: MediaQuery.of(ctx).size.width * 0.78,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    '音质',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (final q in kQualityChain)
                  _QualityRow(
                    quality: q,
                    selected: q == current,
                    onTap: () => Navigator.of(ctx).pop(q),
                  ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(
                    '取消',
                    style: TextStyle(color: theme.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _QualityRow extends StatelessWidget {
  const _QualityRow({
    required this.quality,
    required this.selected,
    required this.onTap,
  });

  final AudioQuality quality;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? theme.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(HaoRadius.large),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                quality.label,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            if (selected) Icon(Icons.check, color: theme.accent, size: 20),
          ],
        ),
      ),
    );
  }
}
