// Fade in/out envelope (build 29, music).
//
// Pure volume math + a small ramp runner the controller uses for:
// - 淡入: a manual track open starts at 0 and ramps to the track's
//   sounding gain (~600 ms); resuming a paused track fades in over
//   ~400 ms (see MusicPlayerController._fadeInThenPlay);
// - 淡出: pause / resume-toggle and the sleep-timer stop fade out
//   first instead of cutting hard (sleep already faded 1 s; the
//   toggle path reuses the same envelope at 400 ms).
// Auto-advance keeps its own Apple Music-style crossfade (2.5 s
// overlap) — this envelope never runs on that path.

import 'dart:async';

class VolumeFader {
  VolumeFader._();

  /// Linear 0..1 gain for [elapsed] into a fade of [total].
  static double fadeInGain(Duration elapsed, Duration total) {
    if (total <= Duration.zero) return 1.0;
    return (elapsed.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Linear 1..0 gain for [elapsed] into a fade of [total].
  static double fadeOutGain(Duration elapsed, Duration total) {
    if (total <= Duration.zero) return 0.0;
    return (1.0 - elapsed.inMilliseconds / total.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  /// Ramp the volume from [from] to [to] in ~50 ms steps, calling
  /// [setVolume] on each step. Returns early (leaving the volume
  /// where it is) when [isCancelled] says so — a newer load owns
  /// the player then and the stale ramp must not fight it.
  /// A zero duration or equal endpoints applies [to] once.
  static Future<void> ramp({
    required Future<void> Function(double volume) setVolume,
    required double from,
    required double to,
    Duration duration = const Duration(milliseconds: 500),
    bool Function()? isCancelled,
  }) async {
    if (duration <= Duration.zero || from == to) {
      await setVolume(to);
      return;
    }
    const step = Duration(milliseconds: 50);
    final steps =
        (duration.inMilliseconds / step.inMilliseconds).ceil().clamp(1, 100);
    for (var i = 1; i <= steps; i++) {
      if (isCancelled?.call() == true) return;
      final t = i / steps;
      await setVolume(from + (to - from) * t);
      if (i < steps) await Future.delayed(step);
    }
  }
}
