// Visual smoke check: SettingsTabPage pumps cleanly (no layout
// exception / overflow) in all 8 theme x light/dark combinations.
// Covers the visual-polish rule: every change must read in every
// combination, not just light mode.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/settings/settings_tab_page.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-settings-smoke-');
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
      'test_settings_smoke',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    Get.put(ThemeController());
  });

  tearDown(() {
    Get.reset();
  });

  for (final id in HaoThemeId.values) {
    for (final dark in [false, true]) {
      testWidgets(
        'settings renders: ${HaoThemes.names[id]} ${dark ? 'dark' : 'light'}',
        (tester) async {
          final pair = HaoThemes.of(id);
          tester.view.physicalSize = const Size(800, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });
          await tester.pumpWidget(
            GetMaterialApp(
              theme: pair.light,
              darkTheme: pair.dark,
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              home: const SettingsTabPage(),
            ),
          );
          await tester.pumpAndSettle();
          // CupertinoSliverNavigationBar keeps two Text('设置') in the
          // tree: the large title (visible at rest) and the collapsed
          // nav-bar title (shown only after scrolling). The settings
          // goldens verify only one is visible at rest.
          expect(find.text('设置'), findsNWidgets(2));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
