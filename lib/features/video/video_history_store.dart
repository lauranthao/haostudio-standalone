// Video local stores — watch history, resume positions, favourites,
// search history, and the user-editable CMS source list.
//
// All Hive-backed (JSON strings in the `app_settings` box). History
// reads are synchronous and must never delay a render (fix 13).

import 'dart:async';
import 'dart:convert';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../../core/player/kernel/video_fit.dart';
import '../../core/storage/hive_store.dart';
import '../../core/storage/safe_json.dart';
import 'cms_sources.dart';
import 'video_models.dart';
import 'video_title_helpers.dart';

/// Watch history (`hao_video_hist`, max 20, most recent first).
class VideoHistoryStore {
  static const int maxEntries = 20;

  static List<WatchHistoryEntry> getAll() {
    final raw = HiveStore.box.get(HiveKeys.videoHistory);
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        // Per-entry skip (b31 crash hunt): one corrupt row must not
        // discard the whole history — drop the bad row, keep the rest.
        final list = <WatchHistoryEntry>[];
        for (final e in decoded.whereType<Map<String, dynamic>>()) {
          try {
            list.add(WatchHistoryEntry.fromJson(e));
          } catch (_) {}
        }
        return _dedupeByFilm(list);
      }
    } catch (_) {}
    return const [];
  }

  /// Film identity for history dedup: the normalised title plus the
  /// release year (`normTitle|year`, the same key search dedup uses).
  /// One film = one history row, even when it was watched on different
  /// CMS sources (each source has its own vodId) or after the detail
  /// page switched to a faster source. Episode / line / progress are
  /// NOT part of the key — watching a new episode updates the same row
  /// instead of starting a second one.
  ///
  /// The year matters because `videoNormTitle` strips a parenthesised
  /// year (`霓裳尽欢 (2024)` -> `霓裳尽欢`): without it, a remake in a
  /// different year collapses into the original's row (P1-16). A row
  /// with no year (written before P1-16, or a film whose source gives
  /// no year) falls back to the bare title, so old rows keep working
  /// and are never lost.
  ///
  /// An empty normalised title (untitled entry) has no film identity
  /// and falls back to the exact `source|vodId` key, so two untitled
  /// entries never merge into each other.
  static String filmKey(WatchHistoryEntry e) {
    final t = videoNormTitle(e.title);
    if (t.isEmpty) return '';
    final y = e.year.trim();
    return y.isEmpty ? t : '$t|$y';
  }

  /// Whether two (title, year) pairs denote the same film for merge
  /// purposes. Years must agree when BOTH are known; a missing year
  /// on either side is treated as "unknown, may match" — the pre-fix
  /// title-only behaviour — so a legacy year-less row is absorbed by
  /// the film it belongs to instead of lingering as a duplicate row.
  /// Two rows with different KNOWN years never match.
  static bool _filmMatches(
    String titleA,
    String yearA,
    String titleB,
    String yearB,
  ) {
    if (videoNormTitle(titleA) != videoNormTitle(titleB)) return false;
    final ya = yearA.trim();
    final yb = yearB.trim();
    if (ya.isEmpty || yb.isEmpty) return true;
    return ya == yb;
  }

  /// Merge legacy duplicates: at most one row per film (by [filmKey]),
  /// keeping the most recently watched entry (`at` latest; ties keep
  /// the first in stored order, which is most-recent-first). Runs on
  /// every read so pre-fix duplicates disappear from the UI without
  /// the user deleting anything; the next [record] persists the
  /// merged list. A legacy year-less row merges into the same-title
  /// row (see [_filmMatches]); two rows with different KNOWN years
  /// stay separate.
  static List<WatchHistoryEntry> _dedupeByFilm(
    List<WatchHistoryEntry> list,
  ) {
    final out = <WatchHistoryEntry>[];
    for (final e in list) {
      if (filmKey(e).isEmpty) {
        out.add(e);
        continue;
      }
      var slot = -1;
      for (var i = 0; i < out.length; i++) {
        if (filmKey(out[i]).isEmpty) continue;
        if (_filmMatches(e.title, e.year, out[i].title, out[i].year)) {
          slot = i;
          break;
        }
      }
      if (slot < 0) {
        out.add(e);
      } else if (e.at.isAfter(out[slot].at)) {
        out[slot] = e;
      }
    }
    return out;
  }

  static Future<void> _save(List<WatchHistoryEntry> entries) async {
    await HiveStore.put(
      HiveKeys.videoHistory,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  /// Record / refresh one entry (moves to the front). Called on play
  /// and periodically while playing (throttled by the caller).
  /// Dedup is by film ([filmKey]): watching a new episode — even on a
  /// different CMS source — updates the same row (episode, progress
  /// and time all take the latest), never a second row.
  static Future<void> record(WatchHistoryEntry entry) async {
    final key = filmKey(entry);
    final list = getAll().where((e) {
      if (key.isEmpty) return e.identityKey != entry.identityKey;
      // Same rule as _dedupeByFilm: a legacy year-less row is
      // absorbed by the same-title film; a different KNOWN year is
      // a different film and keeps its own row.
      return !_filmMatches(e.title, e.year, entry.title, entry.year);
    }).toList();
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

  /// Film-level lookup: the most recent entry for a film, whatever
  /// source it was last watched on. The detail page uses this (not
  /// [find]) so a film watched on another source still resumes at its
  /// latest episode instead of starting over at episode 1.
  ///
  /// When [year] is given, only a row with that year — or a legacy
  /// year-less row (unknown year, pre-P1-16) — matches; a row with a
  /// DIFFERENT known year never matches, so a remake does not resume
  /// into the original's position. With no year, any same-title row
  /// matches (most recent first), as before.
  static WatchHistoryEntry? findByTitle(String title, {String year = ''}) {
    final key = videoNormTitle(title);
    if (key.isEmpty) return null;
    final y = year.trim();
    final all = getAll();
    if (y.isNotEmpty) {
      for (final e in all) {
        if (videoNormTitle(e.title) == key && e.year.trim() == y) {
          return e;
        }
      }
      for (final e in all) {
        if (videoNormTitle(e.title) == key && e.year.trim().isEmpty) {
          return e;
        }
      }
      return null;
    }
    for (final e in all) {
      if (filmKey(e).isNotEmpty && videoNormTitle(e.title) == key) {
        return e;
      }
    }
    return null;
  }

  /// Film-level resume (P1-15): the latest history row for this film
  /// (title + year, any source), mapped onto the CURRENT detail's
  /// lines by episode NAME. The winning source's own resume key
  /// ([loadResume]) is tried first by the caller; this is the
  /// fallback for a source switch, where the new source+vodId has no
  /// resume key of its own yet.
  ///
  /// Only the SAME episode resumes: the stored episode name must
  /// appear in these lines (searched across ALL lines — the new
  /// source may order its lines differently). When the name is not
  /// there the episode list does not line up, so this returns null
  /// instead of guessing by index and reporting a time for the wrong
  /// episode. The saved position must also pass the vodLocalLoad rule
  /// (> 10 s in, >= 30 s from the end, against the STORED duration).
  static ResumeInfo? loadResumeForFilm({
    required String title,
    required String year,
    required List<PlayLine> lines,
  }) {
    if (lines.isEmpty) return null;
    final hist = findByTitle(title, year: year);
    if (hist == null) return null;
    if (hist.position <= 10) return null;
    if (hist.duration > 0 && hist.position >= hist.duration - 30) {
      return null;
    }
    if (hist.epName.isNotEmpty) {
      for (var li = 0; li < lines.length; li++) {
        final eps = lines[li].episodes;
        for (var ei = 0; ei < eps.length; ei++) {
          if (eps[ei].name == hist.epName) {
            return ResumeInfo(
              lineIdx: li,
              epIdx: ei,
              epName: hist.epName,
              position: hist.position,
              duration: hist.duration,
            );
          }
        }
      }
      return null;
    }
    // No episode name recorded: index only, validated + clamped by
    // the same rule as a stored resume key.
    return ResumeInfo.fromStored(
      {
        'lineIdx': hist.lineIdx,
        'epIdx': hist.epIdx,
        'epName': hist.epName,
        'position': hist.position,
        'duration': hist.duration,
      },
      lines,
    );
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
            final d = jsonDecode(raw);
            at = d is Map ? jIntN(d['at']) ?? 0 : 0;
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
        final out = <VideoItem>[];
        for (final e in decoded.whereType<Map<String, dynamic>>()) {
          try {
            out.add(VideoItem.fromJson(e));
          } catch (_) {}
        }
        return out;
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

  /// VOD picture fit (PiliPlus VideoFitType + Kazumi PlayerAspectRatio
  /// intersection — see `VideoFitMode`): 自动 / 拉伸 / 裁剪, default
  /// 自动. Unknown/stored garbage -> 自动. VOD only: live always
  /// renders contain (the backends gate on their own `_isLive`).
  static VideoFitMode get videoFit => VideoFitMode.current;

  /// Fire-and-forget safe, same as [setPlaybackRate].
  static Future<void> setVideoFit(VideoFitMode mode) async {
    try {
      await VideoFitMode.save(mode);
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
        final parsed = <VideoSource>[];
        for (final e in decoded.whereType<Map<String, dynamic>>()) {
          try {
            parsed.add(VideoSource.fromJson(e));
          } catch (_) {}
        }
        return _mergeDefaults(parsed);
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
  /// - A stored http:// URL whose default twin is now https:// is
  ///   upgraded IN PLACE (rev 3: 金鹰/非凡/非凡主站): only the scheme
  ///   changes — the stored `sort` and `enabled` are kept exactly as
  ///   the user has them, so a manual reorder / toggle survives the
  ///   upgrade and no duplicate (http twin + https twin) appears.
  ///   The upgrade is matched by scheme-insensitive URL, and a
  ///   stored http twin counts as "present" so the https default is
  ///   not appended a second time.
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
    // A stored url counts as present under both its own scheme and
    // its https form, so an http twin is not "missing" its https
    // default (which would append a duplicate).
    final storedUrls = <String>{
      for (final s in stored) s.apiUrl,
      for (final s in stored) toHttps(s.apiUrl),
    };
    var changed = false;
    final merged = stored.map((s) {
      VideoSource? def;
      for (final d in kDefaultVideoSources) {
        if (d.apiUrl == s.apiUrl || d.apiUrl == toHttps(s.apiUrl)) {
          def = d;
          break;
        }
      }
      if (def == null) return s;
      if (def.apiUrl != s.apiUrl) {
        // Scheme-only upgrade (http→https twin): keep the user's
        // sort and enabled untouched; only the scheme changes.
        changed = true;
        return VideoSource(
          id: s.id,
          name: s.name,
          apiUrl: def.apiUrl,
          kind: s.kind,
          enabled: s.enabled,
          sort: s.sort,
        );
      }
      if (def.sort != s.sort) {
        changed = true;
        return s.copyWith(sort: def.sort);
      }
      return s;
    }).toList();
    for (final def in kDefaultVideoSources) {
      if (!storedUrls.contains(def.apiUrl)) {
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
