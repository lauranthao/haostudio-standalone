// ignore_for_file: prefer_initializing_formals
// Pure-audio mode + sleep timer — item 4 (build 29, I group).
//
// Pure audio reuses the session's existing audio-only path
// (`PlaybackSession.setAudioOnly`, MPV `vid=no` — IJK / AVPlayer
// keep the default no-op, see live_pip_support.dart for the
// per-engine table). This file owns only the room-side state: the
// on/off toggle and the sleep timer that ends playback.
//
// Sleep timer: 15 / 30 / 60 minutes, or off. On expiry the callback
// fires exactly once (the room pauses the session and toasts); the
// timer survives nothing — leaving the room cancels it (the room
// page disposes the controller). Pure Dart with an injectable
// clock/timer factory so the rules are unit-testable.

import 'dart:async';

/// Sleep-timer presets. `off` cancels any running timer.
enum LiveSleepDuration {
  off('关闭', Duration.zero),
  min15('15 分钟', Duration(minutes: 15)),
  min30('30 分钟', Duration(minutes: 30)),
  min60('60 分钟', Duration(minutes: 60));

  const LiveSleepDuration(this.label, this.duration);

  final String label;
  final Duration duration;
}

/// Owns the sleep timer for one room. [onExpire] fires once when the
/// timer runs out. [timerFactory] is a test seam (defaults to the
/// real [Timer]); pass a fake in tests.
class LiveSleepTimer {
  LiveSleepTimer({
    required void Function() onExpire,
    Timer Function(Duration duration, void Function() callback)?
    timerFactory,
  }) : _onExpire = onExpire,
       _timerFactory =
           timerFactory ?? ((d, cb) => Timer(d, cb));

  final void Function() _onExpire;
  final Timer Function(Duration, void Function()) _timerFactory;

  Timer? _timer;
  LiveSleepDuration _current = LiveSleepDuration.off;

  LiveSleepDuration get current => _current;

  /// Remaining time when a timer is running, null otherwise. The
  /// wall-clock value is computed from the armed time, so it stays
  /// right without a ticking stream.
  Duration? get remaining {
    final until = _until;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  DateTime? _until;

  bool get isArmed => _timer != null;

  /// Arm [duration] (or cancel when [LiveSleepDuration.off]).
  /// Re-arming replaces the previous timer — never two timers.
  void set(LiveSleepDuration duration) {
    _timer?.cancel();
    _timer = null;
    _until = null;
    _current = duration;
    if (duration == LiveSleepDuration.off) return;
    _until = DateTime.now().add(duration.duration);
    _timer = _timerFactory(duration.duration, () {
      _timer = null;
      _until = null;
      _current = LiveSleepDuration.off;
      _onExpire();
    });
  }

  /// Cancel without firing. Idempotent.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _until = null;
    _current = LiveSleepDuration.off;
  }

  void dispose() => cancel();
}
