// Settings page: collapsible player-engine section + About at the bottom.
//
// - The 播放器引擎 group starts collapsed (only the current engine name
//   shows as a summary); tapping the header expands / collapses it and
//   the state persists in Hive (`engineSectionExpanded`).
// - The 关于 section (版本 / 检查更新 / 日志) is the last
//   section on the page, after every other settings group.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    hide GlassCard, GlassShadow;
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/settings/app_log_page.dart';
import 'package:standalone/features/settings/settings_tab_page.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-settings-test-');
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
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    Get.put(ThemeController());
  });

  tearDown(() {
    Get.reset();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // Tall viewport so the whole ListView lays out at once.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: const SettingsTabPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('engine section starts collapsed, tap expands and persists',
      (tester) async {
    await HiveStore.box.delete(HiveKeys.engineSectionExpanded);
    await pumpPage(tester);

    // Collapsed: no engine radios, current engine shown as a summary.
    expect(find.byType(RadioListTile<String>), findsNothing);
    expect(find.text('MPV'), findsOneWidget);
    // Two expandable headers share the chevron icon now (playback +
    // engine), so scope the icon to the engine header row.
    Finder engineChevron(IconData icon) => find.descendant(
          of: find
              .ancestor(
                of: find.text('播放器引擎'),
                matching: find.byType(Row),
              )
              .last,
          matching: find.byIcon(icon),
        );
    expect(engineChevron(Icons.keyboard_arrow_down), findsOneWidget);

    // Expand: all three engines appear; the state is persisted.
    // One '播放器引擎' text now (the redundant section title above the
    // header was removed — chen: no duplicates).
    await tester.tap(find.text('播放器引擎').last);
    await tester.pumpAndSettle();
    expect(find.byType(RadioListTile<String>), findsNWidgets(3));
    expect(engineChevron(Icons.keyboard_arrow_up), findsOneWidget);
    expect(HiveStore.getBool(HiveKeys.engineSectionExpanded, false), isTrue);

    // Collapse again: radios gone, persisted as false.
    await tester.tap(find.text('播放器引擎').last);
    await tester.pumpAndSettle();
    expect(find.byType(RadioListTile<String>), findsNothing);
    expect(HiveStore.getBool(HiveKeys.engineSectionExpanded, true), isFalse);
  });

  testWidgets('engine section restores expanded state from Hive',
      (tester) async {
    await HiveStore.put(HiveKeys.engineSectionExpanded, true);
    await pumpPage(tester);

    expect(find.byType(RadioListTile<String>), findsNWidgets(3));
    expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
  });

  testWidgets('about section is the last section on the page',
      (tester) async {
    await pumpPage(tester);

    // 关于 sits below every other section's last row (缓存管理) and
    // its own rows (版本 / 检查更新 / 日志) follow it.
    final aboutTop = tester.getTopLeft(find.text('关于')).dy;
    final cacheTop = tester.getTopLeft(find.text('缓存管理')).dy;
    final versionTop = tester.getTopLeft(find.text('版本')).dy;
    final updateTop = tester.getTopLeft(find.text('检查更新')).dy;
    final logTop = tester.getTopLeft(find.text('日志')).dy;

    expect(aboutTop, greaterThan(cacheTop));
    expect(versionTop, greaterThan(aboutTop));
    expect(updateTop, greaterThan(versionTop));
    expect(logTop, greaterThan(updateTop));
  });

  testWidgets('日志 row opens the app log page', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();
    expect(find.byType(AppLogPage), findsOneWidget);
    // The old display-only 直播崩溃记录 row is gone.
    expect(find.text('直播崩溃记录'), findsNothing);
  });

  testWidgets('version row opens the changelog; 完成 closes it',
      (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('版本'));
    await tester.pumpAndSettle();
    expect(find.text('更新日志'), findsOneWidget);
    expect(find.text('v1.1.5'), findsOneWidget);
    expect(find.text('新增功能'), findsWidgets);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('更新日志'), findsNothing);
    expect(find.text('版本'), findsOneWidget);
  });

  Future<void> expandPlayback(WidgetTester tester) async {
    await HiveStore.box.delete(HiveKeys.playbackSectionExpanded);
    await pumpPage(tester);
    // Collapsed: panel rows hidden.
    expect(find.text('与其他音频同时播放'), findsNothing);
    // One '播放设置' text now (the redundant section title above the
    // header was removed — chen: no duplicates).
    await tester.tap(find.text('播放设置').last);
    await tester.pumpAndSettle();
    expect(HiveStore.getBool(HiveKeys.playbackSectionExpanded, false),
        isTrue);
  }

  testWidgets('playback section shows every Beans row, no VIP row, with EQ row',
      (tester) async {
    await expandPlayback(tester);

    expect(find.text('与其他音频同时播放'), findsOneWidget);
    expect(find.text('120Hz 高刷新'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('启动时自动播放上次歌曲'), findsOneWidget);
    // Subtitle removed (clean pass 2026-11-19): title + switch only.
    expect(find.text('打开软件后自动恢复上次未播放完的歌曲'),
        findsNothing);
    // ONE quality row (chen: all songs are third-party resolves).
    expect(find.text('播放音质'), findsOneWidget);
    expect(find.text('触感反馈'), findsOneWidget);
    // Stage 3: the EQ engine exists now, so the row is back (Beans
    // `equalizerSection`): real state trailing, opens the 10-band page.
    expect(find.text('均衡器'), findsOneWidget);
    // Subtitle removed (clean pass 2026-11-19): title + 已开启/已关闭
    // state trailing stays.
    expect(find.text('调节低音、人声与高音'), findsNothing);
    expect(find.text('已关闭'), findsOneWidget);
    expect(find.text('第三方音源'), findsOneWidget);
    // No second entry: the '管理 / 导入音源' button inside this panel
    // opened the same page as the standalone 音源管理 row (chen: no
    // duplicates) — it was removed; the count row stays as info only
    // and the single entry is the 音源管理 row in 源管理.
    expect(find.text('管理 / 导入音源'), findsNothing);
    expect(find.text('音源管理'), findsOneWidget);
    // Removed by chen: VIP notice (不提醒). The equalizer removal was
    // only because no engine existed; the engine is stage 3.
    expect(find.textContaining('会员歌提醒'), findsNothing);
  });

  testWidgets('EQ row opens the 10-band page', (tester) async {
    await expandPlayback(tester);

    await tester.tap(find.text('均衡器'));
    await tester.pumpAndSettle();
    // The EQ page: response preview + preamp + 8 presets + 10 bands.
    expect(find.text('频响预览'), findsOneWidget);
    expect(find.text('前级增益'), findsOneWidget);
    expect(find.text('摇滚'), findsOneWidget);
    // '16 kHz' is both a preview scale label and a band row.
    expect(find.text('16 kHz'), findsNWidgets(2));
    // Pop back so no pushed route leaks into the next test
    // (Get.reset in tearDown + a leftover route breaks the next
    // test's Get.find<ThemeController>).
    await tester.pageBack();
    await tester.pumpAndSettle();
  });

  testWidgets('haptics switch persists and flips the Hive flag',
      (tester) async {
    await HiveStore.put(HiveKeys.hapticsEnabled, true);
    await expandPlayback(tester);

    final row = find
        .ancestor(
          of: find.text('触感反馈'),
          matching: find.byType(Row),
        )
        .last;
    final hapticsSwitch = find.descendant(
      of: row,
      matching: find.byType(GlassSwitch),
    );
    expect(hapticsSwitch, findsOneWidget);
    await tester.tap(hapticsSwitch);
    await tester.pumpAndSettle();
    expect(HiveStore.getBool(HiveKeys.hapticsEnabled, true), isFalse);
  });
}
