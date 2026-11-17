// Sleep timer sheet (M-P0-3) — same liquid-glass floating panel as the
// quality sheet: large rounded corners, high transparency + strong blur
// with a bright edge, options stacked vertically, current choice marked.
//
// Options: 5 / 15 / 30 / 45 / 60 / 90 分钟, 到歌单结束, 自定义分钟,
// 关闭. When a wall-clock timer is running, the title shows the honest
// remaining time.
//
// Custom minutes (stage 2, Beans `SleepTimerSheet.swift:47-66`,
// "自定义时长" section): a "分钟" label + number TextField (width 90,
// right-aligned) + a "开始自定义定时" button. Beans clamps the input
// with `min(max(Int(text) ?? 30, 1), 720)` — copied exactly into
// [clampSleepCustomMinutes]; the value is persisted
// (MusicStore.sleepCustomMinutes) so the next open remembers it.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/theme/glass.dart';
import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/haptics.dart';
import '../../../services/music/music_store.dart';
import '../../../services/music/sleep_timer.dart';
import '../music_player_controller.dart';

Future<SleepTimerOption?> showSleepTimerSheet(BuildContext context) {
  final theme = HaoTheme.of(context);
  final controller = MusicPlayerController.ensure();
  // Initial text is the remembered value, not a hardcoded 30
  // (Beans' initial "30" is only the first-run default).
  final customController = TextEditingController(
    text: '${MusicStore.sleepCustomMinutes}',
  );
  final result = showDialog<SleepTimerOption>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (ctx) => Center(
      child: GlassCard(
        radius: 24,
        shadow: GlassShadow.panel,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          width: MediaQuery.of(ctx).size.width * 0.78,
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
                  final selected = controller.sleepOption.value == option;
                  // The custom row shows the remembered minutes so the
                  // selection reads honestly ("自定义 45 分钟").
                  final label = option == SleepTimerOption.custom
                      ? '自定义 ${controller.sleepCustomMinutes.value} 分钟'
                      : option.label;
                  return _SleepRow(
                    option: option,
                    label: label,
                    selected: selected,
                    onTap: () => Navigator.of(ctx).pop(option),
                  );
                }),
              // Custom minutes (Beans "自定义时长" section).
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Row(
                  children: [
                    Text(
                      '分钟',
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 16,
                      ),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: customController,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 16,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _SleepRow(
                  option: SleepTimerOption.custom,
                  label: '开始自定义定时',
                  selected: false,
                  icon: Icons.timer,
                  onTap: () async {
                    final minutes = clampSleepCustomMinutes(
                      int.tryParse(customController.text.trim()),
                    );
                    await MusicStore.setSleepCustomMinutes(minutes);
                    if (ctx.mounted) {
                      Navigator.of(ctx).pop(SleepTimerOption.custom);
                    }
                  },
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text('取消', style: TextStyle(color: theme.textSecondary)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return result.whenComplete(customController.dispose);
}

class _SleepRow extends StatelessWidget {
  const _SleepRow({
    required this.option,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final SleepTimerOption option;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return InkWell(
      onTap: () {
        HaoHaptics.tap();
        onTap();
      },
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
              icon ??
                  (option == SleepTimerOption.queueEnd
                      ? Icons.playlist_play
                      : option == SleepTimerOption.off
                      ? Icons.timer_off
                      : option == SleepTimerOption.custom
                      ? Icons.timer
                      : Icons.timer),
              color: selected ? theme.accent : theme.textSecondary,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
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
