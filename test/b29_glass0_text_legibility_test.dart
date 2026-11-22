// build 29-A — glass 0% text/icon legibility, completed.
//
// b28 added HaoTheme.legibilityShadows but only applied it at scattered
// call sites (live room + a few pages), so chen still reported "很多字
// 不显示" on 1.1.6. b29-A closes the gap systematically:
//
// - Theme-level (hao_themes.dart _buildThemeData): every theme text
//   style (textTheme x9, AppBar title, ListTile title/subtitle, dialog
//   title/content, chip label, Filled/Text button textStyle, input
//   hint/label, slider value indicator) carries the intensity-scaled
//   legibility shadow — [] at 100% (today's look byte-identical), full
//   strength at 0%. Explicit call-site TextStyles merge over the
//   ambient DefaultTextStyle (Text.build:
//   defaultTextStyle.style.merge(style)), so the shadow survives
//   unless the call site sets shadows itself.
// - Icons: all 101 uncovered Icon( sites in lib/ now pass
//   `shadows: HaoTheme.legibilityShadows(context)` (audit script:
//   .tmp_icon_fix.py; downloads_page _statusIcon takes a context now).
// - Buttons (chen: "估计很多按钮都不显示字"): two ChoiceChip
//   labelStyles that overrode the theme default without shadows
//   (emby_detail line chips, video_version_sheet filter chips);
//   HaoSegmentedControl labels carry shadows explicitly; the disabled
//   FilledButton fill was textMuted 0.25 — 1.4-1.5:1 against onPrimary
//   in 6 of 8 combos (the 音源管理 '验证中…' button) — now an opaque
//   textPrimary-0.55-over-scaffold composite, 3.5-5.9:1 everywhere.
//   Enabled Filled/Elevated/Outlined/Text buttons and chips were
//   already accent+onPrimary / accent text — verified, not changed.
//
// Golden scenes reuse the b28 painted-backdrop rule: decoded images do
// NOT rasterise into goldens in this harness, so the busy wallpaper is
// painted (same seed-28 painter as b28_glass0_legibility_test.dart).

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/theme/glass.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/widgets/hao_search_field.dart';
import 'package:standalone/widgets/hao_segmented_control.dart';

ThemeData _theme(HaoThemeId id, double intensity, bool isDark) {
  final pair = HaoThemes.of(
    id,
    glassIntensity: intensity,
    backgroundActive: true,
  );
  return isDark ? pair.dark : pair.light;
}

double _lum(Color c) {
  double f(double v) {
    final x = v / 255;
    return x <= 0.04045 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4) as double;
  }

  return 0.2126 * f(c.r * 255) +
      0.7152 * f(c.g * 255) +
      0.0722 * f(c.b * 255);
}

double _contrast(Color a, Color b) {
  final l1 = _lum(a);
  final l2 = _lum(b);
  final hi = math.max(l1, l2);
  final lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

List<Shadow> _shadowsOf(TextStyle? s) => s?.shadows ?? const <Shadow>[];

void main() {
  group('theme text styles carry the legibility shadow', () {
    test('all 4 themes x light/dark: shadows at 0%, none at 100%', () {
      for (final id in HaoThemeId.values) {
        for (final isDark in [false, true]) {
          final t0 = _theme(id, 0.0, isDark);
          final t1 = _theme(id, 1.0, isDark);
          // textTheme x9.
          final slots0 = [
            t0.textTheme.bodyLarge,
            t0.textTheme.bodyMedium,
            t0.textTheme.bodySmall,
            t0.textTheme.titleLarge,
            t0.textTheme.titleMedium,
            t0.textTheme.titleSmall,
            t0.textTheme.labelLarge,
            t0.textTheme.labelMedium,
            t0.textTheme.labelSmall,
          ];
          final slots1 = [
            t1.textTheme.bodyLarge,
            t1.textTheme.bodyMedium,
            t1.textTheme.bodySmall,
            t1.textTheme.titleLarge,
            t1.textTheme.titleMedium,
            t1.textTheme.titleSmall,
            t1.textTheme.labelLarge,
            t1.textTheme.labelMedium,
            t1.textTheme.labelSmall,
          ];
          for (final s in slots0) {
            expect(_shadowsOf(s), isNotEmpty, reason: '$id $isDark $s');
          }
          for (final s in slots1) {
            expect(_shadowsOf(s), isEmpty, reason: '$id $isDark $s');
          }
          // AppBar / ListTile / dialog / chip / buttons / input / slider.
          expect(_shadowsOf(t0.appBarTheme.titleTextStyle), isNotEmpty);
          expect(_shadowsOf(t1.appBarTheme.titleTextStyle), isEmpty);
          expect(_shadowsOf(t0.listTileTheme.titleTextStyle), isNotEmpty);
          expect(_shadowsOf(t0.listTileTheme.subtitleTextStyle), isNotEmpty);
          expect(_shadowsOf(t1.listTileTheme.titleTextStyle), isEmpty);
          expect(_shadowsOf(t0.dialogTheme.titleTextStyle), isNotEmpty);
          expect(_shadowsOf(t0.dialogTheme.contentTextStyle), isNotEmpty);
          expect(_shadowsOf(t1.dialogTheme.titleTextStyle), isEmpty);
          expect(_shadowsOf(t0.chipTheme.labelStyle), isNotEmpty);
          expect(_shadowsOf(t1.chipTheme.labelStyle), isEmpty);
          final filled0 = t0.filledButtonTheme.style?.textStyle?.resolve({});
          final filled1 = t1.filledButtonTheme.style?.textStyle?.resolve({});
          expect(_shadowsOf(filled0), isNotEmpty);
          expect(_shadowsOf(filled1), isEmpty);
          final text0 = t0.textButtonTheme.style?.textStyle?.resolve({});
          final text1 = t1.textButtonTheme.style?.textStyle?.resolve({});
          expect(_shadowsOf(text0), isNotEmpty);
          expect(_shadowsOf(text1), isEmpty);
          expect(_shadowsOf(t0.inputDecorationTheme.hintStyle), isNotEmpty);
          expect(_shadowsOf(t0.inputDecorationTheme.labelStyle), isNotEmpty);
          expect(_shadowsOf(t1.inputDecorationTheme.hintStyle), isEmpty);
          expect(
            _shadowsOf(t0.sliderTheme.valueIndicatorTextStyle),
            isNotEmpty,
          );
          expect(_shadowsOf(t1.sliderTheme.valueIndicatorTextStyle), isEmpty);
        }
      }
    });

    test('shadow colour follows brightness only, never the theme', () {
      for (final id in HaoThemeId.values) {
        final light = _theme(id, 0.0, false).textTheme.bodyMedium!.shadows!;
        final dark = _theme(id, 0.0, true).textTheme.bodyMedium!.shadows!;
        expect(light.single.color, Colors.white.withValues(alpha: 0.60));
        expect(dark.single.color, Colors.black.withValues(alpha: 0.45));
      }
    });
  });

  group('FilledButton bg/fg pairing (b29-A buttons)', () {
    test('enabled + disabled label contrast >= 3.0 in all 8 combos', () {
      for (final id in HaoThemeId.values) {
        for (final isDark in [false, true]) {
          final t = _theme(id, 0.0, isDark);
          final style = t.filledButtonTheme.style!;
          final fg = style.foregroundColor!.resolve({})!;
          final bgEnabled = style.backgroundColor!.resolve({})!;
          final bgDisabled =
              style.backgroundColor!.resolve({WidgetState.disabled})!;
          expect(
            _contrast(fg, bgEnabled),
            greaterThanOrEqualTo(3.0),
            reason: 'enabled $id $isDark',
          );
          expect(
            _contrast(fg, bgDisabled),
            greaterThanOrEqualTo(3.0),
            reason: 'disabled $id $isDark',
          );
          // The disabled fill must be opaque: a translucent fill would
          // composite over whatever wallpaper sits behind the button.
          expect(bgDisabled.a, 1.0, reason: 'disabled opaque $id $isDark');
        }
      }
    });
  });

  group('effective styles at 0% (widget)', () {
    Future<void> pumpScene(
      WidgetTester tester, {
      required HaoThemeId id,
      required bool isDark,
      required double intensity,
    }) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(id, intensity, isDark),
          home: const Scaffold(body: _B29Scene()),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    testWidgets('0% light: every rendered Text span carries shadows',
        (tester) async {
      await pumpScene(
        tester,
        id: HaoThemeId.appleGlass,
        isDark: false,
        intensity: 0.0,
      );
      final spans = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((r) => r.text.style)
          .toList();
      expect(spans, isNotEmpty);
      for (final s in spans) {
        expect(
          _shadowsOf(s),
          isNotEmpty,
          reason: 'RichText span without legibility shadow: $s',
        );
      }
      // The search field's input text resolves through bodyLarge.
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(_shadowsOf(editable.style), isNotEmpty);
      // The icons in the scene carry shadows too.
      for (final icon in tester.widgetList<Icon>(find.byType(Icon))) {
        expect(icon.shadows, isNotEmpty);
      }
    });

    testWidgets('0% dark: every rendered Text span carries shadows',
        (tester) async {
      await pumpScene(
        tester,
        id: HaoThemeId.appleGlass,
        isDark: true,
        intensity: 0.0,
      );
      for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
        expect(_shadowsOf(r.text.style), isNotEmpty);
      }
    });

    testWidgets('100%: every rendered Text span has empty shadows',
        (tester) async {
      await pumpScene(
        tester,
        id: HaoThemeId.appleGlass,
        isDark: false,
        intensity: 1.0,
      );
      for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
        expect(_shadowsOf(r.text.style), isEmpty);
      }
      for (final icon in tester.widgetList<Icon>(find.byType(Icon))) {
        expect(icon.shadows ?? const <Shadow>[], isEmpty);
      }
    });

    testWidgets('GlassCard fill stays fully transparent at 0%',
        (tester) async {
      await pumpScene(
        tester,
        id: HaoThemeId.appleGlass,
        isDark: false,
        intensity: 0.0,
      );
      // Frosted branch: the inner Container paints theme.surface x
      // intensity. At 0% every such fill under the card is alpha 0.
      final fills = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(GlassCard),
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).color != null,
          ),
        ),
      );
      expect(fills, isNotEmpty);
      for (final c in fills) {
        expect(
          ((c.decoration as BoxDecoration).color!).a,
          0.0,
        );
      }
    });
  });

  group('button matrix goldens (0% busy wallpaper)', () {
    Future<void> goldenScene(
      WidgetTester tester, {
      required HaoThemeId id,
      required bool isDark,
      required double intensity,
      required String name,
    }) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(id, intensity, isDark),
          home: Scaffold(
            body: _ButtonMatrix(intensity: intensity),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/$name'),
      );
    }

    testWidgets('golden: 0% busy appleGlass light', (tester) async {
      await goldenScene(
        tester,
        id: HaoThemeId.appleGlass,
        isDark: false,
        intensity: 0.0,
        name: 'b29_buttons_0_busy_appleGlass_light.png',
      );
    });
    testWidgets('golden: 0% busy appleGlass dark', (tester) async {
      await goldenScene(
        tester,
        id: HaoThemeId.appleGlass,
        isDark: true,
        intensity: 0.0,
        name: 'b29_buttons_0_busy_appleGlass_dark.png',
      );
    });
    testWidgets('golden: 0% busy darkGold light', (tester) async {
      await goldenScene(
        tester,
        id: HaoThemeId.darkGold,
        isDark: false,
        intensity: 0.0,
        name: 'b29_buttons_0_busy_darkGold_light.png',
      );
    });
    testWidgets('golden: 0% busy polarIce dark', (tester) async {
      await goldenScene(
        tester,
        id: HaoThemeId.polarIce,
        isDark: true,
        intensity: 0.0,
        name: 'b29_buttons_0_busy_polarIce_dark.png',
      );
    });
    testWidgets('golden: 100% control busy appleGlass light', (tester) async {
      await goldenScene(
        tester,
        id: HaoThemeId.appleGlass,
        isDark: false,
        intensity: 1.0,
        name: 'b29_buttons_100_busy_appleGlass_light.png',
      );
    });
    testWidgets('golden: 100% control busy appleGlass dark', (tester) async {
      await goldenScene(
        tester,
        id: HaoThemeId.appleGlass,
        isDark: true,
        intensity: 1.0,
        name: 'b29_buttons_100_busy_appleGlass_dark.png',
      );
    });
  });
}

/// Painted busy backdrop: deterministic mirror of
/// test/fixtures/wallpaper_busy.png (same seed 28 as the b28 test —
/// decoded images do not rasterise into goldens in this harness).
class _BusyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final random = math.Random(28);
    for (var i = 0; i < 240; i++) {
      final x = random.nextDouble() * (size.width - 40);
      final y = random.nextDouble() * (size.height - 40);
      final w = 20 + random.nextDouble() * 100;
      final h = 20 + random.nextDouble() * 100;
      canvas.drawRect(
        Rect.fromLTWH(x, y, w, h),
        Paint()
          ..color = Color.fromRGBO(
            random.nextInt(256),
            random.nextInt(256),
            random.nextInt(256),
            1,
          ),
      );
    }
    final points = <Offset>[];
    for (var i = 0; i < 8000; i++) {
      points.add(
        Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        ),
      );
    }
    canvas.drawPoints(
      ui.PointMode.points,
      points,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_BusyPainter oldDelegate) => false;
}

/// Widget-test scene: every text/button form the audit covers, with
/// NO per-site shadows on the plain Texts — the theme fix alone must
/// carry them. (Chips use the fixed explicit-labelStyle pattern, as
/// the real call sites do.)
class _B29Scene extends StatelessWidget {
  const _B29Scene();

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    return _Backdrop(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '设置',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: theme.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            GlassCard(
              radius: 18,
              padding: const EdgeInsets.all(16),
              child: Text(
                '玻璃卡片里的字',
                style: TextStyle(color: theme.textPrimary, fontSize: 15),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '壁纸上的字',
              style: TextStyle(color: theme.textSecondary, fontSize: 15),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: () {},
                  child: const Text('确定'),
                ),
                const SizedBox(width: 8),
                const FilledButton(
                  onPressed: null,
                  child: Text('验证中…'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {},
                  child: const Text('取消'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('已选'),
                  selected: true,
                  selectedColor: theme.accentSoft,
                  labelStyle: TextStyle(
                    shadows: HaoTheme.legibilityShadows(context),
                    color: theme.accent,
                  ),
                  onSelected: (_) {},
                ),
                const SizedBox(width: 8),
                const ChoiceChip(
                  label: Text('默认'),
                  selected: false,
                  onSelected: null,
                ),
              ],
            ),
            const SizedBox(height: 12),
            const HaoSearchField(hintText: '搜索歌曲 / 歌手…'),
            const SizedBox(height: 12),
            HaoSegmentedControl<String>(
              segments: [
                HaoSegment(value: 'a', label: '歌曲'),
                HaoSegment(value: 'b', label: '专辑'),
                HaoSegment(value: 'c', label: '歌单'),
              ],
              value: 'a',
              onChanged: _noop,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.search,
                  shadows: HaoTheme.legibilityShadows(context),
                  color: theme.textMuted,
                ),
                const SizedBox(width: 8),
                Text(
                  '图标加文字',
                  style: TextStyle(color: theme.textPrimary, fontSize: 15),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

void _noop(String value) {}

/// Button matrix for the goldens: one row per button type, all on the
/// painted busy wallpaper + the 0.55 scrim. Nothing here sets shadows
/// per site except the two fixed chip patterns — the theme fix must
/// carry every other label.
class _ButtonMatrix extends StatelessWidget {
  const _ButtonMatrix({required this.intensity});

  final double intensity;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    return _Backdrop(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '按钮',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: theme.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '壁纸上的字',
              style: TextStyle(color: theme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton(onPressed: () {}, child: const Text('确定')),
                const SizedBox(width: 8),
                const FilledButton(onPressed: null, child: Text('验证中…')),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {},
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.accent,
                    foregroundColor: onPrimary,
                  ),
                  child: const Text('重试'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {},
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.accent),
                  ),
                  child: Text(
                    '加载更多',
                    style: TextStyle(
                      color: theme.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {},
                  child: Text(
                    '取消',
                    style: TextStyle(color: theme.accent),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('已选'),
                  selected: true,
                  selectedColor: theme.accentSoft,
                  labelStyle: TextStyle(
                    shadows: HaoTheme.legibilityShadows(context),
                    color: theme.accent,
                  ),
                  onSelected: (_) {},
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('未选'),
                  selected: false,
                  selectedColor: theme.accentSoft,
                  labelStyle: TextStyle(
                    shadows: HaoTheme.legibilityShadows(context),
                    color: theme.textSecondary,
                  ),
                  onSelected: (_) {},
                ),
                const SizedBox(width: 8),
                const ChoiceChip(
                  label: Text('默认'),
                  selected: false,
                  onSelected: null,
                ),
                const SizedBox(width: 8),
                ActionChip(
                  label: const Text('热门'),
                  backgroundColor: theme.surface,
                  labelStyle: TextStyle(
                    shadows: HaoTheme.legibilityShadows(context),
                    color: theme.textSecondary,
                  ),
                  onPressed: () {},
                ),
              ],
            ),
            const SizedBox(height: 10),
            HaoSegmentedControl<String>(
              segments: [
                HaoSegment(value: 'a', label: '歌曲'),
                HaoSegment(value: 'b', label: '专辑'),
                HaoSegment(value: 'c', label: '歌单'),
              ],
              value: 'a',
              onChanged: _noop,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: theme.accent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '播放全部',
                    style: TextStyle(
                      color: onPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GlassCard(
                  radius: 12,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Text(
                    '加入歌单',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const HaoSearchField(hintText: '搜索歌曲 / 歌手…'),
          ],
        ),
      ),
    );
  }
}

/// Painted busy wallpaper + the 0.55 theme scrim, exactly like the
/// production AppearanceBackgroundLayer.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    return SizedBox(
      width: 800,
      height: 600,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: _BusyPainter(), size: const Size(800, 600)),
          Container(
            color: theme.scaffoldBackground.withValues(alpha: 0.55),
          ),
          child,
        ],
      ),
    );
  }
}
