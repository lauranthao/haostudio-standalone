// Music local store — Hive-backed, JSON values in the `app_settings` box.
//
// Mirrors the old web localStorage keys (hao_lists / hao_fav / hao_recent /
// hao_listen / hao_daily_YYYY-MM-DD) so a future import can read the same
// shape. Durations are SECONDS (audit P0-3).

import 'dart:convert';

import '../../core/storage/hive_store.dart';
import 'music_models.dart';
import 'music_quality.dart';
import 'sleep_timer.dart';

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
  ) => HiveStore.put(key, jsonEncode(items));

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

  // ---- User playlists (hao_lists, max 10 lists, max 1000 tracks each) ----
  // Max tracks in one user playlist. Was 200 — an arbitrary cap that
  // silently dropped songs on import (chen 2026-11-17: a 500-song
  // playlist only imported 200). 1000 matches the Kuwo importer
  // (10 pages x 100) and costs ~191 KB of JSON per list (measured in
  // music_playlist_import_test.dart: 1000 songs, 190801 bytes).
  static const int maxTracksPerList = 1000;

  /// Add [incoming] songs to [list], skipping true duplicates (same
  /// platform + songId — the same title/artist in a different version
  /// has a different songId and is kept) and stopping at
  /// [maxTracksPerList]. Returns (added, dropped, dupes): dropped
  /// counts new songs that did not fit, dupes counts skipped
  /// duplicates. Never throws; callers must saveLists afterwards.
  static ({int added, int dropped, int dupes}) addTracks(
    UserPlaylist list,
    Iterable<Song> incoming,
  ) {
    final seen = list.tracks.map((t) => t.identityKey).toSet();
    var added = 0;
    var dropped = 0;
    var dupes = 0;
    for (final t in incoming) {
      // Set.add returns false when already present — covers both
      // songs already in the list and repeats within this batch.
      if (!seen.add(t.identityKey)) {
        dupes++;
        continue;
      }
      if (list.tracks.length >= maxTracksPerList) {
        dropped++;
        continue;
      }
      list.tracks.add(t);
      added++;
    }
    return (added: added, dropped: dropped, dupes: dupes);
  }

  static List<UserPlaylist> getLists() =>
      _readList(HiveKeys.musicLists).map(UserPlaylist.fromJson).toList();

  static Future<void> saveLists(List<UserPlaylist> lists) =>
      _writeList(HiveKeys.musicLists, lists.map((l) => l.toJson()).toList());

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

  static Future<void> _writeFavEntries(List<Map<String, dynamic>> entries) =>
      _writeList(HiveKeys.musicFav, entries);

  static Set<String> getFavIds() => _readFavEntries()
      .map((m) => m['key']?.toString() ?? '')
      .where((k) => k.isNotEmpty)
      .toSet();

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
    final idx = entries.indexWhere((m) => m['key']?.toString() == key);
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

  // ---- Search history (hao_music_search_hist, max 20) ----
  //
  // Mirrors VideoHistoryStore.getSearchHistory/saveSearchQuery: plain
  // query strings, newest first, dedup, cap 20. Empty queries are
  // never recorded; only terms for which a search was actually
  // started are saved (the page calls saveSearchQuery once the query
  // is trimmed and non-empty).
  static List<String> getSearchHistory() {
    final raw = HiveStore.box.get(HiveKeys.musicSearchHist);
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
      HiveKeys.musicSearchHist,
      jsonEncode(list.take(20).toList()),
    );
  }

  static Future<void> clearSearchHistory() =>
      HiveStore.put(HiveKeys.musicSearchHist, '[]');

  /// Remove one history term (Beans history chips have a per-chip ×).
  static Future<void> removeSearchQuery(String query) async {
    final list = getSearchHistory().where((e) => e != query).toList();
    await HiveStore.put(HiveKeys.musicSearchHist, jsonEncode(list));
  }

  // ---- Cover cache (hao_cover_cache, max 500) ----
  //
  // Cover URLs found by the search cover backfill (NetEase lookup for
  // coverless songs), keyed by normalised base title|artist — the same
  // key idea as backfillCovers' dedup. Covers are stable (album art
  // does not change), so no TTL; only positive results are stored, a
  // miss is retried on the next search. Cap 500, oldest dropped first.
  static Map<String, String> getCoverCache() {
    final map = _readMap(HiveKeys.musicCoverCache);
    return map.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  static Future<void> saveCover(String key, String cover) async {
    if (key.isEmpty || cover.isEmpty) return;
    final map = _readMap(HiveKeys.musicCoverCache);
    map[key] = cover;
    while (map.length > 500) {
      map.remove(map.keys.first);
    }
    await _writeMap(HiveKeys.musicCoverCache, map);
  }

  // ---- Listen log (hao_listen, max 3000, dur in SECONDS) ----
  static List<ListenEvent> getListenLog() =>
      _readList(HiveKeys.musicListen).map(ListenEvent.fromJson).toList();

  /// Persist a FINISHED listen session (real listened seconds — see
  /// ListenSessionTracker). This replaces the old recordListen(song),
  /// which wrote the song's FULL duration the moment a track started,
  /// before a second had played: skipping after 5 s still counted 4
  /// minutes, and every retry / re-open counted the full song again,
  /// so the report's total time was inflated and "not real".
  static Future<void> recordListenEvent(ListenEvent event) async {
    final log = getListenLog();
    log.insert(0, event);
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

  static Future<void> saveDaily(String dayKey, List<Song> tracks, bool cold) =>
      HiveStore.put(
        HiveKeys.musicDailyKey(dayKey),
        jsonEncode({
          'tracks': tracks.map((s) => s.toJson()).toList(),
          'cold': cold,
        }),
      );

  // ---- Quality preference (curQuality, default hires) ----
  static AudioQuality get quality => AudioQualityX.fromCode(
    HiveStore.getString(HiveKeys.musicQuality, 'hires'),
  );

  static Future<void> setQuality(AudioQuality q) =>
      HiveStore.put(HiveKeys.musicQuality, q.code);

  // ---- Plaza platform selection (fix 9: sticky) ----
  static MusicPlatform get plazaPlatform =>
      MusicPlatformX.fromCode(HiveStore.getString(HiveKeys.musicPlazaPf, 'wy'));

  static Future<void> setPlazaPlatform(MusicPlatform pf) =>
      HiveStore.put(HiveKeys.musicPlazaPf, pf.code);

  // ---- Sleep timer custom minutes (stage 2): 1..720, default 30 ----
  static int get sleepCustomMinutes =>
      clampSleepCustomMinutes(HiveStore.getInt(HiveKeys.musicSleepCustomMinutes, 30));

  static Future<void> setSleepCustomMinutes(int minutes) =>
      HiveStore.put(
        HiveKeys.musicSleepCustomMinutes,
        clampSleepCustomMinutes(minutes),
      );

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
        // An out-of-range / missing index with a non-empty queue
        // recovers to the first song: onInit copies this index into
        // currentIndex, and -1 with songs present leaves the player
        // with a queue but no current song (nothing selected, nothing
        // resumes). -1 is only meaningful for an empty queue.
        return (
          songs: songs,
          index: songs.isEmpty
              ? -1
              : (index >= 0 && index < songs.length ? index : 0),
        );
      }
    } catch (_) {}
    return (songs: <Song>[], index: -1);
  }

  static Future<void> saveQueue(List<Song> songs, int index) => HiveStore.put(
    HiveKeys.musicQueue,
    jsonEncode({
      'songs': songs.map((s) => s.toJson()).toList(),
      'index': index,
    }),
  );

  static String get playMode =>
      HiveStore.getString(HiveKeys.musicPlayMode, 'seq');

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

  static int resumeFor(String identityKey) => getResumeMap()[identityKey] ?? 0;

  static Future<void> saveResume(String identityKey, int seconds) async {
    if (seconds <= 0) return;
    final map = getResumeMap();
    // Re-saving refreshes recency: a plain map assignment keeps the
    // original insertion position, so a song resumed every day would
    // still be evicted first as "oldest". Remove-then-set moves it to
    // the end, and the cap below drops the truly-oldest entries.
    map.remove(identityKey);
    map[identityKey] = seconds;
    if (map.length > 200) {
      // Drop oldest entries (insertion order is preserved by the map).
      final keys = map.keys.toList();
      for (var i = 0; i < map.length - 200; i++) {
        map.remove(keys[i]);
      }
    }
    await _writeMap(HiveKeys.musicResume, map.map((k, v) => MapEntry(k, v)));
  }

  static Future<void> clearResume(String identityKey) async {
    final map = getResumeMap();
    map.remove(identityKey);
    await _writeMap(HiveKeys.musicResume, map.map((k, v) => MapEntry(k, v)));
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

  /// Ranges are CALENDAR ranges, matching the labels: 'week' is
  /// Monday 00:00 local to now, 'month' is the 1st 00:00 local to
  /// now, 'all' is everything. (Before v1.0.9 these were rolling
  /// 7/30 days, so "本周" wrongly included last week's days.)
  /// `now` is injectable so tests are deterministic.
  static ListenReport compute(
    List<ListenEvent> all,
    String range, {
    DateTime? now,
  }) {
    final ref = now ?? DateTime.now();
    final refDay = DateTime(ref.year, ref.month, ref.day);
    final startMs = range == 'week'
        ? refDay
              .subtract(Duration(days: ref.weekday - 1))
              .millisecondsSinceEpoch
        : range == 'month'
        ? DateTime(ref.year, ref.month, 1).millisecondsSinceEpoch
        : 0;
    final evs = startMs > 0
        ? all.where((x) => x.at >= startMs).toList()
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
          // Full song length, NOT the listened seconds: the row
          // shows this as the song's duration. Legacy events carry
          // totalDur 0, so their rows hide the duration instead of
          // showing a wrong number.
          dur: x.totalDur,
        ),
        plays: (prev?.plays ?? 0) + 1,
      );
      byArtist[x.artist.isEmpty ? '—' : x.artist] =
          (byArtist[x.artist.isEmpty ? '—' : x.artist] ?? 0) + 1;
      byPlatform[x.platform.code] = (byPlatform[x.platform.code] ?? 0) + 1;
      final day = DateTime.fromMillisecondsSinceEpoch(x.at)
          .toIso8601String()
          .substring(0, 10);
      byDay[day] = (byDay[day] ?? 0) + 1;
    }
    final topSongs = bySong.values.toList()
      ..sort((a, b) => b.plays.compareTo(a.plays));
    final topArtists =
        byArtist.entries
            .map((e) => TopArtist(artist: e.key, plays: e.value))
            .toList()
          ..sort((a, b) => b.plays.compareTo(a.plays));
    final topPlatforms =
        byPlatform.entries
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
        months.length > 12 ? months.length - 12 : 0,
      )) {
        days.add(DayCount(label: m.substring(5), plays: byMonth[m] ?? 0));
      }
    } else {
      // Calendar bars: Monday..today for a week, 1st..today for a
      // month — the same span the filter above keeps.
      final start = range == 'week'
          ? refDay.subtract(Duration(days: ref.weekday - 1))
          : DateTime(ref.year, ref.month, 1);
      for (
        var d = start;
        !d.isAfter(refDay);
        d = d.add(const Duration(days: 1))
      ) {
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

/// Accumulates REAL listened seconds for one song session (pure Dart,
/// unit-tested in music_test.dart).
///
/// The old behaviour recorded the song's full duration the moment a
/// track started, so the report's total time was the sum of full
/// durations of every song ever started — skipping after 5 s counted
/// 4 minutes, a failed load + retry counted the song twice. This
/// tracker only counts wall-clock seconds while the player reports
/// playing; pause, buffering and seeks add nothing. A session counts
/// as a play only when at least [kMinListenSeconds] were heard, so a
/// tap-through does not inflate the play count either.
class ListenSessionTracker {
  /// Minimum actually-heard seconds for a session to count as a play.
  static const int kMinListenSeconds = 5;

  Song? _song;
  DateTime? _startedAt;
  DateTime? _playingSince;
  int _seconds = 0;

  bool get hasSession => _song != null;

  /// Start a session for [song] (no time accrues until playing).
  void begin(Song song, DateTime now) {
    _song = song;
    _startedAt = now;
    _playingSince = null;
    _seconds = 0;
  }

  /// Call on every playing-state change. `now` is injected so tests
  /// are deterministic. Duplicate playing=true calls are ignored.
  void setPlaying(bool playing, DateTime now) {
    if (_song == null) return;
    if (playing) {
      _playingSince ??= now;
    } else if (_playingSince != null) {
      _seconds += now.difference(_playingSince!).inSeconds;
      _playingSince = null;
    }
  }

  /// Finish the session. Returns the event to persist, or null when
  /// less than [kMinListenSeconds] were heard. `at` is the session
  /// start, so per-day bucketing still uses when listening began.
  ListenEvent? finish(DateTime now) {
    final song = _song;
    final at = _startedAt;
    if (song == null || at == null) return null;
    setPlaying(false, now);
    final dur = _seconds;
    _song = null;
    _startedAt = null;
    _playingSince = null;
    _seconds = 0;
    if (dur < kMinListenSeconds) return null;
    return ListenEvent(
      songId: song.songId,
      title: song.title,
      artist: song.artist,
      platform: song.platform,
      cover: song.cover,
      dur: dur,
      totalDur: song.dur,
      at: at.millisecondsSinceEpoch,
    );
  }

  /// Non-destructive snapshot of the session in progress, for the
  /// report page: the song playing right now has no persisted event
  /// yet (events are only written on finish), so without this the
  /// report shows "还没有听歌记录" while a song is playing. Returns
  /// null when nothing is tracked or fewer than [kMinListenSeconds]
  /// have been heard. Does NOT close the session — the real event
  /// still lands on finish() and replaces this snapshot, so the song
  /// is never counted twice.
  ListenEvent? currentEvent(DateTime now) {
    final song = _song;
    final at = _startedAt;
    if (song == null || at == null) return null;
    var heard = _seconds;
    if (_playingSince != null) {
      heard += now.difference(_playingSince!).inSeconds;
    }
    if (heard < kMinListenSeconds) return null;
    return ListenEvent(
      songId: song.songId,
      title: song.title,
      artist: song.artist,
      platform: song.platform,
      cover: song.cover,
      dur: heard,
      totalDur: song.dur,
      at: at.millisecondsSinceEpoch,
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
