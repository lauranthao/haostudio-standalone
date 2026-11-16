// Cache settings — size + real clear, per section.
//
// CACHE (safe to clear) vs DATA (never touched here):
// - 视频首页缓存 `hao_video_home` — home rows JSON, re-fetched on next
//   visit.
// - 豆瓣缓存 `hao_douban_detail` + `hao_douban_idmap` — metadata caches,
//   re-fetched on demand (200-entry cap, permanent until cleared).
// - 每日推荐缓存 `hao_daily_YYYY-MM-DD` — one key per day, re-fetched.
// - 图片缓存 — Flutter ImageCache (network posters/covers), in-memory
//   only; cleared via ImageCache.clear().
//
// NOT cache and never cleared here: watch history, favourites, resume
// positions, playlists, listen records, search history — that is the
// user's data; backup/restore owns it, not cache clearing.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../../core/storage/hive_store.dart';

enum CacheSection { videoHome, douban, daily, images }

extension CacheSectionX on CacheSection {
  String get title {
    switch (this) {
      case CacheSection.videoHome:
        return '视频首页缓存';
      case CacheSection.douban:
        return '豆瓣缓存';
      case CacheSection.daily:
        return '每日推荐缓存';
      case CacheSection.images:
        return '图片缓存';
    }
  }

  String get subtitle {
    switch (this) {
      case CacheSection.videoHome:
        return '视频首页列表，下次打开时重新加载';
      case CacheSection.douban:
        return '影片评分、演员与简介，下次打开时重新获取';
      case CacheSection.daily:
        return '每日推荐，按天缓存，下次打开时重新获取';
      case CacheSection.images:
        return '海报与封面图片，仅占内存';
    }
  }
}

class CacheService {
  /// Hive keys belonging to [section] (images has none — in-memory).
  static List<String> keysOf(CacheSection section, Box<dynamic> box) {
    switch (section) {
      case CacheSection.videoHome:
        return [HiveKeys.videoHomeCache];
      case CacheSection.douban:
        return [HiveKeys.doubanDetail, HiveKeys.doubanIdmap];
      case CacheSection.daily:
        return box.keys
            .whereType<String>()
            .where((k) => k.startsWith('hao_daily_'))
            .toList();
      case CacheSection.images:
        return const [];
    }
  }

  static int _bytesOf(Object? value) {
    if (value is String) return utf8.encode(value).length;
    if (value is List<int>) return value.length;
    if (value == null) return 0;
    return utf8.encode(value.toString()).length;
  }

  /// Size of one section in bytes. [box] defaults to HiveStore.box.
  static int sizeOf(CacheSection section, {Box<dynamic>? box}) {
    final b = box ?? HiveStore.box;
    if (section == CacheSection.images) {
      return _imageCacheBytes();
    }
    var total = 0;
    for (final key in keysOf(section, b)) {
      total += _bytesOf(b.get(key));
    }
    return total;
  }

  static int totalSize({Box<dynamic>? box}) {
    var total = 0;
    for (final s in CacheSection.values) {
      total += sizeOf(s, box: box);
    }
    return total;
  }

  /// Delete the section's Hive keys (images: clear the ImageCache).
  /// Returns the bytes freed (measured before clearing).
  static Future<int> clearSection(
    CacheSection section, {
    Box<dynamic>? box,
  }) async {
    final b = box ?? HiveStore.box;
    final freed = sizeOf(section, box: b);
    if (section == CacheSection.images) {
      _clearImageCache();
      return freed;
    }
    for (final key in keysOf(section, b)) {
      await b.delete(key);
    }
    return freed;
  }

  static Future<int> clearAll({Box<dynamic>? box}) async {
    var freed = 0;
    for (final s in CacheSection.values) {
      freed += await clearSection(s, box: box);
    }
    return freed;
  }

  /// ImageCache access is guarded: the binding is always initialised
  /// in the app, but unit tests calling CacheService without a binding
  /// must get 0 / a no-op instead of a throw.
  static int _imageCacheBytes() {
    try {
      return PaintingBinding.instance.imageCache.currentSizeBytes;
    } catch (_) {
      return 0;
    }
  }

  static void _clearImageCache() {
    try {
      PaintingBinding.instance.imageCache.clear();
    } catch (_) {}
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}
