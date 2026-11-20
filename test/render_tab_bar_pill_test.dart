// Render test — GlassTabBar pill lens (chen 2026-11-20, bug 5:
// NetEase tab-bar animation). NOT a regression test: it writes golden
// PNGs (run with --update-goldens) of the real GlassTabBar so the lens
// can be eyeballed against the NetEase reference frames
// (~/workspace/preview/netease_pill_anim/frame_005 = mid-slide,
// frame_011 = over 我的/搜索）.
//
// - rest: pill settled on 音乐 (index 2) — the lens visibility is 0
//   (optics off, body opaque) and the solid resting pill shows; the
//   selected icon+label are a single direct copy at normal scale
//   (bug 6 v2).
// - mid-slide: tap 设置 (scoped to the bar — an unscoped tap hit the
//   music page's own 设置 row), shot 300ms into the spring (6x50ms
//   pumps — a single big pump does not tick the spring in this
//   harness) — the 180ms thickness forward has completed (lens fully
//   up) while the settle spring is still mid-flight, the pill is
//   stretched, and the icon + label under the lens must read
//   magnified / warped, a single copy.
// - settled: pill at rest on 设置 (index 3) — lens out, resting pill
//   in again.
// Light + dark. The list is scrolled to the bottom first, so song rows
// sit behind the bar and the glass has something to refract (same
// trick as render_music_home_test.dart).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    hide GlassTabBar;
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/core/theme/tab_bar_accent.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/music_tab_page.dart';
import 'package:standalone/services/music/music_api.dart';
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
  final iconLoader = FontLoader('MaterialIcons');
  final iconBytes = await File(
    '/home/hatch/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytes();
  iconLoader.addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
}

ThemeData _cjkTheme(ThemeData base) {
  final text = base.textTheme.apply(fontFamily: 'NotoSansSC');
  return base.copyWith(textTheme: text);
}

class _EmptyCoverApi extends MusicApi {
  @override
  Future<List<PlaylistSummary>> plaza(MusicPlatform pf) async => [];

  @override
  Future<List<PlaylistSummary>> neteaseCharts() async => [];
}

List<Song> _sampleSongs() => [
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

/// Stateful bar holder: tapping a tab updates currentIndex, so the
/// pill springs across like in the product.
class _BarHolder extends StatefulWidget {
  const _BarHolder();

  @override
  State<_BarHolder> createState() => _BarHolderState();
}

class _BarHolderState extends State<_BarHolder> {
  var index = 2;

  @override
  Widget build(BuildContext context) {
    return GlassTabBar(
      currentIndex: index,
      onTap: (i) => setState(() => index = i),
    );
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-pill-test-');
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

  Future<void> pumpHome(WidgetTester tester, ThemeData theme) async {
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
        home: Stack(
          children: [
            MusicTabPage(api: _EmptyCoverApi()),
            Positioned(
              left: 0,
              right: 0,
              bottom: 6,
              child: DefaultTextStyle(
                style: const TextStyle(fontFamily: 'NotoSansSC'),
                child: const _BarHolder(),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  Future<void> shoot(
    WidgetTester tester,
    ThemeData theme,
    String name,
  ) async {
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  /// The tab-bar tab label, scoped to the GlassTabBar's unselected
  /// clip: an unscoped find.text('设置') matches the music page's own
  /// 设置 row first, so the old mid-slide/settled tests tapped the
  /// page instead of the tab and their goldens were meaningless
  /// duplicates of rest-on-音乐 (both sha256 ad6c408f…).
  /// Scoped to the unselected clip because the icon layer is split:
  /// every label exists twice in the tree (unselected inverse clip +
  /// selected normal clip). The tap point is the cell centre either
  /// way — what matters is the position, not which copy the finder
  /// returns — and the unselected copy is the visible one for a
  /// not-yet-selected tab.
  Finder barTab(String label) => find.descendant(
        of: find.byKey(GlassTabBarState.unselectedClipKey),
        matching: find.text(label),
      );

  /// Crossfade state (bug 6 v2, chen 2026-11-20): at rest the lens
  /// visibility is 0 (optics off, body opaque — a single direct copy
  /// on the solid resting pill) and the resting pill Opacity is 1;
  /// in motion the lens visibility is 1 and the resting pill 0.
  /// The lens is NEVER wrapped in Opacity (build 21 did that and it
  /// doubled during every fade — the library fades via
  /// settings.visibility instead).
  double lensVisibility(WidgetTester tester) =>
      tester
          .widget<GlassContainer>(find.byKey(GlassTabBarState.pillKey))
          .settings
          ?.visibility ??
      -1;
  double restPillOpacity(WidgetTester tester) =>
      tester.widget<Opacity>(
        find.byKey(GlassTabBarState.restPillOpacityKey),
      ).opacity;

  void expectAtRest(WidgetTester tester) {
    expect(find.byKey(GlassTabBarState.restPillKey), findsOneWidget);
    expect(lensVisibility(tester), 0.0);
    expect(restPillOpacity(tester), 1.0);
  }

  void expectInMotion(WidgetTester tester) {
    expect(find.byKey(GlassTabBarState.pillKey), findsOneWidget);
    expect(lensVisibility(tester), 1.0);
    expect(restPillOpacity(tester), 0.0);
  }

  testWidgets('pill rest on 音乐 light', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    // Bug 6: at rest the lens is fully faded out and the solid
    // resting pill shows — a single direct copy, normal scale.
    expectAtRest(tester);
    await shoot(tester, _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
        'pill_rest_light');
  });

  testWidgets('pill rest on 音乐 dark', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await shoot(tester, _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
        'pill_rest_dark');
  });

  // Bug 4 (tab-bar glass back, 4 themes x light/dark): the bar at
  // rest in the other three themes, so the frost bump can be eyeballed
  // per theme instead of assuming appleGlass generalises.
  testWidgets('pill rest 暗夜鎏金 light', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.darkGold).light),
    );
    await shoot(tester, _cjkTheme(HaoThemes.of(HaoThemeId.darkGold).light),
        'pill_rest_gold_light');
  });

  testWidgets('pill rest 暗夜鎏金 dark', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.darkGold).dark),
    );
    await shoot(tester, _cjkTheme(HaoThemes.of(HaoThemeId.darkGold).dark),
        'pill_rest_gold_dark');
  });

  testWidgets('pill rest 清新薄荷 light', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.freshMint).light),
    );
    await shoot(tester, _cjkTheme(HaoThemes.of(HaoThemeId.freshMint).light),
        'pill_rest_mint_light');
  });

  testWidgets('pill rest 清新薄荷 dark', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.freshMint).dark),
    );
    await shoot(tester, _cjkTheme(HaoThemes.of(HaoThemeId.freshMint).dark),
        'pill_rest_mint_dark');
  });

  testWidgets('pill rest 极夜冰蓝 light', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.polarIce).light),
    );
    await shoot(tester, _cjkTheme(HaoThemes.of(HaoThemeId.polarIce).light),
        'pill_rest_ice_light');
  });

  testWidgets('pill rest 极夜冰蓝 dark', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.polarIce).dark),
    );
    await shoot(tester, _cjkTheme(HaoThemes.of(HaoThemeId.polarIce).dark),
        'pill_rest_ice_dark');
  });

  testWidgets('pill mid-slide to 设置 light', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    await tester.tap(barTab('设置'));
    // The tap-triggered spring starts in a post-frame callback, so
    // it needs a starter pump before the clock advance (same as
    // glass_tab_bar_test.dart: "a tap-triggered spring needs two
    // pumps to start"). Advance in 50ms steps, not one big pump: a
    // single pump(300ms) does not tick the spring/thickness tickers
    // in this harness (the pill stays put), while repeated small
    // pumps advance them (the glass test's slide-stretch test uses
    // the same 6x50ms pattern). After 300ms the 180ms thickness
    // forward has completed (lens fully up) while the 350ms settle
    // spring is still mid-flight, the pill stretched, the lens
    // refracting the tab item.
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expectInMotion(tester);
    await shoot(tester, _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
        'pill_mid_light');
    // Drain the pill spring's trailing-edge delay (scheduled in the
    // post-frame callback after the tap) before the test ends.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('pill mid-slide to 设置 dark', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await tester.tap(barTab('设置'));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expectInMotion(tester);
    await shoot(tester, _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
        'pill_mid_dark');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('pill settled on 设置 light', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
    );
    await tester.tap(barTab('设置'));
    // Same starter pump + small steps as mid-slide: a single big
    // pump does not tick the spring in this harness (the pill stays
    // on 音乐 and the golden would be a meaningless rest duplicate).
    // Then pumpAndSettle to drain the spring + the 180ms thickness
    // reverse (the spring's exact settle time in this harness is
    // longer than the 350ms response, so a fixed 1s of pumps leaves
    // the lens up).
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    // Settled: the spring is done and the 180ms thickness reverse
    // has completed — the lens is out again, the resting pill is in,
    // and the tab has actually switched to 设置.
    expectAtRest(tester);
    expect(
      tester
          .widget<Icon>(
            find
                .descendant(
                  of: find.byType(GlassTabBar),
                  matching: find.byType(Icon),
                )
                .at(3),
          )
          .color,
      TabBarAccentController.defaultColor,
    );
    await shoot(tester, _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
        'pill_settled_light');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('pill settled on 设置 dark', (tester) async {
    await pumpHome(
      tester,
      _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
    );
    await tester.tap(barTab('设置'));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expectAtRest(tester);
    expect(
      tester
          .widget<Icon>(
            find
                .descendant(
                  of: find.byType(GlassTabBar),
                  matching: find.byType(Icon),
                )
                .at(3),
          )
          .color,
      TabBarAccentController.defaultColor,
    );
    await shoot(tester, _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark),
        'pill_settled_dark');
    await tester.pump(const Duration(seconds: 1));
  });
}
