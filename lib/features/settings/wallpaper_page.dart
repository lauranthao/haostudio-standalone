// Wallpaper manager (stage 2 item 5, Beans `ProfileView` wallpaper
// section, ProfileView.swift:1790-1872: "上传壁纸（可多张）" + a
// wallpaper grid where tapping applies, the in-use one shows a
// theme-coloured border + checkmark, and each cell has a delete
// button; "当前：默认背景 / 已应用壁纸" state line).
//
// Beans splits wallpapers by light/dark appearance; this port keeps
// one list for both modes (see AppearanceStore) — the grid is the
// same, the per-mode split is the documented deviation.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/theme/appearance_store.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';

class WallpaperPage extends StatelessWidget {
  const WallpaperPage({super.key});

  Future<void> _upload(BuildContext context) async {
    HaoHaptics.tap();
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选择壁纸图片',
      type: FileType.image,
    );
    if (picked.isEmpty) return; // user cancelled
    final path = picked.first.path;
    if (path == null) return;
    final controller = AppearanceController.ensure();
    final stored = await controller.addWallpaper(File(path));
    if (!context.mounted) return;
    if (stored == null) {
      Get.snackbar('导入失败', '只支持 jpg / png / webp / gif 图片');
      return;
    }
    await controller.applyWallpaper(stored);
    Get.snackbar('已应用', '壁纸已设为背景');
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final controller = AppearanceController.ensure();
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(
        title: const Text('壁纸'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '上传壁纸',
            onPressed: () => unawaited(_upload(context)),
          ),
        ],
      ),
      body: Obx(() {
        final paths = controller.wallpaperPaths;
        final current = controller.currentWallpaper.value;
        final enabled = controller.wallpaperEnabled.value;
        if (paths.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wallpaper, size: 48, color: theme.textMuted),
                const SizedBox(height: 12),
                Text(
                  '还没有壁纸，上传后会显示在这里',
                  style: TextStyle(color: theme.textSecondary, fontSize: 15),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => unawaited(_upload(context)),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('上传壁纸'),
                ),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                enabled && current.isNotEmpty ? '当前：已应用壁纸' : '当前：默认背景',
                style: TextStyle(color: theme.textSecondary, fontSize: 13),
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.66,
                ),
                itemCount: paths.length,
                itemBuilder: (ctx, i) {
                  final path = paths[i];
                  final inUse = enabled && path == current;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              HaoHaptics.tap();
                              unawaited(controller.applyWallpaper(path));
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: inUse
                                    ? Border.all(
                                        color: theme.accent,
                                        width: 2,
                                      )
                                    : null,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  inUse ? 10 : 12,
                                ),
                                child: Image.file(
                                  File(path),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Container(
                                    color: theme.accentSoft,
                                    child: Icon(
                                      Icons.broken_image,
                                      color: theme.textMuted,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (inUse)
                        Positioned(
                          left: 6,
                          top: 6,
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: theme.accent,
                            ),
                            child: Icon(
                              Icons.check,
                              size: 14,
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimary,
                            ),
                          ),
                        ),
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Material(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () {
                              HaoHaptics.tap();
                              unawaited(controller.deleteWallpaper(path));
                            },
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.close,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      }),
    );
  }
}
