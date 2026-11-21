// Missing-episode chips (1.1.6 缺集接续): the episode row shows the
// base line's episodes plus the episodes only other sources carry,
// merged by exact episode number (see [parseEpisodeNumber] — never
// guessed from a title). A missing chip is greyed with an "其他源"
// badge; tapping it switches to the source that carries that episode
// and plays it (see `_VideoDetailPageState._playMissingEpisode`).
// Present episodes are untouched: same card, same order, same tap
// behaviour — only missing chips gain the badge and the grey.
import 'video_models.dart';

/// One row in the merged episode list: either an episode of the
/// current line ([epIdx] into the base line) or an episode only an
/// alt source carries ([episodeNumber] + [target]).
class EpisodeChipItem {
  const EpisodeChipItem.base(this.epIdx)
      : episodeNumber = null,
        target = null;

  const EpisodeChipItem.missing(this.episodeNumber, this.target)
      : epIdx = null;

  /// Index into the base line's episodes (base chips only).
  final int? epIdx;

  /// Episode number (missing chips only).
  final int? episodeNumber;

  /// Where the missing episode can be played (missing chips only).
  final EpisodeUnionTarget? target;

  bool get isMissing => target != null;
}

/// Merge the current line's episodes with the missing episodes from
/// the multi-source union, in episode-number order: a missing number
/// is inserted before the first base episode with a larger number.
/// Unparseable base names (正片/花絮) stay in place and never shift
/// the insertion. Numbers the union has but the base also has are
/// never emitted as missing chips.
List<EpisodeChipItem> mergeEpisodeChips({
  required List<PlayEpisode> base,
  required Map<int, EpisodeUnionTarget> union,
}) {
  final missing = missingEpisodeNumbers(union);
  final out = <EpisodeChipItem>[];
  var mi = 0;
  for (var bi = 0; bi < base.length; bi++) {
    final n = base[bi].episodeNumber;
    if (n != null) {
      while (mi < missing.length && missing[mi] < n) {
        out.add(EpisodeChipItem.missing(missing[mi], union[missing[mi]]!));
        mi++;
      }
    }
    out.add(EpisodeChipItem.base(bi));
  }
  while (mi < missing.length) {
    out.add(EpisodeChipItem.missing(missing[mi], union[missing[mi]]!));
    mi++;
  }
  return out;
}
