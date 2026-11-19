// Accent-colour sheet: grid pick applies to the tab bar
// immediately, opacity / presets / segments work, and the dropper
// samples the captured app frame.
//
// Harness: a Scaffold with the real GlassTabBar (currentIndex 0) and
// a button that opens the sheet — so a pick's effect on the tab bar
// is asserted directly, not just on the controller.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/core/theme/screen_capture.dart';
import 'package:standalone/core/theme/tab_bar_accent.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/settings/accent_color_sheet.dart';
import 'package:standalone/features/settings/accent_dropper_page.dart';
import 'package:standalone/features/settings/settings_tab_page.dart';
import 'package:standalone/widgets/app_shell.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-accent-sheet-');
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
      'test_settings',
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
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  /// Pump a Scaffold holding the real tab bar + a button that opens
  /// the colour sheet.
  Future<void> pumpBarWithSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
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
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    expect(find.text('网格'), findsOneWidget);
    expect(find.text('光谱'), findsOneWidget);
    expect(find.text('滑块'), findsOneWidget);
  }

  Color tabIconColor(WidgetTester tester, int i) =>
      tester.widget<Icon>(find.byType(Icon).at(i)).color!;

  testWidgets('grid pick applies to the tab bar immediately',
      (tester) async {
    await pumpBarWithSheet(tester);
    await openSheet(tester);
    expect(
      tabIconColor(tester, 0),
      TabBarAccentController.defaultColor,
    );

    // Hue 0 (red), row 4 (middle lightness): HSV(0, 0.55, 0.6).
    await tester.tap(find.byKey(const ValueKey('accent-grid-0.0-4')));
    await tester.pumpAndSettle();
    final expected =
        HSVColor.fromAHSV(1.0, 0, 0.55, 0.6).toColor();
    expect(TabBarAccentController.ensure().color.value, expected);
    expect(tabIconColor(tester, 0), expected);
  });

  testWidgets('segments switch between grid / spectrum / sliders',
      (tester) async {
    await pumpBarWithSheet(tester);
    await openSheet(tester);
    expect(find.byKey(const ValueKey('accent-grid-0.0-4')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('accent-mode-spectrum')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('accent-hue-strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-sv-square')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('accent-mode-sliders')));
    await tester.pumpAndSettle();
    expect(find.text('色相'), findsOneWidget);
    expect(find.text('饱和度'), findsOneWidget);
    expect(find.text('明度'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('accent-mode-grid')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('accent-grid-0.0-4')), findsOneWidget);
  });

  testWidgets('opacity slider stores the colour with its opacity',
      (tester) async {
    await pumpBarWithSheet(tester);
    await openSheet(tester);

    // Tap the opacity track at 25% of its width.
    final rect = tester.getRect(
      find.byKey(const ValueKey('accent-opacity-slider')),
    );
    await tester.tapAt(Offset(rect.left + rect.width * 0.25, rect.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('25%'), findsOneWidget);
    final color = TabBarAccentController.ensure().color.value;
    expect(color.a, closeTo(0.25, 0.02));
    // The tab bar reads the same translucent colour.
    expect(tabIconColor(tester, 0).a, closeTo(0.25, 0.02));
  });

  testWidgets('preset + adds, persists, long-press deletes customs only',
      (tester) async {
    await pumpBarWithSheet(tester);
    await openSheet(tester);
    // The default red is not one of the 5 built-ins, so + adds it.
    await tester.tap(find.byKey(const ValueKey('accent-preset-add')));
    await tester.pumpAndSettle();
    final red = TabBarAccentController.defaultColor;
    expect(
      find.byKey(ValueKey('accent-preset-${red.toARGB32()}')),
      findsOneWidget,
    );
    expect(
      AccentPresetStore.loadCustoms(),
      contains(red),
    );

    // Long-press the custom preset: it is removed.
    await tester.longPress(
      find.byKey(ValueKey('accent-preset-${red.toARGB32()}')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('accent-preset-${red.toARGB32()}')),
      findsNothing,
    );
    expect(AccentPresetStore.loadCustoms(), isNot(contains(red)));

    // Long-press a built-in (black): it stays.
    const black = Color(0xFF000000);
    await tester.longPress(
      find.byKey(ValueKey('accent-preset-${black.toARGB32()}')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('accent-preset-${black.toARGB32()}')),
      findsOneWidget,
    );
  });

  testWidgets('tapping a preset dot applies it', (tester) async {
    await pumpBarWithSheet(tester);
    await openSheet(tester);
    const blue = Color(0xFF2563EB);
    await tester.tap(
      find.byKey(ValueKey('accent-preset-${blue.toARGB32()}')),
    );
    await tester.pumpAndSettle();
    expect(TabBarAccentController.ensure().color.value, blue);
    expect(tabIconColor(tester, 0), blue);
  });

  testWidgets('settings row opens the sheet', (tester) async {
    // SettingsTabPage reads ThemeController via Get.find.
    Get.put(ThemeController());
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: const SettingsTabPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('自定义强调色'), findsOneWidget);
    expect(find.byType(AccentRingButton), findsOneWidget);

    await tester.tap(find.text('自定义强调色'));
    await tester.pumpAndSettle();
    expect(find.text('网格'), findsOneWidget);
  });

  testWidgets('sheet opens cleanly in all 4 themes x light/dark',
      (tester) async {
    for (final id in HaoThemeId.values) {
      for (final dark in [false, true]) {
        tester.view.physicalSize = const Size(780, 1688);
        tester.view.devicePixelRatio = 2.0;
        final themes = HaoThemes.of(id);
        await tester.pumpWidget(
          GetMaterialApp(
            theme: dark ? themes.dark : themes.light,
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
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('open sheet'));
        await tester.pumpAndSettle();
        expect(
          find.text('网格'),
          findsOneWidget,
          reason: 'sheet opens in $id ${dark ? 'dark' : 'light'}',
        );
        // The preview shows the default red in every theme/mode.
        final preview = tester.widget<Container>(
          find.byKey(const ValueKey('accent-preview')),
        );
        final decoration = preview.decoration as BoxDecoration;
        expect(
          decoration.color,
          TabBarAccentController.defaultColor,
          reason: 'preview is default red in $id ${dark ? 'dark' : 'light'}',
        );
        await tester.tap(find.byKey(const ValueKey('accent-close')));
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('dropper samples the captured frame', (tester) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const green = Color(0xFF00FF00);
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: ScreenCapture.boundaryKey,
            child: Container(color: green),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // toImage()/toByteData() complete via the engine's real event
    // loop, which the fake-async test zone blocks — run them in
    // runAsync (this is a test-harness constraint only; in the
    // real app the same calls complete normally).
    ui.Image? image;
    await tester.runAsync(() async {
      image = await ScreenCapture.capture();
    });
    expect(image, isNotNull);
    // The whole frame is green: the centre pixel is green.
    final captured = image!;
    Color? centre;
    await tester.runAsync(() async {
      centre = await ScreenCapture.sample(
        captured,
        Offset(captured.width / 2, captured.height / 2),
      );
    });
    expect(centre, green);

    // The dropper page: tapping the centre returns the green.
    Color? picked;
    await tester.pumpWidget(
      GetMaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await Navigator.of(context).push<Color>(
                MaterialPageRoute<Color>(
                  builder: (_) => AccentDropperPage(image: image!),
                ),
              );
            },
            child: const Text('open dropper'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open dropper'));
    await tester.pumpAndSettle();
    // The tap runs the dropper's sample (toByteData) — real async.
    // The sample's Future only completes while the real event loop
    // is turning, so the tap AND the wait for the pop both happen
    // inside runAsync: each iteration lets the engine finish the
    // readback (real 20ms) and pumps a frame (gesture + pop).
    await tester.runAsync(() async {
      await tester.tapAt(const Offset(200, 200));
      for (var i = 0; i < 50 && picked == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 16));
      }
    });
    await tester.pumpAndSettle();
    expect(picked, green);
  });

  testWidgets('dropper close button pops without picking',
      (tester) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final image = await _solidImageInTest(tester, const Color(0xFF0000FF));
    Color? picked = const Color(0xFF123456);
    await tester.pumpWidget(
      GetMaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await Navigator.of(context).push<Color>(
                MaterialPageRoute<Color>(
                  builder: (_) => AccentDropperPage(image: image),
                ),
              );
            },
            child: const Text('open dropper'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open dropper'));
    await tester.pumpAndSettle();
    // The × is the close icon in the dropper page.
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(picked, isNull);
  });
}

/// A solid-colour image, for the dropper close test (no capture).
/// `Picture.toImage` needs the real event loop (see the dropper
/// test), so it is created inside runAsync.
Future<ui.Image> _solidImageInTest(
  WidgetTester tester,
  Color color,
) async {
  ui.Image? image;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 400, 400),
      ui.Paint()..color = color,
    );
    image = await recorder.endRecording().toImage(400, 400);
  });
  return image!;
}
