// Render test — live home (LiveTabPage), light + dark.
// NOT a regression test: it writes golden PNGs (run with
// --update-goldens) of the live grid.
//
// Harness copied from render_music_home_test.dart (Hive temp dir,
// CJK + Material icon fonts from the VM) and live_tab_test.dart
// (FakeLiveSite + fakeRoom, LiveTabController with a fake site —
// no network, no real adapters).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/domains/live/presentation/live_tab_controller.dart';
import 'package:standalone/domains/live/presentation/live_tab_page.dart';
import 'package:standalone/shared/platforms/live_site.dart';

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

LiveRoom _fakeRoom(
  int i, {
  String platform = 'huya',
  int watching = 12345,
  bool liveStatus = true,
}) =>
    LiveRoom(
      roomId: 'room-$i',
      platform: platform,
      title: '直播间 $i',
      nick: '主播 $i',
      cover: 'https://example.com/cover-$i.jpg',
      watching: watching,
      liveStatus: liveStatus,
    );

/// Controllable fake adapter (copied from live_tab_test.dart): canned
/// pages per method, no network.
class _FakeLiveSite extends LiveSite {
  _FakeLiveSite({
    Map<int, List<LiveRoom>>? recommendPages,
    Map<String, Map<int, List<LiveRoom>>>? categoryPages,
    List<LiveArea>? categories,
  })  : _recommendPages = recommendPages ?? {},
        _categoryPages = categoryPages ?? {},
        _categories = categories ?? const [];

  @override
  String get id => 'huya';

  @override
  String get name => '虎牙';

  final Map<int, List<LiveRoom>> _recommendPages;
  final Map<String, Map<int, List<LiveRoom>>> _categoryPages;
  final List<LiveArea> _categories;

  @override
  Future<List<LiveRoom>> getRecommendRooms({
    int page = 1,
    int pageSize = 30,
  }) async {
    return _recommendPages[page] ?? const <LiveRoom>[];
  }

  @override
  Future<List<LiveArea>> getCategories({
    int page = 1,
    int pageSize = 30,
  }) async {
    return _categories;
  }

  @override
  Future<List<LiveRoom>> getCategoryRooms(
    LiveArea area, {
    int page = 1,
    int pageSize = 30,
  }) async {
    return _categoryPages[area.areaId]?[page] ?? const <LiveRoom>[];
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-render-live-tab-');
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

  Future<void> pumpTab(
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
    final site = _FakeLiveSite(
      recommendPages: {
        1: [
          _fakeRoom(1),
          _fakeRoom(2, watching: 500, liveStatus: false),
          _fakeRoom(3, watching: 9999),
          _fakeRoom(4, watching: 123456),
          _fakeRoom(5),
          _fakeRoom(6, watching: 88),
        ],
      },
      categories: const [
        LiveArea(areaId: 'g1', areaName: '英雄联盟'),
        LiveArea(areaId: 'g2', areaName: '王者荣耀'),
      ],
    );
    final controller = LiveTabController(
      siteOf: (_) => site,
      initialPlatform: 'huya',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: LiveTabPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('直播间 1'), findsOneWidget);
  }

  testWidgets('render live tab light', (tester) async {
    await pumpTab(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/live_tab_light.png'),
    );
  });

  testWidgets('render live tab dark', (tester) async {
    await pumpTab(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/live_tab_dark.png'),
    );
  });
}
