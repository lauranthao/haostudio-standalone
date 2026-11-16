// Clipboard service (fix 5) — copy with visible feedback, always.
//
// Three-step fallback chain: (1) platform clipboard write; if that is
// unavailable or fails, (2) the platform's alternate copy path (Flutter's
// Clipboard API is the alternate on mobile — the chain degrades to
// showing the text); (3) show the text itself in a dialog so the user
// can copy it manually. Never silently do nothing; never show a success
// toast for a copy that did not happen.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/hao_themes.dart';

class ClipboardService {
  ClipboardService._();

  /// Copy [text] and always give visible feedback. Returns true when the
  /// clipboard write succeeded, false when the dialog fallback was used.
  static Future<bool> copyWithFeedback(
    BuildContext context,
    String text, {
    String successMessage = '已复制',
  }) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(successMessage)),
      );
      return true;
    } catch (_) {
      // Fall through to the show-the-text dialog.
    }
    if (!context.mounted) return false;
    final theme = HaoTheme.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: theme.surfaceSolid,
        title: Text('复制', style: TextStyle(color: theme.textPrimary)),
        content: SelectableText(
          text,
          style: TextStyle(color: theme.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('关闭', style: TextStyle(color: theme.accent)),
          ),
        ],
      ),
    );
    return false;
  }
}
