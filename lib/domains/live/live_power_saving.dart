// Power-saving mode — item 10 (build 29, I group).
//
// One tap drops the room's power draw; one tap restores exactly
// what was there before. The mode does three things, all reversible:
// - Quality: switch to the lowest quality tier (the cheapest decode
//   + least network). The previous quality index is remembered and
//   restored on exit.
// - Danmaku: hide the flying + list danmaku (no transport stop —
//   the transport keeps running so re-enabling is instant; only
//   rendering stops).
// - (Deliberately NOT done: brightness — the room never touches
//   system brightness outside the user's own drag, standing rule;
//   and NOT audio-only — that is the separate pure-audio toggle.)
//
// The controller is pure Dart: it computes the target quality index
// and remembers the previous one. The room page applies the switch
// through its existing `_switchQuality` and restores it the same way.

/// One room's power-saving state.
class LivePowerSaving {
  bool _on = false;
  int? _previousQualityIndex;

  bool get isOn => _on;

  /// Enter power saving: returns the lowest-quality index to switch
  /// to, or null when there is nothing to switch (0/1 qualities).
  /// Remembers [currentQualityIndex] for the exit restore.
  int? enter({
    required int qualityCount,
    required int currentQualityIndex,
  }) {
    if (_on || qualityCount < 2) return null;
    _on = true;
    _previousQualityIndex = currentQualityIndex;
    return qualityCount - 1;
  }

  /// Exit power saving: returns the quality index to restore, or
  /// null when the mode was not on / nothing was remembered.
  int? exit() {
    if (!_on) return null;
    _on = false;
    final prev = _previousQualityIndex;
    _previousQualityIndex = null;
    return prev;
  }

  /// Reset without restoring (room disposed while saving).
  void reset() {
    _on = false;
    _previousQualityIndex = null;
  }
}
