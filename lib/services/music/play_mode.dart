// Five music playback modes (M-P0-1).
//
// Source note: Pure Live — the reference app for this project — is a
// live-streaming app and defines NO music playback mode (its player
// settings cover live kernels, danmaku and display mode only), so there
// is nothing to port from it. The five modes below are the mainstream
// music-player set (NetEase Cloud Music / QQ Music / Apple Music):
// sequential, list loop, single loop, shuffle, single play. No sixth
// mode is invented.
//
// Stored codes (Hive `playMode`): 'seq' | 'loop' | 'one' | 'shuffle' |
// 'once'. The two legacy codes ('seq', 'shuffle') keep working for
// existing users; anything unknown reads back as sequential.

import 'dart:math';

enum PlayMode { sequential, listLoop, singleLoop, shuffle, single }

extension PlayModeX on PlayMode {
  /// Cycle order for the mode button: sequential -> list loop ->
  /// single loop -> shuffle -> single play -> sequential.
  static const List<PlayMode> cycleOrder = [
    PlayMode.sequential,
    PlayMode.listLoop,
    PlayMode.singleLoop,
    PlayMode.shuffle,
    PlayMode.single,
  ];

  String get code {
    switch (this) {
      case PlayMode.sequential:
        return 'seq';
      case PlayMode.listLoop:
        return 'loop';
      case PlayMode.singleLoop:
        return 'one';
      case PlayMode.shuffle:
        return 'shuffle';
      case PlayMode.single:
        return 'once';
    }
  }

  String get label {
    switch (this) {
      case PlayMode.sequential:
        return '顺序播放';
      case PlayMode.listLoop:
        return '列表循环';
      case PlayMode.singleLoop:
        return '单曲循环';
      case PlayMode.shuffle:
        return '随机播放';
      case PlayMode.single:
        return '单曲播放';
    }
  }

  PlayMode get next {
    final i = cycleOrder.indexOf(this);
    return cycleOrder[(i + 1) % cycleOrder.length];
  }

  static PlayMode fromCode(String? code) {
    switch (code) {
      case 'loop':
        return PlayMode.listLoop;
      case 'one':
        return PlayMode.singleLoop;
      case 'shuffle':
        return PlayMode.shuffle;
      case 'once':
        return PlayMode.single;
      case 'seq':
      default:
        // Legacy/unknown values fall back to sequential, never crash.
        return PlayMode.sequential;
    }
  }
}

/// Pure queue math — unit-tested, no player involved.
///
/// Returns the index of the next track, or -1 when playback must STOP
/// (end of queue reached in a non-looping mode).
///
/// [auto] is true for automatic advance on track completion, false for
/// an explicit user tap on next. They differ in two modes:
/// - single loop: auto replays the same track; a manual tap advances.
/// - single play: auto stops after the current song; a manual tap still
///   advances to the next track (the user asked for it).
int nextTrackIndex(
  PlayMode mode,
  int current,
  int length, {
  required bool auto,
  Random? random,
}) {
  if (length <= 0 || current < 0 || current >= length) return -1;
  switch (mode) {
    case PlayMode.sequential:
      return current + 1 < length ? current + 1 : -1;
    case PlayMode.listLoop:
      return (current + 1) % length;
    case PlayMode.singleLoop:
      if (auto) return current;
      return (current + 1) % length;
    case PlayMode.shuffle:
      if (length == 1) return current;
      final rng = random ?? Random();
      var n = current;
      while (n == current) {
        n = rng.nextInt(length);
      }
      return n;
    case PlayMode.single:
      if (auto) return -1;
      return current + 1 < length ? current + 1 : -1;
  }
}

/// Previous-track index. Manual only (there is no auto-previous).
/// Shuffle picks a random other track. Loop modes wrap at the start;
/// sequential and single-play stop at the first track — mirroring
/// [nextTrackIndex], where they stop at the last track instead of
/// wrapping (a wrap on prev but a stop on next read as a broken
/// next button at the end of the queue).
int prevTrackIndex(
  PlayMode mode,
  int current,
  int length, {
  Random? random,
}) {
  if (length <= 0 || current < 0 || current >= length) return -1;
  if (mode == PlayMode.shuffle) {
    if (length == 1) return current;
    final rng = random ?? Random();
    var n = current;
    while (n == current) {
      n = rng.nextInt(length);
    }
    return n;
  }
  switch (mode) {
    case PlayMode.sequential:
    case PlayMode.single:
      return current == 0 ? -1 : current - 1;
    case PlayMode.listLoop:
    case PlayMode.singleLoop:
    case PlayMode.shuffle:
      return (current - 1 + length) % length;
  }
}
