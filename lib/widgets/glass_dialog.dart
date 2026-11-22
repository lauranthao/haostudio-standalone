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
import 'package:glassy_ui_ios/glassy_ui_ios.dart';

import '../core/theme/glass.dart';

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

/// Confirm dialog — a real UIAlertController on iOS
/// (NativeDialog.alert): title + message + two actions (confirm,
/// cancel). Returns true only when the confirm button is tapped.
/// Off-iOS NativeDialog falls back to a Material AlertDialog with the
/// same two actions, so the bool contract is identical everywhere.
/// [confirmColor] is kept for API compatibility: a caller that passes
/// an explicit confirm colour means the confirm is destructive (red
/// on iOS); no caller passes one today, so the confirm action is a
/// normal action. (The old glass version stacked confirm above
/// cancel; UIAlertController lays two alert actions side by side —
/// that is the native layout, not a regression.)
Future<bool> showGlassConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  Color? confirmColor,
}) async {
  final id = await NativeDialog.alert(
    title: title,
    message: content,
    actions: [
      NativeItem(
        id: 'confirm',
        title: confirmLabel,
        role: confirmColor == null
            ? NativeItemRole.normal
            : NativeItemRole.destructive,
      ),
      NativeItem(
        id: 'cancel',
        title: cancelLabel,
        role: NativeItemRole.cancel,
      ),
    ],
    context: context,
  );
  return id == 'confirm';
}
