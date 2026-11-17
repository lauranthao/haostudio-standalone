// Aggregated song search (fix 12), streaming (v1.0.9: 秒出).
//
// chen's latest instruction wins over music-video spec §1.1: every song
// search queries ALL FOUR platforms by default (wy + tx + kg + kw),
// concurrently, each with its own timeout; a failing platform contributes
// nothing and does not fail the search. Results are NOT round-robin
// merged any more — the old [mergeSearchResults] needed every leg
// before it could return anything, so a single slow leg held the whole
// search up to 5 s. Now each leg emits the moment it returns
// ([searchAllStream]): the fastest leg (usually ~1 s) shows first, the
// rest append after it, grouped by platform, in arrival order. Nothing
// already shown is ever reordered. A new query cancels the previous
// search (generation guard) so stale results cannot overwrite it.
// Infinite scroll: first 20 shown, 20 more per sentinel hit, "已加载全部"
// at the end — no next-page button.
//
// Which platforms are queried comes from [MusicSourcesStore] (settings
// → 音源管理): all four by default, fewer when the user disabled one
// there. At least one platform always stays enabled (store guard).

import 'dart:async';

import '../../features/settings/source_stores.dart';
import 'lx_script_engine.dart';
import 'music_api.dart';
import 'music_models.dart';

const int kSearchPageSize = 20;
const int kSearchPerPlatform = 40;

/// One streaming update from [SongSearchService.searchAllStream].
///
/// [songs] is the cumulative result list so far — arrival order
/// (first-returned platform first, later legs appended after it),
/// deduped, covers backfilled. A fresh list on every emission; the
/// service never mutates a list it already handed out. [pending] is
/// the set of platforms with at least one leg not yet settled; it is
/// empty on the last emission, just before the stream closes.
class SearchStreamUpdate {
  const SearchStreamUpdate({required this.songs, required this.pending});

  final List<Song> songs;
  final Set<MusicPlatform> pending;
}

/// Cover backfill (v1.0.6 phone bug: "很多歌曲都没封面"): Kugou search
/// returns NO cover field at all, so ~1 in 4 merged rows was coverless
/// by construction. Fill an empty cover from another result with the
/// same normalised title+artist in the same search (the same song is
/// usually on wy/tx/kw too, with a real cover). Pure, unit-tested;
/// client-side only, no new network.
List<Song> backfillCovers(List<Song> songs) {
  final byKey = <String, String>{};
  for (final s in songs) {
    if (s.cover.isEmpty) continue;
    final k = '${normalizeName(s.title)}|${normalizeName(s.artist)}';
    byKey.putIfAbsent(k, () => s.cover);
  }
  if (byKey.isEmpty) return songs;
  var changed = false;
  final out = songs.map((s) {
    if (s.cover.isNotEmpty) return s;
    final k = '${normalizeName(s.title)}|${normalizeName(s.artist)}';
    final cover = byKey[k];
    if (cover == null || cover.isEmpty) return s;
    changed = true;
    return s.copyWith(cover: cover);
  }).toList();
  return changed ? out : songs;
}

/// Script-hit dedup key (same rule as the old merge): script ids are
/// sometimes generated (溯音 falls back to `kw_<ts>_<rand>`), so
/// title+artist — not id — is the only stable key.
String _titleArtistKey(Song s) =>
    '${s.title.toLowerCase()}|${s.artist.toLowerCase()}';

class SongSearchService {
  SongSearchService({MusicApi? api, LxScriptEngine? scriptEngine})
      : _api = api ?? MusicApi(),
        _scriptEngine = scriptEngine ?? LxScriptEngine.instance;

  final MusicApi _api;

  /// LX script engine (M-P0-6). Defaults to the process singleton;
  /// tests pass their own engine.
  final LxScriptEngine _scriptEngine;
  var _generation = 0;
  StreamController<SearchStreamUpdate>? _current;

  /// Streaming aggregated search: one [SearchStreamUpdate] per settled
  /// leg, in arrival order; the stream closes when every leg has
  /// settled (or the search was superseded).
  ///
  /// A "leg" is one platform's own search, or one LX script search
  /// for a platform. Platform legs emit the moment their own search
  /// returns — never waiting for the platform's script legs, and
  /// never for another platform — so the first result appears as soon
  /// as the fastest leg returns (~1 s), not when the slowest leg
  /// gives up at the 5 s cap. A leg that fails or times out
  /// contributes nothing and never blocks the others; a platform
  /// with no results at all does not hold up the rest.
  ///
  /// Script legs run concurrently with their platform leg, but emit
  /// only after the platform leg has settled, so the dedup sees the
  /// platform's own songs (the platform list is authoritative, script
  /// hits are extras — exactly as before). The platform leg never
  /// waits for a script leg.
  ///
  /// A stale generation emits nothing: starting a new search closes
  /// the previous stream at once, and late leg completions are
  /// dropped, so stale results cannot overwrite the new search.
  Stream<SearchStreamUpdate> searchAllStream(String query) {
    final gen = ++_generation;
    // Supersede the previous search: close its stream so the page's
    // loop ends at once instead of waiting out its legs.
    final prev = _current;
    final controller = StreamController<SearchStreamUpdate>();
    _current = controller;
    unawaited(prev?.close());

    final platforms = MusicSourcesStore.enabled();
    if (platforms.isEmpty) {
      // The store guarantees >= 1; never hand out a stream that
      // never closes.
      unawaited(controller.close());
      return controller.stream;
    }

    // LX script search legs (M-P0-6): only scripts declaring `search`
    // for an enabled platform (today: 溯音 for kw — mg is not a search
    // platform, so in practice kw only). Kick off engine load on
    // first use; legs appear once loaded.
    unawaited(_scriptEngine.ensureInitialized().catchError((_) {}));
    final scriptLegs = <({MusicPlatform pf, String scriptId})>[];
    for (final pf in platforms) {
      for (final leg in _scriptEngine.searchLegsFor(pf)) {
        scriptLegs.add((pf: pf, scriptId: leg.scriptId));
      }
    }

    // Per-search accumulation state. Only touched from synchronous
    // leg-settle callbacks (no await between the generation check and
    // the settle), so no interleaving is possible.
    final accumulated = <Song>[];
    final seenKeys = <String>{};
    final shownTitles = <MusicPlatform, Set<String>>{
      for (final pf in platforms) pf: <String>{},
    };
    // Legs not yet settled, per platform. A platform leaves `pending`
    // when its own leg AND all its script legs have settled.
    final legsLeftByPlatform = <MusicPlatform, int>{
      for (final pf in platforms) pf: 1,
    };
    for (final leg in scriptLegs) {
      legsLeftByPlatform[leg.pf] = legsLeftByPlatform[leg.pf]! + 1;
    }
    var legsLeft = 0;
    for (final n in legsLeftByPlatform.values) {
      legsLeft += n;
    }

    bool isLive() => gen == _generation && !controller.isClosed;

    void emit() {
      if (!isLive()) return;
      final pending = <MusicPlatform>{
        for (final e in legsLeftByPlatform.entries)
          if (e.value > 0) e.key,
      };
      // Copy first: the page keeps the emitted list while this
      // search keeps appending to `accumulated`.
      controller.add(SearchStreamUpdate(
        songs: backfillCovers(List.of(accumulated)),
        pending: pending,
      ));
    }

    void settle(MusicPlatform pf) {
      if (!isLive()) return;
      legsLeftByPlatform[pf] = legsLeftByPlatform[pf]! - 1;
      legsLeft--;
      emit();
      if (legsLeft == 0) {
        if (identical(_current, controller)) _current = null;
        unawaited(controller.close());
      }
    }

    Future<void> runPlatformLeg(MusicPlatform pf) async {
      List<Song> songs;
      try {
        songs = await _api
            .searchOne(pf, query)
            // 2026-11-17: per-leg 5 s cap. searchOne's own timeouts
            // are 10 s and kg/kw retry — a dead leg used to hold the
            // whole aggregated search 10–21 s. A leg that cannot
            // answer in 5 s contributes nothing.
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => <Song>[],
            )
            .catchError((_) => <Song>[]);
      } catch (_) {
        songs = const [];
      }
      if (!isLive()) return;
      try {
        for (final s in songs) {
          if (seenKeys.contains(s.dedupeKey)) continue;
          seenKeys.add(s.dedupeKey);
          shownTitles[pf]!.add(_titleArtistKey(s));
          accumulated.add(s);
        }
      } catch (_) {
        // A corrupt entry must not kill the search.
      } finally {
        settle(pf);
      }
    }

    Future<void> runScriptLeg(
      MusicPlatform pf,
      Future<List<Map<String, dynamic>>> scriptFuture,
      Future<void> platformDone,
    ) async {
      try {
        // The script search already ran concurrently with the platform
        // leg; only the emission waits for the platform leg to settle,
        // so the dedup sees the platform's own songs.
        final raw = await scriptFuture;
        await platformDone;
        if (!isLive()) return;
        try {
          for (final item in raw) {
            final song = LxScriptEngine.lxSongFromJson(item, pf);
            if (song == null) continue;
            if (seenKeys.contains(song.dedupeKey)) continue;
            final taKey = _titleArtistKey(song);
            if (shownTitles[pf]!.contains(taKey)) continue;
            seenKeys.add(song.dedupeKey);
            shownTitles[pf]!.add(taKey);
            accumulated.add(song);
          }
        } catch (_) {
          // A corrupt entry must not kill the search.
        }
      } catch (_) {
        // The platform gate or the script search failed: this leg
        // contributes nothing.
      } finally {
        settle(pf);
      }
    }

    for (final pf in platforms) {
      final pfScripts = scriptLegs.where((l) => l.pf == pf).toList();
      if (pfScripts.isEmpty) {
        unawaited(runPlatformLeg(pf));
      } else {
        final platformDone = runPlatformLeg(pf);
        for (final leg in pfScripts) {
          // Start the script search now (concurrently with the
          // platform leg); runScriptLeg only delays its emission.
          final scriptFuture = _scriptEngine
              .search(
                scriptId: leg.scriptId,
                platform: leg.pf.code,
                keyword: query,
                limit: 20,
              )
              // LX-style single deadline (2026-11-17, 歌一刀/LX 借鉴):
              // script legs share the 5 s leg cap.
              .timeout(
                const Duration(seconds: 5),
                onTimeout: () => const <Map<String, dynamic>>[],
              )
              .catchError((_) => const <Map<String, dynamic>>[]);
          unawaited(runScriptLeg(pf, scriptFuture, platformDone));
        }
      }
    }

    return controller.stream;
  }
}
