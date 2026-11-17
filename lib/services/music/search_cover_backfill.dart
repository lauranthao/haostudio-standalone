// Search-result cover backfill: Kuwo (14/15 songs coverless, measured
// 2026-11-17) and Kugou (no cover field at all) leave most search rows
// on the grey note placeholder. Same-batch backfillCovers can only copy
// a cover when the same song is also in another leg's results — for a
// Kuwo-first list it usually is not (Kuwo's "张学友" top 15 shares only
// 1 title with NetEase's top 20). So coverless visible rows get their
// cover from NetEase ("加一个源", chen 2026-11-17): one serial searchWy
// lookup per song, title+artist, first title+artist match wins.
// LX model, serial: one song at a time, no fan-out.
//
// Results display first — the list never waits for covers. Covers pop
// in as they arrive (callback per song). Only the current page's
// visible rows are looked up, never the whole list. A new search
// abandons the old run (generation guard). Failures/timeouts leave the
// placeholder and never touch the list. Found covers land in the
// in-memory + Hive cover cache (keyed by normalised base title|artist),
// so the same song is never looked up twice. A reorder mid-lookup
// does not lose the cover: a newer fill takes over the in-flight
// lookup's delivery (see [_waiters] in [_run]) instead of starting
// a duplicate lookup or waiting for the next emission.
import 'dart:async';

import 'music_api.dart';
import 'music_models.dart';
import 'music_store.dart';

class SearchCoverBackfill {
  SearchCoverBackfill({
    MusicApi? api,
    this.lookupTimeout = const Duration(seconds: 3),
  }) : _api = api ?? MusicApi();

  /// How many leading songs to fill (the current page's visible rows).
  static const _maxSongs = 20;

  /// NetEase candidates scanned per song (first title+artist match wins).
  static const _candidates = 5;

  final MusicApi _api;

  /// One lookup may not hold the serial queue longer than this.
  final Duration lookupTimeout;
  int _gen = 0;
  final _inFlight = <String>{};
  // Callbacks waiting for an in-flight lookup, keyed by cover key.
  // A newer fill() for a song already being looked up registers its
  // delivery here instead of starting a duplicate lookup; when the
  // in-flight lookup finishes, the found cover is handed to the
  // current run (not to the abandoned run that started it). Each
  // waiter closes over its own run's Song, so the delivery merges
  // by the right identityKey on the page. If nobody is waiting
  // (cancelled, no new fill), the result is dropped as before — but
  // it stays in [_cache]/Hive for the next applyCached.
  final _waiters = <String, List<void Function(String cover)>>{};
  final _cache = <String, String>{};
  final _misses = <String>{};
  var _cacheLoaded = false;

  /// Cover-cache key: normalised base title + artist — the same key
  /// idea as backfillCovers' dedup.
  static String coverKey(Song s) =>
      '${baseSongTitle(s.title)}|${normalizeName(s.artist)}';

  void _ensureCacheLoaded() {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      _cache.addAll(MusicStore.getCoverCache());
    } catch (_) {
      // Hive not ready (plain unit tests): in-memory only.
    }
  }

  /// Synchronous cache application: fill covers already known (this
  /// session's lookups or Hive) into [songs]. Pure, no network — the
  /// page applies it to every streaming update so a filled cover
  /// survives the next re-emission.
  List<Song> applyCached(List<Song> songs) {
    _ensureCacheLoaded();
    if (_cache.isEmpty) return songs;
    var changed = false;
    final out = songs.map((s) {
      if (s.cover.isNotEmpty) return s;
      final cover = _cache[coverKey(s)];
      if (cover == null || cover.isEmpty) return s;
      changed = true;
      return s.copyWith(cover: cover);
    }).toList();
    return changed ? out : songs;
  }

  /// Fill empty covers of the first [_maxSongs] songs in [songs],
  /// serially. Calls [onSong] once per song whose cover was found.
  /// Fire-and-forget: never throws.
  void fill(List<Song> songs, void Function(Song song) onSong) {
    final gen = ++_gen;
    final targets = songs.take(_maxSongs).toList();
    if (targets.isEmpty) return;
    _run(gen, targets, onSong);
  }

  /// Abandon the current run (new search / dispose). In-flight
  /// lookups finish on their own; the generation check keeps the
  /// abandoned run from starting any further song or delivering.
  /// [_inFlight] is deliberately NOT cleared: a new fill for the same
  /// song skips it while the old lookup is still running — but that
  /// new fill registers its callback in [_waiters], so the old
  /// lookup's result is handed over instead of lost (see [_run]).
  /// Waiters are cleared here: after a cancel, nobody is waiting,
  /// so a late result is dropped, never delivered to a dead list.
  void cancel() {
    _gen++;
    _waiters.clear();
  }

  Future<void> _run(
    int gen,
    List<Song> targets,
    void Function(Song song) onSong,
  ) async {
    _ensureCacheLoaded();
    for (final song in targets) {
      if (gen != _gen) return;
      if (song.cover.isNotEmpty) continue;
      final key = coverKey(song);
      final cached = _cache[key];
      if (cached != null && cached.isNotEmpty) {
        onSong(song.copyWith(cover: cached));
        continue;
      }
      if (_misses.contains(key)) continue;
      if (_inFlight.contains(key)) {
        // Reorder/re-emission mid-lookup: the new run must NOT start
        // a duplicate lookup, but it must NOT lose the song either.
        // Take over the in-flight lookup's delivery instead — the
        // old run hands the found cover to this callback when its
        // lookup finishes (see below). Registration is synchronous
        // in this loop pass, so it always lands before the pending
        // lookup can complete.
        _waiters.putIfAbsent(key, () => []).add(
          (cover) => onSong(song.copyWith(cover: cover)),
        );
        continue;
      }
      _inFlight.add(key);
      try {
        final cover = await _lookupCover(song).timeout(
          lookupTimeout,
          onTimeout: () => '',
        );
        if (cover.isEmpty) {
          _misses.add(key);
          continue;
        }
        _cache[key] = cover;
        try {
          unawaited(MusicStore.saveCover(key, cover));
        } catch (_) {}
        if (gen != _gen) {
          // Abandoned mid-lookup. The cover is already in [_cache]
          // and Hive, but that alone does not reach the list — the
          // new run already passed this song (it was in-flight, so
          // it skipped it) and there may be no next emission or
          // scroll to applyCached it. Hand the cover to the current
          // run if it took over this song; if nobody did (cancelled
          // with no new fill), drop it — the page's own generation
          // check and this guard keep a stale delivery out.
          final waiters = _waiters.remove(key);
          if (waiters != null) {
            for (final deliver in waiters) {
              deliver(cover);
            }
          }
          return;
        }
        onSong(song.copyWith(cover: cover));
      } catch (_) {
        _misses.add(key);
      } finally {
        _inFlight.remove(key);
        _waiters.remove(key);
      }
    }
  }

  /// NetEase lookup: search "base title + first artist", take the
  /// first candidate whose base title matches AND whose artist
  /// overlaps (or is 群星 for a multi-singer song). The first result
  /// alone is NOT trusted: measured 2026-11-17, "季候风 张学友" returns
  /// 王菲's 季候风 first, and "越吻越伤心 张学友" returns a medley
  /// first — a blind first-result cover would be the wrong singer's
  /// album art.
  Future<String> _lookupCover(Song song) async {
    final q = '${baseTitleRaw(song.title)} ${_firstArtist(song.artist)}'
        .trim();
    if (q.isEmpty) return '';
    final results = await _api.searchWy(q, _candidates);
    for (final r in results) {
      if (r.cover.isEmpty) continue;
      if (baseSongTitle(r.title) != baseSongTitle(song.title)) continue;
      if (!_artistMatches(r.artist, song.artist)) continue;
      return r.cover;
    }
    return '';
  }

  static bool _artistMatches(String resultArtist, String targetArtist) {
    final target = _artistSet(targetArtist);
    final result = _artistSet(resultArtist);
    if (target.intersection(result).isNotEmpty) return true;
    // Chorus songs: NetEase labels them 群星; the Kuwo side lists the
    // individual singers. Accept a title-only match then.
    if (result.contains('群星') && target.length >= 2) return true;
    if (target.contains('群星')) return true;
    return false;
  }

  static Set<String> _artistSet(String artist) => artist
      .split(RegExp(r'[/&、，,；;]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();

  /// First artist for the lookup query. Like [firstArtist] but also
  /// splits on `&` — Kuwo joins singers with `&` ("梅艳芳&张学友..."),
  /// and the whole string would pollute the query.
  static String _firstArtist(String artist) {
    final parts = artist.split(RegExp(r'[/&、，,；;]'));
    return parts.isEmpty ? '' : parts.first.trim();
  }
}
