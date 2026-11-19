// HAo Studio standalone — Flutter v1.0.4 (version 1.0.4, build 5).
//
// Entry: Hive init (app_settings box) -> ThemeController -> GetMaterialApp
// with the 4-theme system (immediate switching, light/dark/system).
// No login / community / shop / admin: video / live / music + settings +
// backup/restore only. Player is native (media_kit / fijk / AVPlayer),
// never a web <video>.
//
// NOTE (chen 2026-11-16 ~13:07): do NOT build an IPA unless he explicitly
// asks. Keep optimizing the app code; verify with flutter analyze /
// flutter test. When the app is ready for him to test, say so and WAIT
// for him to ask for the IPA. codemagic.yaml stays a draft.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'core/storage/hive_store.dart';
import 'core/storage/local_paths.dart';
import 'core/theme/appearance_store.dart';
import 'core/theme/liquid_glass_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/live/live_breadcrumb.dart';
import 'features/music/av_music_player.dart';
import 'features/music/mini_player_overlay.dart';
import 'features/settings/update_dialog.dart';
import 'features/splash/splash_page.dart';
import 'services/custom_font_service.dart';
import 'services/music/equalizer_store.dart';
import 'services/update_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Liquid glass shader pipeline: pre-warm fragment shaders before
  // runApp so the first glass frame has no white flash / jank
  // (liquid_glass_widgets SKILL.md §2). No-op cost on Skia-only
  // platforms (Linux tests / web): premium preload is skipped there
  // by the library's own static probe.
  await LiquidGlassWidgets.initialize();

  // media_kit native library MUST be initialised before any Player()
  // is created. Without this, NativeLibrary.path throws on first
  // Player() construction (music tab blank, live/video stuck loading).
  // Idempotent: media_kit guards with an internal _initialized flag.
  MediaKit.ensureInitialized();

  // Crash breadcrumb: read before anything else (fix 1).
  await HiveStore.init();
  // Warm the Documents-directory cache so every synchronous
  // LocalPaths.resolveSync on the playback hot path (downloads /
  // wallpapers) has a current container to resolve against. Without
  // this, a stale absolute index entry could not be repaired until
  // the first async directory call.
  await LocalPaths.ensureDocumentsPath();
  final lastCrashStage = LiveBreadcrumb.current;
  if (lastCrashStage.isNotEmpty) {
    debugPrint('[HAo] last live stage before crash/close: $lastCrashStage');
  }

  // "与其他音频同时播放" (Beans `configureAudioSession`): apply the
  // saved preference to the audio session before any playback.
  unawaited(
    AvMusicPlayer.applyMixWithOthers(
      HiveStore.getBool(HiveKeys.audioMixWithOthers, false),
    ),
  );

  // Equalizer (stage 3, Beans `BeansEqualizer`): push the persisted
  // enabled/gains/preamp to the native MTAudioProcessingTap engine
  // before any playback, so items created by either crossfade player
  // pick the tap up at creation. No-op off iOS/macOS (the channel
  // call returns false there and the Hive values stay the truth).
  unawaited(EqualizerStore.ensure().syncToNative());

  final themeController = Get.put(ThemeController());
  themeController.loadFromBox(HiveStore.box);

  // Custom font (stage 2, Beans `FontManager.reinstallIfNeeded`):
  // re-register the stored font before the first frame so the custom
  // family is already available when ThemeData applies it.
  await CustomFontService().loadPersisted();

  // Appearance (stage 2: wallpaper / background colour): load the
  // stored background state before the first frame so the AppShell
  // layer paints immediately.
  final appearanceController = Get.put(AppearanceController());
  await appearanceController.load();

  // Automatic update check, 2 s after start, at most once per 20 h.
  // Silent when throttled / up to date / fetch fails (fix 8). When a
  // newer version IS found, show the same download dialog as the
  // manual check — not just a snackbar.
  final updateService = UpdateService();
  unawaited(
    Future<void>.delayed(const Duration(seconds: 2), () async {
      final info = await updateService.checkAuto();
      if (info == null) return;
      await updateService.recordKnownUpdate(info.version);
      final context = Get.context;
      if (context == null || !context.mounted) return;
      await showUpdateDialog(context, info, service: updateService);
    }),
  );

  runApp(
    LiquidGlassWidgets.wrap(
      // Dynamically benchmarks the device raster budget and scales
      // quality (premium on capable devices, down on weak ones).
      adaptiveQuality: true,
      // Degrades on Reduce Motion / Reduce Transparency.
      respectSystemAccessibility: true,
      // Bridges Material ThemeMode so glass honours our light/dark/
      // system modes even when the OS disagrees.
      brightnessResolver: Theme.maybeBrightnessOf,
      // ios27 defaults; our 4 themes map at widget level, see
      // liquid_glass_theme.dart (no global quality override, Rule 5).
      theme: HaoLiquidGlass.themeData,
      child: const HAoApp(),
    ),
  );
}

class HAoApp extends StatelessWidget {
  const HAoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeController = Get.find<ThemeController>();
    return Obx(
      () => GetMaterialApp(
        title: 'HAo Studio',
        theme: themeController.lightTheme,
        darkTheme: themeController.darkTheme,
        themeMode: themeController.themeMode.value,
        home: const SplashPage(),
        navigatorObservers: [musicRouteObserver],
        // App-level mini player overlay: floats above the root Navigator
        // on music sub-pages only (the observer decides). The home keeps
        // its own embedded bar; the overlay is hidden there, on the full
        // player, and on video / live / settings pages.
        builder: (context, child) => Stack(
          children: [
            child ?? const SizedBox.shrink(),
            MiniPlayerOverlay(observer: musicRouteObserver),
          ],
        ),
      ),
    );
  }
}
