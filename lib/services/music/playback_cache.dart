// Playback cache (build 29, music) — 只自动缓存已播内容、弱网续播.
//
// Streaming audio is cached progressively through just_audio's
// LockCachingAudioSource (see AvMusicPlayer): bytes are written to
// disk AS they are played, so the cache only ever holds what was
// actually heard — there is no whole-song pre-download and no
// "offline download" promise (play URLs expire, chen 2026-11-22:
// 整首下载离线不做). A cached prefix replays from disk while the
// rest resumes over the network, so a weak-network replay does not
// re-buffer from zero.
//
// Cap 500 MB, oldest-first eviction. The toggle + size + clear live
// on the Downloads page; the player enables the cache by default.

import 'dart:io';

import '../../core/storage/hive_store.dart';
import '../../core/storage/local_paths.dart';

class PlaybackCache {
  PlaybackCache._();

  static const String subdir = 'music_playback_cache';

  /// Cache cap: 500 MB.
  static const int maxBytes = 500 * 1024 * 1024;

  /// Hive key for the on/off toggle (literal — HiveKeys lives in
  /// core storage; see MultiQueueStore's header for why literals
  /// are used here).
  static const String hiveKeyEnabled = 'hao_music_playback_cache_enabled';

  /// Test-only directory override (production uses Documents).
  static Directory? directoryOverrideForTest;

  static bool get enabled {
    try {
      return HiveStore.getBool(hiveKeyEnabled, true);
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool value) async {
    try {
      await HiveStore.put(hiveKeyEnabled, value);
    } catch (_) {}
  }

  static Future<Directory> directory() async {
    final override = directoryOverrideForTest;
    if (override != null) {
      if (!await override.exists()) {
        await override.create(recursive: true);
      }
      return override;
    }
    final basePath = await LocalPaths.ensureDocumentsPath();
    final dir = Directory('$basePath/$subdir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// FNV-1a (32-bit) hex of the URL — stable across launches, so a
  /// replay of the same URL finds the same file. URLs carry
  /// per-resolve tokens, so a re-resolved song usually gets a NEW
  /// file: the old one is just evicted by age under the cap.
  static String fileNameForUrl(String url) {
    var h = 2166136261;
    for (var i = 0; i < url.length; i++) {
      h ^= url.codeUnitAt(i);
      h = ((h & 0xFFFFFFFF) * 16777619) & 0xFFFFFFFF;
    }
    return '${h.toRadixString(16).padLeft(8, '0')}.cache';
  }

  static Future<File> fileForUrl(String url) async {
    final dir = await directory();
    return File('${dir.path}/${fileNameForUrl(url)}');
  }

  /// Total cached bytes (0 when the dir does not exist yet).
  static Future<int> sizeBytes() async {
    try {
      final dir = await directory();
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list()) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Delete oldest files (by modified time) until the total is at
  /// most [capBytes]. Returns the bytes freed.
  static Future<int> prune({int capBytes = maxBytes}) async {
    try {
      final dir = await directory();
      if (!await dir.exists()) return 0;
      final files = <File>[];
      var total = 0;
      await for (final e in dir.list()) {
        if (e is File) {
          files.add(e);
          total += await e.length();
        }
      }
      if (total <= capBytes) return 0;
      files.sort(
        (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
      );
      var freed = 0;
      for (final f in files) {
        if (total <= capBytes) break;
        final size = await f.length();
        try {
          await f.delete();
          total -= size;
          freed += size;
        } catch (_) {}
      }
      return freed;
    } catch (_) {
      return 0;
    }
  }

  /// Delete every cached file. Returns the bytes freed.
  static Future<int> clear() async {
    try {
      final dir = await directory();
      if (!await dir.exists()) return 0;
      var freed = 0;
      await for (final e in dir.list()) {
        if (e is File) {
          freed += await e.length();
          try {
            await e.delete();
          } catch (_) {}
        }
      }
      return freed;
    } catch (_) {
      return 0;
    }
  }
}
