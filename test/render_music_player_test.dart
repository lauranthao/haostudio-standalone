// Render test — music player page (Kumone classic redo), for chen to look at.
// NOT a regression test: it writes golden PNGs (run with --update-goldens)
// of the real MusicPlayerPage in light + dark.
//
// The cover is EMPTY on purpose: a network cover would hang the widget
// test on Dio. The empty cover shows the placeholder note icon over the
// Kumone no-cover fallback gradient, which is exactly what the page
// looks like before a cover loads.
//
// Chinese glyphs: widget tests render with the Ahem test font by default,
// so CJK text would be tofu blocks. We load Noto Sans CJK from the VM
// (/usr/share/fonts/opentype/noto/) and apply it as the theme fontFamily
// (same loader as render_music_home_test.dart).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/native/now_playing.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/music_player_sheet.dart';
import 'package:standalone/services/music/music_models.dart';

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
  // Material icons are tofu in widget tests unless the icon font is
  // loaded explicitly.
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
  return base.copyWith(
    textTheme: text,
    primaryTextTheme: primary,
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'NotoSansSC',
      ),
    ),
  );
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-render-player-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(nowPlayingChannelName),
          (call) async => null,
        );
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

  Future<void> pumpPlayer(WidgetTester tester, ThemeData theme) async {
    // iPhone-ish 390x844 logical @2x.
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final c = Get.put(MusicPlayerController());
    c.queue.assignAll([
      Song(
        songId: 'wy-1',
        title: '富士山下',
        artist: '陈奕迅',
        album: "What's Going On...?",
        cover: '',
        platform: MusicPlatform.wy,
        dur: 245,
      ),
    ]);
    c.currentIndex.value = 0;
    c.duration.value = const Duration(seconds: 245);
    c.position.value = const Duration(seconds: 65);
    // Playing (not resolving): pause icon, cover at full scale.
    c.isPlaying.value = true;
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: const MusicPlayerPage(),
      ),
    );
    // A few manual pumps (no pumpAndSettle: the player controller owns
    // timers that never settle in the fake-async zone).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('render music player light', (tester) async {
    await pumpPlayer(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/music_player_light.png'),
    );
  });

  testWidgets('render music player dark', (tester) async {
    await pumpPlayer(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/music_player_dark.png'),
    );
  });
}
