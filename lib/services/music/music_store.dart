// Music local store — Hive-backed, JSON values in the `app_settings` box.
//
// Mirrors the old web localStorage keys (hao_lists / hao_fav / hao_recent /
// hao_listen / hao_daily_YYYY-MM-DD) so a future import can read the same
// shape. Durations are SECONDS (audit P0-3).

import 'dart:convert';

import '../../core/storage/hive_store.dart';
import 'music_models.dart';
import 'music_quality.dart';

class MusicStore {
  MusicStore._();

  static List<Map<String, dynamic>> _readList(String key) {
    final raw = HiveStore.box.get(key) as String?;
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<Map<String, dynamic>>().toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<void> _writeList(
    String key,
    List<Map<String, dynamic>> items,
  ) =>
      HiveStore.put(key, jsonEncode(items));

  static Map<String, dynamic> _readMap(String key) {
    final raw = HiveStore.box.get(key) as String?;
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  static Future<void> _writeMap(String key, Map<String, dynamic> map) =>
      HiveStore.put(key, jsonEncode(map));

  // ---- User playlists (hao_lists, max 10 lists, max 200 tracks each) ----
  static List<UserPlaylist> getLists() =>
      _readList(HiveKeys.musicLists).map(UserPlaylist.fromJson).toList();

  static Future<void> saveLists(List<UserPlaylist> lists) => _writeList(
        HiveKeys.musicLists,
        lists.map((l) => l.toJson()).toList(),
      );

  static String get currentListId =>
      HiveStore.getString(HiveKeys.musicCurListId, '');

  static Future<void> setCurrentListId(String id) =>
      HiveStore.put(HiveKeys.musicCurListId, id);

  // ---- Favourites (hao_fav, M-P0-7) ----
  //
  // Each entry is {'key': identityKey, 'song': Song JSON}. The full
  // Song is stored so the favourites page can list songs without
  // re-resolving them. Legacy entries are key-only ({'key': k}) — they
  // still count as favourites and are resolved from recent / listen
  // history where possible; unresolvable ones are dropped from the
  // page (no fake data), never shown as blank rows.
  static List<Map<String, dynamic>> _readFavEntries() =>
      _readList(HiveKeys.musicFav);

  static Future<void> _writeFavEntries(
    List<Map<String, dynamic>> entries,
  ) =>
      _writeList(HiveKeys.musicFav, entries);

  static Set<String> getFavIds() => _readFavEntries()
      .map((m) => m['key']?.toString() ?? '')
      .where((k) => k.isNotEmpty)
      .toSet();

  static Future<void> saveFavIds(Set<String> ids) => _writeFavEntries(
        ids.map((k) => {'key': k}).toList(),
      );

  /// Favourited songs, newest first. Key-only legacy entries are
  /// resolved from recent plays / the listen log; entries that cannot
  /// be resolved to a real song are skipped.
  static List<Song> getFavSongs() {
    final entries = _readFavEntries();
    if (entries.isEmpty) return [];
    final byKey = <String, Song>{};
    for (final s in getRecent()) {
      byKey.putIfAbsent(s.identityKey, () => s);
    }
    for (final e in getListenLog()) {
      byKey.putIfAbsent(
        '${e.platform.code}|${e.songId}',
        () => Song(
          songId: e.songId,
          title: e.title,
          artist: e.artist,
          platform: e.platform,
          cover: e.cover,
          dur: e.dur,
        ),
      );
    }
    final out = <Song>[];
    final seen = <String>{};
    for (final m in entries) {
      final key = m['key']?.toString() ?? '';
      if (key.isEmpty || !seen.add(key)) continue;
      final stored = m['song'];
      if (stored is Map<String, dynamic>) {
        out.add(Song.fromJson(stored));
      } else if (byKey.containsKey(key)) {
        out.add(byKey[key]!);
      }
      // Else: legacy key with no stored song and no history — skip.
    }
    return out;
  }

  /// Toggle favourite. New favourites store the full Song JSON at the
  /// front (newest first). Returns true when the song was added.
  static Future<bool> toggleFav(Song song) async {
    final entries = _readFavEntries();
    final key = song.identityKey;
    final idx = entries.indexWhere(
      (m) => m['key']?.toString() == key,
    );
    if (idx >= 0) {
      entries.removeAt(idx);
      await _writeFavEntries(entries);
      return false;
    }
    entries.insert(0, {'key': key, 'song': song.toJson()});
    await _writeFavEntries(entries);
    return true;
  }

  // ---- Recently played (hao_recent, max 100) ----
  static List<Song> getRecent() =>
      _readList(HiveKeys.musicRecent).map(Song.fromJson).toList();

  static Future<void> addRecent(Song song) async {
    final list = getRecent()
        .where((s) => s.identityKey != song.identityKey)
        .toList();
    list.insert(0, song);
    await _writeList(
      HiveKeys.musicRecent,
      list.take(100).map((s) => s.toJson()).toList(),
    );
  }

  static Future<void> clearRecent() =>
      HiveStore.put(HiveKeys.musicRecent, '[]');

  // ---- Listen log (hao_listen, max 3000, dur in SECONDS) ----
  static List<ListenEvent> getListenLog() =>
      _readList(HiveKeys.musicListen).map(ListenEvent.fromJson).toList();

  static Future<void> recordListen(Song song) async {
    final log = getListenLog();
    log.insert(
      0,
      ListenEvent(
        songId: song.songId,
        title: song.title,
        artist: song.artist,
        platform: song.platform,
        cover: song.cover,
        dur: song.dur,
        at: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await _writeList(
      HiveKeys.musicListen,
      log.take(3000).map((e) => e.toJson()).toList(),
    );
  }

  // ---- Daily picks cache (hao_daily_YYYY-MM-DD) ----
  static List<Song>? getDaily(String dayKey) {
    final raw = HiveStore.box.get(HiveKeys.musicDailyKey(dayKey)) as String?;
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final tracks = decoded['tracks'] as List<dynamic>? ?? [];
        final songs = tracks
            .whereType<Map<String, dynamic>>()
            .map(Song.fromJson)
            .toList();
        if (songs.isEmpty) return null;
        return songs;
      }
    } catch (_) {}
    return null;
  }

  static bool getDailyCold(String dayKey) {
    final raw = HiveStore.box.get(HiveKeys.musicDailyKey(dayKey)) as String?;
    if (raw == null) return false;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> && decoded['cold'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveDaily(
    String dayKey,
    List<Song> tracks,
    bool cold,
  ) =>
      HiveStore.put(
        HiveKeys.musicDailyKey(dayKey),
        jsonEncode({
          'tracks': tracks.map((s) => s.toJson()).toList(),
          'cold': cold,
        }),
      );

  // ---- Quality preference (curQuality, default hires) ----
  static AudioQuality get quality =>
      AudioQualityX.fromCode(HiveStore.getString(HiveKeys.musicQuality, 'hires'));

  static Future<void> setQuality(AudioQuality q) =>
      HiveStore.put(HiveKeys.musicQuality, q.code);

  // ---- Plaza platform selection (fix 9: sticky) ----
  static MusicPlatform get plazaPlatform =>
      MusicPlatformX.fromCode(HiveStore.getString(HiveKeys.musicPlazaPf, 'wy'));

  static Future<void> setPlazaPlatform(MusicPlatform pf) =>
      HiveStore.put(HiveKeys.musicPlazaPf, pf.code);

  // ---- Volume / play mode ----
  static double get volume => HiveStore.getDouble(HiveKeys.musicVolume, 0.8);

  static Future<void> setVolume(double v) =>
      HiveStore.put(HiveKeys.musicVolume, v.clamp(0.0, 1.0));

  // ---- Playback speed (M-P0-2): 0.6..2.0, default 1.0 ----
  static double get speed =>
      HiveStore.getDouble(HiveKeys.musicSpeed, 1.0).clamp(0.6, 2.0);

  static Future<void> setSpeed(double v) =>
      HiveStore.put(HiveKeys.musicSpeed, v.clamp(0.6, 2.0));

  // ---- Play queue (M-P0-4): the player playlist + current index,
  // persisted so a reorder / play-next survives app restarts. ----
  static ({List<Song> songs, int index}) getQueue() {
    final raw = HiveStore.box.get(HiveKeys.musicQueue) as String?;
    if (raw == null || raw.isEmpty) return (songs: <Song>[], index: -1);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final tracks = decoded['songs'] as List<dynamic>? ?? [];
        final songs = tracks
            .whereType<Map<String, dynamic>>()
            .map(Song.fromJson)
            .toList();
        final index = (decoded['index'] as num?)?.toInt() ?? -1;
        return (
          songs: songs,
          index: (index >= 0 && index < songs.length) ? index : -1,
        );
      }
    } catch (_) {}
    return (songs: <Song>[], index: -1);
  }

  static Future<void> saveQueue(List<Song> songs, int index) =>
      HiveStore.put(
        HiveKeys.musicQueue,
        jsonEncode({
          'songs': songs.map((s) => s.toJson()).toList(),
          'index': index,
        }),
      );

  static String get playMode => HiveStore.getString(HiveKeys.musicPlayMode, 'seq');

  static Future<void> setPlayMode(String mode) =>
      HiveStore.put(HiveKeys.musicPlayMode, mode);

  // ---- Resume positions (seconds), saved ONLY on app kill (pagehide
  // equivalent — see MusicPlayerController's detached handler). ----
  static Map<String, int> getResumeMap() {
    final map = _readMap(HiveKeys.musicResume);
    final out = <String, int>{};
    map.forEach((k, v) {
      final n = (v as num?)?.toInt();
      if (n != null && n > 0) out[k] = n;
    });
    return out;
  }

  static int resumeFor(String identityKey) =>
      getResumeMap()[identityKey] ?? 0;

  static Future<void> saveResume(String identityKey, int seconds) async {
    if (seconds <= 0) return;
    final map = getResumeMap();
    map[identityKey] = seconds;
    if (map.length > 200) {
      // Drop oldest entries (insertion order is preserved by the map).
      final keys = map.keys.toList();
      for (var i = 0; i < map.length - 200; i++) {
        map.remove(keys[i]);
      }
    }
    await _writeMap(
      HiveKeys.musicResume,
      map.map((k, v) => MapEntry(k, v)),
    );
  }

  static Future<void> clearResume(String identityKey) async {
    final map = getResumeMap();
    map.remove(identityKey);
    await _writeMap(
      HiveKeys.musicResume,
      map.map((k, v) => MapEntry(k, v)),
    );
  }
}

/// Pure listen-report math (audit P0-3) — unit-tested.
///
/// Durations are stored in SECONDS. Total minutes = totalSeconds / 60.
class ListenReport {
  ListenReport({
    required this.totalPlays,
    required this.totalSeconds,
    required this.topSongs,
    required this.topArtists,
    required this.topPlatforms,
    required this.perDay,
  });

  /// Total listening time in whole minutes (seconds / 60, rounded).
  int get totalMinutes => (totalSeconds / 60).round();

  String get totalTimeText {
    final m = totalMinutes;
    if (m >= 60) return '${m ~/ 60}小时${m % 60}分';
    return '$m分钟';
  }

  final int totalPlays;
  final int totalSeconds;
  final List<TopSong> topSongs;
  final List<TopArtist> topArtists;
  final List<TopPlatform> topPlatforms;

  /// Per-day (week/month) or per-month (all) play counts, chronological.
  final List<DayCount> perDay;

  static ListenReport compute(List<ListenEvent> all, String range) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final spanMs = range == 'week'
        ? 7 * 86400000
        : range == 'month'
            ? 30 * 86400000
            : 0;
    final evs = spanMs > 0
        ? all.where((x) => now - x.at <= spanMs).toList()
        : List.of(all);
    var totalSec = 0;
    final bySong = <String, TopSong>{};
    final byArtist = <String, int>{};
    final byPlatform = <String, int>{};
    final byDay = <String, int>{};
    for (final x in evs) {
      totalSec += x.dur;
      final sk = '${x.platform.code}|${x.songId}';
      final prev = bySong[sk];
      bySong[sk] = TopSong(
        song: Song(
          songId: x.songId,
          title: x.title,
          artist: x.artist,
          platform: x.platform,
          cover: x.cover,
          dur: x.dur,
        ),
        plays: (prev?.plays ?? 0) + 1,
      );
      byArtist[x.artist.isEmpty ? '—' : x.artist] =
          (byArtist[x.artist.isEmpty ? '—' : x.artist] ?? 0) + 1;
      byPlatform[x.platform.code] =
          (byPlatform[x.platform.code] ?? 0) + 1;
      final day = DateTime.fromMillisecondsSinceEpoch(x.at)
          .toIso8601String()
          .substring(0, 10);
      byDay[day] = (byDay[day] ?? 0) + 1;
    }
    final topSongs = bySong.values.toList()
      ..sort((a, b) => b.plays.compareTo(a.plays));
    final topArtists = byArtist.entries
        .map((e) => TopArtist(artist: e.key, plays: e.value))
        .toList()
      ..sort((a, b) => b.plays.compareTo(a.plays));
    final topPlatforms = byPlatform.entries
        .map((e) => TopPlatform(platform: e.key, plays: e.value))
        .toList()
      ..sort((a, b) => b.plays.compareTo(a.plays));
    final days = <DayCount>[];
    if (range == 'all') {
      final byMonth = <String, int>{};
      for (final e in byDay.entries) {
        final m = e.key.substring(0, 7);
        byMonth[m] = (byMonth[m] ?? 0) + e.value;
      }
      final months = byMonth.keys.toList()..sort();
      for (final m in months.sublist(
          months.length > 12 ? months.length - 12 : 0)) {
        days.add(DayCount(label: m.substring(5), plays: byMonth[m] ?? 0));
      }
    } else {
      final n = range == 'week' ? 7 : 30;
      final today = DateTime.now();
      for (var i = n - 1; i >= 0; i--) {
        final d = today.subtract(Duration(days: i));
        final key = dayKeyOf(d);
        days.add(DayCount(label: key.substring(5), plays: byDay[key] ?? 0));
      }
    }
    return ListenReport(
      totalPlays: evs.length,
      totalSeconds: totalSec,
      topSongs: topSongs.take(10).toList(),
      topArtists: topArtists.take(10).toList(),
      topPlatforms: topPlatforms,
      perDay: days,
    );
  }
}

class TopSong {
  TopSong({required this.song, required this.plays});
  final Song song;
  final int plays;
}

class TopArtist {
  TopArtist({required this.artist, required this.plays});
  final String artist;
  final int plays;
}

class TopPlatform {
  TopPlatform({required this.platform, required this.plays});
  final String platform;
  final int plays;
}

class DayCount {
  DayCount({required this.label, required this.plays});
  final String label;
  final int plays;
}
