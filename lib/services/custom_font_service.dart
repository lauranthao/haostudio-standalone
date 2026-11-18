// Custom font (stage 2 item 7, Beans `FontManager`,
// FontManager.swift:5-160).
//
// Beans copies the picked ttf/otf/ttc into Documents/Fonts (clearing
// the old font first), registers it with CoreText, stores the
// PostScript name, and re-registers it on every launch
// (`reinstallIfNeeded`). The Flutter equivalent of CoreText
// registration is [FontLoader]: the file bytes are loaded under a
// fixed family name, and `ThemeData(fontFamily:)` applies it —
// ThemeData merges the family into the default text theme, and app
// TextStyles (which set size/weight/colour but no family) inherit it
// through DefaultTextStyle, so the whole app follows the font.
//
// Differences from Beans, with reasons:
// - One global font only (Beans also has a separate greeting font —
//   our greeting is plain themed text, no separate greeting-font
//   slot exists to fill).
// - Family name is the fixed 'HaoCustomFont', not the font's internal
//   PostScript name: FontLoader registers bytes under an arbitrary
//   family name, and the internal name is not needed to use it. The
//   original file name is stored separately for display.
// - .ttc (a collection of faces): FontLoader loads the file as one
//   font; on engines that reject collections the install fails
//   cleanly (null, nothing stored) instead of half-applying.

import 'dart:io';

import 'package:flutter/services.dart';

import '../core/storage/hive_store.dart';
import '../core/storage/local_paths.dart';

class CustomFontService {
  CustomFontService({
    Directory? documentsDir,
    Future<void> Function(String family, Uint8List bytes)? register,
  }) : _documentsOverride = documentsDir,
       _register = register ?? _registerWithFontLoader;

  /// Family name the installed font is registered under.
  static const String family = 'HaoCustomFont';

  static const Set<String> kFontExtensions = {'ttf', 'otf', 'ttc'};

  /// Subdirectory under Documents holding the installed font file.
  static const String kCustomFontSubdir = 'fonts';

  final Directory? _documentsOverride;
  final Future<void> Function(String family, Uint8List bytes) _register;

  static Future<void> _registerWithFontLoader(
    String family,
    Uint8List bytes,
  ) async {
    final loader = FontLoader(family);
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }

  Future<Directory> get _fontsDir async {
    final basePath = _documentsOverride == null
        ? await LocalPaths.ensureDocumentsPath()
        : _documentsOverride.path;
    final dir = Directory('$basePath/$kCustomFontSubdir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Display name of the installed font file ('' = none installed).
  String get currentName {
    try {
      return HiveStore.getString(HiveKeys.customFontName, '');
    } catch (_) {
      return '';
    }
  }

  bool get hasCustomFont {
    try {
      return HiveStore.getString(HiveKeys.customFontFamily, '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Install [source] as the global font. Returns the family name on
  /// success, null when the file is not a font or registration failed.
  /// The old font is only cleared AFTER the new one registers: a
  /// failed install leaves the previous font exactly as it was
  /// (files + Hive keys untouched).
  Future<String?> install(File source) async {
    final ext = source.path.split('.').last.toLowerCase();
    if (!kFontExtensions.contains(ext)) return null;
    if (!await source.exists()) return null;
    final dir = await _fontsDir;
    final baseName = source.path.split('/').last;
    final safeName = baseName.replaceAll(RegExp(r'''[/\\?%*:|"<>]'''), '_');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final target = File('${dir.path}/${stamp}_$safeName');
    await source.copy(target.path);
    final bytes = await target.readAsBytes();
    try {
      await _register(family, bytes);
    } catch (_) {
      try {
        await target.delete();
      } catch (_) {}
      return null;
    }
    // New font registered — now clear the old files (Beans
    // `FontManager.install` clears first; clearing here instead keeps
    // a failed install from deleting the working font).
    try {
      final entries = await dir.list().toList();
      for (final e in entries) {
        if (e.path != target.path) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    try {
      await HiveStore.put(HiveKeys.customFontFamily, family);
      await HiveStore.put(HiveKeys.customFontName, baseName);
      // Relative name only (`fonts/<file>`): an absolute path dies
      // with the old container UUID on reinstall (same bug class as
      // local files / downloads / wallpapers, chen 2026-11-18).
      await HiveStore.put(
        HiveKeys.customFontPath,
        LocalPaths.storedName(kCustomFontSubdir, target.path.split('/').last),
      );
    } catch (_) {
      return null;
    }
    return family;
  }

  /// Re-register the stored font (call once at startup, before
  /// runApp — Beans `reinstallIfNeeded`). Returns false when nothing
  /// is stored or the file is gone. An old absolute stored path is
  /// resolved through the current container and repaired to the
  /// relative form in place.
  Future<bool> loadPersisted() async {
    String stored = '';
    String storedFamily = '';
    try {
      storedFamily = HiveStore.getString(HiveKeys.customFontFamily, '');
      stored = HiveStore.getString(HiveKeys.customFontPath, '');
    } catch (_) {
      return false;
    }
    if (storedFamily.isEmpty || stored.isEmpty) return false;
    final resolved = await LocalPaths.resolve(
      stored,
      kCustomFontSubdir,
      directoryOverride: _documentsOverride == null
          ? null
          : Directory('${_documentsOverride.path}/$kCustomFontSubdir'),
    );
    if (resolved == null) return false;
    final relative = LocalPaths.storedName(
      kCustomFontSubdir,
      LocalPaths.baseName(stored),
    );
    if (relative != stored) {
      try {
        await HiveStore.put(HiveKeys.customFontPath, relative);
      } catch (_) {}
    }
    final file = File(resolved);
    if (!await file.exists()) return false;
    try {
      await _register(storedFamily, await file.readAsBytes());
    } catch (_) {
      return false;
    }
    return true;
  }

  /// Remove the installed font files (keeps the Hive keys — use
  /// [clear] to reset everything).
  Future<void> clearFilesOnly() async {
    final dir = await _fontsDir;
    try {
      final entries = await dir.list().toList();
      for (final e in entries) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Restore the system default font (delete files + clear keys).
  Future<void> clear() async {
    await clearFilesOnly();
    try {
      await HiveStore.put(HiveKeys.customFontFamily, '');
      await HiveStore.put(HiveKeys.customFontName, '');
      await HiveStore.put(HiveKeys.customFontPath, '');
    } catch (_) {}
  }
}
