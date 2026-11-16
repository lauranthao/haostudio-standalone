// Play-URL resolvers — Dart port of resolvers.js (14 resolvers).
//
// resolvePlayUrl(songId, platform, quality, title) ->
// {url, candidates, quality, via} | null.
// Downgrade is sequential from the requested tier (hires → lossless →
// 320k → 128k); first tier with any candidate wins. Per-tier collection
// (collectAt): all applicable resolvers run in parallel (each capped at
// 5 s); non-hi tiers finish 350 ms after the first URL; hi tiers wait
// until a lossless/hires candidate arrives, else up to 2.5 s; hard cap
// 5 s. Candidates: max 3, deduped by URL, sorted by rank desc.
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

class _Candidate {
  _Candidate({required this.url, required this.via, required this.quality});
  final String url;
  final String via;
  final AudioQuality quality;
}

typedef _ResolverFn = Future<String> Function(
  String songId,
  MusicPlatform platform,
  AudioQuality quality,
  String title,
);

/// One collection job: a built-in resolver or an LX script job, unified
/// so [_collectAt] runs both in the same parallel batch.
typedef _Job = ({
  String key,
  String name,
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
class _PlayUrlCache {
  final _map = <String, (PlayUrlResult, DateTime)>{};

  PlayUrlResult? get(String key) {
    final hit = _map[key];
    if (hit == null) return null;
    if (DateTime.now().difference(hit.$2) > const Duration(minutes: 5)) {
      _map.remove(key);
      return null;
    }
    return hit.$1;
  }

  void put(String key, PlayUrlResult value) {
    if (_map.length >= 200) {
      _map.remove(_map.keys.first);
    }
    _map[key] = (value, DateTime.now());
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
          enabled: true,
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

  Future<List<_Candidate>> _collectAt(
    AudioQuality q,
    String songId,
    MusicPlatform pf,
    String title,
  ) async {
    final builtin = _applicable(pf);
    // LX script jobs (M-P0-6): kick off engine load on first use; jobs
    // appear once the engine has loaded, so the first resolve after
    // launch may predate them — later resolves include them.
    unawaited(_scriptEngine.ensureInitialized().catchError((_) {}));
    final song = Song(songId: songId, title: title, platform: pf);
    final scriptJobs = _scriptEngine.scriptJobsFor(pf, q, song);
    final jobs = <_Job>[
      for (final r in builtin) (key: r.key, name: r.name, fn: r.fn),
      for (final s in scriptJobs)
        (key: s.key, name: s.name, fn: (_, _, _, _) => s.fn()),
    ];
    if (jobs.isEmpty) return [];
    final isHi = q == AudioQuality.master ||
        q == AudioQuality.hires ||
        q == AudioQuality.lossless;
    final results = List<String?>.filled(jobs.length, null);
    var done = 0;
    var finished = false;
    final completer = Completer<List<_Candidate>>();
    void finish() {
      if (finished) return;
      finished = true;
      final cands = <_Candidate>[];
      for (var i = 0; i < jobs.length; i++) {
        final u = results[i];
        if (u == null || u.isEmpty || cands.length >= 3) continue;
        final https = toHttps(u);
        if (https.isEmpty) continue;
        if (cands.any((c) => c.url == https)) continue;
        cands.add(
          _Candidate(
            url: https,
            via: jobs[i].name,
            quality: extraQuality(jobs[i].key, q, pf.code),
          ),
        );
      }
      cands.sort((a, b) => b.quality.rank.compareTo(a.quality.rank));
      completer.complete(cands);
    }

    final hiCap = isHi
        ? const Duration(milliseconds: 2500)
        : const Duration(seconds: 5);
    Timer(hiCap, finish);
    for (var i = 0; i < jobs.length; i++) {
      unawaited(
        jobs[i]
            .fn(songId, pf, q, title)
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => '',
            )
            .then((u) {
          results[i] = u;
          if (u.isNotEmpty) {
            final ql = extraQuality(jobs[i].key, q, pf.code);
            // Hi tiers finish early only on a candidate AT the tier
            // (master: only a real master candidate counts — a
            // hires-level answer must not cut the master wait short).
            final early = isHi
                ? (q == AudioQuality.master
                    ? ql == AudioQuality.master
                    : (ql == AudioQuality.lossless ||
                        ql == AudioQuality.hires))
                : results.where((r) => r != null && r.isNotEmpty).length == 1;
            if (early) {
              Timer(const Duration(milliseconds: 350), finish);
            }
          }
        }).catchError((_) {
          results[i] = '';
        }).whenComplete(() {
          done++;
          if (done == jobs.length) finish();
        }),
      );
    }
    return completer.future;
  }

  /// Main entry. Returns null when no resolver yields a URL at any tier.
  /// The caller always passes the user's chosen tier for every new song
  /// (downgrade never persists — rule "fi").
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
    for (final tier in qualityChainFrom(quality)) {
      var cands = await _collectAt(tier, songId, platform, title);
      if (tier == AudioQuality.master) {
        // Master honesty gate: only a genuine master candidate may
        // satisfy the master tier. Anything lesser is dropped and the
        // loop downgrades to hires instead of mislabelling it Master.
        cands =
            cands.where((c) => c.quality == AudioQuality.master).toList();
      }
      if (cands.isNotEmpty) {
        final result = PlayUrlResult(
          url: cands.first.url,
          candidates: cands.map((c) => c.url).toList(),
          quality: cands.first.quality,
          via: cands.first.via,
        );
        _cache.put(cacheKey, result);
        return result;
      }
    }
    return null;
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
