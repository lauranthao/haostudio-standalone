// Douban pure parsers (no I/O) — verbatim ports of app.js
// `doubanParseAbstract` / `doubanParseMPage` / suggest + search-page id
// extraction / `mergeDoubanIntoMeta`.
//
// Douban is the SOLE metadata source for the standalone app (TMDB was
// removed 2026-11-16 — no TMDB calls, logo, or ratings anywhere in the
// standalone build). No key, no login.
//
// Dead ends — do NOT use: douban.uieee.com (hijacked), frodo /
// api.douban.com v2 (public API keys revoked), rexxar search (needs
// login).
//
// Verified fixtures: 流浪地球2 id 35267208 (8.3), 庆余年第一季 id
// 25853071 (7.9).

import '../../features/video/video_models.dart';
import '../../features/video/video_title_helpers.dart';

/// Parse `movie.douban.com/j/subject_abstract?subject_id=<id>`.
/// Returns null when `r==='error'` or no `subject`.
DoubanDetail? parseDoubanAbstract(Map<String, dynamic>? json) {
  if (json == null) return null;
  if (json['r'] == 'error') return null;
  final s = json['subject'] as Map<String, dynamic>?;
  if (s == null) return null;
  final duration = (s['duration'] as String?) ?? '';
  final mm = RegExp(r'(\d+)').firstMatch(duration);
  final rate = s['rate'];
  final directors = (s['directors'] as List<dynamic>? ?? const [])
      .map((e) => e.toString())
      .where((e) => e.isNotEmpty)
      .toList();
  final actors = (s['actors'] as List<dynamic>? ?? const [])
      .map((e) => e.toString())
      .where((e) => e.isNotEmpty)
      .toList();
  final region = (s['region'] as String?) ?? '';
  final rateStr = rate?.toString();
  return DoubanDetail(
    id: (s['id'] ?? '').toString(),
    media: s['is_tv'] == true ? 'tv' : 'movie',
    title: (s['title'] as String?) ?? '',
    year: s['release_year']?.toString(),
    score: rateStr?.isNotEmpty == true ? rateStr : null,
    genres: (s['types'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList(),
    director: directors.join('/'),
    castNames: actors.take(10).toList(),
    runtime: int.tryParse(mm?.group(1) ?? ''),
    countries: region.isNotEmpty ? [region] : const [],
    episodes: s['episodes_count']?.toString(),
  );
}

/// Parse the mobile page `m.douban.com/movie/subject/<id>/` →
/// `{poster, overview, score}`. Port of `doubanParseMPage` exactly,
/// except the poster tier (F1, build 28): poster via og:image `pNNNN`
/// id → l_ratio_poster URL, else any l_ratio_poster match (then m,
/// then s), else the raw og:image; overview from the description meta
/// (entity-decoded, leading `…豆瓣评分：X.X 简介：` prefix stripped);
/// score from the ratingValue meta.
///
/// F1 note — the m page only ever embeds s_ratio_poster thumbnails
/// (verified 2026-11-21 on the real 庆余年 + 流浪地球2 pages: 0
/// l_ratio_poster and 0 m_ratio_poster occurrences), so a bare
/// regex search for an embedded l URL can never match. The l URL
/// is built by swapping ONLY the tier segment of the embedded URL
/// found (host + p-id untouched — the imgN host must stay the one
/// the page gave, per the 418 check in §2.2). The l→m→s order
/// picks which embedded URL to rewrite when several are present.
({String poster, String overview, String? score}) parseDoubanMPage(
  String? html,
) {
  if (html == null || html.isEmpty) {
    return (poster: '', overview: '', score: null);
  }
  var poster = '';
  final og = RegExp(r'<meta[^>]*property="og:image"[^>]*content="([^"]+)"')
          .firstMatch(html) ??
      RegExp(r'<meta[^>]*content="([^"]+)"[^>]*property="og:image"')
          .firstMatch(html);
  final ogUrl = og != null ? og.group(1)!.replaceAll('&amp;', '&') : '';
  final idm = RegExp(r'/public/(p\d+)\.jpg').firstMatch(ogUrl);
  if (idm != null) {
    // F1: prefer an embedded l URL, then m, then s — then rewrite
    // the tier segment to l (see the doc comment above for why a
    // plain l search can never match a real m page).
    for (final tier in const [
      'l_ratio_poster',
      'm_ratio_poster',
      's_ratio_poster',
    ]) {
      final re = RegExp(
        'https://img\\d+\\.doubanio\\.com/view/photo/$tier/public/${idm.group(1)}\\.jpg',
      );
      final m2 = re.firstMatch(html);
      if (m2 != null) {
        poster = m2.group(0)!.replaceFirst(tier, 'l_ratio_poster');
        break;
      }
    }
  }
  if (poster.isEmpty) {
    for (final tier in const [
      'l_ratio_poster',
      'm_ratio_poster',
      's_ratio_poster',
    ]) {
      final m3 = RegExp(
        'https://img\\d+\\.doubanio\\.com/view/photo/$tier/public/p\\d+\\.jpg',
      ).firstMatch(html);
      if (m3 != null) {
        poster = m3.group(0)!.replaceFirst(tier, 'l_ratio_poster');
        break;
      }
    }
  }
  if (poster.isEmpty && ogUrl.isNotEmpty) poster = ogUrl;

  var overview = '';
  final dm = RegExp(r'<meta[^>]*itemprop="description"[^>]*content="([^"]*)"')
          .firstMatch(html) ??
      RegExp(r'<meta[^>]*content="([^"]*)"[^>]*itemprop="description"')
          .firstMatch(html);
  if (dm != null) {
    final txt = dm
        .group(1)!
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#39;', "'");
    overview = txt.replaceAll(RegExp(r'^.*?豆瓣评分：[\d.]+ *简介：'), '').trim();
  }

  String? score;
  final rm = RegExp(r'<meta[^>]*itemprop="ratingValue"[^>]*content="([\d.]+)"')
      .firstMatch(html);
  if (rm != null) score = rm.group(1);
  return (poster: poster, overview: overview, score: score);
}

/// Suggest endpoint: `movie.douban.com/j/subject_suggest?q=<title>` —
/// JSON array; take `arr[0].id`.
String? parseDoubanSuggestId(dynamic json) {
  if (json is List && json.isNotEmpty) {
    final first = json.first;
    if (first is Map<String, dynamic> && first['id'] != null) {
      return first['id'].toString();
    }
  }
  return null;
}

/// Desktop page `movie.douban.com/subject/<id>/` cast section →
/// `{actor name: avatar URL}`.
///
/// The celebrities list renders each person as `<li class="celebrity">`
/// with the avatar as a
/// `background-image:url(https://imgN.doubanio.com/view/celebrity/s_ratio_celebrity/public/p....jpg)`
/// and the name in `<span class="name"><a>…</a></span>`.
/// Directors are in the list too; callers match by name against the
/// abstract's actor list, so they are ignored there.
Map<String, String> parseDoubanDesktopCast(String? html) {
  final out = <String, String>{};
  if (html == null || html.isEmpty) return out;
  final blockRe = RegExp(r'<li class="celebrity">(.*?)</li>', dotAll: true);
  final avatarRe = RegExp(
    r'https://img\d+\.doubanio\.com/view/celebrity/s_ratio_celebrity/public/p[\w.]+?\.jpg',
  );
  final nameRe = RegExp(r'<span class="name">\s*<a[^>]*>([^<]+)</a>');
  for (final block in blockRe.allMatches(html)) {
    final body = block.group(1) ?? '';
    final avatar = avatarRe.firstMatch(body)?.group(0);
    final name = nameRe.firstMatch(body)?.group(1)?.trim();
    if (avatar != null && name != null && name.isNotEmpty) {
      out.putIfAbsent(name, () => avatar);
    }
  }
  return out;
}

/// Baidu Baike lemma card (`BaikeLemmaCardApi`, free, no key) → actor
/// photo URL, or null.
///
/// The Douban desktop subject page — the v1.0.5 cast-photo source — is
/// login-walled for anonymous requests (302 to sec.douban.com, then
/// `error code: 008, please Login`), so its parser always returns an
/// empty map in production. Baike is the fallback that actually works
/// (verified 2026-11-17: 张若昀/李沁/陈道明/吴刚 all return a real
/// bkimg.cdn.bcebos.com JPEG, 200 with a browser UA and no Referer).
///
/// Guards against wrong-person matches: `title` must equal [name]
/// exactly, and a non-empty `desc` must describe an entertainer
/// (演员/歌手/艺人/明星/导演/主持/偶像/童星/舞者) — e.g. 吴刚 the actor
/// (desc 中国内地男演员) passes, 张三 (desc 人物泛称) is rejected.
String? parseBaikeCardPhoto(Map<String, dynamic>? json, String name) {
  if (json == null || name.isEmpty) return null;
  final title = (json['title'] as String?)?.trim() ?? '';
  if (title != name) return null;
  final desc = (json['desc'] as String?) ?? '';
  const entertainer = [
    '演员',
    '歌手',
    '艺人',
    '明星',
    '导演',
    '主持',
    '偶像',
    '童星',
    '舞者',
  ];
  if (desc.isNotEmpty && !entertainer.any(desc.contains)) return null;
  final image = (json['image'] as String?)?.trim() ?? '';
  if (image.isEmpty) return null;
  return image;
}

/// Desktop search fallback: `www.douban.com/search?cat=1002&q=<title>` —
/// HTML regex `sid:\s*(\d+)` else `movie.douban.com/subject/(\d+)`.
String? parseDoubanSearchPageId(String? html) {
  if (html == null || html.isEmpty) return null;
  final m = RegExp(r'sid:\s*(\d+)').firstMatch(html) ??
      RegExp(r'movie\.douban\.com/subject/(\d+)').firstMatch(html);
  return m?.group(1);
}

/// Title → id cache key: season-stripped title, whitespace removed,
/// lowercased (`doubanTitleKey`).
String doubanTitleKey(String? title) {
  try {
    return vodStripSeasonSuffix(title)
        .base
        .replaceAll(RegExp(r'\s+'), '')
        .toLowerCase();
  } catch (_) {
    return (title ?? '').replaceAll(RegExp(r'\s+'), '').toLowerCase();
  }
}

/// Merge Douban into CMS meta (`mergeDoubanIntoMeta` — Douban is
/// primary for score/poster, fill-when-missing for the rest). Mutates
/// [meta] in place.
void mergeDoubanIntoMeta(VideoMeta meta, DoubanDetail? dd) {
  if (dd == null) return;
  if (dd.score != null && dd.score!.isNotEmpty) meta.score = dd.score!;
  if (dd.overview.isNotEmpty && meta.plainContent.length < 20) {
    meta.content = dd.overview;
  }
  if (meta.type.isEmpty && dd.genres.isNotEmpty) {
    meta.type = dd.genres.take(3).join('/');
  }
  if (meta.area.isEmpty && dd.countries.isNotEmpty) {
    meta.area = dd.countries.first;
  }
  if (meta.year.isEmpty && dd.year != null && dd.year!.isNotEmpty) {
    meta.year = dd.year!;
  }
  if (meta.director.isEmpty && dd.director.isNotEmpty) {
    meta.director = dd.director;
  }
  if (meta.actor.isEmpty && dd.castNames.isNotEmpty) {
    meta.actor = dd.castNames.join(',');
  }
  if (meta.runtime == null && dd.runtime != null) {
    meta.runtime = dd.runtime;
  }
  if (dd.poster.isNotEmpty) {
    if (meta.pic.isNotEmpty && meta.pic != dd.poster && meta.picAlt.isEmpty) {
      meta.picAlt = meta.pic;
    }
    meta.pic = dd.poster;
  }
  // Cast photos are Douban-ordered (dd.castPhotos aligns with
  // dd.castNames), but the displayed names come from meta.actor, which
  // may be the CMS list in a different order. Zipping by index can
  // attach a photo to the wrong person — align by name instead: a
  // displayed actor only gets a photo when Douban has the same name.
  // (meta.actor was filled from Douban above when it was empty, so
  // that case still aligns exactly.)
  final doubanPhotos = <String, String>{};
  for (var i = 0; i < dd.castNames.length; i++) {
    doubanPhotos[dd.castNames[i]] =
        i < dd.castPhotos.length ? dd.castPhotos[i] : '';
  }
  final alignedPhotos =
      meta.castNames.map((n) => doubanPhotos[n] ?? '').toList();
  meta.douban = DoubanMark(
    id: dd.id,
    score: dd.score,
    poster: dd.poster,
    castPhotos: alignedPhotos,
  );
}
