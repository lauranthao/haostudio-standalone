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
// Caches (200-entry cap, oldest evicted): detail by id + title→id map,
// permanent. [DoubanCache] is Hive-backed in production and in-memory
// in tests.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/network/http_client.dart';
import '../../core/storage/hive_store.dart';
import '../../features/video/cms_sources.dart';
import '../../features/video/video_models.dart';
import '../../features/video/video_title_helpers.dart';
import 'douban_parsers.dart';

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

/// Cache backend for Douban detail + id map.
abstract class DoubanCache {
  DoubanDetail? detail(String id);
  void setDetail(String id, DoubanDetail detail);
  String? idForTitle(String key);
  void setIdForTitle(String key, String id);
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
    map[id] = {
      ...detail.toJson(),
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    if (map.length > maxEntries) {
      final keys = map.keys.toList()
        ..sort((a, b) {
          final atA = (map[a] as Map?)?['at'] as num? ?? 0;
          final atB = (map[b] as Map?)?['at'] as num? ?? 0;
          return atA.compareTo(atB);
        });
      for (var i = 0; i < map.length - maxEntries; i++) {
        map.remove(keys[i]);
      }
    }
    _writeMap(HiveKeys.doubanDetail, map);
  }

  @override
  String? idForTitle(String key) {
    final map = _readMap(HiveKeys.doubanIdmap);
    final v = map[key];
    return v is String ? v : null;
  }

  @override
  void setIdForTitle(String key, String id) {
    final map = _readMap(HiveKeys.doubanIdmap);
    map[key] = id;
    if (map.length > maxEntries) {
      final keys = map.keys.toList();
      for (var i = 0; i < map.length - maxEntries; i++) {
        map.remove(keys[i]);
      }
    }
    _writeMap(HiveKeys.doubanIdmap, map);
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
  bool _suggestDisabled = false;

  @override
  DoubanDetail? detail(String id) => details[id];

  @override
  void setDetail(String id, DoubanDetail detail) {
    details[id] = detail;
  }

  @override
  String? idForTitle(String key) => ids[key];

  @override
  void setIdForTitle(String key, String id) {
    ids[key] = id;
  }

  @override
  bool get suggestDisabled => _suggestDisabled;

  @override
  void disableSuggest() {
    _suggestDisabled = true;
  }
}

class DoubanService {
  DoubanService({DoubanFetcher? fetcher, DoubanCache? cache})
      : _fetcher = fetcher ?? defaultDoubanFetcher,
        _cache = cache ?? HiveDoubanCache();

  final DoubanFetcher _fetcher;
  final DoubanCache _cache;

  Future<void> _chain = Future.value();
  DateTime _lastCall = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _suggestFails = 0;

  bool get blocked => DateTime.now().isBefore(_blockedUntil);

  void _note403() {
    _blockedUntil = DateTime.now().add(const Duration(seconds: 60));
  }

  /// Serialised call with a ≥ 1 s gap (`doubanCall`).
  Future<T> _call<T>(Future<T> Function() fn) {
    final run = _chain.then((_) async {
      if (blocked) throw StateError('douban blocked');
      final wait = const Duration(seconds: 1) -
          DateTime.now().difference(_lastCall);
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
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
  }) async {
    final res = await _call(
      () => _fetcher(url, kDoubanHeaders, timeout: timeout),
    );
    if (res.status == 403) {
      if (!noBackoff) _note403();
      throw StateError('douban 403');
    }
    if (res.status < 200 || res.status >= 300) {
      throw StateError('http ${res.status}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<String> _text(
    String url,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final res = await _call(
      () => _fetcher(url, headers, timeout: timeout),
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

  Future<String?> _suggestId(String title) async {
    try {
      final res = await _call(
        () => _fetcher(
          'https://movie.douban.com/j/subject_suggest?q=${Uri.encodeComponent(title)}',
          kDoubanHeaders,
          timeout: const Duration(seconds: 8),
        ),
      );
      if (res.status == 403) {
        _note403();
        return null;
      }
      if (res.status < 200 || res.status >= 300) return null;
      final id = parseDoubanSuggestId(jsonDecode(res.body));
      if (id != null && id.isNotEmpty) {
        _suggestFails = 0;
        return id;
      }
      _suggestFails++;
      if (_suggestFails >= 3) _cache.disableSuggest();
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _searchPageId(String title) async {
    try {
      final html = await _text(
        'https://www.douban.com/search?cat=1002&q=${Uri.encodeComponent(title)}',
        {
          'User-Agent': kDirectVideoUa,
          'Referer': 'https://www.douban.com/',
        },
        timeout: const Duration(seconds: 10),
      );
      return parseDoubanSearchPageId(html);
    } catch (_) {
      return null;
    }
  }

  /// Title → Douban id (suggest → desktop search → builtin map).
  /// Cached by title key permanently.
  Future<String?> resolveId(String title) async {
    final key = doubanTitleKey(title);
    final cached = _cache.idForTitle(key);
    if (cached != null) return cached;
    String? id;
    if (!_cache.suggestDisabled) {
      id = await _suggestId(title);
    }
    id ??= await _searchPageId(title);
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
    Future<DoubanDetail?> run() async {
      if (blocked) return null;
      final base = vodStripSeasonSuffix(title).base;
      final id = await resolveId(base);
      if (id == null || id.isEmpty) return null;
      final cached = _cache.detail(id);
      if (cached != null) return cached;
      DoubanDetail? ab;
      try {
        ab = parseDoubanAbstract(
          await _json(
            'https://movie.douban.com/j/subject_abstract?subject_id=$id',
          ),
        );
      } catch (_) {
        ab = null;
      }
      if (ab == null) return null;
      var mp = (poster: '', overview: '', score: null as String?);
      try {
        final html = await _text(
          'https://m.douban.com/movie/subject/$id/',
          kDoubanHeaders,
        );
        mp = parseDoubanMPage(html);
      } catch (_) {}
      // Desktop page: cast avatar photos (best effort — a slow or
      // failed fetch must never kill the detail).
      var castPhotos = const <String>[];
      try {
        final desktopHtml = await _text(
          'https://movie.douban.com/subject/$id/',
          kDoubanHeaders,
          timeout: const Duration(seconds: 6),
        ).timeout(const Duration(seconds: 6));
        final byName = parseDoubanDesktopCast(desktopHtml);
        if (byName.isNotEmpty) {
          castPhotos = ab.castNames.map((n) => byName[n] ?? '').toList();
        }
      } catch (_) {}
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
      _cache.setDetail(id, d);
      return d;
    }

    try {
      return await run().timeout(
        const Duration(seconds: 15),
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    }
  }
}
