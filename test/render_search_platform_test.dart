// Render test — music search platform picker + capsule with the REAL
// brand logos (chen 2026-11-18: "平台的logo用真实logo啊").
// NOT a regression test: it writes golden PNGs (run with
// --update-goldens) of the search page capsule and the platform
// picker sheet, light + dark.
//
// Harness copied from render_music_home_test.dart: Hive is mocked to
// a temp dir, CJK + Material icon fonts are loaded from the VM so
// text/icons are not tofu, manual pumps only (the player controller
// owns timers that never settle in the fake-async zone).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/song_search_page.dart';

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
  // Button themes carry their own textStyle WITHOUT a fontFamily, and
  // a button's DefaultTextStyle shadows the ambient one — so the
  // SegmentedButton labels and the 搜索 TextButton would render in
  // the Ahem test font (tofu) unless the family is forced here too.
  // On a real device the system font covers them; this is test-only.
  ButtonStyle cjkButton(ButtonStyle? style) {
    final resolved = style?.textStyle?.resolve({});
    return (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStatePropertyAll(
        (resolved ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC'),
      ),
    );
  }

  return base.copyWith(
    textTheme: text,
    primaryTextTheme: primary,
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'NotoSansSC',
      ),
    ),
    segmentedButtonTheme: base.segmentedButtonTheme.copyWith(
      style: cjkButton(base.segmentedButtonTheme.style),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: cjkButton(base.filledButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: cjkButton(base.textButtonTheme.style),
    ),
  );
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-render-platform-');
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
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  Future<void> pumpSearch(WidgetTester tester, ThemeData theme) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    Get.put(MusicPlayerController());
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: const SongSearchPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    // Asset images decode on real async time, not the fake clock:
    // without this the picker rows' logos are still blank when the
    // golden is taken (the capsule's logo gets in via the earlier
    // pumps only because it rendered first).
    await tester.runAsync(() async {
      final ctx = tester.element(find.byType(GetMaterialApp));
      for (final code in ['wy', 'tx', 'kg', 'kw']) {
        await precacheImage(AssetImage('assets/logos/$code.jpg'), ctx);
      }
    });
    await tester.pump();
  }

  testWidgets('render search platform capsule light', (tester) async {
    await pumpSearch(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    // Capsule shows the current platform (default 网易云) with its
    // real logo; the picker sheet is closed.
    expect(find.text('网易云'), findsWidgets);
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/search_platform_light.png'),
    );
  });

  testWidgets('render search platform capsule dark', (tester) async {
    await pumpSearch(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    expect(find.text('网易云'), findsWidgets);
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/search_platform_dark.png'),
    );
  });

  Future<void> pumpPicker(WidgetTester tester, ThemeData theme) async {
    await pumpSearch(tester, theme);
    // Tap the capsule (its label is the current platform name) to
    // open the picker sheet, then let the bottom-sheet animation run.
    await tester.tap(find.text('网易云').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('选择平台'), findsOneWidget);
    for (final name in ['网易云', 'QQ音乐', '酷狗音乐', '酷我']) {
      expect(find.text(name), findsWidgets);
    }
  }

  testWidgets('render search platform picker light', (tester) async {
    await pumpPicker(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/search_platform_picker_light.png'),
    );
  });

  testWidgets('render search platform picker dark', (tester) async {
    await pumpPicker(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/search_platform_picker_dark.png'),
    );
  });
}
