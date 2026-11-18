// Glass dialogs — the same Center + GlassCard pattern as the update
// dialog (update_dialog.dart): a real backdrop blur over the page
// (barrier black 0.35), radius 24, panel shadow, padding 20/20/12,
// width 82% of the screen. Use these instead of AlertDialog anywhere
// a dialog appears, so dialogs are glass like every other surface.

import 'package:flutter/material.dart';

import '../core/theme/glass.dart';
import '../core/theme/hao_themes.dart';

/// Generic glass dialog shell. [builder] returns the dialog content
/// (title + body + actions, laid out by the caller).
Future<T?> showGlassDialog<T>(
  BuildContext context, {
  required Widget Function(BuildContext ctx) builder,
  bool barrierDismissible = true,
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
          radius: 24,
          shadow: GlassShadow.panel,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: SizedBox(
            width: MediaQuery.of(ctx).size.width * 0.82,
            child: builder(ctx),
          ),
        ),
      ),
    ),
  );
}

/// Glass confirm dialog: title 17 w700, content 14 secondary, two
/// right-aligned actions (cancel secondary, confirm accent — or
/// [confirmColor] for destructive confirms). Returns true only when
/// the confirm button is tapped.
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
    builder: (ctx) {
      final theme = HaoTheme.of(ctx);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            content,
            style: TextStyle(
              color: theme.textSecondary,
              fontSize: 14,
              height: 1.55,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(
                  cancelLabel,
                  style: TextStyle(color: theme.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(
                  confirmLabel,
                  style: TextStyle(color: confirmColor ?? theme.accent),
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
  return result ?? false;
}
