// Recovery ladder (Pure Live 3.x media_core recovery/ladder).
//
// Shape, verbatim from the ladder's doc comment: report(failure) -> one
// run at a time -> per engine: reopen the current source once, then every
// other source -> sources exhausted -> next engine, sweep again -> nothing
// left -> exhausted event. Every attempt is verified by ACTUAL playback
// (open returning != success); bounded by the candidate lists (each source
// once per engine, each engine once, no budgets/backoff/memory). A
// source-level failure (unopenable URL — expired signature, unsupported
// format) SKIPS the in-place reopen: replaying the same URL reproduces
// the fault, so live goes to the fresh-URL path (fix 3) instead.
//
// Timeouts (study §1.3): sourceOpen 18 s, live retry delays [750 ms, 2 s],
// healthy 30 s of playback resets the budget.

import 'dart:async';

import 'player_engine.dart';

enum RecoveryLadderStatus { idle, running, completed, exhausted }

/// One attempt: open [url] on [engine] and verify real playback.
typedef LadderAttempt = Future<bool> Function({
  required PlayerEngine engine,
  required String url,
});

/// Staged, automatic engine ladder. No user prompt at any step.
class RecoveryLadder {
  RecoveryLadder({
    required this.engines,
    required this.urls,
    required this.attempt,
    this.retryDelays = const [
      Duration(milliseconds: 750),
      Duration(seconds: 2),
    ],
  });

  /// Capable engines in try order (from [candidatesFor]).
  final List<PlayerEngine> engines;

  /// URLs to try, in order (current line first, then other lines).
  /// The ladder never retries the SAME url on the SAME engine twice.
  final List<String> urls;

  final LadderAttempt attempt;

  /// Bounded retry delays between ladder passes (750 ms, 2 s).
  final List<Duration> retryDelays;

  RecoveryLadderStatus status = RecoveryLadderStatus.idle;

  final _tried = <String>{};

  String _attemptKey(PlayerEngine engine, String url) =>
      '${engine.key}::$url';

  /// Run the ladder. Returns the (engine, url) that verified playback,
  /// or null when every capable engine failed on every URL.
  Future<({PlayerEngine engine, String url})?> run() async {
    if (status == RecoveryLadderStatus.running) return null;
    status = RecoveryLadderStatus.running;
    try {
      for (final engine in engines) {
        for (final url in urls) {
          final key = _attemptKey(engine, url);
          if (_tried.contains(key)) continue;
          _tried.add(key);
          final ok = await attempt(engine: engine, url: url);
          if (ok) {
            status = RecoveryLadderStatus.completed;
            return (engine: engine, url: url);
          }
        }
      }
      // One bounded retry pass with delays (live only in practice).
      for (final delay in retryDelays) {
        await Future<void>.delayed(delay);
        for (final engine in engines) {
          for (final url in urls) {
            final key = _attemptKey(engine, url);
            if (_tried.contains(key)) continue;
            _tried.add(key);
            final ok = await attempt(engine: engine, url: url);
            if (ok) {
              status = RecoveryLadderStatus.completed;
              return (engine: engine, url: url);
            }
          }
        }
      }
      status = RecoveryLadderStatus.exhausted;
      return null;
    } catch (_) {
      status = RecoveryLadderStatus.exhausted;
      return null;
    }
  }

  /// Healthy playback resets the budget (30 s of playback, study §1.3).
  void resetBudget() {
    _tried.clear();
    status = RecoveryLadderStatus.idle;
  }
}
