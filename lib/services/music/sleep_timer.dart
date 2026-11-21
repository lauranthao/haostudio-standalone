// Sleep timer (M-P0-3) — wall-clock countdown, not per-song.
//
// Options: 5 / 15 / 30 / 45 / 60 / 90 minutes (Beans sleep ladder),
// 到歌单结束 (stop when the current queue ends), 播完本首后停止
// (stop when the current track completes), 播完 N 首后停止 (stop
// after N naturally-completed tracks), or off. The timer survives
// track changes because it is a plain wall-clock countdown owned by
// the player controller, not by any single track. When it fires it
// pauses playback and clears itself. 到歌单结束 / 播完本首后停止 /
// 播完 N 首后停止 never start a clock: the controller checks them
// when a track completes and stops there instead.
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

  /// Stop when the current track completes (1.1.6). No clock: the
  /// controller stops in [_onTrackCompleted] instead of firing.
  /// Beats single-loop: a looping track still ends (see the
  /// controller — the check runs before the single-loop replay).
  currentTrackEnd,

  /// Stop after N naturally-completed tracks (1.1.6). N lives on
  /// [SleepTimer.trackTarget], not on the enum — the enum is only
  /// the selection, the value is set separately (like custom
  /// minutes). Only natural completions count (see
  /// [SleepTimer.noteTrackCompleted]): manual next/prev, taps and
  /// failed skips do not count; the track playing when the mode
  /// starts counts when it completes.
  afterNTracks,

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
      case SleepTimerOption.currentTrackEnd:
      case SleepTimerOption.afterNTracks:
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
      case SleepTimerOption.currentTrackEnd:
        return '播完本首后停止';
      case SleepTimerOption.afterNTracks:
        return '播完 N 首后停止';
      case SleepTimerOption.custom:
        return '自定义';
    }
  }

  /// All selectable options, in sheet order (custom last before off,
  /// after the presets — Beans puts 自定义时长 in its own section
  /// below the preset list). The two 1.1.6 completion modes sit
  /// right after 到歌单结束: they are the same kind of choice
  /// (stop at a completion, not at a clock time). The sheet renders
  /// this list directly, so a new option appears as a row with no
  /// sheet edit.
  static const List<SleepTimerOption> all = [
    SleepTimerOption.min5,
    SleepTimerOption.min15,
    SleepTimerOption.min30,
    SleepTimerOption.min45,
    SleepTimerOption.min60,
    SleepTimerOption.min90,
    SleepTimerOption.queueEnd,
    SleepTimerOption.currentTrackEnd,
    SleepTimerOption.afterNTracks,
    SleepTimerOption.custom,
    SleepTimerOption.off,
  ];
}

/// Beans-style clamp for the "播完 N 首" count (1.1.6): 1..10 songs,
/// bad input falls back to 3 (the default).
int clampSleepTrackCount(int? count) => (count ?? 3).clamp(1, 10);

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

  /// Target count for [SleepTimerOption.afterNTracks] (default 3,
  /// range 1..10 — see [clampSleepTrackCount]). Set by
  /// [startAfterNTracks] / [setTrackTarget]; [start] with
  /// `afterNTracks` uses the last value set here.
  int _trackTarget = 3;
  int get trackTarget => _trackTarget;

  /// Naturally-completed tracks counted so far under the current
  /// `afterNTracks` run. Reset whenever the mode starts, whenever
  /// the target changes mid-run ("改 N 从当下重计"), and on cancel.
  int _tracksCompleted = 0;
  int get tracksCompleted => _tracksCompleted;

  SleepTimerOption get option => _option;

  bool get isActive => _option != SleepTimerOption.off;

  bool get isQueueEnd => _option == SleepTimerOption.queueEnd;

  bool get isCurrentTrackEnd =>
      _option == SleepTimerOption.currentTrackEnd;

  bool get isAfterNTracks => _option == SleepTimerOption.afterNTracks;

  /// Remaining wall-clock time, or null when off / queue-end /
  /// completion modes (they have no clock).
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

  /// Start a "播完 N 首后停止" run (clamp 1..10, bad input 3).
  /// The count restarts from zero: a track that completed before
  /// this call never counts towards the new run.
  void startAfterNTracks(int count) {
    _trackTarget = clampSleepTrackCount(count);
    start(SleepTimerOption.afterNTracks);
  }

  /// Change the N target. When an `afterNTracks` run is active the
  /// count restarts from zero ("改 N 从当下重计" — already-counted
  /// tracks do not carry over); when no run is active the target is
  /// just remembered for the next run.
  void setTrackTarget(int count) {
    _trackTarget = clampSleepTrackCount(count);
    if (isAfterNTracks) _tracksCompleted = 0;
    onChanged?.call();
  }

  /// Record one naturally-completed track. Call ONLY from the
  /// controller's track-completed path: manual next/prev, taps and
  /// failed skips never reach it, so they never count. Returns true
  /// when the target is reached (the caller stops playback there);
  /// a no-op returning false when the mode is not `afterNTracks`.
  /// The current track counts when it completes — including the
  /// track that was playing when the mode started.
  bool noteTrackCompleted() {
    if (!isAfterNTracks) return false;
    _tracksCompleted++;
    onChanged?.call();
    return _tracksCompleted >= _trackTarget;
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
    _tracksCompleted = 0;
    onChanged?.call();
  }
}
