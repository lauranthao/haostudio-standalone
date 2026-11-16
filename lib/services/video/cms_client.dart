// Apple CMS client — direct (no server), Dart `sharedDio()` transport.
//
// Request patterns (all GET, headers User-Agent: DIRECT_VIDEO_UA,
// Accept: application/json) — port of app.js §2.2:
// - Type list:  `<apiUrl>?ac=list`            -> j.class[] {type_id, type_name}
// - Search:     `<apiUrl>?ac=videolist&wd=<q>&pg=<p>`  -> j.list[]
// - Detail:     `<apiUrl>?ac=videolist&ids=<vodId>`    -> j.list[0]
// - Home/daily: `<apiUrl>?ac=videolist&pg=<p>`         -> j.list[], total
// - By type:    `<apiUrl>?ac=videolist&t=<typeId>&pg=<p>[&area=&year=&by=]`
//
// NOTE on the search param: the task brief says "search param q", but
// the source of truth (app.js directVideoSearch, line 1060) uses `wd` —
// Apple CMS expects `wd`. This client uses `wd`.
//
// Timeouts: search 5 s per source (8 s in the sequential fallback),
// detail 8 s, home/daily/by-type 8 s.
//
// The [CmsFetcher] is injectable so tests can run hermetically against
// canned JSON; production uses [defaultCmsFetcher] over [sharedDio].

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/network/http_client.dart';
import '../../features/video/cms_sources.dart';
import '../../features/video/video_history_store.dart';
import '../../features/video/video_models.dart';
import '../../features/video/video_title_helpers.dart';

/// Thrown when a CMS request times out (detail retry logic treats this
/// differently from a fast failure — see VideoDetailService).
class CmsTimeoutException implements Exception {
  CmsTimeoutException(this.message);
  final String message;
  @override
  String toString() => 'CmsTimeoutException: $message';
}

class CmsException implements Exception {
  CmsException(this.message);
  final String message;
  @override
  String toString() => 'CmsException: $message';
}

/// Fetch one CMS JSON document. Throws [CmsTimeoutException] on timeout,
/// [CmsException] on non-2xx / bad JSON.
typedef CmsFetcher = Future<Map<String, dynamic>> Function(
  String url, {
  Duration timeout,
});

/// Production fetcher over the shared Dio instance.
Future<Map<String, dynamic>> defaultCmsFetcher(
  String url, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final dio = sharedDio();
  late Response<dynamic> res;
  try {
    res = await dio.get<dynamic>(
      toHttps(url),
      options: Options(
        headers: <String, String>{
          'User-Agent': kDirectVideoUa,
          'Accept': 'application/json',
        },
        receiveTimeout: timeout,
        sendTimeout: timeout,
      ),
    );
  } on DioException catch (e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      throw CmsTimeoutException('timeout fetching $url');
    }
    throw CmsException('network error fetching $url: ${e.message}');
  }
  final status = res.statusCode ?? 0;
  if (status < 200 || status >= 300) {
    throw CmsException('http $status fetching $url');
  }
  final data = res.data;
  if (data is Map<String, dynamic>) return data;
  if (data is String) {
    final decoded = jsonDecode(data);
    if (decoded is Map<String, dynamic>) return decoded;
  }
  throw CmsException('non-JSON response from $url');
}

// ---------------------------------------------------------------------------
// Pure parsers (no I/O) — covered by test/video_test.dart.
// ---------------------------------------------------------------------------

/// Map one raw CMS `list[]` row to a [VideoItem] (port of
/// `directVideoItem`).
VideoItem parseCmsVideoItem(VideoSource source, Map<String, dynamic> x) {
  return VideoItem(
    source: source.id,
    sourceName: source.name,
    vodId: (x['vod_id'] ?? '').toString(),
    name: (x['vod_name'] as String?) ?? '',
    pic: toHttps((x['vod_pic'] as String?) ?? ''),
    year: (x['vod_year'] ?? '').toString(),
    type: (x['type_name'] as String?) ?? '',
    area: (x['vod_area'] as String?) ?? '',
    score: (x['vod_score'] ?? '').toString(),
    total: (x['vod_total'] ?? '').toString(),
    remarks: (x['vod_remarks'] as String?) ?? '',
    hits: (x['vod_hits'] as num?)?.toInt() ?? 0,
  );
}

/// Episode / line parsing — port of `directParsePlayUrl(playUrl,
/// playFrom)` (app.js:1000).
///
/// `vod_play_from`: line names joined by `$$$`. `vod_play_url`: per
/// line, episodes joined by `#`; each episode `<name>$<url>` (split on
/// the FIRST `$`). Empty name → '正片'. Line display name: the
/// `play_from` name if it contains CJK, else '线路' + (index+1).
/// Prefer m3u8: if any line has an .m3u8 episode, return only the lines
/// containing m3u8 episodes; otherwise return all lines.
List<PlayLine> parsePlayLines(String playUrl, String playFrom) {
  final names = playFrom.split('\$\$\$');
  final groups = <PlayLine>[];
  final parts = playUrl.split('\$\$\$');
  for (var gi = 0; gi < parts.length; gi++) {
    final eps = <PlayEpisode>[];
    for (final part in parts[gi].split('#')) {
      final di = part.indexOf('\$');
      if (di < 0) continue;
      final nm = part.substring(0, di).trim();
      final u = part.substring(di + 1).trim();
      if (u.isNotEmpty) {
        eps.add(PlayEpisode(
          name: nm.isEmpty ? '正片' : nm,
          // CMS play URLs are often bare http:// — force https so ATS
          // and the AVPlayer backend don't reject them outright.
          url: toHttps(u),
        ));
      }
    }
    if (eps.isEmpty) continue;
    final rawName = gi < names.length ? names[gi] : '';
    final hasCjk = RegExp(r'[\u4e00-\u9fff]').hasMatch(rawName);
    groups.add(PlayLine(
      name: hasCjk ? rawName : '线路${gi + 1}',
      episodes: eps,
    ));
  }
  final m3 = groups
      .where((g) => g.episodes.any((e) => e.url.contains('.m3u8')))
      .toList();
  return m3.isNotEmpty ? m3 : groups;
}

/// Fallback: synthesise one 直链 line when no lines parse but the CMS
/// content contains an m3u8 URL.
List<PlayLine> parsePlayLinesWithContentFallback(
  String playUrl,
  String playFrom,
  String content,
) {
  final lines = parsePlayLines(playUrl, playFrom);
  if (lines.isNotEmpty) return lines;
  final m = RegExp(
    r'[\$]?(https?://[^\s"<>]+[.]m3u8[^\s"<>]*)',
  ).firstMatch(content);
  if (m != null) {
    return [
      PlayLine(
        name: '直链',
        episodes: [PlayEpisode(name: '正片', url: toHttps(m.group(1)!))],
      )
    ];
  }
  return lines;
}

/// Parse a CMS detail document (`?ac=videolist&ids=`) into a
/// [VideoDetail]. Returns null when there is no usable item/lines
/// (caller throws '找不到这部影片').
VideoDetail? parseCmsDetail(
  VideoSource source,
  String vodId,
  Map<String, dynamic> json,
) {
  final list = (json['list'] as List<dynamic>? ?? const []);
  if (list.isEmpty) return null;
  final d = list.first as Map<String, dynamic>;
  final lines = parsePlayLinesWithContentFallback(
    (d['vod_play_url'] as String?) ?? '',
    (d['vod_play_from'] as String?) ?? '',
    (d['vod_content'] as String?) ?? '',
  );
  if (lines.isEmpty) return null;
  return VideoDetail(
    source: source.id,
    vodId: vodId,
    meta: VideoMeta(
      name: (d['vod_name'] as String?) ?? '',
      pic: toHttps((d['vod_pic'] as String?) ?? ''),
      year: (d['vod_year'] ?? '').toString(),
      type: (d['type_name'] as String?) ?? '',
      area: (d['vod_area'] as String?) ?? '',
      remarks: (d['vod_remarks'] as String?) ?? '',
      score: (d['vod_score'] ?? '').toString(),
      actor: (d['vod_actor'] as String?) ?? '',
      director: (d['vod_director'] as String?) ?? '',
      content: (d['vod_content'] as String?) ?? '',
    ),
    lines: lines,
  );
}

/// Probe check (`testSource('video')`): pass when the JSON has `list[]`
/// or `class[]` (or `code===0`).
bool isCmsProbeOk(Map<String, dynamic> json) {
  if (json['code'] == 0) return true;
  if (json['list'] is List) return true;
  if (json['class'] is List) return true;
  return false;
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Apple CMS client. Holds the source list (defaults unless overridden)
/// and a 10-min in-memory type-map cache.
///
/// Default sources come from [VideoSourcesStore.getEnabled] — the
/// user-editable list from settings (影视源管理) — falling back to the
/// shipped defaults when Hive has no override or is not initialised.
class CmsClient {
  CmsClient({
    List<VideoSource>? sources,
    CmsFetcher? fetcher,
  })  : _sources = sources ?? VideoSourcesStore.getEnabled(),
        _fetcher = fetcher ?? defaultCmsFetcher;

  final List<VideoSource> _sources;
  final CmsFetcher _fetcher;

  List<VideoSource> get sources => List.unmodifiable(_sources);

  VideoSource? sourceById(dynamic id) {
    for (final s in _sources) {
      if (s.idKey == id.toString()) return s;
    }
    return null;
  }

  VideoSource? sourceByName(String name) {
    for (final s in _sources) {
      if (s.name == name) return s;
    }
    return null;
  }

  // -- Search ---------------------------------------------------------------

  /// Search one source (5 s default; 8 s in the sequential fallback).
  Future<List<VideoItem>> searchOne(
    VideoSource source,
    String query, {
    int page = 1,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final json = await _fetcher(
      '${source.apiUrl}?ac=videolist&wd=${Uri.encodeComponent(query)}&pg=$page',
      timeout: timeout,
    );
    final list = (json['list'] as List<dynamic>? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map((x) => parseCmsVideoItem(source, x))
        .toList();
  }

  /// `directVideoSearch(q)` (app.js:1058): fan out to all enabled
  /// sources with 3 workers, 5 s per source, whole search capped at
  /// 6 s. If nothing returned and no source answered at all, sequential
  /// fallback over all sources at 8 s each, total budget 35 s. If still
  /// nothing and no source ever answered → throws 'video source
  /// unreachable'. Filter 里番, dedupe by normTitle|year (first wins,
  /// higher score overwrites; an exact-title later duplicate replaces
  /// the kept item's source/id/pic), rank, return top 40.
  Future<List<VideoItem>> search(String query, {int page = 1}) async {
    final results = <VideoItem>[];
    var anyOk = false;
    var cursor = 0;

    Future<void> worker() async {
      while (cursor < _sources.length) {
        final s = _sources[cursor++];
        try {
          final items = await searchOne(s, query, page: page);
          anyOk = true;
          results.addAll(items);
        } catch (_) {
          // One source failing never kills the search.
        }
      }
    }

    if (page == 1) {
      await Future.wait([worker(), worker(), worker()])
          .timeout(const Duration(seconds: 6), onTimeout: () => <void>[]);
      if (results.isEmpty && !anyOk) {
        final fbStart = DateTime.now();
        for (final s in _sources) {
          if (DateTime.now().difference(fbStart) >
              const Duration(seconds: 35)) {
            break;
          }
          try {
            final items = await searchOne(
              s,
              query,
              page: page,
              timeout: const Duration(seconds: 8),
            );
            anyOk = true;
            results.addAll(items);
          } catch (_) {}
        }
      }
    } else {
      // Later pages: same 3 workers, no sequential fallback.
      await Future.wait([worker(), worker(), worker()])
          .timeout(const Duration(seconds: 10), onTimeout: () => <void>[]);
    }

    if (results.isEmpty && !anyOk) {
      throw CmsException('video source unreachable');
    }
    return dedupeAndRankSearch(results, query);
  }

  /// Dedupe + rank a raw merged search list (pure, tested).
  static List<VideoItem> dedupeAndRankSearch(
    List<VideoItem> results,
    String query,
  ) {
    final seen = <String, int>{};
    final out = <VideoItem>[];
    final qp = videoQueryParts(query);
    for (final x in results) {
      if (x.name.isEmpty) continue;
      if (isAdultVideo(x.type, x.name)) continue;
      final k = '${videoNormTitle(x.name)}|${x.year}';
      if (seen.containsKey(k)) {
        var ex = out[seen[k]!];
        if (x.scoreNum > ex.scoreNum) {
          ex = ex.copyWith(score: x.score);
          out[seen[k]!] = ex;
        }
        if (videoNormTitle(x.name) == qp.qn &&
            videoNormTitle(ex.name) != qp.qn) {
          final keepScore = ex.score;
          out[seen[k]!] = VideoItem(
            source: x.source,
            sourceName: x.sourceName,
            vodId: x.vodId,
            name: x.name,
            pic: x.pic,
            year: x.year,
            type: x.type,
            area: x.area,
            score: keepScore,
            total: x.total,
            remarks: x.remarks,
            hits: x.hits,
          );
        }
        continue;
      }
      seen[k] = out.length;
      out.add(x);
    }
    videoRankSort(out, query);
    return out.take(40).toList();
  }

  // -- Detail ---------------------------------------------------------------

  /// `directVideoDetail(sid, vid)` (app.js:1096): 8 s timeout, throws
  /// '找不到这部影片' when absent or when no lines parse.
  Future<VideoDetail> detail(dynamic sourceId, String vodId) async {
    final s = sourceById(sourceId) ?? sourceByName(sourceId.toString());
    if (s == null) throw CmsException('unknown source');
    final json = await _fetcher(
      '${s.apiUrl}?ac=videolist&ids=${Uri.encodeComponent(vodId)}',
      timeout: const Duration(seconds: 8),
    );
    final parsed = parseCmsDetail(s, vodId, json);
    if (parsed == null) throw CmsException('找不到这部影片');
    return parsed;
  }

  // -- Alt sources ----------------------------------------------------------

  /// `directVideoAltSources` (app.js:3576): 3 workers over all sources
  /// except the current one, exact normalised-title (+ year) match,
  /// up to 3 `{source, vodId}`, 15 s cap.
  Future<List<AltVideoSource>> altSources(
    String title,
    String year,
    dynamic excludeSourceId,
  ) async {
    final qn = videoNormTitle(title);
    final out = <AltVideoSource>[];
    var cursor = 0;

    Future<void> worker() async {
      while (cursor < _sources.length && out.length < 3) {
        final s = _sources[cursor++];
        if (s.idKey == excludeSourceId.toString()) continue;
        try {
          final json = await _fetcher(
            '${s.apiUrl}?ac=videolist&wd=${Uri.encodeComponent(title)}&pg=1',
            timeout: const Duration(seconds: 5),
          );
          final list = (json['list'] as List<dynamic>? ?? const []);
          for (final raw in list.whereType<Map<String, dynamic>>()) {
            final name = (raw['vod_name'] as String?) ?? '';
            final y = (raw['vod_year'] ?? '').toString();
            if (videoNormTitle(name) == qn &&
                (year.isEmpty || y.isEmpty || y == year)) {
              out.add(AltVideoSource(
                source: s.id,
                vodId: (raw['vod_id'] ?? '').toString(),
              ));
              break;
            }
          }
        } catch (_) {}
      }
    }

    await Future.wait([worker(), worker(), worker()])
        .timeout(const Duration(seconds: 15), onTimeout: () => <void>[]);
    return out.take(3).toList();
  }

  // -- Type map -------------------------------------------------------------

  Map<String, CmsTypeEntry>? _typeMap;
  DateTime? _typeMapAt;

  /// `directVideoTypeMap` (app.js:1351): `GET ?ac=list` on every
  /// kind==='play' source in parallel; map type_name → {source,
  /// sourceName, typeId}; FIRST source wins per type name. Adult type
  /// names skipped. 10-min cache.
  Future<Map<String, CmsTypeEntry>> typeMap() async {
    if (_typeMap != null &&
        _typeMapAt != null &&
        DateTime.now().difference(_typeMapAt!) <
            const Duration(minutes: 10)) {
      return _typeMap!;
    }
    final playSources = _sources.where((s) => s.isPlay).toList();
    final map = <String, CmsTypeEntry>{};
    await Future.wait(playSources.map((s) async {
      try {
        final json = await _fetcher(
          '${s.apiUrl}?ac=list',
          timeout: const Duration(seconds: 8),
        );
        for (final c in (json['class'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()) {
          final nm = ((c['type_name'] as String?) ?? '').trim();
          if (nm.isEmpty) continue;
          if (isAdultVideo(nm, null)) continue;
          if (nm.contains('里番')) continue;
          map.putIfAbsent(
            nm,
            () => CmsTypeEntry(
              source: s.id,
              sourceName: s.name,
              typeId: (c['type_id'] ?? '').toString(),
            ),
          );
        }
      } catch (_) {}
    }));
    _typeMap = map;
    _typeMapAt = DateTime.now();
    return map;
  }

  // -- Home / daily / by-type ----------------------------------------------

  /// One home row: `?ac=videolist&t=<typeId>&pg=1`, 8 s timeout.
  Future<VideoHomeRow?> homeRowOne(
    String typeName,
    CmsTypeEntry entry,
  ) async {
    final s = sourceById(entry.source);
    if (s == null) return null;
    try {
      final json = await _fetcher(
        '${s.apiUrl}?ac=videolist&t=${Uri.encodeComponent(entry.typeId)}&pg=1',
        timeout: const Duration(seconds: 8),
      );
      final items = (json['list'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .where((x) =>
              ((x['vod_name'] as String?) ?? '').isNotEmpty &&
              ((x['vod_pic'] as String?) ?? '').isNotEmpty &&
              !isAdultVideo(
                (x['type_name'] as String?) ?? '',
                (x['vod_name'] as String?) ?? '',
              ))
          .map((x) => parseCmsVideoItem(s, x))
          .toList();
      return VideoHomeRow(
        name: typeName,
        count: (json['total'] as num?)?.toInt() ?? items.length,
        items: items.take(10).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  /// `directVideoHome` (app.js:1443): first 12 types (priority order),
  /// EACH raced against its own 8 s timeout; keep rows with items;
  /// sort rows by count desc, take top 10. Throws when empty.
  Future<VideoHomeData> home() async {
    final map = await typeMap();
    final names = map.keys.toList()
      ..sort((a, b) {
        final ia = kVideoTypePriority.indexOf(a);
        final ib = kVideoTypePriority.indexOf(b);
        if (ia >= 0 && ib >= 0) return ia - ib;
        if (ia >= 0) return -1;
        if (ib >= 0) return 1;
        return 0;
      });
    final results = await Future.wait(
      names.take(12).map(
        (nm) => homeRowOne(nm, map[nm]!).timeout(
          const Duration(seconds: 8),
          onTimeout: () => null,
        ),
      ),
    );
    final got = results.whereType<VideoHomeRow>().where((r) => r.items.isNotEmpty).toList();
    got.sort((a, b) => b.count.compareTo(a.count));
    final rows = got.take(10).toList();
    if (rows.isEmpty) throw CmsException('video source unreachable');
    return VideoHomeData(rows: rows, fetchedAt: DateTime.now());
  }

  /// `directVideoDaily` (app.js:1372): 3 workers over all play sources,
  /// `?ac=videolist&pg=1`; dedupe by name|year (higher score wins);
  /// require name + pic; drop adult; series first (type contains 剧),
  /// then the rest; take 12. Throws when empty.
  Future<List<VideoItem>> daily() async {
    final playSources = _sources.where((s) => s.isPlay).toList();
    final all = <VideoItem>[];
    var cursor = 0;

    Future<void> worker() async {
      while (cursor < playSources.length) {
        final s = playSources[cursor++];
        try {
          final json = await _fetcher(
            '${s.apiUrl}?ac=videolist&pg=1',
            timeout: const Duration(seconds: 8),
          );
          for (final x in (json['list'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()) {
            all.add(parseCmsVideoItem(s, x));
          }
        } catch (_) {}
      }
    }

    await Future.wait([worker(), worker(), worker()]);
    final seen = <String, VideoItem>{};
    final series = <VideoItem>[];
    final other = <VideoItem>[];
    for (final x in all) {
      if (x.name.isEmpty || x.pic.isEmpty) continue;
      if (isAdultVideo(x.type, x.name)) continue;
      final k = '${x.name}|${x.year}';
      final ex = seen[k];
      if (ex != null) {
        if (x.scoreNum > ex.scoreNum) {
          seen[k] = ex.copyWith(score: x.score);
        }
        continue;
      }
      seen[k] = x;
      if (x.type.contains('剧')) {
        series.add(x);
      } else {
        other.add(x);
      }
    }
    final items = [...series, ...other].take(12).toList();
    if (items.isEmpty) throw CmsException('video source unreachable');
    return items;
  }

  /// `directVideoByType(name, pg, area, year, by)` (app.js:1402):
  /// single source from the type map. Filtered (area≠all or year≠all)
  /// fetches a window of 10 CMS pages in parallel, then client-side
  /// filters; page count is divided by 10 when filtered. Unfiltered
  /// fetches one page. Only `by=hits|score` is passed through;
  /// `area`/`year` omitted for `all`/`other`/`earlier`.
  Future<VideoByTypeResult> byType(
    String name,
    int page, {
    String area = 'all',
    String year = 'all',
    String by = '',
  }) async {
    final map = await typeMap();
    final entry = map[name];
    if (entry == null) throw CmsException('type not found');
    final s = sourceById(entry.source);
    if (s == null) throw CmsException('source gone');
    final filtered = (area != 'all') || (year != 'all');
    const win = 10;
    final pagesToFetch = filtered
        ? List<int>.generate(win, (i) => (page - 1) * win + 1 + i)
        : [page];
    final baseQ = 't=${Uri.encodeComponent(entry.typeId)}';
    var extraQ = '';
    if (area != 'all' && area != 'other') {
      extraQ += '&area=${Uri.encodeComponent(area)}';
    }
    if (year != 'all' && year != 'earlier') {
      extraQ += '&year=${Uri.encodeComponent(year)}';
    }
    if (by == 'hits' || by == 'score') {
      extraQ += '&by=${Uri.encodeComponent(by)}';
    }
    var anyOk = false;
    final raws = await Future.wait(
      pagesToFetch.map((p) async {
        try {
          final json = await _fetcher(
            '${s.apiUrl}?ac=videolist&$baseQ&pg=$p$extraQ',
            timeout: const Duration(seconds: 8),
          );
          anyOk = true;
          return json;
        } catch (_) {
          return null;
        }
      }),
    );
    if (!anyOk) throw CmsException('video source unreachable');
    var srcPagecount = 1;
    var srcTotal = 0;
    for (final j in raws.whereType<Map<String, dynamic>>()) {
      final pc = (j['pagecount'] as num?)?.toInt() ?? 1;
      if (pc > srcPagecount) srcPagecount = pc;
      final tot = (j['total'] as num?)?.toInt() ?? 0;
      if (tot > srcTotal) srcTotal = tot;
    }
    var items = <VideoItem>[];
    for (final j in raws.whereType<Map<String, dynamic>>()) {
      for (final x in (j['list'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()) {
        if (((x['vod_name'] as String?) ?? '').isEmpty) continue;
        if (((x['vod_pic'] as String?) ?? '').isEmpty) continue;
        items.add(parseCmsVideoItem(s, x));
      }
    }
    if (area != 'all') {
      if (area == 'other') {
        items = items
            .where((x) => !kKnownVideoAreas
                .any((a) => (x.area).contains(a)))
            .toList();
      } else {
        final aliases = kVideoAreaAlias[area] ?? [area];
        items = items
            .where((x) => aliases.any((a) => x.area.contains(a)))
            .toList();
      }
    }
    if (year != 'all') {
      if (year == 'earlier') {
        items = items
            .where((x) => (int.tryParse(x.year) ?? 9999) <= 2021)
            .toList();
      } else {
        items = items.where((x) => x.year == year).toList();
      }
    }
    if (by == 'hits') {
      items.sort((a, b) => b.hits.compareTo(a.hits));
    } else if (by == 'score') {
      items.sort((a, b) => b.scoreNum.compareTo(a.scoreNum));
    }
    final pagecount = filtered
        ? (srcPagecount / win).ceil().clamp(1, 1 << 30)
        : srcPagecount;
    return VideoByTypeResult(
      name: name,
      page: page,
      pagecount: pagecount,
      total: filtered ? items.length : srcTotal,
      items: items,
    );
  }

  /// Probe (`testSource('video')`): `GET <apiUrl>?ac=videolist&pg=1` —
  /// pass when the JSON has `list[]` or `class[]` (or `code===0`).
  Future<bool> probe(VideoSource source) async {
    try {
      final json = await _fetcher(
        '${source.apiUrl}?ac=videolist&pg=1',
        timeout: const Duration(seconds: 8),
      );
      return isCmsProbeOk(json);
    } catch (_) {
      return false;
    }
  }
}

/// One entry of the type map: the (first) source carrying a type name.
class CmsTypeEntry {
  const CmsTypeEntry({
    required this.source,
    required this.sourceName,
    required this.typeId,
  });

  final dynamic source;
  final String sourceName;
  final String typeId;
}

/// By-type page result.
class VideoByTypeResult {
  const VideoByTypeResult({
    required this.name,
    required this.page,
    required this.pagecount,
    required this.total,
    required this.items,
  });

  final String name;
  final int page;
  final int pagecount;
  final int total;
  final List<VideoItem> items;
}
