// Lyric display tools (build 29, music) — 歌词偏移 / 翻译显隐.
//
// What exists and what does not (verified 2026-11-22, live probe of
// the NetEase lyric endpoint for 186016 晴天 / 185811 稻香 / 145689):
// the response carries `lrc` (line-level) + `tlyric` (translation)
// and NO `yrc` / `romalrc` key at all, and `klyric` (karaoke) is
// present but an empty string. QQ returns line-level LRC only and
// Kuwo returns `lrclist` line times only (see MusicApi._fetchLyrics).
// So there is NO word-level timing in any existing lyric source —
// 逐字卡拉 OK cannot be built from real data this round, and no
// fake per-word timing is invented. What IS built: a per-user lyric
// offset (±5 s, shifts which line is active) and a translation
// show/hide switch (the `tlyric` data was already fetched, only
// never toggleable).
//
// 罗马音 is likewise not built: no lyric source returns romaji, the
// app bundles no pinyin data, and pubspec is frozen for this group
// (no new dependency). The native route (CFStringTransform
// Mandarin-Latin) belongs to the native group, not this one.

import 'music_models.dart';

class LyricDisplay {
  LyricDisplay._();

  /// Offset range (ms): ±5 s, 100 ms steps in the UI.
  static const int maxOffsetMs = 5000;

  static int clampOffsetMs(int ms) => ms.clamp(-maxOffsetMs, maxOffsetMs);

  /// The lyric line active at [position] with [offsetMs] applied:
  /// a positive offset treats the lyrics as EARLY (the active line
  /// moves forward), a negative offset as LATE. The offset only
  /// shifts which line highlights — tapping a line still seeks to
  /// its true timestamp.
  static int lyricIndexFor(
    List<LyricLine> lines,
    Duration position,
    int offsetMs,
  ) {
    if (lines.isEmpty) return -1;
    final t = position.inMilliseconds / 1000 + offsetMs / 1000;
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].t <= t) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  /// Human offset label ("+1.5s", "-0.5s", "0s").
  static String offsetLabel(int offsetMs) {
    if (offsetMs == 0) return '0s';
    final sign = offsetMs > 0 ? '+' : '-';
    final abs = offsetMs.abs();
    final whole = abs ~/ 1000;
    final frac = (abs % 1000) ~/ 100;
    return frac == 0 ? '$sign${whole}s' : '$sign$whole.${frac}s';
  }
}
