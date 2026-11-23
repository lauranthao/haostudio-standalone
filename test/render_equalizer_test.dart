// Render test — equalizer page, light + dark.
// NOT a regression test: it writes golden PNGs (run with
// --update-goldens) of the full equalizer page.
//
// Harness copied from render_settings_test.dart (Hive temp dir, CJK +
// Material icon fonts from the VM) and equalizer_page_test.dart
// (ThemeController in Get, tall viewport so the whole page lays out
// at once, real EqualizerStore on a Hive test box + mocked equalizer
// channel). Covers the three standard-glass cards migrated in
// Phase B: _ResponseCard, _PresetCard, _BandsCard.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/music/equalizer_page.dart';
import 'package:standalone/services/music/equalizer_store.dart';

Future<void> _loadCjkFont() async {
  final loader = FontLoader('NotoSansSC');
  for (final path in const [
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc',
  ]) {
    final bytes = await File(path).readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
  final iconLoader = FontLoader('MaterialIcons');
  final iconBytes = await File(
    '/home/hatch/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytes();
  iconLoader.addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
}

ThemeData _cjkTheme(ThemeData base) {
  final text = base.textTheme.apply(fontFamily: 'NotoSansSC');
  final primary = base.primaryTextTheme.apply(fontFamily: 'NotoSansSC');
  ButtonStyle cjkButton(ButtonStyle? style) {
    final resolved = style?.textStyle?.resolve({});
    return (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStatePropertyAll(
        (resolved ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC'),
      ),
    );
  }

  TextStyle cjkStyle(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC');

  return base.copyWith(
    cupertinoOverrideTheme: haoCupertinoThemeWithFont('NotoSansSC'),
    textTheme: text,
    primaryTextTheme: primary,
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjkStyle(base.appBarTheme.titleTextStyle),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: cjkStyle(base.listTileTheme.titleTextStyle),
      subtitleTextStyle: cjkStyle(base.listTileTheme.subtitleTextStyle),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      valueIndicatorTextStyle: cjkStyle(
        base.sliderTheme.valueIndicatorTextStyle,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: cjkStyle(base.chipTheme.labelStyle),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: cjkStyle(base.dialogTheme.titleTextStyle),
      contentTextStyle: cjkStyle(base.dialogTheme.contentTextStyle),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: cjkButton(base.filledButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: cjkButton(base.textButtonTheme.style),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      hintStyle: cjkStyle(base.inputDecorationTheme.hintStyle),
      labelStyle: cjkStyle(base.inputDecorationTheme.labelStyle),
    ),
  );
}

void main() {
  late Directory hiveDir;
  late Box<dynamic> box;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-render-eq-');
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
      'test_eq_render',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(box);
    await _loadCjkFont();
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    HaoHaptics.debugEnabledOverride = false;
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
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
    EqualizerStore.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.haostudio.standalone/equalizer'),
          null,
        );
  });

  Future<void> pumpPage(WidgetTester tester, ThemeData theme) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: const EqualizerPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('render equalizer light', (tester) async {
    await pumpPage(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/equalizer_light.png'),
    );
  });

  testWidgets('render equalizer dark', (tester) async {
    await pumpPage(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/equalizer_dark.png'),
    );
  });
}
