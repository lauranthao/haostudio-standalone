// Video local stores — watch history, resume positions, favourites,
// search history, and the user-editable CMS source list.
//
// All Hive-backed (JSON strings in the `app_settings` box). History
// reads are synchronous and must never delay a render (fix 13).

import 'dart:async';
import 'dart:convert';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../../core/storage/hive_store.dart';
import 'cms_sources.dart';
import 'video_models.dart';

/// Watch history (`hao_video_hist`, max 20, most recent first).
class VideoHistoryStore {
  static const int maxEntries = 20;

  static List<WatchHistoryEntry> getAll() {
    final raw = HiveStore.box.get(HiveKeys.videoHistory);
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(WatchHistoryEntry.fromJson)
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  static Future<void> _save(List<WatchHistoryEntry> entries) async {
    await HiveStore.put(
      HiveKeys.videoHistory,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  /// Record / refresh one entry (moves to the front). Called on play
  /// and periodically while playing (throttled by the caller).
  static Future<void> record(WatchHistoryEntry entry) async {
    final list = getAll()
        .where((e) => e.identityKey != entry.identityKey)
        .toList();
    list.insert(0, entry);
    await _save(list.take(maxEntries).toList());
  }

  static WatchHistoryEntry? find(dynamic source, String vodId) {
    final key = '$source|$vodId';
    for (final e in getAll()) {
      if (e.identityKey == key) return e;
    }
    return null;
  }

  static Future<void> remove(dynamic source, String vodId) async {
    final key = '$source|$vodId';
    await _save(getAll().where((e) => e.identityKey != key).toList());
  }

  static Future<void> clear() async {
    await HiveStore.put(HiveKeys.videoHistory, '[]');
  }

  /// Clear history AND all saved resume positions (history page
  /// "清空"). Clearing only the list would leave stale "继续播放"
  /// buttons on detail pages for videos no longer in history.
  static Future<void> clearAll() async {
    await clear();
    final box = HiveStore.box;
    final keys = box.keys
        .whereType<String>()
        .where((k) => k.startsWith(HiveKeys.videoResumePrefix))
        .toList();
    for (final k in keys) {
      await HiveStore.delete(k);
    }
  }

  // -- Resume (vodLocalSave / vodLocalLoad) -------------------------------

  static String _resumeKey(dynamic source, String vodId) =>
      '${HiveKeys.videoResumePrefix}$source:$vodId';

  /// Save a resume position. Positions < 5 s are not saved (web rule:
  /// `saveVideoProgress` returns early when pos < 5).
  static Future<void> saveResume(
    dynamic source,
    String vodId, {
    required int lineIdx,
    required int epIdx,
    required String epName,
    required double position,
    required double duration,
  }) async {
    if (position < 5) return;
    final value = jsonEncode({
      'lineIdx': lineIdx,
      'epIdx': epIdx,
      'epName': epName,
      'position': position,
      'duration': duration,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    await HiveStore.put(_resumeKey(source, vodId), value);
    // Prune old resume keys (cap 200, oldest first).
    final box = HiveStore.box;
    final keys = box.keys
        .whereType<String>()
        .where((k) => k.startsWith(HiveKeys.videoResumePrefix))
        .toList();
    if (keys.length > 200) {
      final withAt = <(String, int)>[];
      for (final k in keys) {
        var at = 0;
        final raw = box.get(k);
        if (raw is String) {
          try {
            at = (jsonDecode(raw) as Map)['at'] as int? ?? 0;
          } catch (_) {}
        }
        withAt.add((k, at));
      }
      withAt.sort((a, b) => a.$2.compareTo(b.$2));
      for (var i = 0; i < withAt.length - 200; i++) {
        await HiveStore.delete(withAt[i].$1);
      }
    }
  }

  /// Load a resume position (only counts when > 10 s in and >= 30 s
  /// from the end — see [ResumeInfo.fromStored]).
  static ResumeInfo? loadResume(
    dynamic source,
    String vodId,
    List<PlayLine> lines,
  ) {
    final raw = HiveStore.box.get(_resumeKey(source, vodId));
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return ResumeInfo.fromStored(decoded, lines);
      }
    } catch (_) {}
    return null;
  }

  // -- Favourites -----------------------------------------------------------

  static List<VideoItem> getFavs() {
    final raw = HiveStore.box.get(HiveKeys.videoFavs);
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(VideoItem.fromJson)
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  static bool isFav(VideoItem item) =>
      getFavs().any((e) => e.identityKey == item.identityKey);

  /// Toggle favourite; returns the new state (true = now favourited).
  static Future<bool> toggleFav(VideoItem item) async {
    final list = getFavs();
    final has = list.any((e) => e.identityKey == item.identityKey);
    final next = has
        ? list.where((e) => e.identityKey != item.identityKey).toList()
        : [item, ...list];
    await HiveStore.put(
      HiveKeys.videoFavs,
      jsonEncode(next.map((e) => e.toJson()).toList()),
    );
    return !has;
  }

  // -- Search history -------------------------------------------------------

  static List<String> getSearchHistory() {
    final raw = HiveStore.box.get(HiveKeys.videoSearchHist);
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
    } catch (_) {}
    return const [];
  }

  static Future<void> saveSearchQuery(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final list = getSearchHistory().where((e) => e != q).toList();
    list.insert(0, q);
    await HiveStore.put(
      HiveKeys.videoSearchHist,
      jsonEncode(list.take(20).toList()),
    );
  }
}

/// VOD playback preferences (V-P0-2).
///
/// Auto-play-next defaults to ON; the reader never throws (uninitialised
/// Hive in a unit test falls back to the default, like
/// [VideoSourcesStore.getAll]).
class VideoPlaybackSettings {
  static bool get autoNext {
    try {
      return HiveStore.getBool(HiveKeys.videoAutoNext, true);
    } catch (_) {
      return true;
    }
  }

  static Future<void> setAutoNext(bool value) =>
      HiveStore.put(HiveKeys.videoAutoNext, value);

  /// Playback speeds (Pure Live defaultRates, same order for cycling).
  static const List<double> vodRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  /// Persisted VOD playback speed; unknown/stored garbage -> 1.0x.
  static double get playbackRate {
    try {
      final v = HiveStore.getDouble(HiveKeys.vodPlaybackRate, 1.0);
      return vodRates.contains(v) ? v : 1.0;
    } catch (_) {
      return 1.0;
    }
  }

  /// Fire-and-forget safe: a storage failure must never break the player.
  static Future<void> setPlaybackRate(double value) async {
    try {
      await HiveStore.put(HiveKeys.vodPlaybackRate, value);
    } catch (_) {}
  }
}

/// User-editable CMS source list (`hao_sa_video`).
///
/// Defaults apply when absent. Returns enabled sources sorted by
/// `sort`. The "at least one video source must remain" delete guard
/// lives here so settings UI and services share it.
class VideoSourcesStore {
  static List<VideoSource> getAll() {
    // Falls back to defaults when Hive is not initialised yet (unit
    // tests constructing CmsClient without HiveStore.init).
    Box<dynamic>? box;
    try {
      box = HiveStore.box;
    } catch (_) {
      return List.of(kDefaultVideoSources);
    }
    final raw = box.get(HiveKeys.videoSources);
    if (raw is! String || raw.isEmpty) {
      return List.of(kDefaultVideoSources);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List && decoded.isNotEmpty) {
        return _mergeDefaults(
          decoded
              .whereType<Map<String, dynamic>>()
              .map(VideoSource.fromJson)
              .toList(),
        );
      }
    } catch (_) {}
    return List.of(kDefaultVideoSources);
  }

  /// Merge new defaults into a persisted list, once per
  /// [kVideoSourcesRevision].
  ///
  /// - Defaults missing from the persisted list (matched by apiUrl)
  ///   are appended, so a new fast source reaches existing installs
  ///   without a "reset to defaults".
  /// - Matched defaults get their `sort` refreshed from the current
  ///   defaults, so a re-prioritisation (fast first, slow last)
  ///   applies; the user's `enabled` toggle is never touched.
  /// - The revision guard means a source the user deliberately
  ///   deleted is never resurrected by a later load: the merge runs
  ///   once per revision, then the stored revision is bumped.
  static List<VideoSource> _mergeDefaults(List<VideoSource> stored) {
    int seenRev = 0;
    try {
      final raw = HiveStore.box.get(HiveKeys.videoSourcesRevision);
      if (raw is int) {
        seenRev = raw;
      } else if (raw is String) {
        seenRev = int.tryParse(raw) ?? 0;
      }
    } catch (_) {}
    if (seenRev >= kVideoSourcesRevision) return stored;
    final byUrl = <String, VideoSource>{
      for (final s in stored) s.apiUrl: s,
    };
    var changed = false;
    final merged = stored.map((s) {
      VideoSource? def;
      for (final d in kDefaultVideoSources) {
        if (d.apiUrl == s.apiUrl) {
          def = d;
          break;
        }
      }
      if (def != null && def.sort != s.sort) {
        changed = true;
        return s.copyWith(sort: def.sort);
      }
      return s;
    }).toList();
    for (final def in kDefaultVideoSources) {
      if (!byUrl.containsKey(def.apiUrl)) {
        merged.add(def);
        changed = true;
      }
    }
    // Best-effort persist so the settings page shows the merged list;
    // behaviour does not depend on it (the merge recomputes in memory).
    // The revision is bumped ONLY after the merged list lands: the
    // old code fired both writes independently, so a crash (or a
    // failed save) between them left the revision bumped while the
    // list still lacked the new defaults — and the merge, guarded by
    // that revision, would never run again for them.
    if (changed) {
      unawaited(
        save(merged)
            .then(
              (_) => HiveStore.put(
                HiveKeys.videoSourcesRevision,
                kVideoSourcesRevision,
              ),
            )
            .catchError((_) {}),
      );
    } else {
      unawaited(
        HiveStore.put(HiveKeys.videoSourcesRevision, kVideoSourcesRevision)
            .catchError((_) {}),
      );
    }
    return merged;
  }

  static List<VideoSource> getEnabled() {
    final list = getAll().where((s) => s.enabled).toList();
    list.sort((a, b) => a.sort.compareTo(b.sort));
    return list;
  }

  static Future<void> save(List<VideoSource> sources) async {
    await HiveStore.put(
      HiveKeys.videoSources,
      jsonEncode(sources.map((s) => s.toJson()).toList()),
    );
  }

  /// True when removing [source] would leave zero video sources.
  static bool wouldLeaveNone(VideoSource source) {
    final rest =
        getAll().where((s) => s.idKey != source.idKey).toList();
    return rest.isEmpty;
  }

  static Future<void> resetToDefaults() async {
    await HiveStore.delete(HiveKeys.videoSources);
  }
}
