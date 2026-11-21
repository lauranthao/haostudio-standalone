// Video models — Apple CMS + Douban (standalone).
//
// Field names/semantics mirror the web app.js models so the port stays
// 1:1 with the source of truth:
// - Video item: {source, sourceName, vodId, name, pic, year, type, area,
//   score, total, remarks, hits}
// - Detail: {ok, meta, lines}; line = {name, episodes: [{name, url}]}
// - Douban is the SOLE metadata source (TMDB is OUT of the standalone
//   entirely — no TMDB calls, logo, or ratings anywhere here).
// - CMS video ceiling is 1080p — NO 4K labels on CMS titles (no true 4K
//   in free Apple CMS sources). Emby is exempt: real 4K files label 4K.
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
    this.progressSeconds = 0,
    this.progressFraction = 0,
    this.played = false,
    this.isFavorite = false,
    this.likes,
    this.mediaType = '',
    this.seriesId = '',
    this.seriesName = '',
    this.seasonIndex,
    this.episodeIndex,
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
        progressSeconds:
            (json['progressSeconds'] as num?)?.toDouble() ?? 0,
        progressFraction:
            (json['progressFraction'] as num?)?.toDouble() ?? 0,
        played: json['played'] as bool? ?? false,
        isFavorite: json['isFavorite'] as bool? ?? false,
        likes: json['likes'] as bool?,
        mediaType: (json['mediaType'] as String?) ?? '',
        seriesId: (json['seriesId'] as String?) ?? '',
        seriesName: (json['seriesName'] as String?) ?? '',
        seasonIndex: (json['seasonIndex'] as num?)?.toInt(),
        episodeIndex: (json['episodeIndex'] as num?)?.toInt(),
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
        'progressSeconds': progressSeconds,
        'progressFraction': progressFraction,
        'played': played,
        'isFavorite': isFavorite,
        'likes': likes,
        'mediaType': mediaType,
        'seriesId': seriesId,
        'seriesName': seriesName,
        'seasonIndex': seasonIndex,
        'episodeIndex': episodeIndex,
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

  /// Server-side playback state (Emby UserData; CMS leaves all of
  /// these at their defaults). Read-only here: the server owns them,
  /// the client only displays them and reports progress back.
  /// [progressSeconds] is the resume position in seconds
  /// (UserData.PlaybackPositionTicks / 10,000,000).
  final double progressSeconds;

  /// 0..1 watched fraction (UserData.PlayedPercentage / 100, or
  /// progressSeconds / runtime when the percentage is absent).
  final double progressFraction;

  /// UserData.Played — the server considers this item finished.
  final bool played;

  /// UserData.IsFavorite.
  final bool isFavorite;

  /// UserData.Likes: true = liked, false = disliked, null = no rating.
  final bool? likes;

  /// Emby item type: 'Movie' | 'Series' | 'Episode' ('' on CMS).
  final String mediaType;

  /// Series id this episode belongs to ('' when not an episode).
  final String seriesId;

  /// Series name this episode belongs to ('' when not an episode).
  final String seriesName;

  /// Season number (ParentIndexNumber) / episode number (IndexNumber)
  /// of an episode; null when the server did not supply one.
  final int? seasonIndex;
  final int? episodeIndex;

  double get serverProgressFraction =>
      progressFraction.clamp(0.0, 1.0);

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
    double? progressSeconds,
    double? progressFraction,
    bool? played,
    bool? isFavorite,
    bool? likes,
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
        progressSeconds: progressSeconds ?? this.progressSeconds,
        progressFraction: progressFraction ?? this.progressFraction,
        played: played ?? this.played,
        isFavorite: isFavorite ?? this.isFavorite,
        likes: likes ?? this.likes,
        mediaType: mediaType,
        seriesId: seriesId,
        seriesName: seriesName,
        seasonIndex: seasonIndex,
        episodeIndex: episodeIndex,
      );
}

/// One episode inside a play line.
///
/// [isMissing] marks a synthetic union entry: this episode number
/// exists on another source but NOT on this line's own source, so
/// the episode list can render it as a grey "other source" chip
/// (number only, never a poster/placeholder image) and tapping it
/// switches source instead of playing a local URL. A missing
/// episode's [url] is '' — it must never be opened directly.
///
/// [introStart]/[introEnd]/[creditsStart] (seconds, 1.1.6) ride the
/// skip-intro/outro markers: Emby fills them from `Chapters`
/// (IntroStart/IntroEnd/CreditsStart); CMS leaves them null (no
/// markers — per-episode custom seconds apply instead). Null = no
/// marker; old caches without the fields read as null.
class PlayEpisode {
  const PlayEpisode({
    required this.name,
    required this.url,
    this.isMissing = false,
    this.introStart,
    this.introEnd,
    this.creditsStart,
  });

  factory PlayEpisode.fromJson(Map<String, dynamic> json) => PlayEpisode(
        name: (json['name'] as String?) ?? '正片',
        url: (json['url'] as String?) ?? '',
        isMissing: json['isMissing'] as bool? ?? false,
        introStart: (json['introStart'] as num?)?.toDouble(),
        introEnd: (json['introEnd'] as num?)?.toDouble(),
        creditsStart: (json['creditsStart'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'url': url,
        if (isMissing) 'isMissing': true,
        if (introStart != null) 'introStart': introStart,
        if (introEnd != null) 'introEnd': introEnd,
        if (creditsStart != null) 'creditsStart': creditsStart,
      };

  final String name;
  final String url;
  final bool isMissing;
  final double? introStart;
  final double? introEnd;
  final double? creditsStart;

  /// Episode number parsed from [name] (see [parseEpisodeNumber]);
  /// null when the name carries no parseable number — such an
  /// episode never takes part in cross-source matching (never guessed).
  int? get episodeNumber => parseEpisodeNumber(name);
}

/// Parse an episode number out of an episode name. Strict, never
/// guessing: a name that does not match one of the shapes below
/// yields null, and the caller must treat it as unmatchable.
///
/// Accepted shapes (in priority order):
/// - `第(\d+)集/话/期` — e.g. `第1集`, `第01集`, `第12话`;
/// - `(\d+)集/话` at the start — e.g. `01集`;
/// - `E(\d+)` / `EP(\d+)` (case-insensitive) — e.g. `E05`, `EP12`,
///   including `S02E05` (the E-part wins);
/// - the whole name is 1–3 bare digits — e.g. `01`, `1`, `001`.
///
/// The number must be 1..999: 0 is never an episode, and 4+ digit
/// runs are years/resolutions, never episode numbers (`2024`,
/// `1080P` and `正片` all yield null).
int? parseEpisodeNumber(String name) {
  final s = name.trim();
  if (s.isEmpty) return null;
  int? take(int? n) {
    if (n == null || n < 1 || n > 999) return null;
    return n;
  }

  final cn = RegExp(r'第\s*0*(\d{1,3})\s*[集话期]').firstMatch(s);
  if (cn != null) return take(int.tryParse(cn.group(1)!));
  final bareWithUnit = RegExp(r'^0*(\d{1,3})\s*[集话]$').firstMatch(s);
  if (bareWithUnit != null) {
    return take(int.tryParse(bareWithUnit.group(1)!));
  }
  final e = RegExp(r'[Ee][Pp]?0*(\d{1,3})\b').firstMatch(s);
  if (e != null) return take(int.tryParse(e.group(1)!));
  final bare = RegExp(r'^0*(\d{1,3})$').firstMatch(s);
  if (bare != null) return take(int.tryParse(bare.group(1)!));
  return null;
}

/// Find an episode by exact number across all lines of a detail.
/// Returns null when no episode carries [episodeNumber] — the caller
/// must NOT fall back to a neighbour episode for an automatic
/// continuation (a neighbour is a different episode, not the same
/// one). Name equality is never consulted here: cross-source names
/// differ in format (`第1集` vs `01`), the number is the identity.
({int lineIdx, int epIdx})? findEpisodeByNumber(
  List<PlayLine> lines,
  int episodeNumber,
) {
  for (var li = 0; li < lines.length; li++) {
    final eps = lines[li].episodes;
    for (var ei = 0; ei < eps.length; ei++) {
      if (eps[ei].episodeNumber == episodeNumber) {
        return (lineIdx: li, epIdx: ei);
      }
    }
  }
  return null;
}

/// One entry of the multi-source episode union: where episode
/// [episodeNumber] can be played.
class EpisodeUnionTarget {
  const EpisodeUnionTarget({
    required this.episodeNumber,
    required this.source,
    required this.vodId,
    required this.lineIdx,
    required this.epIdx,
    required this.inBase,
  });

  /// Episode number (the union key).
  final int episodeNumber;

  /// Source/vodId that carries this episode.
  final dynamic source;
  final String vodId;

  /// Line/episode index inside that source's detail.
  final int lineIdx;
  final int epIdx;

  /// True when the BASE detail (the one the user opened) carries it;
  /// false = only an alt source has it (render as a missing chip).
  final bool inBase;
}

/// Build the multi-source episode union for one title: the base
/// detail's episodes plus every alt detail's episodes, keyed by
/// exact episode number. Unparseable episode names are excluded
/// (never guessed into the union). The base detail wins a number
/// when several sources carry it; alts fill the gaps in the order
/// given. The result is the data behind the "missing episode" chips:
/// numbers present in the union but absent from the base are the
/// episodes the user can only watch by switching source.
Map<int, EpisodeUnionTarget> buildEpisodeUnion({
  required VideoDetail base,
  required List<VideoDetail> alts,
}) {
  final union = <int, EpisodeUnionTarget>{};
  void add(VideoDetail detail, bool inBase) {
    for (var li = 0; li < detail.lines.length; li++) {
      final eps = detail.lines[li].episodes;
      for (var ei = 0; ei < eps.length; ei++) {
        final ep = eps[ei];
        if (ep.isMissing) continue;
        final num = ep.episodeNumber;
        if (num == null) continue;
        union.putIfAbsent(
          num,
          () => EpisodeUnionTarget(
            episodeNumber: num,
            source: detail.source,
            vodId: detail.vodId,
            lineIdx: li,
            epIdx: ei,
            inBase: inBase,
          ),
        );
      }
    }
  }

  add(base, true);
  for (final alt in alts) {
    add(alt, false);
  }
  return union;
}

/// Episode numbers the union has that the base detail does not —
/// the missing episodes, ascending. Numbers no source carries never
/// appear here (the union never invents episode counts).
List<int> missingEpisodeNumbers(
  Map<int, EpisodeUnionTarget> union,
) {
  final out = union.values
      .where((t) => !t.inBase)
      .map((t) => t.episodeNumber)
      .toList()
    ..sort();
  return out;
}

/// One play line (`vod_play_from` name + its episodes).
class PlayLine {
  const PlayLine({required this.name, required this.episodes});

  factory PlayLine.fromJson(Map<String, dynamic> json) => PlayLine(
        name: (json['name'] as String?) ?? '',
        // One malformed episode must not kill the whole line: a
        // persisted cache entry (or an older build's shape) can
        // carry a non-map element, and the old `as` cast threw.
        episodes: (json['episodes'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PlayEpisode.fromJson)
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
        douban: json['douban'] is Map<String, dynamic>
            ? DoubanMark.fromJson(json['douban'] as Map<String, dynamic>)
            : null,
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
  const DoubanMark({
    required this.id,
    this.score,
    this.poster = '',
    this.castPhotos = const [],
  });

  factory DoubanMark.fromJson(Map<String, dynamic> json) => DoubanMark(
        id: (json['id'] as String?) ?? '',
        score: (json['score'] as String?) ?? '',
        poster: (json['poster'] as String?) ?? '',
        castPhotos: (json['castPhotos'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'score': score,
        'poster': poster,
        'castPhotos': castPhotos,
      };

  final String id;
  final String? score;
  final String poster;

  /// Cast avatar URLs (parallel to the merged cast names).
  final List<String> castPhotos;
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
        // Missing/non-map meta used to throw (`as` on null); a detail
        // without meta is an empty meta, not a crash.
        meta: json['meta'] is Map<String, dynamic>
            ? VideoMeta.fromJson(json['meta'] as Map<String, dynamic>)
            : VideoMeta(name: ''),
        lines: (json['lines'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PlayLine.fromJson)
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
        // Skip malformed items instead of throwing: one bad item in
        // the persisted home cache used to discard the whole cache.
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(VideoItem.fromJson)
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
            .whereType<Map<String, dynamic>>()
            .map(VideoHomeRow.fromJson)
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
    this.castPhotos = const [],
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
        castPhotos: (json['castPhotos'] as List<dynamic>? ?? const [])
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
        'castPhotos': castPhotos,
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

  /// Avatar URLs parallel to [castNames] (same order, '' when unknown),
  /// from the Douban desktop subject page's celebrities section.
  final List<String> castPhotos;
  final String? episodes;
}

/// Next-episode info for a history write (1.1.6, browse A3 §4):
/// total episodes of the CURRENT line + the next episode's name.
/// Same-line next first; when the line is exhausted, [allowCrossLine]
/// (Emby seasons only — CMS lines are play lines, not seasons) falls
/// through to the next line's first episode. Never guesses a name:
/// `nextEpName` is '' when there is no next episode or the lines are
/// unknown. The caller (player record) passes its live lines; the
/// home page never fetches a detail to fill these in.
({int totalEpisodes, String nextEpName}) historyNextEpisode({
  required List<PlayLine> lines,
  required int lineIdx,
  required int epIdx,
  required bool allowCrossLine,
}) {
  if (lines.isEmpty || lineIdx < 0 || lineIdx >= lines.length) {
    return (totalEpisodes: 0, nextEpName: '');
  }
  final eps = lines[lineIdx].episodes;
  if (epIdx + 1 < eps.length) {
    return (totalEpisodes: eps.length, nextEpName: eps[epIdx + 1].name);
  }
  if (allowCrossLine) {
    for (var li = lineIdx + 1; li < lines.length; li++) {
      if (lines[li].episodes.isNotEmpty) {
        return (
          totalEpisodes: eps.length,
          nextEpName: lines[li].episodes.first.name,
        );
      }
    }
  }
  return (totalEpisodes: eps.length, nextEpName: '');
}

/// Find an episode by exact name across all lines (1.1.6: the
/// 下一集 card opens the detail page at the stored next-episode name).
/// Null when the name is absent — the caller falls back to the normal
/// open, never to a guessed index.
({int lineIdx, int epIdx})? findEpisodeByName(
  List<PlayLine> lines,
  String name,
) {
  if (name.isEmpty) return null;
  for (var li = 0; li < lines.length; li++) {
    final eps = lines[li].episodes;
    for (var ei = 0; ei < eps.length; ei++) {
      if (eps[ei].name == name) return (lineIdx: li, epIdx: ei);
    }
  }
  return null;
}

/// Continue Watching entry (local history, `hao_video_hist` shape).
class WatchHistoryEntry {
  const WatchHistoryEntry({
    required this.source,
    required this.vodId,
    required this.title,
    this.pic = '',
    this.picAlt = '',
    this.year = '',
    this.lineIdx = 0,
    this.epIdx = 0,
    this.epName = '',
    this.position = 0,
    this.duration = 0,
    this.totalEpisodes,
    this.nextEpName = '',
    required this.at,
  });

  factory WatchHistoryEntry.fromJson(Map<String, dynamic> json) =>
      WatchHistoryEntry(
        source: json['source'],
        vodId: (json['vodId'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        pic: (json['pic'] as String?) ?? '',
        picAlt: (json['picAlt'] as String?) ?? '',
        // Pre-P1-16 rows carry no year: '' means "unknown", and the
        // film key falls back to title-only for them (see filmKey).
        year: (json['year'] as String?) ?? '',
        lineIdx: (json['lineIdx'] as num?)?.toInt() ?? 0,
        epIdx: (json['epIdx'] as num?)?.toInt() ?? 0,
        epName: (json['epName'] as String?) ?? '',
        position: (json['position'] as num?)?.toDouble() ?? 0,
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
        // 1.1.6 (browse A3 §4): optional — rows written before this
        // carry neither key and read back as null / '' (never a
        // crash, never a guessed next episode).
        totalEpisodes: (json['totalEpisodes'] as num?)?.toInt(),
        nextEpName: (json['nextEpName'] as String?) ?? '',
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
        'year': year,
        'lineIdx': lineIdx,
        'epIdx': epIdx,
        'epName': epName,
        'position': position,
        'duration': duration,
        'totalEpisodes': totalEpisodes,
        'nextEpName': nextEpName,
        'at': at.millisecondsSinceEpoch,
      };

  final dynamic source;
  final String vodId;
  final String title;
  final String pic;
  final String picAlt;

  /// Release year, copied from the VideoItem/VideoMeta that was
  /// playing when the row was recorded. '' on rows written before
  /// P1-16 (unknown year — the film key then falls back to title).
  final String year;
  final int lineIdx;
  final int epIdx;
  final String epName;
  final double position;
  final double duration;

  /// Total episodes of the line being watched (1.1.6). Written by
  /// the player at record time; null on older rows.
  final int? totalEpisodes;

  /// Name of the next episode (1.1.6). '' when there is no next
  /// episode, the title is a movie, or the row predates the field —
  /// such rows never enter the 下一集栏 until re-recorded.
  final String nextEpName;

  /// True only when a next episode is KNOWN (never guessed).
  bool get hasNextEpisode => nextEpName.isNotEmpty;

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
