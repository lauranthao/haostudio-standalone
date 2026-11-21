import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../../core/storage/hive_store.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import 'music_player_controller.dart';

/// Local-only personal FM (私人漫游) + heartbeat mode (心动模式).
///
/// Kumone behaviour, local data only — no login anywhere. Kumone's
/// personalFM and intelligenceList both need a NetEase login, so they
/// are NOT used: seeds come from the local favourites (Hive) and
/// recent plays, and similar songs come from the public
/// single-platform search ([MusicApi.searchOne] — proven by curl:
/// NetEase cloudsearch/pc and QQ search_for_qq_cp both return real
/// songs with no login).
///
/// - 私人漫游： an endless queue. [startFM] builds an initial queue of
///   songs similar to a local seed and plays it through the existing
///   player queue ([MusicPlayerController.playQueue] — no second
///   player). A worker on the player's currentIndex refills the queue
///   whenever 3 or fewer songs remain, so playback never reaches the
///   end. [dislike] removes a song from the queue (skipping it when
///   it is the current one), records its identityKey in Hive, and
///   never recommends it again. Seeds are weighted (likes + decayed
///   plays + full-listen bonus − skip penalty), similar songs are
///   re-ranked locally, and the queue is diversity-capped (at most 3
///   songs by one artist in any 10-song window, at most 5 by one
///   artist in the whole queue).
/// - 心动模式： one weighted-random liked song as the seed; the queue
///   is [seed, ...similar] and refills like FM, anchored on the seed
///   so it stays near the seed instead of wandering. Dislike works on
///   the heartbeat queue too: the song leaves the queue and is
///   recorded, exactly like FM. (An older comment here said
///   "no dislike" — that was wrong: [dislike] never checked the mode,
///   only the refill worker was off, and it is on now.)
/// Playback resolution is unchanged: the queued songs resolve through
/// the normal per-song path (serial source asking, first playable
/// plays immediately).
class FmService {
  FmService({MusicApi? api, MusicPlayerController? player})
      : _api = api ?? MusicApi(),
        _player = player ?? MusicPlayerController.ensure() {
    _disliked = _readDisliked();
    _artistDislikeCounts = _countDislikedArtists(_disliked);
    // Index worker: refill when the queue runs short (see below).
    _indexWorker = ever(
      _player.currentIndex,
      (_) => unawaited(_onIndexChanged()),
    );
    // Queue worker: end FM the moment the queue is replaced by a
    // foreign list. Needed because playQueue can keep currentIndex
    // at the same value (first song of another list while FM is on
    // its first song), in which case the index worker never fires.
    // The service's own appends/removals never trip it: the current
    // song stays an FM song (or null mid-surgery, which is ignored).
    _queueWorker = ever(
      _player.queue,
      (_) => _checkForeign(),
    );
  }

  static FmService? _instance;

  /// App-wide singleton (same pattern as [EqualizerStore.ensure]).
  static FmService ensure() => _instance ??= FmService();

  /// Test-only: install [service] as the singleton, so widget tests
  /// can inject a fake [MusicApi]. Real HTTP never completes inside a
  /// widget test's fake-async zone (a real searchOne hangs there even
  /// though it fails fast in a plain test), so the card-tap path must
  /// be tested with a fake API — same idea as [HiveStore.setTestBox].
  @visibleForTesting
  static void setTestInstance(FmService service) {
    _instance?.dispose();
    _instance = service;
  }

  /// Test-only: drop the singleton (and its index worker) so a fresh
  /// instance re-reads Hive and re-subscribes to a fresh controller.
  @visibleForTesting
  static void resetForTest() {
    _instance?.dispose();
    _instance = null;
  }

  final MusicApi _api;
  final MusicPlayerController _player;

  /// True while a personal-FM queue is playing. Cleared when the user
  /// starts any other queue (the index worker sees a current song the
  /// FM pool did not provide) or when the queue is emptied.
  final RxBool isFM = false.obs;

  /// True while a heartbeat queue is playing. Heartbeat reuses the FM
  /// refill worker (see [_refill]); [isFM] stays false so the ⋯ menu
  /// and the FM card keep treating the two modes apart.
  final RxBool isHeartbeat = false.obs;

  /// Refill when this many songs (including the current one) remain.
  static const int refillThreshold = 3;

  /// Songs wanted per similar-songs fetch.
  static const int initialWant = 10;

  /// Songs wanted for a heartbeat queue (seed + similar).
  static const int heartbeatWant = 20;

  // -- Built-in FM tuning. No UI exposes these (no tuning UI). -----

  /// Half-life (days) for play recency: each logged play decays as
  /// 0.5^(ageDays / 14), so a song played 100 times years ago counts
  /// for almost nothing while yesterday's plays count in full.
  static const double kRecencyHalfLifeDays = 14;

  /// Recent window (days) for "least-listened artist" rotation.
  static const int kRecentWindowDays = 30;

  /// Seed weight: liked base vs unliked base (playlist-only songs
  /// are pickable, just low).
  static const double kLikedBase = 5;
  static const double kUnlikedBase = 1;

  /// Seed weight: 6 * ln(1 + decayedPlays). Log compression stops one
  /// song from monopolising the seeds.
  static const double kPlayCoef = 6;

  /// Seed weight: +0.5 per full listen (>80%), capped at +4.
  static const double kFullBonusPer = 0.5;
  static const double kFullBonusCap = 4;

  /// Seed weight: −1 per low-completion skip (<20%, ≥5 s heard).
  static const double kSkipPenalty = 1;

  /// A song skipped [kSkipExileCount] times stops being a seed.
  static const int kSkipExileCount = 3;

  /// Floor so a seed never has weight 0 unless exiled above.
  static const double kMinWeight = 0.05;

  /// Completion-rate bands (dur / totalDur, known length only).
  static const double kCompletionHigh = 0.8;
  static const double kCompletionLow = 0.2;

  /// An artist is downweighted once its consecutive-skip streak
  /// (low-completion log events + dislikes, no full listen since)
  /// reaches [kArtistPenaltyStreak]. The artist is never blacklisted.
  static const int kArtistPenaltyStreak = 3;
  static const double kArtistPenaltyFactor = 0.25;

  /// Diversity (FM only — heartbeat stays near its seed by design):
  /// at most 3 songs by one artist in any 10-song window, at most 5
  /// by one artist in the whole queue.
  static const int kMaxPerArtistWindow = 3;
  static const int kMaxPerArtistTotal = 5;

  /// Similarity points (see [similarityScore]).
  static const double kSameArtistPts = 10;
  static const double kSameAlbumPts = 8;
  static const double kYearClosePts = 4; // |Δyear| <= 2
  static const double kYearNearPts = 2; // |Δyear| <= 5
  static const int kWordOverlapCap = 4;

  /// Leg-2 (album name as a song keyword) is keyword matching, not a
  /// true album lookup — its results score half.
  static const double kAlbumLegFactor = 0.5;

  Set<String> _disliked = {};

  /// Dislikes per artist (normalised first artist), rebuilt from Hive
  /// at construction and incremented by [dislike]. A dislike counts
  /// as a skip signal for its artist; see [effectiveArtistSkipStreak].
  Map<String, int> _artistDislikeCounts = {};

  /// Heartbeat seed song: refill anchors stay on it (anti-drift).
  Song? _heartbeatSeed;

  /// Artists used as refill anchors recently (normalised names, most
  /// recent last, max 4) — rotation avoids re-anchoring the same
  /// artist refill after refill.
  final List<String> _recentRefillArtists = [];

  /// IdentityKeys of every song this service put in the queue. The
  /// workers use it to tell "still FM" from "the user started
  /// something else".
  Set<String> _fmIds = {};

  Worker? _indexWorker;
  Worker? _queueWorker;
  var _refilling = false;

  /// True while an FM or heartbeat queue is playing.
  bool get _isActive => isFM.value || isHeartbeat.value;

  /// Disliked identityKeys (read-only view, for tests).
  @visibleForTesting
  Set<String> get dislikedIds => Set.unmodifiable(_disliked);

  /// FM pool identityKeys (read-only view, for tests).
  @visibleForTesting
  Set<String> get fmIds => Set.unmodifiable(_fmIds);

  /// Test-only: put [songs] in the player queue as an FM queue
  /// (sets [_fmIds] and [isFM]) without resolving any URL, so refill
  /// / dislike tests do not wait on the network.
  @visibleForTesting
  void seedForTest(List<Song> songs, {int index = 0}) {
    _fmIds = songs.map((s) => s.identityKey).toSet();
    isFM.value = true;
    isHeartbeat.value = false;
    _player.queue.assignAll(songs);
    _player.currentIndex.value = index;
  }

  void dispose() {
    _indexWorker?.dispose();
    _indexWorker = null;
    _queueWorker?.dispose();
    _queueWorker = null;
  }

  static Set<String> _readDisliked() {
    final raw = HiveStore.box.get(HiveKeys.fmDislikedIds) as List?;
    if (raw == null) return {};
    return raw
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  /// Count disliked songs per artist, resolving each disliked key
  /// against the local pools (favourites / recent / playlists / log).
  /// Keys that resolve to no known song are ignored (conservative:
  /// an unresolvable dislike never penalises an artist).
  static Map<String, int> _countDislikedArtists(Set<String> keys) {
    if (keys.isEmpty) return {};
    final byKey = <String, Song>{};
    for (final s in [
      ...MusicStore.getFavSongs(),
      ...MusicStore.getRecent(),
      ...MusicStore.getLists().expand((l) => l.tracks),
    ]) {
      byKey.putIfAbsent(s.identityKey, () => s);
    }
    for (final e in MusicStore.getListenLog()) {
      byKey.putIfAbsent(
        '${e.platform.code}|${e.songId}',
        () => Song(
          songId: e.songId,
          title: e.title,
          artist: e.artist,
          platform: e.platform,
          dur: e.totalDur,
        ),
      );
    }
    final counts = <String, int>{};
    for (final k in keys) {
      final s = byKey[k];
      if (s == null) continue;
      final a = _artistKey(s);
      if (a.isEmpty) continue;
      counts[a] = (counts[a] ?? 0) + 1;
    }
    return counts;
  }

  // -- Pure helpers: no Hive, no network, unit-testable. -------------

  /// Normalised first-artist key ('' when unknown).
  static String _artistKey(Song s) => _artistKeyOf(s.artist);

  static String _artistKeyOf(String artist) =>
      normalizeName(firstArtist(artist));

  /// Completion rate of a listen event, or null when the full length
  /// is unknown (legacy events carry totalDur 0).
  static double? _completion(ListenEvent e) =>
      e.totalDur > 0 ? e.dur / e.totalDur : null;

  /// Aggregate [events] into per-song / per-artist stats. Pure: the
  /// same events + [nowMs] always give the same stats. [nowMs] is
  /// injectable so tests are deterministic.
  static FmListenStats aggregateListenEvents(
    List<ListenEvent> events, {
    required int nowMs,
  }) {
    const msPerDay = 86400000;
    final songEvents = <String, List<ListenEvent>>{};
    final artistEvents = <String, List<ListenEvent>>{};
    for (final e in events) {
      final sk = '${e.platform.code}|${e.songId}';
      (songEvents[sk] ??= []).add(e);
      final ak = _artistKeyOf(e.artist);
      if (ak.isNotEmpty) (artistEvents[ak] ??= []).add(e);
    }
    final bySong = <String, SeedListenStats>{};
    for (final entry in songEvents.entries) {
      var decayed = 0.0;
      var lastAt = 0;
      var full = 0;
      var skip = 0;
      for (final e in entry.value) {
        var ageDays = (nowMs - e.at) / msPerDay;
        if (ageDays < 0) ageDays = 0;
        decayed += pow(0.5, ageDays / kRecencyHalfLifeDays);
        if (e.at > lastAt) lastAt = e.at;
        final c = _completion(e);
        if (c == null) continue;
        if (c > kCompletionHigh) full++;
        if (c < kCompletionLow && e.dur >= 5) skip++;
      }
      bySong[entry.key] = SeedListenStats(
        plays: entry.value.length,
        decayedPlays: decayed,
        lastPlayedAtMs: lastAt,
        fullCount: full,
        skipCount: skip,
      );
    }
    final byArtist = <String, ArtistListenStats>{};
    for (final entry in artistEvents.entries) {
      final evs = entry.value.toList()
        ..sort((a, b) => b.at.compareTo(a.at));
      var recent = 0;
      var full = 0;
      var streak = 0;
      var streakOpen = true;
      var lastAt = 0;
      bool? newestKnownFull;
      for (final e in evs) {
        if (e.at > lastAt) lastAt = e.at;
        if (e.at <= nowMs &&
            nowMs - e.at <= kRecentWindowDays * msPerDay) {
          recent++;
        }
        final c = _completion(e);
        if (c == null) continue;
        newestKnownFull ??= c > kCompletionHigh;
        if (c > kCompletionHigh) {
          full++;
          streakOpen = false;
        } else if (c < kCompletionLow && e.dur >= 5) {
          if (streakOpen) streak++;
        }
      }
      byArtist[entry.key] = ArtistListenStats(
        plays: evs.length,
        recentPlays: recent,
        lastPlayedAtMs: lastAt,
        fullCount: full,
        skipStreak: streak,
        newestIsFull: newestKnownFull ?? false,
      );
    }
    return FmListenStats(bySong: bySong, byArtist: byArtist);
  }

  /// Seed weight: liked base + log-compressed decayed plays +
  /// full-listen bonus − skip penalty, times the artist factor.
  /// A song skipped [kSkipExileCount] times scores 0 — it stops
  /// being a seed. A song with no log at all still scores its base
  /// (playlist-only songs are naturally low, never excluded).
  static double seedWeight({
    required bool liked,
    SeedListenStats? listen,
    double artistFactor = 1,
  }) {
    final skip = listen?.skipCount ?? 0;
    if (skip >= kSkipExileCount) return 0;
    var w = liked ? kLikedBase : kUnlikedBase;
    w += kPlayCoef * log(1 + (listen?.decayedPlays ?? 0));
    w += (kFullBonusPer * (listen?.fullCount ?? 0)).clamp(
      0,
      kFullBonusCap,
    );
    w -= kSkipPenalty * skip;
    w *= artistFactor;
    return w < kMinWeight ? kMinWeight : w;
  }

  /// Artist downweight factor for a consecutive-skip streak:
  /// quartered at 3+, untouched below.
  static double artistPenaltyFactor(int skipStreak) =>
      skipStreak >= kArtistPenaltyStreak ? kArtistPenaltyFactor : 1;

  /// Effective consecutive-skip streak for an artist: the log's
  /// leading low-completion streak plus dislikes of that artist.
  /// A recent full listen of the artist resets it — the dislikes are
  /// then stale, not "consecutive" any more. With no log at all the
  /// streak is just the dislike count.
  static int effectiveArtistSkipStreak({
    required ArtistListenStats? log,
    required int dislikeCount,
  }) {
    if (log == null) return dislikeCount;
    if (log.newestIsFull) return 0;
    return log.skipStreak + dislikeCount;
  }

  /// Local similarity score of [candidate] against [seed], using only
  /// signals that exist locally: same artist, same album, year
  /// closeness (only when both years are known — search results
  /// usually carry albumYear 0, which simply scores nothing),
  /// title/album word overlap. Leg-2 (album name as a song keyword)
  /// scores half: it is keyword matching, not a true album lookup.
  /// No genre / mood / style is invented — the local model has none.
  /// [artistFactor] is 1 normally, [kArtistPenaltyFactor] for a
  /// skip-streaked artist.
  static double similarityScore({
    required Song seed,
    required Song candidate,
    required int legIndex,
    double artistFactor = 1,
  }) {
    var score = 0.0;
    final seedArtist = firstArtist(seed.artist);
    final candArtist = firstArtist(candidate.artist);
    if (seedArtist.isNotEmpty &&
        normalizeName(seedArtist) == normalizeName(candArtist)) {
      score += kSameArtistPts;
    }
    if (seed.album.isNotEmpty &&
        candidate.album.isNotEmpty &&
        normalizeName(seed.album) == normalizeName(candidate.album)) {
      score += kSameAlbumPts;
    }
    if (seed.albumYear > 0 && candidate.albumYear > 0) {
      final d = (seed.albumYear - candidate.albumYear).abs();
      if (d <= 2) {
        score += kYearClosePts;
      } else if (d <= 5) {
        score += kYearNearPts;
      }
    }
    score += _wordOverlapPoints(seed, candidate).toDouble();
    final legFactor = legIndex == 1 ? kAlbumLegFactor : 1.0;
    return score * legFactor * artistFactor;
  }

  static int _wordOverlapPoints(Song seed, Song candidate) {
    final a = _wordTokens('${seed.title} ${seed.album}');
    final b = _wordTokens('${candidate.title} ${candidate.album}');
    var n = 0;
    for (final t in a) {
      if (b.contains(t)) n++;
    }
    return n > kWordOverlapCap ? kWordOverlapCap : n;
  }

  /// Word tokens: ASCII words + single CJK characters (Chinese
  /// titles have no spaces to split on).
  static Set<String> _wordTokens(String s) {
    final out = <String>{};
    for (final m in RegExp(
      r'[a-z0-9]+|[\u4e00-\u9fff]',
    ).allMatches(s.toLowerCase())) {
      out.add(m.group(0)!);
    }
    return out;
  }

  /// Cross-platform same-recording key: normalised base title +
  /// first artist. The wy and tx versions of one recording share it,
  /// so they can never both enter a queue.
  @visibleForTesting
  static String recordingKey(Song s) =>
      '${normalizeName(baseTitleRaw(s.title))}|${normalizeName(firstArtist(s.artist))}';

  /// One weighted draw: returns the picked index, or -1 when every
  /// weight is <= 0. Pure given [random].
  @visibleForTesting
  static int weightedPickIndex(List<double> weights, Random random) {
    var total = 0.0;
    for (final w in weights) {
      if (w > 0) total += w;
    }
    if (total <= 0) return -1;
    var r = random.nextDouble() * total;
    for (var i = 0; i < weights.length; i++) {
      final w = weights[i];
      if (w <= 0) continue;
      r -= w;
      if (r <= 0) return i;
    }
    return weights.lastIndexWhere((w) => w > 0);
  }

  /// Weighted shuffle (Efraimidis–Spirakis): key = rand^(1/w), sort
  /// desc. P(item first) = w / Σw exactly. Items with w <= 0 are
  /// dropped. Pure given [random].
  @visibleForTesting
  static List<T> weightedShuffle<T>(
    List<T> items,
    List<double> weights,
    Random random,
  ) {
    final scored = <({T item, double key})>[];
    for (var i = 0; i < items.length; i++) {
      final w = weights[i];
      if (w <= 0) continue;
      final r = random.nextDouble();
      scored.add((item: items[i], key: pow(r, 1 / w).toDouble()));
    }
    scored.sort((a, b) => b.key.compareTo(a.key));
    return scored.map((e) => e.item).toList();
  }

  /// Append [songs] to [queue] honouring the FM diversity caps: at
  /// most [kMaxPerArtistWindow] by one artist in any 10-song window
  /// and [kMaxPerArtistTotal] by one artist in the whole queue.
  /// Songs with no artist are never capped (nothing to group them
  /// by). Returns the appended songs.
  @visibleForTesting
  static List<Song> diverseAppend(List<Song> queue, List<Song> songs) {
    final appended = <Song>[];
    final total = <String, int>{};
    for (final s in queue) {
      final a = _diversityKey(s);
      total[a] = (total[a] ?? 0) + 1;
    }
    for (final s in songs) {
      final a = _diversityKey(s);
      if (a.startsWith('song:')) {
        appended.add(s);
        continue;
      }
      if ((total[a] ?? 0) >= kMaxPerArtistTotal) continue;
      // Window = the last 9 songs of (queue + appended). NOTE: do
      // NOT write `queue + appended` — GetX RxList's `+` mutates the
      // receiver (it appends `other` in place and returns the same
      // list), which duplicated songs into the player queue. Index
      // into the two lists instead.
      final combinedLen = queue.length + appended.length;
      final windowStart = combinedLen - 9 < 0 ? 0 : combinedLen - 9;
      var inWindow = 0;
      for (var i = windowStart; i < combinedLen; i++) {
        final w = i < queue.length ? queue[i] : appended[i - queue.length];
        if (_diversityKey(w) == a) inWindow++;
      }
      if (inWindow >= kMaxPerArtistWindow) continue;
      appended.add(s);
      total[a] = (total[a] ?? 0) + 1;
    }
    queue.addAll(appended);
    return appended;
  }

  static String _diversityKey(Song s) {
    final a = _artistKey(s);
    return a.isEmpty ? 'song:${s.identityKey}' : 'artist:$a';
  }

  // -- Service internals ------------------------------------------------

  double _artistFactorFor(Song s, FmListenStats stats) {
    final a = _artistKey(s);
    if (a.isEmpty) return 1;
    final streak = effectiveArtistSkipStreak(
      log: stats.byArtist[a],
      dislikeCount: _artistDislikeCounts[a] ?? 0,
    );
    return artistPenaltyFactor(streak);
  }

  /// Songs similar to [seed], most similar first: same artist on the
  /// seed's platform, then same album, then the same artist on the
  /// other main platform (wy <-> tx). The seed itself, duplicates and
  /// disliked songs are dropped. A failed leg contributes nothing and
  /// never blocks the others.
  ///
  /// The three legs are still the recall; the fetched pool is then
  /// re-ranked by [similarityScore] (same artist / album / year /
  /// word overlap), cross-platform recordings are deduped, and
  /// skip-streaked artists score a quarter. Legs are fetched lazily:
  /// the common case (first leg fills [want] with no penalised
  /// artist dominating) still costs one search; a further leg is only
  /// fetched when the top-[want] is short or dominated by a penalised
  /// artist, so its unpenalised candidates can outrank them.
  /// [exclude] (usually the already-queued keys) lets a refill dig
  /// deeper into a leg's 20 results instead of re-offering the same
  /// first 10.
  Future<List<Song>> similarSongs(
    Song seed, {
    int want = 10,
    Set<String> exclude = const {},
  }) async {
    final stats = aggregateListenEvents(
      MusicStore.getListenLog(),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    final pool = <_ScoredSong>[];
    var order = 0;
    void addLeg(List<Song> songs, int leg) {
      for (final s in songs) {
        if (s.title.isEmpty || s.songId.isEmpty) continue;
        pool.add(
          _ScoredSong(
            song: s,
            score: similarityScore(
              seed: seed,
              candidate: s,
              legIndex: leg,
              artistFactor: _artistFactorFor(s, stats),
            ),
            order: order++,
          ),
        );
      }
    }

    final artist = firstArtist(seed.artist);
    final legs = <({MusicPlatform pf, String q, int leg})>[];
    if (artist.isNotEmpty) {
      legs.add((pf: seed.platform, q: artist, leg: 0));
    }
    if (seed.album.isNotEmpty) {
      legs.add((pf: seed.platform, q: seed.album, leg: 1));
    }
    if (artist.isNotEmpty) {
      final other = seed.platform == MusicPlatform.wy
          ? MusicPlatform.tx
          : MusicPlatform.wy;
      legs.add((pf: other, q: artist, leg: 2));
    }
    for (var i = 0; i < legs.length; i++) {
      addLeg(await _safeSearch(legs[i].pf, legs[i].q), legs[i].leg);
      final selected = _selectTop(pool, seed, want, exclude);
      if (selected.length >= want &&
          _penalisedCount(selected, stats) <= _maxPenalisedInTop(want)) {
        return selected;
      }
    }
    return _selectTop(pool, seed, want, exclude);
  }

  /// Penalised artists allowed in a top-[want] selection (30%).
  static int _maxPenalisedInTop(int want) => (want * 0.3).ceil();

  int _penalisedCount(List<Song> songs, FmListenStats stats) {
    var n = 0;
    for (final s in songs) {
      if (_artistFactorFor(s, stats) < 1) n++;
    }
    return n;
  }

  /// Top-[want] of [pool] by score (insertion order breaks ties),
  /// dropping the seed, identity duplicates, cross-platform
  /// recordings of one song, disliked songs and [exclude].
  List<Song> _selectTop(
    List<_ScoredSong> pool,
    Song seed,
    int want,
    Set<String> exclude,
  ) {
    final ranked = pool.toList()
      ..sort((a, b) {
        final c = b.score.compareTo(a.score);
        return c != 0 ? c : a.order.compareTo(b.order);
      });
    final out = <Song>[];
    final seenKeys = <String>{seed.identityKey};
    final seenRecordings = <String>{recordingKey(seed)};
    for (final entry in ranked) {
      if (out.length >= want) break;
      final s = entry.song;
      if (!seenKeys.add(s.identityKey)) continue;
      if (!seenRecordings.add(recordingKey(s))) continue;
      if (_disliked.contains(s.identityKey)) continue;
      if (exclude.contains(s.identityKey)) continue;
      out.add(s);
    }
    return out;
  }

  Future<List<Song>> _safeSearch(MusicPlatform pf, String q) async {
    try {
      return await _api.searchOne(pf, q);
    } catch (_) {
      return [];
    }
  }

  /// Local seeds in weighted-random order: favourites + recent plays
  /// + user-playlist tracks, deduplicated, disliked dropped. The
  /// order IS the draw (see [weightedShuffle]) — a song played 100
  /// times outweighs a once-liked song, recent plays outweigh old
  /// ones (14-day half-life), and a song skipped 3 times is gone
  /// from the seeds entirely. Playlist-only songs score their base
  /// and stay pickable, just low.
  List<Song> _localSeeds() {
    final favIds = MusicStore.getFavIds();
    final stats = aggregateListenEvents(
      MusicStore.getListenLog(),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    final seen = <String>{};
    final songs = <Song>[];
    final weights = <double>[];
    for (final s in [
      ...MusicStore.getFavSongs(),
      ...MusicStore.getRecent(),
      ...MusicStore.getLists().expand((l) => l.tracks),
    ]) {
      if (_disliked.contains(s.identityKey)) continue;
      if (!seen.add(s.identityKey)) continue;
      final w = seedWeight(
        liked: favIds.contains(s.identityKey),
        listen: stats.bySong[s.identityKey],
        artistFactor: _artistFactorFor(s, stats),
      );
      if (w <= 0) continue;
      songs.add(s);
      weights.add(w);
    }
    return weightedShuffle(songs, weights, Random());
  }

  /// Weighted-best favourite (heartbeat seed). Falls back to a plain
  /// random favourite when every favourite is exiled by skips.
  Song _weightedFavSeed(List<Song> favs, FmListenStats stats) {
    final weights = favs
        .map(
          (s) => seedWeight(
            liked: true,
            listen: stats.bySong[s.identityKey],
            artistFactor: _artistFactorFor(s, stats),
          ),
        )
        .toList();
    final ordered = weightedShuffle(favs, weights, Random());
    if (ordered.isNotEmpty) return ordered.first;
    return favs[Random().nextInt(favs.length)];
  }

  /// A weighted seed from an artist not in [excludeArtists]
  /// (falling back to any weighted seed), skipping artists used as
  /// refill anchors recently. [seeds] is already in weighted order.
  Song? _pickRotatedSeed(
    List<Song> seeds,
    Set<String> excludeArtists,
  ) {
    if (seeds.isEmpty) return null;
    final pool = seeds.where((s) {
      final a = _artistKey(s);
      return a.isEmpty || !excludeArtists.contains(a);
    }).toList();
    final list = pool.isEmpty ? seeds : pool;
    for (final s in list) {
      final a = _artistKey(s);
      if (a.isEmpty || !_recentRefillArtists.contains(a)) {
        if (a.isNotEmpty) {
          _recentRefillArtists.add(a);
          while (_recentRefillArtists.length > 4) {
            _recentRefillArtists.removeAt(0);
          }
        }
        return s;
      }
    }
    return list.first;
  }

  /// The seed whose artist was listened to least in the last 30 days
  /// (ties: first in weighted order). Null when there are no seeds.
  Song? _leastListenedSeed(List<Song> seeds) {
    if (seeds.isEmpty) return null;
    final stats = aggregateListenEvents(
      MusicStore.getListenLog(),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    Song? best;
    var bestPlays = 1 << 30;
    for (final s in seeds) {
      final plays = stats.byArtist[_artistKey(s)]?.recentPlays ?? 0;
      if (plays < bestPlays) {
        bestPlays = plays;
        best = s;
      }
    }
    return best;
  }

  /// FM anchors after the primary one: a rotated weighted seed, then
  /// the least-listened-artist seed.
  List<Song> _fmAnchors({
    required List<Song> seeds,
    Set<String> excludeArtists = const {},
  }) {
    final out = <Song>[];
    final rotated = _pickRotatedSeed(seeds, excludeArtists);
    if (rotated != null) out.add(rotated);
    final least = _leastListenedSeed(seeds);
    if (least != null) out.add(least);
    return out;
  }

  /// Heartbeat refill anchors, all near the seed: the seed itself,
  /// then liked songs by the same artist, then liked songs from the
  /// same album.
  List<Song> _heartbeatAnchors() {
    final seed = _heartbeatSeed;
    if (seed == null) return const [];
    final favs = MusicStore.getFavSongs()
        .where((s) => !_disliked.contains(s.identityKey))
        .toList();
    final seedArtist = _artistKey(seed);
    final out = <Song>[seed];
    for (final s in favs) {
      if (out.length >= 4) break;
      if (s.identityKey == seed.identityKey) continue;
      if (seedArtist.isNotEmpty && _artistKey(s) == seedArtist) {
        out.add(s);
      }
    }
    for (final s in favs) {
      if (out.length >= 5) break;
      if (out.any((o) => o.identityKey == s.identityKey)) continue;
      if (seed.album.isNotEmpty &&
          s.album.isNotEmpty &&
          normalizeName(s.album) == normalizeName(seed.album)) {
        out.add(s);
      }
    }
    return out;
  }

  /// Try [anchors] in order, appending diversity-admissible fresh
  /// songs until [queue] reaches [target] or anchors run out.
  /// Returns the appended songs (callers add their keys to [_fmIds]).
  Future<List<Song>> _fillFromAnchors(
    List<Song> queue,
    List<Song> anchors,
    int target,
  ) async {
    final appended = <Song>[];
    final seenAnchors = <String>{};
    for (final anchor in anchors) {
      if (queue.length >= target) break;
      if (!seenAnchors.add(anchor.identityKey)) continue;
      final more = await similarSongs(
        anchor,
        want: target - queue.length,
        exclude: queue.map((s) => s.identityKey).toSet(),
      );
      appended.addAll(diverseAppend(queue, more));
    }
    return appended;
  }

  /// Start personal FM. Returns false when there are no local seeds
  /// at all (no favourites and no recent plays) — the caller shows
  /// the "collect some songs first" prompt instead of failing
  /// silently. Otherwise the FM queue is playing when this returns.
  Future<bool> startFM() async {
    final seeds = _localSeeds();
    if (seeds.isEmpty) return false;
    // Try the first few (weighted-best) seeds until one yields
    // similar songs; the fetch is serial (one artist search at a time).
    final queue = <Song>[];
    for (final seed in seeds.take(3)) {
      final similar = await similarSongs(
        seed,
        want: initialWant,
        exclude: queue.map((s) => s.identityKey).toSet(),
      );
      if (similar.isEmpty) continue;
      diverseAppend(queue, similar);
      // Top the queue up from rotated anchors (other artists) so
      // the first screen is already diverse instead of one artist.
      await _fillFromAnchors(
        queue,
        _fmAnchors(seeds: seeds, excludeArtists: {_artistKey(seed)}),
        initialWant,
      );
      break;
    }
    // Offline or no similar songs anywhere: play the seeds
    // themselves, so FM still starts when seeds exist.
    final finalQueue = queue.isNotEmpty ? queue : seeds;
    _fmIds = finalQueue.map((s) => s.identityKey).toSet();
    isFM.value = true;
    isHeartbeat.value = false;
    await _player.playQueue(finalQueue, 0, label: '私人漫游');
    return true;
  }

  /// Start heartbeat mode. Returns false when there are no liked
  /// songs — the caller shows the "collect some songs first" prompt.
  /// The queue is [seed, ...similar] and refills like FM (see
  /// [_refill]), anchored on the seed so it stays near the seed
  /// instead of wandering. Dislike works on the heartbeat queue:
  /// the song leaves the queue and is recorded, exactly like FM.
  Future<bool> startHeartbeat() async {
    final favs = MusicStore.getFavSongs()
        .where((s) => !_disliked.contains(s.identityKey))
        .toList();
    if (favs.isEmpty) return false;
    final stats = aggregateListenEvents(
      MusicStore.getListenLog(),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    final seed = _weightedFavSeed(favs, stats);
    final similar = await similarSongs(seed, want: heartbeatWant);
    _heartbeatSeed = seed;
    _fmIds = {seed.identityKey, ...similar.map((s) => s.identityKey)};
    isFM.value = false;
    isHeartbeat.value = true;
    await _player.playQueue([seed, ...similar], 0, label: '心动模式');
    return true;
  }

  /// "不喜欢": never recommend [song] again, and take it out of the
  /// queue. When it is the current song playback skips to the next
  /// one (or, when it was the last one, refills first and plays the
  /// first fresh song). Safe to call for a song that is not queued
  /// (only the Hive record is added). A dislike also counts as a skip
  /// signal for the song's artist: 3 consecutive skips of one artist
  /// (dislikes + low-completion plays, no full listen since) quarter
  /// that artist's weight — the artist itself is never blacklisted.
  Future<void> dislike(Song song) async {
    final key = song.identityKey;
    if (_disliked.add(key)) {
      final a = _artistKey(song);
      if (a.isNotEmpty) {
        _artistDislikeCounts[a] = (_artistDislikeCounts[a] ?? 0) + 1;
      }
      await HiveStore.put(HiveKeys.fmDislikedIds, _disliked.toList());
    }
    _fmIds.remove(key);
    final queue = _player.queue;
    final idx = queue.indexWhere((s) => s.identityKey == key);
    if (idx < 0) return;
    final current = _player.currentIndex.value;
    final wasCurrent = idx == current;
    queue.removeAt(idx);
    if (queue.isEmpty) {
      isFM.value = false;
      isHeartbeat.value = false;
      await _player.pause();
      return;
    }
    if (wasCurrent) {
      if (idx >= queue.length) {
        // It was the last song: pause, refill, then play the first
        // fresh song (it lands at the removed song's index).
        final before = queue.length;
        await _player.pause();
        await _refill(anchor: song);
        if (_player.queue.length > before) {
          await _player.playIndex(before);
        } else {
          isFM.value = false;
          isHeartbeat.value = false;
        }
      } else {
        // The next song slid into the removed song's slot.
        await _player.playIndex(idx);
      }
    } else if (idx < current) {
      // The queue shifted before the current song: keep the index
      // pointing at the same song.
      _player.currentIndex.value = current - 1;
    }
  }

  /// End FM when the current song is not one this service queued
  /// (the user started a different list). A null current song is
  /// ignored: it happens mid-surgery (dislike removing the last song
  /// leaves the index briefly past the end before the refill lands).
  void _checkForeign() {
    if (!_isActive) return;
    final song = _player.currentSong;
    if (song == null) return;
    if (!_fmIds.contains(song.identityKey)) {
      isFM.value = false;
      isHeartbeat.value = false;
    }
  }

  Future<void> _onIndexChanged() async {
    if (!_isActive) return;
    final song = _player.currentSong;
    if (song == null) {
      isFM.value = false;
      isHeartbeat.value = false;
      return;
    }
    if (!_fmIds.contains(song.identityKey)) {
      // The user started a different queue: FM is over.
      isFM.value = false;
      isHeartbeat.value = false;
      return;
    }
    final remaining = _player.queue.length - _player.currentIndex.value;
    if (remaining > refillThreshold) return;
    await _refill(anchor: song);
  }

  /// Append fresh similar songs to the queue.
  ///
  /// FM: rotate anchors — current song, last queued song, a weighted
  /// seed from another artist, the least-listened artist's seed —
  /// until the queue is topped up by [initialWant], with the
  /// diversity caps applied on append.
  ///
  /// Heartbeat: anchor stays on the seed (plus same-artist /
  /// same-album favourites), no diversity caps — staying near the
  /// seed IS the point.
  Future<void> _refill({required Song anchor}) async {
    if (_refilling || !_isActive) return;
    _refilling = true;
    try {
      final queue = _player.queue;
      if (isHeartbeat.value) {
        for (final candidate in _heartbeatAnchors()) {
          if (!_isActive) return;
          final more = await similarSongs(
            candidate,
            want: initialWant,
            exclude: queue.map((s) => s.identityKey).toSet(),
          );
          final fresh = more
              .where(
                (s) => !queue.any((q) => q.identityKey == s.identityKey),
              )
              .toList();
          if (fresh.isEmpty) continue;
          _fmIds.addAll(fresh.map((s) => s.identityKey));
          queue.addAll(fresh);
          return;
        }
        return;
      }
      final seeds = _localSeeds();
      final anchors = <Song>[anchor];
      if (queue.isNotEmpty &&
          queue.last.identityKey != anchor.identityKey) {
        anchors.add(queue.last);
      }
      anchors.addAll(
        _fmAnchors(
          seeds: seeds,
          excludeArtists: {
            _artistKey(anchor),
            if (queue.isNotEmpty) _artistKey(queue.last),
          },
        ),
      );
      final appended = await _fillFromAnchors(
        queue,
        anchors,
        queue.length + initialWant,
      );
      _fmIds.addAll(appended.map((s) => s.identityKey));
    } finally {
      _refilling = false;
    }
  }
}

/// Per-song listen aggregate, built from [ListenEvent]s (see
/// [FmService.aggregateListenEvents]).
class SeedListenStats {
  const SeedListenStats({
    this.plays = 0,
    this.decayedPlays = 0,
    this.lastPlayedAtMs = 0,
    this.fullCount = 0,
    this.skipCount = 0,
  });

  /// Raw play count.
  final int plays;

  /// Σ 0.5^(ageDays / halfLife) over the song's plays.
  final double decayedPlays;

  final int lastPlayedAtMs;

  /// Events heard to >80% (completion known).
  final int fullCount;

  /// Events cut at <20% with ≥5 s heard.
  final int skipCount;
}

/// Per-artist listen aggregate.
class ArtistListenStats {
  const ArtistListenStats({
    this.plays = 0,
    this.recentPlays = 0,
    this.lastPlayedAtMs = 0,
    this.fullCount = 0,
    this.skipStreak = 0,
    this.newestIsFull = false,
  });

  final int plays;

  /// Plays in the last 30 days.
  final int recentPlays;

  final int lastPlayedAtMs;

  /// Full listens (>80%).
  final int fullCount;

  /// Leading low-completion events, newest first, until the first
  /// full listen (unknown-completion events are skipped over).
  final int skipStreak;

  /// True when the newest known-completion event is a full listen.
  final bool newestIsFull;
}

/// [FmService.aggregateListenEvents] output.
class FmListenStats {
  const FmListenStats({required this.bySong, required this.byArtist});

  /// Key: 'platform|songId'.
  final Map<String, SeedListenStats> bySong;

  /// Key: normalised first artist.
  final Map<String, ArtistListenStats> byArtist;
}

class _ScoredSong {
  _ScoredSong({
    required this.song,
    required this.score,
    required this.order,
  });

  final Song song;
  final double score;

  /// Insertion order (leg order, then search order) — breaks ties.
  final int order;
}
