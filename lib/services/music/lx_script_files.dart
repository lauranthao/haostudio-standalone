// Bundled LX script files — user-manageable copies in the app
// documents directory.
//
// First launch: each bundled asset script is copied to
// <documents>/lx_scripts/<id>.js (seed). The engine loads bundled
// scripts from these files, never from assets directly, so a deleted
// script stays deleted: deletion removes the file and records the id
// in the Hive deleted set ([LxScriptSourcesStore]), and seeding never
// re-creates a deleted id. Assets are only the first-install seed.
//
// Custom (user-added) scripts are NOT stored here — they already live
// in Hive ([LxScriptSourcesStore.customScripts]) with their code
// inline and are deleted through the same store.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Resolves the directory holding the user-manageable script copies.
/// Injectable so tests can point it at a temp dir.
typedef LxScriptsDirResolver = Future<Directory> Function();

class LxScriptFileStore {
  LxScriptFileStore({LxScriptsDirResolver? dirResolver})
      : _dirResolver = dirResolver ?? _defaultDirResolver;

  static Future<Directory> _defaultDirResolver() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/lx_scripts');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  final LxScriptsDirResolver _dirResolver;

  Future<File> _fileFor(String id) async {
    final dir = await _dirResolver();
    return File('${dir.path}/$id.js');
  }

  /// Copy the asset to the file store when the file is missing.
  /// No-op when the file already exists (a user-edited copy is never
  /// overwritten). Throws when the asset cannot be read — the caller
  /// falls back to loading from the asset directly.
  Future<void> seedIfMissing({
    required String id,
    required String assetPath,
    required Future<String> Function(String) assetLoader,
  }) async {
    final file = await _fileFor(id);
    if (await file.exists()) return;
    final code = await assetLoader(assetPath);
    await file.writeAsString(code, flush: true);
  }

  /// The stored copy, or null when there is none (never seeded, or
  /// deleted). Never throws.
  Future<String?> read(String id) async {
    try {
      final file = await _fileFor(id);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// Delete the stored copy. No-op when there is none. Never throws.
  Future<void> delete(String id) async {
    try {
      final file = await _fileFor(id);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
