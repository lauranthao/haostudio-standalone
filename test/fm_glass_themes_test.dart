// FM / heartbeat glass cards across all themes (2026-11-19).
//
// The two cards in _fmRow render as real liquid glass (GlassCard
// standard + tint wash) instead of the solid Kumone gradient. The
// wash colours are fixed per mode, but the icon/title colour comes
// from theme.textPrimary, so every theme x brightness combination
// must render the cards without a layout error, with the tint
// present, and with the title in the theme's primary text colour
// and no shadow (the shadow only exists to lift white text off the
// solid gradient — on glass it muddies the text).
//
// Pumps the real MusicTabPage (tall viewport so the whole ListView
// lays out at once, same pattern as the render tests); no golden,
// no fonts needed — this asserts structure + colours, the goldens
// assert the pixels.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/glass.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/music_tab_page.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-fm-glass-');
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
      'test_fm_glass',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    HaoHaptics.debugEnabledOverride = false;
    Get.reset();
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  Future<void> pumpHome(WidgetTester tester, ThemeData theme) async {
    // Tall viewport so the whole page lays out at once (the FM row
    // sits mid-page; a phone viewport would leave it unbuilt).
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    Get.put(MusicPlayerController());
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: const MusicTabPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  for (final id in HaoThemeId.values) {
    for (final mode in ['light', 'dark']) {
      testWidgets('FM glass cards: ${HaoThemes.names[id]} $mode', (
        tester,
      ) async {
        final pair = HaoThemes.of(id);
        final theme = mode == 'light' ? pair.light : pair.dark;
        final expectedText =
            theme.extension<HaoTheme>()!.textPrimary;
        await pumpHome(tester, theme);

        // No layout error (overflow, missing theme, bad assert).
        expect(tester.takeException(), isNull);

        // Exactly the two FM cards carry a tint wash, both standard
        // quality (scrollable page — never premium). The shelf cards
        // and the playlists card have no tint.
        final tinted = tester
            .widgetList<GlassCard>(find.byType(GlassCard))
            .where((c) => c.tint != null)
            .toList();
        expect(tinted, hasLength(2));
        for (final card in tinted) {
          expect(card.quality, GlassCardQuality.standard);
          expect(card.radius, 12);
          expect(card.padding, EdgeInsets.zero);
          // The wash is a two-stop 135-degree gradient.
          expect(card.tint!.begin, Alignment.topLeft);
          expect(card.tint!.end, Alignment.bottomRight);
          expect(card.tint!.colors, hasLength(2));
        }

        // Titles use the theme's primary text (dark in light mode,
        // white in dark mode) with no shadow.
        for (final title in ['私人漫游', '心动模式']) {
          final text = tester.widget<Text>(find.text(title));
          expect(text.style!.color, expectedText);
          expect(text.style!.shadows ?? [], isEmpty);
          expect(text.style!.fontSize, 15);
          expect(text.style!.fontWeight, FontWeight.w700);
        }
      });
    }
  }
}
