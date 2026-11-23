// Render test — Emby tab + Emby detail (build 28).
// NOT a regression test: it writes golden PNGs (run with
// --update-goldens) of the Emby pages.
//
// Harness copied from render_video_detail_test.dart (Hive temp dir,
// CJK + Material icon fonts from the VM). Both pages take a canned
// EmbyClient through their test-only `client` seam — zero network.
//
// Fixtures carry NO ImageTags on purpose: real artwork URLs would
// attempt HTTP from the test (no server here), so posters render
// the missing-artwork theme tile. The golden verifies layout /
// typography / spacing / empty states; the artwork path itself
// (sizes, header auth, no api_key in URLs) is unit-tested in
// emby_client_test.dart, and real artwork needs chen's server.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/video/emby_category_page.dart';
import 'package:standalone/features/video/emby_detail_page.dart';
import 'package:standalone/features/video/emby_tab_page.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';

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
  // CupertinoIcons (back chevron etc.): golden tests render Cupertino
  // icons as tofu without this — the font is not loaded by default.
  // Family must be the packaged name: the framework's CupertinoIcons
  // IconData carries fontPackage 'cupertino_icons', so plain
  // 'CupertinoIcons' does not match and still renders tofu.
  final cupertinoLoader = FontLoader('packages/cupertino_icons/CupertinoIcons');
  final cupertinoDir = Directory('/home/hatch/.pub-cache/hosted/pub.dev')
      .listSync()
      .whereType<Directory>()
      .firstWhere((d) => d.path.split('/').last.startsWith('cupertino_icons-'));
  final cupertinoBytes = await File(
    '${cupertinoDir.path}/assets/CupertinoIcons.ttf',
  ).readAsBytes();
  cupertinoLoader.addFont(Future.value(ByteData.view(cupertinoBytes.buffer)));
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

  TextStyle cjkStyle(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC');

  return base.copyWith(
    cupertinoOverrideTheme: haoCupertinoThemeWithFont('NotoSansSC'),
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
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: cjkButton(base.outlinedButtonTheme.style),
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

// Fixture key: explicitly fake, never a real credential (same
// convention as emby_client_test.dart).
const _config = EmbyServerConfig(
  baseUrl: 'http://127.0.0.1:8096',
  apiKey: 'test-key-123',
  userId: 'user-1',
);

/// Canned item JSON (Emby BaseItemDto shape, audit §2.2).
/// No ImageTags: posters render the missing-artwork tile (see the
/// file header — zero network from this test).
Map<String, dynamic> _itemJson({
  required String id,
  required String type,
  required String name,
  int? year,
  double? rating,
  List<String>? genres,
  String? overview,
  int? childCount,
}) =>
    <String, dynamic>{
      'Id': id,
      'Name': name,
      'Type': type,
      'ProductionYear': ?year,
      'CommunityRating': ?rating,
      'Genres': ?genres,
      'Overview': ?overview,
      'ChildCount': ?childCount,
    };

Map<String, dynamic> _movie1() => _itemJson(
      id: 'm1',
      type: 'Movie',
      name: '流浪地球2',
      year: 2023,
      rating: 8.3,
      genres: const ['科幻'],
      overview: '太阳即将毁灭，人类开启流浪地球计划，带着地球逃离太阳系。',
    );

Map<String, dynamic> _movie2() => _itemJson(
      id: 'm2',
      type: 'Movie',
      name: '奥本海默',
      year: 2023,
      rating: 8.8,
      genres: const ['剧情', '历史'],
    );

Map<String, dynamic> _series1() => _itemJson(
      id: 's1',
      type: 'Series',
      name: '三体',
      year: 2023,
      rating: 8.0,
      genres: const ['科幻'],
      overview: '纳米科学家汪淼与刑警史强联手，揭开科学边界背后的真相。',
      childCount: 1,
    );

/// Canned fetcher: answers by URL substring, 404s anything else.
/// Same shape as CannedEmbyFetcher in emby_client_test.dart.
Future<EmbyResponse> _cannedFetcher(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 8),
  CancelToken? cancelToken,
}) async {
  if (url.contains('System/Info')) {
    return const EmbyResponse(
      statusCode: 200,
      json: {'ServerName': 'Test Emby', 'Version': '4.8.0.0'},
    );
  }
  if (url.contains('/Views')) {
    return const EmbyResponse(statusCode: 200, json: {
      'Items': [
        {'Id': 'lib-m', 'Name': '电影', 'CollectionType': 'movies'},
        {'Id': 'lib-t', 'Name': '剧集', 'CollectionType': 'tvshows'},
      ],
    });
  }
  // Detail fetch first: its URL also contains '/Items'.
  if (url.contains('/Items/m1')) {
    return EmbyResponse(statusCode: 200, json: _movie1());
  }
  if (url.contains('IncludeItemTypes=Movie')) {
    return EmbyResponse(statusCode: 200, json: {
      'Items': [_movie1(), _movie2()],
      'TotalRecordCount': 2,
    });
  }
  if (url.contains('IncludeItemTypes=Series')) {
    return EmbyResponse(statusCode: 200, json: {
      'Items': [_series1()],
      'TotalRecordCount': 1,
    });
  }
  return const EmbyResponse(statusCode: 404, json: {});
}

EmbyClient _cannedClient() =>
    EmbyClient(config: _config, fetcher: _cannedFetcher);

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-render-emby-');
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

  setUp(() async {
    HaoHaptics.debugEnabledOverride = false;
    // Unconfigured unless a test stores a mode/config.
    await HiveStore.delete(HiveKeys.embyConfig);
    await HiveStore.delete(HiveKeys.videoTabMode);
    await HiveStore.delete(HiveKeys.embyHomeCache);
    await HiveStore.delete(HiveKeys.videoHistory);
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
  });

  void setPhoneSize(WidgetTester tester) {
    // iPhone-ish 390x844 logical @2x.
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  /// Bounded wait for the canned async loads to land (never
  /// pumpAndSettle: a live ticker/timer never lets it return).
  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder,
  ) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('expected $finder to appear after the canned load');
  }

  Future<void> pumpTab(WidgetTester tester, ThemeData theme) async {
    setPhoneSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: EmbyTabPage(client: _cannedClient()),
      ),
    );
    await pumpUntilFound(tester, find.text('流浪地球2'));
    expect(find.text('电影'), findsWidgets);
    expect(find.text('剧集'), findsWidgets);
  }

  Future<void> pumpTabUnconfigured(
    WidgetTester tester,
    ThemeData theme,
  ) async {
    setPhoneSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: const EmbyTabPage(),
      ),
    );
    await pumpUntilFound(tester, find.text('还没有连接 Emby'));
    expect(find.text('去设置连接'), findsOneWidget);
  }

  Future<void> pumpDetail(WidgetTester tester, ThemeData theme) async {
    setPhoneSize(tester);
    // Preload from the same canned mapping production uses.
    final preload =
        (await _cannedClient().movies(libraryId: 'lib-m')).items.first;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: EmbyDetailPage(
          itemId: 'm1',
          preload: preload,
          client: _cannedClient(),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('正片'));
    expect(find.text('流浪地球2'), findsWidgets);
    // The page fades in over 350 ms (AnimatedOpacity, _fadedIn set
    // in a post-frame callback): without these pumps the golden
    // captures opacity ~0 — a blank page. Same settle as
    // render_video_detail_test.dart.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpCategory(WidgetTester tester, ThemeData theme) async {
    setPhoneSize(tester);
    final page = await _cannedClient().movies(libraryId: 'lib-m');
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: EmbyCategoryPage(
          client: _cannedClient(),
          kind: EmbyCategoryKind.movies,
          libraryId: 'lib-m',
          initialItems: page.items,
          total: page.totalCount,
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('共 2 部'));
    expect(find.text('流浪地球2'), findsWidgets);
    expect(find.text('奥本海默'), findsWidgets);
  }

  ThemeData light() =>
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light);
  ThemeData dark() => _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark);

  testWidgets('render emby tab light', (tester) async {
    await pumpTab(tester, light());
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/emby_tab_light.png'),
    );
  });

  testWidgets('render emby tab dark', (tester) async {
    await pumpTab(tester, dark());
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/emby_tab_dark.png'),
    );
  });

  testWidgets('render emby tab unconfigured light', (tester) async {
    await pumpTabUnconfigured(tester, light());
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/emby_tab_unconfigured_light.png'),
    );
  });

  testWidgets('render emby tab unconfigured dark', (tester) async {
    await pumpTabUnconfigured(tester, dark());
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/emby_tab_unconfigured_dark.png'),
    );
  });

  testWidgets('render emby detail light', (tester) async {
    await pumpDetail(tester, light());
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/emby_detail_light.png'),
    );
  });

  testWidgets('render emby detail dark', (tester) async {
    await pumpDetail(tester, dark());
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/emby_detail_dark.png'),
    );
  });

  // Category full list (§18): golden files do not exist yet — the
  // parent generates them after inspecting the testImage renders
  // (same flow as the other goldens in this file).
  testWidgets('render emby category light', (tester) async {
    await pumpCategory(tester, light());
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/emby_category_light.png'),
    );
  });

  testWidgets('render emby category dark', (tester) async {
    await pumpCategory(tester, dark());
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/emby_category_dark.png'),
    );
  });
}
