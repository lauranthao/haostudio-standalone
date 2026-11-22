// VOD in-player settings panel (build 29, D 组).
//
// Pure Live-style control-bar settings entry → bottom sheet. VOD
// ONLY: every row here is a VOD feature — no live-only control
// (live has no speed / super-resolution / dialogue boost, and this
// panel never offers them).
//
// The sheet is dumb: it takes the current values + callbacks and
// owns no Hive keys. The player page applies each change to the
// SAME Hive key the settings page reads (one key, two writers, no
// second state) and to the running session where the backend
// supports it — so a change takes effect on the current playback
// immediately, and the settings page reads the same value after.
//
// Immediate vs next-open (same split as Settings → 影视播放):
// - Immediate: speed, double-tap step, auto-next, fit, skip mode,
//   dialogue boost, audio-only, subtitle delay / appearance,
//   dual-subtitle picker, danmaku master + display, occlusion,
//   Anime4K super-resolution, interpolation, SDR→HDR (b30: the
//   trio is set on the running mpv player at once — no reopen),
//   DV P8 downgrade on AVPlayer (re-opens at the current position),
//   low-memory mode (re-opens at the current position).
// - Still next open: nothing in this panel. The engine picker
//   (Settings only) stays next-open by design — a kernel choice
//   for the next session, not a live effect.
// The trio (super-res / interpolation / SDR→HDR) is mutually
// exclusive in display too: a row locked by another trio switch
// renders greyed out and cannot be tapped (its stored value is
// never cleared — same rule as Settings).

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../widgets/player_settings_sheet.dart';

/// Subtitle-delay label: "+0.5 秒" / "0.0 秒" / "-0.5 秒".
String formatVodSubtitleDelayLabel(double seconds) {
  final sign = seconds > 0 ? '+' : '';
  return '$sign${seconds.toStringAsFixed(1)} 秒';
}

/// Current VOD settings + the callbacks that apply a change.
/// [onSuperResolutionChanged] / [onInterpolationChanged] /
/// [onSdrToHdrChanged] are null when that trio row is locked by
/// another trio switch being on.
class VodPlayerSettings {
  const VodPlayerSettings({
    required this.rateLabel,
    required this.onRateCycle,
    required this.doubleTapSeekSeconds,
    required this.onDoubleTapSeekCycle,
    required this.autoNext,
    required this.onAutoNextChanged,
    required this.videoFitLabel,
    required this.onVideoFitCycle,
    required this.skipIntroLabel,
    required this.onSkipIntroCycle,
    required this.dialogueBoost,
    required this.onDialogueBoostChanged,
    required this.audioOnly,
    required this.onAudioOnlyChanged,
    required this.superResolution,
    required this.superResolutionLocked,
    required this.onSuperResolutionChanged,
    required this.interpolation,
    required this.interpolationLocked,
    required this.onInterpolationChanged,
    required this.sdrToHdr,
    required this.sdrToHdrLocked,
    required this.onSdrToHdrChanged,
    required this.dvP8Downgrade,
    required this.onDvP8Changed,
    required this.lowMemoryLabel,
    required this.onLowMemoryCycle,
    required this.subtitleDelay,
    required this.onSubtitleDelayChanged,
    required this.subtitleFontLabel,
    required this.onSubtitleFontCycle,
    required this.subtitleColorLabel,
    required this.onSubtitleColorCycle,
    required this.subtitlePositionLabel,
    required this.onSubtitlePositionCycle,
    required this.dualSubtitleOn,
    required this.onDualSubtitleTap,
    required this.danmakuEnabled,
    required this.onDanmakuEnabledChanged,
    required this.danmakuVisible,
    required this.onDanmakuVisibleChanged,
    required this.danmakuOcclusionAvoidance,
    required this.onDanmakuOcclusionChanged,
  });

  /// Current playback rate, e.g. "1.0x" (倍速记忆 = this persisted rate).
  final String rateLabel;
  final VoidCallback onRateCycle;

  /// Double-tap seek step in seconds (5/10/15/30/60).
  final int doubleTapSeekSeconds;
  final VoidCallback onDoubleTapSeekCycle;

  final bool autoNext;
  final ValueChanged<bool> onAutoNextChanged;

  /// Picture fit label, e.g. "自动".
  final String videoFitLabel;
  final VoidCallback onVideoFitCycle;

  /// Skip-intro mode label, e.g. "关" / "手动" / "自动延时 3 秒".
  final String skipIntroLabel;
  final VoidCallback onSkipIntroCycle;

  final bool dialogueBoost;
  final ValueChanged<bool> onDialogueBoostChanged;

  final bool audioOnly;
  final ValueChanged<bool> onAudioOnlyChanged;

  final bool superResolution;
  final bool superResolutionLocked;
  final ValueChanged<bool>? onSuperResolutionChanged;

  final bool interpolation;
  final bool interpolationLocked;
  final ValueChanged<bool>? onInterpolationChanged;

  final bool sdrToHdr;
  final bool sdrToHdrLocked;
  final ValueChanged<bool>? onSdrToHdrChanged;

  final bool dvP8Downgrade;
  final ValueChanged<bool> onDvP8Changed;

  /// Low-memory mode label, e.g. "自动".
  final String lowMemoryLabel;
  final VoidCallback onLowMemoryCycle;

  /// Subtitle time offset in seconds (±10, 0.1 steps).
  final double subtitleDelay;

  /// Called with the NEW absolute delay (already clamped to ±10).
  final ValueChanged<double> onSubtitleDelayChanged;

  /// Subtitle appearance tier labels, e.g. "标准" / "白色" / "底部".
  final String subtitleFontLabel;
  final VoidCallback onSubtitleFontCycle;
  final String subtitleColorLabel;
  final VoidCallback onSubtitleColorCycle;
  final String subtitlePositionLabel;
  final VoidCallback onSubtitlePositionCycle;

  /// A second subtitle track is active (MPV `secondary-sid`).
  final bool dualSubtitleOn;

  /// Opens the track sheet (the second-subtitle picker lives there).
  final VoidCallback onDualSubtitleTap;

  /// VOD danmaku master gate (DanmakuSettings 'vod' key, default OFF).
  final bool danmakuEnabled;
  final ValueChanged<bool> onDanmakuEnabledChanged;

  /// Per-episode danmaku display (top-bar toggle state).
  final bool danmakuVisible;
  final ValueChanged<bool> onDanmakuVisibleChanged;

  /// Danmaku person-occlusion avoidance (MPV only, default off).
  final bool danmakuOcclusionAvoidance;
  final ValueChanged<bool> onDanmakuOcclusionChanged;
}

/// The VOD settings sheet (content only — the caller opens it in a
/// modal bottom sheet with a StatefulBuilder refresh, like the
/// episode / track sheets).
class VodPlayerSettingsSheet extends StatelessWidget {
  const VodPlayerSettingsSheet({super.key, required this.settings});

  final VodPlayerSettings settings;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final s = settings;
    return GlassSheetBackground(
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  '播放设置',
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.02,
                  ),
                ),
              ),
              const PlayerSettingsSectionTitle('播放'),
              PlayerSettingsCycleRow(
                key: const ValueKey('vod_setting_rate'),
                title: '倍速',
                subtitle: '记住当前倍速，下次打开沿用',
                valueLabel: s.rateLabel,
                onTap: s.onRateCycle,
              ),
              PlayerSettingsCycleRow(
                key: const ValueKey('vod_setting_double_tap'),
                title: '双击快进秒数',
                subtitle: '双击左 / 右半屏快退 / 快进',
                valueLabel: '${s.doubleTapSeekSeconds} 秒',
                onTap: s.onDoubleTapSeekCycle,
              ),
              PlayerSettingsSwitchRow(
                key: const ValueKey('vod_setting_auto_next'),
                title: '自动连播下一集',
                value: s.autoNext,
                onChanged: s.onAutoNextChanged,
              ),
              PlayerSettingsCycleRow(
                key: const ValueKey('vod_setting_fit'),
                title: '画面比例',
                subtitle: '双指张开去黑边，捏合恢复完整画面',
                valueLabel: s.videoFitLabel,
                onTap: s.onVideoFitCycle,
              ),
              PlayerSettingsCycleRow(
                key: const ValueKey('vod_setting_skip'),
                title: '跳过片头片尾',
                valueLabel: s.skipIntroLabel,
                onTap: s.onSkipIntroCycle,
              ),
              const PlayerSettingsSectionTitle('声音'),
              PlayerSettingsSwitchRow(
                key: const ValueKey('vod_setting_dialogue'),
                title: '对白增强',
                subtitle: '对白更清楚，大声不炸 · 仅 MPV',
                value: s.dialogueBoost,
                onChanged: s.onDialogueBoostChanged,
              ),
              PlayerSettingsSwitchRow(
                key: const ValueKey('vod_setting_audio_only'),
                title: '纯音频播放',
                subtitle: '只听声音，后台继续播',
                value: s.audioOnly,
                onChanged: s.onAudioOnlyChanged,
              ),
              const PlayerSettingsSectionTitle('画面增强'),
              PlayerSettingsSwitchRow(
                key: const ValueKey('vod_setting_super_res'),
                title: 'Anime4K 超分',
                subtitle: s.superResolutionLocked
                    ? '与插帧 / SDR 转 HDR 互斥，已锁定 · 仅 MPV，立即生效'
                    : '仅 MPV，立即生效',
                value: s.superResolution,
                onChanged: s.onSuperResolutionChanged,
              ),
              PlayerSettingsSwitchRow(
                key: const ValueKey('vod_setting_interpolation'),
                title: '插帧',
                subtitle: s.interpolationLocked
                    ? '与超分 / SDR 转 HDR 互斥，已锁定 · 仅 MPV，立即生效'
                    : '仅 MPV，立即生效',
                value: s.interpolation,
                onChanged: s.onInterpolationChanged,
              ),
              PlayerSettingsSwitchRow(
                key: const ValueKey('vod_setting_sdr_hdr'),
                title: 'SDR 转 HDR',
                subtitle: s.sdrToHdrLocked
                    ? '与超分 / 插帧互斥，已锁定 · 仅 MPV，立即生效'
                    : '仅 MPV，立即生效',
                value: s.sdrToHdr,
                onChanged: s.onSdrToHdrChanged,
              ),
              PlayerSettingsSwitchRow(
                key: const ValueKey('vod_setting_dv_p8'),
                title: '杜比视界 Profile 8 降级 HDR',
                subtitle: 'AVPlayer 在播时立即换内核',
                value: s.dvP8Downgrade,
                onChanged: s.onDvP8Changed,
              ),
              PlayerSettingsCycleRow(
                key: const ValueKey('vod_setting_low_memory'),
                title: '低内存模式',
                subtitle: '立即生效（当前这集重开，进度保留）',
                valueLabel: s.lowMemoryLabel,
                onTap: s.onLowMemoryCycle,
              ),
              const PlayerSettingsSectionTitle('字幕'),
              PlayerSettingsStepperRow(
                key: const ValueKey('vod_setting_sub_delay'),
                title: '字幕时间偏移',
                subtitle: '立即生效 · ±10 秒，步进 0.1 秒',
                valueLabel: formatVodSubtitleDelayLabel(s.subtitleDelay),
                decrementKey: const ValueKey('vod_setting_sub_delay_minus'),
                incrementKey: const ValueKey('vod_setting_sub_delay_plus'),
                onDecrement: () => s.onSubtitleDelayChanged(
                  (s.subtitleDelay - 0.1).clamp(-10.0, 10.0),
                ),
                onIncrement: () => s.onSubtitleDelayChanged(
                  (s.subtitleDelay + 0.1).clamp(-10.0, 10.0),
                ),
              ),
              PlayerSettingsCycleRow(
                key: const ValueKey('vod_setting_sub_font'),
                title: '字幕字号',
                valueLabel: s.subtitleFontLabel,
                onTap: s.onSubtitleFontCycle,
              ),
              PlayerSettingsCycleRow(
                key: const ValueKey('vod_setting_sub_color'),
                title: '字幕颜色',
                valueLabel: s.subtitleColorLabel,
                onTap: s.onSubtitleColorCycle,
              ),
              PlayerSettingsCycleRow(
                key: const ValueKey('vod_setting_sub_position'),
                title: '字幕位置',
                valueLabel: s.subtitlePositionLabel,
                onTap: s.onSubtitlePositionCycle,
              ),
              PlayerSettingsCycleRow(
                key: const ValueKey('vod_setting_dual_subtitle'),
                title: '双字幕',
                subtitle: '点按选择第二字幕轨道',
                valueLabel: s.dualSubtitleOn ? '开' : '关',
                onTap: s.onDualSubtitleTap,
              ),
              const PlayerSettingsSectionTitle('弹幕'),
              PlayerSettingsSwitchRow(
                key: const ValueKey('vod_setting_danmaku'),
                title: '影视弹幕',
                subtitle: '关后本片不再加载弹幕',
                value: s.danmakuEnabled,
                onChanged: s.onDanmakuEnabledChanged,
              ),
              PlayerSettingsSwitchRow(
                key: const ValueKey('vod_setting_danmaku_visible'),
                title: '显示弹幕',
                subtitle: '本集内显示 / 隐藏弹幕',
                value: s.danmakuVisible,
                onChanged: s.onDanmakuVisibleChanged,
              ),
              PlayerSettingsSwitchRow(
                key: const ValueKey('vod_setting_occlusion'),
                title: '弹幕防遮挡（人物）',
                subtitle: '弹幕避开画面中的人物 · 仅 MPV',
                value: s.danmakuOcclusionAvoidance,
                onChanged: s.onDanmakuOcclusionChanged,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
