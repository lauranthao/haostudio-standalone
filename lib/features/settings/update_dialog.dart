// Online-update download dialog (fix 8, download flow).
//
// Shared by the manual check (Settings → 检查更新) and the automatic
// check in main.dart: when a newer version is found, show version +
// changelog with three actions — 下载 / 跳过此版本 / 稍后.
//
// 下载 opens info.ipaUrl in the external browser (Safari on iOS) via
// url_launcher LaunchMode.externalApplication. iOS cannot silently
// install an IPA from inside the app: the user downloads it in Safari
// and installs via LCSign / TrollStore. Nothing here claims otherwise.
//
// Theming: every colour comes from HaoTheme (all 4 themes x light/dark),
// never a hardcoded colour; no purple anywhere. Frosted-glass card in
// the same style as the audio-quality sheet.

import '../../core/theme/hao_radius.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../services/update_service.dart';

/// What the user chose in the update dialog.
enum UpdateDialogAction {
  /// Tapped 下载 (the IPA URL was opened in the external browser).
  download,

  /// Tapped 跳过此版本 (the version was recorded as skipped).
  skipped,

  /// Tapped 稍后 (dismissed, no state change).
  later,
}

/// Opens [url] in the external browser. Injectable so tests can record
/// the URL instead of hitting url_launcher / the network.
typedef UpdateUrlOpener = Future<bool> Function(Uri url);

Future<bool> _defaultUrlOpener(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// Show the new-version dialog. Returns the action the user took, or
/// null if the dialog was dismissed another way (e.g. back gesture).
Future<UpdateDialogAction?> showUpdateDialog(
  BuildContext context,
  UpdateInfo info, {
  required UpdateService service,
  UpdateUrlOpener urlOpener = _defaultUrlOpener,
}) {
  final theme = HaoTheme.of(context);
  return showDialog<UpdateDialogAction>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    // Material ancestor is required: the dialog route has none, and
    // without it Text falls back to the framework's debug style
    // (red monospace + double yellow underline). Transparent so the
    // glass card's own surface stays visible.
    builder: (ctx) => Material(
      type: MaterialType.transparency,
      child: Center(
        child: GlassCard(
          radius: 24,
          shadow: GlassShadow.panel,
          quality: GlassCardQuality.premium,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 480),
            child: SizedBox(
              width: MediaQuery.of(ctx).size.width * 0.82,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '发现新版本 v${info.version} (build ${info.build})',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Text(
                        (info.changelog == null || info.changelog!.isEmpty)
                            ? '新版本已发布，点击下载在浏览器中获取安装包。'
                            : info.changelog!,
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () async {
                      final uri = Uri.tryParse(info.ipaUrl);
                      if (uri == null) {
                        Get.snackbar('下载失败', '下载链接无效');
                        return;
                      }
                      final opened = await urlOpener(uri);
                      if (!ctx.mounted) return;
                      if (opened) {
                        Navigator.of(ctx).pop(UpdateDialogAction.download);
                      } else {
                        Get.snackbar('下载失败', '无法打开下载链接，请检查网络后重试');
                      }
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.accent,
                      // Theme-derived (light: white, dark: near-black) so
                      // the label stays readable on every accent, incl. gold.
                      foregroundColor: Theme.of(ctx).colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(HaoRadius.large),
                      ),
                    ),
                    child: const Text(
                      '下载',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          // Pop first so the dialog dismisses instantly;
                          // record the skip in the background. Awaiting
                          // the Hive disk write before popping held the
                          // dialog open on a slow write (and made the
                          // dismiss timing depend on disk I/O).
                          onPressed: () {
                            Navigator.of(ctx).pop(UpdateDialogAction.skipped);
                            unawaited(service.skipVersion(info.id));
                          },
                          child: Text(
                            '跳过此版本',
                            style: TextStyle(color: theme.textSecondary),
                          ),
                        ),
                      ),
                      Expanded(
                        child: TextButton(
                          onPressed: () =>
                              Navigator.of(ctx).pop(UpdateDialogAction.later),
                          child: Text(
                            '稍后',
                            style: TextStyle(color: theme.textSecondary),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
