// Live watch history store (L01) — Hive-backed, following
// VideoHistoryStore's patterns (JSON strings in the `app_settings`
// box, synchronous reads, never delaying a render).
//
// Pure Live reference: features/history/history_page.dart,
// history_sections.dart, history_refresh.dart, history_limit_dialog.dart.
// Web equivalents translated: localStorage `hao_live_hist` -> Hive
// [HiveKeys.liveHistory]; `#/live/history` -> [LiveHistoryPage].
//
// One entry is recorded on entering a live room (see LiveTabPage's
// room tap). Re-entering moves the entry to the front with fresh
// title/cover and time.

import 'dart:convert';

import '../../core/models/live_models.dart';
import '../../core/storage/hive_store.dart';
import '../../shared/platforms/sites.dart';
import '../../core/storage/safe_json.dart';

/// One watched live room.
class LiveHistoryEntry {
  const LiveHistoryEntry({
    required this.platform,
    required this.roomId,
    this.title = '',
    this.nick = '',
    this.cover = '',
    required this.at,
  });

  factory LiveHistoryEntry.fromRoom(LiveRoom room, {DateTime? at}) =>
      LiveHistoryEntry(
        platform: room.platform,
        roomId: room.roomId,
        title: room.title,
        nick: room.nick,
        cover: room.cover,
        at: (at ?? DateTime.now()).millisecondsSinceEpoch,
      );

  factory LiveHistoryEntry.fromJson(Map<String, dynamic> json) =>
      LiveHistoryEntry(
        platform: json['platform']?.toString() ?? '',
        roomId: json['roomId']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        nick: json['nick']?.toString() ?? '',
        cover: json['cover']?.toString() ?? '',
        at: jIntN(json['at']) ?? 0,
      );

  final String platform;
  final String roomId;
  final String title;
  final String nick;
  final String cover;

  /// When the room was entered, epoch milliseconds.
  final int at;

  DateTime get atDate => DateTime.fromMillisecondsSinceEpoch(at);

  /// `platform|roomId` — the identity key for record / delete.
  String get identityKey => '$platform|$roomId';

  Map<String, dynamic> toJson() => {
    'platform': platform,
    'roomId': roomId,
    'title': title,
    'nick': nick,
    'cover': cover,
    'at': at,
  };

  LiveRoom toRoom() => LiveRoom(
    roomId: roomId,
    platform: platform,
    title: title,
    nick: nick,
    cover: cover,
  );
}

/// Day-group section (Pure Live `HistorySection.of`: today /
/// yesterday / 2–6 days ago / earlier).
enum LiveHistorySection {
  today('今天'),
  yesterday('昨天'),
  recent('2–6 天前'),
  earlier('更早');

  const LiveHistorySection(this.label);

  final String label;

  /// Section for [at] relative to [now] (calendar days, local time).
  static LiveHistorySection of(DateTime at, DateTime now) {
    final aDay = DateTime(at.year, at.month, at.day);
    final nDay = DateTime(now.year, now.month, now.day);
    final diff = nDay.difference(aDay).inDays;
    if (diff <= 0) return LiveHistorySection.today;
    if (diff == 1) return LiveHistorySection.yesterday;
    if (diff <= 6) return LiveHistorySection.recent;
    return LiveHistorySection.earlier;
  }
}

/// Live history store (`hao_live_hist`, most recent first).
class LiveHistoryStore {
  static const int defaultLimit = 50;

  static List<LiveHistoryEntry> getAll() {
    final raw = HiveStore.box.get(HiveKeys.liveHistory);
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        // Per-entry skip (b31 crash hunt): one corrupt row must not
        // discard the whole list.
        final out = <LiveHistoryEntry>[];
        for (final e in decoded.whereType<Map<String, dynamic>>()) {
          try {
            out.add(LiveHistoryEntry.fromJson(e));
          } catch (_) {}
        }
        return out;
      }
    } catch (_) {}
    return const [];
  }

  static Future<void> _save(List<LiveHistoryEntry> entries) async {
    await HiveStore.put(
      HiveKeys.liveHistory,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  /// Record / refresh one entry (moves to the front with fresh
  /// title/cover/time). Called on entering a live room. Entries
  /// older than the retention period (item 11b, key
  /// `hao_live_hist_retention_days`, 0 = forever) are pruned here.
  static Future<void> record(LiveRoom room, {DateTime? at}) async {
    final entry = LiveHistoryEntry.fromRoom(room, at: at);
    final list = getAll()
        .where((e) => e.identityKey != entry.identityKey)
        .toList();
    list.insert(0, entry);
    await _save(_applyLimit(_applyRetention(list)));
  }

  /// Record a pre-built entry (tests / re-entry from the history page).
  static Future<void> recordEntry(LiveHistoryEntry entry) async {
    final list = getAll()
        .where((e) => e.identityKey != entry.identityKey)
        .toList();
    list.insert(0, entry);
    await _save(_applyLimit(_applyRetention(list)));
  }

  static Future<void> remove(String platform, String roomId) async {
    final key = '$platform|$roomId';
    await _save(getAll().where((e) => e.identityKey != key).toList());
  }

  static Future<void> clear() async {
    await HiveStore.put(HiveKeys.liveHistory, '[]');
  }

  // -- Search history --------------------------------------------------
  //
  // Mirrors VideoHistoryStore / MusicStore exactly: plain keywords,
  // most recent first, max 20, JSON string in the app_settings box.
  // Saved when a live search starts (the page calls saveSearchQuery
  // once the query is submitted); only the query is stored, never
  // results. Search results are per-platform and time-sensitive, so
  // history holds keywords only — re-running re-searches live.

  static List<String> getSearchHistory() {
    final raw = HiveStore.box.get(HiveKeys.liveSearchHist);
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
      HiveKeys.liveSearchHist,
      jsonEncode(list.take(20).toList()),
    );
  }

  static Future<void> clearSearchHistory() =>
      HiveStore.delete(HiveKeys.liveSearchHist);

  // -- Limit ------------------------------------------------------------

  /// Current limit: 0 = unlimited, default [defaultLimit].
  static int get limit {
    try {
      return HiveStore.getInt(HiveKeys.liveHistoryLimit, defaultLimit);
    } catch (_) {
      return defaultLimit;
    }
  }

  /// How many stored entries a new [newLimit] would delete (0 when the
  /// new limit is unlimited or >= the stored count).
  static int wouldDeleteCount(int newLimit) {
    if (newLimit <= 0) return 0;
    final count = getAll().length;
    return count > newLimit ? count - newLimit : 0;
  }

  /// Set the limit, trimming stored entries to it when shrinking.
  /// Returns the number of entries deleted by the trim.
  static Future<int> setLimit(int newLimit) async {
    final deleted = wouldDeleteCount(newLimit);
    await HiveStore.put(HiveKeys.liveHistoryLimit, newLimit);
    if (deleted > 0) {
      await _save(getAll().take(newLimit).toList());
    }
    return deleted;
  }

  static List<LiveHistoryEntry> _applyLimit(
    List<LiveHistoryEntry> list,
  ) {
    final l = limit;
    if (l <= 0) return list;
    return list.take(l).toList();
  }

  // -- Retention (item 11b) -------------------------------------------
  //
  // Time-based expiry, read from the literal key
  // `hao_live_hist_retention_days` (0 = forever, default). Kept as a
  // literal here (not via live_history_retention.dart) so this store
  // does not import the module that imports it back.

  static int _retentionDays() {
    try {
      return HiveStore.getInt('hao_live_hist_retention_days', 0);
    } catch (_) {
      return 0;
    }
  }

  /// Drop entries older than the retention period (no-op when the
  /// period is 0 / forever). [now] is injectable for tests.
  static List<LiveHistoryEntry> _applyRetention(
    List<LiveHistoryEntry> list, {
    DateTime? now,
  }) {
    final days = _retentionDays();
    if (days <= 0) return list;
    final cutoff = (now ?? DateTime.now())
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    return list.where((e) => e.at >= cutoff).toList();
  }

  /// Delete entries older than the retention period right now.
  /// Returns how many were deleted.
  static Future<int> pruneExpired({DateTime? now}) async {
    final all = getAll();
    final kept = _applyRetention(all, now: now);
    final deleted = all.length - kept.length;
    if (deleted > 0) await _save(kept);
    return deleted;
  }

  // -- Grouping / filtering (pure, unit-testable) -----------------------

  /// Entries grouped by day section, sections in newest-first order,
  /// entries newest-first within each section.
  static List<(LiveHistorySection, List<LiveHistoryEntry>)> grouped(
    List<LiveHistoryEntry> entries, {
    DateTime? now,
  }) {
    final n = now ?? DateTime.now();
    final bySection = <LiveHistorySection, List<LiveHistoryEntry>>{};
    for (final e in entries) {
      final section = LiveHistorySection.of(e.atDate, n);
      (bySection[section] ??= []).add(e);
    }
    return LiveHistorySection.values
        .where(bySection.containsKey)
        .map((s) => (s, bySection[s]!))
        .toList();
  }

  /// Filter by title / anchor / roomId / platform id or display name.
  /// Empty query returns the list unchanged.
  static List<LiveHistoryEntry> filter(
    List<LiveHistoryEntry> entries,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return entries;
    return entries.where((e) {
      if (e.title.toLowerCase().contains(q)) return true;
      if (e.nick.toLowerCase().contains(q)) return true;
      if (e.roomId.toLowerCase().contains(q)) return true;
      if (e.platform.toLowerCase().contains(q)) return true;
      if (Sites.isSupported(e.platform)) {
        try {
          if (Sites.of(e.platform).name.toLowerCase().contains(q)) {
            return true;
          }
        } catch (_) {}
      }
      return false;
    }).toList();
  }
}
