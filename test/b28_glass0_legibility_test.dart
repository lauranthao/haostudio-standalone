// build 28 — glass 0% legibility (b28 audit).
//
// T1 scrim regression, T2 transparency conservation, T3 render matrix,
// T4 icon probe. One scene per testWidgets (same rasterisation rule as
// test/glass_intensity_test.dart: a 0% -> 1% pump inside one test leaves
// the golden stuck on the first frame).
//
// T4 verdict (probe run 2026-11-21, temp file deleted after the probe —
// the golden pair is re-generated here):
// - A1 glyph-as-Text renders pixel-identical to Icon (same sha256; both
//   are the missing-glyph box in flutter_test because the MaterialIcons
//   font is not loaded in the harness — and A1 IS Icon's own mechanism:
//   Icon builds RichText/TextSpan(codePoint, fontFamily, package),
//   icon.dart:310-330).
// - Better still, Icon natively takes `shadows` (icon.dart:85, 283, 321),
//   so no A1 widget and no A2 ghost are needed: call sites pass
//   `shadows: HaoTheme.legibilityShadows(context)` to Icon and
//   `shadows: ...` in TextStyle. A2 was inconclusive (white ghost on a
//   white probe background is invisible) and is not used. Scheme C
//   (local scrim) is not used anywhere.
// - Decoded raster images do NOT rasterise into goldens in this harness
//   (probe b28_probe_wallpaper*.png: 0 non-white px even after
//   pumpAndSettle / runAsync). T3 backdrops are therefore PAINTED with
//   widgets (gradients + a seeded CustomPaint mirroring the fixture
//   generation), not Image widgets. The fixture PNGs in test/fixtures/
//   stay the canonical worst-case wallpapers; T1 uses one as the real
//   file behind the layer.
//
// T3 matrix (0%): 3 wallpapers x {appleGlass light, appleGlass dark}
// (6) + busy x {darkGold light, darkGold dark, freshMint light,
// polarIce dark} (4) = 10 goldens. (The audit §4 says "9" but lists 4
//抽查 items on top of the 6 — 6+4=10; all 4 listed items are generated.)
// Plus 2x 100% controls (busy, appleGlass light/dark) and 6x no-glass
// baselines (3 wallpapers x appleGlass light/dark) for the <0.5%
// pixel-diff check (PIL, run after generation — see report).

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    hide GlassCard, GlassShadow;
import 'package:standalone/core/theme/appearance_store.dart';
import 'package:standalone/core/theme/glass.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/liquid_glass_theme.dart';

String get _busyWallpaper =>
    File('test/fixtures/wallpaper_busy.png').absolute.path;

ThemeData _theme(HaoThemeId id, double intensity, bool isDark) {
  final pair = HaoThemes.of(
    id,
    glassIntensity: intensity,
    backgroundActive: true,
  );
  return isDark ? pair.dark : pair.light;
}

// ---------------------------------------------------------------- T1 ---

Future<void> _pumpLayer(
  WidgetTester tester,
  ThemeData theme, {
  required String wallpaperPath,
}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    Get.delete<AppearanceController>(force: true);
  });
  Get.put(AppearanceController())
    ..wallpaperEnabled.value = true
    ..currentWallpaper.value = wallpaperPath
    ..backgroundActive.value = true;
  await tester.pumpWidget(
    GetMaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: const Scaffold(body: AppearanceBackgroundLayer()),
    ),
  );
  await tester.pump();
}

/// The scrim Container: the Stack child whose colour is the scrim
/// (the Image.file child has no colour).
Color _scrimColor(WidgetTester tester) {
  final found = find.descendant(
    of: find.byType(AppearanceBackgroundLayer),
    matching: find.byWidgetPredicate(
      (w) => w is Container && w.color != null,
    ),
  );
  expect(found, findsOneWidget);
  return tester.widget<Container>(found).color!;
}

// ---------------------------------------------------------------- T2 ---

Future<void> _pumpLibraryCard(
  WidgetTester tester,
  double intensity,
  GlassCardQuality quality,
) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    LiquidGlassWidgets.wrap(
      brightnessResolver: Theme.maybeBrightnessOf,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(HaoThemeId.appleGlass, intensity, false),
        home: Scaffold(
          body: Center(
            child: GlassCard(
              quality: quality,
              child: const SizedBox(
                width: 200,
                height: 60,
                child: Center(child: Text('lib')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The outer Container of a library GlassCard: its child is the
/// GlassContainer (standard) or the GlassAdaptiveScope wrapping it
/// (premium). The library's own internals are not asserted here —
/// only the Beans shadow this widget owns.
BoxDecoration _libraryOuterDeco(WidgetTester tester) {
  final found = find.descendant(
    of: find.byType(GlassCard),
    matching: find.byWidgetPredicate(
      (w) =>
          w is Container &&
          (w.child is GlassContainer ||
              w.child is GlassAdaptiveScope),
    ),
  );
  expect(found, findsOneWidget);
  return tester.widget<Container>(found).decoration as BoxDecoration;
}

// ---------------------------------------------------------------- T3 ---

enum _WallpaperKind { bright, dark, busy }

/// Painted busy backdrop: deterministic mirror of
/// test/fixtures/wallpaper_busy.png (same seed 28, 240 rects + noise),
/// painted instead of decoded — decoded images do not rasterise into
/// goldens in this harness (see file header).
class _BusyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black,
    );
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

Widget _paintedBackdrop(_WallpaperKind kind) {
  switch (kind) {
    case _WallpaperKind.bright:
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF5F0E1), Color(0xFFFFF8DC)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );
    case _WallpaperKind.dark:
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF080A16), Color(0xFF16233D)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );
    case _WallpaperKind.busy:
      return CustomPaint(
        painter: _BusyPainter(),
        size: const Size(800, 600),
      );
  }
}

/// One scene holding the §2 priority groups together (A tab bar +
/// mini player, D search box, C SongRow-like row, E big title), all
/// sitting on a painted wallpaper + the fixed scrim, at the pumped
/// intensity. [glass] false = the no-glass baseline twin (same texts,
/// same legibility shadows, plain Containers instead of glass).
class _B28Scene extends StatelessWidget {
  const _B28Scene({required this.wallpaper, required this.glass});

  final _WallpaperKind wallpaper;
  final bool glass;

  Widget _card(Widget child) {
    if (!glass) return Container(padding: const EdgeInsets.all(16), child: child);
    return GlassCard(
      radius: 18,
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }

  Widget _chrome(Widget child) {
    if (!glass) return Container(padding: const EdgeInsets.all(12), child: child);
    return GlassAdaptiveScope(
      minQuality: GlassQuality.premium,
      child: Builder(
        builder: (context) => GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 20),
          settings: HaoLiquidGlass.chromeSettings(context),
          useOwnLayer: true,
          quality: GlassQuality.premium,
          padding: const EdgeInsets.all(12),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    final shadows = HaoTheme.legibilityShadows(context);
    final titleStyle = TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w800,
      color: theme.textPrimary,
      shadows: shadows,
    );
    final nameStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: theme.textPrimary,
      shadows: shadows,
    );
    final subStyle = TextStyle(
      fontSize: 13,
      color: theme.textSecondary,
      shadows: shadows,
    );
    final hintStyle = TextStyle(
      fontSize: 15,
      color: theme.textMuted,
      shadows: shadows,
    );
    final icons = [
      Icons.movie,
      Icons.live_tv,
      Icons.music_note,
      Icons.settings,
    ];
    return SizedBox(
      width: 800,
      height: 600,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _paintedBackdrop(wallpaper),
          Container(
            color: theme.scaffoldBackground.withValues(alpha: 0.55),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('设置', style: titleStyle),
                const SizedBox(height: 16),
                _card(
                  Row(
                    children: [
                      Icon(
                        Icons.search,
                        size: 20,
                        color: theme.textMuted,
                        shadows: shadows,
                      ),
                      const SizedBox(width: 8),
                      Text('搜索歌曲 / 歌手…', style: hintStyle),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _card(
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: theme.accent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('晴天', style: nameStyle),
                            Text('周杰伦', style: subStyle),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.more_horiz,
                        color: theme.textSecondary,
                        shadows: shadows,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _chrome(
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      for (var i = 0; i < icons.length; i++)
                        Icon(
                          icons[i],
                          size: 23,
                          color: i == 0
                              ? theme.accent
                              : theme.textPrimary.withValues(alpha: 0.8),
                          shadows: shadows,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _chrome(
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: theme.accent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '晴天',
                              style: nameStyle.copyWith(fontSize: 13),
                            ),
                            Text(
                              '周杰伦 · 歌词行',
                              style: subStyle.copyWith(fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.repeat,
                        size: 15,
                        color: theme.textSecondary,
                        shadows: shadows,
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        Icons.skip_previous,
                        size: 15,
                        color: theme.textPrimary,
                        shadows: shadows,
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        Icons.play_arrow,
                        size: 15,
                        color: theme.textPrimary,
                        shadows: shadows,
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        Icons.skip_next,
                        size: 15,
                        color: theme.textPrimary,
                        shadows: shadows,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _pumpScene(
  WidgetTester tester, {
  required HaoThemeId id,
  required bool isDark,
  required double intensity,
  required _WallpaperKind wallpaper,
  required bool glass,
}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final pair = HaoThemes.of(
    id,
    glassIntensity: intensity,
    backgroundActive: true,
  );
  await tester.pumpWidget(
    LiquidGlassWidgets.wrap(
      brightnessResolver: Theme.maybeBrightnessOf,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: isDark ? pair.dark : pair.light,
        home: Scaffold(
          body: _B28Scene(wallpaper: wallpaper, glass: glass),
        ),
      ),
    ),
  );
  await tester.pump();
}

String _sceneName(
  String prefix,
  _WallpaperKind wallpaper,
  HaoThemeId id,
  bool isDark,
) =>
    'goldens/${prefix}_${wallpaper.name}_${id.name}_${isDark ? 'dark' : 'light'}.png';

void main() {
  group('T1 scrim regression (b28 audit 1.3, second root cause)', () {
    testWidgets('light mode: scrim is a near-white wash, not black', (
      tester,
    ) async {
      await _pumpLayer(
        tester,
        _theme(HaoThemeId.appleGlass, 0.0, false),
        wallpaperPath: _busyWallpaper,
      );
      expect(tester.takeException(), isNull);
      final scrim = _scrimColor(tester);
      // Near-white wash: theme scaffold #F2F2F7 at 0.55 alpha.
      expect(scrim.r, greaterThan(200 / 255));
      expect(scrim.g, greaterThan(200 / 255));
      expect(scrim.b, greaterThan(200 / 255));
      expect(scrim.a, closeTo(0.55, 0.001));
      expect(
        scrim,
        HaoThemes.of(HaoThemeId.appleGlass).light
            .extension<HaoTheme>()!
            .scaffoldBackground
            .withValues(alpha: 0.55),
      );
    });

    testWidgets('dark mode: scrim is a black wash', (tester) async {
      await _pumpLayer(
        tester,
        _theme(HaoThemeId.appleGlass, 0.0, true),
        wallpaperPath: _busyWallpaper,
      );
      expect(tester.takeException(), isNull);
      final scrim = _scrimColor(tester);
      expect(scrim.r, lessThan(20 / 255));
      expect(scrim.g, lessThan(20 / 255));
      expect(scrim.b, lessThan(20 / 255));
      expect(scrim.a, closeTo(0.55, 0.001));
    });
  });

  group('T2 transparency conservation (scheme A + library shadow)', () {
    testWidgets('helper at 100%: no shadows, either mode', (tester) async {
      expect(
        HaoTheme.legibilityShadowsFor(isDark: false, intensity: 1.0),
        isEmpty,
      );
      expect(
        HaoTheme.legibilityShadowsFor(isDark: true, intensity: 1.0),
        isEmpty,
      );
      expect(
        HaoTheme.legibilityShadowsFor(isDark: false, intensity: 1.5),
        isEmpty,
      );
    });

    testWidgets('helper at 0% light: white halo 0.60, blur 5, offset 0', (
      tester,
    ) async {
      final shadows = HaoTheme.legibilityShadowsFor(
        isDark: false,
        intensity: 0.0,
      );
      expect(shadows, hasLength(1));
      expect(shadows.single.color, Colors.white.withValues(alpha: 0.60));
      expect(shadows.single.blurRadius, 5.0);
      expect(shadows.single.offset, Offset.zero);
    });

    testWidgets('helper at 0% dark: black shadow 0.45, blur 5, offset (0,1)', (
      tester,
    ) async {
      final shadows = HaoTheme.legibilityShadowsFor(
        isDark: true,
        intensity: 0.0,
      );
      expect(shadows, hasLength(1));
      expect(shadows.single.color, Colors.black.withValues(alpha: 0.45));
      expect(shadows.single.blurRadius, 5.0);
      expect(shadows.single.offset, const Offset(0, 1));
    });

    testWidgets('helper scales with (1 - intensity), clamped', (
      tester,
    ) async {
      final half = HaoTheme.legibilityShadowsFor(
        isDark: false,
        intensity: 0.5,
      );
      expect(half.single.color.a, closeTo(0.30, 0.001));
      expect(
        HaoTheme.legibilityShadowsFor(isDark: false, intensity: -0.5),
        hasLength(1),
      );
      expect(
        HaoTheme.legibilityShadowsFor(isDark: false, intensity: -0.5)
            .single
            .color
            .a,
        closeTo(0.60, 0.001),
      );
    });

    // One theme per testWidgets: a second pumpWidget in the same test
    // still reads the FIRST theme — MaterialApp's AnimatedTheme is
    // mid-animation after one pump, so Theme.of returns the old
    // brightness (probe: b2 stayed light after pumping the dark theme).
    testWidgets('helper via context: light mode gives the white halo', (
      tester,
    ) async {
      List<Shadow>? out;
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(HaoThemeId.appleGlass, 0.0, false),
          home: Builder(
            builder: (context) {
              out = HaoTheme.legibilityShadows(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(out!.single.color, Colors.white.withValues(alpha: 0.60));
    });

    testWidgets('helper via context: dark mode gives the black shadow', (
      tester,
    ) async {
      List<Shadow>? out;
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(HaoThemeId.appleGlass, 0.0, true),
          home: Builder(
            builder: (context) {
              out = HaoTheme.legibilityShadows(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(out!.single.color, Colors.black.withValues(alpha: 0.45));
    });

    testWidgets('bare ThemeData (no HaoTheme) reads as intensity 1.0', (
      tester,
    ) async {
      List<Shadow>? out;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Builder(
            builder: (context) {
              out = HaoTheme.legibilityShadows(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(out, isEmpty);
    });

    testWidgets('GlassCard standard at 0%: outer shadow alpha is 0', (
      tester,
    ) async {
      await _pumpLibraryCard(tester, 0.0, GlassCardQuality.standard);
      expect(tester.takeException(), isNull);
      expect(_libraryOuterDeco(tester).boxShadow!.single.color.a, 0.0);
    });

    testWidgets('GlassCard premium at 0%: outer shadow alpha is 0', (
      tester,
    ) async {
      await _pumpLibraryCard(tester, 0.0, GlassCardQuality.premium);
      expect(tester.takeException(), isNull);
      expect(_libraryOuterDeco(tester).boxShadow!.single.color.a, 0.0);
    });

    testWidgets('GlassCard standard at 100%: Beans shadow untouched', (
      tester,
    ) async {
      await _pumpLibraryCard(tester, 1.0, GlassCardQuality.standard);
      expect(tester.takeException(), isNull);
      final shadow = _libraryOuterDeco(tester).boxShadow!.single;
      expect(shadow.color.a, closeTo(0.08, 0.001));
      expect(shadow.blurRadius, 9);
    });

    testWidgets('library settings at 0 use clear body mode', (
      tester,
    ) async {
      LiquidGlassSettings? ios27;
      LiquidGlassSettings? chrome;
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(HaoThemeId.appleGlass, 0.0, false),
          home: Builder(
            builder: (context) {
              ios27 = HaoLiquidGlass.ios27Settings(context);
              chrome = HaoLiquidGlass.chromeSettings(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(ios27!.bodyMode, GlassBodyMode.clear);
      expect(chrome!.bodyMode, GlassBodyMode.clear);
      // Visibility stays 1.0 at 0% — the child must stay opaque.
      expect(ios27!.visibility, 1.0);
      expect(chrome!.visibility, 1.0);
    });

    testWidgets('library settings above 0 keep the adaptive body mode', (
      tester,
    ) async {
      LiquidGlassSettings? ios27;
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(HaoThemeId.appleGlass, 0.5, false),
          home: Builder(
            builder: (context) {
              ios27 = HaoLiquidGlass.ios27Settings(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(ios27!.bodyMode, GlassBodyMode.adaptive);
    });
  });

  // T3 goldens are warmed by the T2 library-card pumps above: the
  // very first GlassContainer render in a process still paints the
  // adaptive body wash even in clear bodyMode (see
  // glass_intensity_test.dart warm-up note), so a 0% golden must
  // never be the first library render in its file.
  group('T3 render matrix (0% scene)', () {
    Future<void> goldenScene(
      WidgetTester tester, {
      required _WallpaperKind wallpaper,
      required HaoThemeId id,
      required bool isDark,
      required double intensity,
      required bool glass,
      required String prefix,
    }) async {
      await _pumpScene(
        tester,
        id: id,
        isDark: isDark,
        intensity: intensity,
        wallpaper: wallpaper,
        glass: glass,
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(_sceneName(prefix, wallpaper, id, isDark)),
      );
    }

    for (final wallpaper in _WallpaperKind.values) {
      testWidgets('golden: 0% ${wallpaper.name} appleGlass light', (
        tester,
      ) async {
        await goldenScene(
          tester,
          wallpaper: wallpaper,
          id: HaoThemeId.appleGlass,
          isDark: false,
          intensity: 0.0,
          glass: true,
          prefix: 'b28_glass0',
        );
      });
      testWidgets('golden: 0% ${wallpaper.name} appleGlass dark', (
        tester,
      ) async {
        await goldenScene(
          tester,
          wallpaper: wallpaper,
          id: HaoThemeId.appleGlass,
          isDark: true,
          intensity: 0.0,
          glass: true,
          prefix: 'b28_glass0',
        );
      });
    }
    testWidgets('golden: 0% busy darkGold light', (tester) async {
      await goldenScene(
        tester,
        wallpaper: _WallpaperKind.busy,
        id: HaoThemeId.darkGold,
        isDark: false,
        intensity: 0.0,
        glass: true,
        prefix: 'b28_glass0',
      );
    });
    testWidgets('golden: 0% busy darkGold dark', (tester) async {
      await goldenScene(
        tester,
        wallpaper: _WallpaperKind.busy,
        id: HaoThemeId.darkGold,
        isDark: true,
        intensity: 0.0,
        glass: true,
        prefix: 'b28_glass0',
      );
    });
    testWidgets('golden: 0% busy freshMint light', (tester) async {
      await goldenScene(
        tester,
        wallpaper: _WallpaperKind.busy,
        id: HaoThemeId.freshMint,
        isDark: false,
        intensity: 0.0,
        glass: true,
        prefix: 'b28_glass0',
      );
    });
    testWidgets('golden: 0% busy polarIce dark', (tester) async {
      await goldenScene(
        tester,
        wallpaper: _WallpaperKind.busy,
        id: HaoThemeId.polarIce,
        isDark: true,
        intensity: 0.0,
        glass: true,
        prefix: 'b28_glass0',
      );
    });

    testWidgets('golden: 100% control busy appleGlass light', (
      tester,
    ) async {
      await goldenScene(
        tester,
        wallpaper: _WallpaperKind.busy,
        id: HaoThemeId.appleGlass,
        isDark: false,
        intensity: 1.0,
        glass: true,
        prefix: 'b28_glass100',
      );
    });
    testWidgets('golden: 100% control busy appleGlass dark', (
      tester,
    ) async {
      await goldenScene(
        tester,
        wallpaper: _WallpaperKind.busy,
        id: HaoThemeId.appleGlass,
        isDark: true,
        intensity: 1.0,
        glass: true,
        prefix: 'b28_glass100',
      );
    });

    for (final wallpaper in _WallpaperKind.values) {
      testWidgets('golden: baseline ${wallpaper.name} appleGlass light', (
        tester,
      ) async {
        await goldenScene(
          tester,
          wallpaper: wallpaper,
          id: HaoThemeId.appleGlass,
          isDark: false,
          intensity: 0.0,
          glass: false,
          prefix: 'b28_baseline',
        );
      });
      testWidgets('golden: baseline ${wallpaper.name} appleGlass dark', (
        tester,
      ) async {
        await goldenScene(
          tester,
          wallpaper: wallpaper,
          id: HaoThemeId.appleGlass,
          isDark: true,
          intensity: 0.0,
          glass: false,
          prefix: 'b28_baseline',
        );
      });
    }

    testWidgets('every Text/Icon carries shadows at 0%, none at 100%', (
      tester,
    ) async {
      await _pumpScene(
        tester,
        id: HaoThemeId.appleGlass,
        isDark: false,
        intensity: 0.0,
        wallpaper: _WallpaperKind.busy,
        glass: true,
      );
      final texts0 = tester.widgetList<Text>(find.byType(Text));
      expect(texts0, isNotEmpty);
      for (final t in texts0) {
        expect(t.style?.shadows, isNotEmpty);
      }
      final icons0 = tester.widgetList<Icon>(find.byType(Icon));
      expect(icons0, isNotEmpty);
      for (final i in icons0) {
        expect(i.shadows, isNotEmpty);
      }
    });

    testWidgets('100%: every Text/Icon has empty shadows', (tester) async {
      await _pumpScene(
        tester,
        id: HaoThemeId.appleGlass,
        isDark: false,
        intensity: 1.0,
        wallpaper: _WallpaperKind.busy,
        glass: true,
      );
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        expect(t.style?.shadows ?? const <Shadow>[], isEmpty);
      }
      for (final i in tester.widgetList<Icon>(find.byType(Icon))) {
        expect(i.shadows ?? const <Shadow>[], isEmpty);
      }
    });
  });

  group('T4 icon probe (A1 glyph == Icon; native Icon.shadows)', () {
    Future<void> pumpIconProbe(
      WidgetTester tester,
      Widget child,
      String golden,
    ) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: Colors.white,
            body: Center(child: child),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/$golden'),
      );
    }

    testWidgets('A1: icon glyph as Text', (tester) async {
      const icon = Icons.home;
      await pumpIconProbe(
        tester,
        Text(
          String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            fontSize: 48,
            color: Colors.black,
            shadows: HaoTheme.legibilityShadowsFor(
              isDark: false,
              intensity: 0.0,
            ),
          ),
        ),
        'b28_glass0_probe_a1.png',
      );
    });

    testWidgets('Icon baseline (same glyph, same shadows via Icon.shadows)', (
      tester,
    ) async {
      await pumpIconProbe(
        tester,
        Icon(
          Icons.home,
          size: 48,
          color: Colors.black,
          shadows: HaoTheme.legibilityShadowsFor(
            isDark: false,
            intensity: 0.0,
          ),
        ),
        'b28_glass0_probe_icon.png',
      );
    });
  });
}
