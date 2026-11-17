// Appearance: custom wallpaper + background colour (stage 2 items 5-6).
//
// Beans `ThemeStore` (Theme.swift:318-520) splits everything by
// light/dark (backgroundHexLight/Dark, backgroundImagePathLight/Dark,
// wallpaperPaths list + backup restore, backgroundSyncAll). This port
// keeps ONE wallpaper / ONE background colour for both modes — the
// task only requires "明暗模式都要能看", and the text colours already
// follow the theme per mode, so a single background under a
// theme-coloured scrim (see [AppearanceBackgroundLayer]) stays
// readable in both modes without doubling the UI and the test
// surface. The priority is Beans' own: wallpaper beats background
// colour beats theme default (Beans `GlassBackdrop(customColor:)` /
// `SearchView` background comment).
//
// Files live in app documents (`wallpapers/`); the Hive index is the
// source of truth for the list (same pattern as the download index).
// A list entry whose file is gone is pruned on read, never shown as
// a phantom tile.
//
// Every Hive read is guarded (try/catch -> default) so a call before
// Hive is initialised — e.g. a tab page building in a test — never
// throws.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/storage/hive_store.dart';
import 'hao_themes.dart';

/// Image extensions accepted as wallpaper.
const Set<String> kWallpaperExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
};

class AppearanceStore {
  AppearanceStore({Directory? documentsDir})
      : _documentsOverride = documentsDir;

  final Directory? _documentsOverride;

  Future<Directory> get _wallpaperDir async {
    final base = _documentsOverride ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/wallpapers');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  List<String> _readPaths() {
    try {
      final raw = HiveStore.box.get(HiveKeys.wallpaperPaths) as String?;
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _writePaths(List<String> paths) async {
    try {
      await HiveStore.put(HiveKeys.wallpaperPaths, jsonEncode(paths));
    } catch (_) {}
  }

  // ---- wallpaper ----

  bool get wallpaperEnabled {
    try {
      return HiveStore.getBool(HiveKeys.wallpaperEnabled, false);
    } catch (_) {
      return false;
    }
  }

  Future<void> setWallpaperEnabled(bool value) async {
    try {
      await HiveStore.put(HiveKeys.wallpaperEnabled, value);
    } catch (_) {}
  }

  /// Stored wallpaper list, pruned to files that still exist.
  List<String> get wallpaperPaths {
    final paths = _readPaths();
    final kept = paths.where((p) => File(p).existsSync()).toList();
    if (kept.length != paths.length) unawaited(_writePaths(kept));
    return kept;
  }

  String get currentWallpaper {
    try {
      return HiveStore.getString(HiveKeys.wallpaperCurrent, '');
    } catch (_) {
      return '';
    }
  }

  /// Copy [source] into the app wallpapers directory and add it to
  /// the list. Returns the stored path, or null for a non-image file.
  Future<String?> addWallpaper(File source) async {
    final ext = source.path.split('.').last.toLowerCase();
    if (!kWallpaperExtensions.contains(ext)) return null;
    if (!await source.exists()) return null;
    final dir = await _wallpaperDir;
    final baseName = source.path.split('/').last;
    final safeName = baseName.replaceAll(RegExp(r'''[/\\?%*:|"<>]'''), '_');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final target = File('${dir.path}/${stamp}_$safeName');
    await source.copy(target.path);
    final paths = _readPaths()..add(target.path);
    await _writePaths(paths);
    return target.path;
  }

  /// Apply [path] as the current wallpaper (and turn wallpapers on).
  /// No-op when the path is not in the list.
  Future<void> applyWallpaper(String path) async {
    if (!_readPaths().contains(path)) return;
    try {
      await HiveStore.put(HiveKeys.wallpaperCurrent, path);
      await HiveStore.put(HiveKeys.wallpaperEnabled, true);
    } catch (_) {}
  }

  /// Delete [path] from disk and from the list; if it was the
  /// current wallpaper, the current selection is cleared (the
  /// background falls back to colour / theme default — never a
  /// dangling path).
  Future<void> deleteWallpaper(String path) async {
    final paths = _readPaths()..remove(path);
    await _writePaths(paths);
    try {
      await File(path).delete();
    } catch (_) {}
    if (currentWallpaper == path) {
      try {
        await HiveStore.put(HiveKeys.wallpaperCurrent, '');
      } catch (_) {}
    }
  }

  // ---- background colour ----

  bool get backgroundEnabled {
    try {
      return HiveStore.getBool(HiveKeys.bgColorEnabled, false);
    } catch (_) {
      return false;
    }
  }

  Future<void> setBackgroundEnabled(bool value) async {
    try {
      await HiveStore.put(HiveKeys.bgColorEnabled, value);
    } catch (_) {}
  }

  /// Stored '#RRGGBB' hex ('' = none).
  String get backgroundHex {
    try {
      return HiveStore.getString(HiveKeys.bgColorHex, '');
    } catch (_) {
      return '';
    }
  }

  /// '#RRGGBB' -> [Color], or null for anything else. Pure, tested.
  static Color? parseHex(String hex) {
    final m = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(hex.trim());
    if (m == null) return null;
    final v = int.parse(m.group(1)!, radix: 16);
    return Color(0xFF000000 | v);
  }

  /// Store a background colour (validated) and turn it on. Returns
  /// false and writes nothing for an invalid hex.
  Future<bool> setBackgroundColor(String hex) async {
    if (parseHex(hex) == null) return false;
    try {
      await HiveStore.put(HiveKeys.bgColorHex, hex.toUpperCase());
      await HiveStore.put(HiveKeys.bgColorEnabled, true);
    } catch (_) {
      return false;
    }
    return true;
  }

  /// Restore the theme default background (clears the colour and
  /// turns the switch off).
  Future<void> clearBackgroundColor() async {
    try {
      await HiveStore.put(HiveKeys.bgColorHex, '');
      await HiveStore.put(HiveKeys.bgColorEnabled, false);
    } catch (_) {}
  }

  // ---- effective background ----

  /// Wallpaper wins when enabled, selected and the file exists.
  bool get hasActiveWallpaper {
    if (!wallpaperEnabled) return false;
    final current = currentWallpaper;
    return current.isNotEmpty && File(current).existsSync();
  }

  bool get hasActiveBackgroundColor =>
      backgroundEnabled && parseHex(backgroundHex) != null;

  /// True when any custom background is active (wallpaper or colour).
  /// Tab-root Scaffolds go transparent exactly then, so the
  /// [AppearanceBackgroundLayer] in the AppShell shows through.
  bool get backgroundActive => hasActiveWallpaper || hasActiveBackgroundColor;
}

/// Reactive wrapper around [AppearanceStore] for the UI. Registered
/// in main.dart (Get.put) and read by the AppShell background layer,
/// the tab-root Scaffolds and the settings appearance section.
class AppearanceController extends GetxController {
  AppearanceController({AppearanceStore? store})
      : _store = store ?? AppearanceStore();

  final AppearanceStore _store;

  final RxBool wallpaperEnabled = false.obs;
  final RxList<String> wallpaperPaths = <String>[].obs;
  final RxString currentWallpaper = ''.obs;
  final RxBool backgroundEnabled = false.obs;
  final RxString backgroundHex = ''.obs;

  /// True when any custom background is active.
  final RxBool backgroundActive = false.obs;

  static AppearanceController ensure() {
    if (Get.isRegistered<AppearanceController>()) {
      return Get.find<AppearanceController>();
    }
    return Get.put(AppearanceController());
  }

  /// Read the store into the Rx values (call once at startup and
  /// after every mutation below).
  Future<void> load() async {
    wallpaperEnabled.value = _store.wallpaperEnabled;
    wallpaperPaths.assignAll(_store.wallpaperPaths);
    currentWallpaper.value = _store.currentWallpaper;
    backgroundEnabled.value = _store.backgroundEnabled;
    backgroundHex.value = _store.backgroundHex;
    backgroundActive.value = _store.backgroundActive;
  }

  Future<String?> addWallpaper(File source) async {
    final path = await _store.addWallpaper(source);
    await load();
    return path;
  }

  Future<void> applyWallpaper(String path) async {
    await _store.applyWallpaper(path);
    await load();
  }

  Future<void> deleteWallpaper(String path) async {
    await _store.deleteWallpaper(path);
    await load();
  }

  Future<void> setWallpaperEnabled(bool value) async {
    await _store.setWallpaperEnabled(value);
    await load();
  }

  Future<bool> setBackgroundColor(String hex) async {
    final ok = await _store.setBackgroundColor(hex);
    await load();
    return ok;
  }

  Future<void> setBackgroundEnabled(bool value) async {
    await _store.setBackgroundEnabled(value);
    await load();
  }

  Future<void> clearBackgroundColor() async {
    await _store.clearBackgroundColor();
    await load();
  }
}

/// Background layer for the AppShell (stage 2 items 5-6): paints
/// behind the tab pages — wallpaper image (cover) or background
/// colour, nothing when no custom background is active. Tab-root
/// Scaffolds are transparent exactly when this layer paints, so the
/// layer is the background and the theme still owns every text
/// colour (a dark wallpaper does not force light text and vice versa
/// — readability comes from the scrim, not from re-tinting text).
///
/// Scrim: the theme scaffold colour at 0.55 alpha over the wallpaper
/// (light mode: near-white wash; dark mode: black wash). Glass cards
/// add their own blur on top, so text stays readable on busy images
/// in both modes without hiding the wallpaper.
class AppearanceBackgroundLayer extends StatelessWidget {
  const AppearanceBackgroundLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppearanceController.ensure();
    return Obx(() {
      if (!controller.backgroundActive.value) {
        return const SizedBox.shrink();
      }
      if (controller.wallpaperEnabled.value &&
          controller.currentWallpaper.value.isNotEmpty) {
        final file = File(controller.currentWallpaper.value);
        if (file.existsSync()) {
          final scrim = Theme.of(
            context,
          ).scaffoldBackgroundColor.withValues(alpha: 0.55);
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.file(file, fit: BoxFit.cover),
              Container(color: scrim),
            ],
          );
        }
      }
      final color = AppearanceStore.parseHex(controller.backgroundHex.value);
      if (color != null) return Container(color: color);
      return const SizedBox.shrink();
    });
  }
}

/// Scaffold background for a tab-root page: transparent while a
/// custom background is active (the AppShell layer shows through),
/// otherwise the theme scaffold colour. Call sites wrap their
/// Scaffold in Obx so the switch takes effect immediately.
Color tabScaffoldBackground(BuildContext context) {
  final active = AppearanceController.ensure().backgroundActive.value;
  return active
      ? Colors.transparent
      : HaoTheme.of(context).scaffoldBackground;
}
