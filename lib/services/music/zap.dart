// Zap 快速发现 (build 29, music) — random 5-second previews.
//
// A Zap session plays each song for [previewSeconds] then cuts to
// the next random song in the pool, so the user can sweep a pile of
// unheard music fast. The timer lives in the controller; this file
// holds the pure parts: pool building + the "not the same song
// twice in a row" next-index pick.

import 'dart:math';

import 'music_models.dart';

class ZapPool {
  ZapPool._();

  /// Seconds of each preview before the controller cuts on.
  static const int previewSeconds = 5;

  /// Max songs per Zap session.
  static const int maxPool = 30;

  /// Build the pool from local data: favourites + recent + daily,
  /// deduped, shuffled. [random] is injectable for tests.
  static List<Song> build({
    required List<Song> favourites,
    required List<Song> recent,
    required List<Song> daily,
    Random? random,
  }) {
    final rng = random ?? Random();
    final seen = <String>{};
    final pool = <Song>[];
    for (final s in [...favourites, ...recent, ...daily]) {
      if (seen.add(s.identityKey)) pool.add(s);
    }
    pool.shuffle(rng);
    return pool.take(maxPool).toList();
  }

  /// Next index in a pool of [length] that is not [current] (when
  /// there is any choice). Pure given [random].
  static int nextIndex({
    required int current,
    required int length,
    Random? random,
  }) {
    if (length <= 1) return 0;
    final rng = random ?? Random();
    var next = rng.nextInt(length);
    var guard = 0;
    while (next == current && guard++ < 10) {
      next = rng.nextInt(length);
    }
    return next == current ? (current + 1) % length : next;
  }
}
