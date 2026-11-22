// Render test — settings page, light + dark.
// NOT a regression test: it writes golden PNGs (run with
// --update-goldens) of the full settings page.
//
// Harness copied from render_music_home_test.dart (Hive temp dir,
// CJK + Material icon fonts from the VM) and settings_tab_page_test
// (ThemeController in Get, tall viewport so the whole ListView lays
// out at once, pumpAndSettle).
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
import 'package:standalone/features/settings/settings_tab_page.dart';

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

  // CupertinoIcons (build 29 B组: 组头 chevron_down). Without this
  // the chevron renders as tofu in the golden. The pub-cache path
  // is versioned, so glob for the installed cupertino_icons-* dir.
  final home = Platform.environment['HOME'] ?? '';
  final cupertinoDirs = Directory('$home/.pub-cache/hosted/pub.dev')
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.split('/').last.startsWith('cupertino_icons-'))
      .toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  if (cupertinoDirs.isEmpty) {
    throw StateError('cupertino_icons package not found in pub cache');
  }
  final cupertinoBytes = await File(
    '${cupertinoDirs.first.path}/assets/CupertinoIcons.ttf',
  ).readAsBytes();
  // Package icons resolve as 'packages/<package>/<family>' (the
  // Icon widget prefixes fontPackage), so the loader must register
  // the qualified name — a bare 'CupertinoIcons' loads but never
  // matches, and the chevron renders as a tofu box.
  final cupertinoLoader =
      FontLoader('packages/cupertino_icons/CupertinoIcons');
  cupertinoLoader.addFont(
    Future.value(ByteData.view(cupertinoBytes.buffer)),
  );
  await cupertinoLoader.load();
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

  // Literal TextStyles in the sub-themes carry NO fontFamily (the
  // product relies on the system font on a real phone). In widget
  // tests a null family resolves to the Ahem test font — solid bars
  // for Latin, tofu for CJK — and ListTile titles/subtitles plus
  // ChoiceChip labels go through these sub-themes, so force the CJK
  // family here too (probe_font_test.dart proved the mechanism).
  TextStyle cjkStyle(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC');

  return base.copyWith(
    textTheme: text,
    primaryTextTheme: primary,
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjkStyle(base.appBarTheme.titleTextStyle),
    ),
    bottomNavigationBarTheme: base.bottomNavigationBarTheme.copyWith(
      selectedLabelStyle: cjkStyle(
        base.bottomNavigationBarTheme.selectedLabelStyle,
      ),
      unselectedLabelStyle: cjkStyle(
        base.bottomNavigationBarTheme.unselectedLabelStyle,
      ),
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
    segmentedButtonTheme: base.segmentedButtonTheme.copyWith(
      style: cjkButton(base.segmentedButtonTheme.style),
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

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-render-settings-');
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
    await _loadCjkFont();
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    HaoHaptics.debugEnabledOverride = false;
    Get.put(ThemeController());
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  Future<void> pumpSettings(
    WidgetTester tester,
    ThemeData theme,
  ) async {
    // Tall viewport so the whole ListView lays out at once (same as
    // settings_tab_page_test): the golden shows every group, not just
    // the top of a scrollable page.
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
        home: const SettingsTabPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('render settings light', (tester) async {
    await pumpSettings(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/settings_light.png'),
    );
  });

  testWidgets('render settings dark', (tester) async {
    await pumpSettings(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/settings_dark.png'),
    );
  });

  testWidgets('render settings light scrolled', (tester) async {
    await pumpSettings(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    // The flat page (build 28) is taller than the viewport: scroll to
    // the bottom (数据 + 关于 groups) for the second golden. Scope the
    // scrollable to the ListView — the quality-chips row is a second,
    // horizontal Scrollable on the same page.
    await tester.scrollUntilVisible(
      find.text('启动时自动检查更新'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/settings_light_scrolled.png'),
    );
  });

  testWidgets('render settings dark scrolled', (tester) async {
    await pumpSettings(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await tester.scrollUntilVisible(
      find.text('启动时自动检查更新'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/settings_dark_scrolled.png'),
    );
  });
}
