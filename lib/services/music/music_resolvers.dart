// Play-URL resolvers — Dart port of resolvers.js (14 resolvers).
//
// resolvePlayUrl(songId, platform, quality, title) ->
// {url, candidates, quality, via} | null.
//
// Fastest-first, sequential (chen 2026-11-17 拍板: 每次解析都用最快
// 的源, 没有想要的资源就换源继续找, 直到找到能播的为止 — 歌一刀/LX
// 模型: 一次只问一个源, 不搞十几个并行扇出):
// - Jobs (built-in resolvers + LX script jobs) are ordered by measured
//   speed, fastest first; an unknown job ranks in the middle (500 ms
//   placeholder) and falls back to its declared order.
// - Each pass tries jobs one by one (per-job timeout 3 s, pass budget
//   6 s). The first URL at-or-above the requested tier wins at once.
//   A below-tier URL is kept as fallback while at most 2 more jobs
//   (5 for master) are tried for a tier-matching one, then the
//   fallback is returned. Master honesty gate: only a real master
//   URL satisfies master; anything lesser downgrades, never
//   mislabelled.
// - A job that fails 3 times in a row is cooled down for 5 min (sorted
//   last, still tried if nothing else works). Speeds persist in Hive
//   so the ranking survives restarts.
// - Passes: requested quality first; only when NO source returns any
//   URL at all, re-ask at 320k, then 128k. The old tier loop re-fired
//   every resolver at every tier (worst case ~15 s); now the common
//   case is one sequential pass over the fastest sources.
// - Resolved URLs are cached persistently (Hive, 1 h TTL) like LX's
//   disk cache, so a replayed song resolves instantly.
// Downgrade never persists (rule "fi"): the caller always passes the
// user's chosen tier for every new song.
//
// The Huibq key is public in the lx-music-source repo (fetched via
// jsdelivr) — no secret handling. The hyw resolver stays DISABLED by
// default (direct-IP host, shared key), exactly like the JS.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/network/http_client.dart';
import '../../core/storage/hive_store.dart';
import 'lx_script_engine.dart';
import 'lx_script_store.dart';
import 'music_models.dart';
import 'music_quality.dart';

const String _musicUa =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 '
    'Safari/604.1';
const String _huibqApi = 'https://lxmusicapi.onrender.com';
const String _huibqKeyUrl =
    'https://cdn.jsdelivr.net/gh/tfappstore/lx-music-source@main/huibq/latest.js';
const String _huibqSeedKey = 'share-v3';
const String _xhTokenUrl = 'https://yy1.zddyr.top/lx/api/token.php';

class PlayUrlResult {
  PlayUrlResult({
    required this.url,
    required this.candidates,
    required this.quality,
    required this.via,
  });

  final String url;
  final List<String> candidates;
  final AudioQuality quality;
  final String via;
}

typedef _ResolverFn = Future<String> Function(
  String songId,
  MusicPlatform platform,
  AudioQuality quality,
  String title,
);

/// One resolution job: a built-in resolver or an LX script job, unified
/// so [_resolvePass] runs them in measured-speed order. `order` is the
/// declared order, used as the tie-break for never-measured jobs.
typedef _Job = ({
  String key,
  String name,
  int order,
  _ResolverFn fn,
});

class _Resolver {
  _Resolver({
    required this.key,
    required this.name,
    required this.platforms,
    required this.enabled,
    required this.order,
    required this.fn,
  });

  final String key;
  final String name;
  final List<MusicPlatform> platforms;
  final bool enabled;
  final int order;
  final _ResolverFn fn;
}

/// In-memory play-URL cache (haoParseCache): key songId|platform|quality,
/// TTL 5 min, max 200 entries, oldest evicted.
///
/// LX-style persistent layer (2026-11-17, 歌一刀/LX 借鉴): LX stores
/// every resolved URL on disk (`musicUrl_{id}_{type}`, no expiry), so a
/// song played before resolves instantly. Ours was memory-only — every
/// app restart re-resolved from scratch. Persist to Hive with a 1 h
/// TTL (signed CDN URLs do expire; LX trusts the cache blindly, we
/// bound it). Hive access is guarded: resolvers also run in unit
/// tests without HiveStore.init().
class _PlayUrlCache {
  static const _ttl = Duration(hours: 1);
  static const _prefix = 'hao_play_url_cache:';

  final _map = <String, (PlayUrlResult, DateTime)>{};

  PlayUrlResult? get(String key) {
    final hit = _map[key];
    if (hit != null) {
      if (DateTime.now().difference(hit.$2) > _ttl) {
        _map.remove(key);
      } else {
        return hit.$1;
      }
    }
    try {
      final raw = HiveStore.getString('$_prefix$key', '');
      if (raw.isEmpty) return null;
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return null;
      final at = DateTime.fromMillisecondsSinceEpoch(
        (j['at'] as num?)?.toInt() ?? 0,
      );
      if (DateTime.now().difference(at) > _ttl) return null;
      final url = j['u']?.toString() ?? '';
      if (url.isEmpty) return null;
      // Drop a cached URL NSURL would reject (cached before the
      // v1.0.7 crash fix): re-resolve instead of crashing on it.
      if (!isPlayableUrl(url)) return null;
      final result = PlayUrlResult(
        url: url,
        candidates: (j['c'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            [url],
        quality: AudioQualityX.fromCode(j['q']?.toString() ?? ''),
        via: j['v']?.toString() ?? '',
      );
      _map[key] = (result, at);
      return result;
    } catch (_) {
      return null;
    }
  }

  void put(String key, PlayUrlResult value) {
    if (_map.length >= 200) {
      _map.remove(_map.keys.first);
    }
    final now = DateTime.now();
    _map[key] = (value, now);
    try {
      unawaited(
        HiveStore.put(
          '$_prefix$key',
          jsonEncode({
            'u': value.url,
            'c': value.candidates,
            'q': value.quality.code,
            'v': value.via,
            'at': now.millisecondsSinceEpoch,
          }),
        ).catchError((_) {}),
      );
    } catch (_) {}
  }
}

class MusicResolvers {
  MusicResolvers({Dio? dio, LxScriptEngine? scriptEngine})
      : _dio = dio ?? sharedDio(),
        _scriptEngine = scriptEngine ?? LxScriptEngine.instance;

  final Dio _dio;

  /// LX script engine (M-P0-6). Defaults to the process singleton;
  /// tests pass their own engine (or a never-initialised one to
  /// disable script jobs entirely).
  final LxScriptEngine _scriptEngine;
  final _cache = _PlayUrlCache();

  /// Measured resolver speeds, for fastest-first ordering (chen
  /// 2026-11-17: 每次解析都用最快的). Keyed by job key (built-in
  /// resolver key or `lx:<script id>`). Persisted to Hive so the
  /// ranking survives restarts; load is lazy and guarded (resolvers
  /// also run in unit tests without HiveStore.init()).
  final _speedAvg = <String, int>{};
  final _speedFails = <String, int>{};
  final _speedCooledUntil = <String, DateTime>{};
  bool _speedLoaded = false;
  bool _speedDirty = false;

  static const _speedHiveKey = 'hao_resolver_speed';
  static const _unknownSpeedMs = 500;
  static const _coolAfterFails = 3;
  static const _coolFor = Duration(minutes: 5);

  void _loadSpeeds() {
    if (_speedLoaded) return;
    _speedLoaded = true;
    try {
      final raw = HiveStore.getString(_speedHiveKey, '');
      if (raw.isEmpty) return;
      final map = jsonDecode(raw);
      if (map is! Map) return;
      for (final e in map.entries) {
        final v = e.value;
        if (v is! Map) continue;
        final avg = v['avg'];
        if (avg is num) _speedAvg[e.key.toString()] = avg.toInt();
        final fails = v['fails'];
        if (fails is num) _speedFails[e.key.toString()] = fails.toInt();
        final cooled = v['cooled'];
        if (cooled is num) {
          _speedCooledUntil[e.key.toString()] =
              DateTime.fromMillisecondsSinceEpoch(cooled.toInt());
        }
      }
    } catch (_) {
      // No Hive / corrupt data — start unranked, declaration order.
    }
  }

  void _saveSpeeds() {
    if (!_speedDirty) return;
    _speedDirty = false;
    try {
      final map = <String, Map<String, int>>{};
      for (final k in {
        ..._speedAvg.keys,
        ..._speedFails.keys,
        ..._speedCooledUntil.keys,
      }) {
        map[k] = {
          if (_speedAvg[k] != null) 'avg': _speedAvg[k]!,
          if (_speedFails[k] != null) 'fails': _speedFails[k]!,
          if (_speedCooledUntil[k] != null)
            'cooled': _speedCooledUntil[k]!.millisecondsSinceEpoch,
        };
      }
      unawaited(HiveStore.put(_speedHiveKey, jsonEncode(map)));
    } catch (_) {
      // Persistence is best-effort; in-memory ranking still works.
    }
  }

  /// Record one job attempt. Success updates the EMA latency and
  /// resets the failure streak; failure bumps the streak and cools
  /// the job down after [_coolAfterFails] in a row, so a dead
  /// "fastest" source stops blocking the race (换源).
  void _recordAttempt(String key, bool ok, int ms) {
    if (ok) {
      final prev = _speedAvg[key];
      _speedAvg[key] = prev == null ? ms : (prev * 7 + ms * 3) ~/ 10;
      _speedFails.remove(key);
      _speedCooledUntil.remove(key);
    } else {
      final fails = (_speedFails[key] ?? 0) + 1;
      _speedFails[key] = fails;
      if (fails >= _coolAfterFails) {
        _speedCooledUntil[key] = DateTime.now().add(_coolFor);
      }
    }
    _speedDirty = true;
  }

  bool _isCooled(String key, DateTime now) {
    final until = _speedCooledUntil[key];
    if (until == null) return false;
    if (now.isBefore(until)) return true;
    _speedCooledUntil.remove(key);
    return false;
  }

  /// Jobs for this platform in fastest-first order: cooled-down jobs
  /// last, then by measured latency (unknown = middle), then by
  /// declared order.
  List<_Job> _rankedJobs(
    MusicPlatform pf,
    AudioQuality q,
    String songId,
    String title,
  ) {
    _loadSpeeds();
    final song = Song(songId: songId, title: title, platform: pf);
    final jobs = <_Job>[
      for (final r in _applicable(pf))
        (key: r.key, name: r.name, order: r.order, fn: r.fn),
      for (final s in _scriptEngine.scriptJobsFor(pf, q, song))
        (key: s.key, name: s.name, order: 2, fn: (_, _, _, _) => s.fn()),
    ];
    final now = DateTime.now();
    jobs.sort((a, b) {
      final aCool = _isCooled(a.key, now);
      final bCool = _isCooled(b.key, now);
      if (aCool != bCool) return aCool ? 1 : -1;
      final aMs = _speedAvg[a.key] ?? _unknownSpeedMs;
      final bMs = _speedAvg[b.key] ?? _unknownSpeedMs;
      if (aMs != bMs) return aMs.compareTo(bMs);
      return a.order.compareTo(b.order);
    });
    return jobs;
  }

  String? _huibqKey;
  DateTime? _huibqKeyAt;
  String? _xhToken;
  DateTime? _xhTokenAt;
  Future<String>? _xhTokenFuture;

  Future<Map<String, dynamic>?> _fetchJson(
    String url, {
    Map<String, String>? headers,
    String? method,
    String? body,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final res = await _dio.request<dynamic>(
        url,
        data: body,
        options: Options(
          method: method ?? 'GET',
          headers: headers,
          receiveTimeout: timeout,
          sendTimeout: timeout,
          responseType: ResponseType.json,
        ),
      );
      if (res.statusCode != 200) return null;
      final data = res.data;
      if (data is Map<String, dynamic>) return data;
      if (data is String) {
        try {
          final decoded = jsonDecode(data);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {}
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _fetchText(String url, {Duration? timeout}) async {
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(
          receiveTimeout: timeout ?? const Duration(seconds: 10),
          responseType: ResponseType.plain,
        ),
      );
      if (res.statusCode != 200) return null;
      return res.data;
    } catch (_) {
      return null;
    }
  }

  // -- key / token plumbing --------------------------------------------------

  String _xhDeviceId() {
    var d = HiveStore.getString('hao_sa_xh_device', '');
    if (d.isEmpty) {
      final rand = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
      d = 'lx-sa-${rand.substring(rand.length > 8 ? rand.length - 8 : 0)}'
          '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
      unawaited(HiveStore.put('hao_sa_xh_device', d));
    }
    return d;
  }

  Future<String> _getXhToken() async {
    if (_xhToken != null &&
        _xhTokenAt != null &&
        DateTime.now().difference(_xhTokenAt!) <
            const Duration(minutes: 4)) {
      return _xhToken!;
    }
    _xhTokenFuture ??= () async {
      final j = await _fetchJson(
        '$_xhTokenUrl?device_id=${Uri.encodeComponent(_xhDeviceId())}',
        headers: {'User-Agent': 'lx-music'},
        timeout: const Duration(seconds: 6),
      );
      final tk = (j?['data'] as Map<String, dynamic>?)?['token']?.toString() ?? '';
      if (tk.isNotEmpty) {
        _xhToken = tk;
        _xhTokenAt = DateTime.now();
      }
      return tk;
    }().whenComplete(() => _xhTokenFuture = null);
    return _xhTokenFuture!;
  }

  Future<String> _getHuibqKey() async {
    if (_huibqKey != null &&
        _huibqKeyAt != null &&
        DateTime.now().difference(_huibqKeyAt!) < const Duration(hours: 1)) {
      return _huibqKey!;
    }
    await _refreshHuibqKey();
    return _huibqKey ?? _huibqSeedKey;
  }

  Future<bool> _refreshHuibqKey() async {
    final code = await _fetchText(_huibqKeyUrl);
    final m = RegExp(r'''API_KEY\s*=\s*['"]([^'"]+)['"]''').firstMatch(code ?? '');
    if (m != null && (m.group(1) ?? '').isNotEmpty) {
      _huibqKey = m.group(1);
      _huibqKeyAt = DateTime.now();
      return true;
    }
    return false;
  }

  Future<String> _huibqUrl(
    String songId,
    MusicPlatform pf,
    AudioQuality q,
  ) async {
    Future<String> once() async {
      final key = await _getHuibqKey();
      final j = await _fetchJson(
        '$_huibqApi/url/${pf.code}/${Uri.encodeComponent(songId)}/${srcQuality(q)}',
        headers: {
          'X-Request-Key': key,
          'User-Agent': 'lx-music-request/1.0',
        },
        timeout: const Duration(seconds: 8),
      );
      if (j == null) return '';
      if (j['code'] == 1) return '__KEY_EXPIRED__';
      final url = j['url']?.toString() ??
          (j['data'] as Map<String, dynamic>?)?['url']?.toString() ??
          '';
      return toHttps(url);
    }

    final first = await once();
    if (first == '__KEY_EXPIRED__') {
      final ok = await _refreshHuibqKey();
      if (!ok) return '';
      final second = await once();
      return second == '__KEY_EXPIRED__' ? '' : second;
    }
    return first;
  }

  // -- the 14 resolvers (order = try order) ----------------------------------

  List<_Resolver> get _resolvers => [
        _Resolver(
          key: 'huibq',
          name: 'Huibq',
          platforms: MusicPlatform.values,
          // DISABLED 2026-11-17: lxmusicapi.onrender.com returns 503
          // "Service Suspended" (verified by curl) — the order-1
          // resolver was dead, and its jsdelivr key fetch (10 s
          // timeout) ran before every first/hourly call. Re-enable
          // only if the service revives.
          enabled: false,
          order: 1,
          fn: (id, pf, q, title) => _huibqUrl(id, pf, q),
        ),
        _Resolver(
          key: 'ikun',
          name: 'ikun',
          platforms: const [MusicPlatform.wy],
          enabled: true,
          order: 2,
          fn: (id, pf, q, title) async {
            // Master only: the ikun API is the only direct resolver
            // with a distinct master tier (quality=master). Other
            // tiers already have many resolvers; asking ikun for them
            // would only add load on a fragile API.
            // STATUS 2026-11-16: api.ikunshare.com is DEAD from this
            // VM (empty replies, http+https) — this resolver returns ''
            // until the API revives. Master does not depend on it:
            // zddyr/xinghai serve master live (see music_quality.dart).
            // iOS note: plain http:// — blocked by ATS unless an
            // exception is added; zddyr/xinghai are https.
            if (q != AudioQuality.master) return '';
            final j = await _fetchJson(
              'http://api.ikunshare.com/url?source=wy&songId=${Uri.encodeComponent(id)}&quality=master',
              headers: {
                'Content-Type': 'application/json',
                'User-Agent': 'lx-music-request/1.0',
                'X-Request-Key': '',
              },
              timeout: const Duration(seconds: 8),
            );
            return (j != null && j['code'] == 200)
                ? toHttps(j['url']?.toString() ?? '')
                : '';
          },
        ),
        _Resolver(
          key: 'tang',
          name: 'tang',
          platforms: const [MusicPlatform.tx],
          enabled: true,
          order: 15,
          fn: (id, pf, q, title) async {
            final j = await _fetchJson(
              'https://tang.api.s01s.cn/music_open_api.php?mid=${Uri.encodeComponent(id)}',
              headers: {'User-Agent': _musicUa},
            );
            if (j == null || j['song_play_url'] == null) return '';
            // QQ top tier field is `song_play_url_pq` — it is the hires
            // tier's URL source, not a separate Master tier (see
            // music_quality.dart header).
            final field = q == AudioQuality.hires
                ? 'song_play_url_pq'
                : q == AudioQuality.lossless
                    ? 'song_play_url_sq'
                    : q == AudioQuality.q320k
                        ? 'song_play_url_hq'
                        : 'song_play_url_standard';
            return toHttps(
              j[field]?.toString() ?? j['song_play_url']?.toString() ?? '',
            );
          },
        ),
        _Resolver(
          key: 'lzm',
          name: 'lzm',
          platforms: const [MusicPlatform.wy],
          enabled: true,
          order: 20,
          fn: (id, pf, q, title) async {
            final j = await _fetchJson(
              'https://music.lzmhhh.com/api/music/url',
              method: 'POST',
              headers: {
                'User-Agent': _musicUa,
                'Content-Type': 'application/x-www-form-urlencoded',
                'Referer': 'https://music.lzmhhh.com/',
              },
              body: 'id=${Uri.encodeComponent(id)}&type=wy',
            );
            return toHttps(j?['data']?.toString() ?? '');
          },
        ),
        _Resolver(
          key: 'zddyr',
          name: 'zddyr',
          platforms: const [MusicPlatform.wy],
          enabled: true,
          order: 25,
          fn: (id, pf, q, title) async {
            final j = await _fetchJson(
              'https://yy.zddyr.top/lx/api/?source=wy&songmid=${Uri.encodeComponent(id)}&quality=${lxQuality(q)}',
              headers: {'User-Agent': _musicUa},
            );
            return (j != null && j['code'] == 200)
                ? toHttps(j['url']?.toString() ?? '')
                : '';
          },
        ),
        _Resolver(
          key: 'gd',
          name: 'GD Studio',
          platforms: const [MusicPlatform.wy],
          enabled: true,
          order: 30,
          fn: (id, pf, q, title) async {
            final j = await _fetchJson(
              'https://music-api.gdstudio.xyz/api.php?types=url&id=${Uri.encodeComponent(id)}&source=netease&br=${gdBr(q)}',
              headers: {'User-Agent': _musicUa},
            );
            return toHttps(j?['url']?.toString() ?? '');
          },
        ),
        _Resolver(
          key: 'xinghai',
          name: '星海',
          platforms: const [
            MusicPlatform.wy,
            MusicPlatform.kg,
            MusicPlatform.kw,
          ],
          enabled: true,
          order: 40,
          fn: (id, pf, q, title) async {
            final tk = await _getXhToken();
            if (tk.isEmpty) return '';
            const bs = {
              MusicPlatform.wy: 'wy',
              MusicPlatform.tx: 'qq',
              MusicPlatform.kg: 'kg',
              MusicPlatform.kw: 'kw',
              MusicPlatform.mg: 'mg',
            };
            var url =
                'https://yy1.zddyr.top/lx/api/?source=${bs[pf] ?? pf.code}&songmid=${Uri.encodeComponent(id)}&quality=${lxQuality(q)}';
            if (pf == MusicPlatform.kg) {
              url += '&mainHash=${Uri.encodeComponent(id)}';
            }
            final j = await _fetchJson(
              url,
              headers: {
                'User-Agent': 'lx-music',
                'X-Client': 'XingHaiMusicSource/v3.2.19 (Linux)',
                'X-Token': tk,
              },
            );
            return (j != null && j['code'] == 200)
                ? toHttps(j['url']?.toString() ?? '')
                : '';
          },
        ),
        _Resolver(
          key: 'oiapi_wy',
          name: 'oiapi-网易',
          platforms: const [MusicPlatform.wy],
          enabled: true,
          order: 60,
          fn: (id, pf, q, title) async {
            final j = await _fetchJson(
              'https://oiapi.net/api/Music_163?id=${Uri.encodeComponent(id)}',
              headers: {'User-Agent': _musicUa},
            );
            if (j == null || j['code'] != 0) return '';
            final data = j['data'] as List<dynamic>?;
            if (data == null || data.isEmpty) return '';
            final first = data.first as Map<String, dynamic>?;
            return toHttps(first?['url']?.toString() ?? '');
          },
        ),
        _Resolver(
          key: 'qjqq',
          name: 'qjqq',
          platforms: const [MusicPlatform.wy],
          enabled: true,
          order: 70,
          fn: (id, pf, q, title) async {
            final j = await _fetchJson(
              'https://metings.qjqq.cn/Song_V1',
              method: 'POST',
              headers: {
                'User-Agent': _musicUa,
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body:
                  'url=${Uri.encodeComponent(id)}&level=${songLevel(q)}&type=json',
            );
            final data = j?['data'] as Map<String, dynamic>?;
            return toHttps(data?['url']?.toString() ?? '');
          },
        ),
        _Resolver(
          key: 'kangqi',
          name: 'kangqi',
          platforms: const [MusicPlatform.wy],
          enabled: true,
          order: 80,
          fn: (id, pf, q, title) async {
            final j = await _fetchJson(
              'https://ncm.kangqiovo.com/Song_V1',
              method: 'POST',
              headers: {
                'User-Agent': _musicUa,
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body:
                  'url=${Uri.encodeComponent(id)}&level=${songLevel(q)}&type=json',
            );
            final data = j?['data'] as Map<String, dynamic>?;
            return toHttps(data?['url']?.toString() ?? '');
          },
        ),
        _Resolver(
          key: 'yutang',
          name: 'yutang',
          platforms: const [MusicPlatform.wy],
          enabled: true,
          order: 90,
          fn: (id, pf, q, title) async {
            final j = await _fetchJson(
              'https://api.yutangxiaowu.cn/api/music/Song_V1?url=${Uri.encodeComponent(id)}&level=${songLevel(q)}&type=json',
              headers: {'User-Agent': _musicUa},
            );
            if (j == null) return '';
            final data = j['data'] as Map<String, dynamic>?;
            return toHttps(
              j['url']?.toString() ?? data?['url']?.toString() ?? '',
            );
          },
        ),
        _Resolver(
          key: 'oiapi_kw',
          name: 'oiapi-酷我',
          platforms: const [MusicPlatform.kw],
          enabled: true,
          order: 100,
          fn: (id, pf, q, title) async {
            if (title.isEmpty) return '';
            final j = await _fetchJson(
              'https://oiapi.net/api/Kuwo?msg=${Uri.encodeComponent(title)}&n=1&br=${kwBr(q)}',
              headers: {'User-Agent': _musicUa},
            );
            final data = j?['data'] as Map<String, dynamic>?;
            return toHttps(data?['url']?.toString() ?? '');
          },
        ),
        _Resolver(
          key: 'hyw',
          name: 'HYWmusic',
          platforms: const [MusicPlatform.wy],
          // Default OFF (direct-IP host, shared key) — same as the JS.
          enabled: false,
          order: 110,
          fn: (id, pf, q, title) async {
            final j = await _fetchJson(
              'https://103.79.184.97/api/music/url?platform=wy&source=wy&songId=${Uri.encodeComponent(id)}&quality=320k',
              headers: {
                'User-Agent': _musicUa,
                'X-Card-Key': '6C1F-53W0-GRKI-EVFG',
              },
            );
            return (j != null && j['code'] == 200)
                ? toHttps(j['url']?.toString() ?? '')
                : '';
          },
        ),
        _Resolver(
          key: 'wwwweb',
          name: 'wwwweb',
          platforms: const [MusicPlatform.wy, MusicPlatform.kw],
          enabled: true,
          order: 120,
          fn: (id, pf, q, title) async {
            final j = await _fetchJson(
              'https://c.wwwweb.top/music/url',
              method: 'POST',
              headers: {
                'User-Agent': 'lx-music-desktop/2.10.1',
                'Content-Type': 'application/json',
                'X-Api-Key': '',
              },
              body: jsonEncode({
                'source': pf.code,
                'musicId': id,
                'quality': wwwwebQuality(q, pf.code),
              }),
            );
            return (j != null && j['code'] == 200)
                ? toHttps(j['url']?.toString() ?? '')
                : '';
          },
        ),
        _Resolver(
          key: 'zddyr_kw',
          name: '星海酷我',
          platforms: const [MusicPlatform.kw],
          enabled: true,
          order: 130,
          fn: (id, pf, q, title) async {
            if (title.isEmpty) return '';
            // Refuses master/hires/lossless outright (returns empty → downgrade).
            if (q == AudioQuality.master ||
                q == AudioQuality.hires ||
                q == AudioQuality.lossless) {
              return '';
            }
            final j = await _fetchJson(
              'https://yy.zddyr.top/lx/api/?source=kw&name=${Uri.encodeComponent(title)}&singer=&songmid=${Uri.encodeComponent(id)}&interval=&albumName=&quality=${q.code}',
              headers: {'User-Agent': _musicUa},
            );
            return (j != null && j['code'] == 200)
                ? toHttps(j['url']?.toString() ?? '')
                : '';
          },
        ),
      ];

  List<_Resolver> _applicable(MusicPlatform pf) {
    final list = _resolvers
        .where((r) => r.enabled && r.platforms.contains(pf))
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  // -- collection + main entry ----------------------------------------------

  // -- fastest-first sequential resolution + main entry --------------------

  /// One pass at a single quality: try jobs in measured-speed order,
  /// one at a time, until a playable URL is found (换源 — chen
  /// 2026-11-17: 每次解析都用最快的, 没有想要的资源就换源继续找,
  /// 直到找到能播的为止; 歌一刀/LX 模型: 一次只问一个源, 不搞
  /// 十几个并行扇出). The first URL at-or-above the requested tier
  /// wins at once; a below-tier URL is kept as fallback while a few
  /// more jobs are tried for a tier-matching one (and a short hunt
  /// window), then the fallback is returned. Returns null when no job
  /// yields any URL within [budget]. Jobs that time out are added to
  /// [skipTimedOut] so later tiers in the same resolve don't waste
  /// their budget re-asking a source that doesn't answer; a
  /// definitive empty answer is retried at lower tiers, which may
  /// serve the song (e.g. zddyr has hires but no master).
  static const _perJobTimeout = Duration(seconds: 3);

  Future<PlayUrlResult?> _resolvePass(
    AudioQuality q,
    String songId,
    MusicPlatform pf,
    String title,
    Duration budget,
    Set<String> skipTimedOut,
  ) async {
    // LX script jobs (M-P0-6): kick off engine load on first use; jobs
    // appear once the engine has loaded, so the first resolve after
    // launch may predate them — later resolves include them.
    unawaited(_scriptEngine.ensureInitialized().catchError((_) {}));
    final jobs = _rankedJobs(pf, q, songId, title);
    if (jobs.isEmpty) return null;
    // Master is explicitly wanted: hunt longer for a real master URL.
    final huntCap = q == AudioQuality.master ? 5 : 2;
    final huntWindow = q == AudioQuality.master
        ? const Duration(milliseconds: 2500)
        : const Duration(seconds: 1);
    final deadline = DateTime.now().add(budget);
    PlayUrlResult? best;
    var extraTries = 0;
    var haveUrl = false;
    DateTime? huntDeadline;
    for (final job in jobs) {
      if (skipTimedOut.contains(job.key)) continue;
      var remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      if (haveUrl) {
        if (extraTries >= huntCap) break;
        final huntLeft = huntDeadline!.difference(DateTime.now());
        if (huntLeft <= Duration.zero) break;
        if (huntLeft < remaining) remaining = huntLeft;
      }
      final timeout =
          remaining < _perJobTimeout ? remaining : _perJobTimeout;
      final sw = Stopwatch()..start();
      String url;
      try {
        url = await job.fn(songId, pf, q, title).timeout(timeout);
      } on TimeoutException {
        _recordAttempt(job.key, false, timeout.inMilliseconds);
        skipTimedOut.add(job.key);
        continue;
      } catch (_) {
        url = '';
      }
      sw.stop();
      if (url.isEmpty) {
        _recordAttempt(job.key, false, sw.elapsedMilliseconds);
        continue;
      }
      final https = toHttps(url);
      // A URL NSURL rejects kills the process the moment it reaches
      // AVURLAsset (v1.0.7 crash): treat it as a failed source and
      // try the next one, like any other unusable result.
      if (https.isEmpty || !isPlayableUrl(https)) {
        _recordAttempt(job.key, false, sw.elapsedMilliseconds);
        continue;
      }
      _recordAttempt(job.key, true, sw.elapsedMilliseconds);
      final realQ = extraQuality(job.key, q, pf.code);
      final cand = PlayUrlResult(
        url: https,
        candidates: [https],
        quality: realQ,
        via: job.name,
      );
      // Tier-matching wins immediately. Master honesty gate: only a
      // real master URL satisfies master.
      final matched = q == AudioQuality.master
          ? realQ == AudioQuality.master
          : realQ.rank >= q.rank;
      if (matched) return cand;
      if (best == null || realQ.rank > best.quality.rank) best = cand;
      if (haveUrl) extraTries++;
      haveUrl = true;
      huntDeadline ??= DateTime.now().add(huntWindow);
    }
    return best;
  }

  /// Main entry. Returns null when no resolver yields a URL at any
  /// tier. The caller always passes the user's chosen tier for every
  /// new song (downgrade never persists — rule "fi").
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title,
  ) async {
    if (songId.isEmpty) return null;
    final cacheKey = '$songId|${platform.code}|${quality.code}';
    final cached = _cache.get(cacheKey);
    if (cached != null) return cached;
    // Warm the xinghai token in parallel: its first fetch can take
    // seconds, and the sequential pass must not stall on it.
    if (_applicable(platform).any((r) => r.key == 'xinghai')) {
      unawaited(_getXhToken().catchError((_) => ''));
    }
    // Walk the quality chain, fastest-first per tier. A whole resolve
    // is bounded by one global deadline — the old tier loop re-fired
    // every resolver at every tier (worst case ~15 s).
    final skipTimedOut = <String>{};
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    PlayUrlResult? best;
    var first = true;
    for (final tier in qualityChainFrom(quality)) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      final cap =
          first ? const Duration(seconds: 6) : const Duration(seconds: 2);
      final budget = remaining < cap ? remaining : cap;
      final r = await _resolvePass(
        tier,
        songId,
        platform,
        title,
        budget,
        skipTimedOut,
      );
      first = false;
      if (r == null) continue;
      final matched = tier == AudioQuality.master
          ? r.quality == AudioQuality.master
          : r.quality.rank >= tier.rank;
      if (matched) {
        _saveSpeeds();
        _cache.put(cacheKey, r);
        return r;
      }
      // Below-tier fallback: keep the best. At a non-master tier this
      // is the answer (lower tiers can only be worse). At master, a
      // later tier may still beat it (e.g. hires from zddyr beats a
      // 320k answer), so keep walking the chain.
      if (best == null || r.quality.rank > best.quality.rank) best = r;
      if (tier != AudioQuality.master) break;
    }
    _saveSpeeds();
    if (best != null) _cache.put(cacheKey, best);
    return best;
  }

  /// Resolver inventory (for settings / debugging). Script resolvers
  /// (M-P0-6) are appended once the engine has loaded them.
  List<({String key, String name, List<MusicPlatform> platforms, bool enabled, int order})>
      listResolvers() {
    final out = _resolvers
        .map(
          (r) => (
            key: r.key,
            name: r.name,
            platforms: List.of(r.platforms),
            enabled: r.enabled,
            order: r.order,
          ),
        )
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    for (final info in _scriptEngine.scripts) {
      if (!info.loaded) continue;
      final pfs = <MusicPlatform>[];
      for (final s in info.sources) {
        if (const ['wy', 'tx', 'kg', 'kw', 'mg'].contains(s.platform)) {
          pfs.add(MusicPlatformX.fromCode(s.platform));
        }
      }
      out.add(
        (
          key: 'lx:${info.id}',
          name: info.name,
          platforms: pfs,
          enabled: LxScriptSourcesStore.isEnabled(info.id),
          order: 2,
        ),
      );
    }
    return out;
  }
}
