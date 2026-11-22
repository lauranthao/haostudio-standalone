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
// - Each pass tries jobs one by one (per-job timeout 2 s, pass budget
//   6 s). The FIRST playable URL wins at once and the pass stops —
//   no hunting for a higher tier after a playable URL exists (chen
//   2026-11-17 铁律: 第一个源搜到了可以播放直接放, 要是没有就下一个
//   源, 不要把全部源问一遍; 歌一刀就是这个逻辑). A below-target URL
//   plays now as a per-song downgrade — the preference is untouched
//   and the next song still aims for the highest quality. The URL is
//   labelled with its REAL tier, never mislabelled (master honesty
//   gate: only a real master URL is master).
// - A job that fails 3 times in a row is cooled down for 5 min
//   (sorted last, still tried if nothing else works). A job that
//   TIMES OUT is cooled immediately for 2 min: a source that did not
//   answer just burned a whole per-job timeout, and retrying it
//   first on the next song would burn another one. Speeds persist
//   in Hive so the ranking survives restarts.
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

/// What one resolver call actually produced: the URL ('' = no result)
/// and, when the resolver KNOWS the tier it served (its upstream
/// reports it — zddyr/xinghai's `quality` / `quality_fallback`), that
/// tier. The loop labels the result with it instead of the declared
/// [extraQuality]; null = unknown, keep the declared label.
/// (P1-L1 Master gate: only a verified master answer may be labelled
/// master.)
typedef _ResolvedUrl = ({String url, AudioQuality? actualQuality});

/// A resolver that only knows its URL returns [_u] (unknown tier).
_ResolvedUrl _u(String url) => (url: url, actualQuality: null);

typedef _ResolverFn = Future<_ResolvedUrl> Function(
  String songId,
  MusicPlatform platform,
  AudioQuality quality,
  String title,
  // Expected artist for title-only resolvers (oiapi_kw, P1-L5):
  // '' = unknown, no singer check.
  String artist, {
  // Per-job cancellation (M-P1-1): the pass cancels this token when
  // the job times out, so the underlying Dio request aborts instead
  // of running on in the background.
  CancelToken? cancelToken,
});

/// One resolution job: a built-in resolver or an LX script job, unified
/// so [_resolvePass] runs them in measured-speed order. `order` is the
/// declared order, used as the tie-break for never-measured jobs.
/// `warmup`, when set, is awaited BEFORE the per-job timeout starts
/// (M-P0-2 b): a prerequisite that is not the job itself (xinghai's
/// token fetch) must not burn the job's 2 s timeout.
typedef _Job = ({
  String key,
  String name,
  int order,
  _ResolverFn fn,
  Future<void> Function()? warmup,
});

class _Resolver {
  _Resolver({
    required this.key,
    required this.name,
    required this.platforms,
    required this.enabled,
    required this.order,
    required this.fn,
    this.warmup,
  });

  final String key;
  final String name;
  final List<MusicPlatform> platforms;
  final bool enabled;
  final int order;
  final _ResolverFn fn;

  /// Prerequisite awaited before this resolver's per-job timeout
  /// starts (M-P0-2 b). Null for resolvers with no prerequisite.
  final Future<void> Function()? warmup;
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

  /// A key with an empty songId segment ('|platform|quality') is
  /// shared by every id-less song: never read, write, or evict it —
  /// two different songs would otherwise share one cached URL (the
  /// same collision Song.identityKey avoids with its
  /// title|artist|album fallback). The resolver entry already
  /// returns null for an empty songId, so this is the backstop: the
  /// cache itself can never serve song A's URL to song B, whatever
  /// a future caller passes in.
  static bool _isEmptyIdKey(String key) => key.startsWith('|');

  PlayUrlResult? get(String key) {
    if (_isEmptyIdKey(key)) return null;
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
    if (_isEmptyIdKey(key)) return;
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

  /// Drop one cached URL (e.g. a trial/preview clip was detected at
  /// playback): the next resolve for this song re-asks the sources
  /// instead of replaying the cached bad URL.
  void evict(String key) {
    if (_isEmptyIdKey(key)) return;
    _map.remove(key);
    try {
      unawaited(HiveStore.delete('$_prefix$key').catchError((_) {}));
    } catch (_) {}
  }
}

/// What one job attempt actually was (M-P1-8): an empty answer is
/// NOT a failure, an error is, a timeout cools at once.
enum _AttemptOutcome {
  /// A playable URL came back: EMA update, streak reset, cool cleared.
  success,

  /// The source answered fast with no stock at this tier — a
  /// deliberate refusal (e.g. zddyr_kw above 320k) or an instant
  /// API "no". Costs no time, so it is not a failure: no streak,
  /// no cooldown, no EMA change.
  empty,

  /// The job threw, or returned a URL that is not playable.
  error,

  /// The job burned its whole per-job timeout.
  timeout,
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
  // M-P2-3: throttled mid-resolve persistence — _saveSpeeds runs at
  // most every 10 attempts / 5 s during a resolve, so a process
  // killed mid-resolve keeps what was learned so far instead of
  // losing the whole resolve's EMA updates.
  int _attemptsSinceSave = 0;
  // Starts at construction: the 5 s rule only fires after 5 s of
  // resolving without a save (an epoch start would fire it on the
  // very first attempt of the first resolve).
  DateTime _lastSaveAt = DateTime.now();

  static const _speedHiveKey = 'hao_resolver_speed';
  static const _unknownSpeedMs = 500;
  // LX script jobs with no saved manual position sort after every
  // listed one (newly added scripts go last among scripts).
  static const _unlistedScriptIndex = 1 << 30;
  static const _coolAfterFails = 3;
  static const _coolFor = Duration(minutes: 5);
  // A single timeout cools the job right away (see _recordAttempt).
  static const _coolTimeoutFor = Duration(minutes: 2);

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
    _lastSaveAt = DateTime.now();
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
  /// resets the failure streak; an error bumps the streak and cools
  /// the job down after [_coolAfterFails] in a row, so a dead
  /// "fastest" source stops blocking the race (换源). A TIMEOUT cools
  /// the job immediately for [_coolTimeoutFor]: the failure streak
  /// alone is too slow to learn — the speed average is never updated
  /// on failure, so a source that was fast once but hangs now would
  /// otherwise stay ranked first and burn a full per-job timeout on
  /// every song until it has failed 3 times. An EMPTY answer records
  /// nothing at all (M-P1-8): a source that is fast but has no stock
  /// at this tier must not be cooled out of the tiers it does serve.
  ///
  /// [background] (M-P1-5): prewarm / prefetch resolves must not
  /// pollute the ranking — a background failure is never recorded
  /// (no streak, no cooldown); only a background success updates
  /// the speed, because it proves the source alive.
  void _recordAttempt(
    String key,
    _AttemptOutcome outcome,
    int ms, {
    bool background = false,
  }) {
    switch (outcome) {
      case _AttemptOutcome.success:
        final prev = _speedAvg[key];
        _speedAvg[key] = prev == null ? ms : (prev * 7 + ms * 3) ~/ 10;
        _speedFails.remove(key);
        _speedCooledUntil.remove(key);
        _speedDirty = true;
      case _AttemptOutcome.empty:
        // A fast "no" is not a failure — nothing changes, in
        // foreground or background.
        return;
      case _AttemptOutcome.error:
        if (background) return;
        final fails = (_speedFails[key] ?? 0) + 1;
        _speedFails[key] = fails;
        if (fails >= _coolAfterFails) {
          _speedCooledUntil[key] = DateTime.now().add(_coolFor);
        }
        _speedDirty = true;
      case _AttemptOutcome.timeout:
        if (background) return;
        final fails = (_speedFails[key] ?? 0) + 1;
        _speedFails[key] = fails;
        _speedCooledUntil[key] = DateTime.now().add(_coolTimeoutFor);
        _speedDirty = true;
    }
    // M-P2-3: throttle mid-resolve persistence (every 10 attempts
    // or every 5 s). The end-of-resolve _saveSpeeds calls stay.
    _attemptsSinceSave++;
    final now = DateTime.now();
    if (_attemptsSinceSave >= 10 ||
        now.difference(_lastSaveAt) >= const Duration(seconds: 5)) {
      _attemptsSinceSave = 0;
      _saveSpeeds();
    }
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
  /// declared order — except between two LX script jobs, where the
  /// user's manual drag order (音源管理, chen 2026-11-18) wins over
  /// measured speed. Script vs built-in is still by speed.
  List<_Job> _rankedJobs(
    MusicPlatform pf,
    AudioQuality q,
    String songId,
    String title, {
    String artist = '',
  }) {
    _loadSpeeds();
    final song =
        Song(songId: songId, title: title, platform: pf, artist: artist);
    final jobs = <_Job>[
      for (final r in _applicable(pf))
        (
          key: r.key,
          name: r.name,
          order: r.order,
          fn: r.fn,
          warmup: r.warmup,
        ),
      for (final s in _scriptEngine.scriptJobsFor(pf, q, song))
        (
          key: s.key,
          name: s.name,
          order: 2,
          fn: (_, _, _, _, _, {CancelToken? cancelToken}) =>
              s.fn(cancelToken: cancelToken),
          warmup: null,
        ),
    ];
    final now = DateTime.now();
    // Manual script order, read fresh per resolve so a drag in
    // settings takes effect without restart. Script ids are stored
    // bare; job keys are `lx:<id>`.
    final manualOrder = LxScriptSourcesStore.scriptOrder();
    final manualIndex = <String, int>{
      for (var i = 0; i < manualOrder.length; i++) manualOrder[i]: i,
    };
    jobs.sort((a, b) {
      final aCool = _isCooled(a.key, now);
      final bCool = _isCooled(b.key, now);
      if (aCool != bCool) return aCool ? 1 : -1;
      if (a.key.startsWith('lx:') && b.key.startsWith('lx:')) {
        final ai = manualIndex[a.key.substring(3)] ?? _unlistedScriptIndex;
        final bi = manualIndex[b.key.substring(3)] ?? _unlistedScriptIndex;
        if (ai != bi) return ai.compareTo(bi);
      }
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
    CancelToken? cancelToken,
  }) async {
    try {
      final res = await _dio.request<dynamic>(
        url,
        data: body,
        cancelToken: cancelToken,
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

  Future<String?> _fetchText(
    String url, {
    Duration? timeout,
    CancelToken? cancelToken,
  }) async {
    try {
      final res = await _dio.get<String>(
        url,
        cancelToken: cancelToken,
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

  Future<String> _getXhToken({CancelToken? cancelToken}) async {
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
        cancelToken: cancelToken,
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

  /// Singer-name containment check (P1-L5): normalize case + whitespace,
  /// then either side must contain the other. An empty reported singer
  /// cannot verify — the API names its singer, so a missing name means
  /// the hit is unusable for a title-only lookup.
  static bool _singerMatches(String reported, String expected) {
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final r = norm(reported);
    final e = norm(expected);
    if (r.isEmpty || e.isEmpty) return false;
    return r.contains(e) || e.contains(r);
  }

  /// Master honesty gate (P1-L1): the LX APIs (zddyr / xinghai) report
  /// the tier they actually served — `quality` + `quality_fallback`.
  /// Only `quality == 'master'` with no fallback keeps the master
  /// label at a master request; anything else the API served is hires
  /// (its best fallback tier). Other tiers carry no verifiable signal
  /// in the response, so they keep the declared label (null).
  static AudioQuality? _lxApiServedTier(
    Map<String, dynamic> j,
    AudioQuality q,
  ) {
    if (q != AudioQuality.master) return null;
    final servedMaster =
        j['quality'] == 'master' && j['quality_fallback'] != true;
    return servedMaster ? AudioQuality.master : AudioQuality.hires;
  }

  // -- the 10 resolvers (order = try order) ----------------------------------

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
          fn: (id, pf, q, title, artist, {CancelToken? cancelToken}) async =>
              _u(await _huibqUrl(id, pf, q)),
        ),
        _Resolver(
          key: 'tang',
          name: 'tang',
          platforms: const [MusicPlatform.tx],
          enabled: true,
          order: 15,
          fn: (id, pf, q, title, artist, {CancelToken? cancelToken}) async {
            final j = await _fetchJson(
              'https://tang.api.s01s.cn/music_open_api.php?mid=${Uri.encodeComponent(id)}',
              cancelToken: cancelToken,
              headers: {'User-Agent': _musicUa},
            );
            if (j == null || j['song_play_url'] == null) return _u('');
            // QQ top tier field is `song_play_url_pq` — it is the hires
            // tier's URL source, not a separate Master tier (see
            // music_quality.dart header). Master caps at the same
            // top field: falling through to `song_play_url_standard`
            // would serve the LOWEST tier while extraQuality labels
            // it hires.
            final field = q == AudioQuality.master || q == AudioQuality.hires
                ? 'song_play_url_pq'
                : q == AudioQuality.lossless
                    ? 'song_play_url_sq'
                    : q == AudioQuality.q320k
                        ? 'song_play_url_hq'
                        : 'song_play_url_standard';
            return _u(
              toHttps(
                j[field]?.toString() ?? j['song_play_url']?.toString() ?? '',
              ),
            );
          },
        ),
        _Resolver(
          key: 'lzm',
          name: 'lzm',
          platforms: const [MusicPlatform.wy],
          enabled: true,
          order: 20,
          fn: (id, pf, q, title, artist, {CancelToken? cancelToken}) async {
            final j = await _fetchJson(
              'https://music.lzmhhh.com/api/music/url',
              cancelToken: cancelToken,
              method: 'POST',
              headers: {
                'User-Agent': _musicUa,
                'Content-Type': 'application/x-www-form-urlencoded',
                'Referer': 'https://music.lzmhhh.com/',
              },
              body: 'id=${Uri.encodeComponent(id)}&type=wy',
            );
            return _u(toHttps(j?['data']?.toString() ?? ''));
          },
        ),
        _Resolver(
          key: 'zddyr',
          name: 'zddyr',
          platforms: const [MusicPlatform.wy],
          enabled: true,
          order: 25,
          fn: (id, pf, q, title, artist, {CancelToken? cancelToken}) async {
            final j = await _fetchJson(
              'https://yy.zddyr.top/lx/api/?source=wy&songmid=${Uri.encodeComponent(id)}&quality=${lxQuality(q)}',
              cancelToken: cancelToken,
              headers: {'User-Agent': _musicUa},
            );
            if (j == null || j['code'] != 200) return _u('');
            // P1-L1: verify the tier the API actually served — a
            // master request answered with a fallback stream is
            // hires, never master.
            return (
              url: toHttps(j['url']?.toString() ?? ''),
              actualQuality: _lxApiServedTier(j, q),
            );
          },
        ),
        _Resolver(
          key: 'gd',
          name: 'GD Studio',
          platforms: const [MusicPlatform.wy],
          enabled: true,
          order: 30,
          fn: (id, pf, q, title, artist, {CancelToken? cancelToken}) async {
            final j = await _fetchJson(
              'https://music-api.gdstudio.xyz/api.php?types=url&id=${Uri.encodeComponent(id)}&source=netease&br=${gdBr(q)}',
              cancelToken: cancelToken,
              headers: {'User-Agent': _musicUa},
            );
            return _u(toHttps(j?['url']?.toString() ?? ''));
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
          // M-P0-2 (b): the token fetch waits OUTSIDE the 2 s job
          // timeout (see [_resolvePass]) — on a cold start the token
          // can take seconds, and counting that against the job
          // cooled xinghai for 2 min before it was ever really tried.
          // The token is shared across resolves, so this only ever
          // waits on the first song after launch / token expiry.
          warmup: () async {
            await _getXhToken();
          },
          fn: (id, pf, q, title, artist, {CancelToken? cancelToken}) async {
            final tk = await _getXhToken(cancelToken: cancelToken);
            if (tk.isEmpty) return _u('');
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
              cancelToken: cancelToken,
              headers: {
                'User-Agent': 'lx-music',
                'X-Client': 'XingHaiMusicSource/v3.2.19 (Linux)',
                'X-Token': tk,
              },
            );
            if (j == null || j['code'] != 200) return _u('');
            // P1-L1: same served-tier verification as zddyr.
            return (
              url: toHttps(j['url']?.toString() ?? ''),
              actualQuality: _lxApiServedTier(j, q),
            );
          },
        ),
        _Resolver(
          key: 'oiapi_wy',
          name: 'oiapi-网易',
          platforms: const [MusicPlatform.wy],
          enabled: true,
          order: 60,
          fn: (id, pf, q, title, artist, {CancelToken? cancelToken}) async {
            final j = await _fetchJson(
              'https://oiapi.net/api/Music_163?id=${Uri.encodeComponent(id)}',
              cancelToken: cancelToken,
              headers: {'User-Agent': _musicUa},
            );
            if (j == null || j['code'] != 0) return _u('');
            // 2026-11-23: the live API returns data as a Map
            // {items: [{url, ...}]}; the old shape was a bare List.
            // A blind `as List` cast throws on the Map shape, so the
            // job errored on every call and never served a URL.
            // Accept both shapes.
            final raw = j['data'];
            Map<String, dynamic>? first;
            if (raw is List && raw.isNotEmpty) {
              first = raw.first as Map<String, dynamic>?;
            } else if (raw is Map<String, dynamic>) {
              final items = raw['items'] as List<dynamic>?;
              if (items != null && items.isNotEmpty) {
                first = items.first as Map<String, dynamic>?;
              }
            }
            return _u(toHttps(first?['url']?.toString() ?? ''));
          },
        ),
        _Resolver(
          key: 'oiapi_kw',
          name: 'oiapi-酷我',
          platforms: const [MusicPlatform.kw],
          enabled: true,
          order: 100,
          fn: (id, pf, q, title, artist, {CancelToken? cancelToken}) async {
            if (title.isEmpty) return _u('');
            final j = await _fetchJson(
              'https://oiapi.net/api/Kuwo?msg=${Uri.encodeComponent(title)}&n=1&br=${kwBr(q)}',
              cancelToken: cancelToken,
              headers: {'User-Agent': _musicUa},
            );
            final data = j?['data'] as Map<String, dynamic>?;
            final url = toHttps(data?['url']?.toString() ?? '');
            if (url.isEmpty) return _u('');
            // P1-L5: the request is title-only, so the API's first
            // hit can be a different song with the same title. The
            // response names its singer — when the expected artist
            // is known, require a match; a mismatch is "no result
            // from this source", and the loop asks the next source.
            if (artist.isNotEmpty &&
                !_singerMatches(
                  data?['singer']?.toString() ?? '',
                  artist,
                )) {
              return _u('');
            }
            return _u(url);
          },
        ),
        _Resolver(
          key: 'wwwweb',
          name: 'wwwweb',
          platforms: const [MusicPlatform.wy, MusicPlatform.kw],
          enabled: true,
          order: 120,
          fn: (id, pf, q, title, artist, {CancelToken? cancelToken}) async {
            final j = await _fetchJson(
              'https://c.wwwweb.top/music/url',
              cancelToken: cancelToken,
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
            return _u(
              (j != null && j['code'] == 200)
                  ? toHttps(j['url']?.toString() ?? '')
                  : '',
            );
          },
        ),
        _Resolver(
          key: 'zddyr_kw',
          name: '星海酷我',
          platforms: const [MusicPlatform.kw],
          enabled: true,
          order: 130,
          fn: (id, pf, q, title, artist, {CancelToken? cancelToken}) async {
            if (title.isEmpty) return _u('');
            // Refuses master/hires/lossless outright (returns empty → downgrade).
            if (q == AudioQuality.master ||
                q == AudioQuality.hires ||
                q == AudioQuality.lossless) {
              return _u('');
            }
            final j = await _fetchJson(
              'https://yy.zddyr.top/lx/api/?source=kw&name=${Uri.encodeComponent(title)}&singer=&songmid=${Uri.encodeComponent(id)}&interval=&albumName=&quality=${q.code}',
              cancelToken: cancelToken,
              headers: {'User-Agent': _musicUa},
            );
            return _u(
              (j != null && j['code'] == 200)
                  ? toHttps(j['url']?.toString() ?? '')
                  : '',
            );
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

  /// True when the most recent [resolvePlayUrl] that returned null
  /// ran out of budget with jobs still untried, so "no source"
  /// would be a lie: some available source was never asked (the
  /// 8 s global / 6 s first-pass budget can die while jobs remain —
  /// e.g. three 2 s hangs eat the whole first pass). False when
  /// every available job was tried and answered empty, when a URL
  /// was found, or when the song had no id (nothing was attempted).
  /// Read immediately after a null result; the next resolve
  /// overwrites it. Cooled / disabled jobs do not count as untried:
  /// cooled jobs are only sorted last (still tried when reached),
  /// disabled ones are not applicable at all.
  bool lastResolveTruncated = false;

  /// One pass at a single quality: try jobs in measured-speed order,
  /// one at a time, until a playable URL is found (换源 — chen
  /// 2026-11-17: 每次解析都用最快的, 没有想要的资源就换源继续找,
  /// 直到找到能播的为止; 歌一刀/LX 模型: 一次只问一个源, 不搞
  /// 十几个并行扇出). The FIRST playable URL wins at once and the
  /// pass stops — NO hunting for a higher tier after a playable URL
  /// exists (chen 2026-11-17 铁律: 第一个源搜到了可以播放直接放,
  /// 要是没有就下一个源, 不要把全部源问一遍). A below-target URL
  /// plays now as a per-song downgrade (the preference is untouched;
  /// the next song still aims for the highest quality), labelled
  /// with its REAL tier, never mislabelled. Returns (null, false)
  /// when no job yields any URL within [budget] AND every available
  /// job was tried; (null, true) when the budget died with jobs
  /// still untried. Jobs that time out are added to
  /// [skipTimedOut] so later tiers in the same resolve don't waste
  /// their budget re-asking a source that doesn't answer; a
  /// definitive empty answer is retried at lower tiers, which may
  /// serve the song (e.g. zddyr has hires but no master).
  static const _perJobTimeout = Duration(seconds: 2);

  /// [excludeNames]: job NAMES ([PlayUrlResult.via] values) to skip
  /// entirely in this pass — the trial-clip retry (controller
  /// `_handleTrial`) excludes the job that served the trial URL so the
  /// next-fastest job gets its chance. Excluded jobs are NOT recorded
  /// as failures (no cooldown, no speed penalty): they were not tried.
  Future<({PlayUrlResult? result, bool incomplete})> _resolvePass(
    AudioQuality q,
    String songId,
    MusicPlatform pf,
    String title,
    Duration budget,
    Set<String> skipTimedOut, {
    Set<String> excludeNames = const <String>{},
    String artist = '',
    bool background = false,
  }) async {
    // LX script jobs (M-P0-6): kick off engine load on first use; jobs
    // appear once the engine has loaded, so the first resolve after
    // launch may predate them — later resolves include them.
    unawaited(_scriptEngine.ensureInitialized().catchError((_) {}));
    final jobs = _rankedJobs(pf, q, songId, title, artist: artist);
    if (jobs.isEmpty) return (result: null, incomplete: false);
    final deadline = DateTime.now().add(budget);
    // Jobs still untried from [i] on (skipped-by-timeout / excluded
    // jobs do not count: they were attempted, or deliberately not
    // asked).
    bool untriedFrom(int i) => jobs.skip(i).any(
          (j) =>
              !skipTimedOut.contains(j.key) &&
              !excludeNames.contains(j.name),
        );
    for (var i = 0; i < jobs.length; i++) {
      final job = jobs[i];
      if (excludeNames.contains(job.name)) continue;
      if (skipTimedOut.contains(job.key)) continue;
      // M-P0-2 (b): a job prerequisite (xinghai's token) waits
      // OUTSIDE the per-job timeout — the 2 s clock starts only
      // once the token is in hand. Bounded by the pass budget, so
      // a hung prerequisite cannot stall the pass past its budget.
      if (job.warmup != null) {
        final warmRemaining = deadline.difference(DateTime.now());
        if (warmRemaining <= Duration.zero) {
          return (result: null, incomplete: untriedFrom(i));
        }
        try {
          await job.warmup!().timeout(warmRemaining);
        } on TimeoutException {
          // Budget died waiting for the prerequisite: the source
          // itself was never asked — not a job timeout, so no
          // cooldown and no skipTimedOut. Loop on; the top check
          // reports the pass incomplete with jobs still untried.
          continue;
        } catch (_) {
          // Warmup itself failed (token endpoint down): the job's
          // own fn re-checks and answers empty fast; do not skip it.
        }
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        // Budget gone with this job (and any after it) still
        // untried: the caller must not report "no source" — some
        // available source was never asked. Skipped jobs (timed out
        // earlier in this resolve, or excluded by name) do not
        // count: they were attempted, or deliberately not asked.
        return (result: null, incomplete: untriedFrom(i));
      }
      final timeout =
          remaining < _perJobTimeout ? remaining : _perJobTimeout;
      final sw = Stopwatch()..start();
      _ResolvedUrl resolved;
      var threw = false;
      // M-P1-1: one token per job attempt. On timeout the token is
      // cancelled, so the underlying Dio request / script poll loop
      // aborts instead of running on in the background (a bare
      // Future.timeout only abandons the wait).
      final token = CancelToken();
      try {
        resolved = await job
            .fn(songId, pf, q, title, artist, cancelToken: token)
            .timeout(timeout);
      } on TimeoutException {
        token.cancel();
        _recordAttempt(
          job.key,
          _AttemptOutcome.timeout,
          timeout.inMilliseconds,
          background: background,
        );
        skipTimedOut.add(job.key);
        continue;
      } catch (_) {
        // The job itself failed — record it as an error below, not
        // as a deliberate "no stock" (M-P1-8).
        threw = true;
        resolved = _u('');
      }
      sw.stop();
      final url = resolved.url;
      if (url.isEmpty) {
        _recordAttempt(
          job.key,
          threw ? _AttemptOutcome.error : _AttemptOutcome.empty,
          sw.elapsedMilliseconds,
          background: background,
        );
        continue;
      }
      final https = toHttps(url);
      // A URL NSURL rejects kills the process the moment it reaches
      // AVURLAsset (v1.0.7 crash): treat it as a failed source and
      // try the next one, like any other unusable result.
      if (https.isEmpty || !isPlayableUrl(https)) {
        _recordAttempt(
          job.key,
          _AttemptOutcome.error,
          sw.elapsedMilliseconds,
          background: background,
        );
        continue;
      }
      _recordAttempt(
        job.key,
        _AttemptOutcome.success,
        sw.elapsedMilliseconds,
        background: background,
      );
      // First playable URL wins immediately. No hunting: even a
      // below-target URL plays now (per-song downgrade); the caller
      // still passes the user's chosen tier for the next song.
      return (
        result: PlayUrlResult(
          url: https,
          candidates: [https],
          // P1-L1: a resolver that reports the tier it actually
          // served is held to it; otherwise the declared label.
          quality:
              resolved.actualQuality ?? extraQuality(job.key, q, pf.code),
          via: job.name,
        ),
        incomplete: false,
      );
    }
    return (result: null, incomplete: false);
  }

  /// Main entry. Returns null when no resolver yields a URL at any
  /// tier. The caller always passes the user's chosen tier for every
  /// new song (downgrade never persists — rule "fi").
  /// [excludeJobs]: job NAMES ([PlayUrlResult.via] values) to skip in
  /// every tier pass — the trial-clip retry excludes the job that
  /// served the trial URL. When non-empty the URL cache is bypassed
  /// for the read (the previous answer is exactly what is being
  /// excluded), but the new result is still cached.
  /// [background] (M-P1-5): prewarm / prefetch calls — failures are
  /// not recorded (no streak, no cooldown); only successes update
  /// the speed ranking, so a background timeout can never demote a
  /// source the user is about to tap.
  /// [totalBudget] (M-P1-4): whole-resolve deadline. 8 s by default;
  /// the auto-advance failure path passes a tighter budget so a dead
  /// song fails over to the next track instead of silencing the app.
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
    // Expected artist for title-only resolvers (oiapi_kw, P1-L5).
    String artist = '',
    bool background = false,
    Duration totalBudget = const Duration(seconds: 8),
  }) async {
    if (songId.isEmpty) {
      lastResolveTruncated = false;
      return null;
    }
    final cacheKey = '$songId|${platform.code}|${quality.code}';
    final cached = excludeJobs.isEmpty ? _cache.get(cacheKey) : null;
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
    final deadline = DateTime.now().add(totalBudget);
    var first = true;
    // OR across tiers: if ANY tier ran out of budget with jobs
    // still untried, the resolve did not exhaust the sources — a
    // later tier re-asking the same jobs at a lower quality does not
    // make up for the untried jobs at the requested tier.
    var truncated = false;
    for (final tier in qualityChainFrom(quality)) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      final cap =
          first ? const Duration(seconds: 6) : const Duration(seconds: 2);
      final budget = remaining < cap ? remaining : cap;
      final pass = await _resolvePass(
        tier,
        songId,
        platform,
        title,
        budget,
        skipTimedOut,
        excludeNames: excludeJobs,
        artist: artist,
        background: background,
      );
      truncated = truncated || pass.incomplete;
      first = false;
      // First playable URL wins, at any tier (chen 2026-11-17 铁律):
      // a below-target URL plays now as a per-song downgrade — the
      // chain only advances when NO source returns anything at this
      // tier. No hunting across tiers for a better URL (the old
      // "keep the best and walk on at master" is gone: a hires URL
      // from the master pass plays now, it does not wait for the
      // hires pass to maybe find a better one).
      final r = pass.result;
      if (r == null) continue;
      lastResolveTruncated = false;
      _saveSpeeds();
      _cache.put(cacheKey, r);
      return r;
    }
    lastResolveTruncated = truncated;
    _saveSpeeds();
    return null;
  }

  /// Drop a cached play URL (e.g. a trial/preview clip was detected at
  /// playback): the next resolve for this song re-asks the sources
  /// instead of replaying the cached bad URL.
  void evictPlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
  ) {
    _cache.evict('$songId|${platform.code}|${quality.code}');
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
