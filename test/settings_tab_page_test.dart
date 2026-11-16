// Settings page: collapsible player-engine section + About at the bottom.
//
// - The 播放器引擎 group starts collapsed (only the current engine name
//   shows as a summary); tapping the header expands / collapses it and
//   the state persists in Hive (`engineSectionExpanded`).
// - The 关于 section (版本 / 检查更新 / 直播崩溃记录) is the last
//   section on the page, after every other settings group.

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
    hiveDir = await Directory.systemTemp.createTemp('hao-settings-test-');
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
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    Get.put(ThemeController());
  });

  tearDown(() {
    Get.reset();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // Tall viewport so the whole ListView lays out at once.
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
  }

  testWidgets('engine section starts collapsed, tap expands and persists',
      (tester) async {
    await HiveStore.box.delete(HiveKeys.engineSectionExpanded);
    await pumpPage(tester);

    // Collapsed: no engine radios, current engine shown as a summary.
    expect(find.byType(RadioListTile<String>), findsNothing);
    expect(find.text('MPV'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

    // Expand: all three engines appear; the state is persisted.
    await tester.tap(find.text('播放器引擎'));
    await tester.pumpAndSettle();
    expect(find.byType(RadioListTile<String>), findsNWidgets(3));
    expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
    expect(HiveStore.getBool(HiveKeys.engineSectionExpanded, false), isTrue);

    // Collapse again: radios gone, persisted as false.
    await tester.tap(find.text('播放器引擎'));
    await tester.pumpAndSettle();
    expect(find.byType(RadioListTile<String>), findsNothing);
    expect(HiveStore.getBool(HiveKeys.engineSectionExpanded, true), isFalse);
  });

  testWidgets('engine section restores expanded state from Hive',
      (tester) async {
    await HiveStore.put(HiveKeys.engineSectionExpanded, true);
    await pumpPage(tester);

    expect(find.byType(RadioListTile<String>), findsNWidgets(3));
    expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
  });

  testWidgets('about section is the last section on the page',
      (tester) async {
    await pumpPage(tester);

    // 关于 sits below every other section's last row (缓存管理) and
    // its own rows (版本 / 检查更新 / 直播崩溃记录) follow it.
    final aboutTop = tester.getTopLeft(find.text('关于')).dy;
    final cacheTop = tester.getTopLeft(find.text('缓存管理')).dy;
    final versionTop = tester.getTopLeft(find.text('版本')).dy;
    final updateTop = tester.getTopLeft(find.text('检查更新')).dy;
    final crashTop = tester.getTopLeft(find.text('直播崩溃记录')).dy;

    expect(aboutTop, greaterThan(cacheTop));
    expect(versionTop, greaterThan(aboutTop));
    expect(updateTop, greaterThan(versionTop));
    expect(crashTop, greaterThan(updateTop));
  });
}
