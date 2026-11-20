// Tab-bar accent colour: no choice stored (null — the theme's own
// accent shows), set() persists to Hive and applies immediately
// through the Rx.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/tab_bar_accent.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-accent-test-');
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
    await HiveStore.delete(HiveKeys.tabBarAccentColor);
    Get.delete<TabBarAccentController>(force: true);
  });

  tearDown(() {
    Get.delete<TabBarAccentController>(force: true);
  });

  test('no stored colour means no choice (null), not a fake red',
      () {
    final controller = TabBarAccentController.ensure();
    // P0-5: a fresh install shows the theme's own accent — the
    // controller holds no colour at all until the user picks one.
    expect(controller.color.value, isNull);
  });

  test('setColor persists and applies immediately', () async {
    const blue = Color(0xFF2563EB);
    final controller = TabBarAccentController.ensure();
    await controller.setColor(blue);
    expect(controller.color.value, blue);
    expect(
      HiveStore.getInt(
        HiveKeys.tabBarAccentColor,
        0,
      ),
      blue.toARGB32(),
    );
  });

  test('a fresh controller loads the persisted colour', () async {
    const green = Color(0xFF16A34A);
    await TabBarAccentController.ensure().setColor(green);
    Get.delete<TabBarAccentController>(force: true);
    expect(TabBarAccentController.ensure().color.value, green);
  });
}
