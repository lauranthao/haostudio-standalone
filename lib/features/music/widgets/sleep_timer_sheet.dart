// Sleep timer sheet (M-P0-3) — same liquid-glass floating panel as the
// quality sheet: large rounded corners, high transparency + strong blur
// with a bright edge, options stacked vertically, current choice marked.
//
// Options: 15 / 30 / 60 / 90 分钟, 到歌单结束, 关闭. When a wall-clock
// timer is running, the title shows the honest remaining time.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../services/music/sleep_timer.dart';
import '../music_player_controller.dart';

Future<SleepTimerOption?> showSleepTimerSheet(BuildContext context) {
  final theme = HaoTheme.of(context);
  final controller = MusicPlayerController.ensure();
  return showDialog<SleepTimerOption>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (ctx) => Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: theme.glassBlurSigma,
            sigmaY: theme.glassBlurSigma,
          ),
          child: Container(
            width: MediaQuery.of(ctx).size.width * 0.78,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: theme.surfaceStrong,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: theme.textPrimary.withValues(alpha: 0.22),
                width: 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Obx(() {
                    final remaining = controller.sleepRemaining.value;
                    final title = remaining != null
                        ? '睡眠定时（剩余 ${SleepTimer.formatRemaining(remaining)}）'
                        : '睡眠定时';
                    return Text(
                      title,
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    );
                  }),
                ),
                for (final option in SleepTimerOptionX.all)
                  Obx(() {
                    final selected =
                        controller.sleepOption.value == option;
                    return _SleepRow(
                      option: option,
                      selected: selected,
                      onTap: () => Navigator.of(ctx).pop(option),
                    );
                  }),
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

class _SleepRow extends StatelessWidget {
  const _SleepRow({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final SleepTimerOption option;
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
          borderRadius: BorderRadius.circular(12),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            Icon(
              option == SleepTimerOption.queueEnd
                  ? Icons.playlist_play
                  : option == SleepTimerOption.off
                      ? Icons.timer_off
                      : Icons.timer,
              color: selected ? theme.accent : theme.textSecondary,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                option.label,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check, color: theme.accent, size: 20),
          ],
        ),
      ),
    );
  }
}
