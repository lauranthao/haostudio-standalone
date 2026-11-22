// Unified page (chen 2026-11-19: "不要有那种分开的感觉，就是一个
// 页面连在一起的" — NetEase 漫游页参考：整页同一底色，顶栏 / mini
// 播放器 / 底栏都是同色胶囊）.
//
// - chromeSettings tints the floating chrome with the page's own
//   background (theme scaffold colour) at low alpha, thin frost —
//   in all 4 themes x light/dark. Frost 0.55 + rimLight 1.5 since the
//   bug-4 fix (chen 2026-11-20: "菜单的那个玻璃也没有了" — the §4
//   0.40 frost left the bar reading as a flat strip); the tint stays
//   the page colour, so the bar is still not a white slab.
// - the mini player bar uses it; the tab bar is the Apple-native bar
//   since build 29 (glassy GlassTabBar on iOS, Flutter fallback in
//   tests — labels on every tab, transparent accent-tint pill).
// - the tab-root top bars (live + settings AppBars) ARE the page
//   background: scaffold colour with wallpaper off, transparent
//   (the background layer shows through) with wallpaper on.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    hide GlassTabBar;
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/appearance_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/core/theme/liquid_glass_theme.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/domains/live/presentation/live_tab_controller.dart';
import 'package:standalone/domains/live/presentation/live_tab_page.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/widgets/mini_player_bar.dart';
import 'package:standalone/features/settings/settings_tab_page.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/shared/platforms/live_site.dart';
import 'package:standalone/widgets/app_shell.dart';

class _FakeLiveSite extends LiveSite {
  @override
  String get id => 'bilibili';

  @override
  String get name => '哔哩哔哩';

  @override
  Future<List<LiveRoom>> getRecommendRooms({
    int page = 1,
    int pageSize = 30,
  }) async => const <LiveRoom>[];

  @override
  Future<List<LiveArea>> getCategories({
    int page = 1,
    int pageSize = 30,
  }) async => const <LiveArea>[];

  @override
  Future<List<LiveRoom>> getCategoryRooms(
    LiveArea area, {
    int page = 1,
    int pageSize = 30,
  }) async => const <LiveRoom>[];
}

void main() {
  late Directory hiveDir;
  late Directory docsDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-unified-test-');
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
      'test_unified',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
    docsDir = await Directory.systemTemp.createTemp('hao-unified-docs-');
  });

  tearDownAll(() async {
    // Trap (2026-11-17): never `await` box.close() in tearDownAll.
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
    await docsDir.delete(recursive: true);
  });

  setUp(() {
    HaoHaptics.debugEnabledOverride = false;
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  /// AppearanceController backed by a store rooted at the temp docs
  /// dir, with a real wallpaper file applied when [wallpaperOn].
  /// The off case explicitly disables the wallpaper first, so a
  /// wallpaper applied by an earlier test cannot leak into this one
  /// (the Hive box is shared across the file). The file IO runs in
  /// the real zone (tester.runAsync): real file copies never
  /// complete inside a widget test's fake-async zone.
  Future<AppearanceController> appearance(
    WidgetTester tester, {
    bool wallpaperOn = false,
  }) async {
    final store = AppearanceStore(documentsDir: docsDir);
    final controller = Get.put(AppearanceController(store: store));
    if (wallpaperOn) {
      await tester.runAsync(() async {
        // A real 1x1 PNG: the background layer decodes it, and
        // invalid bytes would report a FlutterError on decode.
        final src = File('${docsDir.path}/src.png');
        await src.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
          ),
        );
        final path = await store.addWallpaper(src);
        await store.applyWallpaper(path!);
      });
    } else {
      await store.setWallpaperEnabled(false);
    }
    await controller.load();
    return controller;
  }

  Future<void> pumpThemed(
    WidgetTester tester,
    Widget home,
    ThemeData theme,
  ) async {
    await tester.pumpWidget(
      GetMaterialApp(theme: theme, home: home),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('chromeSettings', () {
    testWidgets('page-background tint, thin frost, all 8 combos', (
      tester,
    ) async {
      for (final id in HaoThemeId.values) {
        for (final mode in [Brightness.light, Brightness.dark]) {
          final pair = HaoThemes.of(id);
          final themeData = mode == Brightness.light ? pair.light : pair.dark;
          late LiquidGlassSettings settings;
          await tester.pumpWidget(
            MaterialApp(
              theme: themeData,
              home: Builder(
                builder: (context) {
                  settings = HaoLiquidGlass.chromeSettings(context);
                  return const SizedBox();
                },
              ),
            ),
          );
          await tester.pumpAndSettle(); // finish AnimatedTheme lerp
          final page =
              themeData.extension<HaoTheme>()!.scaffoldBackground;
          expect(
            settings.glassColor,
            page.withValues(alpha: 0.12),
            reason: '$id $mode: glassColor is not the page background',
          );
          expect(
            settings.frostOpacity,
            0.55,
            reason: '$id $mode: frost is not thinned',
          );
          expect(
            settings.rimLight,
            1.5,
            reason: '$id $mode: rim light is the glass cue',
          );
          expect(
            settings.saturation,
            1.0,
            reason: '$id $mode: backdrop must not be re-saturated',
          );
          expect(
            settings.bodyShade,
            0.0,
            reason: '$id $mode: body must not be darkened',
          );
          // Optics untouched from ios27.
          expect(settings.thickness, 32, reason: '$id $mode: thickness');
          expect(settings.frost, 14, reason: '$id $mode: frost');
          expect(
            settings.refractiveIndex,
            1.24,
            reason: '$id $mode: refractiveIndex',
          );
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('tab bar shell is the Apple-native bar (labels + '
        'tint pill)', (tester) async {
      tester.view.physicalSize = const Size(400, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var tapped = -1;
      await pumpThemed(
        tester,
        Scaffold(
          body: GlassTabBar(currentIndex: 1, onTap: (i) => tapped = i),
        ),
        HaoThemes.of(HaoThemeId.appleGlass).light,
      );
      await tester.pumpAndSettle();
      // Apple-native bar (build-29 adoption): every tab shows its
      // label (chen 2026-11-22: 有字）, no GlassContainer chrome any
      // more — the pill is a transparent accent tint, not a solid
      // matte slab. In the test host the off-iOS fallback renders.
      for (final label in ['影视', '直播', '音乐', '设置']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      final theme = HaoThemes.of(HaoThemeId.appleGlass)
          .light
          .extension<HaoTheme>()!;
      // Pill: one piece at the selected cell (index 1 of 4 in a
      // 400pt viewport: left 104, width 92), accent tint.
      final pill = tester.widget<Container>(
        find.byKey(GlassTabBar.pillKey),
      );
      final pillDeco = pill.decoration as BoxDecoration;
      expect(pillDeco.color, theme.accentSoft);
      final pillTopLeft = tester.getTopLeft(find.byKey(GlassTabBar.pillKey));
      expect(pillTopLeft.dx, 104);
      // (64-56)/2 = 4, plus the 0.5 hairline top border.
      expect(pillTopLeft.dy, 4.5);
      // Selected tab label = accent, unselected = primary at 0.8.
      expect(
        tester.widget<Text>(find.text('直播')).style?.color,
        theme.accent,
      );
      expect(
        tester.widget<Text>(find.text('影视')).style?.color,
        theme.textPrimary.withValues(alpha: 0.8),
      );
      await tester.tap(find.text('音乐'));
      expect(tapped, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('mini player bar uses chromeSettings', (tester) async {
      final player = Get.put(MusicPlayerController());
      player.queue.assignAll([
        Song(
          songId: 'wy-1',
          title: '富士山下',
          artist: '陈奕迅',
          album: "What's Going On...?",
          platform: MusicPlatform.wy,
          dur: 245,
        ),
      ]);
      player.currentIndex.value = 0;
      await pumpThemed(
        tester,
        Scaffold(body: MiniPlayerBar(onOpenPlayer: (_) {})),
        HaoThemes.of(HaoThemeId.polarIce).dark,
      );
      await tester.pumpAndSettle();
      final bar = tester.widget<GlassContainer>(
        find.byType(GlassContainer).first,
      );
      final page = HaoThemes.of(HaoThemeId.polarIce)
          .dark
          .extension<HaoTheme>()!
          .scaffoldBackground;
      expect(bar.settings?.glassColor, page.withValues(alpha: 0.12));
      expect(bar.settings?.frostOpacity, 0.55);
      expect(bar.settings?.rimLight, 1.5);
    });
  });

  group('tab-root top bars', () {
    testWidgets('settings has no AppBar; big title sits on the page background',
        (tester) async {
      await appearance(tester);
      final themeController = Get.put(ThemeController());
      themeController.loadFromBox(HiveStore.box);
      await pumpThemed(
        tester,
        const SettingsTabPage(),
        HaoThemes.of(HaoThemeId.appleGlass).light,
      );
      await tester.pumpAndSettle();
      // No AppBar (chen 2026-11-21, screenshot): the title is a big
      // bold header in the list itself, so the top area IS the page
      // background — there is no bar widget to be opaque.
      expect(find.byType(AppBar), findsNothing);
      final title = tester.widget<Text>(find.text('设置'));
      expect(title.style?.fontSize, 34);
      // Apple large title: 34pt bold (w700), not the old 26/w800.
      expect(title.style?.fontWeight, FontWeight.w700);
      expect(
        title.style?.color,
        HaoThemes.of(HaoThemeId.appleGlass)
            .light
            .extension<HaoTheme>()!
            .textPrimary,
      );
    });

    testWidgets('live has no AppBar; big title sits on the page background',
        (tester) async {
      await appearance(tester);
      await pumpThemed(
        tester,
        LiveTabPage(
          controller: LiveTabController(siteOf: (_) => _FakeLiveSite()),
        ),
        HaoThemes.of(HaoThemeId.appleGlass).light,
      );
      await tester.pumpAndSettle();
      // No AppBar (chen 2026-11-21, screenshot): the title is a big
      // bold header in the page body, actions on the same row.
      expect(find.byType(AppBar), findsNothing);
      final title = tester.widget<Text>(find.text('直播'));
      expect(title.style?.fontSize, 26);
      expect(title.style?.fontWeight, FontWeight.w800);
      expect(
        title.style?.color,
        HaoThemes.of(HaoThemeId.appleGlass)
            .light
            .extension<HaoTheme>()!
            .textPrimary,
      );
    });

    testWidgets('wallpaper on: no opaque top bar on the settings page',
        (tester) async {
      await appearance(tester, wallpaperOn: true);
      final themeController = Get.put(ThemeController());
      themeController.loadFromBox(HiveStore.box);
      await pumpThemed(
        tester,
        const SettingsTabPage(),
        HaoThemes.of(HaoThemeId.appleGlass).light,
      );
      // Fixed pumps, not pumpAndSettle: the background layer decodes
      // the wallpaper image asynchronously, and settling would wait
      // on that decode.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // No AppBar (chen 2026-11-21): with the wallpaper on, the
      // top area is the wallpaper itself — no bar widget to cover it.
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('设置'), findsOneWidget);
    });
  });
}
