// Video title helpers — verbatim ports of the web app.js functions
// (`videoNormTitle`, `videoQueryParts`, `videoRankScore`,
// `videoRankSort`, `vodStripSeasonSuffix`). Search ranking parity with
// the shop server is tested (videosearch_rank_test.js in the web tree);
// keep these two functions behaviour-identical, do not "improve" them.

import 'video_models.dart';

/// Normalise a video title for matching/dedupe: lowercase, collapse
/// whitespace, strip up to 3 trailing parenthesised suffixes matching a
/// year / quality word, then up to 3 trailing bare quality words, then
/// trailing separators.
String videoNormTitle(String? s) {
  var n = (s ?? '').toLowerCase().replaceAll(RegExp(r'[\s　]+'), ' ').trim();
  final parenSuffix = RegExp(
    r'^(19|20)\d{2}$|hd|高清|超清|蓝光|\b4k\b|国语|粤语|中字|正片|完整版|抢先版|未删减',
  );
  for (var i = 0; i < 3; i++) {
    final m = RegExp(r'[\s\-–—:：·]*[（(]([^）)]*)[）)]\s*$').firstMatch(n);
    if (m != null && parenSuffix.hasMatch(m.group(1)!.trim())) {
      n = n
          .substring(0, m.start)
          .replaceAll(RegExp(r'[\s\-–—:：·]+$'), '');
      continue;
    }
    break;
  }
  for (var i = 0; i < 3; i++) {
    final n2 = n.replaceAll(
      RegExp(r'[\s\-–—:：·]*(hd|高清|超清|蓝光|4k|正片|完整版|抢先版|未删减|导演剪辑版)\s*$'),
      '',
    );
    if (n2 == n) break;
    n = n2;
  }
  return n.replaceAll(RegExp(r'[\s\-–—:：·.]+$'), '').trim();
}

/// Split a query into a normalised title + trailing year (0 = none).
({String qn, int year}) videoQueryParts(String? q) {
  final s = (q ?? '').trim();
  final ym = RegExp(r'(19|20)\d{2}').allMatches(s).toList();
  final year = ym.isEmpty ? 0 : int.parse(ym.last.group(0)!);
  final qn = videoNormTitle(
    year != 0
        ? s.replaceAll(RegExp(r'(19|20)\d{2}'), ' ').replaceAll(RegExp(r'[\s　]+'), ' ').trim()
        : s,
  );
  return (qn: qn, year: year);
}

/// Rank score: exact normalised-title match first, then starts-with,
/// then contains, then everything else.
int videoRankScore(VideoItem item, String qn) {
  final n = videoNormTitle(item.name);
  if (n == qn) return 0;
  if (n.startsWith(qn)) return 1;
  if (n.contains(qn)) return 2;
  return 3;
}

/// Sort a search result list in place: rank score, then query-year
/// match, then year desc, then score desc. Returns the same list.
List<VideoItem> videoRankSort(List<VideoItem> list, String q) {
  final p = videoQueryParts(q);
  list.sort((a, b) {
    final d = videoRankScore(a, p.qn) - videoRankScore(b, p.qn);
    if (d != 0) return d;
    if (p.year != 0) {
      final ya = int.tryParse(a.year) ?? 0;
      final yb = int.tryParse(b.year) ?? 0;
      final da = (ya == p.year ? 0 : 1) - (yb == p.year ? 0 : 1);
      if (da != 0) return da;
    }
    final y = (int.tryParse(b.year) ?? 0) - (int.tryParse(a.year) ?? 0);
    if (y != 0) return y;
    return (double.tryParse(b.score) ?? 0)
        .compareTo(double.tryParse(a.score) ?? 0);
  });
  return list;
}

/// Strip a trailing season suffix ("xxx第2季" / "Show Season 2" / "S2")
/// so title lookups use the base series title. Returns the base title
/// and whether anything was stripped. NOTE: stripping is a SEARCH
/// concern only — never invent season labels from title suffixes in UI
/// (fix 17.5: no fake "Season 1" dropdown anywhere).
({String base, bool stripped}) vodStripSeasonSuffix(String? title) {
  var base = (title ?? '').trim();
  if (base.isEmpty) return (base: base, stripped: false);
  const cn = r'[0-9０-９]{1,2}|[一二三四五六七八九十百千]+';
  final pats = <RegExp>[
    RegExp(
      '[\\s\\-–—:：·]*[\\(（]\\s*(?:第(?:$cn)季|Season\\s+[0-9]{1,2}(?:\\s+Part\\s+[0-9]{1,2})?|S[0-9]{1,2})\\s*[\\)）]\\s*\$',
      caseSensitive: false,
    ),
    RegExp('第(?:$cn)季\\s*\$'),
    RegExp(r'\s*Season\s+[0-9]{1,2}(?:\s+Part\s+[0-9]{1,2})?\s*$',
        caseSensitive: false),
    RegExp(r'\s*S[0-9]{1,2}\s*$', caseSensitive: false),
  ];
  var stripped = false;
  for (var i = 0; i < 3 && base.isNotEmpty; i++) {
    var changed = false;
    for (final p in pats) {
      final nb = base.replaceAll(p, '').trim();
      if (nb != base) {
        base = nb;
        changed = true;
        stripped = true;
        break;
      }
    }
    if (!changed) break;
  }
  if (stripped) {
    base = base.replaceAll(RegExp(r'[\s\-–—:：·.,]+$'), '').trim();
  }
  if (base.isEmpty) {
    return (base: (title ?? '').trim(), stripped: false);
  }
  return (base: base, stripped: stripped);
}

/// Strip HTML tags (CMS synopsis may contain HTML).
String stripHtmlTags(String? s) =>
    (s ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim();

/// `mm:ss` for a seconds value (resume / elapsed labels).
String formatMmSs(double seconds) {
  final total = seconds.round();
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
