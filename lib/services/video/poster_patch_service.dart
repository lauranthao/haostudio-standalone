// Poster patch (1.1.6, browse A3 §2): high-res poster fallback when
// Douban fails.
//
// Priority is fixed — Douban `l_ratio_poster` (1080×1522, F1, detail
// page only) stays the primary. This service is ONLY the fallback
// when Douban returns nothing, plus the lazy lookup for a poster-less
// wall card. It never runs on the first paint: the wall never calls
// it for a card that already has a poster, and Douban's heavy chain
// is never invoked from here.
//
// Two providers, serial, 5 s each, validated like the danmaku
// candidate gate (normalised title must contain the query title; a
// candidate year that disagrees with the CMS year rejects the
// candidate). A failed lookup is cached for 1 h so a missing poster
// never becomes a retry storm; a success lives 7 days (same TTL as
// the Douban title→id map).
//
// - Bangumi: `api.bgm.tv` search, `images.large`. No key, no login.
//   Coverage is narrow (anime / 三次元番) — a non-anime title simply
//   returns nothing and falls through to Bilibili.
// - Bilibili PGC: `api.bilibili.com/x/web-interface/search/type`
//   (`media_bangumi` → `media_ft`), WBI-signed with the app's
//   existing `BilibiliWbiSigner` and the anonymous buvid device
//   cookie (same public `finger/spi` endpoint the live site uses).
//   buvid is an ANONYMOUS device id, not a login — if Bilibili ever
//   requires a logged-in cookie for this endpoint, this leg must be
//   dropped, never "upgraded" to a login.
//
// UNVERIFIED (report honestly, do not claim otherwise):
// - U2-1: Bangumi `images.large` / Bilibili `cover` real pixel sizes
//   (may be ≤ Douban 1080 — this is a "Douban failed" fallback, not
//   a "clearer than Douban" claim).
// - U2-2: Bangumi rate limits. U2-3: whether PGC search needs WBI +
//   buvid the same way live search does. U2-4: whether `lain.bgm.tv`
//   / `hdslb.com` images need a Referer (`RefererImage` only adds
//   one for doubanio hosts). U2-5: Bangumi coverage for non-anime.
//
// Cache key contract: the Hive key is defined HERE, not in HiveKeys
// (hive_store.dart is owned by the coordinator in this merge — same
// pattern as `kDvDowngradeHiveKey` in player_kernel.dart). The string
// value 'hao_poster_patch' is the contract; do not rename it.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/network/http_client.dart';
import '../../core/storage/hive_store.dart';
import '../../features/video/video_models.dart';
import '../../features/video/video_title_helpers.dart';
import '../../shared/platforms/bilibili/bilibili_wbi.dart';

/// Hive key for the title→poster patch map. Value is the contract.
const String kPosterPatchHiveKey = 'hao_poster_patch';

/// Success TTL (same as the Douban title→id map) / failure TTL.
const Duration kPosterPatchSuccessTtl = Duration(days: 7);
const Duration kPosterPatchFailureTtl = Duration(hours: 1);

/// Max cached mappings (oldest evicted, same cap as the Douban cache).
const int kPosterPatchMaxEntries = 200;

/// One JSON fetch. Returns the decoded body map, or null on any
/// failure (non-200, non-map, timeout — the caller treats null as
/// "this provider has nothing" and moves on).
typedef PosterPatchFetcher = Future<Map<String, dynamic>?> Function(
  String url, {
  Map<String, String>? headers,
  Map<String, dynamic>? queryParameters,
});

Future<Map<String, dynamic>?> _defaultPosterFetcher(
  String url, {
  Map<String, String>? headers,
  Map<String, dynamic>? queryParameters,
}) async {
  try {
    final res = await sharedDio().get<dynamic>(
      url,
      queryParameters: queryParameters,
      options: Options(
        headers: headers,
        receiveTimeout: const Duration(seconds: 5),
        sendTimeout: const Duration(seconds: 5),
      ),
    );
    if (res.statusCode != 200) return null;
    final data = res.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// WBI-sign a full URL (same contract as `BilibiliWbiSigner.signUrl`).
typedef PosterWbiSign = Future<Map<String, String>> Function(String url);

class PosterPatchService {
  PosterPatchService({
    PosterPatchFetcher? fetcher,
    PosterWbiSign? wbiSign,
    this._dio,
  })  : _fetch = fetcher ?? _defaultPosterFetcher,
        _signOverride = wbiSign;

  final PosterPatchFetcher _fetch;

  /// Dio for the live WBI signer / buvid fetch (null = sharedDio).
  final Dio? _dio;
  final PosterWbiSign? _signOverride;

  BilibiliWbiSigner? _signer;

  /// One signer per service (its WBI keys are cached 6 h — a fresh
  /// signer per call would re-fetch the nav keys every time).
  Future<Map<String, String>> _sign(String url) {
    if (_signOverride != null) return _signOverride(url);
    _signer ??= BilibiliWbiSigner(dio: _dio ?? sharedDio());
    return _signer!.signUrl(url);
  }

  /// Cache key: `normTitle|year` — the Smart Groups key (NOT the
  /// Douban `doubanTitleKey`: that one strips season suffixes and
  /// would let a season-2 poster land on season 1).
  static String patchKey(String title, String year) {
    final t = videoNormTitle(title);
    if (t.isEmpty) return '';
    final y = year.trim();
    return y.isEmpty ? t : '$t|$y';
  }

  Map<String, dynamic>? _map;
  bool _mapLoaded = false;
  final Map<String, Future<String?>> _inflight = {};
  String _buvid3 = '';
  String _buvid4 = '';
  Future<(String, String)>? _buvidRequest;

  Map<String, dynamic> _loadMap() {
    if (_mapLoaded) return _map ?? <String, dynamic>{};
    _mapLoaded = true;
    _map = <String, dynamic>{};
    try {
      final raw = HiveStore.box.get(kPosterPatchHiveKey);
      if (raw is String && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) _map = decoded;
      }
    } catch (_) {
      // Hive uninitialised (unit test) or corrupt: memory-only.
      _map = <String, dynamic>{};
    }
    return _map!;
  }

  void _saveMap() {
    final map = _map;
    if (map == null) return;
    // Oldest-first eviction by recorded time.
    while (map.length > kPosterPatchMaxEntries) {
      String? oldestKey;
      var oldestAt = 0;
      for (final e in map.entries) {
        final at = (e.value is Map ? (e.value as Map)['at'] as num? : null)
                ?.toInt() ??
            0;
        if (oldestKey == null || at < oldestAt) {
          oldestKey = e.key;
          oldestAt = at;
        }
      }
      if (oldestKey == null) break;
      map.remove(oldestKey);
    }
    try {
      unawaited(
        HiveStore.put(kPosterPatchHiveKey, jsonEncode(map)),
      );
    } catch (_) {}
  }

  void _remember(String key, String url, String source) {
    final map = _loadMap();
    map[key] = <String, dynamic>{
      'url': url,
      'source': source,
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    _saveMap();
  }

  /// A cached poster URL for [title]/[year], or null. Synchronous so
  /// the wall can apply it during render with zero network. Only
  /// unexpired SUCCESS entries count; failures are invisible here.
  String? cachedPatchFor(String title, String year) {
    final key = patchKey(title, year);
    if (key.isEmpty) return null;
    final entry = _loadMap()[key];
    if (entry is! Map) return null;
    final url = entry['url']?.toString() ?? '';
    final source = entry['source']?.toString() ?? '';
    if (url.isEmpty || source == 'failed') return null;
    final at = (entry['at'] as num?)?.toInt() ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - at >
        kPosterPatchSuccessTtl.inMilliseconds) {
      return null;
    }
    return url;
  }

  bool _failureFresh(String key) {
    final entry = _loadMap()[key];
    if (entry is! Map) return false;
    if (entry['source']?.toString() != 'failed') return false;
    final at = (entry['at'] as num?)?.toInt() ?? 0;
    return DateTime.now().millisecondsSinceEpoch - at <
        kPosterPatchFailureTtl.inMilliseconds;
  }

  /// Look a poster up (Bangumi → Bilibili PGC), validate it, cache
  /// the outcome and return the URL — or null. Concurrent callers
  /// for the same title share one lookup. Never throws.
  Future<String?> patchFor(String title, String year) {
    final key = patchKey(title, year);
    if (key.isEmpty) return Future.value(null);
    final cached = cachedPatchFor(title, year);
    if (cached != null) return Future.value(cached);
    if (_failureFresh(key)) return Future.value(null);
    final pending = _inflight[key];
    if (pending != null) return pending;
    late final Future<String?> job;
    job = _lookup(title, year).then((url) {
      if (url != null) {
        _remember(key, url, 'patch');
      } else {
        _remember(key, '', 'failed');
      }
      return url;
    }).whenComplete(() {
      if (identical(_inflight[key], job)) _inflight.remove(key);
    });
    _inflight[key] = job;
    return job;
  }

  /// Apply cached patches to a fetched list (wall render): only
  /// poster-less items are touched, and only with an unexpired
  /// cached URL. No network, no change to the source data. Returns
  /// the same list instance when nothing was patched.
  List<VideoItem> withCachedPatches(List<VideoItem> items) {
    var changed = false;
    final out = items.map((item) {
      if (item.pic.isNotEmpty) return item;
      final patched = cachedPatchFor(item.name, item.year);
      if (patched == null) return item;
      changed = true;
      return item.copyWith(pic: patched);
    }).toList();
    return changed ? out : items;
  }

  Future<String?> _lookup(String title, String year) async {
    try {
      final bgm = await _bangumi(title, year)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      if (bgm != null) return bgm;
    } catch (_) {}
    try {
      final bili = await _bilibili(title, year)
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
      if (bili != null) return bili;
    } catch (_) {}
    return null;
  }

  /// Same gate as the danmaku candidate check, with an explicit
  /// candidate year (Bangumi `air_date`): normalised candidate title
  /// must contain the query title; a candidate year that disagrees
  /// with the CMS year rejects the candidate.
  static bool candidatePasses({
    required String candidateName,
    String? candidateYear,
    required String queryTitle,
    required String queryYear,
  }) {
    final qn = videoNormTitle(queryTitle);
    if (qn.isEmpty) return false;
    final cn = videoNormTitle(candidateName);
    if (cn.isEmpty || !cn.contains(qn)) return false;
    final cy = (candidateYear ?? '').trim();
    final qy = queryYear.trim();
    if (cy.isNotEmpty && qy.isNotEmpty && cy != qy) return false;
    return true;
  }

  Future<String?> _bangumi(String title, String year) async {
    final q = Uri.encodeComponent(title.trim());
    final body = await _fetch(
      'https://api.bgm.tv/search/subject/$q?type=2&responseGroup=large',
      headers: const {
        'User-Agent': 'HAoStudio/1.1.6 (poster-patch)',
        'Accept': 'application/json',
      },
    );
    final list = body?['list'] as List? ?? const [];
    for (final raw in list.whereType<Map<String, dynamic>>()) {
      final images = raw['images'];
      final url = images is Map
          ? (images['large']?.toString() ?? '')
          : '';
      if (url.isEmpty) continue;
      final nameCn = (raw['name_cn'] as String?) ?? '';
      final name = (raw['name'] as String?) ?? '';
      final airDate = (raw['air_date'] as String?) ?? '';
      final cYear = airDate.length >= 4 ? airDate.substring(0, 4) : '';
      if (candidatePasses(
            candidateName: nameCn.isNotEmpty ? nameCn : name,
            candidateYear: cYear,
            queryTitle: title,
            queryYear: year,
          ) ||
          (nameCn.isNotEmpty &&
              candidatePasses(
                candidateName: name,
                candidateYear: cYear,
                queryTitle: title,
                queryYear: year,
              ))) {
        return url;
      }
    }
    return null;
  }

  Future<(String, String)> _resolveBuvid() async {
    if (_buvid3.isNotEmpty) return (_buvid3, _buvid4);
    final pending = _buvidRequest;
    if (pending != null) return pending;
    late final Future<(String, String)> operation;
    operation = _fetchBuvid().whenComplete(() {
      if (identical(_buvidRequest, operation)) _buvidRequest = null;
    });
    _buvidRequest = operation;
    return operation;
  }

  /// Anonymous device ids, same public endpoint the live site uses
  /// (`finger/spi`). No account, no password, no login of any kind.
  Future<(String, String)> _fetchBuvid() async {
    try {
      final body = await _fetch(
        'https://api.bilibili.com/x/frontend/finger/spi',
        headers: const {
          'user-agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
          'referer': 'https://www.bilibili.com/',
        },
      );
      final data = body?['data'];
      final b3 = data is Map ? (data['b_3']?.toString() ?? '') : '';
      final b4 = data is Map ? (data['b_4']?.toString() ?? '') : '';
      _buvid3 = b3;
      _buvid4 = b4;
      return (b3, b4);
    } catch (_) {
      return ('', '');
    }
  }

  static String _stripEmTags(String s) =>
      s.replaceAll(RegExp(r'</?em[^>]*>'), '');

  Future<String?> _bilibili(String title, String year) async {
    final (b3, b4) = await _resolveBuvid();
    const base = 'https://api.bilibili.com/x/web-interface/search/type';
    for (final searchType in ['media_bangumi', 'media_ft']) {
      try {
        final signed = await _sign(
          '$base?search_type=$searchType&keyword=${Uri.encodeComponent(title)}&page=1&page_size=5',
        );
        final body = await _fetch(
          base,
          headers: <String, String>{
            'user-agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
            'referer': 'https://www.bilibili.com/',
            if (b3.isNotEmpty) 'cookie': 'buvid3=$b3;buvid4=$b4;',
          },
          queryParameters: signed,
        );
        if (body?['code'] != 0) continue;
        final data = body?['data'];
        final result = data is Map ? data['result'] : null;
        if (result is! List) continue;
        for (final raw in result.whereType<Map<String, dynamic>>()) {
          final cover = (raw['cover'] as String?) ?? '';
          if (cover.isEmpty) continue;
          final name = _stripEmTags((raw['title'] as String?) ?? '');
          // PGC search returns no reliable year: the title gate is
          // the only check (a wrong-year candidate cannot be told
          // apart here, so the gate must stay strict).
          if (candidatePasses(
            candidateName: name,
            queryTitle: title,
            queryYear: year,
          )) {
            return cover;
          }
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}
