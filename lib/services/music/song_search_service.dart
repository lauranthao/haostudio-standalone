// Aggregated song search (fix 12).
//
// chen's latest instruction wins over music-video spec §1.1: every song
// search queries ALL FOUR platforms by default (wy + tx + kg + kw),
// concurrently, each with its own timeout; a failing platform contributes
// nothing and does not fail the search. Results merge round-robin across
// platforms (one per platform per round, wy/tx/kg/kw order), deduped by
// platform + songId + title, each tagged with its platform badge. NO
// platform picker in the search UI.
// Infinite scroll: first 20 shown, 20 more per sentinel hit, "已加载全部"
// at the end — no next-page button. A new query cancels the previous
// search (generation guard) so stale results cannot overwrite it.
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

/// Round-robin merge, pure function — unit-tested.
///
/// [perPlatform] is in wy/tx/kg/kw order; one item per platform per
/// round. Dedupe key is platform + songId + title (fix 12).
List<Song> mergeSearchResults(List<List<Song>> perPlatform) {
  final merged = <Song>[];
  var pi = 0;
  var added = true;
  while (added) {
    added = false;
    for (final list in perPlatform) {
      if (pi < list.length) {
        merged.add(list[pi]);
        added = true;
      }
    }
    pi++;
  }
  final seen = <String>{};
  final out = <Song>[];
  for (final s in merged) {
    if (seen.contains(s.dedupeKey)) continue;
    seen.add(s.dedupeKey);
    out.add(s);
  }
  return out;
}

class SongSearchService {
  SongSearchService({MusicApi? api, LxScriptEngine? scriptEngine})
      : _api = api ?? MusicApi(),
        _scriptEngine = scriptEngine ?? LxScriptEngine.instance;

  final MusicApi _api;

  /// LX script engine (M-P0-6). Defaults to the process singleton;
  /// tests pass their own engine.
  final LxScriptEngine _scriptEngine;
  var _generation = 0;

  /// Fan out to the enabled platforms (40 results each, app.js:6406)
  /// and merge. Returns [] when every platform failed or returned
  /// nothing. A stale generation returns [] and the caller must
  /// ignore it.
  Future<List<Song>> searchAll(String query) async {
    final gen = ++_generation;
    final platforms = MusicSourcesStore.enabled();
    // LX script search legs (M-P0-6): only scripts declaring `search`
    // for an enabled platform (today: 溯音 for kw — mg is not a search
    // platform, so in practice kw only). They start concurrently with
    // the platform legs; a slow script never delays the search past
    // 8 s. Kick off engine load on first use; legs appear once loaded.
    unawaited(_scriptEngine.ensureInitialized().catchError((_) {}));
    final scriptLegs = <({MusicPlatform pf, String scriptId})>[];
    for (final pf in platforms) {
      for (final leg in _scriptEngine.searchLegsFor(pf)) {
        scriptLegs.add((pf: pf, scriptId: leg.scriptId));
      }
    }
    final scriptFutures = scriptLegs
        .map(
          (leg) => _scriptEngine
              .search(
                scriptId: leg.scriptId,
                platform: leg.pf.code,
                keyword: query,
                limit: 20,
              )
              .timeout(
                const Duration(seconds: 8),
                onTimeout: () => const <Map<String, dynamic>>[],
              )
              .catchError((_) => const <Map<String, dynamic>>[]),
        )
        .toList();
    final settled = await Future.wait(
      platforms.map(
        (pf) => _api
            .searchOne(pf, query)
            .then((r) => (pf, r))
            .catchError((_) => (pf, <Song>[])),
      ),
    );
    if (gen != _generation) return [];
    final perPf = platforms.map((pf) {
      final hit = settled.firstWhere(
        (e) => e.$1 == pf,
        orElse: () => (pf, <Song>[]),
      );
      return List.of(hit.$2);
    }).toList();
    if (scriptLegs.isNotEmpty) {
      final scriptResults = await Future.wait(scriptFutures);
      if (gen != _generation) return [];
      for (var i = 0; i < scriptLegs.length; i++) {
        final pf = scriptLegs[i].pf;
        final idx = platforms.indexOf(pf);
        if (idx < 0) continue;
        // Script ids are sometimes generated (溯音 falls back to
        // `kw_<ts>_<rand>`), so dedupe script hits against the
        // platform's own results by title+artist, not by id.
        final have = perPf[idx]
            .map((s) => '${s.title.toLowerCase()}|${s.artist.toLowerCase()}')
            .toSet();
        for (final raw in scriptResults[i]) {
          final song = LxScriptEngine.lxSongFromJson(raw, pf);
          if (song == null) continue;
          final key =
              '${song.title.toLowerCase()}|${song.artist.toLowerCase()}';
          if (have.contains(key)) continue;
          have.add(key);
          perPf[idx].add(song);
        }
      }
    }
    if (!perPf.any((l) => l.isNotEmpty)) return [];
    return mergeSearchResults(perPf);
  }

  /// Cancel any in-flight search (called when a new query starts).
  void cancel() => _generation++;
}
