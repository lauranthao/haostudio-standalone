// Custom accent colour (settings -> 自定义强调色) is the app-wide
// accent, not just the tab bar.
//
// - HaoThemes.of(id, accentOverride: c): every theme x light/dark
//   resolves HaoTheme.accent / colorScheme.primary / primaryColor
//   to c, with a readable onAccent (white on dark accents,
//   near-black on light ones); liveRed, text colours and surfaces
//   do not move.
// - ThemeController.customAccent drives the root theme (lightTheme /
//   darkTheme); a translucent pick is stored opaque for the theme
//   (the tab bar keeps the translucency); loadFromBox restores it;
//   clearCustomAccent restores the per-theme defaults.
// - The sheet's 恢复默认 deletes the stored colour and clears the
//   override (no custom colour: the theme's own accent shows).
//
// Harness mirrors tab_bar_accent_test.dart (temp Hive dir +
// in-memory test box); the sheet section mirrors
// accent_color_sheet_test.dart (real GlassTabBar + sheet).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/core/theme/tab_bar_accent.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/settings/accent_color_sheet.dart';
import 'package:standalone/widgets/app_shell.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-custom-accent-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    final memBox = await Hive.openBox<dynamic>(
      'test_custom_accent',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    HaoHaptics.debugEnabledOverride = false;
    await HiveStore.delete(HiveKeys.tabBarAccentColor);
    await HiveStore.delete(HiveKeys.tabBarAccentPresets);
    Get.delete<TabBarAccentController>(force: true);
    Get.delete<ThemeController>(force: true);
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  HaoTheme haoThemeOf(ThemeData theme) =>
      theme.extension<HaoTheme>()!;

  group('HaoThemes.of with accentOverride', () {
    const blue = Color(0xFF2563EB);

    test('all 4 themes x light/dark resolve accent to the override',
        () {
      for (final id in HaoThemeId.values) {
        final pair = HaoThemes.of(id, accentOverride: blue);
        for (final theme in [pair.light, pair.dark]) {
          expect(haoThemeOf(theme).accent, blue);
          expect(theme.colorScheme.primary, blue);
          expect(theme.colorScheme.secondary, blue);
          expect(theme.primaryColor, blue);
          expect(theme.colorScheme.onPrimary, Colors.white);
        }
      }
    });

    test('light override gets a dark onAccent, dark override white',
        () {
      const yellow = Color(0xFFFACC15);
      final lightPair = HaoThemes.of(
        HaoThemeId.appleGlass,
        accentOverride: yellow,
      );
      expect(lightPair.light.colorScheme.onPrimary,
          const Color(0xFF0B0B0F));
      expect(lightPair.dark.colorScheme.onPrimary,
          const Color(0xFF0B0B0F));
      expect(
        haoThemeOf(lightPair.light).accentSoft,
        yellow.withValues(alpha: 0.14),
      );
      const black = Color(0xFF000000);
      final darkPair = HaoThemes.of(
        HaoThemeId.darkGold,
        accentOverride: black,
      );
      expect(darkPair.light.colorScheme.onPrimary, Colors.white);
      expect(darkPair.dark.colorScheme.onPrimary, Colors.white);
    });

    test('no override keeps the per-theme defaults', () {
      expect(
        haoThemeOf(HaoThemes.of(HaoThemeId.appleGlass).light).accent,
        const Color(0xFF000000),
      );
      expect(
        haoThemeOf(HaoThemes.of(HaoThemeId.appleGlass).dark).accent,
        const Color(0xFF76767A),
      );
      expect(
        haoThemeOf(HaoThemes.of(HaoThemeId.darkGold).dark).accent,
        const Color(0xFFD4AF37),
      );
      expect(
        haoThemeOf(HaoThemes.of(HaoThemeId.freshMint).light).accent,
        const Color(0xFF00897B),
      );
      expect(
        haoThemeOf(HaoThemes.of(HaoThemeId.polarIce).dark).accent,
        const Color(0xFF76767A),
      );
    });

    test('override never moves liveRed, text or surfaces', () {
      const red = Color(0xFFEF4444);
      for (final id in HaoThemeId.values) {
        final plain = HaoThemes.of(id);
        final over = HaoThemes.of(id, accentOverride: red);
        for (final i in [0, 1]) {
          final a = [plain.light, plain.dark][i];
          final b = [over.light, over.dark][i];
          expect(haoThemeOf(b).liveRed, haoThemeOf(a).liveRed);
          expect(haoThemeOf(b).liveRed, const Color(0xFFE5484D));
          expect(haoThemeOf(b).textPrimary, haoThemeOf(a).textPrimary);
          expect(haoThemeOf(b).textSecondary, haoThemeOf(a).textSecondary);
          expect(haoThemeOf(b).textMuted, haoThemeOf(a).textMuted);
          expect(haoThemeOf(b).surface, haoThemeOf(a).surface);
          expect(haoThemeOf(b).surfaceSolid, haoThemeOf(a).surfaceSolid);
          expect(haoThemeOf(b).scaffoldBackground,
              haoThemeOf(a).scaffoldBackground);
          expect(b.colorScheme.error, a.colorScheme.error);
        }
      }
    });

    test('ThemeData sub-themes follow the override', () {
      const green = Color(0xFF22C55E);
      final theme = HaoThemes.of(
        HaoThemeId.freshMint,
        accentOverride: green,
      ).light;
      expect(
        theme.switchTheme.trackColor!.resolve({WidgetState.selected}),
        green,
      );
      expect(
        theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
        green,
      );
      expect(theme.sliderTheme.activeTrackColor, green);
      expect(theme.sliderTheme.thumbColor, green);
      expect(theme.progressIndicatorTheme.color, green);
      expect(theme.chipTheme.selectedColor, green.withValues(alpha: 0.14));
      expect(theme.textButtonTheme.style!.foregroundColor!.resolve({}),
          green);
      expect(theme.radioTheme.fillColor!.resolve({WidgetState.selected}),
          green);
    });
  });

  group('ThemeController.customAccent', () {
    test('set applies to light + dark themes, translucent -> opaque',
        () {
      final controller = ThemeController();
      const translucent = Color(0x802563EB);
      controller.setCustomAccent(translucent);
      expect(controller.customAccent.value, const Color(0xFF2563EB));
      expect(haoThemeOf(controller.lightTheme).accent,
          const Color(0xFF2563EB));
      expect(haoThemeOf(controller.darkTheme).accent,
          const Color(0xFF2563EB));
      expect(controller.lightTheme.colorScheme.primary,
          const Color(0xFF2563EB));
    });

    test('clear restores the per-theme defaults', () {
      final controller = ThemeController();
      controller.setCustomAccent(const Color(0xFF2563EB));
      controller.clearCustomAccent();
      expect(controller.customAccent.value, isNull);
      expect(
        haoThemeOf(controller.lightTheme).accent,
        haoThemeOf(HaoThemes.of(HaoThemeId.appleGlass).light).accent,
      );
    });

    test('switching themes keeps the custom colour', () {
      final controller = ThemeController();
      controller.setCustomAccent(const Color(0xFFEF4444));
      controller.setTheme(HaoThemeId.darkGold);
      expect(haoThemeOf(controller.lightTheme).accent,
          const Color(0xFFEF4444));
      expect(haoThemeOf(controller.darkTheme).accent,
          const Color(0xFFEF4444));
      controller.setTheme(HaoThemeId.polarIce);
      expect(haoThemeOf(controller.darkTheme).accent,
          const Color(0xFFEF4444));
    });

    test('loadFromBox restores a stored colour (opaque form)', () {
      const translucent = Color(0x802563EB);
      HiveStore.box.put(
        HiveKeys.tabBarAccentColor,
        translucent.toARGB32(),
      );
      final controller = ThemeController();
      controller.loadFromBox(HiveStore.box);
      expect(controller.customAccent.value, const Color(0xFF2563EB));
    });

    test('loadFromBox with no stored colour leaves null', () {
      final controller = ThemeController();
      controller.loadFromBox(HiveStore.box);
      expect(controller.customAccent.value, isNull);
    });
  });

  group('TabBarAccentController.reset', () {
    test('deletes the stored colour and leaves no choice (null)',
        () async {
      const blue = Color(0xFF2563EB);
      final controller = TabBarAccentController.ensure();
      await controller.setColor(blue);
      expect(
        HiveStore.getInt(HiveKeys.tabBarAccentColor, 0),
        blue.toARGB32(),
      );
      await controller.reset();
      expect(controller.color.value, isNull);
      expect(HiveStore.box.containsKey(HiveKeys.tabBarAccentColor),
          isFalse);
    });
  });

  group('sheet reset', () {
    Future<void> pumpBarWithSheet(WidgetTester tester) async {
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      // The test puts ThemeController before pumping (its handle
      // must stay the one the sheet writes to — never delete/re-put
      // here). Rebuild GetMaterialApp from it so a pick flows to
      // the tab bar through the theme accent (Kumone restore,
      // chen 2026-11-21: selected icon = theme accent).
      final themeController = Get.find<ThemeController>();
      await tester.pumpWidget(
        Obx(
          () => GetMaterialApp(
            theme: themeController.lightTheme,
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: Builder(
                        builder: (context) => TextButton(
                          onPressed: () => showAccentColorSheet(context),
                          child: const Text('open sheet'),
                        ),
                      ),
                    ),
                  ),
                  GlassTabBar(currentIndex: 0, onTap: (_) {}),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Color tabIconColor(WidgetTester tester, int i) =>
        tester.widget<Icon>(find.byType(Icon).at(i)).color!;

    testWidgets('pick recolours the theme override; reset clears it',
        (tester) async {
      final themeController = Get.put(ThemeController());
      await pumpBarWithSheet(tester);
      expect(find.text('恢复默认'), findsNothing);

      await tester.tap(find.text('open sheet'));
      await tester.pumpAndSettle();
      expect(find.text('网格'), findsOneWidget);
      expect(find.text('恢复默认'), findsOneWidget);

      // Hue 0 (red), row 4: HSV(0, 0.55, 0.6) — same cell the sheet
      // test uses.
      await tester.tap(find.byKey(const ValueKey('accent-grid-0.0-4')));
      await tester.pumpAndSettle();
      final expected = HSVColor.fromAHSV(1.0, 0, 0.55, 0.6).toColor();
      expect(TabBarAccentController.ensure().color.value, expected);
      expect(themeController.customAccent.value, expected);
      // Kumone restore (chen 2026-11-21): the pick recolours the
      // theme override, and the SELECTED tab icon follows it.
      expect(tabIconColor(tester, 0), expected);

      await tester.tap(find.byKey(const ValueKey('accent-reset-default')));
      await tester.pumpAndSettle();
      expect(
        TabBarAccentController.ensure().color.value,
        isNull,
      );
      expect(themeController.customAccent.value, isNull);
      // Reset restores the theme's own accent (appleGlass light:
      // black) as the selected icon.
      final themeAccent = HaoThemes.of(HaoThemeId.appleGlass)
          .light
          .extension<HaoTheme>()!
          .accent;
      expect(tabIconColor(tester, 0), themeAccent);
      expect(HiveStore.box.containsKey(HiveKeys.tabBarAccentColor),
          isFalse);
    });
  });

  group('P1-U6: no purple/magenta custom accent', () {
    double hueOf(Color c) => HSVColor.fromColor(c).hue;

    test('clampAccentHue: 260-320 band clamps to 260 blue', () {
      final purple = HSVColor.fromAHSV(1, 280, 0.8, 0.9).toColor();
      expect(hueOf(clampAccentHue(purple)), closeTo(260, 0.5));
      final magenta = HSVColor.fromAHSV(1, 300, 1, 1).toColor();
      expect(hueOf(clampAccentHue(magenta)), closeTo(260, 0.5));
      // Boundaries and outside the band pass through.
      expect(
        hueOf(clampAccentHue(HSVColor.fromAHSV(1, 260, 0.8, 0.9).toColor())),
        closeTo(260, 0.5),
      );
      expect(
        hueOf(clampAccentHue(HSVColor.fromAHSV(1, 240, 0.8, 0.9).toColor())),
        closeTo(240, 0.5),
      );
      expect(
        hueOf(clampAccentHue(HSVColor.fromAHSV(1, 330, 0.8, 0.9).toColor())),
        closeTo(330, 0.5),
      );
      expect(
        hueOf(clampAccentHue(HSVColor.fromAHSV(1, 0, 0.8, 0.9).toColor())),
        closeTo(0, 0.5),
      );
    });

    test('setCustomAccent clamps a purple pick to blue', () {
      final controller = ThemeController();
      controller.setCustomAccent(
        HSVColor.fromAHSV(1, 285, 0.9, 0.9).toColor(),
      );
      expect(hueOf(controller.customAccent.value!), closeTo(260, 0.5));
    });

    test('setColor stores the clamped colour, not the purple', () async {
      final controller = TabBarAccentController.ensure();
      await controller.setColor(
        HSVColor.fromAHSV(1, 300, 1, 1).toColor(),
      );
      expect(hueOf(controller.color.value!), closeTo(260, 0.5));
      expect(
        hueOf(Color(HiveStore.getInt(HiveKeys.tabBarAccentColor, 0))),
        closeTo(260, 0.5),
      );
    });

    test('loadFromBox clamps a stored purple from before the fix', () {
      HiveStore.box.put(
        HiveKeys.tabBarAccentColor,
        HSVColor.fromAHSV(1, 290, 0.9, 0.9).toColor().toARGB32(),
      );
      final controller = ThemeController();
      controller.loadFromBox(HiveStore.box);
      expect(hueOf(controller.customAccent.value!), closeTo(260, 0.5));
    });
  });
}
