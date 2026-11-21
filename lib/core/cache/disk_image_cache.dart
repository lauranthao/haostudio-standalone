// Disk image cache (P1-P1).
//
// Music covers and video posters used to live ONLY in memory (80 / 100
// full-resolution entries): every app restart re-downloaded everything,
// and a scrolled-away poster was re-fetched as soon as its memory slot
// was evicted. There is no image disk-cache dependency in pubspec
// (no cached_network_image / flutter_cache_manager), so this is a
// small self-built file cache instead of a new dependency:
//
// - key: SHA-256 hex of the URL (crypto is already a direct dep);
// - location: <temp>/hao_image_cache/<sha256> (no extension — the
//   bytes are stored verbatim, content-type is irrelevant on read);
// - cap: 200 MB total; when exceeded, oldest files (by mtime) are
//   deleted until back under the cap. Pruning runs after a put, never
//   on the read path.
// - the URL semantics and Referer logic stay with the callers
//   (music_image.dart / referer_image.dart) — this class only stores
//   and returns bytes.
//
// All I/O is best-effort: any failure returns null / is swallowed, so
// a broken cache directory can never break image loading (the caller
// falls through to the network).

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class DiskImageCache {
  DiskImageCache._();

  static const String _kSubdir = 'hao_image_cache';

  /// Total-bytes cap (200 MB). Pruning deletes oldest-first.
  static const int kMaxTotalBytes = 200 * 1024 * 1024;

  static Directory? _dir;
  static Future<Directory?>? _dirFuture;

  /// Test hook: point the cache at a temp dir. Production never calls
  /// this — the directory is resolved lazily from path_provider.
  static void setDirectoryForTest(Directory dir) {
    _dir = dir;
    _dirFuture = Future.value(dir);
  }

  static void resetForTest() {
    _dir = null;
    _dirFuture = null;
  }

  static Future<Directory?> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    var fut = _dirFuture;
    fut ??= _dirFuture = _resolveDirectory();
    return fut;
  }

  static Future<Directory?> _resolveDirectory() async {
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory('${tmp.path}/$_kSubdir');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      return dir;
    } catch (_) {
      return null;
    }
  }

  static String _fileName(String url) =>
      sha256.convert(url.codeUnits).toString();

  /// Cached bytes for [url], or null on a miss / any I/O failure.
  static Future<List<int>?> get(String url) async {
    try {
      final dir = await _directory();
      if (dir == null) return null;
      final file = File('${dir.path}/${_fileName(url)}');
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Store [bytes] for [url]; fire-and-forget safe (never throws).
  static Future<void> put(String url, List<int> bytes) async {
    try {
      final dir = await _directory();
      if (dir == null) return;
      final file = File('${dir.path}/${_fileName(url)}');
      await file.writeAsBytes(bytes, flush: true);
      await _pruneIfNeeded(dir);
    } catch (_) {}
  }

  static Future<void> _pruneIfNeeded(Directory dir) async {
    try {
      final files = <File>[];
      var total = 0;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final len = await e.length();
        total += len;
        files.add(e);
      }
      if (total <= kMaxTotalBytes) return;
      // Oldest first (mtime); delete until back under the cap.
      final stats = <File, DateTime>{};
      for (final f in files) {
        stats[f] = await f.lastModified();
      }
      files.sort((a, b) => stats[a]!.compareTo(stats[b]!));
      for (final f in files) {
        if (total <= kMaxTotalBytes) break;
        final len = await f.length();
        await f.delete();
        total -= len;
      }
    } catch (_) {}
  }
}
