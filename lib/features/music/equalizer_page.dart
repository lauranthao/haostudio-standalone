// Equalizer page — stage 3.
//
// Structure + numbers copied from Beans `EqualizerSettingsView`
// (ProfileView.swift:3017-3430):
//  - page: horizontal padding 16, top 12, bottom 32, cards spaced 14
//  - response preview (EqualizerResponseView): height 108, radius 12,
//    5 grid dividers, curve stroke 2.2 round caps/joins, fill gradient
//    (accent 0.22 -> 0.02), bottom labels 31 Hz / 1 kHz / 16 kHz (10pt)
//  - every card: glass, radius 20 (HaoRadius.panel; Beans uses 18,
//    mapped to the app token so all cards share one radius), padding 14
//  - enable toggle: title 15 semibold + subtitle 11, note 11
//  - preamp slider: -12..+12 step 0.5, value label 12 semibold,
//    scale labels 10pt (-12 / 不增益 / +12)
//  - preset card: title 14 semibold, current-preset Menu (capsule
//    height 31, h padding 11, chevron.up.chevron.down 10 semibold),
//    3-column grid of preset capsules (height 30, font 11.5, selected
//    fill accent 0.14 + stroke accent 0.42 / 0.8pt), custom presets
//    list, save button (height 34, radius 10) + reset icon button
//    (42x34, radius 10)
//  - band rows: freq label 13 medium, dB value 12 semibold (accent
//    when non-zero), slider -12..+12 step 0.5, scale -12 / 0 / +12
//    (10pt), dividers between rows
//  - toolbar 完成 dismisses (Beans .confirmationAction Done)
//
// Differences from Beans, with reasons:
//  - Accent is the theme accent (black/gold/teal per theme), not
//    Beans' amber — our themes own the accent (stage-1 convention).
//  - Sliders are vertical list rows (one per band), not vertical
//    faders: Beans' own page uses the same horizontal-slider rows
//    (equalizerBandRow), so this IS Beans' layout, not a redesign.
//  - No blue, no purple anywhere; all colours come from the theme
//    system (4 themes x light/dark), so every combination stays
//    readable.

import '../../core/theme/hao_radius.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../widgets/hao_pressable.dart';
import '../../widgets/native_switch.dart';

import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../services/music/autoeq_presets.dart';
import '../../services/music/equalizer_store.dart';
import '../../widgets/glass_dialog.dart';
import '../../widgets/hao_nav_bar.dart';
import '../../widgets/hao_slider.dart';

class EqualizerPage extends StatelessWidget {
  const EqualizerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = EqualizerStore.ensure();
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => Scaffold(
        appBar: HaoNavBar(
          title: '均衡器',
          actions: [HaoNavBarTextButton(label: '完成', onPressed: () => Navigator.of(context).pop())],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            _ResponseCard(store: store),
            const SizedBox(height: 14),
            _ControlCard(store: store),
            const SizedBox(height: 14),
            _PresetCard(store: store),
            const SizedBox(height: 14),
            _AutoEqCard(store: store),
            const SizedBox(height: 14),
            _BandsCard(store: store),
          ],
        ),
      ),
    );
  }
}

/// Beans `EqualizerResponseView`: curve of responseValues
/// (gains + preamp*0.35, clamped +-12), y = height*(1-(v+12)/24).
class _ResponseCard extends StatelessWidget {
  const _ResponseCard({required this.store});

  final EqualizerStore store;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassCard(
      radius: HaoRadius.panel,
      quality: GlassCardQuality.standard,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '频响预览',
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '拖动下方频段，实时塑造声音',
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(shadows: HaoTheme.legibilityShadows(context), Icons.graphic_eq, size: 18, color: theme.accent),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 108,
            child: CustomPaint(
              painter: _ResponsePainter(
                values: store.responseValues,
                accent: theme.accent,
                grid: theme.textSecondary.withValues(alpha: 0.12),
              ),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(HaoRadius.large),
                  color: theme.textPrimary.withValues(alpha: 0.035),
                  border: Border.all(
                    color: theme.textPrimary.withValues(alpha: 0.07),
                    width: 0.7,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('31 Hz', style: _scaleStyle(theme, HaoTheme.legibilityShadows(context))),
              const Spacer(),
              Text('1 kHz', style: _scaleStyle(theme, HaoTheme.legibilityShadows(context))),
              const Spacer(),
              Text('16 kHz', style: _scaleStyle(theme, HaoTheme.legibilityShadows(context))),
            ],
          ),
        ],
      ),
    );
  }

  static TextStyle _scaleStyle(HaoTheme theme, List<Shadow> shadows) =>
      TextStyle(color: theme.textSecondary, fontSize: 10, shadows: shadows);
}

class _ResponsePainter extends CustomPainter {
  _ResponsePainter({
    required this.values,
    required this.accent,
    required this.grid,
  });

  final List<double> values;
  final Color accent;
  final Color grid;

  double _y(double value, double height) =>
      height * (1 - (value + 12) / 24);

  @override
  void paint(Canvas canvas, Size size) {
    // 5 horizontal grid dividers (Beans VStack of Divider + Spacer).
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.5;
    for (var i = 0; i < 5; i++) {
      final y = size.height * (i + 1) / 6;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    if (values.isEmpty) return;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = _y(values[i], size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          colors: [accent.withValues(alpha: 0.22), accent.withValues(alpha: 0.02)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_ResponsePainter old) =>
      old.values != values || old.accent != accent;
}

/// Beans `controlCard`: enable toggle + note + preamp slider.
class _ControlCard extends StatelessWidget {
  const _ControlCard({required this.store});

  final EqualizerStore store;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassCard(
      radius: HaoRadius.panel,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 24,
                child: Icon(shadows: HaoTheme.legibilityShadows(context),
                  Icons.graphic_eq,
                  size: 16,
                  color: theme.accent,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '启用均衡器',
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '播放时实时应用当前调节',
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              HaoNativeSwitch(
                value: store.enabled,
                onChanged: (value) {
                  HaoHaptics.select();
                  unawaited(store.setEnabled(value));
                },
                activeColor: theme.accent,
                semanticsLabel: '均衡器',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '均衡器仅处理 HAo Studio 当前播放的音乐，不影响其他 App。',
            style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary, fontSize: 11),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(
              height: 1,
              color: theme.textSecondary.withValues(alpha: 0.14),
            ),
          ),
          Row(
            children: [
              Text(
                '前级增益',
                style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                  color: theme.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                '${store.preampGain >= 0 ? '+' : ''}${store.preampGain.toStringAsFixed(1)} dB',
                style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                  color: store.preampGain.abs() > 0.01
                      ? theme.accent
                      : theme.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          _EqSlider(
            value: store.preampGain,
            onChanged: (v) => unawaited(store.setPreampGain(v)),
          ),
          Row(
            children: [
              Text('-12', style: _scaleStyle(theme, HaoTheme.legibilityShadows(context))),
              const Spacer(),
              Text('不增益', style: _scaleStyle(theme, HaoTheme.legibilityShadows(context))),
              const Spacer(),
              Text('+12', style: _scaleStyle(theme, HaoTheme.legibilityShadows(context))),
            ],
          ),
        ],
      ),
    );
  }

  static TextStyle _scaleStyle(HaoTheme theme, List<Shadow> shadows) =>
      TextStyle(color: theme.textSecondary.withValues(alpha: 0.75), fontSize: 10, shadows: shadows);
}

/// Beans `presetCard`: current-preset Menu + 3-column preset grid +
/// custom presets + save / reset.
class _PresetCard extends StatelessWidget {
  const _PresetCard({required this.store});

  final EqualizerStore store;

  /// Preset picker as an iOS action sheet (was a Material
  /// PopupMenuButton). Actions are built at open time, so the
  /// current-preset ✓ is read when the sheet opens, not at build.
  void _showPresetSheet(BuildContext context) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        actions: [
          for (final preset in EqualizerPreset.values)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                HaoHaptics.select();
                unawaited(store.applyPreset(preset));
              },
              child: Text(
                !store.isCustom && store.selectedPreset == preset
                    ? '✓ ${preset.displayName}'
                    : preset.displayName,
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: const Text('取消'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassCard(
      radius: HaoRadius.panel,
      quality: GlassCardQuality.standard,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '预设',
                style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                  color: theme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              HaoPressable(
                onTap: () {
                  HaoHaptics.tap();
                  _showPresetSheet(context);
                },
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  height: 31,
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: theme.textPrimary.withValues(alpha: 0.055),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        store.currentPresetName,
                        style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                          color: theme.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(shadows: HaoTheme.legibilityShadows(context),
                        CupertinoIcons.chevron_up_chevron_down,
                        size: 10,
                        color: theme.accent,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              mainAxisExtent: 30,
            ),
            itemCount: EqualizerPreset.values.length,
            itemBuilder: (context, index) {
              final preset = EqualizerPreset.values[index];
              final selected =
                  !store.isCustom && store.selectedPreset == preset;
              return Material(
                color: Colors.transparent,
                child: HaoPressable(
                  onTap: () {
                    HaoHaptics.select();
                    unawaited(store.applyPreset(preset));
                  },
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: selected
                          ? theme.accent.withValues(alpha: 0.14)
                          : theme.textPrimary.withValues(alpha: 0.035),
                      border: Border.all(
                        color: selected
                            ? theme.accent.withValues(alpha: 0.42)
                            : theme.textPrimary.withValues(alpha: 0.06),
                        width: 0.8,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      preset.displayName,
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                        color: selected ? theme.accent : theme.textPrimary,
                        fontSize: 11.5,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if (store.customPresets.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '我的预设',
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: theme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 7),
            for (final preset in store.customPresets)
              Row(
                children: [
                  Expanded(
                    child: HaoPressable(
                      onTap: () {
                        HaoHaptics.select();
                        unawaited(store.applyCustomPreset(preset));
                      },
                      child: Row(
                        children: [
                          Icon(shadows: HaoTheme.legibilityShadows(context),
                            store.selectedCustomPresetName == preset.name
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            size: 16,
                            color:
                                store.selectedCustomPresetName == preset.name
                                    ? theme.accent
                                    : theme.textSecondary,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              preset.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                                color: theme.textPrimary,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () =>
                        unawaited(store.deleteCustomPreset(preset)),
                    icon: Icon(shadows: HaoTheme.legibilityShadows(context),
                      Icons.delete_outline,
                      size: 12,
                      color: theme.textSecondary,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
                ],
              ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: HaoPressable(
                  onTap: () => _showSavePresetDialog(context, store),
                  borderRadius: BorderRadius.circular(HaoRadius.standard),
                  child: Container(
                    height: 34,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(HaoRadius.standard),
                      color: theme.textPrimary.withValues(alpha: 0.055),
                    ),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(shadows: HaoTheme.legibilityShadows(context),
                          Icons.download,
                          size: 14,
                          color: theme.accent,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '保存当前预设',
                          style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                            color: theme.accent,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              HaoPressable(
                onTap: () {
                  HaoHaptics.select();
                  unawaited(store.reset());
                },
                borderRadius: BorderRadius.circular(HaoRadius.standard),
                child: Container(
                  width: 42,
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(HaoRadius.standard),
                    color: theme.textPrimary.withValues(alpha: 0.055),
                  ),
                  child: Icon(shadows: HaoTheme.legibilityShadows(context),
                    Icons.refresh,
                    size: 13,
                    color: theme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showSavePresetDialog(
    BuildContext context,
    EqualizerStore store,
  ) async {
    final controller = TextEditingController(
      text: store.selectedCustomPresetName ?? '',
    );
    // Glass dialog, like every other dialog in the app (glass_dialog
    // rule): same shell, title 17 w700, actions right-aligned.
    final name = await showGlassDialog<String>(
      context,
      builder: (ctx) {
        final theme = HaoTheme.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '保存自定义预设',
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: theme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '保存当前频段和前级增益，之后可以一键恢复。',
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              style: TextStyle(
                color: theme.textPrimary,
                shadows: HaoTheme.legibilityShadows(ctx),
              ),
              decoration: InputDecoration(
                labelText: '预设名称',
                labelStyle: TextStyle(
                  shadows: HaoTheme.legibilityShadows(ctx),
                ),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(
                    '取消',
                    style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(controller.text),
                  child: Text('保存', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.accent)),
                ),
              ],
            ),
          ],
        );
      },
    );
    if (name != null) {
      final ok = await store.saveCustomPreset(name);
      if (ok && context.mounted) {
        HaoHaptics.select();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存预设')),
        );
      }
    }
  }
}

/// AutoEq headphone presets (build 29): one tap applies a
/// community AutoEq-style correction for that model through the
/// same native channel as any preset. The gains are approximations
/// mapped onto our 10 fixed bands — NOT per-unit measurements —
/// so the card says so, and any hand-tune afterwards clears the
/// AutoEq label (the gains are the truth, the name is only a label).
///
/// Crossfeed is deliberately absent: it needs L/R sample mixing
/// inside the native tap (HaoEqualizer.m), which is the native
/// group's file — no dead toggle is shipped here.
class _AutoEqCard extends StatelessWidget {
  const _AutoEqCard({required this.store});

  final EqualizerStore store;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassCard(
      radius: HaoRadius.panel,
      quality: GlassCardQuality.standard,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '耳机校准 · AutoEq',
                style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                  color: theme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (store.selectedAutoEqName != null)
                Text(
                  store.selectedAutoEqName!,
                  style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                    color: theme.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '社区校准近似值（非实测），仅作起点；觉得不对就直接调频段。',
            style: TextStyle(
              color: theme.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              mainAxisExtent: 34,
            ),
            itemCount: kAutoEqPresets.length,
            itemBuilder: (context, index) {
              final preset = kAutoEqPresets[index];
              final selected = store.selectedAutoEqName == preset.name;
              return Material(
                color: Colors.transparent,
                child: HaoPressable(
                  onTap: () {
                    HaoHaptics.select();
                    unawaited(store.applyAutoEqPreset(preset));
                  },
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: selected
                          ? theme.accent.withValues(alpha: 0.14)
                          : theme.textPrimary.withValues(alpha: 0.035),
                      border: Border.all(
                        color: selected
                            ? theme.accent.withValues(alpha: 0.42)
                            : theme.textPrimary.withValues(alpha: 0.06),
                        width: 0.8,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      preset.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                        color: selected ? theme.accent : theme.textPrimary,
                        fontSize: 12,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Beans `bandsCard`: one horizontal slider row per band.
class _BandsCard extends StatelessWidget {
  const _BandsCard({required this.store});

  final EqualizerStore store;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassCard(
      radius: HaoRadius.panel,
      quality: GlassCardQuality.standard,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '自定义调节',
            style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
              color: theme.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '范围 -12 dB 至 +12 dB',
            style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < EqualizerStore.bandFrequencies.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Divider(
                  height: 1,
                  color: theme.textSecondary.withValues(alpha: 0.14),
                ),
              ),
            _BandRow(store: store, index: i),
          ],
        ],
      ),
    );
  }
}

class _BandRow extends StatelessWidget {
  const _BandRow({required this.store, required this.index});

  final EqualizerStore store;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final gain = store.bandGains[index];
    return Column(
      children: [
        Row(
          children: [
            Text(
              EqualizerStore.frequencyLabel(
                EqualizerStore.bandFrequencies[index],
              ),
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: theme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Text(
              '${gain >= 0 ? '+' : ''}${gain.toStringAsFixed(1)} dB',
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: gain.abs() > 0.01 ? theme.accent : theme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _EqSlider(
          value: gain,
          onChanged: (v) => unawaited(store.setBandGain(index, v)),
        ),
        Row(
          children: [
            Text('-12', style: _scaleStyle(theme, HaoTheme.legibilityShadows(context))),
            const Spacer(),
            Text('0', style: _scaleStyle(theme, HaoTheme.legibilityShadows(context))),
            const Spacer(),
            Text('+12', style: _scaleStyle(theme, HaoTheme.legibilityShadows(context))),
          ],
        ),
      ],
    );
  }

  static TextStyle _scaleStyle(HaoTheme theme, List<Shadow> shadows) =>
      TextStyle(color: theme.textSecondary.withValues(alpha: 0.75), fontSize: 10, shadows: shadows);
}

/// Shared EQ slider: -12..+12, 0.5 dB steps (Beans step 0.5,
/// `.transaction { animation = nil }` — no animation while dragging).
class _EqSlider extends StatelessWidget {
  const _EqSlider({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        activeTrackColor: theme.accent,
        inactiveTrackColor: theme.accentSoft,
        thumbColor: theme.accent,
        overlayColor: theme.accentSoft,
      ),
      child: HaoSlider(
        value: value.clamp(-12, 12),
        min: -EqualizerStore.maximumGain,
        max: EqualizerStore.maximumGain,
        divisions: 48,
        activeColor: theme.accent,
        onChanged: onChanged,
        // N-13: light tap on release, click at either end.
        onChangeEnd: (v) => HaoHaptics.sliderEnd(
          v,
          -EqualizerStore.maximumGain,
          EqualizerStore.maximumGain,
        ),
      ),
    );
  }
}
