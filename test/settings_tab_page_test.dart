// Settings page: seven collapsible groups + About at the bottom
// (build 29 B组, chen 2026-11-22 “设置里面要可以收放啊”; build 30
// adds the 直播 group: 弹幕设置 moved out of 影视播放, plus the
// 移动网自动降档 row that previously had no settings entry).
//
// - Every group header taps to collapse/expand (Cupertino chevron_down,
//   AnimatedSize body); state persists per group in Hive
//   (`settingsSectionExpanded_<id>`, bool, default true = all
//   expanded). The old `engineSectionExpanded` /
//   `playbackSectionExpanded` Hive keys are gone — D12.
// - The 关于 section (版本 / 检查更新 / 启动时自动检查更新) is the
//   last section on the page, after every other settings group;
//   日志 and 缓存管理 live in the 数据 group above it.

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/domains/live/live_network_quality.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/settings/app_log_page.dart';
import 'package:standalone/features/settings/settings_tab_page.dart';
import 'package:standalone/widgets/native_switch.dart';

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

  /// Build 29 B组: one Hive key per group, bool, default true.
  const sectionKeys = [
    'settingsSectionExpanded_appearance',
    'settingsSectionExpanded_music',
    'settingsSectionExpanded_live',
    'settingsSectionExpanded_video',
    'settingsSectionExpanded_sources',
    'settingsSectionExpanded_data',
    'settingsSectionExpanded_about',
  ];

  Future<void> clearSectionStates() async {
    for (final key in sectionKeys) {
      await HiveStore.box.delete(key);
    }
  }

  /// Tap a group header (the big title text) and settle the
  /// AnimatedSize + chevron rotation.
  Future<void> tapSectionHeader(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  Future<void> pumpPage(WidgetTester tester) async {
    // Tall viewport so the whole ListView lays out at once. The
    // collapsible page (build 29) is as tall as the flat build-28
    // one when every group is expanded; the 1.1.6 VOD/music rows
    // add ~530px more than the old collapsed page.
    tester.view.physicalSize = const Size(800, 4200);
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

  /// The HaoNativeSwitch inside the row titled [title] (Beans switch
  /// rows render title + trailing switch in one Row).
  Finder rowSwitch(String title) {
    final row = find
        .ancestor(
          of: find.text(title),
          matching: find.byType(Row),
        )
        .last;
    return find.descendant(
      of: row,
      matching: find.byType(HaoNativeSwitch),
    );
  }

  Future<void> tapRowSwitch(WidgetTester tester, String title) async {
    final sw = rowSwitch(title);
    expect(sw, findsOneWidget);
    await tester.tap(sw);
    await tester.pumpAndSettle();
  }

  /// The 0.4-grey lock wrapper (1.1.6 trio display lock) around
  /// the row titled [title]; findsNothing when the row is unlocked.
  Finder greyLock(String title) => find.ancestor(
        of: find.text(title),
        matching: find.byWidgetPredicate(
          (w) => w is Opacity && w.opacity == 0.4,
        ),
      );

  testWidgets('engine rows are visible by default, tap switches engine',
      (tester) async {
    await HiveStore.box.delete(HiveKeys.videoPlayerKey);
    await clearSectionStates();
    await pumpPage(tester);

    // Build 29: groups are collapsible, but all expanded by default —
    // all three engine rows visible with no tap. The header chevron is a
    // Cupertino chevron_down (one per group), not a Material arrow.
    expect(find.text('播放器引擎'), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
    expect(find.byIcon(CupertinoIcons.chevron_down), findsNWidgets(7));
    // G-设置 (Wave 2): iOS settings-style rows with a trailing
    // checkmark — no Material RadioListTile left on the page.
    expect(find.byType(RadioListTile<String>), findsNothing);
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
    expect(find.text('MPV'), findsOneWidget);
    expect(find.text('IJK'), findsOneWidget);
    expect(find.text('AVPlayer'), findsOneWidget);
    // AVPlayer row keeps its FLV warning subtitle (E8).
    expect(find.text('AVPlayer 不能播 FLV，失败时自动换内核'), findsOneWidget);

    // Tapping a row persists the engine key and moves the checkmark.
    await tester.tap(find.text('IJK'));
    await tester.pumpAndSettle();
    expect(HiveStore.getString(HiveKeys.videoPlayerKey, 'mpv'), 'ijk');
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
    // The check sits on the IJK row now, not the MPV row.
    final ijkRow = find
        .ancestor(
          of: find.text('IJK'),
          matching: find.byType(Row),
        )
        .first;
    expect(
      find.descendant(
        of: ijkRow,
        matching: find.byIcon(CupertinoIcons.checkmark),
      ),
      findsOneWidget,
    );
  });

  testWidgets('seven groups in order, old group names gone',
      (tester) async {
    await clearSectionStates();
    await pumpPage(tester);

    final tops = [
      for (final title in ['外观', '音乐播放', '直播', '影视播放', '源管理', '数据', '关于'])
        tester.getTopLeft(find.text(title)).dy,
    ];
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThan(tops[i - 1]));
    }
    expect(find.text('主题'), findsNothing);
    expect(find.text('播放设置'), findsNothing);
    expect(find.text('播放器引擎'), findsNothing);
    expect(find.text('备份与数据'), findsNothing);
    expect(find.text('播放与缓存'), findsNothing);
  });

  testWidgets('all seven groups are expanded by default',
      (tester) async {
    await clearSectionStates();
    await pumpPage(tester);

    // One representative row per group, all visible with no tap.
    expect(find.text('壁纸'), findsOneWidget);
    expect(find.text('音量归一化'), findsOneWidget);
    expect(find.text('移动网自动降档'), findsOneWidget);
    expect(find.text('Anime4K 超分'), findsOneWidget);
    expect(find.text('音源管理'), findsOneWidget);
    expect(find.text('导出备份'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
    // Seven headers, seven chevrons.
    expect(find.byIcon(CupertinoIcons.chevron_down), findsNWidgets(7));
  });

  testWidgets('tapping a group header collapses it and persists',
      (tester) async {
    await clearSectionStates();
    await pumpPage(tester);

    expect(find.text('Anime4K 超分'), findsOneWidget);
    await tapSectionHeader(tester, '影视播放');
    expect(find.text('Anime4K 超分'), findsNothing);
    expect(
        HiveStore.getBool('settingsSectionExpanded_video', true), isFalse);

    // The header stays put (no dead end): tapping it again re-opens.
    expect(find.text('影视播放'), findsOneWidget);
    await tapSectionHeader(tester, '影视播放');
    expect(find.text('Anime4K 超分'), findsOneWidget);
    expect(
        HiveStore.getBool('settingsSectionExpanded_video', true), isTrue);
  });

  testWidgets('collapsed state survives a restart (fresh pump)',
      (tester) async {
    await HiveStore.box.put('settingsSectionExpanded_video', false);
    await pumpPage(tester);

    expect(find.text('Anime4K 超分'), findsNothing);
    // Other groups are untouched by the persisted collapse.
    expect(find.text('壁纸'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);

    // A fresh page State (restart) re-reads Hive: still collapsed.
    await pumpPage(tester);
    expect(find.text('Anime4K 超分'), findsNothing);
    expect(find.text('壁纸'), findsOneWidget);
  });

  testWidgets('collapsing one group leaves the others untouched',
      (tester) async {
    await clearSectionStates();
    await pumpPage(tester);

    await tapSectionHeader(tester, '数据');
    expect(find.text('导出备份'), findsNothing);
    expect(find.text('导入备份'), findsNothing);
    expect(find.text('缓存管理'), findsNothing);
    expect(find.text('日志'), findsNothing);
    // Neighbours stay open.
    expect(find.text('直播源管理'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
  });

  testWidgets('collapsing then expanding every group restores all rows',
      (tester) async {
    await clearSectionStates();
    await pumpPage(tester);

    const groups = ['外观', '音乐播放', '直播', '影视播放', '源管理', '数据', '关于'];
    for (final group in groups) {
      await tapSectionHeader(tester, group);
    }
    expect(find.text('壁纸'), findsNothing);
    expect(find.text('音量归一化'), findsNothing);
    expect(find.text('Anime4K 超分'), findsNothing);
    expect(find.text('音源管理'), findsNothing);
    expect(find.text('导出备份'), findsNothing);
    expect(find.text('版本'), findsNothing);

    for (final group in groups) {
      await tapSectionHeader(tester, group);
    }
    expect(find.text('壁纸'), findsOneWidget);
    expect(find.text('音量归一化'), findsOneWidget);
    expect(find.text('Anime4K 超分'), findsOneWidget);
    expect(find.text('音源管理'), findsOneWidget);
    expect(find.text('导出备份'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
  });

  testWidgets('chevron points down when expanded, right when collapsed',
      (tester) async {
    await clearSectionStates();
    await pumpPage(tester);

    // One AnimatedRotation per group header, in page order
    // (appearance, music, live, video, sources, data, about); expanded
    // = 0 turns, so chevron_down points down.
    final rotations = find.byType(AnimatedRotation);
    expect(rotations, findsNWidgets(7));
    for (var i = 0; i < 7; i++) {
      expect(tester.widget<AnimatedRotation>(rotations.at(i)).turns, 0);
    }

    // Collapse 数据 (index 5): only its chevron rotates -0.25 turns
    // (chevron_down turns to point right); the other six stay down.
    await tapSectionHeader(tester, '数据');
    for (var i = 0; i < 7; i++) {
      expect(
        tester.widget<AnimatedRotation>(rotations.at(i)).turns,
        i == 5 ? -0.25 : 0,
      );
    }
  });

  testWidgets('toggling every group persists all seven Hive keys',
      (tester) async {
    await clearSectionStates();
    await pumpPage(tester);

    const groups = ['外观', '音乐播放', '直播', '影视播放', '源管理', '数据', '关于'];
    for (final group in groups) {
      await tapSectionHeader(tester, group);
    }
    for (final key in sectionKeys) {
      expect(HiveStore.getBool(key, true), isFalse);
    }
    for (final group in groups) {
      await tapSectionHeader(tester, group);
    }
    for (final key in sectionKeys) {
      expect(HiveStore.getBool(key, true), isTrue);
    }
  });

  testWidgets('every row of every group is present when all expanded',
      (tester) async {
    await clearSectionStates();
    await pumpPage(tester);

    // 外观: 4 theme chips + 3 mode segments + 7 rows. 恢复默认字体
    // only exists when a custom font is installed, so it is not
    // asserted here.
    const appearance = [
      '苹果毛玻璃',
      '暗夜鎏金',
      '清新薄荷',
      '极夜冰蓝',
      '浅色',
      '深色',
      '跟随系统',
      '壁纸',
      '壁纸管理',
      '自定义强调色',
      '背景色',
      '液态玻璃强度',
      '自定义字体',
    ];
    // 音乐播放: panel rows + loudness row.
    const music = [
      '与其他音频同时播放',
      '启动时自动播放上次歌曲',
      '播放音质',
      '触感反馈',
      '均衡器',
      '第三方音源',
      '音量归一化',
    ];
    // 直播：弹幕设置从影视播放组挪来；移动网自动降档此前只有
    // 播放器内面板入口，现在有了设置页行（同一 Hive 键）。
    const live = [
      '弹幕设置',
      '移动网自动降档',
    ];
    // 影视播放: 3 engine radios + 11 rows（弹幕设置已挪到直播组）。
    const video = [
      'MPV',
      'IJK',
      'AVPlayer',
      '自动连播下一集',
      '视频画面比例',
      'Anime4K 超分',
      '插帧',
      'SDR 转 HDR',
      '杜比视界 Profile 8 降级 HDR',
      '跳过片头片尾',
      '字幕字号',
      '字幕颜色',
      '字幕位置',
      '低内存模式',
    ];
    const sources = ['音源管理', '影视源管理', '直播源管理'];
    const data = ['导出备份', '导入备份', '缓存管理', '日志'];
    const about = ['版本', '检查更新', '启动时自动检查更新'];
    for (final title in [
      ...appearance,
      ...music,
      ...live,
      ...video,
      ...sources,
      ...data,
      ...about,
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
  });

  testWidgets('live group: cellular downgrade row writes the shared key',
      (tester) async {
    await clearSectionStates();
    // Default ON — the same default the live room reads.
    await HiveStore.box.delete(liveCellularDowngradeKey);
    await pumpPage(tester);

    // The row lives in the 直播 group, between 音乐播放 and 影视播放.
    final liveTop = tester.getTopLeft(find.text('直播')).dy;
    final rowTop = tester.getTopLeft(find.text('移动网自动降档')).dy;
    final videoTop = tester.getTopLeft(find.text('影视播放')).dy;
    expect(rowTop, greaterThan(liveTop));
    expect(rowTop, lessThan(videoTop));
    expect(liveCellularDowngradeEnabled(), isTrue);

    await tapRowSwitch(tester, '移动网自动降档');
    expect(liveCellularDowngradeEnabled(), isFalse);
    await tapRowSwitch(tester, '移动网自动降档');
    expect(liveCellularDowngradeEnabled(), isTrue);
  });

  testWidgets('about section is the last section on the page',
      (tester) async {
    await pumpPage(tester);

    // 关于 sits below every other section and its own rows
    // (版本 / 检查更新 / 启动时自动检查更新) follow it. 日志 and
    // 缓存管理 moved to the 数据 group above 关于 (build 28).
    final dataTop = tester.getTopLeft(find.text('数据')).dy;
    final aboutTop = tester.getTopLeft(find.text('关于')).dy;
    final exportTop = tester.getTopLeft(find.text('导出备份')).dy;
    final importTop = tester.getTopLeft(find.text('导入备份')).dy;
    final cacheTop = tester.getTopLeft(find.text('缓存管理')).dy;
    final logTop = tester.getTopLeft(find.text('日志')).dy;
    final versionTop = tester.getTopLeft(find.text('版本')).dy;
    final updateTop = tester.getTopLeft(find.text('检查更新')).dy;
    final autoCheckTop =
        tester.getTopLeft(find.text('启动时自动检查更新')).dy;

    expect(exportTop, greaterThan(dataTop));
    expect(importTop, greaterThan(exportTop));
    expect(cacheTop, greaterThan(importTop));
    expect(logTop, greaterThan(cacheTop));
    expect(aboutTop, greaterThan(logTop));
    expect(versionTop, greaterThan(aboutTop));
    expect(updateTop, greaterThan(versionTop));
    expect(autoCheckTop, greaterThan(updateTop));
  });

  testWidgets('redundant subtitles are gone, state subtitles stay',
      (tester) async {
    await pumpPage(tester);

    // E1–E5: the repeated hint subtitles are deleted.
    expect(find.text('选择备份文件恢复'), findsNothing);
    expect(find.text('导出全部本地数据（含音乐/壁纸文件）'), findsNothing);
    expect(find.text('已开启自定义背景色'), findsNothing);
    expect(find.text('关闭后回到主题默认背景'), findsNothing);
    expect(find.textContaining('仅影视播放'), findsNothing);
    expect(find.textContaining('下次打开生效'), findsNothing);
    // No font installed → no reset row (D4).
    expect(find.text('恢复默认字体'), findsNothing);
    expect(find.text('自定义字体'), findsOneWidget);
    // Kept: the version subtitle is state, not a hint.
    expect(find.textContaining('build'), findsOneWidget);
  });

  testWidgets('background swatches stay mounted when the switch is off',
      (tester) async {
    await pumpPage(tester);

    // One '背景色' text only (the switch row); the swatch card's
    // duplicate title is gone (A1), but the card itself stays mounted
    // (D5) — 恢复默认 is present even with the switch off.
    expect(find.text('背景色'), findsOneWidget);
    expect(find.text('恢复默认'), findsOneWidget);
  });

  testWidgets('low-memory tap cycles the mode and the subtitle follows',
      (tester) async {
    await HiveStore.put(HiveKeys.lowMemoryMode, 'auto');
    await pumpPage(tester);

    // b30: no toast, no "下次打开生效" — the mode applies at once
    // (a running player re-opens the episode at its position);
    // the subtitle states the effective state now.
    expect(find.textContaining('下次打开生效'), findsNothing);
    await tester.tap(find.text('低内存模式'));
    await tester.pump();
    expect(find.text('始终开启 · 减少缓存'), findsOneWidget);
    expect(HiveStore.getString(HiveKeys.lowMemoryMode, ''), 'always');
    await tester.tap(find.text('低内存模式'));
    await tester.pump();
    expect(find.text('始终关闭 · 完整缓存'), findsOneWidget);
    expect(HiveStore.getString(HiveKeys.lowMemoryMode, ''), 'never');
  });

  testWidgets('auto update check switch defaults on and persists',
      (tester) async {
    await HiveStore.box.delete(HiveKeys.autoUpdateCheck);
    await pumpPage(tester);

    final row = find
        .ancestor(
          of: find.text('启动时自动检查更新'),
          matching: find.byType(Row),
        )
        .last;
    final autoSwitch = find.descendant(
      of: row,
      matching: find.byType(HaoNativeSwitch),
    );
    expect(autoSwitch, findsOneWidget);
    expect(tester.widget<HaoNativeSwitch>(autoSwitch).value, isTrue);
    await tester.tap(autoSwitch);
    await tester.pumpAndSettle();
    expect(HiveStore.getBool(HiveKeys.autoUpdateCheck, true), isFalse);
  });

  testWidgets('Anime4K super-resolution switch defaults off and persists',
      (tester) async {
    await HiveStore.box.delete(HiveKeys.vodSuperResolution);
    await pumpPage(tester);

    // In the 影视播放 group, below 视频画面比例. The subtitle states
    // the scope (MPV-only, applies at once) — it is load-bearing, not
    // a hint: on IJK/AVPlayer the switch does nothing visible.
    final fitTop = tester.getTopLeft(find.text('视频画面比例')).dy;
    final srTop = tester.getTopLeft(find.text('Anime4K 超分')).dy;
    final lowMemTop = tester.getTopLeft(find.text('低内存模式')).dy;
    expect(srTop, greaterThan(fitTop));
    expect(lowMemTop, greaterThan(srTop));
    // 1.1.6: the same scope subtitle now also sits on 插帧 and
    // SDR 转 HDR (the MPV trio shares it). b30: the trio applies
    // at once, so the copy reads 立即生效, not 下次播放生效.
    expect(find.text('仅 MPV，立即生效'), findsNWidgets(3));

    final row = find
        .ancestor(
          of: find.text('Anime4K 超分'),
          matching: find.byType(Row),
        )
        .last;
    final srSwitch = find.descendant(
      of: row,
      matching: find.byType(HaoNativeSwitch),
    );
    expect(srSwitch, findsOneWidget);
    expect(tester.widget<HaoNativeSwitch>(srSwitch).value, isFalse);
    await tester.tap(srSwitch);
    await tester.pumpAndSettle();
    expect(HiveStore.getBool(HiveKeys.vodSuperResolution, false), isTrue);
  });

  testWidgets('1.1.6 VOD trio defaults off, DV P8 defaults on, persist',
      (tester) async {
    // The Anime4K test above leaves vodSuperResolution=true in the
    // shared box — clear it, or the trio rows start greyed out.
    await HiveStore.box.delete(HiveKeys.vodSuperResolution);
    await HiveStore.box.delete(HiveKeys.vodInterpolation);
    await HiveStore.box.delete(HiveKeys.vodSdrToHdr);
    await HiveStore.box.delete(HiveKeys.vodDvP8Downgrade);
    await pumpPage(tester);

    expect(find.text('插帧'), findsOneWidget);
    expect(find.text('SDR 转 HDR'), findsOneWidget);
    expect(find.text('杜比视界 Profile 8 降级 HDR'), findsOneWidget);
    // DV P8 has no subtitle (title only).
    expect(tester.widget<HaoNativeSwitch>(rowSwitch('插帧')).value, isFalse);
    expect(tester.widget<HaoNativeSwitch>(rowSwitch('SDR 转 HDR')).value,
        isFalse);
    expect(
        tester.widget<HaoNativeSwitch>(rowSwitch('杜比视界 Profile 8 降级 HDR'))
            .value,
        isTrue);

    await tapRowSwitch(tester, '插帧');
    expect(HiveStore.getBool(HiveKeys.vodInterpolation, false), isTrue);
    await tapRowSwitch(tester, '杜比视界 Profile 8 降级 HDR');
    expect(HiveStore.getBool(HiveKeys.vodDvP8Downgrade, true), isFalse);
  });

  testWidgets('MPV trio mutual exclusion greys the other two, keeps stored values',
      (tester) async {
    await HiveStore.box.delete(HiveKeys.vodSuperResolution);
    await HiveStore.box.delete(HiveKeys.vodInterpolation);
    await HiveStore.box.delete(HiveKeys.vodSdrToHdr);
    await pumpPage(tester);

    // All off: nothing greyed.
    expect(greyLock('Anime4K 超分'), findsNothing);
    expect(greyLock('插帧'), findsNothing);
    expect(greyLock('SDR 转 HDR'), findsNothing);

    // Turn super-res on: the other two grey out, their stored
    // values are NOT cleared.
    await tapRowSwitch(tester, 'Anime4K 超分');
    expect(greyLock('Anime4K 超分'), findsNothing);
    expect(greyLock('插帧'), findsOneWidget);
    expect(greyLock('SDR 转 HDR'), findsOneWidget);
    expect(HiveStore.getBool(HiveKeys.vodInterpolation, false), isFalse);
    expect(HiveStore.getBool(HiveKeys.vodSdrToHdr, false), isFalse);

    // Turn super-res off again: locks release.
    await tapRowSwitch(tester, 'Anime4K 超分');
    expect(greyLock('插帧'), findsNothing);
    expect(greyLock('SDR 转 HDR'), findsNothing);
  });

  testWidgets('MPV trio seeded on greys the other two from the start',
      (tester) async {
    await HiveStore.box.delete(HiveKeys.vodSuperResolution);
    await HiveStore.put(HiveKeys.vodInterpolation, true);
    await HiveStore.box.delete(HiveKeys.vodSdrToHdr);
    await pumpPage(tester);

    expect(tester.widget<HaoNativeSwitch>(rowSwitch('插帧')).value, isTrue);
    expect(greyLock('插帧'), findsNothing);
    expect(greyLock('Anime4K 超分'), findsOneWidget);
    expect(greyLock('SDR 转 HDR'), findsOneWidget);
  });

  testWidgets('skip intro row cycles four modes and persists',
      (tester) async {
    await HiveStore.box.delete(HiveKeys.vodSkipIntroMode);
    await pumpPage(tester);

    expect(find.text('跳过片头片尾'), findsOneWidget);
    expect(find.text('当前：关'), findsOneWidget);

    await tester.tap(find.text('跳过片头片尾'));
    await tester.pumpAndSettle();
    expect(find.text('当前：手动'), findsOneWidget);
    expect(HiveStore.getString(HiveKeys.vodSkipIntroMode, 'off'),
        'manual');

    await tester.tap(find.text('跳过片头片尾'));
    await tester.pumpAndSettle();
    expect(find.text('当前：自动延时 3 秒'), findsOneWidget);
    expect(HiveStore.getString(HiveKeys.vodSkipIntroMode, 'off'),
        'auto3s');

    await tester.tap(find.text('跳过片头片尾'));
    await tester.pumpAndSettle();
    expect(find.text('当前：自动立即'), findsOneWidget);
    expect(HiveStore.getString(HiveKeys.vodSkipIntroMode, 'off'),
        'autoNow');

    await tester.tap(find.text('跳过片头片尾'));
    await tester.pumpAndSettle();
    expect(find.text('当前：关'), findsOneWidget);
    expect(
        HiveStore.getString(HiveKeys.vodSkipIntroMode, 'off'), 'off');
  });

  /// The thumb centre of a CupertinoSlider (Flutter's slider only
  /// takes pointer events near the thumb — hitTestSelf in
  /// cupertino/slider.dart: |(dx - thumbCenter)| < radius + padding
  /// — so a drag must start ON the thumb, not the widget centre.
  /// Padding 8 / thumb radius 14 are that file's _kPadding and
  /// CupertinoThumbPainter.radius; the normalised value maps the
  /// widget's min..max onto the track.
  Offset sliderThumb(WidgetTester tester, Finder sliderFinder) {
    final slider = tester.widget<CupertinoSlider>(sliderFinder);
    final topLeft = tester.getTopLeft(sliderFinder);
    final size = tester.getSize(sliderFinder);
    final normalized =
        (slider.value - slider.min) / (slider.max - slider.min);
    const padding = 8.0;
    const radius = 14.0;
    return Offset(
      topLeft.dx +
          padding +
          radius +
          normalized * (size.width - 2 * (padding + radius)),
      topLeft.dy + size.height / 2,
    );
  }

  testWidgets('subtitle delay slider defaults 0s, drag persists a positive offset',
      (tester) async {
    await HiveStore.box.delete(HiveKeys.vodSubtitleDelay);
    await pumpPage(tester);

    expect(find.text('字幕时间偏移'), findsOneWidget);
    expect(find.text('0s'), findsOneWidget);
    final card = find
        .ancestor(
          of: find.text('字幕时间偏移'),
          matching: find.byType(Column),
        )
        .first;
    // G-设置 (Wave 2): iOS CupertinoSlider — no Material Slider
    // left on the page; same -10..10 range, 200 divisions.
    expect(find.descendant(of: card, matching: find.byType(Slider)),
        findsNothing);
    final slider = find.descendant(
      of: card,
      matching: find.byType(CupertinoSlider),
    );
    expect(slider, findsOneWidget);
    final sliderWidget = tester.widget<CupertinoSlider>(slider);
    expect(sliderWidget.min, -10);
    expect(sliderWidget.max, 10);
    expect(sliderWidget.divisions, 200);

    await tester.dragFrom(sliderThumb(tester, slider), const Offset(120, 0));
    await tester.pumpAndSettle();
    final stored = HiveStore.getDouble(HiveKeys.vodSubtitleDelay, 0.0);
    expect(stored, greaterThan(0));
    expect(find.textContaining('+'), findsOneWidget);
  });

  testWidgets('theme segmented control taps switch theme, same Hive key',
      (tester) async {
    await HiveStore.box.delete('haoThemeId');
    await clearSectionStates();
    await pumpPage(tester);

    // G-设置 (Wave 2): the four theme names are segments of one
    // CupertinoSlidingSegmentedControl — no Material ChoiceChip left.
    expect(find.byType(ChoiceChip), findsNothing);
    final segmented =
        find.byType(CupertinoSlidingSegmentedControl<HaoThemeId>);
    expect(segmented, findsOneWidget);
    expect(
      tester
          .widget<CupertinoSlidingSegmentedControl<HaoThemeId>>(segmented)
          .groupValue,
      HaoThemeId.appleGlass,
    );

    await tester.tap(find.text('暗夜鎏金'));
    await tester.pumpAndSettle();
    expect(Get.find<ThemeController>().themeId.value, HaoThemeId.darkGold);
    expect(HiveStore.box.get('haoThemeId'), 'darkGold');
  });

  testWidgets('glass intensity slider drag previews, release persists',
      (tester) async {
    await HiveStore.box.delete('haoGlassIntensity');
    await clearSectionStates();
    await pumpPage(tester);

    expect(find.text('液态玻璃强度'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    final card = find
        .ancestor(
          of: find.text('液态玻璃强度'),
          matching: find.byType(Column),
        )
        .first;
    final slider = find.descendant(
      of: card,
      matching: find.byType(CupertinoSlider),
    );
    expect(slider, findsOneWidget);
    expect(tester.widget<CupertinoSlider>(slider).value, 1.0);

    // Drag left from the thumb: the live preview moves the value,
    // Hive is only written once on release (onChangeEnd) — same
    // key as before. (The % label is NOT asserted here: in the real
    // app the root Obx rebuilds the page on every preview tick, but
    // this test's GetMaterialApp has no root Obx, so the label does
    // not refresh mid-drag — the controller value + Hive write are
    // the contract.)
    await tester.dragFrom(
        sliderThumb(tester, slider), const Offset(-120, 0));
    await tester.pumpAndSettle();
    final controller = Get.find<ThemeController>();
    expect(controller.glassIntensity.value, lessThan(1.0));
    expect(HiveStore.box.get('haoGlassIntensity'),
        controller.glassIntensity.value);
  });

  testWidgets('volume normalisation switch defaults off and persists',
      (tester) async {
    await HiveStore.box.delete(HiveKeys.musicNormalizationEnabled);
    await pumpPage(tester);

    expect(find.text('音量归一化'), findsOneWidget);
    expect(tester.widget<HaoNativeSwitch>(rowSwitch('音量归一化')).value,
        isFalse);
    await tapRowSwitch(tester, '音量归一化');
    expect(HiveStore.getBool(HiveKeys.musicNormalizationEnabled, false),
        isTrue);
  });

  testWidgets('normalisation strength picker defaults to 标准 and persists', (
    tester,
  ) async {
    await HiveStore.box.delete(HiveKeys.musicNormalizationStrength);
    await pumpPage(tester);

    expect(find.text('归一化强度'), findsOneWidget);
    final segmented = find.byType(CupertinoSlidingSegmentedControl<int>);
    expect(segmented, findsOneWidget);
    expect(
      tester
          .widget<CupertinoSlidingSegmentedControl<int>>(segmented)
          .groupValue,
      1,
    );

    await tester.tap(find.text('强力'));
    await tester.pumpAndSettle();
    expect(HiveStore.getInt(HiveKeys.musicNormalizationStrength, 1), 2);
    expect(MusicPlayerController.ensure().normalizationStrength.value, 2);
    expect(
      tester
          .widget<CupertinoSlidingSegmentedControl<int>>(segmented)
          .groupValue,
      2,
    );
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

  testWidgets('music playback group shows every Beans row, no VIP row, with EQ row',
      (tester) async {
    await pumpPage(tester);

    // Flat (build 28): rows visible with no expand tap; the 120Hz
    // display row is deleted (D2).
    expect(find.text('音乐播放'), findsOneWidget);
    expect(find.text('与其他音频同时播放'), findsOneWidget);
    expect(find.text('120Hz 高刷新'), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.text('启动时自动播放上次歌曲'), findsOneWidget);
    // Subtitle removed (clean pass 2026-11-19): title + switch only.
    expect(find.text('打开软件后自动恢复上次未播放完的歌曲'),
        findsNothing);
    // ONE quality row (chen: all songs are third-party resolves).
    expect(find.text('播放音质'), findsOneWidget);
    // Quality hint removed (build 28 E4).
    expect(find.text('无法使用时会由平台自动降级。'), findsNothing);
    expect(find.text('触感反馈'), findsOneWidget);
    // Stage 3: the EQ engine exists now, so the row is back (Beans
    // `equalizerSection`): real state trailing, opens the 10-band page.
    expect(find.text('均衡器'), findsOneWidget);
    // Subtitle removed (clean pass 2026-11-19): title + 已开启/已关闭
    // state trailing stays.
    expect(find.text('调节低音、人声与高音'), findsNothing);
    expect(find.text('已关闭'), findsOneWidget);
    expect(find.text('第三方音源'), findsOneWidget);
    // 1.1.6: loudness normalisation row, below the panel.
    expect(find.text('音量归一化'), findsOneWidget);
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
    await pumpPage(tester);

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
    await pumpPage(tester);

    final row = find
        .ancestor(
          of: find.text('触感反馈'),
          matching: find.byType(Row),
        )
        .last;
    final hapticsSwitch = find.descendant(
      of: row,
      matching: find.byType(HaoNativeSwitch),
    );
    expect(hapticsSwitch, findsOneWidget);
    await tester.tap(hapticsSwitch);
    await tester.pumpAndSettle();
    expect(HiveStore.getBool(HiveKeys.hapticsEnabled, true), isFalse);
  });
}
