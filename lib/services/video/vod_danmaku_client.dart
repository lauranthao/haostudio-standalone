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
// Rules (audit b28-audit-danmaku.md §2-§3, as fixed in build 29):
// - Client-side dual validation of a candidate: title gate (the
//   normalised candidate name must contain the normalised query
//   title — compared on a match key with whitespace and Chinese
//   numerals folded, so `庆余年 第2季` matches `庆余年第二季(2024)…`
//   and vice versa) + year gate (a year in the candidate name that
//   disagrees with VideoMeta.year rejects it; no year in the name
//   passes). The season numeral is part of the key, never stripped:
//   an S1 candidate must NOT match an S2 query.
// - Every failure mode is silent: empty result, 404, timeout,
//   network error -> null / empty, never an exception to the player,
//   never a prompt. But silence is not surrender: a 429 or 5xx is
//   retried with backoff (Retry-After honoured, capped at 30 s),
//   and an empty hop-1 200 is retried once — the audit saw a cold
//   fetch occasionally return empty once, and "no danmaku" is never
//   cached as a permanent answer.
// - Per-hop budgets: hop 1 gets 60 s, hop 2 gets 30 s. The audit
//   measured hop 1 cold start at 24.6 s — the old single 10 s
//   budget killed every cold start outright, so the first open of
//   a session could never show danmaku.
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

/// Match key for the title gate: [videoNormTitle], then all
/// whitespace folded out and Chinese numerals folded to Arabic
/// digits — so `庆余年 第2季`, `庆余年第二季` and `庆余年 第二季`
/// all key the same, while the season number itself is preserved
/// (an S1 key never contains an S2 key). Applied to both sides, so
/// a conversion can never match a title against itself only.
String vodDanmakuMatchKey(String s) {
  final norm = videoNormTitle(s).replaceAll(RegExp(r'\s+'), '');
  return _foldChineseNumerals(norm);
}

const _cnDigits = {
  '零': 0,
  '一': 1,
  '二': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '七': 7,
  '八': 8,
  '九': 9,
};

/// Fold runs of Chinese numerals (`二`, `十二`, `二十一`, `一百零三`)
/// to Arabic digits. Non-numeral characters pass through untouched.
/// A run that cannot be parsed (lone `十`/`百` handling aside) falls
/// back to digit-per-character, which still keeps both sides equal.
String _foldChineseNumerals(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final ch = s[i];
    if (!_cnDigits.containsKey(ch) && ch != '十' && ch != '百' && ch != '千') {
      out.write(ch);
      i++;
      continue;
    }
    var j = i;
    while (j < s.length &&
        (_cnDigits.containsKey(s[j]) ||
            s[j] == '十' ||
            s[j] == '百' ||
            s[j] == '千')) {
      j++;
    }
    out.write(_parseChineseNumeral(s.substring(i, j)));
    i = j;
  }
  return out.toString();
}

int _parseChineseNumeral(String run) {
  // Standard positional parse: 十=10, 百=100, 千=1000 as units.
  var total = 0;
  var current = 0;
  var seenAny = false;
  for (var k = 0; k < run.length; k++) {
    final ch = run[k];
    final digit = _cnDigits[ch];
    if (digit != null) {
      current = digit;
      seenAny = true;
      continue;
    }
    final unit = ch == '十'
        ? 10
        : ch == '百'
        ? 100
        : 1000;
    total += (current == 0 ? 1 : current) * unit;
    current = 0;
    seenAny = true;
  }
  if (!seenAny) return 0;
  return total + current;
}

/// Transient, retryable server failure (429 rate-limit or 5xx).
/// Thrown by a [VodDanmakuFetcher] test seam to model a 429, and
/// raised internally from the Dio path on a 429/5xx response.
/// [retryAfter] comes from the response's Retry-After header
/// (seconds); null means "use exponential backoff".
class VodDanmakuTransientError implements Exception {
  const VodDanmakuTransientError({this.retryAfter});

  final Duration? retryAfter;

  @override
  String toString() =>
      'VodDanmakuTransientError(retryAfter: $retryAfter)';
}

/// Dual validation (audit §2.3, build 29): title gate + year gate.
///
/// - Title gate: the match key of the normalised query title (via
///   [vodDanmakuMatchKey]) must appear in the match key of the
///   normalised candidate name. Whitespace and Chinese-vs-Arabic
///   season numerals are folded on both sides, so `庆余年 第2季`
///   matches `庆余年第二季(2024)from tencent - …` — the live server
///   mixes both spellings across candidates of one show.
/// - Year gate: when the candidate name carries a year and [year]
///   (VideoMeta.year) is known, a mismatch rejects the candidate.
///   A candidate without a year passes (no false kills).
bool vodDanmakuCandidatePasses(
  VodDanmakuCandidate candidate, {
  required String queryTitle,
  String year = '',
}) {
  final queryNorm = vodDanmakuMatchKey(queryTitle);
  if (queryNorm.isEmpty) return false;
  final candidateNorm = vodDanmakuMatchKey(candidate.name);
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
/// dropped. Top-level so [compute] can run it in an isolate. Total:
/// an unparseable body returns [] instead of throwing into the
/// compute isolate / caller (b31 crash hunt).
List<VodDanmakuComment> parseVodDanmakuCommentsJson(String body) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const [];
  }
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
    Duration? hopTimeout,
    Duration? hop1Timeout,
    Duration? hop2Timeout,
    this.maxTimelineItems,
    this.maxRetries = 2,
    this.retryBaseDelay = const Duration(seconds: 1),
    this.emptyRetryDelay = const Duration(seconds: 2),
  }) : hop1Timeout =
           hop1Timeout ?? hopTimeout ?? const Duration(seconds: 60),
       hop2Timeout =
           hop2Timeout ?? hopTimeout ?? const Duration(seconds: 30) {
    _fetcher = fetcher;
  }

  /// danmu-api host (audit §1.5). Public API, no token.
  static const String defaultBaseUrl =
      'https://danmu-api-production-60e143e3.up.railway.app';

  final String baseUrl;

  /// Hop-1 budget (60 s): the server cold-starts in ~25 s (audit
  /// §1.5), so a 10 s budget killed every cold start outright.
  final Duration hop1Timeout;

  /// Hop-2 budget (30 s): the comment payload is multi-MB (a live
  /// check saw 4.2 MB / 42,319 comments taking 9 s warm), and hop 2
  /// runs right after hop 1 warmed the service — 30 s leaves room
  /// for a slow pipe without stalling the (background, silent) load.
  final Duration hop2Timeout;

  /// Retries after a transient failure (429 / 5xx), on top of the
  /// first attempt. Total attempts = 1 + [maxRetries].
  final int maxRetries;

  /// Base backoff between retries: attempt n waits
  /// [retryBaseDelay] * 2^n — unless the server sent Retry-After,
  /// which is honoured instead (capped at 30 s).
  final Duration retryBaseDelay;

  /// Delay before the single re-try of an empty hop-1 200 (the
  /// audit saw a cold fetch occasionally return empty once).
  final Duration emptyRetryDelay;

  /// Legacy single budget: sets both hop budgets when neither
  /// [hop1Timeout] nor [hop2Timeout] is given (kept for the
  /// existing timeout test, which passes 50 ms).
  Duration get hopTimeout => hop1Timeout;

  /// Escape hatch: when set, timelines longer than this are uniformly
  /// sampled (see [uniformSampleTimeline]). Null = full load.
  final int? maxTimelineItems;

  late final VodDanmakuFetcher? _fetcher;

  /// Hop 1: candidate list for [title] + [episode] (episode name as
  /// shown by the CMS, e.g. `第1集`). Null on any failure / empty.
  /// An empty 200 is retried once after [emptyRetryDelay]: a cold
  /// fetch occasionally returns empty once, and "no danmaku" is
  /// never a permanent answer.
  Future<List<VodDanmakuCandidate>?> fetchCandidates({
    required String title,
    required String episode,
  }) async {
    final uri = Uri.parse(baseUrl).replace(
      path: '/api/v2/fongmi/danmaku',
      queryParameters: {'name': title, 'episode': episode},
    );
    for (var attempt = 0; ; attempt++) {
      final body = await _fetch(uri, timeout: hop1Timeout);
      List<VodDanmakuCandidate>? list;
      if (body != null && body.isNotEmpty) {
        try {
          list = parseVodDanmakuCandidates(jsonDecode(body));
        } catch (_) {
          return null; // Unparseable body: not a cold glitch, give up.
        }
      }
      if (list != null && list.isNotEmpty) return list;
      // Empty result (empty body or `[]`): one delayed re-try for
      // the cold-fetch glitch. A null body means the transport
      // already failed (and already retried what was retryable),
      // so it returns immediately without waiting.
      if (body != null && attempt == 0) {
        await Future<void>.delayed(emptyRetryDelay);
        continue;
      }
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
    final body = await _fetch(uri, timeout: hop2Timeout);
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

  /// One attempt plus [maxRetries] retries on transient failures
  /// (429 / 5xx). Anything else — timeout, 404, DNS, unparseable —
  /// returns null immediately: still silent, still no danmaku, but
  /// a rate-limit no longer kills the episode outright.
  Future<String?> _fetch(Uri uri, {required Duration timeout}) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _fetchOnce(uri, timeout: timeout);
      } on VodDanmakuTransientError catch (e) {
        if (attempt >= maxRetries) return null;
        final retryAfter = e.retryAfter;
        final delay = retryAfter != null && retryAfter > Duration.zero
            ? (retryAfter > const Duration(seconds: 30)
                  ? const Duration(seconds: 30)
                  : retryAfter)
            : retryBaseDelay * (1 << attempt);
        await Future<void>.delayed(delay);
        continue;
      } catch (_) {
        // Timeout / network error / DNS: silent, no danmaku.
        return null;
      }
    }
  }

  /// A single attempt. A 429 / 5xx raises [VodDanmakuTransientError]
  /// (Retry-After honoured for 429); any other failure raises, and
  /// the caller turns it into a silent null.
  Future<String?> _fetchOnce(Uri uri, {required Duration timeout}) async {
    final fetcher = _fetcher;
    if (fetcher != null) {
      // A seam fetcher signals a 429 by throwing
      // VodDanmakuTransientError; anything else it throws is a
      // terminal failure.
      return await fetcher(uri).timeout(timeout);
    }
    try {
      final res = await sharedDio().get<String>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.plain,
          connectTimeout: timeout,
          receiveTimeout: timeout,
          sendTimeout: timeout,
          headers: const {'Accept': 'application/json'},
        ),
      );
      final status = res.statusCode ?? 0;
      if (status >= 200 && status < 300) return res.data;
      if (status == 429 || status >= 500) {
        throw VodDanmakuTransientError(
          retryAfter: status == 429 ? _retryAfter(res) : null,
        );
      }
      return null;
    } on VodDanmakuTransientError {
      rethrow;
    } on DioException catch (e) {
      // Dio surfaces non-2xx as DioException when validateStatus
      // rejects them; the status still rides on the response.
      final status = e.response?.statusCode ?? 0;
      if (status == 429 || status >= 500) {
        throw VodDanmakuTransientError(
          retryAfter: status == 429 ? _retryAfter(e.response) : null,
        );
      }
      rethrow;
    }
  }

  /// Retry-After header (seconds) from a 429 response, or null.
  Duration? _retryAfter(Response<dynamic>? res) {
    final raw = res?.headers.value('retry-after');
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds);
  }
}
