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
// The live room reads these keys (live_room_page.dart) and honours
// them: per-platform on/off gates the transport, font size + opacity
// style the list, and a Hive listenable applies changes while the room
// is open, no restart. Speed / stroke / colour only affect the
// fullscreen flying danmaku (BarrageConfig): the portrait list is a
// chat list of plain Text — it has no scroll speed, no stroke and no
// flying area to size — so the settings page must say "仅全屏飞弹幕生效"
// next to those controls, like it already does for area. Maximum
// count caps both sides: the portrait list drops its oldest items
// past the cap, and the flying side takes min(cap, engine pool 72).
class DanmakuSettings {
  static const double defaultFontSize = 14;
  static const double minFontSize = 12;
  static const double maxFontSize = 20;

  static const double defaultOpacity = 1.0;
  static const double minOpacity = 0.3;
  static const double maxOpacity = 1.0;

  /// VOD ("影视弹幕") key in the same `hao_danmaku_enabled` map.
  /// Not a live platform — it is listed separately in the settings
  /// page. Unlike the live platforms it defaults to OFF (opt-in):
  /// VOD danmaku comes from a title guess, so a wrong guess would
  /// float another show's spoilers over the picture.
  static const String vodSiteId = 'vod';

  /// Per-platform danmaku on/off. Absent entry = enabled, except
  /// [vodSiteId] which is absent = disabled (opt-in, see above).
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

  static bool isEnabled(String siteId, {Box<dynamic>? box}) {
    final map = enabledMap(box: box);
    if (map.containsKey(siteId)) return map[siteId]!;
    return siteId != vodSiteId;
  }

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
    // Wrong-typed stored value (e.g. a String left by an old
    // build) must fall back to the default, not throw: `as num?`
    // throws TypeError and the page crashes on open (b30).
    final raw = b?.get(HiveKeys.danmakuFontSize);
    final v = raw is num ? raw.toDouble() : null;
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
    // Wrong-typed stored value (e.g. a String left by an old
    // build) must fall back to the default, not throw: `as num?`
    // throws TypeError and the page crashes on open (b30).
    final raw = b?.get(HiveKeys.danmakuOpacity);
    final v = raw is num ? raw.toDouble() : null;
    if (v == null) return defaultOpacity;
    return v.clamp(minOpacity, maxOpacity);
  }

  static Future<void> setOpacity(double value, {Box<dynamic>? box}) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(HiveKeys.danmakuOpacity, value.clamp(minOpacity, maxOpacity));
  }

  // -- Chat-list style (S2) -------------------------------------------
  //
  // The list font size is the existing [fontSize] setting (it already
  // styles the list); these three are the remaining S2 controls.

  /// 'compact' (one line per message, default) or 'card'.
  static const String listStyleCompact = 'compact';
  static const String listStyleCard = 'card';

  static String listStyle({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final raw = b?.get(HiveKeys.danmakuListStyle);
    if (raw is String && raw == listStyleCard) return listStyleCard;
    return listStyleCompact;
  }

  static Future<void> setListStyle(String value, {Box<dynamic>? box}) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(
      HiveKeys.danmakuListStyle,
      value == listStyleCard ? listStyleCard : listStyleCompact,
    );
  }

  /// 'compact' | 'standard' (default) | 'loose'. Mirrors Pure Live's
  /// ChatSpacing: gaps halved / as-is / x1.5, text height 1.4 /
  /// theme default / 1.7.
  static const String listSpacingCompact = 'compact';
  static const String listSpacingStandard = 'standard';
  static const String listSpacingLoose = 'loose';

  static String listSpacing({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final raw = b?.get(HiveKeys.danmakuListSpacing);
    if (raw is String &&
        (raw == listSpacingCompact || raw == listSpacingLoose)) {
      return raw;
    }
    return listSpacingStandard;
  }

  static Future<void> setListSpacing(
    String value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    final v = value == listSpacingCompact || value == listSpacingLoose
        ? value
        : listSpacingStandard;
    await b.put(HiveKeys.danmakuListSpacing, v);
  }

  /// Show the sender name in the chat list. Default true.
  static bool showUsernames({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final v = b?.get(HiveKeys.danmakuShowUsernames);
    if (v is bool) return v;
    return true;
  }

  static Future<void> setShowUsernames(
    bool value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(HiveKeys.danmakuShowUsernames, value);
  }

  // -- Content filtering (S3) -----------------------------------------
  //
  // Defaults: similarity ON at 85 (Pure Live's threshold; this app
  // defaults the filter on, Pure Live defaults it off), pure-emoji /
  // overlong / Douyu-bot OFF (they hide content a user may want, so
  // they are opt-in). Overlong length defaults to 30, Pure Live's
  // default, clamped 10..100 like Pure Live.

  static const int defaultSimilarityThreshold = 85;
  static const int minSimilarityThreshold = 0;
  static const int maxSimilarityThreshold = 100;

  static const int defaultBlockLongLength = 30;
  static const int minBlockLongLength = 10;
  static const int maxBlockLongLength = 100;

  static bool similarityEnabled({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final v = b?.get(HiveKeys.danmakuSimilarityEnabled);
    if (v is bool) return v;
    return true;
  }

  static Future<void> setSimilarityEnabled(
    bool value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(HiveKeys.danmakuSimilarityEnabled, value);
  }

  static int similarityThreshold({Box<dynamic>? box}) {
    final b = _safeBox(box);
    // Wrong-typed stored value (e.g. a String left by an old
    // build) must fall back to the default, not throw: `as num?`
    // throws TypeError and the page crashes on open (b30).
    final raw = b?.get(HiveKeys.danmakuSimilarityThreshold);
    final v = raw is num ? raw.toInt() : null;
    if (v == null) return defaultSimilarityThreshold;
    return v.clamp(minSimilarityThreshold, maxSimilarityThreshold);
  }

  static Future<void> setSimilarityThreshold(
    int value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(
      HiveKeys.danmakuSimilarityThreshold,
      value.clamp(minSimilarityThreshold, maxSimilarityThreshold),
    );
  }

  static bool blockEmoteOnly({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final v = b?.get(HiveKeys.danmakuBlockEmoteOnly);
    if (v is bool) return v;
    return false;
  }

  static Future<void> setBlockEmoteOnly(
    bool value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(HiveKeys.danmakuBlockEmoteOnly, value);
  }

  static bool blockLong({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final v = b?.get(HiveKeys.danmakuBlockLong);
    if (v is bool) return v;
    return false;
  }

  static Future<void> setBlockLong(bool value, {Box<dynamic>? box}) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(HiveKeys.danmakuBlockLong, value);
  }

  static int blockLongLength({Box<dynamic>? box}) {
    final b = _safeBox(box);
    // Wrong-typed stored value (e.g. a String left by an old
    // build) must fall back to the default, not throw: `as num?`
    // throws TypeError and the page crashes on open (b30).
    final raw = b?.get(HiveKeys.danmakuBlockLongLength);
    final v = raw is num ? raw.toInt() : null;
    if (v == null) return defaultBlockLongLength;
    return v.clamp(minBlockLongLength, maxBlockLongLength);
  }

  static Future<void> setBlockLongLength(
    int value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(
      HiveKeys.danmakuBlockLongLength,
      value.clamp(minBlockLongLength, maxBlockLongLength),
    );
  }

  /// Douyu suspected-automated-message filter. Default false.
  static bool douyuBotFilter({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final v = b?.get(HiveKeys.danmakuDouyuBotFilter);
    if (v is bool) return v;
    return false;
  }

  static Future<void> setDouyuBotFilter(
    bool value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(HiveKeys.danmakuDouyuBotFilter, value);
  }

  // -- Fullscreen floating-danmaku area -------------------------------
  //
  // Which part of the video the flying danmaku may cover, fullscreen
  // only (the portrait list below the video is a chat list, not an
  // overlay — it has no area to size). 'full' = whole video (default),
  // 'half' = top half, 'third' = top third, 'fifth' = top fifth. Stored
  // as a string so a bad value falls back to full; the live room maps it
  // to the flame_barrage BarrageConfig.area fraction (usableHeight =
  // screenHeight * area), exactly like Pure Live's danmakuArea.
  static const String areaFull = 'full';
  static const String areaHalf = 'half';
  static const String areaThird = 'third';
  static const String areaFifth = 'fifth';

  /// Default area fraction (whole video).
  static const double defaultAreaFraction = 1.0;

  static const Map<String, double> areaFractions = {
    areaFull: 1.0,
    areaHalf: 0.5,
    areaThird: 1 / 3,
    areaFifth: 1 / 5,
  };

  static String area({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final raw = b?.get(HiveKeys.danmakuArea);
    if (raw is String && areaFractions.containsKey(raw)) return raw;
    return areaFull;
  }

  static double areaFraction({Box<dynamic>? box}) =>
      areaFractions[area(box: box)] ?? defaultAreaFraction;

  static Future<void> setArea(String value, {Box<dynamic>? box}) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(
      HiveKeys.danmakuArea,
      areaFractions.containsKey(value) ? value : areaFull,
    );
  }

  // -- Fullscreen flying-danmaku fine settings (1.1.6) --------------
  //
  // Speed / stroke / colour apply ONLY to the fullscreen flying
  // danmaku (BarrageConfig) — the portrait list is plain Text and
  // has none of these. The settings page must say "仅全屏飞弹幕生效"
  // next to each of these controls, like it already does for area.
  // Maximum count caps both sides: the portrait list drops its
  // oldest items past the cap, and the flying side takes
  // min(cap, engine pool ceiling 72) — see [flyingMaxVisibleCount].

  static const bool defaultStroke = true;

  static const double defaultStrokeWidth = 1.0;
  static const double minStrokeWidth = 0.5;
  static const double maxStrokeWidth = 2.0;

  static const double defaultSpeed = 1.0;
  static const double minSpeed = 0.5;
  static const double maxSpeed = 2.0;

  /// Engine default for BarrageConfig.baseSpeed (px/s at speed 1.0).
  static const double baseSpeedPxPerSecond = 120.0;

  static const int defaultMaxCount = 80;
  static const int minMaxCount = 20;
  static const int maxMaxCount = 200;

  /// Engine object-pool ceiling (BarrageConfig.barragePoolMaxSize in
  /// the live room): the flying danmaku can never show more than
  /// this many items at once, however high [maxCount] is set.
  static const int enginePoolMaxSize = 72;

  static const String colorModeUniform = 'uniform';
  static const String colorModePlatform = 'platform';

  /// Flying-danmaku stroke on/off. Default true (engine default).
  /// 仅全屏飞弹幕生效 (the portrait list is plain Text).
  static bool stroke({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final v = b?.get(HiveKeys.danmakuStroke);
    if (v is bool) return v;
    return defaultStroke;
  }

  static Future<void> setStroke(bool value, {Box<dynamic>? box}) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(HiveKeys.danmakuStroke, value);
  }

  /// Flying-danmaku stroke width, 0.5..2.0, default 1.0.
  /// 仅全屏飞弹幕生效. Stroke colour is fixed black (see HiveKeys).
  static double strokeWidth({Box<dynamic>? box}) {
    final b = _safeBox(box);
    // Wrong-typed stored value (e.g. a String left by an old
    // build) must fall back to the default, not throw: `as num?`
    // throws TypeError and the page crashes on open (b30).
    final raw = b?.get(HiveKeys.danmakuStrokeWidth);
    final v = raw is num ? raw.toDouble() : null;
    if (v == null) return defaultStrokeWidth;
    return v.clamp(minStrokeWidth, maxStrokeWidth);
  }

  static Future<void> setStrokeWidth(
    double value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(
      HiveKeys.danmakuStrokeWidth,
      value.clamp(minStrokeWidth, maxStrokeWidth),
    );
  }

  /// Flying-danmaku speed multiplier, 0.5..2.0, default 1.0.
  /// 仅全屏飞弹幕生效. This is NOT playback rate — live has no
  /// speed control and playbackRate stays 1.0.
  static double speed({Box<dynamic>? box}) {
    final b = _safeBox(box);
    // Wrong-typed stored value (e.g. a String left by an old
    // build) must fall back to the default, not throw: `as num?`
    // throws TypeError and the page crashes on open (b30).
    final raw = b?.get(HiveKeys.danmakuSpeed);
    final v = raw is num ? raw.toDouble() : null;
    if (v == null) return defaultSpeed;
    return v.clamp(minSpeed, maxSpeed);
  }

  static Future<void> setSpeed(double value, {Box<dynamic>? box}) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(HiveKeys.danmakuSpeed, value.clamp(minSpeed, maxSpeed));
  }

  /// Flying speed in px/s: BarrageConfig.baseSpeed = 120 * [speed].
  static double flyingBaseSpeed({Box<dynamic>? box}) =>
      baseSpeedPxPerSecond * speed(box: box);

  /// Maximum danmaku count, 20..200, default 80 (the engine's
  /// maxVisibleCount default). Caps the portrait list AND the
  /// fullscreen flying danmaku (flying side additionally clamped
  /// to [enginePoolMaxSize] — see [flyingMaxVisibleCount]).
  static int maxCount({Box<dynamic>? box}) {
    final b = _safeBox(box);
    // Wrong-typed stored value (e.g. a String left by an old
    // build) must fall back to the default, not throw: `as num?`
    // throws TypeError and the page crashes on open (b30).
    final raw = b?.get(HiveKeys.danmakuMaxCount);
    final v = raw is num ? raw.toInt() : null;
    if (v == null) return defaultMaxCount;
    return v.clamp(minMaxCount, maxMaxCount);
  }

  static Future<void> setMaxCount(int value, {Box<dynamic>? box}) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(
      HiveKeys.danmakuMaxCount,
      value.clamp(minMaxCount, maxMaxCount),
    );
  }

  /// Flying-danmaku visible cap: the stored [maxCount], clamped to
  /// the engine object-pool ceiling ([enginePoolMaxSize]).
  static int flyingMaxVisibleCount({Box<dynamic>? box}) =>
      maxCount(box: box).clamp(minMaxCount, enginePoolMaxSize);

  /// 'uniform' (default — theme text in the portrait list, white
  /// flying danmaku) or 'platform' (the platform's own colour from
  /// LiveMessage.color, where the adapter provides one).
  /// 仅全屏飞弹幕 + 竖屏列表正文生效；用户名在两种模式下都保持主题色。
  static String colorMode({Box<dynamic>? box}) {
    final b = _safeBox(box);
    final raw = b?.get(HiveKeys.danmakuColorMode);
    if (raw is String && raw == colorModePlatform) return colorModePlatform;
    return colorModeUniform;
  }

  static Future<void> setColorMode(
    String value, {
    Box<dynamic>? box,
  }) async {
    final b = _safeBox(box);
    if (b == null) return;
    await b.put(
      HiveKeys.danmakuColorMode,
      value == colorModePlatform ? colorModePlatform : colorModeUniform,
    );
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
