// Per-episode custom skip-intro seconds (1.1.6, CMS) — edit dialog.
//
// Long-press an episode chip on a detail page → this glass dialog
// (showGlassDialog, the app's only dialog shell) with a seconds
// stepper. The value is stored per episode under
// HiveKeys.vodSkipIntroDurations ('<normalizedTitle>|<episodeName>'
// → seconds, 0–300); 0 = no custom skip for that episode. Emby
// episodes with Chapters markers ignore this value (markers win);
// the dialog still saves it — it applies if the same title is ever
// played from a CMS source.

import 'package:flutter/material.dart';

import '../../core/player/vod_controls.dart';
import '../../core/theme/hao_themes.dart';
import '../../widgets/glass_dialog.dart';

/// Edit one episode's custom skip-intro seconds. Returns when the
/// dialog closes (saved or cancelled).
Future<void> showSkipIntroDialog(
  BuildContext context, {
  required String title,
  required String episodeName,
}) async {
  var seconds = readSkipIntroDuration(
    title: title,
    episodeName: episodeName,
  );
  await showGlassDialog<void>(
    context,
    builder: (ctx) {
      final theme = HaoTheme.of(ctx);
      return StatefulBuilder(
        builder: (ctx, setDialogState) {
          void step(int delta) {
            setDialogState(() {
              seconds = (seconds + delta).clamp(0, 300);
            });
          }

          Widget stepButton(String label, int delta) {
            return OutlinedButton(
              onPressed: () => step(delta),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.textPrimary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              child: Text(label),
            );
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '跳过片头',
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                episodeName,
                style: TextStyle(color: theme.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  stepButton('−10秒', -10),
                  const SizedBox(width: 8),
                  stepButton('−1秒', -1),
                  const SizedBox(width: 12),
                  Text(
                    '$seconds 秒',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 12),
                  stepButton('+1秒', 1),
                  const SizedBox(width: 8),
                  stepButton('+10秒', 10),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '播放该集时自动跳过片头；0 秒 = 不跳过。',
                style: TextStyle(color: theme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(
                      '取消',
                      style: TextStyle(color: theme.textSecondary),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await saveSkipIntroDuration(
                        title: title,
                        episodeName: episodeName,
                        seconds: seconds,
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                    child: Text('保存', style: TextStyle(color: theme.accent)),
                  ),
                ],
              ),
            ],
          );
        },
      );
    },
  );
}
