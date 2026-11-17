// Sleep timer (M-P0-3) — wall-clock countdown, not per-song.
//
// Options: 5 / 15 / 30 / 45 / 60 / 90 minutes (Beans sleep ladder),
// 到歌单结束 (stop when the current queue ends), or off. The timer
// survives track changes because it is a plain wall-clock countdown
// owned by the player controller, not by any single track. When it
// fires it pauses playback and clears itself. 到歌单结束 never starts
// a clock: the controller checks [isQueueEnd] when a track completes
// and stops there instead.
//
// Pure Dart (no Flutter widgets) so the countdown is unit-testable with
// fake_async.

import 'dart:async';

enum SleepTimerOption {
  off,
  min5,
  min15,
  min30,
  min45,
  min60,
  min90,
  queueEnd,

  /// Custom minutes (stage 2, Beans `SleepTimerSheet` 自定义时长).
  /// The minutes live on [SleepTimer.customMinutes], not on the enum
  /// — the enum is only the selection, the value is persisted
  /// separately (MusicStore.sleepCustomMinutes).
  custom,
}

extension SleepTimerOptionX on SleepTimerOption {
  /// Wall-clock duration, or null for off / queue-end / custom (no
  /// fixed clock — custom reads [SleepTimer.customMinutes]).
  Duration? get duration {
    switch (this) {
      case SleepTimerOption.min5:
        return const Duration(minutes: 5);
      case SleepTimerOption.min15:
        return const Duration(minutes: 15);
      case SleepTimerOption.min30:
        return const Duration(minutes: 30);
      case SleepTimerOption.min45:
        return const Duration(minutes: 45);
      case SleepTimerOption.min60:
        return const Duration(minutes: 60);
      case SleepTimerOption.min90:
        return const Duration(minutes: 90);
      case SleepTimerOption.off:
      case SleepTimerOption.queueEnd:
      case SleepTimerOption.custom:
        return null;
    }
  }

  String get label {
    switch (this) {
      case SleepTimerOption.off:
        return '关闭';
      case SleepTimerOption.min5:
        return '5 分钟';
      case SleepTimerOption.min15:
        return '15 分钟';
      case SleepTimerOption.min30:
        return '30 分钟';
      case SleepTimerOption.min45:
        return '45 分钟';
      case SleepTimerOption.min60:
        return '60 分钟';
      case SleepTimerOption.min90:
        return '90 分钟';
      case SleepTimerOption.queueEnd:
        return '到歌单结束';
      case SleepTimerOption.custom:
        return '自定义';
    }
  }

  /// All selectable options, in sheet order (custom last before off,
  /// after the presets — Beans puts 自定义时长 in its own section
  /// below the preset list).
  static const List<SleepTimerOption> all = [
    SleepTimerOption.min5,
    SleepTimerOption.min15,
    SleepTimerOption.min30,
    SleepTimerOption.min45,
    SleepTimerOption.min60,
    SleepTimerOption.min90,
    SleepTimerOption.queueEnd,
    SleepTimerOption.custom,
    SleepTimerOption.off,
  ];
}

/// Beans `SleepTimerSheet` clamp (SleepTimerSheet.swift:61):
/// `min(max(Int(text) ?? 30, 1), 720)` — 1..720 minutes, bad input
/// falls back to 30. Copied exactly, including the 30 fallback.
int clampSleepCustomMinutes(int? minutes) =>
    (minutes ?? 30).clamp(1, 720);

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

  /// Custom minutes for [SleepTimerOption.custom] (default 30, the
  /// Beans sheet's initial text). Set by [startCustom]; [start] with
  /// `custom` uses the last value set here.
  int _customMinutes = 30;
  int get customMinutes => _customMinutes;

  SleepTimerOption get option => _option;

  bool get isActive => _option != SleepTimerOption.off;

  bool get isQueueEnd => _option == SleepTimerOption.queueEnd;

  /// Remaining wall-clock time, or null when off / queue-end.
  Duration? get remaining => _remaining;

  /// Shared "m:ss" formatter for a remaining duration. Single copy —
  /// the two sheets used to each carry their own identical copy.
  static String formatRemaining(Duration remaining) {
    final total = remaining.inSeconds;
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// "12:34" style remaining text, or '' when there is no clock.
  String get remainingText {
    final r = _remaining;
    if (r == null) return '';
    return formatRemaining(r);
  }

  /// Start a custom-minutes timer (Beans: clamp 1..720, bad input 30).
  /// The minutes are remembered on this instance so a later
  /// `start(custom)` replays them.
  void startCustom(int minutes) {
    _customMinutes = clampSleepCustomMinutes(minutes);
    start(SleepTimerOption.custom);
  }

  void start(SleepTimerOption option) {
    cancel();
    _option = option;
    final d = option == SleepTimerOption.custom
        ? Duration(minutes: _customMinutes)
        : option.duration;
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
