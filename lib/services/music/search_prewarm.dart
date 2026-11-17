// Search-result prewarm: resolve the play URLs of the first few
// visible songs while the user is still looking at the list, so
// tapping one plays from the URL cache instead of parsing from
// scratch (chen 2026-11-17: playback must start in ~1 s).
//
// LX model, serial: one song at a time, no fan-out. Best-effort and
// fire-and-forget — a prewarm never blocks the UI and never throws.
// Only the first [_maxSongs] songs are warmed (the visible rows);
// warming the whole list would burn traffic for songs the user never
// taps. A new prewarm abandons the old run (generation guard), and
// songs already being resolved are not started twice. The warmed
// URLs land in the shared URL cache (Hive), so the controller's
// resolver picks them up on tap — no controller change needed.
import 'music_models.dart';
import 'music_resolvers.dart';
import 'music_store.dart';

class SearchPrewarm {
  SearchPrewarm({MusicResolvers? resolvers})
      : _resolvers = resolvers ?? MusicResolvers();

  /// How many leading songs to warm (the visible rows).
  static const _maxSongs = 3;

  final MusicResolvers _resolvers;
  int _gen = 0;
  final _inFlight = <String>{};

  /// Warm the play URLs of the first [_maxSongs] songs in [songs],
  /// serially. Calling it again abandons the previous run before its
  /// next song (streaming search re-emits the list as legs arrive, so
  /// this is called on every update). Fire-and-forget: never throws.
  void prewarm(List<Song> songs) {
    final gen = ++_gen;
    final targets = songs.take(_maxSongs).toList();
    if (targets.isEmpty) return;
    _run(gen, targets);
  }

  /// Abandon the current run (called when the page is disposed).
  /// In-flight resolves finish on their own and their URLs are still
  /// cached (a valid URL is a valid URL); the generation check keeps
  /// the abandoned run from starting any further song. [_inFlight]
  /// is deliberately NOT cleared: a new prewarm for the same song
  /// skips it while the old resolve is still warming it, so the same
  /// song is never resolved twice at once.
  void cancel() {
    _gen++;
  }

  Future<void> _run(int gen, List<Song> targets) async {
    for (final song in targets) {
      if (gen != _gen) return; // abandoned by a newer prewarm/cancel
      final key = song.identityKey;
      if (_inFlight.contains(key)) continue;
      _inFlight.add(key);
      try {
        await _resolvers.resolvePlayUrl(
          song.songId,
          song.platform,
          MusicStore.quality,
          song.title,
        );
      } catch (_) {
        // Best-effort: one song failing must not break the next.
      } finally {
        _inFlight.remove(key);
      }
    }
  }
}
