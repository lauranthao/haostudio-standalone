// VOD danmaku client (build 28) — two-hop FongMi-compatible fetch
// against the danmu-api service. No token, no login, anonymous GETs.
//
//   Hop 1  GET /api/v2/fongmi/danmaku?name=<title>&episode=<ep name>
//          -> JSON array of candidates, best match first (server-side
//          score). Only the top-1 passing the client-side dual check
//          is ever used; candidates are never merged.
//   Hop 2  GET <candidate.url> with format=xml rewritten to
//          format=json -> {"count": N, "comments": [{cid, p, m, t}]}
//          where `t` is the media-time axis (seconds) and `m` the text.
//
// Rules (audit b28-audit-danmaku.md §2-§3):
// - Client-side dual validation of a candidate: title gate (the
//   normalised candidate name must contain the normalised query
//   title) + year gate (a year in the candidate name that disagrees
//   with VideoMeta.year rejects it; no year in the name passes).
// - Every failure mode is silent: empty result, 404, 429, timeout,
//   network error -> null / empty, never an exception to the player,
//   never a retry, never a prompt. Single-hop timeout 10 s.
// - The 17,399-item timeline loads in full by default; [maxTimelineItems]
//   (uniform sampling across the time axis, never first-N) exists only
//   as the escape hatch if real-device frame rate proves full load
//   too heavy — it defaults to off.
// - Hop-2 JSON parsing runs in an isolate ([compute]) so a 1.7 MB
//   payload never blocks the UI thread; a synchronous fallback covers
//   environments where spawning an isolate fails.

import 'dart:convert';
import 'dart:ui' show Color;

import 'package:dio/dio.dart';
import 'package:flame_barrage/flame_barrage.dart';
import 'package:flutter/foundation.dart';

import '../../core/models/live_models.dart';
import '../../core/network/http_client.dart';
import '../../domains/live/presentation/playback/danmaku_filter.dart';
import '../../features/video/video_title_helpers.dart';

/// One candidate episode returned by hop 1.
class VodDanmakuCandidate {
  const VodDanmakuCandidate({required this.name, required this.url});

  /// Human-readable label, e.g. `狂飙(2023)from iqiyi - 狂飙第1集 …`.
  final String name;

  /// Hop-2 address (arrives with `format=xml`; rewritten to json).
  final String url;

  @override
  bool operator ==(Object other) =>
      other is VodDanmakuCandidate && other.name == name && other.url == url;

  @override
  int get hashCode => Object.hash(name, url);
}

/// One comment from hop 2 (`{cid, p, m, t}`).
class VodDanmakuComment {
  const VodDanmakuComment({
    required this.time,
    required this.text,
    this.colorRgb,
    this.type = BarrageType.scroll,
  });

  /// Media time in seconds (`t`; also the first field of `p`).
  final double time;

  /// Text (`m`).
  final String text;

  /// RGB colour from the 3rd field of `p` (e.g. 16777215 = white).
  final int? colorRgb;

  /// `p` type 1 = scroll, 4 = top-fixed, 5 = bottom-fixed.
  final BarrageType type;
}

/// Raw body fetcher (test seam): returns the response body, or null
/// for any non-2xx / error. Production uses the shared Dio instance.
typedef VodDanmakuFetcher = Future<String?> Function(Uri uri);

/// Parse hop-1's JSON array into candidates. Non-list / malformed
/// entries are dropped, never thrown.
List<VodDanmakuCandidate> parseVodDanmakuCandidates(dynamic decoded) {
  if (decoded is! List) return const [];
  final out = <VodDanmakuCandidate>[];
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final name = entry['name']?.toString() ?? '';
    final url = entry['url']?.toString() ?? '';
    if (name.isNotEmpty && url.isNotEmpty) {
      out.add(VodDanmakuCandidate(name: name, url: url));
    }
  }
  return out;
}

/// Year embedded in a candidate name (`狂飙(2023)…`), or null.
int? vodDanmakuCandidateYear(String candidateName) {
  final m = RegExp(r'(19|20)\d{2}').firstMatch(candidateName);
  if (m == null) return null;
  return int.tryParse(m.group(0)!);
}

/// Dual validation (audit §2.3): title gate + year gate.
///
/// - Title gate: the normalised query title (via [videoNormTitle])
///   must appear in the normalised candidate name. Normalisation is
///   the same helper the video search ranking uses, so `狂飙` matches
///   `狂飙(2023)from iqiyi - 狂飙第1集 …`.
/// - Year gate: when the candidate name carries a year and [year]
///   (VideoMeta.year) is known, a mismatch rejects the candidate.
///   A candidate without a year passes (no false kills).
bool vodDanmakuCandidatePasses(
  VodDanmakuCandidate candidate, {
  required String queryTitle,
  String year = '',
}) {
  final queryNorm = videoNormTitle(queryTitle);
  if (queryNorm.isEmpty) return false;
  final candidateNorm = videoNormTitle(candidate.name);
  if (!candidateNorm.contains(queryNorm)) return false;
  final candidateYear = vodDanmakuCandidateYear(candidate.name);
  if (candidateYear != null && year.isNotEmpty) {
    final wantYear = int.tryParse(year);
    if (wantYear != null && candidateYear != wantYear) return false;
  }
  return true;
}

/// First candidate at or after [startIndex] that passes the dual
/// validation, or null. The caller keeps the full list so "换弹幕源"
/// can scan forward from the current index.
VodDanmakuCandidate? selectVodDanmakuCandidate(
  List<VodDanmakuCandidate> candidates, {
  required String queryTitle,
  String year = '',
  int startIndex = 0,
}) {
  for (var i = startIndex; i < candidates.length; i++) {
    final c = candidates[i];
    if (vodDanmakuCandidatePasses(
      c,
      queryTitle: queryTitle,
      year: year,
    )) {
      return c;
    }
  }
  return null;
}

/// Parse hop-2's JSON body (`{"count": N, "comments": [...]}`) into
/// comments. Entries with missing/illegal time or empty text are
/// dropped. Top-level so [compute] can run it in an isolate.
List<VodDanmakuComment> parseVodDanmakuCommentsJson(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) return const [];
  final raw = decoded['comments'];
  if (raw is! List) return const [];
  final out = <VodDanmakuComment>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final text = entry['m']?.toString() ?? '';
    if (text.isEmpty) continue;
    double? time;
    final t = entry['t'];
    if (t is num) {
      time = t.toDouble();
    } else if (t is String) {
      time = double.tryParse(t);
    }
    time ??= _timeFromP(entry['p']?.toString());
    if (time == null || time.isNaN || time < 0) continue;
    var type = BarrageType.scroll;
    int? colorRgb;
    final p = entry['p']?.toString();
    if (p != null && p.isNotEmpty) {
      final parts = p.split(',');
      if (parts.length > 1) {
        switch (int.tryParse(parts[1].trim())) {
          case 4:
            type = BarrageType.topFixed;
          case 5:
            type = BarrageType.bottomFixed;
          default:
            type = BarrageType.scroll;
        }
      }
      if (parts.length > 2) {
        final rgb = int.tryParse(parts[2].trim());
        if (rgb != null && rgb >= 0 && rgb <= 0xFFFFFF) colorRgb = rgb;
      }
    }
    out.add(
      VodDanmakuComment(
        time: time,
        text: text,
        colorRgb: colorRgb,
        type: type,
      ),
    );
  }
  return out;
}

double? _timeFromP(String? p) {
  if (p == null || p.isEmpty) return null;
  final first = p.split(',').first.trim();
  return double.tryParse(first);
}

/// Rewrite a hop-2 URL to JSON: `format=xml` -> `format=json`
/// (added when absent). Relative URLs resolve against [baseUrl].
Uri? rewriteVodCommentUrlToJson(String rawUrl, {required String baseUrl}) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return null;
  var uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (!uri.hasScheme) {
    uri = Uri.parse(baseUrl).resolveUri(uri);
  }
  final params = Map<String, String>.of(uri.queryParameters)
    ..['format'] = 'json';
  return uri.replace(queryParameters: params);
}

/// Build the engine timeline from comments: sorted by media time,
/// content-filtered through the shared [DanmakuContentFilter]
/// (platform `'vod'` — the Douyu-bot rule can never match there),
/// each item stamped with its `at`.
///
/// The similarity filter's 3-second window runs on MEDIA time, not
/// wall time: its clock tracks the comment currently being judged,
/// so a repeated text 10 minutes apart is shown twice (as in live,
/// where the window is 3 seconds of stream time), while a burst of
/// identical texts within 3 media-seconds collapses like live.
List<BarrageItem> buildVodDanmakuTimeline(
  List<VodDanmakuComment> comments, {
  DanmakuFilterConfig? filterConfig,
}) {
  final sorted = List<VodDanmakuComment>.of(comments)
    ..sort((a, b) => a.time.compareTo(b.time));
  DanmakuContentFilter? filter;
  var mediaNow = DateTime.fromMillisecondsSinceEpoch(0);
  if (filterConfig != null) {
    filter = DanmakuContentFilter(
      config: filterConfig,
      clock: () => mediaNow,
    );
  }
  final items = <BarrageItem>[];
  for (final c in sorted) {
    mediaNow = DateTime.fromMillisecondsSinceEpoch((c.time * 1000).round());
    if (filter != null &&
        !filter.shouldShow(
          LiveMessage(message: c.text),
          platform: 'vod',
        )) {
      continue;
    }
    items.add(
      BarrageItem(
        content: c.text,
        at: Duration(milliseconds: (c.time * 1000).round()),
        textColor: c.colorRgb == null
            ? null
            : Color(0xFF000000 | c.colorRgb!),
        type: c.type,
      ),
    );
  }
  return items;
}

/// Uniformly sample [items] down to [maxCount], evenly spaced across
/// the whole timeline — never just the first N, which would front-load
/// the episode and starve the rest.
List<BarrageItem> uniformSampleTimeline(
  List<BarrageItem> items,
  int maxCount,
) {
  if (maxCount <= 0) return const [];
  if (items.length <= maxCount) return List<BarrageItem>.of(items);
  final out = <BarrageItem>[];
  for (var i = 0; i < maxCount; i++) {
    out.add(items[(i * items.length / maxCount).floor()]);
  }
  return out;
}

class VodDanmakuClient {
  VodDanmakuClient({
    VodDanmakuFetcher? fetcher,
    this.baseUrl = defaultBaseUrl,
    this.hopTimeout = const Duration(seconds: 10),
    this.maxTimelineItems,
  }) {
    _fetcher = fetcher;
  }

  /// danmu-api host (audit §1.5). Public API, no token.
  static const String defaultBaseUrl =
      'https://danmu-api-production-60e143e3.up.railway.app';

  final String baseUrl;

  /// Per-hop budget (10 s, aligned with the server's VOD timeout).
  final Duration hopTimeout;

  /// Escape hatch: when set, timelines longer than this are uniformly
  /// sampled (see [uniformSampleTimeline]). Null = full load.
  final int? maxTimelineItems;

  late final VodDanmakuFetcher? _fetcher;

  /// Hop 1: candidate list for [title] + [episode] (episode name as
  /// shown by the CMS, e.g. `第1集`). Null on any failure / empty.
  Future<List<VodDanmakuCandidate>?> fetchCandidates({
    required String title,
    required String episode,
  }) async {
    final uri = Uri.parse(baseUrl).replace(
      path: '/api/v2/fongmi/danmaku',
      queryParameters: {'name': title, 'episode': episode},
    );
    final body = await _fetch(uri);
    if (body == null || body.isEmpty) return null;
    try {
      final list = parseVodDanmakuCandidates(jsonDecode(body));
      return list.isEmpty ? null : list;
    } catch (_) {
      return null;
    }
  }

  /// Hop 2: all comments for [candidate]. Null on any failure / empty.
  Future<List<VodDanmakuComment>?> fetchCommentsFor(
    VodDanmakuCandidate candidate,
  ) async {
    final uri = rewriteVodCommentUrlToJson(
      candidate.url,
      baseUrl: baseUrl,
    );
    if (uri == null) return null;
    final body = await _fetch(uri);
    if (body == null || body.isEmpty) return null;
    try {
      // 1.7 MB of JSON parses off the UI thread.
      final comments = await compute(parseVodDanmakuCommentsJson, body);
      return comments.isEmpty ? null : comments;
    } catch (_) {
      try {
        final comments = parseVodDanmakuCommentsJson(body);
        return comments.isEmpty ? null : comments;
      } catch (_) {
        return null;
      }
    }
  }

  /// Filter + sort + (optionally) uniformly sample [comments] into
  /// engine timeline items. Pure apart from the filter config passed in.
  List<BarrageItem> buildTimeline(
    List<VodDanmakuComment> comments, {
    DanmakuFilterConfig? filterConfig,
  }) {
    var items = buildVodDanmakuTimeline(
      comments,
      filterConfig: filterConfig,
    );
    final cap = maxTimelineItems;
    if (cap != null && items.length > cap) {
      items = uniformSampleTimeline(items, cap);
    }
    return items;
  }

  Future<String?> _fetch(Uri uri) async {
    try {
      final fetcher = _fetcher;
      if (fetcher != null) {
        return await fetcher(uri).timeout(hopTimeout);
      }
      final res = await sharedDio().get<String>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: hopTimeout,
          sendTimeout: hopTimeout,
          headers: const {'Accept': 'application/json'},
        ),
      );
      final status = res.statusCode ?? 0;
      if (status < 200 || status >= 300) return null;
      return res.data;
    } catch (_) {
      // Timeout / 429 / network error / DNS: silent, no danmaku.
      return null;
    }
  }
}
