// Room tools sheet — the in-room entry for the build-29 live
// features (items 4, 8, 10, 12, 13, 14, 15). All switches are
// [HaoNativeSwitch] (via [HaoSwitchRow]) — never Material
// SwitchListTile. The sheet is state-display only: every row reads
// its value from the room page and reports changes back through
// callbacks, so the room stays the single source of truth.
//
// Rows:
// - 纯音频模式 (audio-only; MPV-only underneath — IJK/AVPlayer no-op,
//   the subtitle says so when the engine is not MPV)
// - 定时关闭 (15/30/60 分钟 / 关闭)
// - 音量增强 (100–300% slider + effective % for the live engine)
// - 省电模式 (one tap: lowest quality + hide danmaku; restores on exit)
// - 全屏时钟位置 (tap cycles the four corners; the clock itself
//   also cycles on tap)
// - 录制 (start/stop + 录制中心 entry)
// - 多画面同看 (opens the 2/4-way page with this room first)
// - 系统画中画 (per-engine verdict table — honest, no dead button)

import 'package:flutter/material.dart';

import '../../../../core/player/kernel/player_engine.dart';
import '../../../../core/theme/hao_themes.dart';
import '../../../../core/theme/haptics.dart';
import '../../../../widgets/hao_slider.dart';
import '../../../../widgets/native_switch.dart';
import '../live_audio_sleep.dart';
import '../live_pip_support.dart';
import '../live_volume_boost.dart';
import 'playback/live_fullscreen_clock.dart';

class LiveRoomToolsSheet extends StatelessWidget {
  const LiveRoomToolsSheet({
    super.key,
    required this.audioOnly,
    required this.onAudioOnlyChanged,
    required this.sleep,
    required this.onSleepChanged,
    required this.boostPct,
    required this.onBoostChanged,
    required this.engine,
    required this.baseVolume,
    required this.powerSaving,
    required this.onPowerSavingChanged,
    required this.isRecording,
    required this.onToggleRecording,
    required this.onOpenMultiView,
    required this.onOpenRecordingCenter,
    required this.clockCorner,
    required this.onClockCornerChanged,
  });

  final bool audioOnly;
  final ValueChanged<bool> onAudioOnlyChanged;

  final LiveSleepDuration sleep;
  final ValueChanged<LiveSleepDuration> onSleepChanged;

  final int boostPct;
  final ValueChanged<int> onBoostChanged;
  final PlayerEngine engine;
  final double baseVolume;

  final bool powerSaving;
  final ValueChanged<bool> onPowerSavingChanged;

  final bool isRecording;
  final VoidCallback onToggleRecording;

  final VoidCallback onOpenMultiView;
  final VoidCallback onOpenRecordingCenter;

  final LiveClockCorner clockCorner;
  final ValueChanged<LiveClockCorner> onClockCornerChanged;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final effective = effectiveBoostPct(
      baseVolume: baseVolume,
      boostPct: boostPct,
      engine: engine,
    );
    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceSolid,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                '直播工具',
                style: TextStyle(
                  shadows: HaoTheme.legibilityShadows(context),
                  color: theme.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            HaoSwitchRow(
              title: '纯音频模式',
              subtitle: engine == PlayerEngine.mediaKit
                  ? '只听声音不看画面，省流量省电'
                  : '当前内核 ${engine.displayName} 不支持纯音频（仅 MPV 可用）',
              value: audioOnly,
              onChanged: onAudioOnlyChanged,
            ),
            ListTile(
              title: Text(
                '定时关闭',
                style: TextStyle(color: theme.textPrimary),
              ),
              subtitle: Text(
                sleep == LiveSleepDuration.off
                    ? '关闭后到点自动暂停'
                    : '已设 ${sleep.label}，到点自动暂停',
                style: TextStyle(color: theme.textSecondary),
              ),
              trailing: DropdownButton<LiveSleepDuration>(
                value: sleep,
                underline: const SizedBox.shrink(),
                items: LiveSleepDuration.values
                    .map(
                      (d) => DropdownMenuItem(value: d, child: Text(d.label)),
                    )
                    .toList(),
                onChanged: (d) {
                  if (d != null) onSleepChanged(d);
                },
              ),
            ),
            ListTile(
              title: Text(
                '音量增强',
                style: TextStyle(color: theme.textPrimary),
              ),
              subtitle: Text(
                boostPct <= 100
                    ? '关闭（100%）'
                    : '已增强到 $boostPct%，实际生效 $effective%（${engine.displayName}上限）',
                style: TextStyle(color: theme.textSecondary),
              ),
              trailing: SizedBox(
                width: 160,
                child: Row(
                  children: [
                    Expanded(
                      child: HaoSlider(
                        value: boostPct.toDouble(),
                        min: 100,
                        max: 300,
                        divisions: 8,
                        label: '$boostPct%',
                        activeColor: theme.accent,
                        onChanged: (v) => onBoostChanged(v.round()),
                        onChangeEnd: (v) =>
                            HaoHaptics.sliderEnd(v, 100, 300),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text(
                        '$boostPct%',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          shadows: HaoTheme.legibilityShadows(context),
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            HaoSwitchRow(
              title: '省电模式',
              subtitle: '一键切最低清晰度 + 隐藏弹幕；关闭后恢复原清晰度',
              value: powerSaving,
              onChanged: onPowerSavingChanged,
            ),
            ListTile(
              title: Text(
                '全屏时钟位置',
                style: TextStyle(color: theme.textPrimary),
              ),
              subtitle: Text(
                '当前：${clockCorner.label}（点全屏里的时钟也可切换）',
                style: TextStyle(color: theme.textSecondary),
              ),
              trailing: TextButton(
                onPressed: () => onClockCornerChanged(clockCorner.next),
                child: Text('换到${clockCorner.next.label}'),
              ),
            ),
            ListTile(
              leading: Icon(
                shadows: HaoTheme.legibilityShadows(context),
                isRecording ? Icons.stop_circle_outlined : Icons.fiber_manual_record_outlined,
                color: isRecording ? theme.liveRed : theme.textPrimary,
              ),
              title: Text(
                isRecording ? '停止录制' : '开始录制',
                style: TextStyle(color: theme.textPrimary),
              ),
              subtitle: Text(
                isRecording ? '正在录制到本地…' : '把当前直播流存到本地（FLV/HLS 原流）',
                style: TextStyle(color: theme.textSecondary),
              ),
              onTap: onToggleRecording,
            ),
            ListTile(
              leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.folder_outlined, color: theme.textPrimary),
              title: Text(
                '录制中心',
                style: TextStyle(color: theme.textPrimary),
              ),
              subtitle: Text(
                '查看、分享、删除本地录制',
                style: TextStyle(color: theme.textSecondary),
              ),
              onTap: onOpenRecordingCenter,
            ),
            ListTile(
              leading: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.grid_view_outlined, color: theme.textPrimary),
              title: Text(
                '多画面同看',
                style: TextStyle(color: theme.textPrimary),
              ),
              subtitle: Text(
                '2/4 路同看，点画面切换出声',
                style: TextStyle(color: theme.textSecondary),
              ),
              onTap: onOpenMultiView,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '系统画中画',
                style: TextStyle(
                  shadows: HaoTheme.legibilityShadows(context),
                  color: theme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final e in PlayerEngine.values)
              ListTile(
                dense: true,
                leading: Icon(
                  shadows: HaoTheme.legibilityShadows(context),
                  pipSupportFor(e).verdict == LivePipVerdict.needsBackendWiring
                      ? Icons.picture_in_picture_alt_outlined
                      : Icons.picture_in_picture_outlined,
                  color: theme.textMuted,
                  size: 20,
                ),
                title: Text(
                  e.displayName,
                  style: TextStyle(
                    shadows: HaoTheme.legibilityShadows(context),
                    color: theme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  pipSupportFor(e).reason,
                  style: TextStyle(
                    shadows: HaoTheme.legibilityShadows(context),
                    color: theme.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
