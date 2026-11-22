// Build-29 music UI tests.
//
// - Equalizer page: the AutoEq section renders and tapping a
//   headphone preset applies its gains through the real store.
//
// Hive uses the shared test setup (temp dir + path_provider mock);
// the equalizer method channel is mocked (no native engine on
// Linux), so syncToNative just no-ops.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/music/equalizer_page.dart';
import 'package:standalone/services/music/autoeq_presets.dart';
import 'package:standalone/services/music/equalizer_store.dart';

import 'helpers/hive_test_setup.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init(prefix: 'hao-b29-music-ui-test-');
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  setUp(() async {
    Get.put(ThemeController());
    EqualizerStore.resetForTest();
    for (final key in [
      HiveKeys.equalizerEnabled,
      HiveKeys.equalizerBandGains,
      HiveKeys.equalizerPreset,
      HiveKeys.equalizerCustomPresetName,
      HiveKeys.equalizerPreamp,
      HiveKeys.equalizerCustomPresets,
      'hao_eq_autoeq_name',
      HiveKeys.musicFav,
      HiveKeys.musicRecent,
      HiveKeys.musicListen,
    ]) {
      await HiveStore.box.delete(key);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.haostudio.standalone/equalizer'),
          (call) async => null,
        );
  });

  tearDown(() {
    Get.reset();
    EqualizerStore.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.haostudio.standalone/equalizer'),
          null,
        );
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: page,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('AutoEq section renders all presets', (tester) async {
    await pumpPage(tester, const EqualizerPage());

    expect(find.text('耳机校准 · AutoEq'), findsOneWidget);
    expect(find.text('社区校准近似值（非实测），仅作起点；觉得不对就直接调频段。'),
        findsOneWidget);
    for (final p in kAutoEqPresets) {
      expect(find.text(p.name), findsOneWidget);
    }
  });

  testWidgets('tapping an AutoEq preset applies its gains', (tester) async {
    await pumpPage(tester, const EqualizerPage());
    final store = EqualizerStore.ensure();

    await tester.tap(find.text('AirPods Pro 2'));
    await settle(tester);

    expect(store.selectedAutoEqName, 'AirPods Pro 2');
    expect(store.bandGains, [1.5, 1.0, 0.5, 0.0, 0.0, -0.5, -1.0, -0.5, 0.5, 1.0]);
    expect(find.text('AirPods Pro 2'), findsWidgets);
    // The tap fires applyAutoEqPreset unawaited (equalizer_page.dart):
    // a 7-write sequential Hive chain (_persist) that a single 200ms
    // settle cannot drain. A write left pending when this test ends
    // stalls hive_ce's ReadWriteSync queue and the NEXT test's first
    // Hive write hangs forever (see drainHiveWrites in
    // helpers/hive_test_setup.dart). Drain inside the body, before
    // the fake zone is discarded.
    await drainHiveWrites(tester);
  });

}
