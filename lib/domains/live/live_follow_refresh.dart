// ignore_for_file: prefer_initializing_formals
// Follow refresh state machine — item 1 (build 29, I group).
//
// The old follows page fired a full concurrent re-check on every
// init, every tab tap and every pull-to-refresh, with no lock and no
// memory of failure: a slow room held the whole page, a failed round
// was retried immediately on the next tap, and there was no way to
// tell "never checked yet" from "checked and offline".
//
// Rules (the state machine):
// - Initial state is [FollowRefreshPhase.unknown]: the page shows the
//   cached follows as a preview (unknown badges), never as live.
// - One round at a time: a second trigger while a round is running
//   is dropped ([tryStartRound] returns false), never queued.
// - One snapshot per round: the fetch callback runs exactly once per
//   round; its result is the round's snapshot. A round never
//   re-fetches to "confirm".
// - Failure cooldown: a round that ends with any unknown (failed)
//   status starts a 60 s cooldown. Automatic triggers (init, tab
//   tap) inside the cooldown are dropped; only an explicit manual
//   pull-to-refresh bypasses it ([manual] = true).
// - A round that ends clean (no unknowns) clears the cooldown.
//
// The machine is pure Dart (clock + fetch injected) so the rules are
// unit-testable without a page. The follows page owns one instance.

import 'dart:async';

/// What the follow list is showing right now.
enum FollowRefreshPhase {
  /// Never checked yet — cached follows shown as a preview, every
  /// status badge "状态未知".
  unknown,

  /// A round is in flight.
  refreshing,

  /// At least one round completed — statuses are a real snapshot.
  ready,
}

/// One round's outcome, as handed to the page.
class FollowRefreshSnapshot<T> {
  const FollowRefreshSnapshot({
    required this.values,
    required this.failedCount,
    required this.at,
  });

  /// The round's single snapshot (platform|roomId -> status payload).
  final Map<String, T> values;

  /// How many entries failed (unknown) in this round.
  final int failedCount;

  /// When the round finished.
  final DateTime at;
}

/// State machine for follow-list refreshes. [fetch] runs one round
/// and returns the snapshot plus its failed count; [isFailed] tells
/// whether one entry failed (unknown). [now] is the clock (inject a
/// fake in tests); [cooldown] defaults to 60 s.
class LiveFollowRefreshController<T> {
  LiveFollowRefreshController({
    required Future<(Map<String, T>, int)> Function() fetch,
    DateTime Function()? now,
    Duration cooldown = const Duration(seconds: 60),
  }) : _fetch = fetch,
       _now = now ?? DateTime.now,
       _cooldown = cooldown;

  final Future<(Map<String, T>, int)> Function() _fetch;
  final DateTime Function() _now;
  final Duration _cooldown;

  FollowRefreshPhase _phase = FollowRefreshPhase.unknown;
  FollowRefreshSnapshot<T>? _snapshot;
  DateTime? _cooldownUntil;
  bool _running = false;

  /// How many rounds have actually started (fetch invoked).
  int roundsStarted = 0;

  /// How many triggers were dropped (already running / cooling down).
  int triggersDropped = 0;

  FollowRefreshPhase get phase => _phase;
  FollowRefreshSnapshot<T>? get snapshot => _snapshot;
  bool get isRefreshing => _running;

  /// True while an automatic (non-manual) trigger is cooling down
  /// after a failed round.
  bool get inCooldown {
    final until = _cooldownUntil;
    return until != null && _now().isBefore(until);
  }

  /// Start a round. Returns false (and drops the trigger) when a
  /// round is already running, or when in cooldown and [manual] is
  /// false. A manual pull-to-refresh ([manual] = true) always runs
  /// unless a round is already in flight.
  Future<bool> tryStartRound({bool manual = false}) async {
    if (_running) {
      triggersDropped++;
      return false;
    }
    if (!manual && inCooldown) {
      triggersDropped++;
      return false;
    }
    _running = true;
    _phase = FollowRefreshPhase.refreshing;
    roundsStarted++;
    try {
      final (values, failedCount) = await _fetch();
      _snapshot = FollowRefreshSnapshot<T>(
        values: values,
        failedCount: failedCount,
        at: _now(),
      );
      _phase = FollowRefreshPhase.ready;
      // A clean round clears the cooldown; a failed round starts it.
      _cooldownUntil = failedCount > 0
          ? _now().add(_cooldown)
          : null;
      return true;
    } finally {
      _running = false;
    }
  }
}
