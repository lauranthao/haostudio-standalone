// Glass dialogs — the same Center + GlassCard pattern as the update
// dialog (update_dialog.dart): a real backdrop blur over the page
// (barrier black 0.35), radius 14 (iOS alert), panel shadow, width
// 82% of the screen. Use these instead of AlertDialog anywhere a
// dialog appears, so dialogs are glass like every other surface.
//
// N-4: iOS alert layout — title 17 Semibold centered, message 13
// centered, actions full-width, stacked vertically, separated by
// hairline dividers (no right-aligned Material TextButton row).

import 'package:flutter/material.dart';

import '../core/theme/glass.dart';
import '../core/theme/hao_themes.dart';

/// Generic glass dialog shell. [builder] returns the dialog content
/// (title + body + actions, laid out by the caller). [padding] is the
/// card's inner padding; confirm dialogs pass zero so their action
/// dividers run edge to edge.
Future<T?> showGlassDialog<T>(
  BuildContext context, {
  required Widget Function(BuildContext ctx) builder,
  bool barrierDismissible = true,
  EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(20, 20, 20, 12),
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    // Material ancestor is required: the dialog route has none, and
    // without it Text falls back to the framework's debug style
    // (red monospace + double yellow underline). Transparent so the
    // glass card's own surface stays visible.
    builder: (ctx) => Material(
      type: MaterialType.transparency,
      child: Center(
        child: GlassCard(
          radius: 14,
          shadow: GlassShadow.panel,
          quality: GlassCardQuality.premium,
          padding: padding,
          child: SizedBox(
            width: MediaQuery.of(ctx).size.width * 0.82,
            child: builder(ctx),
          ),
        ),
      ),
    ),
  );
}

/// One full-width stacked action row for an iOS-style alert: 17pt,
/// centred, min 44pt tall, separated from its neighbours by a
/// hairline divider above it.
Widget _alertAction(
  BuildContext context, {
  required String label,
  required VoidCallback onPressed,
  required Color color,
  FontWeight weight = FontWeight.w400,
}) {
  final theme = HaoTheme.of(context);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(height: 1, color: theme.hairline),
      TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          minimumSize: const Size.fromHeight(44),
          shape: const RoundedRectangleBorder(),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          label,
          style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: color, fontSize: 17, fontWeight: weight),
        ),
      ),
    ],
  );
}

/// Glass confirm dialog: title 17 w600 centered, content 13
/// secondary centered, two full-width stacked actions (confirm on
/// top, cancel at the bottom — iOS stacked order) separated by
/// hairline dividers. Returns true only when the confirm button
/// is tapped.
Future<bool> showGlassConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  Color? confirmColor,
}) async {
  final result = await showGlassDialog<bool>(
    context,
    padding: EdgeInsets.zero,
    builder: (ctx) {
      final theme = HaoTheme.of(ctx);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    shadows: HaoTheme.legibilityShadows(ctx),
                    color: theme.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  content,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    shadows: HaoTheme.legibilityShadows(ctx),
                    color: theme.textSecondary,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          _alertAction(
            ctx,
            label: confirmLabel,
            color: confirmColor ?? theme.accent,
            weight: FontWeight.w600,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
          _alertAction(
            ctx,
            label: cancelLabel,
            color: theme.textSecondary,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
        ],
      );
    },
  );
  return result ?? false;
}
