// Music bookmarks (1.1.6) — multiple saved positions per song.
//
// Storage: one Hive table, `hao_music_bookmarks` (HiveKeys.musicBookmarks),
// `{identityKey: [{position, label, createdAt}]}` — position in whole
// seconds, label is the `m:ss` text shown in the list, createdAt is
// the ms epoch (the delete identity, together with position).
//
// Bookmarks are user-saved, unlike the automatic resume position:
// finishing a track never clears them, and they survive restarts.
// Caps mirror the resume / lyrics tables (per-song 10, whole table
// 500 songs, oldest dropped first). A bookmark is keyed by
// `identityKey`, so the same title on another platform / version
// keeps its own list — the same isolation the resume map already has
// (and the same known empty-songId collision caveat: see
// music_models.dart `identityKey`).

import 'dart:convert';

import '../../core/storage/hive_store.dart';
import '../../core/storage/safe_json.dart';

/// One saved position in one song.
class MusicBookmark {
  MusicBookmark({
    required this.position,
    required this.label,
    required this.createdAt,
  });

  /// Position in whole seconds.
  final int position;

  /// Display text, `m:ss` (e.g. `1:23`).
  final String label;

  /// Ms since epoch — the delete identity (with [position]).
  final int createdAt;

  Map<String, dynamic> toJson() => {
    'position': position,
    'label': label,
    'createdAt': createdAt,
  };

  static MusicBookmark? fromJson(Map<String, dynamic> json) {
    final position = jIntN(json['position']);
    final createdAt = jIntN(json['createdAt']);
    if (position == null || position < 0 || createdAt == null) {
      return null;
    }
    final label = json['label']?.toString();
    return MusicBookmark(
      position: position,
      label: label == null || label.isEmpty
          ? BookmarksStore.formatLabel(position)
          : label,
      createdAt: createdAt,
    );
  }
}

class BookmarksStore {
  BookmarksStore._();

  /// Max bookmarks kept per song (oldest dropped first).
  static const int maxPerSong = 10;

  /// Max songs kept in the whole table (oldest song dropped first).
  static const int maxSongs = 500;

  static Map<String, dynamic> _readMap() {
    final raw = HiveStore.box.get(HiveKeys.musicBookmarks);
    if (raw is! String || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  static Future<void> _writeMap(Map<String, dynamic> map) =>
      HiveStore.put(HiveKeys.musicBookmarks, jsonEncode(map));

  /// `m:ss` label for a position in seconds (e.g. 83 -> `1:23`).
  static String formatLabel(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// This song's bookmarks, earliest position first. Never throws;
  /// corrupt rows are skipped, a corrupt table reads as empty.
  static List<MusicBookmark> forSong(String identityKey) {
    final out = _readList(identityKey);
    out.sort((a, b) => a.position.compareTo(b.position));
    return out;
  }

  /// This song's bookmarks in stored (creation) order. [forSong]
  /// sorts by position for display; this keeps creation order so
  /// the per-song cap drops the oldest-created bookmark, not the
  /// earliest position.
  static List<MusicBookmark> _readList(String identityKey) {
    if (identityKey.isEmpty) return [];
    final raw = _readMap()[identityKey];
    if (raw is! List) return [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(MusicBookmark.fromJson)
        .whereType<MusicBookmark>()
        .toList();
  }

  static int countFor(String identityKey) => forSong(identityKey).length;

  /// Save a bookmark at [positionSec]. A bookmark at the exact same
  /// second already exists: return it, do not duplicate (a double
  /// tap must not stack two identical rows). Returns null for a bad
  /// key / negative position.
  static Future<MusicBookmark?> add(
    String identityKey,
    int positionSec,
  ) async {
    if (identityKey.isEmpty || positionSec < 0) return null;
    final map = _readMap();
    // Creation order here (not forSong's position order): the cap
    // below drops the oldest-created bookmark.
    final list = _readList(identityKey);
    final existing = list.where((b) => b.position == positionSec).firstOrNull;
    if (existing != null) return existing;
    final mark = MusicBookmark(
      position: positionSec,
      label: formatLabel(positionSec),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    list.add(mark);
    // Per-song cap: drop the oldest bookmarks first.
    while (list.length > maxPerSong) {
      list.removeAt(0);
    }
    map.remove(identityKey);
    map[identityKey] = list.map((b) => b.toJson()).toList();
    while (map.length > maxSongs) {
      map.remove(map.keys.first);
    }
    await _writeMap(map);
    return mark;
  }

  /// Delete one bookmark (matched by createdAt + position).
  static Future<void> remove(
    String identityKey,
    MusicBookmark bookmark,
  ) async {
    if (identityKey.isEmpty) return;
    final map = _readMap();
    final list = forSong(identityKey)
        .where(
          (b) =>
              !(b.createdAt == bookmark.createdAt &&
                  b.position == bookmark.position),
        )
        .toList();
    if (list.isEmpty) {
      map.remove(identityKey);
    } else {
      map[identityKey] = list.map((b) => b.toJson()).toList();
    }
    await _writeMap(map);
  }

  /// Delete all of one song's bookmarks.
  static Future<void> clear(String identityKey) async {
    if (identityKey.isEmpty) return;
    final map = _readMap();
    map.remove(identityKey);
    await _writeMap(map);
  }
}
