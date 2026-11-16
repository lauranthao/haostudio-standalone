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

import 'core/storage/hive_store.dart';
import 'core/theme/theme_controller.dart';
import 'features/live/live_breadcrumb.dart';
import 'features/settings/update_dialog.dart';
import 'services/update_service.dart';
import 'widgets/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Crash breadcrumb: read before anything else (fix 1).
  await HiveStore.init();
  final lastCrashStage = LiveBreadcrumb.current;
  if (lastCrashStage.isNotEmpty) {
    debugPrint('[HAo] last live stage before crash/close: $lastCrashStage');
  }

  final themeController = Get.put(ThemeController());
  themeController.loadFromBox(HiveStore.box);

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

  runApp(const HAoApp());
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
        home: const AppShell(),
      ),
    );
  }
}
