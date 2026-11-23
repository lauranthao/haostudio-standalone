// Emby client — direct (no server), Dart `sharedDio()` transport.
//
// Parallel to CmsClient, NOT a subclass of it: the protocol shape
// (baseUrl + /emby/ path family + header auth + userId path params),
// the category system (Views → Movie/Series → Season → Episode) and
// the failure surface (address / key / userId) are all different.
// Shared habits, kept on purpose: `sharedDio()` + injectable fetcher
// + 8 s per-request timeout + CancelToken cancel is never a failure.
//
// Auth (build 29): two modes, one credential on the wire.
// - Username + password (primary, connect page): POST
//   /Users/AuthenticateByName returns AccessToken + User.Id; the
//   token is stored, the password never is. See [authenticateByName].
// - API key (fallback, connect page 高级设置): the old X-Emby-Token.
// Whichever is present rides as `X-Emby-Token` on every API call
// ([_authHeaders]) and as `api_key` on the stream URL
// ([streamUrl]) — Emby accepts a user token in both places, same
// as an API key. The key enters a URL in exactly ONE place — the
// playback stream URL ([streamUrl]), because the native player
// kernels take a bare URL and no custom headers. That URL is never
// logged, never put in an exception message, never used as a cache
// key (images use the header form instead, see [imageHeaders]).
//
// API root prefix: the official Emby API lives under `/emby`
// (http://host:8096/emby/...), but some deployments answer at the
// root. [probe] tries `/emby` first, then the root, and remembers
// which worked; data calls use the remembered prefix (default
// `/emby` until a probe has run). The baseUrl itself is NEVER
// force-upgraded to https: a plain-http LAN address is a legal
// setup (Settings warns about it, it does not block it).
//
// v1 scope (D4, updated 1.1.6): no Douban merge, no transcode
// tiers, no cross-namespace source switching, no merged search.
// Search covers Emby only. Server-side progress reporting,
// played-marking, favorites and rating (see [reportPlaybackStart]
// and friends) landed in 1.1.6 against the official Emby API
// endpoints — endpoint names/shapes verified against the Emby
// Server API listing, but the exact request binding (query params
// vs JSON body) is still 待真服验证: no real server was available,
// and every mutating call is best-effort (false on any failure,
// never thrown into playback).

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/network/http_client.dart';
import '../../core/player/vod_controls.dart';
import '../../features/video/video_models.dart';
import 'emby_models.dart';

/// Human failure text, one per tier. Three tiers, never the CMS
/// wording, never the raw URL or key.
class EmbyException implements Exception {
  const EmbyException(this.kind, this.message);

  factory EmbyException.unreachable() => const EmbyException(
        EmbyErrorKind.unreachable,
        '连不上 Emby 服务器，检查地址和网络',
      );

  factory EmbyException.unauthorized() => const EmbyException(
        EmbyErrorKind.unauthorized,
        'Emby 密钥不对，请在设置里重新填写',
      );

  /// 401 on a password login: the account name or the password is
  /// wrong (never "the key" — there is no key in this mode).
  factory EmbyException.unauthorizedAccount() => const EmbyException(
        EmbyErrorKind.unauthorized,
        'Emby 用户名或密码不对，请重新登录',
      );

  factory EmbyException.notFound([String? message]) => EmbyException(
        EmbyErrorKind.notFound,
        message ?? '在 Emby 里没有找到这个内容',
      );

  factory EmbyException.other(String message) =>
      EmbyException(EmbyErrorKind.other, message);

  final EmbyErrorKind kind;
  final String message;

  @override
  String toString() => 'EmbyException: $message';
}

/// Raw HTTP result handed to the client by the fetcher. The client
/// owns status mapping, so tests can drive every tier with canned
/// statuses and no network.
class EmbyResponse {
  const EmbyResponse({required this.statusCode, this.json});

  final int statusCode;
  final dynamic json;
}

/// Fetch one Emby JSON document. Cancel rethrows the Dio cancel
/// error (cancellation is the caller's decision, never a failure).
/// Production uses [defaultEmbyFetcher] over [sharedDio].
typedef EmbyFetcher = Future<EmbyResponse> Function(
  String url, {
  Map<String, String>? headers,
  Duration timeout,
  CancelToken? cancelToken,
});

/// Production fetcher over the shared Dio instance. Never throws for
/// an HTTP status (sharedDio has validateStatus: true) — the status
/// rides in [EmbyResponse] for the client to map. Transport failures
/// (refused / DNS / timeout) become [EmbyException.unreachable];
/// the URL is never included in the message.
Future<EmbyResponse> defaultEmbyFetcher(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 8),
  CancelToken? cancelToken,
}) async {
  final dio = sharedDio();
  late Response<dynamic> res;
  try {
    res = await dio.get<dynamic>(
      url,
      cancelToken: cancelToken,
      options: Options(
        headers: <String, String>{
          'Accept': 'application/json',
          ...?headers,
        },
        receiveTimeout: timeout,
        sendTimeout: timeout,
      ),
    );
  } on DioException catch (e) {
    if (e.type == DioExceptionType.cancel) rethrow;
    // Timeout, refused, DNS, TLS: all "cannot reach the server".
    throw EmbyException.unreachable();
  }
  final data = res.data;
  dynamic json = data;
  if (data is String && data.isNotEmpty) {
    try {
      json = jsonDecode(data);
    } catch (_) {
      json = null;
    }
  }
  return EmbyResponse(statusCode: res.statusCode ?? 0, json: json);
}

/// Fields requested on item queries. MediaSources is deliberately
/// absent: the v1 stream URL is built directly (static=true), and
/// list payloads stay small without it.
/// Fields the client asks for on every item query. People +
/// RecursiveItemCount ride here too: the detail page shows 导演/主演
/// from People, and the series poster badge shows the episode total
/// from RecursiveItemCount — without asking, the server omits both
/// fields and the UI silently shows nothing (build 30 data fix).
const String _kItemFields =
    'Overview,Genres,ProductionYear,CommunityRating,RunTimeTicks,'
    'ChildCount,RecursiveItemCount,People,ImageTags,'
    'PrimaryImageAspectRatio,UserData';

/// Detail fields: item fields + MediaSources (container / codecs /
/// Dolby Vision — the facts the kernel's engine gate reads) +
/// Chapters (IntroStart/IntroEnd/CreditsStart skip markers, 1.1.6 —
/// the player reads them off the episode). Servers without the
/// IntroSkip plugin return an empty array or no field; the parser
/// treats that as "no markers".
const String _kDetailFields = '$_kItemFields,MediaSources,Chapters';

/// One page of library items.
class EmbyItemsPage {
  const EmbyItemsPage({required this.items, required this.totalCount});

  final List<VideoItem> items;
  final int totalCount;
}

/// One episode with its stream facts (container/codecs), so
/// [EmbyClient.detail] can tag the episode's stream URL for the
/// kernel's engine gate.
class EmbyEpisode {
  const EmbyEpisode({required this.item, this.facts, this.markers});

  final VideoItem item;

  /// Null when the episode carries no MediaSources (old server, or
  /// the field was dropped) — the stream URL is then unmarked and
  /// the kernel falls back to the unknown-format behaviour.
  final EmbyStreamFacts? facts;

  /// Skip-intro/outro markers parsed from the episode's `Chapters`.
  /// Null = the server returned no chapters — the player then falls
  /// back to the per-episode custom seconds.
  final SkipMarkers? markers;
}

/// One item's server-side user data (the `UserData` object Emby
/// returns on item queries when `UserData` is in `Fields`).
/// Parsed by [EmbyUserData.fromJson]; missing fields stay at their
/// "never watched" defaults, never throw.
class EmbyUserData {
  const EmbyUserData({
    this.playbackPositionSeconds = 0,
    this.playedPercentage = 0,
    this.played = false,
    this.isFavorite = false,
    this.likes,
  });

  /// Parse the raw `UserData` map of one item document. A null /
  /// non-map value is "no user data" (all defaults).
  factory EmbyUserData.fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) return const EmbyUserData();
    final ticks = (json['PlaybackPositionTicks'] as num?)?.toDouble() ?? 0;
    final pct = (json['PlayedPercentage'] as num?)?.toDouble();
    return EmbyUserData(
      playbackPositionSeconds:
          ticks > 0 ? ticks / EmbyClient.ticksPerSecond : 0,
      playedPercentage: pct != null ? (pct / 100).clamp(0.0, 1.0) : 0,
      played: json['Played'] as bool? ?? false,
      isFavorite: json['IsFavorite'] as bool? ?? false,
      likes: json['Likes'] as bool?,
    );
  }

  /// Resume position in seconds (PlaybackPositionTicks / 10^7).
  final double playbackPositionSeconds;

  /// 0..1 watched fraction (PlayedPercentage / 100; 0 when the
  /// server did not supply a percentage).
  final double playedPercentage;

  /// The server considers this item finished.
  final bool played;

  /// Server-side favorite flag.
  final bool isFavorite;

  /// true = liked, false = disliked, null = no rating on record.
  final bool? likes;
}

/// Mutating Emby request (POST/DELETE): method + full URL + auth
/// headers + optional JSON body. Returns the status + decoded JSON
/// without throwing for an HTTP status (like [EmbyFetcher]);
/// transport failures throw [EmbyException.unreachable]. Cancel
/// rethrows the Dio cancel error. Production uses
/// [defaultEmbyMutator] over [sharedDio]; tests inject a canned one.
/// The API key NEVER enters the URL here — auth rides the header
/// (the stream URL is the only key-in-URL place, and it is not
/// built by this path).
typedef EmbyMutator = Future<EmbyResponse> Function(
  String method,
  String url, {
  Map<String, String>? headers,
  Map<String, dynamic>? jsonBody,
  Duration timeout,
  CancelToken? cancelToken,
});

/// Production mutator over the shared Dio instance.
Future<EmbyResponse> defaultEmbyMutator(
  String method,
  String url, {
  Map<String, String>? headers,
  Map<String, dynamic>? jsonBody,
  Duration timeout = const Duration(seconds: 8),
  CancelToken? cancelToken,
}) async {
  final dio = sharedDio();
  late Response<dynamic> res;
  try {
    res = await dio.request<dynamic>(
      url,
      data: jsonBody,
      cancelToken: cancelToken,
      options: Options(
        method: method,
        headers: <String, String>{
          'Accept': 'application/json',
          if (jsonBody != null) 'Content-Type': 'application/json',
          ...?headers,
        },
        receiveTimeout: timeout,
        sendTimeout: timeout,
      ),
    );
  } on DioException catch (e) {
    if (e.type == DioExceptionType.cancel) rethrow;
    throw EmbyException.unreachable();
  }
  final data = res.data;
  dynamic json = data;
  if (data is String && data.isNotEmpty) {
    try {
      json = jsonDecode(data);
    } catch (_) {
      json = null;
    }
  }
  return EmbyResponse(statusCode: res.statusCode ?? 0, json: json);
}

class EmbyClient {
  EmbyClient({required this.config, EmbyFetcher? fetcher, EmbyMutator? mutator})
      : _fetcher = fetcher ?? defaultEmbyFetcher,
        _mutator = mutator ?? defaultEmbyMutator;

  /// The source id every Emby item/detail/history row carries.
  /// CMS source ids are ints, so 'emby' can never collide with one;
  /// `VideoItem.identityKey` (source|vodId) splits the namespaces.
  static const String sourceId = 'emby';

  /// .NET ticks per second: Emby positions are 100-ns ticks.
  static const int ticksPerSecond = 10000000;

  /// Seconds → ticks (for progress reports).
  static int ticksFromSeconds(double seconds) =>
      (seconds * ticksPerSecond).round();

  /// The episode/item id inside one of our own stream URLs
  /// (`.../Videos/<id>/stream?...`), or null when the URL is not
  /// one of ours. Lets the player report progress for the episode
  /// actually playing without carrying a separate id through the
  /// page. Never throws.
  static String? episodeIdFromStreamUrl(String url) {
    try {
      final path = Uri.parse(url).path;
      final m = RegExp(r'/Videos/([^/]+)/stream').firstMatch(path);
      final id = m?.group(1);
      if (id == null || id.isEmpty) return null;
      return Uri.decodeComponent(id);
    } catch (_) {
      return null;
    }
  }

  final EmbyServerConfig config;
  final EmbyFetcher _fetcher;
  final EmbyMutator _mutator;

  /// Set by [probe]/[ensureApiRoot]; default true = try `/emby`
  /// first (the official API root).
  bool _useEmbyPrefix = true;

  /// Temporary base-URL override, used only while one probe /
  /// login attempt tries a 备用线路. Always cleared in a finally
  /// (see [_probeBase] / [authenticateByName]) so data calls can
  /// never accidentally use a fallback address.
  String? _baseOverride;

  bool get isConfigured => config.isConfigured;

  String get _base {
    var base = (_baseOverride ?? config.baseUrl).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  /// Account token when logged in, else the API key (see
  /// [EmbyServerConfig.authToken]).
  Map<String, String> get _authHeaders =>
      <String, String>{'X-Emby-Token': config.authToken};

  /// Image auth headers for [RefererImage]: the image URL itself
  /// stays clean (no api_key), so it can be a cache key safely.
  Map<String, String> get imageHeaders => _authHeaders;

  String _apiUrl(String path) =>
      '$_base${_useEmbyPrefix ? '/emby' : ''}$path';

  // -- URL builders (pure, covered by tests) -------------------------

  /// Poster/detail image URL. No api_key in the URL — auth rides the
  /// header ([imageHeaders]). `tag` is omitted when the item has no
  /// Primary tag (the caller then usually leaves pic empty instead).
  String imageUrl(
    String itemId, {
    int? maxWidth,
    int? maxHeight,
    String? tag,
    String type = 'Primary',
  }) {
    final params = <String, String>{
      if (maxWidth != null) 'maxWidth': '$maxWidth',
      if (maxHeight != null) 'maxHeight': '$maxHeight',
      if (tag != null && tag.isNotEmpty) 'tag': tag,
    };
    final query = params.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final path = '/Items/$itemId/Images/$type';
    return query.isEmpty ? _apiUrl(path) : '${_apiUrl(path)}?$query';
  }

  /// Direct (no-transcode) stream URL. THE ONLY place the key enters
  /// a URL — the player kernels take a bare URL. Never log this
  /// value, never put it in an exception, never use it as a key.
  ///
  /// STRM 直连 ([EmbyServerConfig.strmDirect], default off): when
  /// on and the item's MediaSource path is a remote http(s) URL
  /// (a .strm target), that URL is returned directly — no server
  /// round-trip, no credential in the URL. A local server path
  /// ('/media/….strm') or strmDirect off always takes the server
  /// stream endpoint below, which works on nearly every server.
  ///
  /// [facts] (from the item's MediaSources) rides as `hao_*` query
  /// markers so the kernel can pick a capable engine before the
  /// first open (an MKV/TrueHD/Dolby-Vision file must never be
  /// offered to AVPlayer first). Emby ignores unknown query params;
  /// no markers when facts are absent, and the URL is then exactly
  /// the unmarked form.
  String streamUrl(String itemId, {EmbyStreamFacts? facts}) {
    final strmPath = facts?.sourcePath;
    if (config.strmDirect &&
        strmPath != null &&
        (strmPath.startsWith('http://') ||
            strmPath.startsWith('https://'))) {
      return strmPath;
    }
    final base =
        '${_apiUrl('/Videos/$itemId/stream')}?static=true&api_key=${Uri.encodeComponent(config.authToken)}';
    final markers = facts?.toQueryParams() ?? const {};
    if (markers.isEmpty) return base;
    final qs = markers.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return '$base&$qs';
  }

  // -- Low-level GET ---------------------------------------------------

  Future<Map<String, dynamic>> _getJson(
    String url, {
    Duration timeout = const Duration(seconds: 8),
    CancelToken? cancelToken,
  }) async {
    final doc = await _getDocument(
      url,
      timeout: timeout,
      cancelToken: cancelToken,
    );
    if (doc is Map<String, dynamic>) return doc;
    throw EmbyException.other('Emby 返回了无法识别的数据');
  }

  /// Raw GET: returns the decoded JSON document (map or list) after
  /// the same status mapping as [_getJson].
  Future<dynamic> _getDocument(
    String url, {
    Duration timeout = const Duration(seconds: 8),
    CancelToken? cancelToken,
  }) async {
    final res = await _fetcher(
      url,
      headers: _authHeaders,
      timeout: timeout,
      cancelToken: cancelToken,
    );
    final status = res.statusCode;
    if (status == 401) {
      // Password login vs API key: different wording, same tier.
      throw config.usesPasswordAuth
          ? EmbyException.unauthorizedAccount()
          : EmbyException.unauthorized();
    }
    if (status == 404) throw EmbyException.notFound();
    if (status < 200 || status >= 300) {
      throw EmbyException.other('Emby 服务器返回了错误（$status）');
    }
    return res.json;
  }

  // -- Probe -----------------------------------------------------------

  /// GET /System/Info with the credential. Tries `/emby` first,
  /// then the root, and remembers the working prefix. 200 +
  /// ServerName / Version = "server reachable, credential correct".
  /// 401 = credential wrong (same on both prefixes — no point
  /// trying the second). Anything else on both prefixes =
  /// unreachable / wrong address.
  ///
  /// On success also fetches GET /Users — unless [config.userId]
  /// is already known (password login filled it in), in which
  /// case the fetch is skipped: a non-admin user token cannot
  /// read /Users, and a failed fetch must not fail a probe whose
  /// credential System/Info already accepted. A failed fetch in
  /// key mode is likewise tolerated (same reason: the credential
  /// is already proven) and yields an empty user list.
  Future<EmbyProbeResult> probe({CancelToken? cancelToken}) async {
    final bases = <String>[
      config.baseUrl,
      ...config.fallbackUrls.where((u) => u.trim().isNotEmpty),
    ];
    EmbyProbeResult? lastFailure;
    for (final base in bases) {
      final result = await _probeBase(base, cancelToken: cancelToken);
      if (result.ok) return result;
      lastFailure = result;
      // 401 is base-independent: the credential itself is wrong.
      if (result.errorKind == EmbyErrorKind.unauthorized) return result;
    }
    final failure = lastFailure ?? EmbyProbeResult(
      ok: false,
      errorKind: EmbyErrorKind.unreachable,
      errorMessage: EmbyException.unreachable().message,
    );
    return failure;
  }

  /// Probe ONE base URL (both prefixes). The override is always
  /// cleared afterwards, so a later data call uses [config.baseUrl].
  Future<EmbyProbeResult> _probeBase(
    String base, {
    CancelToken? cancelToken,
  }) async {
    _baseOverride = base;
    try {
      EmbyException? lastError;
      for (final prefix in <bool>[true, false]) {
        _useEmbyPrefix = prefix;
        try {
          final info = await _getJson(
            _apiUrl('/System/Info'),
            cancelToken: cancelToken,
          );
          final serverName = (info['ServerName'] as String?) ?? '';
          final version = (info['Version'] as String?) ?? '';
          if (serverName.isEmpty && version.isEmpty) {
            throw EmbyException.other('Emby 服务器没有返回服务器信息');
          }
          final users = await _fetchUsersOrEmpty(cancelToken: cancelToken);
          return EmbyProbeResult(
            ok: true,
            serverName: serverName,
            version: version,
            users: users,
            workingBaseUrl: base,
          );
        } on EmbyException catch (e) {
          // 401 is prefix-independent: the credential itself is wrong.
          if (e.kind == EmbyErrorKind.unauthorized) {
            return EmbyProbeResult(
              ok: false,
              errorKind: e.kind,
              errorMessage: e.message,
            );
          }
          lastError = e;
          // 404/other on this prefix: try the other one.
          continue;
        }
      }
      final e = lastError ?? EmbyException.unreachable();
      return EmbyProbeResult(
        ok: false,
        errorKind: e.kind,
        // A 404 on BOTH prefixes means the address path is wrong.
        errorMessage: e.kind == EmbyErrorKind.notFound
            ? 'Emby 服务器地址不对，请检查地址'
            : e.message,
      );
    } finally {
      _baseOverride = null;
    }
  }

  /// Users for the probe: skipped when [config.userId] is already
  /// known; a failed fetch is an empty list, never a probe failure
  /// (see [probe]).
  Future<List<EmbyUser>> _fetchUsersOrEmpty({
    CancelToken? cancelToken,
  }) async {
    if (config.userId.isNotEmpty) return const [];
    try {
      return await _fetchUsers(cancelToken: cancelToken);
    } catch (_) {
      return const [];
    }
  }

  // -- Account login ---------------------------------------------------

  /// Username + password login: POST /Users/AuthenticateByName.
  /// Returns the AccessToken + User Id to store; the password is
  /// sent once in the request body and never stored anywhere.
  ///
  /// Tries `/emby` first, then the root (same prefix walk as
  /// [probe]). 401 = wrong name/password. [baseUrl] tries a
  /// 备用线路 instead of the main address (the connect page uses
  /// it after the main address fails); the override is always
  /// cleared afterwards.
  Future<EmbyAuthResult> authenticateByName({
    required String username,
    required String password,
    String? baseUrl,
    Duration timeout = const Duration(seconds: 8),
    CancelToken? cancelToken,
  }) async {
    final deviceId = config.deviceId.isNotEmpty
        ? config.deviceId
        : EmbyServerConfig.newDeviceId();
    _baseOverride = baseUrl;
    try {
      EmbyException? lastError;
      for (final prefix in <bool>[true, false]) {
        _useEmbyPrefix = prefix;
        try {
          final res = await _mutator(
            'POST',
            _apiUrl('/Users/AuthenticateByName'),
            headers: <String, String>{
              'X-Emby-Authorization':
                  'MediaBrowser Client="HAo Studio", Device="iPhone", '
                  'DeviceId="$deviceId", Version="1.1.6"',
            },
            jsonBody: <String, dynamic>{
              'Username': username,
              'Pw': password,
            },
            timeout: timeout,
            cancelToken: cancelToken,
          );
          if (res.statusCode == 401) {
            return EmbyAuthResult(
              ok: false,
              errorKind: EmbyErrorKind.unauthorized,
              errorMessage:
                  EmbyException.unauthorizedAccount().message,
            );
          }
          if (res.statusCode == 404) continue;
          if (res.statusCode < 200 || res.statusCode >= 300) {
            return EmbyAuthResult(
              ok: false,
              errorKind: EmbyErrorKind.other,
              errorMessage: 'Emby 服务器返回了错误（${res.statusCode}）',
            );
          }
          final doc = res.json;
          if (doc is Map<String, dynamic>) {
            final token = (doc['AccessToken'] as String?) ?? '';
            final user = doc['User'];
            final userId = user is Map<String, dynamic>
                ? (user['Id'] as String?) ?? ''
                : '';
            final userName = user is Map<String, dynamic>
                ? (user['Name'] as String?) ?? ''
                : '';
            if (token.isEmpty || userId.isEmpty) {
              return const EmbyAuthResult(
                ok: false,
                errorKind: EmbyErrorKind.other,
                errorMessage: 'Emby 登录没有返回有效的凭证',
              );
            }
            return EmbyAuthResult(
              ok: true,
              accessToken: token,
              userId: userId,
              userName: userName,
            );
          }
          return const EmbyAuthResult(
            ok: false,
            errorKind: EmbyErrorKind.other,
            errorMessage: 'Emby 登录返回了无法识别的数据',
          );
        } on EmbyException catch (e) {
          lastError = e;
          continue;
        }
      }
      final e = lastError ?? EmbyException.unreachable();
      return EmbyAuthResult(
        ok: false,
        errorKind: e.kind,
        errorMessage: e.message,
      );
    } finally {
      _baseOverride = null;
    }
  }

  /// Lightweight reachability check for one 备用线路, no
  /// credential needed: GET /System/Info/Public (the public,
  /// unauthenticated endpoint). 200 + a server-identity field =
  /// "this address is an Emby server". Used by the fallback-line
  /// editor's per-line test; never throws.
  Future<bool> checkPublicLine(
    String lineBaseUrl, {
    CancelToken? cancelToken,
  }) async {
    var base = lineBaseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.isEmpty) return false;
    try {
      for (final prefix in <String>['/emby', '']) {
        final res = await _fetcher(
          '$base$prefix/System/Info/Public',
          timeout: const Duration(seconds: 5),
          cancelToken: cancelToken,
        );
        if (res.statusCode != 200) continue;
        final doc = res.json;
        if (doc is Map<String, dynamic> &&
            ((doc['ServerName'] as String?)?.isNotEmpty == true ||
                (doc['Version'] as String?)?.isNotEmpty == true ||
                (doc['Id'] as String?)?.isNotEmpty == true)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Resolve (and remember) the working API prefix without returning
  /// users. Used by the tab page before its first data load; the
  /// full probe (with users) lives in Settings.
  Future<void> ensureApiRoot({CancelToken? cancelToken}) async {
    for (final prefix in <bool>[true, false]) {
      _useEmbyPrefix = prefix;
      try {
        await _getJson(_apiUrl('/System/Info'), cancelToken: cancelToken);
        return;
      } on EmbyException catch (e) {
        if (e.kind == EmbyErrorKind.unauthorized) rethrow;
        continue;
      }
    }
    throw EmbyException.unreachable();
  }

  Future<List<EmbyUser>> _fetchUsers({CancelToken? cancelToken}) async {
    final doc = await _getDocument(
      _apiUrl('/Users'),
      cancelToken: cancelToken,
    );
    // GET /Users answers with a bare JSON array on some versions and
    // an {Items: [...]} object on others — accept both.
    final List<dynamic>? list;
    if (doc is List) {
      list = doc;
    } else if (doc is Map<String, dynamic> && doc['Items'] is List) {
      list = doc['Items'] as List<dynamic>;
    } else {
      list = null;
    }
    if (list == null) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(EmbyUser.fromJson)
        .where((u) => u.id.isNotEmpty)
        .toList();
  }

  // -- Libraries -------------------------------------------------------

  /// GET /Users/{userId}/Views — ALL libraries, not just movies/tv
  /// (build 30 audit §17: the old movies/tvshows-only filter hid
  /// mixed/music/homevideo libraries from the tab page's inventory
  /// line, so chen could not see what the app had found. Pin
  /// resolution still matches by type — see _pickLibrary).
  Future<List<EmbyLibrary>> libraries({CancelToken? cancelToken}) async {
    final json = await _getJson(
      _apiUrl('/Users/${config.userId}/Views'),
      cancelToken: cancelToken,
    );
    final items = (json['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(EmbyLibrary.fromJson)
        .where((l) => l.id.isNotEmpty)
        .toList();
    return items;
  }

  /// Count items under one library (Limit 1 — only TotalRecordCount
  /// is read). Used by the tab page's library inventory line so chen
  /// can match what the app found against his server.
  Future<int> libraryItemCount(
    String libraryId, {
    String? includeItemTypes,
    CancelToken? cancelToken,
  }) async {
    final query = <String, String>{
      'parentId': libraryId,
      'Recursive': 'true',
      'StartIndex': '0',
      'Limit': '1',
      if (includeItemTypes != null && includeItemTypes.isNotEmpty)
        'IncludeItemTypes': includeItemTypes,
    };
    final json = await _getJson(
      _apiQuery('/Users/${config.userId}/Items', query),
      cancelToken: cancelToken,
    );
    return (json['TotalRecordCount'] as num?)?.toInt() ?? 0;
  }

  // -- Items -----------------------------------------------------------

  /// Movies rail (build 30 audit §17): 'Video' as well as 'Movie' —
  /// loose video files the server never matched to a movie carry
  /// Type 'Video' and were invisible before. Trailers / extras are
  /// their own types ('Trailer' / 'Extra'), so they stay out.
  Future<EmbyItemsPage> movies({
    String? libraryId,
    int startIndex = 0,
    int limit = 50,
    CancelToken? cancelToken,
  }) =>
      _items(
        includeItemTypes: 'Movie,Video',
        libraryId: libraryId,
        startIndex: startIndex,
        limit: limit,
        cancelToken: cancelToken,
      );

  Future<EmbyItemsPage> series({
    String? libraryId,
    int startIndex = 0,
    int limit = 50,
    CancelToken? cancelToken,
  }) =>
      _items(
        includeItemTypes: 'Series',
        libraryId: libraryId,
        startIndex: startIndex,
        limit: limit,
        cancelToken: cancelToken,
      );

  Future<EmbyItemsPage> _items({
    required String includeItemTypes,
    String? libraryId,
    int startIndex = 0,
    int limit = 50,
    CancelToken? cancelToken,
  }) async {
    final query = <String, String>{
      if (libraryId != null && libraryId.isNotEmpty) 'parentId': libraryId,
      'IncludeItemTypes': includeItemTypes,
      'Recursive': 'true',
      'StartIndex': '$startIndex',
      'Limit': '$limit',
      'SortBy': 'SortName',
      'Fields': _kItemFields,
    };
    final url = _apiQuery('/Users/${config.userId}/Items', query);
    final json = await _getJson(url, cancelToken: cancelToken);
    return _pageFromJson(json);
  }

  /// Emby title search (title only — the server does not match cast
  /// or synopsis). Emby-only; v1 never merges CMS results in.
  /// Paginated: the old 50-item cap silently cut large result sets
  /// with no way to see the rest. Callers page with [startIndex]
  /// until `items.length >= totalCount`.
  Future<EmbyItemsPage> search(
    String query, {
    int startIndex = 0,
    int limit = 50,
    CancelToken? cancelToken,
  }) async {
    final url = _apiQuery('/Users/${config.userId}/Items', <String, String>{
      'searchTerm': query,
      'IncludeItemTypes': 'Movie,Series,Episode,Video',
      'Recursive': 'true',
      'StartIndex': '$startIndex',
      'Limit': '$limit',
      'Fields': _kItemFields,
    });
    final json = await _getJson(url, cancelToken: cancelToken);
    return _pageFromJson(json);
  }

  // -- Resume / NextUp (1.1.6, server-driven rails) --------------------

  /// Server-side "continue watching": GET /Users/{userId}/Items/Resume.
  /// Items in progress (movies + episodes), each carrying its
  /// UserData (resume position / played / favorite). The tab page
  /// shows these first; local history is only the fallback when the
  /// server cannot be reached or returns nothing.
  Future<List<VideoItem>> resumeItems({
    int limit = 50,
    CancelToken? cancelToken,
  }) async {
    final url = _apiQuery('/Users/${config.userId}/Items/Resume', <String, String>{
      'MediaTypes': 'Video',
      'Recursive': 'true',
      'Limit': '$limit',
      'Fields': _kItemFields,
    });
    final json = await _getJson(url, cancelToken: cancelToken);
    return _pageFromJson(json).items;
  }

  /// Next unwatched episode(s) of one series: GET /Shows/NextUp.
  /// Returns episode items (with SeriesId / SeriesName /
  /// ParentIndexNumber / IndexNumber, so the tab page can label and
  /// open them directly). Empty when the series is fully watched or
  /// the server has no next episode for it.
  Future<List<VideoItem>> nextUp({
    required String seriesId,
    int limit = 5,
    CancelToken? cancelToken,
  }) async {
    final url = _apiQuery('/Shows/NextUp', <String, String>{
      'userId': config.userId,
      'seriesId': seriesId,
      'Limit': '$limit',
      'Fields': _kItemFields,
    });
    final json = await _getJson(url, cancelToken: cancelToken);
    return _pageFromJson(json).items;
  }

  /// One item's server-side user data (resume position / played /
  /// favorite / rating). Best-effort: returns null when the item is
  /// gone or the server cannot be reached — the caller (detail page)
  /// falls back to local state instead of failing the page.
  Future<EmbyUserData?> userData(
    String itemId, {
    CancelToken? cancelToken,
  }) async {
    try {
      final item = await _getJson(
        _apiQuery(
          '/Users/${config.userId}/Items/$itemId',
          <String, String>{'Fields': 'UserData'},
        ),
        cancelToken: cancelToken,
      );
      return EmbyUserData.fromJson(item['UserData']);
    } catch (_) {
      return null;
    }
  }

  // -- Server sync (1.1.6, best-effort writes) -------------------------
  //
  // Endpoints (Emby Server API listing):
  // - POST   /Users/{UserId}/PlayingItems/{Id}            start
  // - POST   /Users/{UserId}/PlayingItems/{Id}/Progress   progress
  // - DELETE /Users/{UserId}/PlayingItems/{Id}            stopped
  // - POST   /Users/{UserId}/PlayedItems/{Id}             mark played
  // - POST   /Users/{UserId}/FavoriteItems/{Id}           favorite
  // - DELETE /Users/{UserId}/FavoriteItems/{Id}           unfavorite
  // - POST   /Users/{UserId}/Items/{Id}/Rating?likes=…    like/dislike
  // - DELETE /Users/{UserId}/Items/{Id}/Rating            clear rating
  // Every method returns false (never throws) on any failure, so a
  // sync failure can never break playback or exit; the local store
  // stays the fallback. The exact request binding (PositionTicks /
  // Likes as query params, as sent here) is 待真服验证.

  /// One mutating call: 2xx = true, anything else = false.
  /// Cancellation is swallowed too (a disposed page reporting late
  /// is not an error) — callers are all fire-and-forget.
  Future<bool> _mutate(
    String method,
    String url, {
    CancelToken? cancelToken,
  }) async {
    try {
      final res = await _mutator(
        method,
        url,
        headers: _authHeaders,
        cancelToken: cancelToken,
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Automatic playback sync (start / progress / stopped / mark
  /// played) behind the 数据上报 switch ([EmbyServerConfig.
  /// reportProgress], default on): when the user turns it off, NO
  /// request is sent at all — the method returns false without
  /// touching the network. Explicit user actions (favorite / like
  /// below) use [_mutate] directly and are never gated: tapping
  /// them is the user asking the server to record it.
  Future<bool> _reportMutate(
    String method,
    String url, {
    CancelToken? cancelToken,
  }) {
    if (!config.reportProgress) return Future.value(false);
    return _mutate(method, url, cancelToken: cancelToken);
  }

  String _playingItemsUrl(String itemId, [String suffix = '']) =>
      _apiUrl('/Users/${config.userId}/PlayingItems/$itemId$suffix');

  String _ticksQuery(double positionSeconds, {bool? isPaused}) {
    final qs = <String, String>{
      'PositionTicks': '${ticksFromSeconds(positionSeconds)}',
      if (isPaused != null) 'IsPaused': '$isPaused',
    };
    return qs.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }

  /// Report that playback of [itemId] started (position in seconds).
  /// Gated by the 数据上报 switch (see [_reportMutate]).
  Future<bool> reportPlaybackStart(
    String itemId, {
    double positionSeconds = 0,
    CancelToken? cancelToken,
  }) =>
      _reportMutate(
        'POST',
        '${_playingItemsUrl(itemId)}?${_ticksQuery(positionSeconds)}',
        cancelToken: cancelToken,
      );

  /// Periodic progress report (position in seconds). The player
  /// throttles calls to one per 15 s of forward playback + exit +
  /// completion (native_video_player_page.dart _reportEmbyProgress);
  /// the server is the resume source of truth across devices.
  /// Gated by the 数据上报 switch (see [_reportMutate]).
  Future<bool> reportPlaybackProgress(
    String itemId, {
    required double positionSeconds,
    bool isPaused = false,
    CancelToken? cancelToken,
  }) =>
      _reportMutate(
        'POST',
        '${_playingItemsUrl(itemId, '/Progress')}?'
        '${_ticksQuery(positionSeconds, isPaused: isPaused)}',
        cancelToken: cancelToken,
      );

  /// Report that playback of [itemId] stopped. The final position
  /// should already have been reported via [reportPlaybackProgress];
  /// this only ends the session server-side.
  /// Gated by the 数据上报 switch (see [_reportMutate]).
  Future<bool> reportPlaybackStopped(
    String itemId, {
    CancelToken? cancelToken,
  }) =>
      _reportMutate('DELETE', _playingItemsUrl(itemId),
          cancelToken: cancelToken);

  /// Mark [itemId] played on the server.
  /// Gated by the 数据上报 switch (see [_reportMutate]): the
  /// 已看标记 is part of the same sync, and it is fired
  /// automatically on episode end, not by a user tap.
  Future<bool> markPlayed(
    String itemId, {
    CancelToken? cancelToken,
  }) =>
      _reportMutate(
        'POST',
        _apiUrl('/Users/${config.userId}/PlayedItems/$itemId'),
        cancelToken: cancelToken,
      );

  /// Set or clear the server-side favorite flag for [itemId].
  Future<bool> setFavorite(
    String itemId,
    bool favorite, {
    CancelToken? cancelToken,
  }) =>
      _mutate(
        favorite ? 'POST' : 'DELETE',
        _apiUrl('/Users/${config.userId}/FavoriteItems/$itemId'),
        cancelToken: cancelToken,
      );

  /// Like (true) or dislike (false) [itemId] on the server. Emby's
  /// rating API is a like/dislike flag, not stars — the app exposes
  /// the same (a single "like" toggle; dislike has no UI yet).
  Future<bool> rateItem(
    String itemId, {
    required bool likes,
    CancelToken? cancelToken,
  }) =>
      _mutate(
        'POST',
        '${_apiUrl('/Users/${config.userId}/Items/$itemId/Rating')}'
        '?likes=$likes',
        cancelToken: cancelToken,
      );

  /// Clear the server-side rating for [itemId].
  Future<bool> clearRating(
    String itemId, {
    CancelToken? cancelToken,
  }) =>
      _mutate(
        'DELETE',
        _apiUrl('/Users/${config.userId}/Items/$itemId/Rating'),
        cancelToken: cancelToken,
      );

  // -- Seasons / episodes ----------------------------------------------

  /// Seasons of a series, sorted by IndexNumber (missing → last).
  /// Explicit Limit: the endpoint has no documented default page
  /// size, and a series with more seasons than the server default
  /// would silently lose the tail.
  Future<List<Map<String, dynamic>>> seasons(
    String seriesId, {
    CancelToken? cancelToken,
  }) async {
    final url = _apiQuery('/Shows/$seriesId/Seasons', <String, String>{
      'userId': config.userId,
      'Limit': '100',
      'Fields': 'Overview,ImageTags',
    });
    final json = await _getJson(url, cancelToken: cancelToken);
    final items = (json['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((s) => s['Type'] == 'Season' || s['Type'] == null)
        .toList();
    items.sort(_byIndexNumber);
    return items;
  }

  /// Episodes of one season, sorted by IndexNumber (missing → last).
  /// Each episode carries its stream facts (MediaSources are
  /// requested here so detail() can tag the stream URLs).
  /// Explicit Limit 1000: the endpoint has no documented default
  /// page size, and a long season (daily shows, 柯南-style runs)
  /// past the server default would silently lose its tail.
  Future<List<EmbyEpisode>> episodes(
    String seriesId,
    String seasonId, {
    CancelToken? cancelToken,
  }) async {
    final url = _apiQuery('/Shows/$seriesId/Episodes', <String, String>{
      'userId': config.userId,
      'seasonId': seasonId,
      'MediaTypes': 'Video',
      'Limit': '1000',
      'Fields': _kDetailFields,
    });
    final json = await _getJson(url, cancelToken: cancelToken);
    final items = (json['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    items.sort(_byIndexNumber);
    return items
        .map(
          (m) => EmbyEpisode(
            item: _toVideoItem(m),
            facts: EmbyStreamFacts.fromMediaSources(m['MediaSources']),
            markers: SkipMarkers.fromEmbyChapters(m['Chapters']),
          ),
        )
        .toList();
  }

  /// Episodes of one season as playable [PlayEpisode]s (the
  /// mapping detail() uses). The detail page calls this when the
  /// user opens a season whose episodes were not loaded yet — one
  /// season per request, never a full-series sweep.
  Future<List<PlayEpisode>> seasonEpisodes(
    String seriesId,
    String seasonId, {
    CancelToken? cancelToken,
  }) async {
    final eps = await episodes(seriesId, seasonId, cancelToken: cancelToken);
    return _episodesToPlayEpisodes(eps);
  }

  /// One season's fetched episodes → playable episodes (name falls
  /// back to '第 N 集' from the list position; the stream URL is
  /// tagged with the episode's stream facts for the engine gate).
  List<PlayEpisode> _episodesToPlayEpisodes(List<EmbyEpisode> eps) => [
        for (var i = 0; i < eps.length; i++)
          PlayEpisode(
            name: eps[i].item.name.isNotEmpty
                ? eps[i].item.name
                : '第 ${i + 1} 集',
            url: streamUrl(eps[i].item.vodId, facts: eps[i].facts),
            introStart: eps[i].markers?.introStart,
            introEnd: eps[i].markers?.introEnd,
            creditsStart: eps[i].markers?.creditsStart,
          ),
      ];

  // -- Detail ----------------------------------------------------------

  /// Single item → [VideoDetail]. Never goes through
  /// VideoDetailService.loadWithRace (that race is CMS-only).
  /// Movie: 1 line ('直链') + 1 episode ('正片'). Series: one line
  /// per season ('第 N 季'), episodes sorted by IndexNumber — but
  /// only the first season with episodes is fetched eagerly (1.1.6
  /// lazy load); the other seasons' lines start empty and are
  /// filled on demand via [seasonEpisodes].
  /// A bare Episode id plays as a single-episode direct stream.
  Future<VideoDetail> detail(String itemId, {CancelToken? cancelToken}) async {
    Map<String, dynamic> item;
    try {
      item = await _getJson(
        _apiQuery(
          '/Users/${config.userId}/Items/$itemId',
          <String, String>{'Fields': _kDetailFields},
        ),
        cancelToken: cancelToken,
      );
    } on EmbyException catch (e) {
      if (e.kind == EmbyErrorKind.notFound) {
        throw EmbyException.notFound('这部影片在 Emby 里找不到了');
      }
      rethrow;
    }
    final type = (item['Type'] as String?) ?? '';
    final meta = _toVideoMeta(item);
    final facts = EmbyStreamFacts.fromMediaSources(item['MediaSources']);
    // 'Video' plays like a movie: one loose file, one direct line
    // (build 30 audit §17 — otherwise a Video card would open an
    // empty detail that only throws '打不开').
    if (type == 'Movie' || type == 'Episode' || type == 'Video') {
      final epName = type == 'Episode'
          ? _episodeDisplayName(item)
          : '正片';
      final markers = SkipMarkers.fromEmbyChapters(item['Chapters']);
      return VideoDetail(
        source: sourceId,
        vodId: itemId,
        meta: meta,
        // A loose 'Video' file is a single film: report it as a
        // movie so the player treats it as one (no 下一集 lookup).
        mediaType: type == 'Video' ? 'Movie' : type,
        lines: [
          PlayLine(name: '直链', episodes: [
            PlayEpisode(
              name: epName,
              url: streamUrl(itemId, facts: facts),
              introStart: markers.introStart,
              introEnd: markers.introEnd,
              creditsStart: markers.creditsStart,
            ),
          ]),
        ],
      );
    }
    if (type == 'Series') {
      final seasonList = await seasons(itemId, cancelToken: cancelToken);
      // Lazy (1.1.6): only the FIRST season with episodes is
      // fetched now — a 10-season series used to cost 11 requests
      // before the detail page could paint. Every season still gets
      // a line (so the season chips render), but a line with no
      // episodes yet is "not loaded", NOT "missing": the detail page
      // loads it on demand via [seasonEpisodes] when the user opens
      // that season. Degenerate case only: when the seasons tried so
      // far all came back empty, the next one is tried too, so a
      // series with no playable episode anywhere still reports the
      // old "no episodes" error instead of an empty page.
      final lines = <PlayLine>[];
      var foundEpisodes = false;
      for (final season in seasonList) {
        final seasonId = (season['Id'] as String?) ?? '';
        if (seasonId.isEmpty) continue;
        final index = (season['IndexNumber'] as num?)?.toInt();
        final lineName = index != null
            ? '第 $index 季'
            : ((season['Name'] as String?) ?? '').isNotEmpty
                ? (season['Name'] as String?)!
                : '季';
        var eps = <PlayEpisode>[];
        if (!foundEpisodes) {
          final fetched = await episodes(
            itemId,
            seasonId,
            cancelToken: cancelToken,
          );
          eps = _episodesToPlayEpisodes(fetched);
          if (eps.isNotEmpty) foundEpisodes = true;
        }
        lines.add(PlayLine(name: lineName, episodes: eps));
      }
      if (lines.isEmpty || !foundEpisodes) {
        throw EmbyException.other('这部剧集在 Emby 里没有可播的集');
      }
      return VideoDetail(
        source: sourceId,
        vodId: itemId,
        meta: meta,
        mediaType: type,
        lines: lines,
      );
    }
    throw EmbyException.other('这部影片在 Emby 里打不开');
  }

  // -- Mapping (pure apart from imageUrl) ------------------------------

  EmbyItemsPage _pageFromJson(Map<String, dynamic> json) {
    final items = (json['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((m) {
          // Playable video types only (build 30 audit §17): 'Video'
          // is a loose video file — visible in the movies rail now.
          // 'Trailer' / 'Extra' / 'BoxSet' stay out: trailers and
          // extras are not films, and a BoxSet has no playable
          // detail yet (it needs a children listing page first).
          final t = (m['Type'] as String?) ?? '';
          return t == 'Movie' ||
              t == 'Series' ||
              t == 'Episode' ||
              t == 'Video';
        })
        .map(_toVideoItem)
        .toList();
    return EmbyItemsPage(
      items: items,
      totalCount: (json['TotalRecordCount'] as num?)?.toInt() ?? items.length,
    );
  }

  /// One raw item → [VideoItem]. Missing fields never throw: no
  /// ImageTags → pic stays '' (placeholder), no Overview / rating /
  /// ChildCount → empty strings. `UserData` is NO LONGER dropped
  /// (1.1.6): the server's resume position / played / favorite /
  /// rating ride on the item, so the tab page can show server-side
  /// "continue watching" instead of local history only.
  VideoItem _toVideoItem(Map<String, dynamic> json) {
    final id = (json['Id'] as String?) ?? '';
    final imageTags = json['ImageTags'];
    final tag = imageTags is Map<String, dynamic>
        ? (imageTags['Primary'] as String?)
        : null;
    final genres = (json['Genres'] as List<dynamic>? ?? const [])
        .map((g) => g.toString())
        .where((g) => g.isNotEmpty)
        .toList();
    final rating = json['CommunityRating'];
    final userData = EmbyUserData.fromJson(json['UserData']);
    final runTicks = (json['RunTimeTicks'] as num?)?.toDouble() ?? 0;
    var fraction = userData.playedPercentage;
    if (fraction <= 0 &&
        userData.playbackPositionSeconds > 0 &&
        runTicks > 0) {
      fraction = (userData.playbackPositionSeconds * ticksPerSecond / runTicks)
          .clamp(0.0, 1.0);
    }
    // Series episode count: ChildCount is the number of SEASONS,
    // not episodes — the poster badge shows "$total 集", so a
    // 3-season show read "3 集" and a 1-season show showed no count
    // at all. RecursiveItemCount is the episode total; fall back to
    // ChildCount when the server omits it.
    final totalCount = (json['Type'] as String?) == 'Series'
        ? (json['RecursiveItemCount'] ?? json['ChildCount'])
        : json['ChildCount'];
    return VideoItem(
      source: sourceId,
      sourceName: 'Emby',
      vodId: id,
      name: (json['Name'] as String?) ?? '',
      pic: tag != null && tag.isNotEmpty
          ? imageUrl(id, maxWidth: 400, tag: tag)
          : '',
      year: (json['ProductionYear'] ?? '').toString(),
      type: genres.join(' / '),
      score: rating is num ? _formatRating(rating) : '',
      total: totalCount?.toString() ?? '',
      progressSeconds: userData.playbackPositionSeconds,
      progressFraction: fraction,
      played: userData.played,
      isFavorite: userData.isFavorite,
      likes: userData.likes,
      mediaType: (json['Type'] as String?) ?? '',
      seriesId: (json['SeriesId'] as String?) ?? '',
      seriesName: (json['SeriesName'] as String?) ?? '',
      seasonIndex: (json['ParentIndexNumber'] as num?)?.toInt(),
      episodeIndex: (json['IndexNumber'] as num?)?.toInt(),
    );
  }

  VideoMeta _toVideoMeta(Map<String, dynamic> json) {
    final id = (json['Id'] as String?) ?? '';
    final imageTags = json['ImageTags'];
    final tag = imageTags is Map<String, dynamic>
        ? (imageTags['Primary'] as String?)
        : null;
    final genres = (json['Genres'] as List<dynamic>? ?? const [])
        .map((g) => g.toString())
        .where((g) => g.isNotEmpty)
        .toList();
    final rating = json['CommunityRating'];
    final ticks = (json['RunTimeTicks'] as num?)?.toInt();
    // People (cast + crew) ride on the item DTO by default — the
    // old mapping dropped them, so the detail page never showed
    // 演员/导演 even though the server sends them. Actors join with
    // '，' so VideoMeta.castNames splits them back into names.
    final people = (json['People'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    String namesOf(String type) => people
        .where((p) => (p['Type'] as String?) == type)
        .map((p) => (p['Name'] as String?) ?? '')
        .where((n) => n.isNotEmpty)
        .join(type == 'Actor' ? '，' : ' / ');
    return VideoMeta(
      name: (json['Name'] as String?) ?? '',
      pic: tag != null && tag.isNotEmpty
          ? imageUrl(id, maxWidth: 800, tag: tag)
          : '',
      year: (json['ProductionYear'] ?? '').toString(),
      type: genres.join(' / '),
      score: rating is num ? _formatRating(rating) : '',
      actor: namesOf('Actor'),
      director: namesOf('Director'),
      content: (json['Overview'] as String?) ?? '',
      runtime: ticks != null && ticks > 0 ? (ticks ~/ 600000000) : null,
    );
  }

  String _formatRating(num rating) {
    // 8.0 → '8.0' would read as a typo; 8 → '8'. Keep one decimal
    // only when it carries information.
    if (rating == rating.truncateToDouble()) {
      return rating.truncate().toString();
    }
    return rating.toStringAsFixed(1);
  }

  /// Episode display name: the episode title when present, else
  /// '第 N 集' from IndexNumber, else '正片'.
  String _episodeDisplayName(Map<String, dynamic> json) {
    final name = (json['Name'] as String?) ?? '';
    if (name.isNotEmpty) return name;
    final index = (json['IndexNumber'] as num?)?.toInt();
    if (index != null) return '第 $index 集';
    return '正片';
  }

  static int _byIndexNumber(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final ai = (a['IndexNumber'] as num?)?.toInt();
    final bi = (b['IndexNumber'] as num?)?.toInt();
    if (ai == null && bi == null) return 0;
    if (ai == null) return 1;
    if (bi == null) return -1;
    return ai.compareTo(bi);
  }

  static String _buildUrl(String path, Map<String, String> query) {
    final qs = query.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return qs.isEmpty ? path : '$path?$qs';
  }

  /// Full API URL for a path + query map (prefix + path + query).
  String _apiQuery(String path, Map<String, String> query) =>
      _apiUrl(_buildUrl(path, query));
}
