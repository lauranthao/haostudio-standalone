// Equalizer page tests (stage 3, Beans `EqualizerSettingsView`).
//
// Pumps the 10-band page and checks the Beans layout is present:
// response preview, enable toggle, preamp slider, 8 preset chips,
// 10 band rows. State changes go through the real store (Hive test
// box + mocked equalizer channel), so the toggle/preset taps prove
// the page is wired to the same store the settings row reads.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/music/equalizer_page.dart';
import 'package:standalone/widgets/native_switch.dart';
import 'package:standalone/services/music/equalizer_store.dart';

void main() {
  late Directory hiveDir;
  late Box<dynamic> box;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-eq-page-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    box = await Hive.openBox<dynamic>(
      'test_eq_page',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(box);
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
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
    ]) {
      await box.delete(key);
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

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: const EqualizerPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('page shows preview, preamp, all presets, all 10 bands',
      (tester) async {
    await pumpPage(tester);

    expect(find.text('均衡器'), findsOneWidget);
    expect(find.text('频响预览'), findsOneWidget);
    expect(find.text('拖动下方频段，实时塑造声音'), findsOneWidget);
    expect(find.text('启用均衡器'), findsOneWidget);
    expect(find.text('前级增益'), findsOneWidget);
    expect(find.text('预设'), findsOneWidget);
    // '默认' appears twice: the current-preset Menu label + the grid chip.
    expect(find.text('默认'), findsNWidgets(2));
    for (final name in ['低音增强', '人声', '流行', '摇滚', '古典', '爵士', '电子']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text('自定义调节'), findsOneWidget);
    // '31 Hz' / '1 kHz' / '16 kHz' appear twice: the preview scale
    // labels + the band rows. The other 7 labels appear once.
    for (final label in ['31 Hz', '1 kHz', '16 kHz']) {
      expect(find.text(label), findsNWidgets(2));
    }
    for (final label in [
      '62 Hz', '125 Hz', '250 Hz', '500 Hz',
      '2 kHz', '4 kHz', '8 kHz',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    // 10 band sliders + 1 preamp slider.
    expect(find.byType(Slider), findsNWidgets(11));
  });

  testWidgets('tapping a preset applies Beans gains and persists',
      (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('摇滚'));
    await tester.pumpAndSettle();
    expect(EqualizerStore.ensure().bandGains[0], 5);
    expect(EqualizerStore.ensure().selectedPreset, EqualizerPreset.rock);
    expect(
      HiveStore.box.get(HiveKeys.equalizerPreset),
      'rock',
    );
    // The 31 Hz and 8 kHz rows both show +5.0 dB for 摇滚.
    expect(find.text('+5.0 dB'), findsNWidgets(2));
  });

  testWidgets('enable toggle flips Hive and shows 已开启 in settings row state',
      (tester) async {
    await pumpPage(tester);

    final store = EqualizerStore.ensure();
    expect(store.enabled, isFalse);
    await tester.tap(find.byType(HaoNativeSwitch));
    await tester.pumpAndSettle();
    expect(store.enabled, isTrue);
    expect(HiveStore.getBool(HiveKeys.equalizerEnabled, false), isTrue);
  });
}
