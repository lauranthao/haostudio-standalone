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
// Stored values are relative names (`wallpapers/<file>`); old
// absolute entries are repaired on read and the directory is
// rescanned before anything is pruned, so a container move never
// loses a wallpaper (see [LocalPaths]).
//
// Every Hive read is guarded (try/catch -> default) so a call before
// Hive is initialised — e.g. a tab page building in a test — never
// throws.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/storage/hive_store.dart';
import '../../core/storage/local_paths.dart';
import 'hao_themes.dart';

/// Image extensions accepted as wallpaper.
const Set<String> kWallpaperExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
};

/// Subdirectory under Documents holding the wallpaper copies.
const String kWallpaperSubdir = 'wallpapers';

class AppearanceStore {
  AppearanceStore({Directory? documentsDir})
      : _documentsOverride = documentsDir;

  final Directory? _documentsOverride;

  Future<Directory> get _wallpaperDir async {
    final basePath = _documentsOverride == null
        ? await LocalPaths.ensureDocumentsPath()
        : _documentsOverride.path;
    final dir = Directory('$basePath/$kWallpaperSubdir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// The wallpapers directory for synchronous reads, or null when
  /// neither an override nor a warmed Documents cache is available.
  Directory? get _wallpaperDirSync {
    final override = _documentsOverride;
    if (override != null) {
      return Directory('${override.path}/$kWallpaperSubdir');
    }
    final docs = LocalPaths.documentsPathSync;
    if (docs == null) return null;
    return Directory('$docs/$kWallpaperSubdir');
  }

  /// Stored values are RELATIVE names (`wallpapers/<file>`), never
  /// absolute paths: iOS changes the app container UUID on every
  /// (re)install, so an absolute path stored in Hive dies with the
  /// old container — and the old code then pruned the list itself
  /// (same bug class as local files / downloads, chen 2026-11-18).
  /// The absolute path is rebuilt from the CURRENT Documents
  /// directory on every read; old absolute entries are repaired in
  /// place, and the directory is rescanned before anything is pruned.
  ///
  /// The public getters below return RESOLVED absolute paths, so the
  /// UI (thumbnails, background layer) works unchanged; only the
  /// Hive values are relative.
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

  /// Normalize any incoming path (absolute or relative) to the
  /// stored form `wallpapers/<basename>`.
  String _toStored(String path) =>
      LocalPaths.storedName(kWallpaperSubdir, LocalPaths.baseName(path));

  /// Resolve a stored value to an existing absolute path, or null.
  String? _resolveStored(String stored) {
    return LocalPaths.resolveSync(
      stored,
      kWallpaperSubdir,
      directoryOverride: _wallpaperDirSync,
    );
  }

  /// Repair the stored list (old absolute values -> relative form),
  /// rescan the directory for images with no index entry, and drop
  /// entries whose file is missing in all three places (stored path,
  /// current-dir basename, directory rescan). Returns the stored
  /// (relative) list; writes back when anything changed.
  List<String> _repairAndRescan() {
    final stored = _readPaths();
    // No directory to resolve against (cold Documents cache, no
    // override): do NOT prune — relative entries cannot be verified
    // yet. In production main() warms the cache before runApp, so
    // this only triggers in tests that read before any write.
    if (_wallpaperDirSync == null) return stored;
    final keptStored = <String>[];
    final seenNames = <String>{};
    var changed = false;
    for (final p in stored) {
      if (p.isEmpty) continue;
      final resolved = _resolveStored(p);
      if (resolved == null) continue;
      final rel = _toStored(p);
      if (rel != p) changed = true;
      keptStored.add(rel);
      seenNames.add(LocalPaths.baseName(p));
    }
    final dir = _wallpaperDirSync!;
    try {
      final names = <String>[];
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        final name = e.path.split('/').last;
        if (name.startsWith('.')) continue;
        final ext = name.contains('.')
            ? name.split('.').last.toLowerCase()
            : '';
        if (!kWallpaperExtensions.contains(ext)) continue;
        if (seenNames.contains(name)) continue;
        names.add(name);
      }
      names.sort();
      for (final name in names) {
        keptStored.add(_toStored(name));
        seenNames.add(name);
        changed = true;
      }
    } catch (_) {
      // A directory that cannot be listed rescans to nothing.
    }
    if (changed || keptStored.length != stored.length) {
      unawaited(_writePaths(keptStored));
    }
    return keptStored;
  }

  /// Stored wallpaper list as RESOLVED absolute paths (the UI
  /// consumes these directly), repaired + rescanned + pruned to
  /// files that still exist.
  List<String> get wallpaperPaths {
    final resolved = <String>[];
    for (final stored in _repairAndRescan()) {
      final abs = _resolveStored(stored);
      if (abs != null) resolved.add(abs);
    }
    return resolved;
  }

  /// Current wallpaper as a RESOLVED absolute path ('' = none).
  /// An old absolute stored value is repaired to the relative form.
  String get currentWallpaper {
    try {
      final stored = HiveStore.getString(HiveKeys.wallpaperCurrent, '');
      if (stored.isEmpty) return '';
      final resolved = _resolveStored(stored);
      if (resolved == null) return '';
      final rel = _toStored(stored);
      if (rel != stored) {
        unawaited(HiveStore.put(HiveKeys.wallpaperCurrent, rel));
      }
      return resolved;
    } catch (_) {
      return '';
    }
  }

  /// Copy [source] into the app wallpapers directory and add it to
  /// the list. Returns the resolved absolute path, or null for a
  /// non-image file. The stored index value is the relative name.
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
    final paths = _readPaths()..add(_toStored(target.path));
    await _writePaths(paths);
    return target.path;
  }

  /// Apply [path] as the current wallpaper (and turn wallpapers on).
  /// No-op when the path is not in the list. [path] may be the
  /// resolved absolute path (as the UI passes it) or a stored
  /// relative name — it is normalized before the membership check.
  Future<void> applyWallpaper(String path) async {
    final stored = _toStored(path);
    if (!_repairAndRescan().contains(stored)) return;
    try {
      await HiveStore.put(HiveKeys.wallpaperCurrent, stored);
      await HiveStore.put(HiveKeys.wallpaperEnabled, true);
    } catch (_) {}
  }

  /// One-time v1.1.5 migration (chen 2026-11-19: the page must read
  /// as one connected surface, NetEase-style — the wallpaper photo is
  /// what broke the page into separate slabs). Turns a stored
  /// wallpaperEnabled=true off ONCE; the wallpaper files + current
  /// selection are kept, so the user can turn it back on in Settings
  /// and get their wallpaper back. Guarded by a Hive flag, so a
  /// later user choice is never overridden. Safe to call on every
  /// load (no-op after the first run).
  Future<void> migrateWallpaperOffOnce() async {
    try {
      if (HiveStore.getBool(HiveKeys.wallpaperV115Migration, false)) {
        return;
      }
      await HiveStore.put(HiveKeys.wallpaperV115Migration, true);
      if (wallpaperEnabled) {
        await HiveStore.put(HiveKeys.wallpaperEnabled, false);
      }
    } catch (_) {}
  }

  /// Delete [path] from disk and from the list; if it was the
  /// current wallpaper, the current selection is cleared (the
  /// background falls back to colour / theme default — never a
  /// dangling path).
  Future<void> deleteWallpaper(String path) async {
    final stored = _toStored(path);
    final paths = _repairAndRescan()..remove(stored);
    await _writePaths(paths);
    try {
      final resolved = _resolveStored(stored);
      if (resolved != null) await File(resolved).delete();
    } catch (_) {}
    try {
      final currentStored =
          HiveStore.getString(HiveKeys.wallpaperCurrent, '');
      if (currentStored.isNotEmpty && _toStored(currentStored) == stored) {
        await HiveStore.put(HiveKeys.wallpaperCurrent, '');
      }
    } catch (_) {}
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

  /// One-time v1.1.5 wallpaper migration (see
  /// [AppearanceStore.migrateWallpaperOffOnce]). Called once at
  /// startup from main(), before [load] — never from [load] itself,
  /// so load() keeps its contract (pure reflection of the store).
  Future<void> migrateWallpaperOffOnce() =>
      _store.migrateWallpaperOffOnce();

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

/// Background layer for the WHOLE app (chen 2026-11-21: 壁纸要到全局）:
/// hosted once behind the root Navigator (main.dart), it paints
/// behind every page — wallpaper image (cover) or background colour,
/// nothing when no custom background is active. Page Scaffolds and
/// app bars are transparent exactly when this layer paints, so the
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
/// custom background is active (the app-root layer shows through),
/// otherwise the theme scaffold colour. Call sites wrap their
/// Scaffold in Obx so the switch takes effect immediately.
Color tabScaffoldBackground(BuildContext context) {
  final active = AppearanceController.ensure().backgroundActive.value;
  return active
      ? Colors.transparent
      : HaoTheme.of(context).scaffoldBackground;
}
