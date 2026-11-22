// HAo Studio standalone — Flutter v1.0.4 (version 1.0.4, build 5).
//
// Entry: Hive init (app_settings box) -> runApp on default theme /
// system font -> post-first-frame warm-up (ThemeController / font /
// appearance / log / shader pre-warm, see _warmUpAfterFirstFrame).
// No login / community / shop / admin: video / live / music + settings +
// backup/restore only. Player is native (media_kit / fijk / AVPlayer),
// never a web <video>.
//
// NOTE (chen 2026-11-16 ~13:07): do NOT build an IPA unless he explicitly
// asks. Keep optimizing the app code; verify with flutter analyze /
// flutter test. When the app is ready for him to test, say so and WAIT
// for him to ask for the IPA. codemagic.yaml stays a draft.

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'app/consts.dart';
import 'core/logging/app_log.dart';
import 'core/storage/hive_store.dart';
import 'core/storage/local_paths.dart';
import 'core/theme/appearance_store.dart';
import 'core/theme/liquid_glass_theme.dart';
import 'core/theme/screen_capture.dart';
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

  // Crash net (build 30): an uncaught error must be logged, not kill
  // the isolate (blank screen / quit). FlutterError.onError keeps the
  // default dump so framework errors still surface in logs;
  // PlatformDispatcher.onError returning true marks an async error
  // handled — without it, an uncaught async error can take the whole
  // isolate down.
  FlutterError.onError = (details) {
    debugPrint('FlutterError: ${details.exception}');
    FlutterError.dumpErrorToConsole(details, forceReport: true);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught async error: $error\n$stack');
    return true;
  };

  // P0-2: runApp 前只留 HiveStore.init() — the serial awaits that
  // used to sit here (LiquidGlassWidgets.initialize, LocalPaths,
  // AppLog, font, appearance) locked cold start to ~2 s+ before the
  // first frame. Everything else now runs after the first frame (see
  // [_warmUpAfterFirstFrame]): the first frame paints on the default
  // theme / system font, and the stored theme / font / appearance
  // land a moment later and refresh once. HiveStore.init() does NOT
  // depend on LocalPaths.ensureDocumentsPath (plain Hive.initFlutter
  // + openBox), so nothing else needs to stay in front of runApp.
  //
  // The two Get.put calls below are synchronous registrations, not
  // initialization work: HAoApp.build does Get.find<ThemeController>
  // on the first frame, so the controller must exist before runApp.
  // Their loads (loadFromBox / migrate + load) move to the warm-up.
  await HiveStore.init();

  // P0-3: lock portrait before the first frame. Info.plist declares
  // Portrait + LandscapeLeft + LandscapeRight (fullscreen needs the
  // landscape orientations), so without this a cold start with the
  // phone turned rotates the whole app until the first fullscreen
  // exit locks it. The fullscreen controller's own enter/exit logic
  // is untouched.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  final themeController = Get.put(ThemeController());
  final appearanceController = Get.put(AppearanceController());

  // First frame first: the warm-up below runs once the first frame
  // has painted.
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(
      _warmUpAfterFirstFrame(themeController, appearanceController),
    ),
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

/// Everything that used to block the first frame, now deferred until
/// after it has painted (P0-2). Order inside is the old order:
/// media_kit first (any Player() created from here on needs it;
/// mpv_backend re-ensures it itself before building a Player), then
/// shader pre-warm, Documents path, log, audio session, equalizer,
/// theme / font / appearance loads, and the automatic update check.
/// The splash animation itself (#4, chen's pick) is untouched.
Future<void> _warmUpAfterFirstFrame(
  ThemeController themeController,
  AppearanceController appearanceController,
) async {
  // media_kit native library MUST be initialised before any Player()
  // is created. Without this, NativeLibrary.path throws on first
  // Player() construction (music tab blank, live/video stuck loading).
  // Idempotent: media_kit guards with an internal _initialized flag.
  MediaKit.ensureInitialized();

  // Liquid glass shader pipeline: pre-warm fragment shaders so glass
  // frames have no white flash / jank (liquid_glass_widgets SKILL.md
  // §2). No-op cost on Skia-only platforms (Linux tests / web):
  // premium preload is skipped there by the library's own static
  // probe.
  await LiquidGlassWidgets.initialize();

  // Warm the Documents-directory cache so every synchronous
  // LocalPaths.resolveSync on the playback hot path (downloads /
  // wallpapers) has a current container to resolve against. Without
  // this, a stale absolute index entry could not be repaired until
  // the first async directory call.
  await LocalPaths.ensureDocumentsPath();

  // Runtime log: in-memory ring + persisted file (Settings → 日志).
  await AppLog.init();
  AppLog.info('HAo Studio 启动（版本 $kAppVersion build $kAppBuild）');

  final lastCrashStage = LiveBreadcrumb.current;
  if (lastCrashStage.isNotEmpty) {
    AppLog.debug('上次直播阶段：$lastCrashStage');
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

  // Stored theme / mode / custom font / custom accent: the first
  // frame already painted on the defaults; applying the stored values
  // now rebuilds GetMaterialApp once via the root Obx.
  themeController.loadFromBox(HiveStore.box);

  // Custom font (stage 2, Beans `FontManager.reinstallIfNeeded`):
  // re-register the stored font; the theme rebuild above picks the
  // family up once the font is registered.
  await CustomFontService().loadPersisted();

  // Appearance (stage 2: wallpaper / background colour): the v1.1.5
  // migration runs first (turn a stored wallpaper-on off once — the
  // unified page needs the theme background, not a photo), so load()
  // already reads the migrated state.
  await appearanceController.migrateWallpaperOffOnce();
  await appearanceController.load();

  // Automatic update check, 2 s after warm-up, at most once per 20 h.
  // Silent when throttled / up to date / fetch fails (fix 8). When a
  // newer version IS found, show the same download dialog as the
  // manual check — not just a snackbar.
  final updateService = UpdateService();
  unawaited(
    Future<void>.delayed(const Duration(seconds: 2), () async {
      // Gate (D1): only when the "启动时自动检查更新" switch is on
      // (default on). checkAutoIfEnabled() reads the switch before
      // checkAuto() runs, so a switched-off check sends no request
      // and writes no throttle stamp. The manual check is never gated.
      final info = await updateService.checkAutoIfEnabled();
      if (info == null) return;
      AppLog.info('发现新版本 v${info.version} (build ${info.build})');
      final context = Get.context;
      if (context == null || !context.mounted) return;
      await showUpdateDialog(context, info, service: updateService);
    }),
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
        // The root content sits inside a RepaintBoundary so the
        // accent-colour dropper can capture the app frame (see
        // ScreenCapture); it also isolates the app's repaints from
        // the overlay above it.
        builder: (context, child) => Stack(
          children: [
            // Custom background (wallpaper / background colour) for
            // the WHOLE app (chen 2026-11-21: 壁纸要到全局）: the layer
            // sits behind the root Navigator, so every page shows it
            // once its scaffold / app bar goes transparent — the tab
            // roots used to host this layer themselves (removed from
            // AppShell; a second copy would double-paint the image).
            const AppearanceBackgroundLayer(),
            RepaintBoundary(
              key: ScreenCapture.boundaryKey,
              child: child ?? const SizedBox.shrink(),
            ),
            MiniPlayerOverlay(observer: musicRouteObserver),
          ],
        ),
      ),
    );
  }
}
