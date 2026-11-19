// Render test — video detail page (Infuse cover top), light + dark.
// NOT a regression test: it writes golden PNGs (run with
// --update-goldens) of the detail page.
//
// Harness copied from render_music_home_test.dart (Hive temp dir,
// CJK + Material icon fonts from the VM). The detail comes from a
// canned VideoDetailService injected through the page's test-only
// `detailService` seam (same pattern as NativeVideoPlayerPage) —
// no network, no CMS, no Douban (enrichment is fire-and-forget and
// returns null in tests).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/video/video_detail_page.dart';
import 'package:standalone/features/video/video_detail_service.dart';
import 'package:standalone/features/video/video_models.dart';

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

VideoDetail _cannedDetail() => VideoDetail(
      source: 12,
      vodId: '93344',
      meta: VideoMeta(
        name: '流浪地球2',
        year: '2023',
        type: '科幻',
        area: '中国大陆',
        score: '8.3',
        actor: '吴京 / 刘德华',
        director: '郭帆',
        content: '太阳即将毁灭，人类开启流浪地球计划，带着地球逃离太阳系。',
      ),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: const [
            PlayEpisode(name: '第1集', url: 'https://example.com/ep1.mp4'),
            PlayEpisode(name: '第2集', url: 'https://example.com/ep2.mp4'),
            PlayEpisode(name: '第3集', url: 'https://example.com/ep3.mp4'),
            PlayEpisode(name: '第4集', url: 'https://example.com/ep4.mp4'),
          ],
        ),
        PlayLine(
          name: '线路2',
          episodes: const [
            PlayEpisode(name: '第1集', url: 'https://example.com/ep1b.mp4'),
            PlayEpisode(name: '第2集', url: 'https://example.com/ep2b.mp4'),
          ],
        ),
      ],
    );

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-render-detail-');
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

  Future<void> pumpDetail(
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
    final service = VideoDetailService(
      fetchDetail: (_, _) async => _cannedDetail(),
      findAlts: (_, _, _) => const Stream.empty(),
    );
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: VideoDetailPage(
          sourceId: 12,
          vodId: '93344',
          preload: const VideoItem(
            source: 12,
            sourceName: '金鹰',
            vodId: '93344',
            name: '流浪地球2',
            year: '2023',
          ),
          detailService: service,
        ),
      ),
    );
    // Direct fetch settles immediately; the 0.35 s fade-in + a frame
    // for the applied detail. The final 8 s pump flushes the race's
    // 7 s deadline timer (cancelled on settle, but the test binding
    // fails on any Timer still pending at test end — without this the
    // light test ends with the timer outstanding).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('流浪地球2'), findsWidgets);
    expect(find.text('第1集'), findsWidgets);
  }

  testWidgets('render video detail light', (tester) async {
    await pumpDetail(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/video_detail_light.png'),
    );
  });

  testWidgets('render video detail dark', (tester) async {
    await pumpDetail(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/video_detail_dark.png'),
    );
  });
}
