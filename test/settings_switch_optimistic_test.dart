// build 27 general group — settings switches + glass slider
// (G-P2-2, G-P2-3).
//
// - G-P2-2: the wallpaper / background-colour switches flip
//   optimistically (thumb moves on the first frame, before the Hive
//   write lands); a write that does not stick flips the thumb back
//   and shows a snackbar. The real AppearanceStore swallows write
//   errors, so "did not stick" is detected by re-reading the
//   persisted value — the slow, never-persisting store below makes
//   that path deterministic.
// - G-P2-3: dragging the glass-intensity slider only previews in
//   memory (zero Hive puts during the drag); Hive is written once
//   when the drag ends.

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/appearance_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/settings/settings_tab_page.dart';
import 'package:standalone/widgets/native_switch.dart';

/// A store whose switch writes never land (and never throw — the
/// real store swallows errors, so the page must notice via re-read).
/// The delay keeps the write pending across the first pumped frame,
/// so the optimistic flip is observable before the rollback.
class _NeverPersistingStore extends AppearanceStore {
  @override
  Future<void> setWallpaperEnabled(bool value) async {
    await Future.delayed(const Duration(milliseconds: 300));
  }

  @override
  bool get wallpaperEnabled => false;

  @override
  Future<void> setBackgroundEnabled(bool value) async {
    await Future.delayed(const Duration(milliseconds: 300));
  }

  @override
  bool get backgroundEnabled => false;
}

/// Counts Hive puts (G-P2-3 unit check: preview must not write).
class _CountingBox extends Fake implements Box<dynamic> {
  var puts = 0;
  Object? lastPutValue;

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) => null;

  @override
  Future<void> put(dynamic key, dynamic value) async {
    puts++;
    lastPutValue = value;
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-settings-b27-');
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
      'test_settings_b27',
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
    // 4200: the 1.1.6 six-group page is ~4200pt tall (same height
    // settings_tab_page_test.dart uses) — at 2400/3200 the last
    // switch (关于 group) stays below the fold and ListView never
    // builds it, so the count reads 11, not 12.
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

  /// The visible HaoNativeSwitches, in page order: wallpaper, background
  /// colour, then the rest of the flat 6-group page (13 _BeansSwitchRow
  /// + 3 _PanelSwitch = 16; the old "12" predates the I-影视 VOD rows
  /// — dialogue boost, 2x spoiler, pure-audio — 4 switches).
  List<HaoNativeSwitch> switches(WidgetTester tester) =>
      tester.widgetList<HaoNativeSwitch>(find.byType(HaoNativeSwitch)).toList();

  group('G-P2-2 optimistic switches', () {
    testWidgets('wallpaper switch flips on the first frame, then persists',
        (tester) async {
      await pumpPage(tester);
      expect(switches(tester).length, 16);
      expect(switches(tester).first.value, isFalse);

      await tester.tap(find.byType(HaoNativeSwitch).first);
      await tester.pump(); // exactly one frame — no settle
      expect(switches(tester).first.value, isTrue);

      await tester.pumpAndSettle();
      expect(switches(tester).first.value, isTrue);
      expect(HiveStore.getBool(HiveKeys.wallpaperEnabled, false), isTrue);
    });

    testWidgets('background switch flips on the first frame, then persists',
        (tester) async {
      await pumpPage(tester);
      expect(switches(tester)[1].value, isFalse);

      await tester.tap(find.byType(HaoNativeSwitch).at(1));
      await tester.pump();
      expect(switches(tester)[1].value, isTrue);

      await tester.pumpAndSettle();
      expect(switches(tester)[1].value, isTrue);
      expect(HiveStore.getBool(HiveKeys.bgColorEnabled, false), isTrue);
    });

    testWidgets('wallpaper switch flips back + snackbar when write fails',
        (tester) async {
      Get.put(AppearanceController(store: _NeverPersistingStore()));
      await pumpPage(tester);
      expect(switches(tester).first.value, isFalse);

      await tester.tap(find.byType(HaoNativeSwitch).first);
      await tester.pump(); // write still pending (300ms delay)
      expect(switches(tester).first.value, isTrue);

      await tester.pumpAndSettle(); // write "lands" (never), rollback
      expect(switches(tester).first.value, isFalse);
      expect(find.text('设置失败'), findsOneWidget);
      // Drain the snackbar's 3s dismiss timer: leaving it pending
      // fails disposal AND queues the next test's snackbar behind
      // this one (GetX's snackbar queue is global). pumpAndSettle
      // alone does NOT fire the timer (a Timer schedules no frame),
      // so step the clock past 3s in small pumps — one big pump()
      // jump breaks the snackbar's animation controller — then let
      // the dismiss animation finish.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
      expect(find.text('设置失败'), findsNothing);
    });

    testWidgets('background switch flips back + snackbar when write fails',
        (tester) async {
      Get.put(AppearanceController(store: _NeverPersistingStore()));
      await pumpPage(tester);
      expect(switches(tester)[1].value, isFalse);

      await tester.tap(find.byType(HaoNativeSwitch).at(1));
      await tester.pump();
      expect(switches(tester)[1].value, isTrue);

      await tester.pumpAndSettle();
      expect(switches(tester)[1].value, isFalse);
      expect(find.text('设置失败'), findsOneWidget);
      // Drain the snackbar's 3s dismiss timer (see the wallpaper
      // rollback test above).
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
      expect(find.text('设置失败'), findsNothing);
    });
  });

  group('G-P2-3 slider writes Hive once, on drag end', () {
    test('preview writes nothing; drag-end write is a single put', () {
      final box = _CountingBox();
      final controller = ThemeController();
      for (var i = 0; i < 10; i++) {
        controller.setGlassIntensityPreview(i / 10);
      }
      expect(controller.glassIntensity.value, 0.9);
      expect(box.puts, 0);
      controller.setGlassIntensity(0.9, box: box);
      expect(box.puts, 1);
      expect(box.lastPutValue, 0.9);
    });

    testWidgets('no Hive put during the drag, one after release', (
      tester,
    ) async {
      await pumpPage(tester);
      final controller = Get.find<ThemeController>();
      expect(controller.glassIntensity.value, 1.0);
      expect(HiveStore.box.get('haoGlassIntensity'), isNull);

      // Two CupertinoSliders live on the page in 1.1.6 (glass
      // intensity 0.0–1.0 + subtitle offset −10–10; G-设置 Wave 2
      // replaced the Material Sliders): scope to the glass one.
      final slider = find.byWidgetPredicate(
        (w) => w is CupertinoSlider && w.min == 0.0 && w.max == 1.0,
      );
      expect(slider, findsOneWidget);
      // CupertinoSlider only grabs near the thumb (iOS behaviour);
      // at value 1.0 the thumb sits at the right end, so start the
      // gesture there — the widget centre misses (see
      // settings_tab_page_test.dart's sliderThumb helper for the
      // same math: padding 8, thumb radius 14).
      final topLeft = tester.getTopLeft(slider);
      final size = tester.getSize(slider);
      final thumb = Offset(
        topLeft.dx + size.width - 8.0 - 14.0,
        topLeft.dy + size.height / 2,
      );
      final gesture = await tester.startGesture(thumb);
      // The first move only arms the drag: CupertinoSlider's
      // recognizer uses DragStartBehavior.start, so the move that
      // crosses the touch slop is discarded — the value does not
      // move and nothing is written. (The Material Slider moved
      // on the first move; verified side by side: Material
      // 1.0 -> 0.9913 on the first -20, Cupertino stays 1.0
      // until the second move.) The G-P2-3 contract is about the
      // Hive puts, not the first move: nothing during the drag,
      // one put on release.
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      expect(controller.glassIntensity.value, 1.0);
      expect(HiveStore.box.get('haoGlassIntensity'), isNull);
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      expect(controller.glassIntensity.value, lessThan(1.0));
      expect(HiveStore.box.get('haoGlassIntensity'), isNull);
      await gesture.up();
      await tester.pumpAndSettle();

      final stored = HiveStore.box.get('haoGlassIntensity');
      expect(stored, isNotNull);
      expect(stored, lessThan(1.0));
      expect(stored, controller.glassIntensity.value);
    });
  });
}
