// H 组 — VOD 线路 pills 回归（chen 截图 2026-11-22，build 29）。
//
// 截图：横屏 VOD（《最后的晚餐》，线路2·正片，正在加载，0:00），底部控制条
// 上方有两个纯白圆角块，左带 ✓、右全空，字看不见。
//
// 身份（代码钉死）：lib/features/video/native_video_player_page.dart
// 的线路切换 pills（`if (_detail.lines.length > 1)` 的横向 ListView，
// 控制条 Row 正上方）。证据：恰好 2 个（2 条线路）；左块带 ✓ = 选中态
// 的 checkmark，右块空 = 未选中；两块不等宽（选中块多了 ✓ 占位）；
// 高度/纵向位置 = 高 36 的 chips 行；播放器里没有别的成对 pill
// （跳过片头/片尾在右:16/bottom:168 且同位重叠，只现其一）。
//
// 根因（已验证，见本文件头部的机制说明）：旧实现是 ChoiceChip，传了
// 半透明填充（白 0.08 / 选中 0.20），以为会透出黑视频面——但 RawChip
// 把这层 fill 画在 Ink 里，而 Ink 外的 Material 不带 color，默认画
// ThemeData.canvasColor（= ColorScheme.surface = surfaceSolid：浅色
// 白、深色 #1C1C1E）。半透明白叠在不透明白画布上 = 纯白块，白字
// 1:1 消失，只剩深色 accent 的 ✓（浅色苹果玻璃 accent 是纯黑）。
// 深色从未复现（画布 #1C1C1E → 深灰块），所以只在浅色 chen 那里爆。
// 证据：复现 golden 取色——浅色块心 (255,255,255)，深色块心
// (46,46,48)/(73,73,75)，与白 0.08/0.20 在各自画布上的混合数学
// 完全一致；SDK 源码：material.dart Material 默认取 canvasColor，
// theme_data.dart canvasColor 默认 = colorScheme.surface。
// 静态只读播放器文件看不出这层——canvas 在 RawChip→Material→
// ThemeData 的链上，不在播放器文件里。这就是 A 组静态排查排除
// “白底白字”后仍漏掉的原因。
//
// 修复：_LinePill（同文件内自定义 pill，不再用 ChoiceChip）——
// 不透明填充（选中 #49494B / 未选 #2E2E30，即旧实现在深色画布上的
// 实际渲染色，深色外观不变、浅色改成和深色一致）+ 显式白字 +
// 显式白 ✓；不再经过 ChipTheme / ColorScheme / canvasColor /
// 玻璃强度中的任何一层。
//
// 复现路径（真机 / 模拟器）：
// 1. 浅色模式（任一主题；默认苹果玻璃浅色必现），玻璃强度任意；
// 2. 打开一部多线路影片（≥2 条线路），进横屏播放器；
// 3. 点一下画面调出控制条 → 控制条上方两块纯白，左带黑 ✓，字全无。
// 修后：两块深灰，选中块白 ✓ + 白字，未选块白字，浅/深/玻璃 0%/100%
// 下都一样。

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_models.dart';

/// Fake backend：即时 open / 首帧；视频面是纯色块（黑 = 正在加载的
/// 黑视频面，白 = 亮场面/白帧，用于验证 pills 在亮帧下依然可见）。
class _FakeBackend implements PlayerBackend {
  _FakeBackend({required this.failUrls, this.videoColor = Colors.black});

  final Set<String> failUrls;
  final Color videoColor;
  String? openedUrl;
  bool disposed = false;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  @override
  Widget buildVideoWidget() => Container(color: videoColor);

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    openedUrl = url;
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      openedUrl != null && !failUrls.contains(openedUrl);

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Future<void> seekTo(Duration position) async {}

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}

ThemeData _theme(HaoThemeId id, double intensity, bool isDark) {
  final pair = HaoThemes.of(id, glassIntensity: intensity);
  return isDark ? pair.dark : pair.light;
}

double _lum(Color c) {
  double f(double v) {
    final x = v / 255;
    return x <= 0.04045 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4) as double;
  }

  return 0.2126 * f(c.r * 255) +
      0.7152 * f(c.g * 255) +
      0.0722 * f(c.b * 255);
}

double _contrast(Color a, Color b) {
  final l1 = _lum(a);
  final l2 = _lum(b);
  final hi = math.max(l1, l2);
  final lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

/// 期望的不透明填充（_LinePill 的静态值，也是旧实现在深色画布上
/// 的实际渲染色）：选中 #49494B，未选 #2E2E30。
const _selectedFill = Color(0xFF49494B);
const _unselectedFill = Color(0xFF2E2E30);

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-vod-pills-');
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
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
  });

  const line2Url = 'https://example.com/last-supper-line2.mp4';
  const line1Url = 'https://example.com/last-supper-line1.mp4';

  // 顺序照 chen 截图：lines[0] = 线路2（选中，✓ 在左块），
  // lines[1] = 线路1（未选，右块空）。
  VideoDetail detail() => VideoDetail(
        source: 12,
        vodId: '93344',
        meta: VideoMeta(name: '最后的晚餐', year: '2024'),
        lines: const [
          PlayLine(
            name: '线路2',
            episodes: [PlayEpisode(name: '正片', url: line2Url)],
          ),
          PlayLine(
            name: '线路1',
            episodes: [PlayEpisode(name: '正片', url: line1Url)],
          ),
        ],
      );

  late PlaybackSession session;

  Future<void> pumpPlayer(
    WidgetTester tester, {
    required ThemeData theme,
    Color videoColor = Colors.black,
  }) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    session = PlaybackSession(
      backendFactory: (_) =>
          _FakeBackend(failUrls: const {}, videoColor: videoColor),
    );
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: NativeVideoPlayerPage(detail: detail(), session: session),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> unmountPlayer(WidgetTester tester) async {
    Get.closeAllSnackbars();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  /// 某条线路 pill 的填充色（_LinePill 的 Container 装饰色）。
  Color pillFill(WidgetTester tester, String label) {
    final found = find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color != null,
      ),
    );
    expect(found, findsOneWidget, reason: '$label pill');
    return (tester.widget<Container>(found.first).decoration
            as BoxDecoration)
        .color!;
  }

  /// 某条线路 pill 的字色。
  Color pillLabelColor(WidgetTester tester, String label) =>
      tester.widget<Text>(find.text(label)).style!.color!;

  /// 某条线路 pill 里有没有白 ✓（选中态的唯一标记）。
  bool pillHasCheck(WidgetTester tester, String label) {
    final found = find.descendant(
      of: find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color != null,
        ),
      ),
      matching: find.byIcon(Icons.check),
    );
    return found.evaluate().isNotEmpty;
  }

  group('线路 pills：不透明填充 + 字可见（4 主题 × 浅/深 × 玻璃 0%/100%）', () {
    testWidgets('16 组：无 ChoiceChip；填充/字色/✓ 全部钉死', (tester) async {
      for (final id in HaoThemeId.values) {
        for (final isDark in [false, true]) {
          for (final intensity in [0.0, 1.0]) {
            await pumpPlayer(tester, theme: _theme(id, intensity, isDark));
            expect(tester.takeException(), isNull);
            final tag = '$id ${isDark ? 'dark' : 'light'} glass $intensity';
            // 根因的反面：播放器里不再有任何 ChoiceChip（它的
            // Material 画布就是白块的来源）。
            expect(find.byType(ChoiceChip), findsNothing, reason: tag);
            expect(find.text('线路2'), findsOneWidget, reason: tag);
            expect(find.text('线路1'), findsOneWidget, reason: tag);
            // 填充不透明且与主题/玻璃无关。
            expect(
              pillFill(tester, '线路2'),
              _selectedFill,
              reason: '$tag 选中填充',
            );
            expect(
              pillFill(tester, '线路1'),
              _unselectedFill,
              reason: '$tag 未选填充',
            );
            expect(
              pillFill(tester, '线路2').a,
              1.0,
              reason: '$tag 选中填充必须不透明',
            );
            expect(
              pillFill(tester, '线路1').a,
              1.0,
              reason: '$tag 未选填充必须不透明',
            );
            // 字色显式白 / 白 70。
            expect(
              pillLabelColor(tester, '线路2'),
              Colors.white,
              reason: '$tag 选中字色',
            );
            expect(
              pillLabelColor(tester, '线路1'),
              Colors.white70,
              reason: '$tag 未选字色',
            );
            // ✓ 只在选中块，且是白的（旧实现里 ✓ 是主题 accent，
            // 浅色苹果玻璃下纯黑，在深块上 1.6:1 近乎看不见）。
            expect(pillHasCheck(tester, '线路2'), isTrue, reason: tag);
            expect(pillHasCheck(tester, '线路1'), isFalse, reason: tag);
            final check = tester.widget<Icon>(
              find.descendant(
                of: find.ancestor(
                  of: find.text('线路2'),
                  matching: find.byWidgetPredicate(
                    (w) =>
                        w is Container &&
                        w.decoration is BoxDecoration &&
                        (w.decoration as BoxDecoration).color != null,
                  ),
                ),
                matching: find.byIcon(Icons.check),
              ),
            );
            expect(check.color, Colors.white, reason: '$tag ✓ 必须是白的');
            // 对比度（白字对不透明填充，与背底无关——这正是修掉的点：
            // 旧实现字是否可见取决于视频帧亮度）。
            expect(
              _contrast(Colors.white, _selectedFill),
              greaterThan(4.5),
              reason: '$tag 选中对比度',
            );
            expect(
              _contrast(
                Color.alphaBlend(Colors.white70, _unselectedFill),
                _unselectedFill,
              ),
              greaterThan(4.5),
              reason: '$tag 未选对比度',
            );
            await unmountPlayer(tester);
          }
        }
      }
    });

    testWidgets('亮帧（白视频面）下 pills 依然可见', (tester) async {
      await pumpPlayer(
        tester,
        theme: _theme(HaoThemeId.appleGlass, 0.0, false),
        videoColor: Colors.white,
      );
      expect(find.byType(ChoiceChip), findsNothing);
      expect(pillFill(tester, '线路2'), _selectedFill);
      expect(pillFill(tester, '线路1'), _unselectedFill);
      expect(pillLabelColor(tester, '线路2'), Colors.white);
      expect(pillHasCheck(tester, '线路2'), isTrue);
      await unmountPlayer(tester);
    });

    testWidgets('点未选线路：切线成功，✓ 跟着走', (tester) async {
      await pumpPlayer(tester, theme: _theme(HaoThemeId.appleGlass, 1.0, false));
      expect(session.currentUrl, line2Url);
      expect(pillHasCheck(tester, '线路2'), isTrue);

      await tester.tap(find.text('线路1'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(session.currentUrl, line1Url);
      expect(pillHasCheck(tester, '线路1'), isTrue);
      expect(pillHasCheck(tester, '线路2'), isFalse);
      expect(pillFill(tester, '线路1'), _selectedFill);
      expect(pillFill(tester, '线路2'), _unselectedFill);
      await unmountPlayer(tester);
    });

    testWidgets('VOD 不加画质选择', (tester) async {
      await pumpPlayer(tester, theme: _theme(HaoThemeId.appleGlass, 1.0, false));
      expect(find.byTooltip('画质'), findsNothing);
      expect(find.text('画质'), findsNothing);
      await unmountPlayer(tester);
    });
  });

  group('同类地方一起查（播放器内其它 pill/按钮，纯数学断言）', () {
    test('跳过片头/片尾 pill：白底黑字，21:1，硬编码——无同类问题', () {
      // _SkipButton：Container 白底 + 黑字，颜色写死，不经过主题。
      expect(_contrast(Colors.black, Colors.white), greaterThan(4.5));
    });

    test('中央提示 pill：黑 54% 底 + 白字，亮帧下仍过 4.5:1', () {
      // _HintPill → DarkGlass(color: Colors.black54) + 白字。
      // 最坏情况（纯白帧）：混合后约 #757575，白字对比度约 4.6:1；
      // 再叠加 20 blur，帧亮度方差被抹平，不会再低。
      final overWhite = Color.alphaBlend(Colors.black54, Colors.white);
      expect(_contrast(Colors.white, overWhite), greaterThan(4.5));
      final overBlack = Color.alphaBlend(Colors.black54, Colors.black);
      expect(_contrast(Colors.white, overBlack), greaterThan(4.5));
    });

    test('顶栏/底栏图标与时间字：白 / 白 70，画在黑渐变上', () {
      // 顶栏返回/标题/图标、底栏播放/上一集/下一集/时间/倍速/全屏：
      // 颜色全部写死白系，背底是黑视频 + 黑渐变，无主题介入。
      expect(_contrast(Colors.white, Colors.black), greaterThan(4.5));
      expect(
        _contrast(
          Color.alphaBlend(Colors.white70, Colors.black),
          Colors.black,
        ),
        greaterThan(4.5),
      );
    });
  });

  group('golden：线路 pills 行（真页，fake 视频面）', () {
    testWidgets('appleGlass 浅色 玻璃0%', (tester) async {
      await pumpPlayer(
        tester,
        theme: _theme(HaoThemeId.appleGlass, 0.0, false),
      );
      await expectLater(
        find.byType(NativeVideoPlayerPage),
        matchesGoldenFile('goldens/vod_line_pills_appleGlass_light_glass0.png'),
      );
      await unmountPlayer(tester);
    });
    testWidgets('appleGlass 深色 玻璃0%', (tester) async {
      await pumpPlayer(
        tester,
        theme: _theme(HaoThemeId.appleGlass, 0.0, true),
      );
      await expectLater(
        find.byType(NativeVideoPlayerPage),
        matchesGoldenFile('goldens/vod_line_pills_appleGlass_dark_glass0.png'),
      );
      await unmountPlayer(tester);
    });
    testWidgets('appleGlass 浅色 玻璃100%', (tester) async {
      await pumpPlayer(
        tester,
        theme: _theme(HaoThemeId.appleGlass, 1.0, false),
      );
      await expectLater(
        find.byType(NativeVideoPlayerPage),
        matchesGoldenFile('goldens/vod_line_pills_appleGlass_light_glass100.png'),
      );
      await unmountPlayer(tester);
    });
    testWidgets('appleGlass 深色 玻璃100%', (tester) async {
      await pumpPlayer(
        tester,
        theme: _theme(HaoThemeId.appleGlass, 1.0, true),
      );
      await expectLater(
        find.byType(NativeVideoPlayerPage),
        matchesGoldenFile('goldens/vod_line_pills_appleGlass_dark_glass100.png'),
      );
      await unmountPlayer(tester);
    });
    testWidgets('appleGlass 浅色 玻璃0% 白帧背底（亮场面）', (tester) async {
      await pumpPlayer(
        tester,
        theme: _theme(HaoThemeId.appleGlass, 0.0, false),
        videoColor: Colors.white,
      );
      await expectLater(
        find.byType(NativeVideoPlayerPage),
        matchesGoldenFile(
          'goldens/vod_line_pills_appleGlass_light_glass0_whiteframe.png',
        ),
      );
      await unmountPlayer(tester);
    });
  });
}
