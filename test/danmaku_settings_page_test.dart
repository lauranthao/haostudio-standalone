// Danmaku settings page — the area SegmentedButton with four options
// （全屏 / 上半屏 / 上 1/3 / 上 1/5）.
//
// Proves the fourth segment fits a 420pt phone (iPhone Air width)
// without overflow and that tapping 上 1/5 selects it and persists
// the 'fifth' value (fraction 1/5) via DanmakuSettings.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/settings/danmaku_settings_page.dart';
import 'package:standalone/features/settings/source_stores.dart';
import 'package:standalone/widgets/hao_segmented_control.dart';

import 'helpers/hive_test_setup.dart' as hive_setup;

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-danmaku-page-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
  });

  // NOTE: do NOT await the Hive box close here. Pending Hive writes from
  // fire-and-forget deletes never resolve in the widget-test fake zone, so
  // awaiting close() hangs tearDownAll forever. Fire-and-forget: the temp
  // dir is deleted right after anyway.
  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // iPhone Air logical width: 420pt.
    tester.view.physicalSize = const Size(420, 874);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: const DanmakuSettingsPage(),
      ),
    );
    await tester.pump();
  }

  /// Hive writes must run in the real zone (runAsync); they hang inside
  /// the fake-async zone. Drain real async work after a tap so the
  /// page's setState has landed before asserting.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  HaoSegmentedControl<String> areaSegments(WidgetTester tester) {
    return tester.widget<HaoSegmentedControl<String>>(
      find.ancestor(
        of: find.text('上 1/5'),
        matching: find.byType(HaoSegmentedControl<String>),
      ),
    );
  }

  testWidgets('four area segments fit a 420pt phone without overflow', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('全屏'), findsOneWidget);
    expect(find.text('上半屏'), findsOneWidget);
    expect(find.text('上 1/3'), findsOneWidget);
    expect(find.text('上 1/5'), findsOneWidget);
    // Any RenderFlex overflow surfaces here as a FlutterError.
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping 上 1/5 selects it and persists fifth', (
    tester,
  ) async {
    await pumpPage(tester);
    // The area section sits below the platform switches: scroll it
    // into view first, or the tap misses the viewport.
    await tester.ensureVisible(find.text('上 1/5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上 1/5'));
    // Pump once so the tap's onTap fires and its Hive write starts;
    // settle's runAsync window is BEFORE its pump, so without this
    // the write only starts after settle returns and the value read
    // below is still the old one.
    await tester.pump();
    await settle(tester);
    // The write lands during settle's pump and its setState runs
    // mid-pump (after the build phase), so one more pump is needed
    // for the rebuild to land (probe: value flips only after the
    // second pump / pumpAndSettle).
    await tester.pump();
    expect(areaSegments(tester).value, 'fifth');
    expect(DanmakuSettings.area(), DanmakuSettings.areaFifth);
    expect(DanmakuSettings.areaFraction(), closeTo(1 / 5, 0.001));
    expect(tester.takeException(), isNull);
    // Drain the fire-and-forget setArea write before this test ends,
    // or the next test's first Hive write queues behind it and never
    // lands (see helpers/hive_test_setup.dart).
    await hive_setup.drainHiveWrites(tester);
  });

  testWidgets('switch group is titled 弹幕开关 and has a 影视弹幕 row', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('弹幕开关'), findsOneWidget);
    expect(find.text('各平台弹幕开关'), findsNothing);
    expect(find.text('影视弹幕'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('影视弹幕 defaults OFF and toggling it persists', (
    tester,
  ) async {
    await pumpPage(tester);
    // Default OFF (opt-in): absent key means disabled for 'vod',
    // unlike the live platforms which default ON.
    expect(DanmakuSettings.isEnabled(DanmakuSettings.vodSiteId), isFalse);
    final tile = tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('影视弹幕'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(tile.value, isFalse);
    await tester.tap(find.text('影视弹幕'));
    // Drain (not the file-local settle): the Hive serial write queue
    // needs a flush probe per write, or the next write queues behind
    // a still-pending one and never lands (see
    // helpers/hive_test_setup.dart).
    await hive_setup.drainHiveWrites(tester);
    // drainHiveWrites pumps BEFORE the flush lands the write, so the
    // setState rebuild it triggers is still pending: pump once so
    // the switch shows the new value, or the next tap re-sends the
    // old value and the toggle never lands.
    await tester.pump();
    expect(DanmakuSettings.isEnabled(DanmakuSettings.vodSiteId), isTrue);
    await tester.tap(find.text('影视弹幕'));
    await hive_setup.drainHiveWrites(tester);
    await tester.pump();
    expect(DanmakuSettings.isEnabled(DanmakuSettings.vodSiteId), isFalse);
    expect(tester.takeException(), isNull);
  });
}
