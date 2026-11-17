// Render test — music home page with liquid glass, for chen to look at.
// NOT a regression test: it writes golden PNGs (run with --update-goldens)
// of the real MusicTabPage + floating GlassTabBar, seeded with sample
// playlists/recents so the page is not empty.
//
// Render-only composition (NOT the product AppShell): the page runs
// full-height with NO 82pt bottom clearance, and the player queue is
// left empty so the mini player does not take the bottom strip —
// otherwise the ListView could never run under the floating bar and
// the glass would sit over a solid background, where frosted glass
// reads as a grey capsule. The list is scrolled to the bottom before
// the shot, so real song rows (cover + title/artist text) sit behind
// the tab bar. The product keeps its 82pt clearance and its mini
// player above the bar; only this render bends the composition, so
// the glass has something to refract.
//
// Chinese glyphs: widget tests render with the Ahem test font by default,
// so CJK text would be tofu blocks. We load Noto Sans CJK from the VM
// (/usr/share/fonts/opentype/noto/) and apply it as the theme fontFamily.
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
import 'package:standalone/features/music/music_tab_page.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';
import 'package:standalone/widgets/app_shell.dart';

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
  // Material icons (search / play / tab icons) are tofu in widget tests
  // unless the icon font is loaded explicitly.
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

List<Song> _sampleSongs() => [
  // Song.dur is SECONDS (formatDuration takes seconds; the APIs
  // convert ms -> s on parse). The old values here were ms and the
  // rows rendered 4083:20-style durations.
  Song(
    songId: 'wy-1',
    title: '富士山下',
    artist: '陈奕迅',
    album: "What's Going On...?",
    platform: MusicPlatform.wy,
    dur: 245,
  ),
  Song(
    songId: 'wy-2',
    title: '孤勇者',
    artist: '陈奕迅',
    album: '孤勇者',
    platform: MusicPlatform.wy,
    dur: 256,
  ),
  Song(
    songId: 'tx-1',
    title: '晴天',
    artist: '周杰伦',
    album: '叶惠美',
    platform: MusicPlatform.tx,
    dur: 269,
  ),
];

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-render-test-');
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
    final songs = _sampleSongs();
    await MusicStore.saveLists([
      UserPlaylist(id: 'p1', name: '我喜欢的音乐', tracks: songs),
      UserPlaylist(
        id: 'p2',
        name: '粤语经典',
        tracks: songs.sublist(0, 2),
      ),
    ]);
    for (final s in songs) {
      await MusicStore.addRecent(s);
    }
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

  Future<void> pumpHome(
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
    // Seed the player controller (the page reads it via ensure())
    // but leave the queue empty: with no current song the mini
    // player collapses, so the ListView runs to the bottom edge and
    // can scroll under the floating tab bar (see the header note).
    Get.put(MusicPlayerController());
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        // Render-only: NO 82pt bottom clearance — the page runs
        // full-height so its content scrolls under the bar.
        home: Stack(
          children: [
            const MusicTabPage(),
            Positioned(
              left: 0,
              right: 0,
              bottom: 6,
              // GlassTabBar is Material-free: its labels do not inherit
              // the theme textTheme, so force the CJK font here.
              child: DefaultTextStyle(
                style: const TextStyle(fontFamily: 'NotoSansSC'),
                child: GlassTabBar(currentIndex: 2, onTap: (_) {}),
              ),
            ),
          ],
        ),
      ),
    );
    // A few manual pumps (no pumpAndSettle: the player controller owns
    // timers that never settle in the fake-async zone).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    // Sections default EXPANDED (Kumone redo P0-2): no taps needed —
    // the glass rows are already showing. The stagger entrance runs at
    // most 0.4s delay + 0.25s settle, covered by the pumps above.
    // Scroll the list to the bottom so song rows (cover + text) sit
    // behind the floating tab bar when the shot is taken. The drag
    // clamps at the max extent if the list is shorter than this.
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pump();
    // Rows scrolled into view start their stagger then; wait for the
    // longest one (0.4s delay + 0.25s settle) before the shot.
    await tester.pump(const Duration(milliseconds: 800));
  }

  testWidgets('render music home light', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/music_home_light.png'),
    );
  });

  testWidgets('render music home dark', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/music_home_dark.png'),
    );
  });

  // Top-of-page shot (no scroll): the greeting large title (P0-4)
  // and the feature shelf (P0-1) are above the fold and invisible in
  // the scrolled shots above, so they get their own goldens.
  Future<void> pumpHomeTop(WidgetTester tester, ThemeData theme) async {
    await pumpHome(tester, theme);
    // pumpHome scrolled to the bottom; scroll back to the top.
    await tester.drag(find.byType(ListView), const Offset(0, 1000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  testWidgets('render music home top light', (tester) async {
    await pumpHomeTop(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/music_home_top_light.png'),
    );
  });

  testWidgets('render music home top dark', (tester) async {
    await pumpHomeTop(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/music_home_top_dark.png'),
    );
  });
}
