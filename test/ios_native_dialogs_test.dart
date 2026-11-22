// N-4 / N-17: iOS dialog + sheet layouts.
// - Confirm dialog: title/content centered, actions full-width and
//   stacked vertically (confirm above cancel), dividers between.
// - Update dialog: same stacked layout (下载 / 跳过此版本 / 稍后).
// - Quality sheet: bottom sheet (not centred card), options + a
//   separate 取消 row at the bottom; tapping a row returns it.
// - Sleep sheet: bottom sheet with a CupertinoPicker wheel for custom
//   minutes (no TextField); scrolling the wheel changes the value and
//   开始自定义定时 returns custom.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:standalone/app/consts.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/widgets/quality_sheet.dart';
import 'package:standalone/features/music/widgets/sleep_timer_sheet.dart';
import 'package:standalone/features/settings/update_dialog.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/sleep_timer.dart';
import 'package:standalone/services/update_service.dart';
import 'package:standalone/widgets/glass_dialog.dart';

import 'helpers/hive_test_setup.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init(prefix: 'hao-ios-dialogs-');
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  tearDown(() {
    Get.reset();
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    required Future<void> Function(BuildContext context) opener,
  }) async {
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => opener(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('confirm dialog: native side-by-side actions',
      (tester) async {
    var result = false;
    await pumpHome(
      tester,
      opener: (context) async {
        result = await showGlassConfirmDialog(
          context,
          title: '删除歌单',
          content: '确定删除这个歌单吗？',
        );
      },
    );
    // NativeDialog.alert: UIAlertController on iOS lays the two
    // actions side by side (confirm left, cancel right) — the old
    // glass version stacked them full-width. The test host renders
    // the Material AlertDialog fallback, which keeps the same order
    // and row; centering is the native side's job (the fallback
    // title carries no textAlign), so only the layout is asserted.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('删除歌单'), findsOneWidget);
    expect(find.text('确定删除这个歌单吗？'), findsOneWidget);
    final confirmTop = tester.getTopLeft(find.text('确定')).dy;
    final cancelTop = tester.getTopLeft(find.text('取消')).dy;
    expect(confirmTop, closeTo(cancelTop, 1.0));
    final confirmLeft = tester.getTopLeft(find.text('确定')).dx;
    final cancelLeft = tester.getTopLeft(find.text('取消')).dx;
    expect(confirmLeft, lessThan(cancelLeft));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('update dialog: actions stacked, download on top',
      (tester) async {
    final parts = kAppVersion.split('.').map(int.parse).toList();
    parts[parts.length - 1] += 1;
    final info = UpdateInfo(
      version: parts.join('.'),
      build: 6,
      ipaUrl: 'https://example.com/hao.ipa',
      changelog: '新功能',
    );
    final service = UpdateService(dio: Dio());
    await pumpHome(
      tester,
      opener: (context) async {
        await showUpdateDialog(
          context,
          info,
          service: service,
          urlOpener: (_) async => true,
        );
      },
    );
    final downloadTop = tester.getTopLeft(find.text('下载')).dy;
    final skipTop = tester.getTopLeft(find.text('跳过此版本')).dy;
    final laterTop = tester.getTopLeft(find.text('稍后')).dy;
    expect(downloadTop, lessThan(skipTop));
    expect(skipTop, lessThan(laterTop));
    final downloadButton = find.ancestor(
      of: find.text('下载'),
      matching: find.byType(TextButton),
    );
    expect(tester.getSize(downloadButton).width, greaterThan(300));
  });

  testWidgets('quality sheet: bottom sheet, tap returns the quality',
      (tester) async {
    AudioQuality? picked;
    await pumpHome(
      tester,
      opener: (context) async {
        picked = await showQualitySheet(context, AudioQuality.hires);
      },
    );
    expect(find.text('音质'), findsOneWidget);
    expect(find.text('无损 FLAC'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    // Bottom sheet: the 取消 row sits near the bottom of the screen.
    final cancelBottom = tester.getBottomLeft(find.text('取消')).dy;
    expect(cancelBottom, greaterThan(500));
    await tester.tap(find.text('无损 FLAC'));
    await tester.pumpAndSettle();
    expect(picked, AudioQuality.lossless);
  });

  testWidgets('sleep sheet: picker wheel, no TextField', (tester) async {
    Get.put(MusicPlayerController());
    SleepTimerOption? picked;
    await pumpHome(
      tester,
      opener: (context) async {
        picked = await showSleepTimerSheet(context);
      },
    );
    expect(find.text('睡眠定时'), findsOneWidget);
    expect(find.byType(CupertinoPicker), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('取消'), findsOneWidget);
    // Scroll the wheel up two items: 30 -> 32 分钟 (default is 30).
    await tester.drag(
      find.byType(CupertinoPicker),
      const Offset(0, -64),
    );
    await tester.pumpAndSettle();
    expect(find.text('32 分钟'), findsOneWidget);
    // The start row sits below the fold in the test viewport:
    // scroll it into view before tapping.
    await tester.ensureVisible(find.text('开始自定义定时'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始自定义定时'));
    await tester.pumpAndSettle();
    expect(picked, SleepTimerOption.custom);
  });

  testWidgets('sleep sheet: N stepper changes the track count',
      (tester) async {
    final controller = Get.put(MusicPlayerController());
    SleepTimerOption? picked;
    await pumpHome(
      tester,
      opener: (context) async {
        picked = await showSleepTimerSheet(context);
      },
    );
    expect(find.text('播完 3 首后停止'), findsOneWidget);
    // + twice: 3 -> 5. The sheet stays open (stepper taps do not
    // trigger the row) and the controller records the new N.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(controller.sleepTrackCount.value, 5);
    expect(find.text('播完 5 首后停止'), findsOneWidget);
    expect(find.text('睡眠定时'), findsOneWidget);
    expect(picked, isNull);
    // − once: 5 -> 4.
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pump();
    expect(controller.sleepTrackCount.value, 4);
    // Lower bound clamps at 1: 4 -> 3 -> 2 -> 1, then stays at 1.
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
    }
    expect(controller.sleepTrackCount.value, 1);
    expect(find.text('播完 1 首后停止'), findsOneWidget);
    // Tapping the row itself starts the run with the new N.
    await tester.tap(find.text('播完 1 首后停止'));
    await tester.pumpAndSettle();
    expect(picked, SleepTimerOption.afterNTracks);
  });
}
