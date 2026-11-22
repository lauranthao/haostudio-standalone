// Live in-player settings panel (build 29, D 组).
//
// Pure Live-style control-bar settings entry → bottom sheet. LIVE
// ONLY: every row here is a live feature — no speed, no
// super-resolution, no dialogue boost (live has none of those).
//
// The sheet is dumb: it takes the current values + callbacks and
// owns no Hive keys. The room page applies each change to the SAME
// Hive key the settings page reads (DanmakuSettings keys / the
// persisted boost %) or to the same room state the tools sheet
// writes (pure-audio / sleep / power-saving) — one key, one room
// state, no second copy — so a change takes effect on the current
// room immediately, and the settings page reads the same value
// after.
//
// Rows and where they land:
// - 画质: cycles the room's quality via the same _switchQuality
//   (persist-after-confirmed-open + restore-on-failure = 画质切换保真).
// - 弹幕总开关 + 4 个过滤开关 + 防遮挡: DanmakuSettings keys — the
//   same keys DanmakuSettingsPage reads/writes; the room's danmaku
//   listener re-reads them live (no restart, no leaving the room).
// - 纯音频 / 定时关闭 / 音量增强 / 省电模式: the same room state
//   the tools sheet displays (I 组工具表不动，本面板只是第二个入口).
// - 移动网降档: opt-out switch (key hao_live_cellular_downgrade,
//   default ON = 今天的行为）；关后移动数据下也不再自动降画质。
//   Settings 里没有直播分组，所以这个键没有设置页行——面板行如实说明。
//
// NOT here, on purpose: 关注刷新 (the follow-refresh state machine
// lives on the follows page — there is no room switch and no Hive
// key for it, so a panel toggle would be fake).

import 'package:flutter/material.dart';

import '../../../../core/theme/hao_themes.dart';
import '../../../../widgets/player_settings_sheet.dart';
import '../../live_audio_sleep.dart';

/// Current live settings + the callbacks that apply a change.
class LivePlayerSettings {
  const LivePlayerSettings({
    required this.qualityLabel,
    required this.canCycleQuality,
    required this.onQualityCycle,
    required this.danmakuEnabled,
    required this.onDanmakuEnabledChanged,
    required this.similarityEnabled,
    required this.onSimilarityChanged,
    required this.blockEmoteOnly,
    required this.onBlockEmoteChanged,
    required this.blockLong,
    required this.onBlockLongChanged,
    required this.douyuBotFilter,
    required this.onDouyuBotChanged,
    required this.danmakuOcclusionAvoidance,
    required this.onDanmakuOcclusionChanged,
    required this.audioOnly,
    required this.onAudioOnlyChanged,
    required this.sleep,
    required this.onSleepCycle,
    required this.boostPct,
    required this.effectiveBoostPct,
    required this.onBoostChanged,
    required this.powerSaving,
    required this.onPowerSavingChanged,
    required this.cellularDowngrade,
    required this.onCellularDowngradeChanged,
  });

  /// Current quality label, e.g. "原画" ('' when unknown).
  final String qualityLabel;

  /// False when the room offers < 2 qualities (nothing to cycle).
  final bool canCycleQuality;
  final VoidCallback onQualityCycle;

  /// Danmaku master switch for this platform (DanmakuSettings key).
  final bool danmakuEnabled;
  final ValueChanged<bool> onDanmakuEnabledChanged;

  /// Danmaku content filters (DanmakuSettings keys, same as 弹幕设置).
  final bool similarityEnabled;
  final ValueChanged<bool> onSimilarityChanged;
  final bool blockEmoteOnly;
  final ValueChanged<bool> onBlockEmoteChanged;
  final bool blockLong;
  final ValueChanged<bool> onBlockLongChanged;
  final bool douyuBotFilter;
  final ValueChanged<bool> onDouyuBotChanged;

  /// Danmaku person-occlusion avoidance (MPV only, default off).
  final bool danmakuOcclusionAvoidance;
  final ValueChanged<bool> onDanmakuOcclusionChanged;

  /// Pure-audio mode (room state, same as the tools sheet).
  final bool audioOnly;
  final ValueChanged<bool> onAudioOnlyChanged;

  /// Sleep timer (room state, same as the tools sheet).
  final LiveSleepDuration sleep;
  final VoidCallback onSleepCycle;

  /// Volume boost percent (100..300, persisted) + the effective %
  /// actually heard on this engine (honest label).
  final int boostPct;
  final int effectiveBoostPct;

  /// Called with the NEW boost percent (already clamped 100..300).
  final ValueChanged<int> onBoostChanged;

  /// Power-saving mode (room state, same as the tools sheet).
  final bool powerSaving;
  final ValueChanged<bool> onPowerSavingChanged;

  /// Cellular entry downgrade (default ON = today's behaviour).
  final bool cellularDowngrade;
  final ValueChanged<bool> onCellularDowngradeChanged;
}

/// The live settings sheet (content only — the caller opens it in a
/// modal bottom sheet with a StatefulBuilder refresh, like the
/// tools sheet).
class LivePlayerSettingsSheet extends StatelessWidget {
  const LivePlayerSettingsSheet({super.key, required this.settings});

  final LivePlayerSettings settings;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final s = settings;
    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceSolid,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      // Transparent Material between the fill and the content: the
      // sheet holds ListTiles, and a ListTile paints its ink on the
      // nearest Material ancestor — without this the Container fill
      // hides the ripples (debug assertion in tests, dead taps
      // visually on device). Same fix as GlassSheetBackground.
      child: Material(
        color: Colors.transparent,
        child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                '直播设置',
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const PlayerSettingsSectionTitle('画质'),
            PlayerSettingsCycleRow(
              key: const ValueKey('live_setting_quality'),
              title: '画质',
              subtitle: '切换失败自动恢复原画质，只保存成功播出的画质',
              valueLabel: s.qualityLabel.isEmpty ? '清晰度' : s.qualityLabel,
              onTap: s.canCycleQuality ? s.onQualityCycle : null,
            ),
            const PlayerSettingsSectionTitle('弹幕'),
            PlayerSettingsSwitchRow(
              key: const ValueKey('live_setting_danmaku'),
              title: '弹幕',
              subtitle: '关后本房间不再加载弹幕',
              value: s.danmakuEnabled,
              onChanged: s.onDanmakuEnabledChanged,
            ),
            PlayerSettingsSwitchRow(
              key: const ValueKey('live_setting_similarity'),
              title: '过滤相似弹幕',
              subtitle: '刷屏的重复弹幕只显示一条',
              value: s.similarityEnabled,
              onChanged: s.onSimilarityChanged,
            ),
            PlayerSettingsSwitchRow(
              key: const ValueKey('live_setting_block_emote'),
              title: '屏蔽纯表情弹幕',
              value: s.blockEmoteOnly,
              onChanged: s.onBlockEmoteChanged,
            ),
            PlayerSettingsSwitchRow(
              key: const ValueKey('live_setting_block_long'),
              title: '屏蔽超长弹幕',
              value: s.blockLong,
              onChanged: s.onBlockLongChanged,
            ),
            PlayerSettingsSwitchRow(
              key: const ValueKey('live_setting_douyu_bot'),
              title: '斗鱼疑似机器人过滤',
              subtitle: '仅斗鱼房间生效',
              value: s.douyuBotFilter,
              onChanged: s.onDouyuBotChanged,
            ),
            PlayerSettingsSwitchRow(
              key: const ValueKey('live_setting_occlusion'),
              title: '弹幕防遮挡（人物）',
              subtitle: '弹幕避开画面中的人物 · 仅 MPV 全屏',
              value: s.danmakuOcclusionAvoidance,
              onChanged: s.onDanmakuOcclusionChanged,
            ),
            const PlayerSettingsSectionTitle('播放'),
            PlayerSettingsSwitchRow(
              key: const ValueKey('live_setting_audio_only'),
              title: '纯音频模式',
              subtitle: '只听声音不看画面，省流量省电 · 仅 MPV',
              value: s.audioOnly,
              onChanged: s.onAudioOnlyChanged,
            ),
            PlayerSettingsCycleRow(
              key: const ValueKey('live_setting_sleep'),
              title: '定时关闭',
              subtitle: '到点自动暂停直播',
              valueLabel: s.sleep.label,
              onTap: s.onSleepCycle,
            ),
            PlayerSettingsStepperRow(
              key: const ValueKey('live_setting_boost'),
              title: '音量增强',
              subtitle: s.boostPct <= 100
                  ? '未增强'
                  : '已增强到 ${s.boostPct}%，实际生效 ${s.effectiveBoostPct}%',
              valueLabel: '${s.boostPct}%',
              decrementKey: const ValueKey('live_setting_boost_minus'),
              incrementKey: const ValueKey('live_setting_boost_plus'),
              onDecrement: () =>
                  s.onBoostChanged((s.boostPct - 25).clamp(100, 300)),
              onIncrement: () =>
                  s.onBoostChanged((s.boostPct + 25).clamp(100, 300)),
            ),
            PlayerSettingsSwitchRow(
              key: const ValueKey('live_setting_power_saving'),
              title: '省电模式',
              subtitle: '最低画质 + 隐藏弹幕，退出时恢复原画质',
              value: s.powerSaving,
              onChanged: s.onPowerSavingChanged,
            ),
            PlayerSettingsSwitchRow(
              key: const ValueKey('live_setting_cellular_downgrade'),
              title: '移动网自动降画质',
              subtitle: '移动数据下进房间自动降至超清及以下；关后保持首选画质 · 下次进房间生效',
              value: s.cellularDowngrade,
              onChanged: s.onCellularDowngradeChanged,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
      ),
    );
  }
}
