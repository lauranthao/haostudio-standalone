// Render test — playlist plaza (歌单广场, incl. PlayCountBadge),
// light + dark.
// NOT a regression test: it writes golden PNGs (run with
// --update-goldens) of the plaza list.
//
// Harness copied from render_music_home_test.dart (Hive temp dir,
// CJK + Material icon fonts from the VM). The lists come from a
// canned NetEase plaza response through a fake Dio injected into
// MusicApi via the page's test-only `api` seam (same pattern as
// NativeVideoPlayerPage) — no network. Covers are empty on purpose
// (placeholder tile, deterministic — real covers cannot load in
// widget tests anyway).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/music/plaza_page.dart';
import 'package:standalone/services/music/music_api.dart';

import 'lx_fake_dio.dart';

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

String _plazaJson() => jsonEncode({
      'result': [
        {
          'id': 1,
          'name': '华语流行精选',
          'picUrl': '',
          'playCount': 123456,
          'trackCount': 50,
          'copywriter': '编辑精选',
        },
        {
          'id': 2,
          'name': '粤语经典老歌',
          'picUrl': '',
          'playCount': 1234567,
          'trackCount': 80,
          'copywriter': '编辑精选',
        },
        {
          'id': 3,
          'name': '深夜电台',
          'picUrl': '',
          'playCount': 9876,
          'trackCount': 30,
          'copywriter': '编辑精选',
        },
        {
          'id': 4,
          'name': '运动节奏',
          'picUrl': '',
          'playCount': 0,
          'trackCount': 20,
          'copywriter': '编辑精选',
        },
        {
          'id': 5,
          'name': '轻音乐放松',
          'picUrl': '',
          'playCount': 54321,
          'trackCount': 40,
          'copywriter': '编辑精选',
        },
      ],
    });

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-render-plaza-');
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

  Future<void> pumpPlaza(
    WidgetTester tester,
    ThemeData theme,
  ) async {
    // iPhone-ish 390x844 logical @2x.
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final log = <String>[];
    final api = MusicApi(
      dio: buildFakeDio(
        respond: (url) => {'status': 200, 'body': _plazaJson()},
        log: log,
      ),
    );
    // PlayCountBadge picks Chinese units from the device locale
    // (platformDispatcher.locale): the test binding defaults to
    // en_US, which would format 123456 as "123.5K" instead of
    // "12.3万" — same mechanism as play_count_badge_test.dart.
    tester.platformDispatcher.localeTestValue = const Locale('zh', 'CN');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: PlazaPage(api: api),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('华语流行精选'), findsOneWidget);
    // PlayCountBadge formats (Kumone P2): 123456 -> 12.3万,
    // 1234567 -> 123.5万; playCount 0 shows no badge.
    expect(find.text('12.3万'), findsOneWidget);
    expect(find.text('123.5万'), findsOneWidget);
  }

  testWidgets('render plaza light', (tester) async {
    await pumpPlaza(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/plaza_light.png'),
    );
  });

  testWidgets('render plaza dark', (tester) async {
    await pumpPlaza(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/plaza_dark.png'),
    );
  });
}
