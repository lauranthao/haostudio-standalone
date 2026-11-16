// Video models — Apple CMS + Douban (standalone).
//
// Field names/semantics mirror the web app.js models so the port stays
// 1:1 with the source of truth:
// - Video item: {source, sourceName, vodId, name, pic, year, type, area,
//   score, total, remarks, hits}
// - Detail: {ok, meta, lines}; line = {name, episodes: [{name, url}]}
// - Douban is the SOLE metadata source (TMDB is OUT of the standalone
//   entirely — no TMDB calls, logo, or ratings anywhere here).
// - Video ceiling is 1080p — NO 4K (no true 4K in free Apple CMS sources;
//   never label 4K).
// - VOD has NO quality tiers (one URL per episode) and therefore NO
//   quality selector anywhere in the video UI (live only — hard rule).

/// One Apple CMS source. `kind: 'play'` = search + play; `kind:
/// 'search'` = search only (its play URLs are not trusted).
/// `sort` ascending = priority. `enabled: false` = shipped off.
/// Source ids drift daily — never hardcode video ids.
class VideoSource {
  const VideoSource({
    required this.id,
    required this.name,
    required this.apiUrl,
    this.kind = 'play',
    this.enabled = true,
    this.sort = 999,
  });

  factory VideoSource.fromJson(Map<String, dynamic> json) => VideoSource(
        id: json['id'],
        name: (json['name'] as String?) ?? '',
        apiUrl: (json['apiUrl'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? 'play',
        enabled: json['enabled'] as bool? ?? true,
        sort: (json['sort'] as num?)?.toInt() ?? 999,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'apiUrl': apiUrl,
        'kind': kind,
        'enabled': enabled,
        'sort': sort,
      };

  /// `id` is an int in the shipped defaults but user-added sources may
  /// carry a string id; keep it dynamic and compare via [idKey].
  final dynamic id;
  final String name;
  final String apiUrl;
  final String kind;
  final bool enabled;
  final int sort;

  String get idKey => id.toString();

  bool get isPlay => kind == 'play';

  VideoSource copyWith({bool? enabled, int? sort}) => VideoSource(
        id: id,
        name: name,
        apiUrl: apiUrl,
        kind: kind,
        enabled: enabled ?? this.enabled,
        sort: sort ?? this.sort,
      );
}

/// One video item (search / home row / daily / by-type).
class VideoItem {
  const VideoItem({
    required this.source,
    required this.sourceName,
    required this.vodId,
    required this.name,
    this.pic = '',
    this.picAlt = '',
    this.year = '',
    this.type = '',
    this.area = '',
    this.score = '',
    this.total = '',
    this.remarks = '',
    this.hits = 0,
  });

  factory VideoItem.fromJson(Map<String, dynamic> json) => VideoItem(
        source: json['source'],
        sourceName: (json['sourceName'] as String?) ?? '',
        vodId: (json['vodId'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        pic: (json['pic'] as String?) ?? '',
        picAlt: (json['picAlt'] as String?) ?? '',
        year: (json['year'] as String?) ?? '',
        type: (json['type'] as String?) ?? '',
        area: (json['area'] as String?) ?? '',
        score: (json['score'] as String?) ?? '',
        total: (json['total'] as String?) ?? '',
        remarks: (json['remarks'] as String?) ?? '',
        hits: (json['hits'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        'sourceName': sourceName,
        'vodId': vodId,
        'name': name,
        'pic': pic,
        'picAlt': picAlt,
        'year': year,
        'type': type,
        'area': area,
        'score': score,
        'total': total,
        'remarks': remarks,
        'hits': hits,
      };

  final dynamic source;
  final String sourceName;
  final String vodId;
  final String name;
  final String pic;

  /// CMS pic kept when Douban replaces [pic] (Douban poster wins).
  final String picAlt;
  final String year;
  final String type;
  final String area;
  final String score;
  final String total;
  final String remarks;
  final int hits;

  String get sourceKey => source.toString();

  /// `source|vodId` — the identity key for history / favourites / cache.
  String get identityKey => '$sourceKey|$vodId';

  double get scoreNum => double.tryParse(score.trim()) ?? 0;

  bool get hasUsableScore => scoreNum > 0;

  VideoItem copyWith({
    String? pic,
    String? picAlt,
    String? score,
    String? type,
    String? area,
    String? year,
  }) =>
      VideoItem(
        source: source,
        sourceName: sourceName,
        vodId: vodId,
        name: name,
        pic: pic ?? this.pic,
        picAlt: picAlt ?? this.picAlt,
        year: year ?? this.year,
        type: type ?? this.type,
        area: area ?? this.area,
        score: score ?? this.score,
        total: total,
        remarks: remarks,
        hits: hits,
      );
}

/// One episode inside a play line.
class PlayEpisode {
  const PlayEpisode({required this.name, required this.url});

  factory PlayEpisode.fromJson(Map<String, dynamic> json) => PlayEpisode(
        name: (json['name'] as String?) ?? '正片',
        url: (json['url'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'url': url,
      };

  final String name;
  final String url;
}

/// One play line (`vod_play_from` name + its episodes).
class PlayLine {
  const PlayLine({required this.name, required this.episodes});

  factory PlayLine.fromJson(Map<String, dynamic> json) => PlayLine(
        name: (json['name'] as String?) ?? '',
        episodes: (json['episodes'] as List<dynamic>? ?? const [])
            .map((e) => PlayEpisode.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'episodes': episodes.map((e) => e.toJson()).toList(),
      };

  final String name;
  final List<PlayEpisode> episodes;
}

/// Detail-page metadata (CMS fields, Douban-merged in place).
class VideoMeta {
  VideoMeta({
    required this.name,
    this.pic = '',
    this.picAlt = '',
    this.year = '',
    this.type = '',
    this.area = '',
    this.remarks = '',
    this.score = '',
    this.actor = '',
    this.director = '',
    this.content = '',
    this.runtime,
    this.releaseDate = '',
    this.douban,
  });

  factory VideoMeta.fromJson(Map<String, dynamic> json) => VideoMeta(
        name: (json['name'] as String?) ?? '',
        pic: (json['pic'] as String?) ?? '',
        picAlt: (json['picAlt'] as String?) ?? '',
        year: (json['year'] as String?) ?? '',
        type: (json['type'] as String?) ?? '',
        area: (json['area'] as String?) ?? '',
        remarks: (json['remarks'] as String?) ?? '',
        score: (json['score'] as String?) ?? '',
        actor: (json['actor'] as String?) ?? '',
        director: (json['director'] as String?) ?? '',
        content: (json['content'] as String?) ?? '',
        runtime: (json['runtime'] as num?)?.toInt(),
        releaseDate: (json['releaseDate'] as String?) ?? '',
        douban: json['douban'] == null
            ? null
            : DoubanMark.fromJson(json['douban'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'pic': pic,
        'picAlt': picAlt,
        'year': year,
        'type': type,
        'area': area,
        'remarks': remarks,
        'score': score,
        'actor': actor,
        'director': director,
        'content': content,
        'runtime': runtime,
        'releaseDate': releaseDate,
        'douban': douban?.toJson(),
      };

  String name;
  String pic;
  String picAlt;
  String year;
  String type;
  String area;
  String remarks;
  String score;
  String actor;
  String director;
  String content;

  /// Runtime in minutes (Douban only; CMS has none).
  int? runtime;
  String releaseDate;

  /// Set once Douban enrichment lands (score came from Douban).
  DoubanMark? douban;

  /// Plain-text synopsis (CMS content may contain HTML).
  String get plainContent =>
      content.replaceAll(RegExp(r'<[^>]*>'), '').trim();

  List<String> get castNames => actor
      .split(RegExp(r'[,，、]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .take(8)
      .toList();

  /// Genre chips: `m.type` split on `/`, up to 3 (Infuse D4). A single
  /// category stays in the meta line, never as chips.
  List<String> get genreChips {
    if (!type.contains('/')) return const [];
    return type.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).take(3).toList();
  }

  double get scoreNum => double.tryParse(score.trim()) ?? 0;
  bool get hasUsableScore => scoreNum > 0;
}

/// Marker that the score/poster came from Douban (renders a 豆瓣 mark).
class DoubanMark {
  const DoubanMark({required this.id, this.score, this.poster = ''});

  factory DoubanMark.fromJson(Map<String, dynamic> json) => DoubanMark(
        id: (json['id'] as String?) ?? '',
        score: (json['score'] as String?) ?? '',
        poster: (json['poster'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'score': score,
        'poster': poster,
      };

  final String id;
  final String? score;
  final String poster;
}

/// Full detail result: meta + playable lines.
class VideoDetail {
  const VideoDetail({
    required this.source,
    required this.vodId,
    required this.meta,
    required this.lines,
  });

  factory VideoDetail.fromJson(Map<String, dynamic> json) => VideoDetail(
        source: json['source'],
        vodId: (json['vodId'] as String?) ?? '',
        meta: VideoMeta.fromJson(json['meta'] as Map<String, dynamic>),
        lines: (json['lines'] as List<dynamic>? ?? const [])
            .map((e) => PlayLine.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        'vodId': vodId,
        'meta': meta.toJson(),
        'lines': lines.map((l) => l.toJson()).toList(),
      };

  final dynamic source;
  final String vodId;
  final VideoMeta meta;
  final List<PlayLine> lines;

  String get sourceKey => source.toString();

  bool get usable => lines.isNotEmpty && lines.any((l) => l.episodes.isNotEmpty);

  int get totalEpisodes =>
      lines.fold(0, (sum, l) => sum + l.episodes.length);
}

/// One home row: a CMS type + its items.
class VideoHomeRow {
  const VideoHomeRow({
    required this.name,
    required this.count,
    required this.items,
  });

  factory VideoHomeRow.fromJson(Map<String, dynamic> json) => VideoHomeRow(
        name: (json['name'] as String?) ?? '',
        count: (json['count'] as num?)?.toInt() ?? 0,
        items: (json['items'] as List<dynamic>? ?? const [])
            .map((e) => VideoItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'count': count,
        'items': items.map((e) => e.toJson()).toList(),
      };

  final String name;
  final int count;
  final List<VideoItem> items;
}

/// Home data: rows + collections (first 5 rows, poster-style).
class VideoHomeData {
  const VideoHomeData({required this.rows, required this.fetchedAt});

  factory VideoHomeData.fromJson(Map<String, dynamic> json) => VideoHomeData(
        rows: (json['rows'] as List<dynamic>? ?? const [])
            .map((e) => VideoHomeRow.fromJson(e as Map<String, dynamic>))
            .toList(),
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['fetchedAt'] as num?)?.toInt() ?? 0,
        ),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'rows': rows.map((r) => r.toJson()).toList(),
        'fetchedAt': fetchedAt.millisecondsSinceEpoch,
      };

  final List<VideoHomeRow> rows;
  final DateTime fetchedAt;

  /// Collections = first 5 rows (Infuse-style poster collections).
  List<VideoHomeRow> get collections => rows.take(5).toList();
}

/// An alternate source carrying the same title (detail race fallback).
class AltVideoSource {
  const AltVideoSource({required this.source, required this.vodId});

  final dynamic source;
  final String vodId;

  String get sourceKey => source.toString();
}

/// Douban enriched detail (same merge shape as the web).
class DoubanDetail {
  const DoubanDetail({
    required this.id,
    required this.media,
    required this.title,
    this.year,
    this.poster = '',
    this.overview = '',
    this.score,
    this.genres = const [],
    this.runtime,
    this.countries = const [],
    this.director = '',
    this.castNames = const [],
    this.episodes,
  });

  factory DoubanDetail.fromJson(Map<String, dynamic> json) => DoubanDetail(
        id: (json['id'] as String?) ?? '',
        media: (json['media'] as String?) ?? 'movie',
        title: (json['title'] as String?) ?? '',
        year: (json['year'] as String?) ?? '',
        poster: (json['poster'] as String?) ?? '',
        overview: (json['overview'] as String?) ?? '',
        score: (json['score'] as String?) ?? '',
        genres: (json['genres'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        runtime: (json['runtime'] as num?)?.toInt(),
        countries: (json['countries'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        director: (json['director'] as String?) ?? '',
        castNames: (json['castNames'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        episodes: (json['episodes'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'media': media,
        'title': title,
        'year': year,
        'poster': poster,
        'overview': overview,
        'score': score,
        'genres': genres,
        'runtime': runtime,
        'countries': countries,
        'director': director,
        'castNames': castNames,
        'episodes': episodes,
      };

  final String id;

  /// 'movie' | 'tv' (from abstract `is_tv`).
  final String media;
  final String title;
  final String? year;
  final String poster;
  final String overview;
  final String? score;
  final List<String> genres;
  final int? runtime;
  final List<String> countries;
  final String director;
  final List<String> castNames;
  final String? episodes;
}

/// Continue Watching entry (local history, `hao_video_hist` shape).
class WatchHistoryEntry {
  const WatchHistoryEntry({
    required this.source,
    required this.vodId,
    required this.title,
    this.pic = '',
    this.picAlt = '',
    this.lineIdx = 0,
    this.epIdx = 0,
    this.epName = '',
    this.position = 0,
    this.duration = 0,
    required this.at,
  });

  factory WatchHistoryEntry.fromJson(Map<String, dynamic> json) =>
      WatchHistoryEntry(
        source: json['source'],
        vodId: (json['vodId'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        pic: (json['pic'] as String?) ?? '',
        picAlt: (json['picAlt'] as String?) ?? '',
        lineIdx: (json['lineIdx'] as num?)?.toInt() ?? 0,
        epIdx: (json['epIdx'] as num?)?.toInt() ?? 0,
        epName: (json['epName'] as String?) ?? '',
        position: (json['position'] as num?)?.toDouble() ?? 0,
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
        at: DateTime.fromMillisecondsSinceEpoch(
          (json['at'] as num?)?.toInt() ?? 0,
        ),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        'vodId': vodId,
        'title': title,
        'pic': pic,
        'picAlt': picAlt,
        'lineIdx': lineIdx,
        'epIdx': epIdx,
        'epName': epName,
        'position': position,
        'duration': duration,
        'at': at.millisecondsSinceEpoch,
      };

  final dynamic source;
  final String vodId;
  final String title;
  final String pic;
  final String picAlt;
  final int lineIdx;
  final int epIdx;
  final String epName;
  final double position;
  final double duration;
  final DateTime at;

  String get sourceKey => source.toString();
  String get identityKey => '$sourceKey|$vodId';

  double get progressFraction =>
      duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0;

  bool get isFinished => duration > 0 && position >= duration - 30;

  /// "还剩 X 分钟" (Infuse H5) when duration + position are known.
  String get remainingLabel {
    if (duration <= 0 || position <= 0) return '';
    final left = ((duration - position) / 60).round();
    if (left <= 0) return '已看完';
    return '还剩 $left 分钟';
  }
}

/// Saved resume position (vodLocalLoad rule: only counts when > 10 s in
/// and >= 30 s from the end).
class ResumeInfo {
  const ResumeInfo({
    required this.lineIdx,
    required this.epIdx,
    required this.epName,
    required this.position,
    required this.duration,
  });

  final int lineIdx;
  final int epIdx;
  final String epName;
  final double position;
  final double duration;

  /// Port of `vodLocalLoad`: position > 10 s and >= 30 s from the end.
  static ResumeInfo? fromStored(Map<String, dynamic>? stored, List<PlayLine> lines) {
    if (stored == null || lines.isEmpty) return null;
    final li = (stored['lineIdx'] as num?)?.toInt() ?? 0;
    final ei = (stored['epIdx'] as num?)?.toInt() ?? 0;
    if (li < 0 || li >= lines.length) return null;
    final eps = lines[li].episodes;
    if (ei < 0 || ei >= eps.length) return null;
    final pos = (stored['position'] as num?)?.toDouble() ?? 0;
    final dur = (stored['duration'] as num?)?.toDouble() ?? 0;
    if (pos <= 10) return null;
    if (dur > 0 && pos >= dur - 30) return null;
    return ResumeInfo(
      lineIdx: li,
      epIdx: ei,
      epName: (stored['epName'] as String?) ?? '',
      position: pos,
      duration: dur,
    );
  }
}
