// Sleep timer sheet (M-P0-3) — bottom ActionSheet-style panel (N-4).
//
// Was a centred floating card; iOS convention for a timer pick list
// is a bottom sheet, so this now rises from the bottom on the app's
// standard glass sheet pattern (showHaoSheet: floating grabber +
// drag-to-dismiss, top corners 14 — same as track_more_sheet).
// Options stacked vertically, current choice marked; 取消 is a separate row at the
// bottom.
//
// Options: 5 / 15 / 30 / 45 / 60 / 90 分钟, 到歌单结束, 自定义分钟,
// 关闭. When a wall-clock timer is running, the title shows the honest
// remaining time.
//
// Custom minutes (N-17): a CupertinoPicker wheel (1–720 分钟, Beans
// clamps with `min(max(minutes, 1), 720)` — copied exactly into
// [clampSleepCustomMinutes]) instead of the old number TextField; the
// value is persisted (MusicStore.sleepCustomMinutes) so the next open
// remembers it.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../core/theme/hao_radius.dart';
import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/haptics.dart';
import '../../../core/theme/liquid_glass_theme.dart';
import '../../../services/music/music_store.dart';
import '../../../services/music/sleep_timer.dart';
import '../../../widgets/hao_pressable.dart';
import '../music_player_controller.dart';
import '../../../widgets/hao_sheet.dart';

Future<SleepTimerOption?> showSleepTimerSheet(BuildContext context) {
  return showHaoSheet<SleepTimerOption>(
    context: context,
    builder: (ctx) => const _SleepTimerSheetContent(),
  );
}

class _SleepTimerSheetContent extends StatefulWidget {
  const _SleepTimerSheetContent();

  @override
  State<_SleepTimerSheetContent> createState() =>
      _SleepTimerSheetContentState();
}

class _SleepTimerSheetContentState extends State<_SleepTimerSheetContent> {
  late final MusicPlayerController _controller;
  late int _minutes;
  late final FixedExtentScrollController _pickerController;

  @override
  void initState() {
    super.initState();
    _controller = MusicPlayerController.ensure();
    // Initial value is the remembered value, not a hardcoded 30
    // (Beans' initial "30" is only the first-run default).
    _minutes = MusicStore.sleepCustomMinutes;
    _pickerController =
        FixedExtentScrollController(initialItem: _minutes - 1);
  }

  @override
  void dispose() {
    _pickerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassContainer(
      shape: const LiquidVerticalRoundedSuperellipse(
        topRadius: HaoRadius.sheet,
        bottomRadius: 0,
      ),
      settings: HaoLiquidGlass.ios27Settings(context),
      quality: GlassQuality.standard,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Obx(() {
                  final remaining = _controller.sleepRemaining.value;
                  final title = remaining != null
                      ? '睡眠定时（剩余 ${SleepTimer.formatRemaining(remaining)}）'
                      : '睡眠定时';
                  return Text(
                    title,
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                      color: theme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  );
                }),
              ),
              for (final option in SleepTimerOptionX.all)
                Obx(() {
                  final selected = _controller.sleepOption.value == option;
                  // The custom row shows the remembered minutes so the
                  // selection reads honestly ("自定义 45 分钟"); the
                  // afterNTracks row shows its N the same way.
                  final label = option == SleepTimerOption.custom
                      ? '自定义 ${_controller.sleepCustomMinutes.value} 分钟'
                      : option == SleepTimerOption.afterNTracks
                      ? '播完 ${_controller.sleepTrackCount.value} 首后停止'
                      : option.label;
                  return _SleepRow(
                    option: option,
                    label: label,
                    selected: selected,
                    onTap: () => Navigator.of(context).pop(option),
                    trailing: option == SleepTimerOption.afterNTracks
                        ? _TrackCountStepper(
                            value: _controller.sleepTrackCount.value,
                            onChanged: (n) {
                              HaoHaptics.select();
                              _controller.setSleepTrackCount(n);
                            },
                          )
                        : null,
                  );
                }),
              // Custom minutes (Beans "自定义时长" section): a picker
              // wheel, not a keyboard — iOS picks a duration by
              // scrolling, never by typing.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Row(
                  children: [
                    Text(
                      '自定义分钟',
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textPrimary,
                        fontSize: 16,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$_minutes 分钟',
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: theme.accent,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 128,
                child: CupertinoPicker.builder(
                  scrollController: _pickerController,
                  itemExtent: 32,
                  onSelectedItemChanged: (index) =>
                      setState(() => _minutes = index + 1),
                  childCount: 720,
                  itemBuilder: (ctx, index) => Center(
                    child: Text(
                      '${index + 1} 分钟',
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 17,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _SleepRow(
                  option: SleepTimerOption.custom,
                  label: '开始自定义定时',
                  selected: false,
                  icon: Icons.timer,
                  onTap: () {
                    final minutes = clampSleepCustomMinutes(_minutes);
                    // Pop first, persist in the background: awaiting
                    // the Hive disk write before popping held the
                    // sheet open on a slow write (same reason the
                    // update dialog pops before recording a skip).
                    unawaited(MusicStore.setSleepCustomMinutes(minutes));
                    Navigator.of(context).pop(SleepTimerOption.custom);
                  },
                ),
              ),
              const SizedBox(height: 8),
              Container(height: 1, color: theme.hairline),
              _CancelRow(onTap: () => Navigator.of(context).pop()),
            ],
          ),
        ),
      ),
    );
  }
}

/// − / value / + stepper for "播完 N 首后停止" (1..10, default 3).
/// Lives in the option row's trailing slot, styled like the other
/// rows (hairline-bordered pills, theme text). Tapping +/− calls
/// [onChanged] with the new value — the controller writes it into
/// the timer immediately (setSleepTrackCount), so tapping the row
/// afterwards starts the run with the new N; changing N mid-run
/// restarts the count from zero (SleepTimer.setTrackTarget).
class _TrackCountStepper extends StatelessWidget {
  const _TrackCountStepper({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _stepButton(theme, context, Icons.remove, value > 1,
            () => onChanged(value - 1)),
        SizedBox(
          width: 28,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: TextStyle(
              shadows: HaoTheme.legibilityShadows(context),
              color: theme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        _stepButton(theme, context, Icons.add, value < 10,
            () => onChanged(value + 1)),
      ],
    );
  }

  Widget _stepButton(
    HaoTheme theme,
    BuildContext context,
    IconData icon,
    bool enabled,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          border: Border.all(color: theme.hairline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon, shadows: HaoTheme.legibilityShadows(context), 
          size: 18,
          color: enabled ? theme.textPrimary : theme.textMuted,
        ),
      ),
    );
  }
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
        padding: const EdgeInsets.symmetric(vertical: 12),
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

class _SleepRow extends StatelessWidget {
  const _SleepRow({
    required this.option,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.trailing,
  });

  final SleepTimerOption option;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  /// Trailing control inside the row (the N stepper for
  /// afterNTracks). Its own taps must not trigger the row's onTap.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return HaoPressable(
      onTap: () {
        HaoHaptics.tap();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? theme.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(HaoRadius.large),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            Icon(
              shadows: HaoTheme.legibilityShadows(context),
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
                  shadows: HaoTheme.legibilityShadows(context),
                  color: theme.textPrimary,
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            if (trailing != null) ...[
              trailing!,
              const SizedBox(width: 8),
            ],
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
