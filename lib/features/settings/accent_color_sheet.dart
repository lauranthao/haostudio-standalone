// Accent-colour sheet (settings → 自定义强调色).
//
// Reference: the colour board in the design screenshots (dark glass
// bottom sheet) — rebuilt on our own glass + theme so it works in
// all 4 themes x light/dark:
// - top row: × close (left), dropper (right);
// - segments: 网格 / 光谱 / 滑块 (default grid);
// - grid: a grayscale row (white → black) over a hue grid (each
//   column dark → light top to bottom); tap a cell to pick;
// - spectrum: a hue strip + a saturation/value square;
// - sliders: H / S / V gradient sliders;
// - opacity: a checkerboard-backed gradient slider + %;
// - bottom: a large preview square + 5 preset dots + a + button
//   (adds the current colour to the presets, persisted; long-press
//   a custom preset to delete it, the 5 defaults cannot be deleted).
//
// Every pick applies IMMEDIATELY — to the tab-bar selected colour
// (TabBarAccentController, with the picked opacity) AND to the
// app-wide accent (ThemeController, opaque form): switches,
// selected chips, play buttons, progress and highlights all follow.
// No confirm step; × closes. "恢复默认" (bottom right) deletes the
// stored colour: the theme accent returns to the per-theme default
// and the ring / picker show that actual accent (never an invented
// default). The colour is stored with its opacity and controls the
// tab-bar selected state (icon + label) plus every accent-role usage
// in the app — semantic red (LIVE badge, recording dot) and
// brand/logo colours never read it and never change.

import '../../core/theme/hao_radius.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../core/theme/screen_capture.dart';
import '../../core/theme/tab_bar_accent.dart';
import '../../core/theme/theme_controller.dart';
import 'accent_dropper_page.dart';

/// Open the accent-colour sheet from a settings row tap.
Future<void> showAccentColorSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (ctx) => GlassContainer(
      // App sheet pattern (track_more_sheet): top corners 28,
      // bottom square — the sheet sits on the screen edge. Standard
      // glass (dense content, never premium shader).
      shape: const LiquidVerticalRoundedSuperellipse(
        topRadius: 28,
        bottomRadius: 0,
      ),
      quality: GlassQuality.standard,
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: MediaQuery.of(ctx).padding.bottom + 16,
          ),
          child: const _AccentColorSheet(),
        ),
      ),
    ),
  );
}

/// The accent actually in effect: the stored custom colour when
/// one exists, else the current theme's own accent (P0-5 — no
/// invented default). Reads ThemeController when registered, else
/// the ThemeData extension (same value: the ThemeData was built from
/// the controller, or directly from HaoThemes in tests).
Color _effectiveAccent(BuildContext context) {
  if (Get.isRegistered<ThemeController>()) {
    return Get.find<ThemeController>()
        .effectiveAccent(Theme.of(context).brightness);
  }
  return HaoTheme.of(context).accent;
}

/// The rainbow-ring button (settings row trailing): a conic rainbow
/// ring with the current accent colour in the middle (the reference
/// row's right-hand control). Rebuilds live through the accent Rx.
class AccentRingButton extends StatelessWidget {
  const AccentRingButton({super.key});

  @override
  Widget build(BuildContext context) {
    final accent = TabBarAccentController.ensure();
    return Obx(() {
      final color = accent.color.value ?? _effectiveAccent(context);
      return SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Rainbow ring (conic spectrum).
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [
                    Color(0xFFFF0000),
                    Color(0xFFFFFF00),
                    Color(0xFF00FF00),
                    Color(0xFF00FFFF),
                    Color(0xFF0000FF),
                    // P1-U6: no magenta — blue goes straight back to red.
                    Color(0xFFFF0000),
                  ],
                ),
              ),
            ),
            // Thin dark gap, then the current colour.
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF1C1C1E)
                    : Colors.white,
              ),
            ),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
              ),
            ),
          ],
        ),
      );
    });
  }
}

enum _AccentMode { grid, spectrum, sliders }

class _AccentColorSheet extends StatefulWidget {
  const _AccentColorSheet();

  @override
  State<_AccentColorSheet> createState() => _AccentColorSheetState();
}

class _AccentColorSheetState extends State<_AccentColorSheet> {
  late HSVColor _hsv;
  late double _opacity;
  var _mode = _AccentMode.grid;
  late List<Color> _customs;
  // didChangeDependencies runs before the first build (and again if
  // an inherited widget changes): the starting colour resolves once.
  var _initialized = false;

  Color get _color => _hsv.toColor().withValues(alpha: _opacity);

  @override
  void initState() {
    super.initState();
    _customs = AccentPresetStore.loadCustoms();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The starting colour needs the theme (Theme.of), which is not
    // available in initState — resolve it here, once, before the
    // first build. Stored custom colour when one exists, else the
    // theme's actual accent (P0-5): the picker HSV starts from what
    // the user actually sees, never from an invented red.
    if (_initialized) return;
    _initialized = true;
    final current =
        TabBarAccentController.ensure().color.value ?? _effectiveAccent(context);
    _hsv = HSVColor.fromColor(current);
    _opacity = current.a;
  }

  Future<void> _apply(HSVColor hsv, double opacity) async {
    setState(() {
      _hsv = hsv;
      _opacity = opacity;
    });
    await TabBarAccentController.ensure().setColor(_color);
    // App-wide accent follows the same pick (opaque form — the
    // theme controller drops the opacity). Guarded: widget tests
    // that pump the sheet without a ThemeController must not throw.
    if (Get.isRegistered<ThemeController>()) {
      Get.find<ThemeController>().setCustomAccent(_color);
    }
  }

  /// Restore defaults: no custom colour — the stored key is deleted
  /// and the theme accent returns to the per-theme default, which is
  /// what the picker restarts from (P0-5).
  Future<void> _resetToDefault() async {
    HaoHaptics.select();
    await TabBarAccentController.ensure().reset();
    if (Get.isRegistered<ThemeController>()) {
      Get.find<ThemeController>().clearCustomAccent();
    }
    if (!mounted) return;
    setState(() {
      final current =
          TabBarAccentController.ensure().color.value ?? _effectiveAccent(context);
      _hsv = HSVColor.fromColor(current);
      _opacity = current.a;
    });
  }

  Future<void> _applyColor(Color color) async {
    await _apply(HSVColor.fromColor(color), color.a);
  }

  Future<void> _openDropper() async {
    final image = await ScreenCapture.capture();
    if (!mounted) return;
    if (image == null) {
      // Never a silent dead button: the capture failed, say so.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('取色失败，请重试')),
      );
      return;
    }
    final picked = await Navigator.of(context).push<Color?>(
      MaterialPageRoute<Color>(
        builder: (_) => AccentDropperPage(image: image),
      ),
    );
    if (picked != null && mounted) {
      await _applyColor(picked);
    }
  }

  Future<void> _addPreset() async {
    if (AccentPresetStore.contains(_color, _customs)) return;
    HaoHaptics.select();
    final next = [..._customs, _color];
    setState(() => _customs = next);
    await AccentPresetStore.saveCustoms(next);
  }

  Future<void> _deletePreset(Color preset) async {
    if (AccentPresetStore.defaults.contains(preset)) return;
    HaoHaptics.select();
    final next = [..._customs]..remove(preset);
    setState(() => _customs = next);
    await AccentPresetStore.saveCustoms(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top row: × close (left), dropper (right).
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _CircleButton(
                key: const ValueKey('accent-close'),
                icon: Icons.close,
                onTap: () => Navigator.of(context).pop(),
              ),
              _CircleButton(
                key: const ValueKey('accent-dropper'),
                icon: Icons.colorize,
                onTap: _openDropper,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Segments(
            mode: _mode,
            onChanged: (mode) => setState(() => _mode = mode),
          ),
          const SizedBox(height: 16),
          switch (_mode) {
            _AccentMode.grid => _GridPicker(
                opacity: _opacity,
                onPick: (color) => _applyColor(color),
              ),
            _AccentMode.spectrum => _SpectrumPicker(
                hsv: _hsv,
                onChanged: (hsv) => _apply(hsv, _opacity),
              ),
            _AccentMode.sliders => _SlidersPicker(
                hsv: _hsv,
                onChanged: (hsv) => _apply(hsv, _opacity),
              ),
          },
          const SizedBox(height: 16),
          // Opacity: label + checkerboard gradient slider + %.
          Row(
            children: [
              Text(
                '不透明度',
                style: TextStyle(
                  color: theme.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _GradientSlider(
                  key: const ValueKey('accent-opacity-slider'),
                  gradient: LinearGradient(
                    colors: [
                      _color.withValues(alpha: 0),
                      _color.withValues(alpha: 1),
                    ],
                  ),
                  checkerboard: true,
                  value: _opacity,
                  onChanged: (v) => _apply(_hsv, v),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(HaoRadius.large),
                  color: theme.surfaceStrong,
                ),
                child: Text(
                  '${(_opacity * 100).round()}%',
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: theme.hairline),
          const SizedBox(height: 16),
          // Bottom: preview square + presets + add.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                key: const ValueKey('accent-preview'),
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(HaoRadius.panel),
                  color: _color,
                  border: Border.all(color: theme.hairline),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final preset in AccentPresetStore.defaults)
                        _PresetDot(
                          key: ValueKey('accent-preset-${preset.toARGB32()}'),
                          color: preset,
                          onTap: () => _applyColor(preset),
                        ),
                      for (final preset in _customs)
                        _PresetDot(
                          key: ValueKey('accent-preset-${preset.toARGB32()}'),
                          color: preset,
                          onTap: () => _applyColor(preset),
                          onLongPress: () => _deletePreset(preset),
                        ),
                      _PresetAddButton(
                        key: const ValueKey('accent-preset-add'),
                        onTap: _addPreset,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Reset: no custom colour — theme accent back to the
          // per-theme default. Plain secondary text, not an
          // accent-role usage — it stays textSecondary.
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('accent-reset-default'),
              onPressed: _resetToDefault,
              child: Text(
                '恢复默认',
                style: TextStyle(
                  color: theme.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Circular sheet button (× / dropper): theme surface, 44pt.
class _CircleButton extends StatelessWidget {
  const _CircleButton({super.key, required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HaoHaptics.tap();
          onTap();
        },
        customBorder: const CircleBorder(),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.surfaceStrong,
          ),
          child: Icon(icon, size: 20, color: theme.textPrimary),
        ),
      ),
    );
  }
}

/// The 网格 / 光谱 / 滑块 segmented control.
class _Segments extends StatelessWidget {
  const _Segments({required this.mode, required this.onChanged});

  final _AccentMode mode;
  final ValueChanged<_AccentMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    Widget segment(_AccentMode m, String label) {
      final selected = m == mode;
      return Expanded(
        child: GestureDetector(
          key: ValueKey('accent-mode-${m.name}'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HaoHaptics.select();
            onChanged(m);
          },
          child: Container(
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(HaoRadius.panel),
              color: selected ? theme.surfaceSolid : Colors.transparent,
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? theme.textPrimary : theme.textMuted,
                fontSize: 15,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 44,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(HaoRadius.panel),
        color: theme.surfaceStrong,
      ),
      child: Row(
        children: [
          segment(_AccentMode.grid, '网格'),
          segment(_AccentMode.spectrum, '光谱'),
          segment(_AccentMode.sliders, '滑块'),
        ],
      ),
    );
  }
}

/// Grid mode: a grayscale row (white → black) over a hue grid.
/// Each column is one hue; each row is one lightness step (dark at
/// the top, pale at the bottom). Tapping a cell picks it.
class _GridPicker extends StatelessWidget {
  const _GridPicker({required this.opacity, required this.onPick});

  /// The current opacity: grid picks keep it (the colour is stored
  /// with its opacity).
  final double opacity;
  final ValueChanged<Color> onPick;

  // P1-U6: no purple/magenta hues (260°–320° dropped) — blue goes
  // straight back to red.
  static const List<double> hues = [
    180, 210, 240, 330, 0, 25, 45, 60, 85, 130,
  ];
  static const int rows = 9;

  static Color gridColor(double hue, int row) {
    final t = row / (rows - 1);
    return HSVColor.fromAHSV(1.0, hue, 0.85 - 0.6 * t, 0.25 + 0.7 * t)
        .toColor();
  }

  @override
  Widget build(BuildContext context) {
    Widget cell(Color color, Key key) {
      return Expanded(
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: () => onPick(color.withValues(alpha: opacity)),
          child: Container(color: color),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(HaoRadius.large),
      child: Column(
        children: [
          SizedBox(
            height: 34,
            child: Row(
              children: [
                for (var i = 0; i < 11; i++)
                  cell(
                    Color.fromARGB(
                      255,
                      255 - (i * 255 / 10).round(),
                      255 - (i * 255 / 10).round(),
                      255 - (i * 255 / 10).round(),
                    ),
                    ValueKey('accent-gray-$i'),
                  ),
              ],
            ),
          ),
          for (var row = 0; row < rows; row++)
            SizedBox(
              height: 30,
              child: Row(
                children: [
                  for (final hue in hues)
                    cell(
                      gridColor(hue, row),
                      ValueKey('accent-grid-$hue-$row'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Spectrum mode: a hue strip over a saturation/value square.
class _SpectrumPicker extends StatelessWidget {
  const _SpectrumPicker({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  static const _rainbow = LinearGradient(
    colors: [
      Color(0xFFFF0000),
      Color(0xFFFFFF00),
      Color(0xFF00FF00),
      Color(0xFF00FFFF),
      Color(0xFF0000FF),
      // P1-U6: no magenta — blue goes straight back to red.
      Color(0xFFFF0000),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Hue strip.
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return GestureDetector(
              key: const ValueKey('accent-hue-strip'),
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _pickHue(d.localPosition.dx / width),
              onHorizontalDragUpdate: (d) =>
                  _pickHue(d.localPosition.dx / width),
              child: Stack(
                children: [
                  Container(
                    height: 28,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(HaoRadius.large),
                      gradient: _rainbow,
                    ),
                  ),
                  Positioned(
                    left: (hsv.hue / 360 * width - 14).clamp(0.0, width - 28),
                    top: 0,
                    child: _Thumb(color: _hueColor),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        // Saturation (x) / value (y) square for the current hue.
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            const height = 190.0;
            return GestureDetector(
              key: const ValueKey('accent-sv-square'),
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _pickSv(d.localPosition, width, height),
              onPanUpdate: (d) => _pickSv(d.localPosition, width, height),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(HaoRadius.large),
                child: Stack(
                  children: [
                    Container(
                      width: width,
                      height: height,
                      color: _hueColor,
                    ),
                    Container(
                      width: width,
                      height: height,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.white, Colors.transparent],
                        ),
                      ),
                    ),
                    Container(
                      width: width,
                      height: height,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black],
                        ),
                      ),
                    ),
                    Positioned(
                      left: (hsv.saturation * width - 14)
                          .clamp(0.0, width - 28),
                      top: ((1 - hsv.value) * height - 14)
                          .clamp(0.0, height - 28),
                      child: _Thumb(color: hsv.toColor()),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Color get _hueColor =>
      HSVColor.fromAHSV(1.0, hsv.hue, 1.0, 1.0).toColor();

  void _pickHue(double fraction) {
    onChanged(hsv.withHue((fraction.clamp(0.0, 1.0) * 360)));
  }

  void _pickSv(Offset local, double width, double height) {
    onChanged(
      hsv.withSaturation((local.dx / width).clamp(0.0, 1.0)).withValue(
            (1 - local.dy / height).clamp(0.0, 1.0),
          ),
    );
  }
}

/// Slider mode: H / S / V gradient sliders.
class _SlidersPicker extends StatelessWidget {
  const _SlidersPicker({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    Widget row(
      String label,
      String value,
      LinearGradient gradient,
      double fraction,
      ValueChanged<double> set,
    ) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Text(
                label,
                style: TextStyle(color: theme.textSecondary, fontSize: 13),
              ),
            ),
            Expanded(
              child: _GradientSlider(
                gradient: gradient,
                value: fraction,
                onChanged: set,
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 44,
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: TextStyle(color: theme.textSecondary, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        row(
          '色相',
          '${hsv.hue.round()}°',
          const LinearGradient(
            colors: [
              Color(0xFFFF0000),
              Color(0xFFFFFF00),
              Color(0xFF00FF00),
              Color(0xFF00FFFF),
              Color(0xFF0000FF),
              // P1-U6: no magenta — blue goes straight back to red.
              Color(0xFFFF0000),
            ],
          ),
          hsv.hue / 360,
          (v) => onChanged(hsv.withHue(v * 360)),
        ),
        row(
          '饱和度',
          '${(hsv.saturation * 100).round()}%',
          LinearGradient(
            colors: [
              HSVColor.fromAHSV(1.0, hsv.hue, 0.0, hsv.value).toColor(),
              HSVColor.fromAHSV(1.0, hsv.hue, 1.0, hsv.value).toColor(),
            ],
          ),
          hsv.saturation,
          (v) => onChanged(hsv.withSaturation(v)),
        ),
        row(
          '明度',
          '${(hsv.value * 100).round()}%',
          LinearGradient(
            colors: [
              HSVColor.fromAHSV(1.0, hsv.hue, hsv.saturation, 0.0).toColor(),
              HSVColor.fromAHSV(1.0, hsv.hue, hsv.saturation, 1.0).toColor(),
            ],
          ),
          hsv.value,
          (v) => onChanged(hsv.withValue(v)),
        ),
      ],
    );
  }
}

/// A gradient track with a thumb (used for H/S/V and opacity).
/// Drag or tap anywhere on the track to set [value] (0..1).
class _GradientSlider extends StatelessWidget {
  const _GradientSlider({
    super.key,
    required this.gradient,
    required this.value,
    required this.onChanged,
    this.checkerboard = false,
  });

  final LinearGradient gradient;
  final double value;
  final ValueChanged<double> onChanged;

  /// Draw a transparency checkerboard under the gradient (opacity).
  final bool checkerboard;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => onChanged((d.localPosition.dx / width).clamp(0.0, 1.0)),
          onHorizontalDragUpdate: (d) =>
              onChanged((d.localPosition.dx / width).clamp(0.0, 1.0)),
          child: Stack(
            children: [
              if (checkerboard)
                CustomPaint(
                  size: Size(width, 28),
                  painter: _CheckerboardPainter(),
                ),
              Container(
                height: 28,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(HaoRadius.large),
                  gradient: gradient,
                ),
              ),
              Positioned(
                left: (value * width - 14).clamp(0.0, width - 28),
                top: 0,
                child: _Thumb(
                  color: gradient.colors.last,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// White-ringed thumb showing the current colour (sliders, spectrum).
class _Thumb extends StatelessWidget {
  const _Thumb({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
    );
  }
}

/// Transparency checkerboard (light squares on white), 8pt cells.
class _CheckerboardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cell = 8.0;
    final light = Paint()..color = Colors.white;
    final dark = Paint()..color = const Color(0xFFCCCCCC);
    canvas.drawRect(Offset.zero & size, light);
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        if (((x / cell).round() + (y / cell).round()) % 2 == 0) continue;
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), dark);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// One preset dot: 44pt circle. Tap to apply; long-press a custom
/// preset to delete it (defaults ignore the long-press).
class _PresetDot extends StatelessWidget {
  const _PresetDot({
    super.key,
    required this.color,
    required this.onTap,
    this.onLongPress,
  });

  final Color color;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    // 36pt dots: all 5 defaults + the + button fit on a 390pt
    // screen without scrolling (5 × 44 + 36 = 256 < the ~270pt
    // left after the preview), matching the reference layout.
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HaoHaptics.tap();
          onTap();
        },
        onLongPress: onLongPress == null
            ? null
            : () {
                HaoHaptics.select();
                onLongPress!();
              },
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: theme.hairline),
          ),
        ),
      ),
    );
  }
}

/// The + button after the presets: adds the current colour.
class _PresetAddButton extends StatelessWidget {
  const _PresetAddButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HaoHaptics.tap();
        onTap();
      },
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.surfaceSolid,
          border: Border.all(color: theme.hairline),
        ),
        child: Icon(Icons.add, size: 20, color: theme.textPrimary),
      ),
    );
  }
}
