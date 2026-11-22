// VOD sleep timer sheet (I-影视 item 8) — bottom sheet.
//
// Reuses the MUSIC timer's state machine, not a second one:
// [SleepTimer] (services/music/sleep_timer.dart) + its
// [SleepTimerOption] enum + the same clamps. Only the persisted
// values are separate VOD keys (vodSleepCustomMinutes /
// vodSleepEpisodeCount) and the labels are VOD words: the music
// "播完本首后停止" is "播完本集后停止" here, "播完 N 首" is
// "播完 N 集". `queueEnd` (到歌单结束) is NOT offered — VOD has
// no queue. The owning player page owns the SleepTimer instance;
// this sheet only collects the choice and pops it, exactly like
// showSleepTimerSheet pops a SleepTimerOption for the music
// controller to apply.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../core/storage/hive_store.dart';
import '../../core/theme/hao_radius.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../core/theme/liquid_glass_theme.dart';
import '../../services/music/sleep_timer.dart';
import '../../widgets/hao_pressable.dart';
import '../../widgets/hao_sheet.dart';

/// What the user picked in the VOD sleep sheet.
class VodSleepChoice {
  const VodSleepChoice({
    required this.option,
    required this.customMinutes,
    required this.trackCount,
  });

  final SleepTimerOption option;

  /// Custom minutes (only meaningful for [SleepTimerOption.custom]).
  final int customMinutes;

  /// "播完 N 集" count (only meaningful for
  /// [SleepTimerOption.afterNTracks]).
  final int trackCount;
}

/// VOD sleep options, in sheet order — the music list minus
/// `queueEnd` (no queue in VOD).
const List<SleepTimerOption> kVodSleepOptions = [
  SleepTimerOption.min5,
  SleepTimerOption.min15,
  SleepTimerOption.min30,
  SleepTimerOption.min45,
  SleepTimerOption.min60,
  SleepTimerOption.min90,
  SleepTimerOption.currentTrackEnd,
  SleepTimerOption.afterNTracks,
  SleepTimerOption.custom,
  SleepTimerOption.off,
];

/// VOD label for a sleep option (music labels, reworded for
/// episodes: 本首 → 本集, N 首 → N 集).
String vodSleepOptionLabel(
  SleepTimerOption option, {
  required int customMinutes,
  required int trackCount,
}) {
  switch (option) {
    case SleepTimerOption.currentTrackEnd:
      return '播完本集后停止';
    case SleepTimerOption.afterNTracks:
      return '播完 $trackCount 集后停止';
    case SleepTimerOption.custom:
      return '自定义 $customMinutes 分钟';
    case SleepTimerOption.queueEnd:
      return '到歌单结束';
    default:
      return option.label;
  }
}

/// The persisted VOD custom minutes (default 30, clamp 1..720 —
/// same clamp as the music sheet).
int vodSleepCustomMinutes() {
  try {
    return clampSleepCustomMinutes(
      HiveStore.getInt(HiveKeys.vodSleepCustomMinutes, 30),
    );
  } catch (_) {
    return 30;
  }
}

/// The persisted VOD "播完 N 集" count (default 3, clamp 1..10).
int vodSleepEpisodeCount() {
  try {
    return clampSleepTrackCount(
      HiveStore.getInt(HiveKeys.vodSleepEpisodeCount, 3),
    );
  } catch (_) {
    return 3;
  }
}

Future<VodSleepChoice?> showVodSleepTimerSheet(
  BuildContext context, {
  required SleepTimer timer,
}) {
  return showHaoSheet<VodSleepChoice>(
    context: context,
    builder: (ctx) => _VodSleepTimerSheetContent(timer: timer),
  );
}

class _VodSleepTimerSheetContent extends StatefulWidget {
  const _VodSleepTimerSheetContent({required this.timer});

  final SleepTimer timer;

  @override
  State<_VodSleepTimerSheetContent> createState() =>
      _VodSleepTimerSheetContentState();
}

class _VodSleepTimerSheetContentState
    extends State<_VodSleepTimerSheetContent> {
  late int _minutes;
  late int _trackCount;
  late final FixedExtentScrollController _pickerController;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _minutes = vodSleepCustomMinutes();
    _trackCount = vodSleepEpisodeCount();
    _pickerController =
        FixedExtentScrollController(initialItem: _minutes - 1);
    // Refresh the remaining-time title once a second while open
    // (the music sheet gets this free via Obx on the controller;
    // this sheet owns no observable, so it ticks itself).
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _pickerController.dispose();
    super.dispose();
  }

  void _pop(SleepTimerOption option) {
    Navigator.of(context).pop(
      VodSleepChoice(
        option: option,
        customMinutes: _minutes,
        trackCount: _trackCount,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final remaining = widget.timer.remaining;
    final title = remaining != null
        ? '睡眠定时（剩余 ${SleepTimer.formatRemaining(remaining)}）'
        : '睡眠定时';
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
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  title,
                  style: TextStyle(
                    shadows: HaoTheme.legibilityShadows(context),
                    color: theme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final option in kVodSleepOptions)
                _SleepRow(
                  label: vodSleepOptionLabel(
                    option,
                    customMinutes: _minutes,
                    trackCount: _trackCount,
                  ),
                  selected: widget.timer.option == option,
                  icon: option == SleepTimerOption.off
                      ? Icons.timer_off
                      : option == SleepTimerOption.currentTrackEnd ||
                              option == SleepTimerOption.afterNTracks
                          ? Icons.playlist_play
                          : Icons.timer,
                  trailing: option == SleepTimerOption.afterNTracks
                      ? _TrackCountStepper(
                          value: _trackCount,
                          onChanged: (n) {
                            HaoHaptics.select();
                            setState(() => _trackCount = n);
                          },
                        )
                      : null,
                  onTap: () => _pop(option),
                ),
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
                height: 160,
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
                  label: '开始自定义定时',
                  selected: false,
                  icon: Icons.timer,
                  onTap: () => _pop(SleepTimerOption.custom),
                ),
              ),
              const SizedBox(height: 8),
              Container(height: 1, color: theme.hairline),
              HaoPressable(
                onTap: () => Navigator.of(context).pop(),
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
          borderRadius: BorderRadius.circular(HaoRadius.standard),
        ),
        child: Icon(
          icon,
          shadows: HaoTheme.legibilityShadows(context),
          size: 18,
          color: enabled ? theme.textPrimary : theme.textMuted,
        ),
      ),
    );
  }
}

class _SleepRow extends StatelessWidget {
  const _SleepRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.trailing,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
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
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? theme.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(HaoRadius.large),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            Icon(
              shadows: HaoTheme.legibilityShadows(context),
              icon ?? Icons.timer,
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
                  fontWeight:
                      selected ? FontWeight.w700 : FontWeight.w400,
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
