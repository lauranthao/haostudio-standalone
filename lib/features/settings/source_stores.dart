// Source + danmaku settings stores — Hive-backed, settings pages
// read/write through these; the consuming features read the same
// keys (SongSearchService, CmsClient, live tab) so a toggle takes
// effect on next use, with no restart.
//
// Guard everywhere: at least one source per group must stay enabled —
// a group with zero sources can search / list nothing, so disabling
// the last one is refused (returns false, nothing written).
//
// All methods take an optional [box] so tests can pass a throwaway
// box; production call sites omit it and use HiveStore.box.

import 'dart:convert';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../../core/storage/hive_store.dart';
import '../../services/music/music_models.dart';
import '../../shared/platforms/sites.dart';

/// Enabled music search platforms (subset of [kSearchPlatforms]).
///
/// 咪咕 (mg) is NOT a search source — it only appears in alt-platform
/// lookup / resolvers — so it is never listed here.
class MusicSourcesStore {
  static List<MusicPlatform> enabled({Box<dynamic>? box}) {
    final b = _safeBox(box);
    if (b == null) return List.of(kSearchPlatforms);
    final raw = b.get(HiveKeys.musicSources);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          // Match on raw codes (never fromCode: it maps unknown
          // strings to wy, which would resurrect a corrupt entry).
          final codes = decoded.map((e) => e.toString()).toSet();
          final list = kSearchPlatforms
              .where((p) => codes.contains(p.code))
              .toList();
          if (list.isNotEmpty) return list;
        }
      } catch (_) {}
    }
    return List.of(kSearchPlatforms);
  }

  static bool isEnabled(MusicPlatform pf, {Box<dynamic>? box}) =>
      enabled(box: box).contains(pf);

  /// Returns false (and writes nothing) when disabling [pf] would
  /// leave zero enabled platforms.
  static Future<bool> setEnabled(
    MusicPlatform pf,
    bool value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return false;
    final current = enabled(box: b);
    final next = value
        ? {...current, pf}.toList()
        : current.where((p) => p != pf).toList();
    if (next.isEmpty) return false;
    // Keep merge order (wy/tx/kg/kw) regardless of toggle order.
    next.sort(
      (a, b) =>
          kSearchPlatforms.indexOf(a).compareTo(kSearchPlatforms.indexOf(b)),
    );
    await b.put(
      HiveKeys.musicSources,
      jsonEncode(next.map((p) => p.code).toList()),
    );
    return true;
  }
}

/// Enabled live platforms (subset of [Sites.supportedSiteIds]).
class LiveSourcesStore {
  static List<String> enabledIds({Box<dynamic>? box}) {
    final b = _safeBox(box);
    if (b == null) return List.of(Sites.supportedSiteIds);
    final raw = b.get(HiveKeys.liveSources);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final list = decoded
              .map((e) => e.toString())
              .where(Sites.isSupported)
              .toList();
          if (list.isNotEmpty) return list;
        }
      } catch (_) {}
    }
    return List.of(Sites.supportedSiteIds);
  }

  static bool isEnabled(String siteId, {Box<dynamic>? box}) =>
      enabledIds(box: box).contains(siteId);

  /// Returns false (and writes nothing) when disabling [siteId] would
  /// leave zero enabled platforms.
  static Future<bool> setEnabled(
    String siteId,
    bool value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return false;
    final current = enabledIds(box: b);
    final next = value
        ? {...current, siteId}.toList()
        : current.where((id) => id != siteId).toList();
    if (next.isEmpty) return false;
    // Keep display order (bilibili/douyu/huya/douyin/kuaishou).
    next.sort(
      (a, b) => Sites.supportedSiteIds
          .indexOf(a)
          .compareTo(Sites.supportedSiteIds.indexOf(b)),
    );
    await b.put(HiveKeys.liveSources, jsonEncode(next));
    return true;
  }
}

/// Danmaku settings.
//
// HONEST STATUS (2026-11-16): the live room renders danmaku as a plain
// scrolling list under the video (live_room_page.dart) and does NOT yet
// read these keys — that file belongs to the player work. These settings
// ARE persisted here the moment the user changes them, and the room page
// only has to read [DanmakuSettings] to honour them; the settings page
// says so on-screen instead of pretending the toggles already work.
// Speed / area have no control at all: a list has no scroll speed and
// no overlay area to size, so they are shown as explanatory text, not
// sliders.
class DanmakuSettings {
  static const double defaultFontSize = 14;
  static const double minFontSize = 12;
  static const double maxFontSize = 20;

  static const double defaultOpacity = 1.0;
  static const double minOpacity = 0.3;
  static const double maxOpacity = 1.0;

  /// Per-platform danmaku on/off. Absent entry = enabled.
  static Map<String, bool> enabledMap({Box<dynamic>? box}) {
    final b = _safeBox(box);
    if (b == null) return const {};
    final raw = b.get(HiveKeys.danmakuEnabled);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return {
            for (final e in decoded.entries)
              if (e.value is bool) e.key: e.value as bool,
          };
        }
      } catch (_) {}
    }
    return const {};
  }

  static bool isEnabled(String siteId, {Box<dynamic>? box}) =>
      enabledMap(box: box)[siteId] ?? true;

  static Future<void> setEnabled(
    String siteId,
    bool value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    final map = Map<String, bool>.of(enabledMap(box: b));
    map[siteId] = value;
    await b.put(HiveKeys.danmakuEnabled, jsonEncode(map));
  }

  static double fontSize({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final v = (b?.get(HiveKeys.danmakuFontSize) as num?)?.toDouble();
    if (v == null) return defaultFontSize;
    return v.clamp(minFontSize, maxFontSize);
  }

  static Future<void> setFontSize(double value, {Box<dynamic>? box}) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(
      HiveKeys.danmakuFontSize,
      value.clamp(minFontSize, maxFontSize),
    );
  }

  static double opacity({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final v = (b?.get(HiveKeys.danmakuOpacity) as num?)?.toDouble();
    if (v == null) return defaultOpacity;
    return v.clamp(minOpacity, maxOpacity);
  }

  static Future<void> setOpacity(double value, {Box<dynamic>? box}) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(HiveKeys.danmakuOpacity, value.clamp(minOpacity, maxOpacity));
  }
}

/// The caller's box, or HiveStore.box when Hive is initialised.
/// Returns null when Hive is NOT initialised yet (unit tests that
/// construct services without HiveStore.init, e.g. CmsClient tests) —
/// callers fall back to defaults instead of crashing.
Box<dynamic>? _safeBox(Box<dynamic>? box) {
  if (box != null) return box;
  try {
    return HiveStore.box;
  } catch (_) {
    return null;
  }
}
