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
import '../../core/storage/safe_json.dart';

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
/// [CmsException] on non-2xx / bad JSON. A cancelled request
/// ([CancelToken] cancelled by the caller) rethrows the Dio
/// [DioException] with type [DioExceptionType.cancel] — cancellation is
/// the caller's decision, never a source failure, so it must not be
/// recorded as one.
typedef CmsFetcher = Future<Map<String, dynamic>> Function(
  String url, {
  Duration timeout,
  CancelToken? cancelToken,
});

/// Production fetcher over the shared Dio instance.
Future<Map<String, dynamic>> defaultCmsFetcher(
  String url, {
  Duration timeout = const Duration(seconds: 8),
  CancelToken? cancelToken,
}) async {
  final dio = sharedDio();
  late Response<dynamic> res;
  try {
    res = await dio.get<dynamic>(
      toHttps(url),
      cancelToken: cancelToken,
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
    if (e.type == DioExceptionType.cancel) rethrow;
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
  return parseCmsResponseBody(res.data, url);
}

/// Pure decode of one CMS HTTP body (no I/O — covered by
/// test/b30_crash_hunt_test.dart).
///
/// A dead source often answers a 200 with an HTML error / WAF page
/// instead of JSON: [jsonDecode] on that throws FormatException, and
/// the old code let it escape the fetcher as an uncaught error.
/// Callers only handle [CmsException], so malformed bodies become one.
Map<String, dynamic> parseCmsResponseBody(dynamic data, String url) {
  if (data is Map<String, dynamic>) return data;
  if (data is String) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      throw CmsException('non-JSON response from $url');
    }
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
    name: jStr(x['vod_name']),
    pic: toHttps(jStr(x['vod_pic'])),
    year: (x['vod_year'] ?? '').toString(),
    type: jStr(x['type_name']),
    area: jStr(x['vod_area']),
    score: (x['vod_score'] ?? '').toString(),
    total: (x['vod_total'] ?? '').toString(),
    remarks: jStr(x['vod_remarks']),
    hits: jIntN(x['vod_hits']) ?? 0,
  );
}

/// Episode / line parsing — port of `directParsePlayUrl(playUrl,
/// playFrom)` (app.js:1000).
///
/// `vod_play_from`: line names joined by `$$$`. `vod_play_url`: per
/// line, episodes joined by `#`; each episode `<name>$<url>` (split on
/// the FIRST `$`). Empty name → '正片'. Line display name: the
/// `play_from` name if it contains CJK, else '线路' + (index+1).
/// Prefer m3u8 by ORDER, not by dropping: lines containing an .m3u8
/// episode sort first, every other line is kept after them (P1-18).
/// The old filter returned ONLY the m3u8 lines, so a source whose
/// m3u8 lines were all dead hid its working MP4/FLV lines from the
/// detail page, the player line chips, and same-source fallback.
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
  // m3u8 lines first, the rest kept after them in original order —
  // never dropped (P1-18). Callers (detail chips, player chips,
  // episode sheet, _trySwitchSource's lines.first) all read
  // `lines` directly, so keeping every line is what makes the
  // non-m3u8 lines visible and usable as same-source fallback.
  final m3 = groups
      .where((g) => g.episodes.any((e) => e.url.contains('.m3u8')))
      .toList();
  final rest = groups
      .where((g) => g.episodes.every((e) => !e.url.contains('.m3u8')))
      .toList();
  return [...m3, ...rest];
}

/// Fallback: synthesise one 直链 line when no lines parse but the CMS
/// content contains a direct media URL (V-P2-2: m3u8 first, then mp4,
/// then flv — a source whose `vod_play_url` is empty but whose
/// `vod_content` embeds an MP4 link is playable, not "找不到这部影片").
/// Only the FIRST direct link of the winning extension is taken.
List<PlayLine> parsePlayLinesWithContentFallback(
  String playUrl,
  String playFrom,
  String content,
) {
  final lines = parsePlayLines(playUrl, playFrom);
  if (lines.isNotEmpty) return lines;
  for (final ext in ['m3u8', 'mp4', 'flv']) {
    final m = RegExp(
      '[\$]?(https?://[^\\s"<>]+[.]$ext[^\\s"<>]*)',
    ).firstMatch(content);
    if (m != null) {
      return [
        PlayLine(
          name: '直链',
          episodes: [PlayEpisode(name: '正片', url: toHttps(m.group(1)!))],
        )
      ];
    }
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
  final list = jList(json['list']);
  if (list.isEmpty) return null;
  // A malformed row (null / string instead of an object): the old
  // `list.first as Map` threw TypeError and the detail load died.
  final first = list.first;
  if (first is! Map<String, dynamic>) return null;
  final d = first;
  final lines = parsePlayLinesWithContentFallback(
    jStr(d['vod_play_url']),
    jStr(d['vod_play_from']),
    jStr(d['vod_content']),
  );
  if (lines.isEmpty) return null;
  return VideoDetail(
    source: source.id,
    vodId: vodId,
    meta: VideoMeta(
      name: jStr(d['vod_name']),
      pic: toHttps(jStr(d['vod_pic'])),
      year: (d['vod_year'] ?? '').toString(),
      type: jStr(d['type_name']),
      area: jStr(d['vod_area']),
      remarks: jStr(d['vod_remarks']),
      score: (d['vod_score'] ?? '').toString(),
      actor: jStr(d['vod_actor']),
      director: jStr(d['vod_director']),
      content: jStr(d['vod_content']),
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
    CancelToken? cancelToken,
  }) async {
    final json = await _fetcher(
      '${source.apiUrl}?ac=videolist&wd=${Uri.encodeComponent(query)}&pg=$page',
      timeout: timeout,
      cancelToken: cancelToken,
    );
    final list = jList(json['list']);
    return list
        .whereType<Map<String, dynamic>>()
        .map((x) => parseCmsVideoItem(source, x))
        .toList();
  }

  /// `directVideoSearch(q)` (app.js:1058): fan out to ALL enabled
  /// sources in parallel, 3 s per source, whole search capped at
  /// 3.5 s (page 1) / 6 s (later pages). If nothing returned and no
  /// source answered at all, sequential fallback over all sources at
  /// 5 s each, total budget 15 s. If still nothing and no source ever
  /// answered → throws 'video source unreachable'. Filter 里番, dedupe
  /// by normTitle|year (first wins, higher score overwrites; an
  /// exact-title later duplicate replaces the kept item's source/id/
  /// pic), rank, return top 40.
  ///
  /// 2026-11-17 (v1.0.6 phone bug: 搜影片慢 + 片源不全): the old
  /// 3-worker sequential queues made every search wait the full 6 s
  /// cap — a slow source at the head of a worker's queue delayed
  /// every source behind it, and the cap then cut the tail off, so
  /// typically only ~12 of 17 sources were ever consulted. Parallel
  /// fan-out: the fast sources (金鹰/非凡, measured 0.4–0.8 s) answer
  /// first and the search returns on the overall cap with whatever
  /// arrived from ALL sources.
  Future<List<VideoItem>> search(
    String query, {
    int page = 1,
    CancelToken? cancelToken,
  }) async {
    final results = <VideoItem>[];
    var anyOk = false;

    Future<void> fanOut(Duration perSource, Duration overall) async {
      // One token per source job (P1-P5): when the overall cap fires,
      // the in-flight jobs are cancelled instead of running on in the
      // background. Cancellation is not a failure — the jobs' errors
      // are swallowed below and no source is penalised for it.
      final tokens = <CancelToken>[
        for (var i = 0; i < _sources.length; i++) CancelToken(),
      ];
      // V-P1-4: an external cancellation (new query / page disposed)
      // cancels the in-flight source jobs too, not just the wait.
      if (cancelToken != null) {
        unawaited(cancelToken.whenCancel.then((_) {
          for (final t in tokens) {
            if (!t.isCancelled) t.cancel();
          }
        }));
      }
      final jobs = _sources.indexed.map<Future<void>>((e) async {
        final s = e.$2;
        try {
          final items = await searchOne(
            s,
            query,
            page: page,
            timeout: perSource,
            cancelToken: tokens[e.$1],
          );
          anyOk = true;
          results.addAll(items);
        } catch (_) {
          // One source failing never kills the search.
        }
      }).toList();
      await Future.wait(jobs).timeout(overall, onTimeout: () {
        for (final t in tokens) {
          t.cancel();
        }
        return <void>[];
      });
    }

    if (page == 1) {
      await fanOut(
        const Duration(seconds: 3),
        const Duration(milliseconds: 3500),
      );
      if (cancelToken?.isCancelled == true) {
        throw DioException(
          requestOptions: RequestOptions(path: query),
          type: DioExceptionType.cancel,
        );
      }
      if (results.isEmpty && !anyOk) {
        final fbStart = DateTime.now();
        for (final s in _sources) {
          if (cancelToken?.isCancelled == true) break;
          if (DateTime.now().difference(fbStart) >
              const Duration(seconds: 15)) {
            break;
          }
          try {
            final items = await searchOne(
              s,
              query,
              page: page,
              timeout: const Duration(seconds: 5),
            );
            anyOk = true;
            results.addAll(items);
          } catch (_) {}
        }
      }
    } else {
      // Later pages: same parallel fan-out, no sequential fallback.
      await fanOut(
        const Duration(seconds: 3),
        const Duration(seconds: 6),
      );
    }

    if (results.isEmpty && !anyOk) {
      throw CmsException('video source unreachable');
    }
    if (cancelToken?.isCancelled == true) {
      throw DioException(
        requestOptions: RequestOptions(path: query),
        type: DioExceptionType.cancel,
      );
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
  /// [cancelToken] (V-P1-4): the detail page cancels it on dispose;
  /// a cancellation rethrows as [DioExceptionType.cancel] and is
  /// never recorded as a source failure.
  Future<VideoDetail> detail(
    dynamic sourceId,
    String vodId, {
    CancelToken? cancelToken,
  }) async {
    final s = sourceById(sourceId) ?? sourceByName(sourceId.toString());
    if (s == null) throw CmsException('unknown source');
    final json = await _fetcher(
      '${s.apiUrl}?ac=videolist&ids=${Uri.encodeComponent(vodId)}',
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    final parsed = parseCmsDetail(s, vodId, json);
    if (parsed == null) throw CmsException('找不到这部影片');
    return parsed;
  }

  // -- Alt sources ----------------------------------------------------------

  /// `directVideoAltSources` (app.js:3576), streaming: 3 workers scan
  /// all sources except the current one in priority order (fastest
  /// first — 金鹰/非凡 first), exact normalised-title (+ year) match.
  /// Each match is yielded THE MOMENT it is found — before, the list
  /// version buffered until 3 matches or a full 15 s scan, so a title
  /// that only the fastest source had still took up to 15 s to surface
  /// (and the 7 s detail race gave up first).
  /// The stream closes when [maxAlts] matches are emitted, all sources
  /// are scanned, or the 15 s cap fires.
  Stream<AltVideoSource> altSourcesStream(
    String title,
    String year,
    dynamic excludeSourceId, {
    int maxAlts = 5,
    CancelToken? cancelToken,
  }) {
    final controller = StreamController<AltVideoSource>();
    final qn = videoNormTitle(title);
    var cursor = 0;
    var emitted = 0;
    var closed = false;
    void closeOnce() {
      if (!closed) {
        closed = true;
        controller.close();
      }
    }

    // V-P1-4: one token for the whole scan (the caller's own when
    // given, else a fresh one the stream owns). Cancelling the
    // subscription cancels the in-flight fetches ONLY when the stream
    // owns the token — a caller's token is never cancelled by a
    // stream cancel (the detail race settles by cancelling this
    // stream, and the same token is still needed for a retry).
    // A caller cancellation still reaches the fetches via the
    // forwarding below; a cancellation is never a source failure
    // (the worker swallows it like any other fetch error).
    final token = cancelToken ?? CancelToken();
    final ownsToken = cancelToken == null;
    if (cancelToken != null) {
      unawaited(cancelToken.whenCancel.then((_) {
        if (!token.isCancelled) token.cancel();
      }));
    }

    // P1-T1: the 15 s cap used to be an orphan Timer — it stayed
    // pending after the listener cancelled (the race in
    // VideoDetailService settles at 7 s and cancels the
    // subscription), which failed widget tests at teardown ("A Timer
    // is still pending") and kept the scan worker alive in prod.
    // Cancelling the subscription now cancels the timer and stops
    // the worker (in-flight fetches still run to their own 5 s
    // timeout, but their results are dropped once closed).
    final capTimer = Timer(const Duration(seconds: 15), closeOnce);
    controller.onCancel = () {
      capTimer.cancel();
      closed = true;
      if (ownsToken && !token.isCancelled) token.cancel();
    };

    Future<void> worker() async {
      while (!closed && cursor < _sources.length && emitted < maxAlts) {
        final s = _sources[cursor++];
        if (s.idKey == excludeSourceId.toString()) continue;
        try {
          final json = await _fetcher(
            '${s.apiUrl}?ac=videolist&wd=${Uri.encodeComponent(title)}&pg=1',
            timeout: const Duration(seconds: 5),
            cancelToken: token,
          );
          if (closed) return;
          final list = jList(json['list']);
          for (final raw in list.whereType<Map<String, dynamic>>()) {
            final name = jStr(raw['vod_name']);
            final y = (raw['vod_year'] ?? '').toString();
            if (videoNormTitle(name) == qn &&
                (year.isEmpty || y.isEmpty || y == year)) {
              emitted++;
              controller.add(AltVideoSource(
                source: s.id,
                vodId: (raw['vod_id'] ?? '').toString(),
              ));
              if (emitted >= maxAlts) {
                closeOnce();
                return;
              }
              break;
            }
          }
        } catch (_) {}
      }
    }

    Future.wait([worker(), worker(), worker()]).then((_) => closeOnce());
    return controller.stream;
  }

  /// List form of [altSourcesStream] (up to 3 matches) — kept for
  /// callers that want the whole list at once. Breaks out as soon as
  /// 3 are collected (breaking the await-for cancels the stream).
  Future<List<AltVideoSource>> altSources(
    String title,
    String year,
    dynamic excludeSourceId,
  ) async {
    final out = <AltVideoSource>[];
    await for (final a in altSourcesStream(
      title,
      year,
      excludeSourceId,
      maxAlts: 3,
    )) {
      out.add(a);
      if (out.length >= 3) break;
    }
    return out;
  }

  /// Alt-source DETAILS for the multi-source episode union (1.1.6
  /// 缺集接续): the detail race ([VideoDetailService.loadWithRace])
  /// settles on the FIRST usable detail and discards the rest, but
  /// the union needs the other sources' episode lists too. This
  /// stream RETAINS them: each alt's parsed detail is yielded the
  /// moment it is fetched (fastest first, up to [maxAlts]); a failed
  /// or unusable alt is skipped silently, never failing the stream.
  /// Each detail fetch is capped at 5 s, like the play-time source
  /// switch — the union must never hold the episode list hostage.
  Stream<VideoDetail> altDetailsStream(
    String title,
    String year,
    dynamic excludeSourceId, {
    int maxAlts = 3,
    CancelToken? cancelToken,
  }) async* {
    await for (final alt in altSourcesStream(
      title,
      year,
      excludeSourceId,
      maxAlts: maxAlts,
      cancelToken: cancelToken,
    )) {
      try {
        final d = await detail(
          alt.source,
          alt.vodId,
          cancelToken: cancelToken,
        ).timeout(const Duration(seconds: 5));
        if (d.usable) yield d;
      } catch (_) {
        // One dead alt must not kill the union: skip it.
      }
    }
  }

  // -- Type map -------------------------------------------------------------

  Map<String, CmsTypeEntry>? _typeMap;
  DateTime? _typeMapAt;

  /// `directVideoTypeMap` (app.js:1351): `GET ?ac=list` on every
  /// kind==='play' source in parallel; map type_name → {source,
  /// sourceName, typeId, childTypeIds, candidates}. 10-min cache.
  ///
  /// Two-stage deterministic build (2026-11-17, 分类乱 fix):
  /// 1. Fetch every source's class table in parallel (6 s cap).
  /// 2. Build the map in SOURCE-PRIORITY order (`_sources` order):
  ///    the first source carrying a name wins as the primary entry;
  ///    same-name entries from other sources become candidates.
  /// The old code built the map inside the parallel callbacks, so the
  /// winner per name was whichever source answered first — it changed
  /// from launch to launch, and a parent category (电影/电视剧/综艺/
  /// 动漫/连续剧) could land on a source where it holds ~0 items.
  /// Children come from each source's own class table (`type_pid`):
  /// items live under leaf type_ids, never under a parent id.
  Future<Map<String, CmsTypeEntry>> typeMap({CancelToken? cancelToken}) async {
    if (_typeMap != null &&
        _typeMapAt != null &&
        DateTime.now().difference(_typeMapAt!) <
            const Duration(minutes: 10)) {
      return _typeMap!;
    }
    final playSources = _sources.where((s) => s.isPlay).toList();
    // Stage 1: fetch all class tables in parallel. Collect results;
    // do NOT build the map here (that was the race).
    final tables = <_SourceClassTable>[];
    // 2026-11-17: 6 s overall cap. Before, typeMap waited for EVERY
    // play source (each up to 8 s) with no overall timeout, so a cold
    // home load could stall 8 s here alone before any row was fetched.
    // A partial map is fine — home rows come from the types that did
    // answer.
    await Future.wait(playSources.map<Future<void>>((s) async {
      try {
        final json = await _fetcher(
          '${s.apiUrl}?ac=list',
          timeout: const Duration(seconds: 8),
          cancelToken: cancelToken,
        );
        tables.add(_SourceClassTable(s, json));
      } catch (_) {}
    })).timeout(const Duration(seconds: 6), onTimeout: () => <void>[]);
    // Stage 2: deterministic build in source-priority order.
    final order = <VideoSource, int>{
      for (var i = 0; i < playSources.length; i++) playSources[i]: i,
    };
    tables.sort(
      (a, b) => (order[a.source] ?? 999) - (order[b.source] ?? 999),
    );
    final grouped = <String, List<CmsTypeEntry>>{};
    for (final t in tables) {
      for (final e in t.entries.entries) {
        grouped.putIfAbsent(e.key, () => []).add(e.value);
      }
    }
    final map = <String, CmsTypeEntry>{};
    for (final g in grouped.entries) {
      final first = g.value.first;
      map[g.key] = CmsTypeEntry(
        source: first.source,
        sourceName: first.sourceName,
        typeId: first.typeId,
        childTypeIds: first.childTypeIds,
        candidates: g.value.skip(1).toList(),
      );
    }
    // V-P1-3: a partial table (fewer than half the play sources
    // answered inside the 6 s cap) is NOT written to the 10-minute
    // cache — the next call re-fetches instead of serving a thin
    // table for 10 minutes while the slow sources have recovered.
    // A complete table is cached exactly as before.
    if (tables.length * 2 >= playSources.length) {
      _typeMap = map;
      _typeMapAt = DateTime.now();
    }
    return map;
  }

  // -- Home / daily / by-type ----------------------------------------------

  /// One `?ac=videolist&t=<typeId>&pg=<p>` page from one source:
  /// parsed items (name + pic required, adult dropped) + the source's
  /// total/pagecount. Null when the request fails.
  Future<_CmsTypePage?> _fetchTypePage(
    VideoSource s,
    String typeId,
    int page, {
    String extraQ = '',
    CancelToken? cancelToken,
  }) async {
    try {
      final json = await _fetcher(
        '${s.apiUrl}?ac=videolist&t=${Uri.encodeComponent(typeId)}&pg=$page$extraQ',
        timeout: const Duration(seconds: 8),
        cancelToken: cancelToken,
      );
      final items = jList(json['list'])
          .whereType<Map<String, dynamic>>()
          .where((x) =>
              (jStr(x['vod_name'])).isNotEmpty &&
              (jStr(x['vod_pic'])).isNotEmpty &&
              !isAdultVideo(
                jStr(x['type_name']),
                jStr(x['vod_name']),
              ))
          .map((x) => parseCmsVideoItem(s, x))
          .toList();
      return _CmsTypePage(
        items: items,
        total: jIntN(json['total']) ?? items.length,
        pagecount: jIntN(json['pagecount']) ?? 1,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetch one page per child type id, at most [_parentFanout] in
  /// flight at once (V-P2-4): a parent with 20 children used to fan
  /// out 20 requests at once onto the shared Dio. Results stay in
  /// child order, so callers see the same merge as before.
  static const int _parentFanout = 5;

  Future<List<_CmsTypePage?>> _fetchChildPages(
    VideoSource s,
    List<String> childTypeIds,
    int page, {
    CancelToken? cancelToken,
  }) async {
    final out = <_CmsTypePage?>[];
    for (var i = 0; i < childTypeIds.length; i += _parentFanout) {
      final end = i + _parentFanout < childTypeIds.length
          ? i + _parentFanout
          : childTypeIds.length;
      out.addAll(
        await Future.wait(
          childTypeIds
              .sublist(i, end)
              .map((tid) => _fetchTypePage(s, tid, page, cancelToken: cancelToken)),
        ),
      );
    }
    return out;
  }

  /// One home row: leaf → `?ac=videolist&t=<typeId>&pg=1` on the
  /// primary source, falling back to same-name candidates when it
  /// answers empty or with the wrong type; parent → all child
  /// type_ids in parallel, merged. 8 s timeout (caller-side).
  Future<VideoHomeRow?> homeRowOne(
    String typeName,
    CmsTypeEntry entry, {
    CancelToken? cancelToken,
  }) async {
    // At most 4 attempts (primary + 3 candidates): the outer home()
    // call caps each row at 8 s anyway, but a cap keeps one row from
    // burning the whole window on dead sources.
    final attempts = [entry, ...entry.candidates].take(4).toList();
    for (final target in attempts) {
      final s = sourceById(target.source);
      if (s == null) continue;
      if (target.isParent) {
        final fetched = await _fetchChildPages(
          s,
          target.childTypeIds,
          1,
          cancelToken: cancelToken,
        );
        final pages = fetched.whereType<_CmsTypePage>().toList();
        if (pages.isEmpty) continue;
        final items = _interleaveTypePages(
          pages.map((p) => p.items).toList(),
        ).take(10).toList();
        if (items.isEmpty) continue;
        return VideoHomeRow(
          name: typeName,
          count: pages.fold<int>(0, (a, p) => a + p.total),
          items: items,
        );
      }
      final pg = await _fetchTypePage(
        s,
        target.typeId,
        1,
        cancelToken: cancelToken,
      );
      if (pg == null || !_leafPageMatches(typeName, pg.items)) continue;
      return VideoHomeRow(
        name: typeName,
        count: pg.total,
        items: pg.items.take(10).toList(),
      );
    }
    return null;
  }

  /// `directVideoHome` (app.js:1443): first 12 types (priority order),
  /// EACH raced against its own 8 s timeout; keep rows with items;
  /// sort rows by count desc, take top 10. Throws when empty.
  ///
  /// Total budget 9 s (P1-P6): typeMap alone can take 6 s (its own
  /// cap) and the rows 8 s each in parallel, so without a total cap
  /// a cold home load stacked to ~14 s. The row phase gets whatever
  /// is left of the 9 s; rows that arrive in time are returned
  /// (sorted, top 10) — a slow or throwing row contributes nothing
  /// and no longer holds the whole load hostage. True per-row
  /// streaming to the UI is a separate step (the tab already renders
  /// the Hive cache first, so there is no blank screen to fix).
  /// Short cross-call throttle (G-P1-1): a home load is expensive (a
  /// type-map fetch + up to 12 row fetches). Within 60 s, repeat calls
  /// return the cached rows instead of re-hitting the network — tab
  /// switches re-create the page (no KeepAlive) but must not re-fetch.
  /// Static because every page build owns a fresh [CmsClient]; the key
  /// is the fetcher identity + the source list, so tests with injected
  /// fetchers never share a production entry. Failures are never cached.
  static VideoHomeData? _homeCache;
  static DateTime? _homeCacheAt;
  static String? _homeCacheKey;
  static const _homeCacheTtl = Duration(seconds: 60);

  Future<VideoHomeData> home({CancelToken? cancelToken}) async {
    final key =
        '${identityHashCode(_fetcher)}|${_sources.map((s) => s.apiUrl).join(',')}';
    final cachedAt = _homeCacheAt;
    if (_homeCache != null &&
        _homeCacheKey == key &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _homeCacheTtl) {
      return _homeCache!;
    }
    final started = DateTime.now();
    final map = await typeMap(cancelToken: cancelToken);
    final names = map.keys.toList()
      ..sort((a, b) {
        final ia = kVideoTypePriority.indexOf(a);
        final ib = kVideoTypePriority.indexOf(b);
        if (ia >= 0 && ib >= 0) return ia - ib;
        if (ia >= 0) return -1;
        if (ib >= 0) return 1;
        return 0;
      });
    final got = <VideoHomeRow>[];
    final rowBudget =
        const Duration(seconds: 9) - DateTime.now().difference(started);
    if (rowBudget > Duration.zero) {
      Future<void> loadRow(String nm) async {
        try {
          final row = await homeRowOne(
            nm,
            map[nm]!,
            cancelToken: cancelToken,
          ).timeout(
            const Duration(seconds: 8),
            onTimeout: () => null,
          );
          if (row != null && row.items.isNotEmpty) got.add(row);
        } catch (_) {
          // One bad row never kills the home load.
        }
      }

      final futures = names.take(12).map(loadRow).toList();
      await Future.wait(futures).timeout(rowBudget, onTimeout: () => <void>[]);
    }
    got.sort((a, b) => b.count.compareTo(a.count));
    final rows = got.take(10).toList();
    if (rows.isEmpty) throw CmsException('video source unreachable');
    final data = VideoHomeData(rows: rows, fetchedAt: DateTime.now());
    _homeCache = data;
    _homeCacheAt = DateTime.now();
    _homeCacheKey = key;
    return data;
  }

  /// `directVideoDaily` (app.js:1372): 3 workers over all play sources,
  /// `?ac=videolist&pg=1`; dedupe by name|year (higher score wins);
  /// require name + pic; drop adult; series first (type contains 剧),
  /// then the rest; take 12. Throws when empty.
  Future<List<VideoItem>> daily({CancelToken? cancelToken}) async {
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
            cancelToken: cancelToken,
          );
          for (final x in jList(json['list'])
              .whereType<Map<String, dynamic>>()) {
            all.add(parseCmsVideoItem(s, x));
          }
        } catch (_) {}
      }
    }

    // 2026-11-17: 10 s overall cap. Before, daily() had NO timeout
    // at all — 3 sequential workers × ~6 sources × 8 s each = up to
    // ~48 s worst case, hogging the shared Dio while home loaded.
    await Future.wait([worker(), worker(), worker()])
        .timeout(const Duration(seconds: 10), onTimeout: () => <void>[]);
    final seen = <String, VideoItem>{};
    final series = <VideoItem>[];
    final other = <VideoItem>[];
    for (final x in all) {
      if (x.name.isEmpty || x.pic.isEmpty) continue;
      if (isAdultVideo(x.type, x.name)) continue;
      // Same normalised key as dedupeAndRankSearch — a raw name|year
      // key keeps "庆余年(高清)" and "庆余年" as two different titles.
      final k = '${videoNormTitle(x.name)}|${x.year}';
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
  /// parent categories fan out to their child type_ids and merge;
  /// leaf categories query one source, falling back to same-name
  /// candidates when it answers empty or with the wrong type.
  /// Filtered (area≠all or year≠all) fetches a window of 10 CMS pages
  /// in parallel for leaves, then client-side filters; page count is
  /// divided by 10 when filtered. Unfiltered fetches one page. Only
  /// `by=hits|score` is passed through; `area`/`year` omitted for
  /// `all`/`other`/`earlier`.
  Future<VideoByTypeResult> byType(
    String name,
    int page, {
    String area = 'all',
    String year = 'all',
    String by = '',
    CancelToken? cancelToken,
  }) async {
    final map = await typeMap(cancelToken: cancelToken);
    final entry = map[name];
    if (entry == null) throw CmsException('type not found');
    if (entry.isParent) {
      return _byParentType(
        name,
        entry,
        page,
        area: area,
        year: year,
        by: by,
        cancelToken: cancelToken,
      );
    }
    return _byLeafType(
      name,
      entry,
      page,
      area: area,
      year: year,
      by: by,
      cancelToken: cancelToken,
    );
  }

  /// Leaf category: one source at a time (primary, then same-name
  /// candidates one by one). Filtered fetches a 10-page window in
  /// parallel; unfiltered fetches one page. The raw window is
  /// validated for this category's type BEFORE area/year filtering —
  /// a source whose items all carry a different type name is
  /// mis-mapped for this name and the next candidate gets a turn.
  Future<VideoByTypeResult> _byLeafType(
    String name,
    CmsTypeEntry entry,
    int page, {
    required String area,
    required String year,
    required String by,
    CancelToken? cancelToken,
  }) async {
    final filtered = (area != 'all') || (year != 'all');
    const win = 10;
    final attempts = [entry, ...entry.candidates].take(4).toList();
    var anyOk = false;
    var bestPagecount = 1;
    for (final target in attempts) {
      final s = sourceById(target.source);
      if (s == null) continue;
      final pagesToFetch = filtered
          ? List<int>.generate(win, (i) => (page - 1) * win + 1 + i)
          : [page];
      final baseQ = 't=${Uri.encodeComponent(target.typeId)}';
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
      final raws = await Future.wait(
        pagesToFetch.map((p) async {
          try {
            final json = await _fetcher(
              '${s.apiUrl}?ac=videolist&$baseQ&pg=$p$extraQ',
              timeout: const Duration(seconds: 8),
              cancelToken: cancelToken,
            );
            anyOk = true;
            return json;
          } catch (_) {
            return null;
          }
        }),
      );
      var srcPagecount = 1;
      var srcTotal = 0;
      for (final j in raws.whereType<Map<String, dynamic>>()) {
        final pc = jIntN(j['pagecount']) ?? 1;
        if (pc > srcPagecount) srcPagecount = pc;
        final tot = jIntN(j['total']) ?? 0;
        if (tot > srcTotal) srcTotal = tot;
      }
      if (srcPagecount > bestPagecount) bestPagecount = srcPagecount;
      var items = <VideoItem>[];
      for (final j in raws.whereType<Map<String, dynamic>>()) {
        for (final x in jList(j['list'])
            .whereType<Map<String, dynamic>>()) {
          if ((jStr(x['vod_name'])).isEmpty) continue;
          if ((jStr(x['vod_pic'])).isEmpty) continue;
          items.add(parseCmsVideoItem(s, x));
        }
      }
      if (!_leafPageMatches(name, items)) continue;
      items = _filterByTypeItems(items, area: area, year: year, by: by);
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
    if (!anyOk) throw CmsException('video source unreachable');
    return VideoByTypeResult(
      name: name,
      page: page,
      pagecount: bestPagecount,
      total: 0,
      items: const [],
    );
  }

  /// Parent category (电影/电视剧/综艺/动漫/连续剧…): items live
  /// under the child type_ids, never under the parent id (a direct
  /// query returns ~0 on every source — measured 2026-11-17).
  /// Fan out to all children in parallel, round-robin merge, one CMS
  /// page per child per logical page. Filtered (area/year) fetches the
  /// same single page per child — the fan-out volume compensates for
  /// the missing 10-page window. Falls back to same-name candidates
  /// when the merge comes back empty.
  Future<VideoByTypeResult> _byParentType(
    String name,
    CmsTypeEntry entry,
    int page, {
    required String area,
    required String year,
    required String by,
    CancelToken? cancelToken,
  }) async {
    final filtered = (area != 'all') || (year != 'all');
    final attempts = [entry, ...entry.candidates].take(4).toList();
    var anyOk = false;
    var bestPagecount = 1;
    for (final target in attempts) {
      final s = sourceById(target.source);
      if (s == null) continue;
      List<_CmsTypePage> pages;
      if (target.isParent) {
        final fetched = await _fetchChildPages(
          s,
          target.childTypeIds,
          page,
          cancelToken: cancelToken,
        );
        pages = fetched.whereType<_CmsTypePage>().toList();
        if (pages.isNotEmpty) anyOk = true;
      } else {
        final pg = await _fetchTypePage(
          s,
          target.typeId,
          page,
          cancelToken: cancelToken,
        );
        if (pg == null) continue;
        anyOk = true;
        if (!_leafPageMatches(name, pg.items)) continue;
        pages = [pg];
      }
      if (pages.isEmpty) continue;
      final total = pages.fold<int>(0, (a, p) => a + p.total);
      final pagecount =
          pages.fold<int>(1, (a, p) => p.pagecount > a ? p.pagecount : a);
      if (pagecount > bestPagecount) bestPagecount = pagecount;
      var items = _interleaveTypePages(
        pages.map((p) => p.items).toList(),
      );
      if (items.isEmpty) continue;
      items = _filterByTypeItems(items, area: area, year: year, by: by);
      // Unfiltered: one logical page = 20 items (CMS page size).
      // Filtered: return everything the filter kept, like the leaf
      // path returns its whole window.
      if (!filtered && items.length > 20) items = items.sublist(0, 20);
      return VideoByTypeResult(
        name: name,
        page: page,
        pagecount: pagecount,
        total: filtered ? items.length : total,
        items: items,
      );
    }
    if (!anyOk) throw CmsException('video source unreachable');
    return VideoByTypeResult(
      name: name,
      page: page,
      pagecount: bestPagecount,
      total: 0,
      items: const [],
    );
  }

  /// Area/year filters + hits/score sort shared by the leaf and
  /// parent by-type paths (extracted from the old `byType` body so
  /// both paths filter identically).
  List<VideoItem> _filterByTypeItems(
    List<VideoItem> items, {
    required String area,
    required String year,
    required String by,
  }) {
    var out = items;
    if (area != 'all') {
      if (area == 'other') {
        out = out
            .where((x) => !kKnownVideoAreas
                .any((a) => (x.area).contains(a)))
            .toList();
      } else {
        final aliases = kVideoAreaAlias[area] ?? [area];
        out = out
            .where((x) => aliases.any((a) => x.area.contains(a)))
            .toList();
      }
    }
    if (year != 'all') {
      if (year == 'earlier') {
        out = out
            .where((x) => (int.tryParse(x.year) ?? 9999) <= 2021)
            .toList();
      } else {
        out = out.where((x) => x.year == year).toList();
      }
    }
    if (by == 'hits') {
      out.sort((a, b) => b.hits.compareTo(a.hits));
    } else if (by == 'score') {
      out.sort((a, b) => b.scoreNum.compareTo(a.scoreNum));
    }
    return out;
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

/// One entry of the type map: the (first, in source-priority order)
/// source carrying a type name, plus its children and same-name
/// candidates from other sources.
class CmsTypeEntry {
  const CmsTypeEntry({
    required this.source,
    required this.sourceName,
    required this.typeId,
    this.childTypeIds = const [],
    this.candidates = const [],
  });

  final dynamic source;
  final String sourceName;
  final String typeId;

  /// Child type ids on the SAME source, from that source's class
  /// table (`type_pid`). Non-empty ⟺ this name is a parent category
  /// on its source; items live under the children, never under this
  /// id (a direct query returns ~0 on every source).
  final List<String> childTypeIds;

  /// Same-name entries from other sources, in source-priority order.
  /// Tried one by one when this entry's source answers empty or with
  /// the wrong type.
  final List<CmsTypeEntry> candidates;

  bool get isParent => childTypeIds.isNotEmpty;
}

/// One `?ac=videolist&t=<typeId>&pg=<p>` page: parsed items +
/// the source's total/pagecount.
class _CmsTypePage {
  const _CmsTypePage({
    required this.items,
    required this.total,
    required this.pagecount,
  });

  final List<VideoItem> items;
  final int total;
  final int pagecount;
}

/// One source's `?ac=list` class table, parsed into entries.
/// Children come from the table's own `type_pid` links; adult and
/// 里番 names are skipped both as entries and as children.
class _SourceClassTable {
  _SourceClassTable(this.source, Map<String, dynamic> json) {
    final rows = <_ClassRow>[];
    final ids = <String>{};
    for (final c in jList(json['class'])
        .whereType<Map<String, dynamic>>()) {
      final nm = (jStr(c['type_name'])).trim();
      if (nm.isEmpty) continue;
      if (isAdultVideo(nm, null)) continue;
      if (nm.contains('里番')) continue;
      final id = (c['type_id'] ?? '').toString();
      if (id.isEmpty) continue;
      rows.add(_ClassRow(nm, id, (c['type_pid'] ?? 0).toString()));
      ids.add(id);
    }
    final childrenOf = <String, List<String>>{};
    for (final r in rows) {
      if (r.pid != '0' && ids.contains(r.pid)) {
        childrenOf.putIfAbsent(r.pid, () => []).add(r.id);
      }
    }
    for (final r in rows) {
      entries.putIfAbsent(
        r.name,
        () => CmsTypeEntry(
          source: source.id,
          sourceName: source.name,
          typeId: r.id,
          childTypeIds: childrenOf[r.id] ?? const [],
        ),
      );
    }
  }

  final VideoSource source;

  /// type_name → entry (first occurrence wins within one source).
  final entries = <String, CmsTypeEntry>{};
}

class _ClassRow {
  const _ClassRow(this.name, this.id, this.pid);
  final String name;
  final String id;
  final String pid;
}

/// A leaf page is usable when it has items AND at least one item's
/// type matches the requested name — or when every item's type is
/// blank (some sources omit type_name, and a blank type can't prove
/// a mismatch). A page of items all carrying a DIFFERENT type name
/// is a mis-mapped category: fall back to the next candidate source.
bool _leafPageMatches(String name, List<VideoItem> items) {
  if (items.isEmpty) return false;
  if (items.any((x) => x.type == name)) return true;
  return items.every((x) => x.type.isEmpty);
}

/// Round-robin interleave of per-child page lists, deduped by
/// source|vodId. A plain concat would show only the first child's
/// 20 items on a parent category's page 1; interleaving mixes the
/// children so every page shows a bit of each.
List<VideoItem> _interleaveTypePages(List<List<VideoItem>> pages) {
  final out = <VideoItem>[];
  final seen = <String>{};
  var idx = 0;
  var added = true;
  while (added) {
    added = false;
    for (final list in pages) {
      if (idx < list.length) {
        final item = list[idx];
        if (seen.add('${item.source}|${item.vodId}')) out.add(item);
        added = true;
      }
    }
    idx++;
  }
  return out;
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
