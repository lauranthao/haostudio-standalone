// Emby connect page — golden test (build 29, C group).
//
// Writes golden PNGs of the connect page (run with
// --update-goldens): light + dark, advanced section expanded.
// Harness copied from emby_render_test.dart (Hive temp dir, CJK +
// Material icon fonts from the VM). No network: the page is pumped
// with a prefilled config and no client call is made.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/settings/emby_connect_page.dart';
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
}

ThemeData _cjkTheme(ThemeData base) {
  TextStyle cjkStyle(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC');
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'NotoSansSC'),
    primaryTextTheme:
        base.primaryTextTheme.apply(fontFamily: 'NotoSansSC'),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjkStyle(base.appBarTheme.titleTextStyle),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: cjkStyle(base.listTileTheme.titleTextStyle),
      subtitleTextStyle:
          cjkStyle(base.listTileTheme.subtitleTextStyle),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: (base.filledButtonTheme.style ?? const ButtonStyle())
          .copyWith(
        textStyle: WidgetStatePropertyAll(
          cjkStyle(
            base.filledButtonTheme.style
                ?.textStyle
                ?.resolve({}),
          ),
        ),
      ),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      hintStyle: cjkStyle(base.inputDecorationTheme.hintStyle),
      labelStyle: cjkStyle(base.inputDecorationTheme.labelStyle),
    ),
  );
}

// Prefilled config: what the page shows for a server that was
// connected with an account (token kept, password blank).
const _config = EmbyServerConfig(
  baseUrl: 'http://192.168.1.10:8096/emby',
  apiKey: '',
  userId: 'user-9',
  username: 'chen',
  accessToken: 'tok-fake-abc',
  name: '家里',
  note: '到期 2027-01',
  serverName: 'Home',
  serverVersion: '4.8.0',
  fallbackUrls: ['http://192.168.1.11:8096'],
  reminderDays: 7,
);

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadCjkFont();
    hiveDir = await Directory.systemTemp.createTemp('hao-emby-golden-');
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
      'test_emby_golden',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    Get.put(ThemeController());
  });

  tearDown(() {
    Get.reset();
  });

  Future<void> pumpPage(WidgetTester tester, ThemeData theme) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: _cjkTheme(theme),
        home: const EmbyConnectPage(initialConfig: _config),
      ),
    );
    await tester.pumpAndSettle();
    // Show the advanced section too (report / strm / api key).
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
  }

  testWidgets('golden light', (tester) async {
    await pumpPage(tester, HaoThemes.of(HaoThemeId.appleGlass).light);
    await expectLater(
      find.byType(EmbyConnectPage),
      matchesGoldenFile('goldens/emby_connect_light.png'),
    );
  });

  testWidgets('golden dark', (tester) async {
    await pumpPage(tester, HaoThemes.of(HaoThemeId.appleGlass).dark);
    await expectLater(
      find.byType(EmbyConnectPage),
      matchesGoldenFile('goldens/emby_connect_dark.png'),
    );
  });
}
