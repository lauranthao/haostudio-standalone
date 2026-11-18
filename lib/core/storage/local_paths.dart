// Relative-path storage for files under the app Documents directory.
//
// iOS changes the app container UUID on every (re)install, so an
// absolute path stored in Hive dies with the old container — and the
// old code then pruned the index entry itself (local files, downloads
// and wallpapers were all lost on the 1.1.0 -> 1.1.1 upgrade, chen
// 2026-11-18). The index now stores only a relative name
// (`<subdir>/<file>`); the absolute path is rebuilt from the CURRENT
// Documents directory on every read.
//
// Resolution order for a stored value:
//   1. the stored value as-is, when it is absolute and the file still
//      exists (same container — covers files written before the
//      migration and every test that uses a real temp file);
//   2. `<current Documents>/<subdir>/<basename>` (the container
//      moved, the file moved with it);
//   3. null — the file is gone in every place we know.
//
// A stored value that is already relative (`local_music/x.mp3`, or a
// bare `x.mp3`) goes straight to step 2. Never hand-build a path from
// a stored value anywhere else in lib — always go through here.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class LocalPaths {
  LocalPaths._();

  static String? _documentsPath;

  /// Resolve + cache the Documents directory. Call once at startup
  /// (main.dart, right after HiveStore.init) so the synchronous
  /// resolvers below have a warm cache on the playback hot path.
  static Future<String> ensureDocumentsPath() async {
    final cached = _documentsPath;
    if (cached != null) return cached;
    final dir = await getApplicationDocumentsDirectory();
    _documentsPath = dir.path;
    return dir.path;
  }

  /// Cached Documents path, or null before [ensureDocumentsPath].
  static String? get documentsPathSync => _documentsPath;

  /// Test hook: point the cache at a temp dir. Tests that construct
  /// a store with a directory override do not need this — the
  /// override is used directly.
  static void setDocumentsPathForTest(String path) {
    _documentsPath = path;
  }

  static void resetForTest() {
    _documentsPath = null;
  }

  /// File name (last segment) of a stored value, absolute or relative.
  static String baseName(String stored) {
    if (stored.isEmpty) return '';
    final parts = stored.split('/');
    return parts.isEmpty ? stored : parts.last;
  }

  /// Stored form for a file under [subdir]: `subdir/<fileName>`.
  static String storedName(String subdir, String fileName) =>
      '$subdir/$fileName';

  /// Resolve [stored] to an existing absolute path, or null.
  /// [directoryOverride] is the SUBDIR directory itself (the stores
  /// that take a directory override pass theirs); without it, the
  /// cached Documents directory + [subdir] is used. Purely
  /// synchronous so [MusicDownloadService.localPathFor] can stay on
  /// the playback hot path; returns null (not an exception) when the
  /// cache is cold and no override is given.
  static String? resolveSync(
    String stored,
    String subdir, {
    Directory? directoryOverride,
  }) {
    if (stored.isEmpty) return null;
    // Old absolute value, same container: still valid as-is.
    if (stored.startsWith('/') && File(stored).existsSync()) {
      return stored;
    }
    final name = baseName(stored);
    if (name.isEmpty) return null;
    final Directory? dir = directoryOverride ??
        (_documentsPath == null
            ? null
            : Directory('$_documentsPath/$subdir'));
    if (dir == null) return null;
    final candidate = File('${dir.path}/$name');
    return candidate.existsSync() ? candidate.path : null;
  }

  /// Async version: warms the Documents cache first when no override
  /// is given, then resolves as [resolveSync].
  static Future<String?> resolve(
    String stored,
    String subdir, {
    Directory? directoryOverride,
  }) async {
    final sync = resolveSync(
      stored,
      subdir,
      directoryOverride: directoryOverride,
    );
    if (sync != null) return sync;
    if (directoryOverride != null) return null;
    await ensureDocumentsPath();
    return resolveSync(stored, subdir);
  }
}
