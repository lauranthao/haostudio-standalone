// Crash probe for the danmaku settings page (chen: 打开直播弹幕设置会闪退,
// build 30). The page pumps fine with default Hive data (see
// danmaku_settings_page_test.dart), so the crash must come from either
// (a) wrong-typed values already stored in Hive on the phone, or (b) the
// Get.to push path from the settings tab / live room. This probe seeds
// hostile values for every danmaku key and exercises the real push.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/settings/danmaku_settings_page.dart';

import 'helpers/hive_test_setup.dart' as hive_setup;

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-danmaku-probe-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  // Each test starts from a clean box: the hostile seeds of one test
  // must not poison the next (the Get.to test failed once on the
  // previous test's seeded Strings, not on the push itself).
  setUp(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await HiveStore.box.clear();
    });
  });

  Future<void> seed(WidgetTester tester, Map<String, Object> values) async {
    await tester.runAsync(() async {
      for (final e in values.entries) {
        await HiveStore.box.put(e.key, e.value);
      }
    });
    await tester.pump();
  }

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 874);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: const DanmakuSettingsPage(),
      ),
    );
    await tester.pump();
  }

  testWidgets('hostile stored values do not crash the page', (tester) async {
    await seed(tester, {
      // Numbers stored as strings (the `as num?` casts in
      // DanmakuSettings throw TypeError on these).
      HiveKeys.danmakuFontSize: '14',
      HiveKeys.danmakuOpacity: '1.0',
      HiveKeys.danmakuSimilarityThreshold: '85',
      HiveKeys.danmakuMaxCount: '80',
      HiveKeys.danmakuBlockLongLength: '30',
      // Numbers stored as the wrong type entirely.
      HiveKeys.danmakuStrokeWidth: true,
      HiveKeys.danmakuSpeed: [1.0],
      // Corrupt JSON blobs.
      HiveKeys.danmakuEnabled: '{not json',
      HiveKeys.danmakuBlockList: '[{bad',
      // Unknown enum strings (getters already fall back).
      HiveKeys.danmakuArea: 'nowhere',
      HiveKeys.danmakuColorMode: 'rainbow',
      HiveKeys.danmakuListStyle: 'grid',
      HiveKeys.danmakuListSpacing: 'huge',
      // Bool stored as a string.
      HiveKeys.danmakuShowUsernames: 'yes',
      HiveKeys.danmakuStroke: 'on',
    });
    await pumpPage(tester);
    expect(find.text('弹幕设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await hive_setup.drainHiveWrites(tester);
  });

  testWidgets('Get.to push from a settings-like page does not crash', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 874);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Get.to(() => const DanmakuSettingsPage()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('弹幕设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await hive_setup.drainHiveWrites(tester);
  });
}
