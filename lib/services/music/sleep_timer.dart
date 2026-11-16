// Sleep timer (M-P0-3) — wall-clock countdown, not per-song.
//
// Options: 15 / 30 / 60 / 90 minutes, 到歌单结束 (stop when the current
// queue ends), or off. The timer survives track changes because it is a
// plain wall-clock countdown owned by the player controller, not by any
// single track. When it fires it pauses playback and clears itself.
// 到歌单结束 never starts a clock: the controller checks [isQueueEnd]
// when a track completes and stops there instead.
//
// Pure Dart (no Flutter widgets) so the countdown is unit-testable with
// fake_async.

import 'dart:async';

enum SleepTimerOption { off, min15, min30, min60, min90, queueEnd }

extension SleepTimerOptionX on SleepTimerOption {
  /// Wall-clock duration, or null for off / queue-end (no clock).
  Duration? get duration {
    switch (this) {
      case SleepTimerOption.min15:
        return const Duration(minutes: 15);
      case SleepTimerOption.min30:
        return const Duration(minutes: 30);
      case SleepTimerOption.min60:
        return const Duration(minutes: 60);
      case SleepTimerOption.min90:
        return const Duration(minutes: 90);
      case SleepTimerOption.off:
      case SleepTimerOption.queueEnd:
        return null;
    }
  }

  String get label {
    switch (this) {
      case SleepTimerOption.off:
        return '关闭';
      case SleepTimerOption.min15:
        return '15 分钟';
      case SleepTimerOption.min30:
        return '30 分钟';
      case SleepTimerOption.min60:
        return '60 分钟';
      case SleepTimerOption.min90:
        return '90 分钟';
      case SleepTimerOption.queueEnd:
        return '到歌单结束';
    }
  }

  /// All selectable options, in sheet order.
  static const List<SleepTimerOption> all = [
    SleepTimerOption.min15,
    SleepTimerOption.min30,
    SleepTimerOption.min60,
    SleepTimerOption.min90,
    SleepTimerOption.queueEnd,
    SleepTimerOption.off,
  ];
}

class SleepTimer {
  SleepTimer({required this.onFire, this.onChanged});

  /// Called once when a wall-clock timer reaches zero. The timer has
  /// already cleared itself by then.
  final void Function() onFire;

  /// Called on start / cancel / every tick so the UI can show the
  /// remaining time honestly.
  final void Function()? onChanged;

  SleepTimerOption _option = SleepTimerOption.off;
  Duration? _remaining;
  Timer? _ticker;

  SleepTimerOption get option => _option;

  bool get isActive => _option != SleepTimerOption.off;

  bool get isQueueEnd => _option == SleepTimerOption.queueEnd;

  /// Remaining wall-clock time, or null when off / queue-end.
  Duration? get remaining => _remaining;

  /// "12:34" style remaining text, or '' when there is no clock.
  String get remainingText {
    final r = _remaining;
    if (r == null) return '';
    final total = r.inSeconds;
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void start(SleepTimerOption option) {
    cancel();
    _option = option;
    final d = option.duration;
    if (d != null) {
      _remaining = d;
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        final r = _remaining;
        if (r == null) return;
        _remaining = r - const Duration(seconds: 1);
        if (_remaining!.inSeconds <= 0) {
          cancel();
          onFire();
          return;
        }
        onChanged?.call();
      });
    }
    onChanged?.call();
  }

  void cancel() {
    _ticker?.cancel();
    _ticker = null;
    _option = SleepTimerOption.off;
    _remaining = null;
    onChanged?.call();
  }
}
