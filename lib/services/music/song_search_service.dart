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

import '../../features/settings/source_stores.dart';
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
  SongSearchService({MusicApi? api}) : _api = api ?? MusicApi();

  final MusicApi _api;
  var _generation = 0;

  /// Fan out to the enabled platforms (40 results each, app.js:6406)
  /// and merge. Returns [] when every platform failed or returned
  /// nothing. A stale generation returns [] and the caller must
  /// ignore it.
  Future<List<Song>> searchAll(String query) async {
    final gen = ++_generation;
    final platforms = MusicSourcesStore.enabled();
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
      return hit.$2;
    }).toList();
    if (!perPf.any((l) => l.isNotEmpty)) return [];
    return mergeSearchResults(perPf);
  }

  /// Cancel any in-flight search (called when a new query starts).
  void cancel() => _generation++;
}
