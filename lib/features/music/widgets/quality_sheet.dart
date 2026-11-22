// Audio quality sheet — bottom ActionSheet-style panel (N-4).
//
// Was a centred floating card; iOS convention for a quality pick list
// is a bottom sheet, so this now rises from the bottom on the app's
// standard glass sheet pattern (showHaoSheet: floating grabber +
// drag-to-dismiss, top corners 14 — same as track_more_sheet).
// Options stacked vertically, current choice marked with a check; 取消 is a separate
// row at the bottom. Colours follow the active theme in both light
// and dark mode.
//
// The FIVE tiers (see music_quality.dart): Master on top, then Hi-Res,
// 无损 FLAC, 高音质 320k, 标准 128k. Rows come from [kQualityChain], so
// Master is first by construction. The badge in the player shows the
// tier ACTUALLY played (controller.actualQuality): if Master is
// unavailable the resolver downgrades and the badge shows hires (or
// whatever really played) — a hires stream is never labelled Master.

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../core/theme/hao_radius.dart';
import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/liquid_glass_theme.dart';
import '../../../services/music/music_quality.dart';
import '../../../widgets/hao_pressable.dart';
import '../../../widgets/hao_sheet.dart';

Future<AudioQuality?> showQualitySheet(
  BuildContext context,
  AudioQuality current,
) {
  final theme = HaoTheme.of(context);
  return showHaoSheet<AudioQuality>(
    context: context,
    builder: (ctx) => GlassContainer(
      shape: const LiquidVerticalRoundedSuperellipse(
        topRadius: HaoRadius.sheet,
        bottomRadius: 0,
      ),
      settings: HaoLiquidGlass.ios27Settings(ctx),
      quality: GlassQuality.standard,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '音质',
                style: TextStyle(
                  shadows: HaoTheme.legibilityShadows(context),
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
            const SizedBox(height: 8),
            Container(height: 1, color: theme.hairline),
            _CancelRow(onTap: () => Navigator.of(ctx).pop()),
          ],
        ),
      ),
    ),
  );
}

/// Separate bottom cancel row (iOS ActionSheet: 取消 stands alone).
class _CancelRow extends StatelessWidget {
  const _CancelRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return HaoPressable(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Text(
          '取消',
          textAlign: TextAlign.center,
          style: TextStyle(
            shadows: HaoTheme.legibilityShadows(context),
            color: theme.textSecondary,
            fontSize: 17,
          ),
        ),
      ),
    );
  }
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
    return HaoPressable(
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
                  shadows: HaoTheme.legibilityShadows(context),
                  color: theme.textPrimary,
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            if (selected)
              Icon(
                shadows: HaoTheme.legibilityShadows(context),
                Icons.check,
                color: theme.accent,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}
