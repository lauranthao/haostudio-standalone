// Follow platform visibility — item 11a (build 29, I group).
//
// Per-platform show/hide for the follow list: hiding a platform
// hides its follows (and its chip) on the follows page, without
// deleting anything and without touching the global live-source
// enablement in Settings (that list decides which platforms exist
// at all; this one decides which of them the follow list shows).
//
// Storage: Hive `app_settings` box, literal key (HiveKeys lives in
// hive_store.dart, owned by the settings group — the literal is
// named here so the key can move there without changing behaviour).
// The value is a JSON list of hidden platform ids.

import 'dart:convert';

import '../../core/storage/hive_store.dart';

/// Hive key for the hidden-platform list (JSON list of ids).
const String liveHiddenPlatformsKey = 'hao_live_hidden_platforms';

/// Platforms whose follows are hidden. Empty = all shown.
class LiveFollowVisibility {
  static Set<String> hiddenPlatforms() {
    try {
      final raw = HiveStore.box.get(liveHiddenPlatformsKey);
      if (raw is! String || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toSet();
      }
    } catch (_) {}
    return {};
  }

  static bool isHidden(String platformId) =>
      hiddenPlatforms().contains(platformId);

  static Future<void> setHidden(String platformId, bool hidden) async {
    final hiddenSet = hiddenPlatforms();
    if (hidden) {
      hiddenSet.add(platformId);
    } else {
      hiddenSet.remove(platformId);
    }
    await HiveStore.put(
      liveHiddenPlatformsKey,
      jsonEncode(hiddenSet.toList()),
    );
  }

  /// Follows left visible after hiding [hidden] platforms (pure,
  /// unit-testable without Hive).
  static List<T> visibleFollows<T>(
    List<T> follows,
    Set<String> hidden, {
    required String Function(T follow) platformOf,
  }) {
    if (hidden.isEmpty) return follows;
    return follows.where((f) => !hidden.contains(platformOf(f))).toList();
  }
}
