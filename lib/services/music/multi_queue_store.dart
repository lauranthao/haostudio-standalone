// Per-source queue memory (build 29, music) — 多队列 / 按专辑分组队列.
//
// One queue per source: each playlist / album / artist / daily list /
// favourites keeps its own song list + last-played position, so coming
// back to an album resumes where you left off instead of restarting
// from track 1. The controller saves the outgoing queue before it
// switches sources and restores the saved index when the same source
// is opened again with the same song order.
//
// Persistence: Hive, literal key below. HiveKeys lives in core
// storage (another group's file); this group owns the key string
// here, so no core file is touched.

import 'dart:convert';

import '../../core/storage/hive_store.dart';
import 'music_models.dart';

/// Source keys. The detail pages pass these to
/// `MusicPlayerController.playQueue(..., sourceKey: ...)`; the queue
/// panel groups the live queue by album on top of this memory.
class QueueSource {
  QueueSource._();

  static String album(String name, String artist) =>
      'album:${name.trim()}|${artist.trim()}';
  static String playlist(String id) => 'playlist:$id';
  static String artist(String name) => 'artist:${name.trim()}';
  static String daily(String dayKey) => 'daily:$dayKey';
  static const String favourites = 'favs';
}

/// One remembered queue: the songs (full Song JSON) + the index that
/// was playing when the user left the source.
class QueueMemoryEntry {
  QueueMemoryEntry({required this.songs, required this.index});

  factory QueueMemoryEntry.fromJson(Map<String, dynamic> j) {
    final raw = j['songs'] as List<dynamic>? ?? [];
    return QueueMemoryEntry(
      songs: raw
          .whereType<Map<String, dynamic>>()
          .map(Song.fromJson)
          .toList(),
      index: (j['index'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'songs': songs.map((s) => s.toJson()).toList(),
        'index': index,
      };

  final List<Song> songs;

  /// Index that was playing (clamped to the list on read).
  final int index;

  /// True when [songs] is the same list in the same order — only
  /// then is the remembered index meaningful (a changed playlist
  /// restarts from the requested track instead).
  bool matches(List<Song> other) {
    if (other.length != songs.length) return false;
    for (var i = 0; i < songs.length; i++) {
      if (songs[i].identityKey != other[i].identityKey) return false;
    }
    return true;
  }
}

class MultiQueueStore {
  /// Hive key (literal — see the file header).
  static const hiveKey = 'hao_music_queue_memory';

  /// Max sources remembered; oldest evicted first.
  static const maxSources = 10;

  /// Max songs kept per source (a playlist longer than this is
  /// still remembered — only its tail is dropped from memory).
  static const maxSongsPerSource = 200;

  final Map<String, QueueMemoryEntry> _entries = {};

  /// In-memory entries, oldest first (insertion order).
  Map<String, QueueMemoryEntry> get entries => Map.of(_entries);

  /// Load persisted memory. Best-effort: junk yields empty, never a
  /// throw — a corrupt entry must not break playback.
  void load() {
    _entries.clear();
    try {
      final raw = HiveStore.box.get(hiveKey);
      if (raw is String && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            final key = e.key.toString();
            if (key.isEmpty || e.value is! Map<String, dynamic>) continue;
            try {
              _entries[key] = QueueMemoryEntry.fromJson(e.value);
            } catch (_) {
              // One bad entry is dropped, the rest survive.
            }
          }
        }
      }
    } catch (_) {
      _entries.clear();
    }
    while (_entries.length > maxSources) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Persist the in-memory map. Best-effort, fire-and-forget safe.
  Future<void> save() async {
    try {
      await HiveStore.put(
        hiveKey,
        jsonEncode(_entries.map((k, v) => MapEntry(k, v.toJson()))),
      );
    } catch (_) {}
  }

  /// Remember [index] in [songs] for [sourceKey]. An empty key or
  /// an empty song list is ignored; the entry moves to the newest
  /// slot so eviction drops the stalest source first.
  void remember(String sourceKey, List<Song> songs, int index) {
    if (sourceKey.isEmpty || songs.isEmpty) return;
    final kept = songs.length > maxSongsPerSource
        ? songs.sublist(0, maxSongsPerSource)
        : List<Song>.of(songs);
    final clamped = index.clamp(0, kept.length - 1);
    _entries.remove(sourceKey);
    _entries[sourceKey] =
        QueueMemoryEntry(songs: kept, index: clamped);
    while (_entries.length > maxSources) {
      _entries.remove(_entries.keys.first);
    }
  }

  QueueMemoryEntry? entryFor(String sourceKey) => _entries[sourceKey];

  /// The index to resume at when [songs] is opened under
  /// [sourceKey]: the remembered index, but only when the remembered
  /// song order still matches — otherwise null (start fresh).
  int? resumeIndexFor(String sourceKey, List<Song> songs) {
    final entry = _entries[sourceKey];
    if (entry == null || !entry.matches(songs)) return null;
    return entry.index.clamp(0, songs.length - 1);
  }

  /// Forget one source (used when its queue is cleared).
  void forget(String sourceKey) {
    _entries.remove(sourceKey);
  }
}
