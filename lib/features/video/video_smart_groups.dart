// Smart Groups (1.1.6, browse A3 §1) — same film, one poster card.
//
// Groups CMS list items that are the same film on different sources /
// with different quality suffixes, so the wall / category page /
// search show one card per film instead of one per source entry.
// Pure functions only — no network, no storage — so the grouping rule
// is unit-testable and cannot drift from the other two places that
// use the same key:
//
// - Search dedup: `CmsClient.dedupeAndRankSearch` (`normTitle|year`).
// - History dedup: `VideoHistoryStore.filmKey` / `_filmMatches`
//   (`normTitle|year`; the rule below is kept behaviour-identical by
//   test, not by sharing code — the store file is owned elsewhere in
//   this merge, so the rule is duplicated here deliberately).
// - Danmaku validation: `vodDanmakuCandidatePasses` (same
//   normalised-title + year gate).
//
// Boundaries (decided, do not re-open):
// - Emby is NOT grouped in v1: Emby items pass through as singletons
//   (own detail page, own resume rules; mixing CMS + Emby versions in
//   one sheet would need two routings + two resume rules).
// - Grouping applies only to lists already fetched (wall row, type
//   page, search results). Never pre-scan the catalogue: the alt
//   sweep (15 s cap) must not run per poster.
// - Different seasons never group: `videoNormTitle` does NOT strip a
//   season suffix, so "庆余年第二季" and "庆余年" stay separate —
//   exactly as intended. Do NOT use `doubanTitleKey` here: it strips
//   the season suffix and would merge seasons.

import '../../services/video/emby_client.dart';
import 'video_models.dart';
import 'video_title_helpers.dart';

/// Group key: `normTitle|year` ('' when the title normalises to
/// empty — untitled items never group).
String groupFilmKey(VideoItem item) {
  final t = videoNormTitle(item.name);
  if (t.isEmpty) return '';
  final y = item.year.trim();
  return y.isEmpty ? t : '$t|$y';
}

/// Whether two (title, year) pairs denote the same film for merge
/// purposes. Years must agree when BOTH are known; a missing year on
/// either side is "unknown, may match" (a legacy year-less row is
/// absorbed by its film instead of lingering as a duplicate). Two
/// rows with different KNOWN years never match (remake protection).
bool filmMatches(
  String titleA,
  String yearA,
  String titleB,
  String yearB,
) {
  if (videoNormTitle(titleA) != videoNormTitle(titleB)) return false;
  final ya = yearA.trim();
  final yb = yearB.trim();
  if (ya.isEmpty || yb.isEmpty) return true;
  return ya == yb;
}

/// One film on the wall: its representative (the card shown) + every
/// version found in the fetched list.
class GroupedVideoItem {
  const GroupedVideoItem({
    required this.key,
    required this.representative,
    required this.versions,
  });

  /// Group key ('' for singletons that never grouped).
  final String key;

  /// Card shown on the wall: highest score wins (same winner rule as
  /// `dedupeAndRankSearch`); a version with artwork beats a scoreless
  /// / imageless tie. First-seen wins the remaining ties.
  final VideoItem representative;

  /// All versions in fetched-list order (representative included).
  final List<VideoItem> versions;

  bool get isSingle => versions.length <= 1;

  /// True when the representative is an Emby item (v1: always a
  /// singleton — Emby never groups).
  bool get isEmby => representative.sourceKey == EmbyClient.sourceId;
}

VideoItem _pickRepresentative(List<VideoItem> versions) {
  var best = versions.first;
  for (var i = 1; i < versions.length; i++) {
    final v = versions[i];
    if (v.scoreNum > best.scoreNum) {
      best = v;
    } else if (v.scoreNum == best.scoreNum &&
        best.pic.isEmpty &&
        v.pic.isNotEmpty) {
      best = v;
    }
  }
  // The card shows the best artwork available in the group: a
  // higher-scored version without a poster must not blank the card
  // when a sibling carries one.
  if (best.pic.isEmpty) {
    for (final v in versions) {
      if (v.pic.isNotEmpty) return best.copyWith(pic: v.pic);
    }
  }
  return best;
}

/// Group an already-fetched list, preserving first-seen order.
/// Emby items and untitled items pass through as singletons.
List<GroupedVideoItem> groupVideoItems(List<VideoItem> items) {
  final groups = <GroupedVideoItem>[];
  for (final item in items) {
    if (item.sourceKey == EmbyClient.sourceId) {
      groups.add(
        GroupedVideoItem(key: '', representative: item, versions: [item]),
      );
      continue;
    }
    final key = groupFilmKey(item);
    if (key.isEmpty) {
      groups.add(
        GroupedVideoItem(key: '', representative: item, versions: [item]),
      );
      continue;
    }
    var slot = -1;
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      if (g.key.isEmpty || g.isEmby) continue;
      if (filmMatches(
        item.name,
        item.year,
        g.representative.name,
        g.representative.year,
      )) {
        slot = i;
        break;
      }
    }
    if (slot < 0) {
      groups.add(
        GroupedVideoItem(key: key, representative: item, versions: [item]),
      );
    } else {
      final g = groups[slot];
      final versions = [...g.versions, item];
      groups[slot] = GroupedVideoItem(
        key: g.key,
        representative: _pickRepresentative(versions),
        versions: versions,
      );
    }
  }
  return groups;
}
