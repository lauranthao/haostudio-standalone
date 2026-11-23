// Douban metadata enrichment service.
//
// Port of app.js `directDoubanDetail` / `directDoubanResolveId` /
// `doubanCall` / `doubanJson` / `doubanText` ([DOUBAN-START] …
// [DOUBAN-END]). Douban is the SOLE metadata source (TMDB is OUT).
//
// Resolution order: title → id via suggest, then desktop search page
// parse, then the builtin map. Then abstract + mobile page (poster /
// overview / score). Whole detail flow race-capped at 15 s.
//
// Throttle + backoff (must be kept — Douban rate-limits aggressively):
// - All Douban calls serialised through one chain with a ≥ 1 s gap.
// - HTTP 403 → block all Douban calls for 60 s.
// - After 3 consecutive suggest failures, suggest is disabled
//   permanently (persisted flag).
//
// Caches (200-entry cap, oldest evicted): detail by id (permanent —
// keyed by Douban id, so a correct id's detail stays correct) +
// title→id map with a TTL ([kDoubanIdMapTtl]; see below). A wrong
// title→id link used to be permanent — see P1-14. [DoubanCache] is
// Hive-backed in production and in-memory in tests.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/network/http_client.dart';
import '../../core/storage/hive_store.dart';
import '../../features/video/cms_sources.dart';
import '../../features/video/video_models.dart';
import '../../features/video/video_title_helpers.dart';
import 'douban_parsers.dart';
import '../../core/storage/safe_json.dart';

/// One raw Douban HTTP result.
typedef DoubanFetcher = Future<({int status, String body})> Function(
  String url,
  Map<String, String> headers, {
  Duration timeout,
});

Future<({int status, String body})> defaultDoubanFetcher(
  String url,
  Map<String, String> headers, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final dio = sharedDio();
  final res = await dio.get<String>(
    url,
    options: Options(
      headers: headers,
      responseType: ResponseType.plain,
      receiveTimeout: timeout,
      sendTimeout: timeout,
    ),
  );
  return (status: res.statusCode ?? 0, body: res.data ?? '');
}

const Map<String, String> kDoubanHeaders = {
  'User-Agent': kDirectMusicUa,
  'Referer': 'https://movie.douban.com/',
};

/// Last resort before giving up (verified ids).
const Map<String, String> kDoubanBuiltinIds = {
  '流浪地球2': '35267208',
  '庆余年': '25853071',
  '肖申克的救赎': '1292052',
  '霸王别姬': '1291546',
  '泰坦尼克号': '1292722',
};

/// Title→id mapping TTL (P1-14).
///
/// Why 7 days: a film's Douban id never changes, so the mapping is
/// essentially stable data — the TTL is NOT about freshness, it only
/// bounds how long a wrong mapping can hurt. 7 days means even a
/// mismatch that slips past every year check (e.g. no year info
/// anywhere) self-heals within a week, while a correct mapping costs
/// at most one cheap re-suggest per title per week (suggest is
/// already serialised ≥ 1 s apart with a 60 s 403 backoff, so the
/// extra traffic is negligible). Entries written before this TTL
/// existed carry no timestamp and are treated as expired on first
/// read — that is the self-healing path for already-cached wrong
/// mappings: the next open re-suggests instead of trusting them.
const Duration kDoubanIdMapTtl = Duration(days: 7);

/// Cache backend for Douban detail + id map.
abstract class DoubanCache {
  DoubanDetail? detail(String id);
  void setDetail(String id, DoubanDetail detail);
  void removeDetail(String id);
  String? idForTitle(String key);
  void setIdForTitle(String key, String id);
  void removeIdForTitle(String key);
  bool get suggestDisabled;
  void disableSuggest();
}

/// Hive-backed cache (production). Stores JSON maps under the web's
/// localStorage key names.
class HiveDoubanCache implements DoubanCache {
  static const int maxEntries = 200;

  Map<String, dynamic> _readMap(String key) {
    final raw = HiveStore.box.get(key);
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  void _writeMap(String key, Map<String, dynamic> map) {
    unawaited(HiveStore.put(key, jsonEncode(map)));
  }

  @override
  DoubanDetail? detail(String id) {
    final map = _readMap(HiveKeys.doubanDetail);
    final raw = map[id];
    if (raw is Map<String, dynamic>) return DoubanDetail.fromJson(raw);
    return null;
  }

  @override
  void setDetail(String id, DoubanDetail detail) {
    final map = _readMap(HiveKeys.doubanDetail);
    map[id] = {...detail.toJson(), 'at': DateTime.now().millisecondsSinceEpoch};
    if (map.length > maxEntries) {
      final keys = map.keys.toList()
        ..sort((a, b) {
          final atA = jIntN(jMapN(map[a])?['at']) ?? 0;
          final atB = jIntN(jMapN(map[b])?['at']) ?? 0;
          return atA.compareTo(atB);
        });
      for (var i = 0; i < map.length - maxEntries; i++) {
        map.remove(keys[i]);
      }
    }
    _writeMap(HiveKeys.doubanDetail, map);
  }

  @override
  void removeDetail(String id) {
    final map = _readMap(HiveKeys.doubanDetail);
    if (map.remove(id) != null) _writeMap(HiveKeys.doubanDetail, map);
  }

  /// A title→id entry is `{id, at}`. Pre-TTL entries stored a bare
  /// String id with no timestamp — treated as expired (see
  /// [kDoubanIdMapTtl]): the caller re-resolves instead of trusting a
  /// mapping that may be one of the permanent P1-14 mismatches.
  @override
  String? idForTitle(String key) {
    final map = _readMap(HiveKeys.doubanIdmap);
    final v = map[key];
    if (v is String) return null; // legacy, no timestamp → expired
    if (v is Map) {
      final id = v['id'];
      final at = v['at'];
      if (id is String && id.isNotEmpty && at is num) {
        final age = DateTime.now().millisecondsSinceEpoch - at.toInt();
        if (age >= 0 && age < kDoubanIdMapTtl.inMilliseconds) return id;
      }
    }
    return null;
  }

  @override
  void setIdForTitle(String key, String id) {
    final map = _readMap(HiveKeys.doubanIdmap);
    map[key] = {'id': id, 'at': DateTime.now().millisecondsSinceEpoch};
    if (map.length > maxEntries) {
      // Oldest first; legacy bare-String entries (at unknown) evict
      // before stamped ones.
      final keys = map.keys.toList()
        ..sort((a, b) {
          final atA = jIntN(jMapN(map[a])?['at']) ?? 0;
          final atB = jIntN(jMapN(map[b])?['at']) ?? 0;
          return atA.compareTo(atB);
        });
      for (var i = 0; i < map.length - maxEntries; i++) {
        map.remove(keys[i]);
      }
    }
    _writeMap(HiveKeys.doubanIdmap, map);
  }

  @override
  void removeIdForTitle(String key) {
    final map = _readMap(HiveKeys.doubanIdmap);
    if (map.remove(key) != null) _writeMap(HiveKeys.doubanIdmap, map);
  }

  @override
  bool get suggestDisabled =>
      HiveStore.box.get(HiveKeys.doubanNoSuggest) == '1';

  @override
  void disableSuggest() {
    unawaited(HiveStore.put(HiveKeys.doubanNoSuggest, '1'));
  }
}

/// In-memory cache (tests / previews).
class MemoryDoubanCache implements DoubanCache {
  final Map<String, DoubanDetail> details = {};
  final Map<String, String> ids = {};

  /// Write time per title→id entry (same TTL rule as Hive; the
  /// in-memory box only lives for one process run, so entries written
  /// here always carry a stamp).
  final Map<String, DateTime> idTimes = {};
  bool _suggestDisabled = false;

  @override
  DoubanDetail? detail(String id) => details[id];

  @override
  void setDetail(String id, DoubanDetail detail) {
    details[id] = detail;
  }

  @override
  void removeDetail(String id) {
    details.remove(id);
  }

  @override
  String? idForTitle(String key) {
    final at = idTimes[key];
    if (at == null) return null;
    if (DateTime.now().difference(at) >= kDoubanIdMapTtl) {
      ids.remove(key);
      idTimes.remove(key);
      return null;
    }
    return ids[key];
  }

  @override
  void setIdForTitle(String key, String id) {
    ids[key] = id;
    idTimes[key] = DateTime.now();
  }

  @override
  void removeIdForTitle(String key) {
    ids.remove(key);
    idTimes.remove(key);
  }

  @override
  bool get suggestDisabled => _suggestDisabled;

  @override
  void disableSuggest() {
    _suggestDisabled = true;
  }
}

/// One actor's photo URL by name (Baidu Baike lemma card).
/// Returns '' when unavailable. Injectable for tests.
typedef CastPhotoFetcher = Future<String> Function(String name);

/// Default cast-photo fetch: Baidu Baike open API (free, no key).
/// Validated by [parseBaikeCardPhoto] — wrong-person cards rejected.
Future<String> defaultCastPhotoFetcher(String name) async {
  try {
    final res = await sharedDio().get<Map<String, dynamic>>(
      'https://baike.baidu.com/api/openapi/BaikeLemmaCardApi',
      queryParameters: {
        'scope': '103',
        'format': 'json',
        'appid': '379020',
        'bk_key': name,
        'bk_length': '600',
      },
      options: Options(
        responseType: ResponseType.json,
        receiveTimeout: const Duration(seconds: 5),
        sendTimeout: const Duration(seconds: 5),
      ),
    );
    if (res.statusCode != 200 || res.data == null) return '';
    return parseBaikeCardPhoto(res.data, name) ?? '';
  } catch (_) {
    return '';
  }
}

/// First (19|20)xx year in [s], or 0 when there is none.
int _parseYear(String? s) {
  if (s == null || s.isEmpty) return 0;
  final m = RegExp(r'(19|20)\d{2}').firstMatch(s);
  return m == null ? 0 : int.tryParse(m.group(0)!) ?? 0;
}

/// True when [gotYear] (Douban's year) and [wantYear] (the CMS year)
/// are both known and more than 1 year apart. A 1-year gap is
/// tolerated (release-year vs first-air-year drift between sources).
bool _yearsMismatch(String? gotYear, bool useYear, int wantYear) {
  if (!useYear || wantYear == 0) return false;
  final got = _parseYear(gotYear);
  if (got == 0) return false;
  return (got - wantYear).abs() > 1;
}

/// A cached detail whose cast has names but NO photos is stale: it
/// was saved when the photo fetch failed, and the cache is
/// permanent — without this, photos never appear again on an
/// installed phone. Re-fetch instead of returning it.
bool _photosMissing(DoubanDetail? cached) =>
    cached != null &&
    cached.castNames.isNotEmpty &&
    (cached.castPhotos.length < cached.castNames.length ||
        cached.castPhotos.every((p) => p.isEmpty));

/// One suggest hit. Douban's `j/subject_suggest` returns
/// `{id, title, year, type, ...}` per hit (`year` verified live
/// 2026-11-19); `year` is 0 when the hit carries none.
typedef _SuggestHit = ({String id, String title, int year});

List<_SuggestHit> _parseSuggestHits(dynamic json) {
  final out = <_SuggestHit>[];
  if (json is! List) return out;
  for (final e in json) {
    if (e is! Map) continue;
    final id = e['id']?.toString() ?? '';
    if (id.isEmpty) continue;
    final rawYear = e['year'];
    final year = rawYear is num
        ? rawYear.toInt()
        : int.tryParse(rawYear?.toString() ?? '') ?? 0;
    out.add((id: id, title: e['title']?.toString() ?? '', year: year));
  }
  return out;
}

/// Pick the best suggest hit for [title] (+ [year] when known).
///
/// P1-14: the old code took `arr[0].id` blind. Now every hit is
/// scored on normalised title first, then year closeness; a hit is
/// only eligible when its title matches (exact / starts-with /
/// contains, either direction — suggest titles carry suffixes) and,
/// when both years are known, the years are within 1. Returns null
/// when nothing is eligible — the caller then falls through to the
/// desktop search page / builtin map instead of caching a wrong id.
String? _pickSuggestId(List<_SuggestHit> hits, String title, int year) {
  final qn = videoNormTitle(title);
  if (qn.isEmpty) return null;
  _SuggestHit? best;
  var bestTitleScore = 1 << 30;
  var bestYearDiff = 1 << 30;
  for (final hit in hits) {
    final cn = videoNormTitle(hit.title);
    if (cn.isEmpty || qn.length < 2 || cn.length < 2) {
      if (cn != qn) continue;
    }
    final int titleScore;
    if (cn == qn) {
      titleScore = 0;
    } else if (cn.startsWith(qn) || qn.startsWith(cn)) {
      titleScore = 1;
    } else if (cn.contains(qn) || qn.contains(cn)) {
      titleScore = 2;
    } else {
      continue;
    }
    // Unknown year sorts after a known-year match.
    var yearDiff = 1 << 30;
    if (year != 0 && hit.year != 0) {
      final d = (hit.year - year).abs();
      if (d > 1) continue;
      yearDiff = d;
    }
    if (titleScore < bestTitleScore ||
        (titleScore == bestTitleScore && yearDiff < bestYearDiff)) {
      best = hit;
      bestTitleScore = titleScore;
      bestYearDiff = yearDiff;
    }
  }
  return best?.id;
}

class DoubanService {
  DoubanService({
    DoubanFetcher? fetcher,
    DoubanCache? cache,
    CastPhotoFetcher? castPhotoFetcher,
  })  : _fetcher = fetcher ?? defaultDoubanFetcher,
        _cache = cache ?? HiveDoubanCache(),
        _castPhotoFetcher = castPhotoFetcher ?? defaultCastPhotoFetcher;

  final DoubanFetcher _fetcher;
  final DoubanCache _cache;
  final CastPhotoFetcher _castPhotoFetcher;

  Future<void> _chain = Future.value();
  DateTime _lastCall = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _suggestFails = 0;

  bool get blocked => DateTime.now().isBefore(_blockedUntil);

  void _note403() {
    _blockedUntil = DateTime.now().add(const Duration(seconds: 60));
  }

  /// Serialised call with a ≥ 1 s gap (`doubanCall`).
  ///
  /// D-P1-1: [isCancelled] lets a timed-out detail() chain abandon
  /// its queued steps instead of running them: when the 15 s budget
  /// fires, the chain's remaining _calls throw immediately (no gap
  /// wait, no fetch), so the next detail() is not stuck behind the
  /// orphaned chain's leftover requests.
  Future<T> _call<T>(
    Future<T> Function() fn, {
    bool Function()? isCancelled,
  }) {
    final run = _chain.then((_) async {
      if (blocked) throw StateError('douban blocked');
      if (isCancelled?.call() ?? false) {
        throw StateError('douban cancelled');
      }
      final wait = const Duration(seconds: 1) -
          DateTime.now().difference(_lastCall);
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
      if (isCancelled?.call() ?? false) {
        throw StateError('douban cancelled');
      }
      _lastCall = DateTime.now();
      return fn();
    });
    _chain = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Map<String, dynamic>> _json(
    String url, {
    Duration timeout = const Duration(seconds: 10),
    bool noBackoff = false,
    bool Function()? isCancelled,
  }) async {
    final res = await _call(
      () => _fetcher(url, kDoubanHeaders, timeout: timeout),
      isCancelled: isCancelled,
    );
    if (res.status == 403) {
      if (!noBackoff) _note403();
      throw StateError('douban 403');
    }
    if (res.status < 200 || res.status >= 300) {
      throw StateError('http ${res.status}');
    }
    final decoded = jsonDecode(res.body);
    // A non-object body (list / scalar / garbage) degrades to an
    // empty result instead of throwing TypeError into the caller.
    return decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{};
  }

  Future<String> _text(
    String url,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 10),
    bool Function()? isCancelled,
  }) async {
    final res = await _call(
      () => _fetcher(url, headers, timeout: timeout),
      isCancelled: isCancelled,
    );
    if (res.status == 403) {
      _note403();
      throw StateError('douban 403');
    }
    if (res.status < 200 || res.status >= 300) {
      throw StateError('http ${res.status}');
    }
    return res.body;
  }

  Future<String?> _suggestId(
    String title, {
    int year = 0,
    bool Function()? isCancelled,
  }) async {
    try {
      final res = await _call(
        () => _fetcher(
          'https://movie.douban.com/j/subject_suggest?q=${Uri.encodeComponent(title)}',
          kDoubanHeaders,
          timeout: const Duration(seconds: 8),
        ),
        isCancelled: isCancelled,
      );
      if (res.status == 403) {
        _note403();
        return null;
      }
      if (res.status < 200 || res.status >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! List) {
        // Unusable reply (not a hit list) — a real suggest failure.
        _suggestFails++;
        if (_suggestFails >= 3) _cache.disableSuggest();
        return null;
      }
      final id = _pickSuggestId(_parseSuggestHits(decoded), title, year);
      if (id != null && id.isNotEmpty) {
        _suggestFails = 0;
        return id;
      }
      // A valid suggest reply with no eligible hit is NOT a suggest
      // failure (the service answered fine — the title just has no
      // good match): do not count it towards the 3-strike disable.
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _searchPageId(
    String title, {
    bool Function()? isCancelled,
  }) async {
    try {
      final html = await _text(
        'https://www.douban.com/search?cat=1002&q=${Uri.encodeComponent(title)}',
        {
          'User-Agent': kDirectVideoUa,
          'Referer': 'https://www.douban.com/',
        },
        timeout: const Duration(seconds: 10),
        isCancelled: isCancelled,
      );
      return parseDoubanSearchPageId(html);
    } catch (_) {
      return null;
    }
  }

  /// Title → Douban id (suggest → desktop search → builtin map).
  /// Cached by title key for [kDoubanIdMapTtl] (not permanently —
  /// P1-14). [year] (0 = unknown) is passed to suggest so a
  /// same-name remake / sequel resolves to the right year; the
  /// desktop-search and builtin fallbacks carry no year, so a wrong
  /// id from them is still caught later by detail()'s abstract-year
  /// check, which evicts the cached link.
  Future<String?> resolveId(
    String title, {
    int year = 0,
    bool Function()? isCancelled,
  }) async {
    final key = doubanTitleKey(title);
    final cached = _cache.idForTitle(key);
    if (cached != null) return cached;
    String? id;
    if (!_cache.suggestDisabled) {
      id = await _suggestId(title, year: year, isCancelled: isCancelled);
    }
    id ??= await _searchPageId(title, isCancelled: isCancelled);
    if (id == null || id.isEmpty) {
      final base = vodStripSeasonSuffix(title).base;
      id = kDoubanBuiltinIds[title] ?? kDoubanBuiltinIds[base];
    }
    if (id != null && id.isNotEmpty) _cache.setIdForTitle(key, id);
    return id;
  }

  /// Full detail flow, race-capped at 15 s (returns null on timeout).
  /// Never throws for upstream failures — returns null.
  Future<DoubanDetail?> detail(String title, String year) async {
    // D-P1-1: the 15 s timeout used to orphan the chain — run() kept
    // going (each _call up to 6-10 s + the 1 s serial gap), and a
    // stale success could setDetail AFTER the timeout, poisoning the
    // cache; the next detail() also queued behind the orphan's
    // leftover _calls. `cancelled` is set by onTimeout; run() checks
    // it after every await and before setDetail, and every _call in
    // the chain takes isCancelled so queued steps throw immediately
    // instead of fetching.
    var cancelled = false;
    bool isCancelled() => cancelled;

    Future<DoubanDetail?> run() async {
      if (blocked || cancelled) return null;
      final strip = vodStripSeasonSuffix(title);
      final base = strip.base;
      final wantYear = _parseYear(year);
      // The CMS year belongs to the full title (a specific season),
      // not to the stripped base series — e.g. 庆余年第二季 (2024)
      // resolves to the 庆余年 series entry (2019). Enforce the year
      // only when no season suffix was stripped.
      final useYear = !strip.stripped && wantYear != 0;
      var id = await resolveId(
        base,
        year: useYear ? wantYear : 0,
        isCancelled: isCancelled,
      );
      if (cancelled || id == null || id.isEmpty) return null;
      final cached = _cache.detail(id);
      if (cached != null) {
        if (_yearsMismatch(cached.year, useYear, wantYear)) {
          // The cached title→id link points at the wrong film: drop
          // the link AND the wrong detail, then resolve once more —
          // the year-aware suggest now excludes the bad id. If the
          // second resolve lands on the same id (suggest disabled /
          // search-page fallback), fall through: the abstract year
          // check below still guards what gets shown.
          _cache.removeIdForTitle(doubanTitleKey(base));
          _cache.removeDetail(id);
          final id2 = await resolveId(
            base,
            year: useYear ? wantYear : 0,
            isCancelled: isCancelled,
          );
          if (cancelled || id2 == null || id2.isEmpty) return null;
          if (id2 != id) {
            id = id2;
            final cached2 = _cache.detail(id);
            if (cached2 != null &&
                !_yearsMismatch(cached2.year, useYear, wantYear) &&
                !_photosMissing(cached2)) {
              return cached2;
            }
          }
        } else if (!_photosMissing(cached)) {
          return cached;
        }
        // Year OK but photos missing: fall through to a fresh fetch.
      }
      DoubanDetail? ab;
      try {
        ab = parseDoubanAbstract(
          await _json(
            'https://movie.douban.com/j/subject_abstract?subject_id=$id',
            isCancelled: isCancelled,
          ),
        );
      } catch (_) {
        ab = null;
      }
      if (cancelled || ab == null) return null;
      if (_yearsMismatch(ab.year, useYear, wantYear)) {
        // Wrong film confirmed by its own year: never cache it, never
        // show its score / poster / overview — and drop the title→id
        // link so the next open re-resolves instead of repeating the
        // mismatch.
        _cache.removeIdForTitle(doubanTitleKey(base));
        return null;
      }
      var mp = (poster: '', overview: '', score: null as String?);
      try {
        final html = await _text(
          'https://m.douban.com/movie/subject/$id/',
          kDoubanHeaders,
          isCancelled: isCancelled,
        );
        mp = parseDoubanMPage(html);
      } catch (_) {}
      if (cancelled) return null;
      // D-P1-2: desktop page + Baike lookups in PARALLEL (was serial:
      // desktop up to 6 s, THEN Baike 5 s — up to 11+ s after the m
      // page, past the 15 s budget). Desktop wins on merge. Baike
      // runs for all cast names (desktop "almost always yields
      // nothing" in production — login-walled — so the extra lookups
      // are the common case anyway); a failed/slow desktop or Baike
      // side degrades to {} and never kills the detail.
      final desktopFuture = _text(
        'https://movie.douban.com/subject/$id/',
        kDoubanHeaders,
        timeout: const Duration(seconds: 6),
        isCancelled: isCancelled,
      )
          .timeout(const Duration(seconds: 6))
          .then(parseDoubanDesktopCast)
          .catchError((_) => <String, String>{});
      final castNames = ab.castNames;
      final baikeFuture = castNames.isEmpty
          ? Future.value(<String, String>{})
          : Future.wait(castNames.map(_castPhotoFetcher)).then((got) {
              final byName = <String, String>{};
              for (var i = 0; i < castNames.length; i++) {
                if (got[i].isNotEmpty) byName[castNames[i]] = got[i];
              }
              return byName;
            });
      final photoResults = await Future.wait([
        desktopFuture,
        baikeFuture,
      ]);
      if (cancelled) return null;
      // Desktop page: cast avatar photos (best effort — a slow or
      // failed fetch must never kill the detail). NOTE: in production
      // this almost always yields nothing — the desktop subject page
      // is login-walled for anonymous requests (302 to sec.douban.com,
      // then `error code: 008, please Login`), so the parser finds no
      // celebrity blocks. The Baike fallback fills those gaps.
      // Douban photos win when present; Baike fills the rest.
      final byName = {...photoResults[1], ...photoResults[0]};
      final castPhotos =
          ab.castNames.map((n) => byName[n] ?? '').toList();
      final d = DoubanDetail(
        id: id,
        media: ab.media,
        title: ab.title.isNotEmpty ? ab.title : base,
        year: ab.year ?? (year.isNotEmpty ? year.substring(0, 4) : null),
        poster: mp.poster,
        overview: mp.overview,
        score: ab.score ?? mp.score,
        genres: ab.genres,
        runtime: ab.runtime,
        countries: ab.countries,
        director: ab.director,
        castNames: ab.castNames.take(10).toList(),
        castPhotos: castPhotos,
        episodes: ab.episodes,
      );
      if (cancelled) return null;
      _cache.setDetail(id, d);
      return d;
    }

    try {
      return await run().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          cancelled = true;
          return null;
        },
      );
    } catch (_) {
      return null;
    }
  }
}
