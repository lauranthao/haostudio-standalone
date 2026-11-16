// Huya adapter — port of Pure Live 3.x
// lib/shared/platforms/huya/huya_site.dart (1284 lines, most complex).
//
// Room detail: HTML scrape — GET https://www.huya.com/<roomId>, regex
// `var TT_ROOM_DATA` + `stream:`; vMultiStreamInfo[] -> qualities
// (bitRate 0 = 原画; 4K excluded; no invented 2000 fallback).
// URL build: buildAntiCode (base64 fm template, wsSecret=md5(template));
// `ratio` query param REPLACED with the requested bitrate (removed for
// 原画); `codec=264` appended when missing.
// Expiry model: refreshAt ~100 s after issue, invalidAt ~125 s
// (wsTime+5min is the hard signature bound).
// Recovery: reload room detail, re-list qualities, rebuild ALL URLs.
// Search: GET https://search.cdn.huya.com/ — real API, paginated.
// Lines are identified by URL (CDN + path), never by index after refresh
// (see huya_transport_policy.dart).
//
// NOT ported (needs lib/core/tars/, which does not exist in this project):
// * Play UA fetch from GitHub assets/play_config.json — the HYSDK UA is
//   used for room requests instead.
// * Account cookies (yyuid) — anonymousLogin only; parseViewerUidFromCookie
//   is kept for when a cookie store exists.
//
// PORTED (v1.0.4, huya_wup.dart + lib/core/tars/):
// * Native WUP `getCdnTokenInfoEx` FLV token (~420 s) — preferred for FLV
//   lines in getPlayUrl, with the web template as fallback; NEVER reused
//   for HLS. Leases are remembered per URL so getPlayUrlRefreshAt /
//   getPlayUrlInvalidAt report the long lease (refresh 30 s before
//   invalidAt) instead of the web-template 100 s / 125 s transport terms.
// * Super-chat (WUP TARS) — getSuperChatMessage() fetches the board via
//   `getHeadLineMessageBoard`; the WS uri-2001314 reconciliation lives
//   in huya_danmaku.dart.
// * Danmaku (WS wss://wsapi.huya.com, TARS-serialised) — ported in
//   huya_danmaku.dart (TARS codec vendored under lib/core/tars/codec/);
//   getDanmaku() returns HuyaDanmaku.

import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../../core/models/live_models.dart';
import '../../../core/network/http_client.dart';
import '../live_site.dart';
import 'huya_anti_code.dart';
import 'huya_danmaku.dart';
import 'huya_models.dart';
import 'huya_request_params.dart';
import 'huya_room_parser.dart';
import 'huya_transport_policy.dart';
import 'huya_wup.dart';

/// Fetches the native WUP FLV token for one line. Defaults to the live
/// WUP call ([fetchNativeHuyaCdnToken]); tests inject a stub.
typedef HuyaNativeTokenFetcher = Future<HuyaCdnTokenLease> Function(
  HuyaLineModel line,
);

/// Fetches the web-identity WUP FLV token for one line. Defaults to the
/// live WUP call ([fetchWebHuyaCdnToken]); tests inject a stub.
typedef HuyaWebTokenFetcher = Future<HuyaCdnTokenLease> Function(
  HuyaLineModel line,
  HuyaViewerIdentity viewer,
);

class HuyaSite extends LiveSite {
  HuyaSite({
    Dio? dio,
    HuyaNativeTokenFetcher? nativeTokenFetcher,
    HuyaWebTokenFetcher? webTokenFetcher,
    HuyaSuperChatFetcher? superChatFetcher,
  })  : _dio = dio ?? sharedDio(),
        _nativeTokenFetcher =
            nativeTokenFetcher ?? fetchNativeHuyaCdnToken,
        _webTokenFetcher = webTokenFetcher ?? fetchWebHuyaCdnToken,
        _superChatFetcher = superChatFetcher ??
            ((lPid) => getHuyaSuperChatMessageList(lPid: lPid, first: true));

  @override
  String get id => 'huya';

  @override
  String get name => '虎牙';

  @override
  LiveDanmaku getDanmaku() =>
      HuyaDanmaku(superChatFetcher: _superChatFetcher);

  // One shared Dio for this adapter (sharedDio(); never a second Dio).
  final Dio _dio;

  /// WUP token fetchers (injectable for tests; defaults hit wup.huya.com).
  final HuyaNativeTokenFetcher _nativeTokenFetcher;
  final HuyaWebTokenFetcher _webTokenFetcher;
  final HuyaSuperChatFetcher _superChatFetcher;

  static const String _searchBaseUrl = 'https://search.cdn.huya.com/';
  static const String _anonymousLoginUrl =
      'https://udblgn.huya.com/web/anonymousLogin';

  static const String _browserUa = HuyaRequestParams.kUserAgent;

  int _lastSignatureMillis = 0;
  final Map<String, DateTime> _playbackTransportIssuedAt =
      <String, DateTime>{};
  // In-flight native/web WUP token requests, deduplicated so parallel
  // line resolution shares one request per stream (Pure Live
  // _nativeTokenRequests / _inFlightTokenRequests).
  final Map<String, Future<HuyaCdnTokenLease>> _nativeTokenRequests =
      <String, Future<HuyaCdnTokenLease>>{};
  final Map<String, Future<HuyaCdnTokenLease>> _inFlightTokenRequests =
      <String, Future<HuyaCdnTokenLease>>{};
  // Native token leases per signed URL (keyed by huyaUrlLeaseKey, cap
  // 32) — the lease-aware refresh/invalid math reads these.
  final Map<String, HuyaCdnTokenLease> _playbackTokenLeases =
      <String, HuyaCdnTokenLease>{};
  HuyaViewerIdentity? _anonymousViewerIdentity;
  Future<HuyaViewerIdentity>? _anonymousViewerIdentityRequest;
  late final int _fallbackViewerUid = _createFallbackViewerUid();
  late final String _viewerGuid = _createViewerGuid();

  // ---------------------------------------------------------------- room

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async {
    try {
      return await _loadRoomDetail(room.roomId);
    } on Object {
      // UI path: a transient failure must not blank the card — return the
      // room as offline. The recovery path below does NOT swallow errors.
      return room.copyWith(liveStatus: false);
    }
  }

  /// Strict room load: throws [FormatException] when the page carries no
  /// parseable playback metadata (recording/recovery callers must see the
  /// transient error, never a disguised "offline").
  Future<LiveRoom> _loadRoomDetail(String roomId) async {
    final response = await _dio.get<String>(
      '${HuyaRequestParams.baseUrl}/$roomId',
      options: Options(
        headers: <String, String>{
          ...HuyaRequestParams.requestHeaders,
          'Accept': 'text/html,application/xhtml+xml',
        },
        responseType: ResponseType.plain,
      ),
    );
    final html = response.data ?? '';
    if (html.isEmpty) {
      throw const FormatException('Huya room page is empty');
    }
    return parseHuyaRoomPage(html, roomId);
  }

  // ------------------------------------------------------- qualities/lines

  @override
  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async {
    final data = huyaDataOf(liveRoom);
    if (data == null) return const <LivePlayQuality>[];
    return parseHuyaPlayQualities(data);
  }

  @override
  Future<List<String>> getPlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final resolved = await _resolveLines(quality);
    return resolved.map((r) => r.url).toList(growable: false);
  }

  /// Full resolution with lease times + per-URL stream facts.
  ///
  /// Refresh/invalid deadlines come from the lease-aware overrides
  /// ([getPlayUrlRefreshAt]/[getPlayUrlInvalidAt]) so native-token FLV
  /// URLs report their long lease instead of the web-template transport
  /// terms.
  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final issuedAt = DateTime.now().toUtc();
    final resolved = await _resolveLines(quality);
    final urls = resolved.map((r) => r.url).toList(growable: false);
    DateTime? refreshAt;
    DateTime? invalidAt;
    for (final url in urls) {
      final r = getPlayUrlRefreshAt(url);
      if (r != null && (refreshAt == null || r.isBefore(refreshAt))) {
        refreshAt = r;
      }
      final v = getPlayUrlInvalidAt(url);
      if (v != null && (invalidAt == null || v.isBefore(invalidAt))) {
        invalidAt = v;
      }
    }
    return LivePlayUrlResolution(
      urls: urls,
      appliedQualityData: quality?.selectionId,
      issuedAt: issuedAt,
      refreshAt: refreshAt,
      invalidAt: invalidAt,
      streamFacts: resolved
          .map((r) => LiveStreamFacts(
              format: r.line.lineType == HuyaLineType.hls ? 'hls' : 'flv',
              codec: 'avc'))
          .toList(growable: false),
    );
  }

  /// Recovery — MUST re-fetch all identity/token/room fields; returning
  /// cached URLs is a no-op. Reloads room detail, re-lists qualities,
  /// matches the requested quality id (else first), rebuilds ALL URLs.
  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsForRecovery({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final roomId = liveRoom.roomId.trim();
    if (roomId.isEmpty) {
      return LivePlayUrlResolution(
          urls: const <String>[], appliedQualityData: quality?.selectionId);
    }
    final refreshedDetail = await _loadRoomDetail(roomId);
    if (!refreshedDetail.liveStatus) {
      return LivePlayUrlResolution(
          urls: const <String>[], appliedQualityData: quality?.selectionId);
    }
    final refreshedQualities =
        await getPlayQualities(liveRoom: refreshedDetail);
    if (refreshedQualities.isEmpty) {
      return LivePlayUrlResolution(
          urls: const <String>[], appliedQualityData: quality?.selectionId);
    }
    final requestedId = quality?.selectionId;
    final refreshedQuality = refreshedQualities.firstWhere(
      (item) => item.selectionId == requestedId,
      orElse: () => refreshedQualities.first,
    );
    final resolution = await resolvePlayUrls(
        liveRoom: refreshedDetail, quality: refreshedQuality);
    return LivePlayUrlResolution(
      urls: resolution.urls,
      appliedQualityData: refreshedQuality.selectionId,
      issuedAt: resolution.issuedAt,
      refreshAt: resolution.refreshAt,
      invalidAt: resolution.invalidAt,
      streamFacts: resolution.streamFacts,
    );
  }

  /// Resolves every line for one quality in parallel (Future.wait,
  /// per-line try/catch — one bad token must not discard the healthy
  /// FLV/HLS alternatives). Server order is kept; duplicates dropped.
  Future<List<_ResolvedLine>> _resolveLines(LivePlayQuality? quality) async {
    final data = quality?.data;
    if (data is! Map) return const <_ResolvedLine>[];
    final bitRate = int.tryParse(data['bitRate']?.toString() ?? '');
    final rawLines = data['urls'];
    if (bitRate == null || rawLines is! List) {
      return const <_ResolvedLine>[];
    }
    final lines = rawLines.whereType<HuyaLineModel>().toList(growable: false);
    final resolved = await Future.wait<_ResolvedLine?>(
      lines.map((line) async {
        try {
          final url = await getPlayUrl(line, bitRate);
          return _ResolvedLine(line: line, url: url);
        } on Object {
          return null;
        }
      }),
    );
    final out = <_ResolvedLine>[];
    final seen = <String>{};
    for (final item in resolved) {
      if (item == null || item.url.isEmpty) continue;
      if (seen.add(item.url)) out.add(item);
    }
    return out;
  }

  /// Builds the signed play URL for one line at [bitRate].
  ///
  /// FLV prefers the native WUP token (`getCdnTokenInfoEx`, ~420 s
  /// lease) and falls back to the web-template anti-code (~120 s) when
  /// WUP is unavailable; the native token is NEVER reused for HLS.
  /// When the room's own FLV template cannot be signed, a second WUP
  /// call with the anonymous web identity is tried before giving up.
  /// FLV uses its `sFlvAntiCode`, HLS its `sHlsAntiCode` — never
  /// cross-used. `ratio` is replaced with the requested bitrate and
  /// removed for 原画 (bitRate 0); `codec=264` is appended when missing.
  Future<String> getPlayUrl(HuyaLineModel line, int bitRate) async {
    HuyaViewerIdentity? viewer;
    HuyaCdnTokenLease? tokenLease;
    // Select signing material by transport before any fallback. Starting
    // every line from HLS AntiCode made an FLV WUP failure accidentally
    // reuse the HLS token; both strings happen to match for many rooms,
    // but Huya does not promise that invariant.
    var antiCode = line.lineType == HuyaLineType.flv
        ? line.flvAntiCode.trim()
        : line.hlsAntiCode.trim();
    var signatureAlreadyBuilt = false;
    // A syntactically valid web template may still yield a ~120 second
    // stream. Prefer the native WUP contract proven by sustained,
    // single-open probes. Never reuse its FLV token for HLS.
    // Native WUP needs the stream name, not the web template's `fm`. A
    // room snapshot may carry an empty/already-signed AntiCode; gating
    // on `fm` silently skipped the long-lived path or rejected an
    // otherwise valid stream. Keep legacy web material only as a
    // fallback after native fails.
    if (line.lineType == HuyaLineType.flv) {
      try {
        final nativeLease = await _getNativeCdnToken(line);
        if (nativeLease.isExpired(DateTime.now().toUtc())) {
          throw StateError('Native token expired');
        }
        final nativeUid = line.presenterUid > 0
            ? line.presenterUid
            : (await resolveViewerIdentity()).uid;
        antiCode = buildHuyaAntiCode(
          line.streamName,
          nativeUid,
          nativeLease.antiCode,
          now: _monotonicNow(),
          fallbackViewerUid: _fallbackViewerUid,
        );
        tokenLease = nativeLease;
        signatureAlreadyBuilt = true;
      } on Object {
        // Fall through to the web-template path below.
      }
    }
    if (line.lineType == HuyaLineType.flv && !signatureAlreadyBuilt) {
      final roomFlvAntiCode = line.flvAntiCode.trim();
      final isLegacyStaticToken =
          !RegExp(r'(^|&)fm=').hasMatch(roomFlvAntiCode);
      // Retain the protocol-correct web path as an explicit fallback
      // when native WUP is unavailable. Its shorter transport lease
      // remains active.
      if (isLegacyStaticToken) {
        antiCode = roomFlvAntiCode;
      } else {
        viewer = await resolveViewerIdentity();
        try {
          antiCode = buildHuyaAntiCode(
            line.streamName,
            viewer.uid,
            roomFlvAntiCode,
            now: _monotonicNow(),
            fallbackViewerUid: _fallbackViewerUid,
          );
          signatureAlreadyBuilt = true;
        } on Object {
          try {
            tokenLease = await _getWebCdnToken(line, viewer);
            antiCode = tokenLease.antiCode.trim();
          } on Object {
            // Keep the (possibly unusable) template; the empty check
            // below throws a clear error instead of a stale token.
          }
        }
      }
      if (antiCode.isEmpty) antiCode = roomFlvAntiCode;
    }
    if (antiCode.isEmpty) {
      final protocol = line.lineType == HuyaLineType.hls ? 'HLS' : 'FLV';
      throw StateError('Huya $protocol token is unavailable');
    }
    // The web fallback uses its anonymous viewer identity. Native WUP
    // above has a separate request/signing contract; do not mix those
    // identities.
    if (!signatureAlreadyBuilt && RegExp(r'(^|&)fm=').hasMatch(antiCode)) {
      viewer ??= await resolveViewerIdentity();
      antiCode = buildHuyaAntiCode(
        line.streamName,
        viewer.uid,
        antiCode,
        now: _monotonicNow(),
        fallbackViewerUid: _fallbackViewerUid,
      );
    }

    final extension = line.lineType == HuyaLineType.hls ? 'm3u8' : 'flv';
    final cdnBase = secureHuyaCdnBase(line.line);
    if (!RegExp(r'(^|&)codec=').hasMatch(antiCode)) {
      antiCode = '$antiCode&codec=264';
    }
    // Huya reuses one anti-leech query for every quality. `ratio`, when
    // already present, describes the URL captured from the page rather
    // than the user's new selection. Always replace it for a transcode
    // and remove it for source quality (bitRate 0).
    antiCode = replaceQueryParameter(
        antiCode, 'ratio', bitRate > 0 ? '$bitRate' : null);
    final url = '$cdnBase/${line.streamName}.$extension?$antiCode';
    // Current AntiCode templates encode the issue instant through seqid.
    // Some legacy/static token families do not. Remember the connection
    // issue instant for every URL built here so legacy lines stay on the
    // same proactive hand-off path instead of waiting for EOF.
    _rememberTransportIssuedAt(
        url, huyaSignedSequenceIssuedAt(url) ?? DateTime.now().toUtc());
    if (tokenLease != null) _rememberPlaybackTokenLease(url, tokenLease);
    return url;
  }

  /// Shares one in-flight native token request per stream name. Each
  /// consumer signs a new URL from the shared lease.
  Future<HuyaCdnTokenLease> _getNativeCdnToken(HuyaLineModel line) async {
    final key = line.streamName;
    final pending = _nativeTokenRequests[key];
    if (pending != null) return pending;
    final request = _nativeTokenFetcher(line);
    _nativeTokenRequests[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_nativeTokenRequests[key], request)) {
        _nativeTokenRequests.remove(key);
      }
    }
  }

  /// Shares one in-flight web-identity token request per viewer + line +
  /// stream. Each consumer signs a new URL from the shared lease.
  Future<HuyaCdnTokenLease> _getWebCdnToken(
    HuyaLineModel line,
    HuyaViewerIdentity viewer,
  ) async {
    final key = '${viewer.uid}|${line.line}|${line.streamName}';
    final current = _inFlightTokenRequests[key];
    if (current != null) return current;
    final request = _webTokenFetcher(line, viewer);
    _inFlightTokenRequests[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_inFlightTokenRequests[key], request)) {
        _inFlightTokenRequests.remove(key);
      }
    }
  }

  void _rememberPlaybackTokenLease(String url, HuyaCdnTokenLease lease) {
    final now = DateTime.now().toUtc();
    _playbackTokenLeases.removeWhere((_, value) => value.isExpired(now));
    final key = huyaUrlLeaseKey(url);
    if (_playbackTokenLeases.length >= 32 &&
        !_playbackTokenLeases.containsKey(key)) {
      _playbackTokenLeases.remove(_playbackTokenLeases.keys.first);
    }
    _playbackTokenLeases[key] = lease;
  }

  HuyaCdnTokenLease? _getPlaybackTokenLease(String url) {
    // Keep an expired entry until the next URL is registered. Forgetting
    // it at the exact expiry instant would make the longer wsTime bound
    // appear valid again and postpone a recovery that is already due.
    return _playbackTokenLeases[huyaUrlLeaseKey(url)];
  }

  static DateTime? _earlierDate(DateTime? first, DateTime? second) {
    if (first == null) return second;
    if (second == null) return first;
    return first.isBefore(second) ? first : second;
  }

  /// Wall clock strictly increasing per signature (upstream guard: two
  /// URLs signed in the same millisecond would share a seqid).
  DateTime _monotonicNow() {
    final wallMillis = DateTime.now().millisecondsSinceEpoch;
    final currentMillis =
        wallMillis > _lastSignatureMillis ? wallMillis : _lastSignatureMillis + 1;
    _lastSignatureMillis = currentMillis;
    return DateTime.fromMillisecondsSinceEpoch(currentMillis);
  }

  void _rememberTransportIssuedAt(String url, DateTime issuedAt) {
    final key = huyaUrlLeaseKey(url);
    if (_playbackTransportIssuedAt.length >= 64 &&
        !_playbackTransportIssuedAt.containsKey(key)) {
      _playbackTransportIssuedAt.remove(_playbackTransportIssuedAt.keys.first);
    }
    _playbackTransportIssuedAt[key] = issuedAt.toUtc();
  }

  DateTime? _rememberedTransportIssuedAt(String url) {
    // Keep a past deadline authoritative. Removing it exactly at expiry
    // would reveal the much later wsTime bound and incorrectly make a
    // dead URL look healthy again.
    return _playbackTransportIssuedAt[huyaUrlLeaseKey(url)];
  }

  // ------------------------------------------------------------ lease math

  /// Proactive refresh deadline for one URL: earliest of
  /// (wsTime expiry − 30 s), the native token lease's refreshAt, and
  /// (transport issue + 100 s). The transport terms apply ONLY to
  /// short-lease (web-template) URLs — native-token FLV URLs have no
  /// 100 s / 125 s transport bound. Null when no expiry can be derived.
  @override
  DateTime? getPlayUrlRefreshAt(String url) {
    final current = DateTime.now().toUtc();
    final signedInvalidAt = huyaSignedUrlInvalidAt(url);
    final tokenLease = _getPlaybackTokenLease(url);
    final transportIssuedAt =
        HuyaTransportPolicy.hasShortTransportLease(url)
            ? huyaSignedSequenceIssuedAt(url) ??
                _rememberedTransportIssuedAt(url)
            : null;
    final transportInvalidAt =
        transportIssuedAt?.add(huyaTransportInvalidAge);
    final invalidAt = _earlierDate(
        _earlierDate(signedInvalidAt, tokenLease?.invalidAt),
        transportInvalidAt);
    if (invalidAt == null) return null;
    final signatureRefreshAt =
        signedInvalidAt?.subtract(huyaSignatureRefreshLead);
    final transportRefreshAt =
        transportIssuedAt?.add(huyaTransportRefreshAge);
    final refreshAt = _earlierDate(
            _earlierDate(signatureRefreshAt, tokenLease?.refreshAt),
            transportRefreshAt) ??
        current;
    return refreshAt.isAfter(current) ? refreshAt : current;
  }

  /// Hard expiry for one URL: earliest of (wsTime + 5 min), the native
  /// token lease's invalidAt, and (transport issue + 125 s — web
  /// template URLs only). Null when no expiry can be derived.
  @override
  DateTime? getPlayUrlInvalidAt(String url) {
    final tokenLease = _getPlaybackTokenLease(url);
    final transportIssuedAt =
        HuyaTransportPolicy.hasShortTransportLease(url)
            ? huyaSignedSequenceIssuedAt(url) ??
                _rememberedTransportIssuedAt(url)
            : null;
    return _earlierDate(
      _earlierDate(huyaSignedUrlInvalidAt(url), tokenLease?.invalidAt),
      transportIssuedAt?.add(huyaTransportInvalidAge),
    );
  }

  // ------------------------------------------------------------ super chat

  /// Super-chat board for one room, via the WUP
  /// `getHeadLineMessageBoard` call (see huya_wup.dart). Prefers the
  /// room's existing danmaku credentials and re-fetches room detail only
  /// when they are missing. Best-effort: any failure returns [] rather
  /// than breaking the room load.
  @override
  Future<List<LiveMessage>> getSuperChatMessage({
    required LiveRoom liveRoom,
  }) async {
    try {
      var args = HuyaDanmakuArgs.fromDataMap(liveRoom.danmakuData);
      args ??= HuyaDanmakuArgs.fromDataMap(
          (await getRoomDetail(liveRoom)).danmakuData);
      if (args == null || args.topSid == 0) {
        return const <LiveMessage>[];
      }
      final messages = await _superChatFetcher(args.topSid);
      return messages.map(huyaSuperChatLiveMessage).toList(growable: false);
    } on Object {
      return const <LiveMessage>[];
    }
  }

  // ------------------------------------------------- anonymous identity

  /// Anonymous viewer identity from
  /// POST https://udblgn.huya.com/web/anonymousLogin. Cached per site
  /// instance; concurrent callers share the in-flight request. When the
  /// endpoint fails, a stable process-local fallback UID is used for that
  /// one acquisition and NOT cached, so the next acquisition retries the
  /// official endpoint instead of turning a brief outage into
  /// persistent 403s.
  Future<HuyaViewerIdentity> resolveViewerIdentity() async {
    final cached = _anonymousViewerIdentity;
    if (cached != null) return cached;
    final pending = _anonymousViewerIdentityRequest;
    if (pending != null) return pending;

    final request = _loadAnonymousViewerIdentity();
    _anonymousViewerIdentityRequest = request;
    try {
      final identity = await request;
      if (identity.uid != _fallbackViewerUid) {
        _anonymousViewerIdentity = identity;
      }
      return identity;
    } finally {
      if (identical(_anonymousViewerIdentityRequest, request)) {
        _anonymousViewerIdentityRequest = null;
      }
    }
  }

  Future<HuyaViewerIdentity> _loadAnonymousViewerIdentity() async {
    try {
      final uid = int.tryParse((await getAnonymousUid()).trim());
      if (uid != null && uid > 0) {
        return HuyaViewerIdentity(
            uid: uid, guid: _viewerGuid, isAnonymous: true);
      }
    } on Object {
      // Fall through to the local fallback UID below.
    }
    return HuyaViewerIdentity(
        uid: _fallbackViewerUid, guid: _viewerGuid, isAnonymous: true);
  }

  /// Raw anonymousLogin call — returns the uid string from `data.uid`.
  Future<String> getAnonymousUid() async {
    final response = await _dio.post<dynamic>(
      _anonymousLoginUrl,
      data: <String, dynamic>{
        'appId': 5002,
        'byPass': 3,
        'context': '',
        'version': '2.4',
        'data': <String, dynamic>{},
      },
      options: Options(headers: <String, String>{
        'User-Agent': _browserUa,
        'Accept': '*/*',
        'Origin': 'https://www.huya.com',
        'Referer': 'https://www.huya.com/',
        'Sec-Fetch-Dest': 'empty',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Site': 'same-site',
      }),
    );
    final decoded = _decodeJson(response.data);
    final dataMap = decoded is Map ? decoded['data'] : null;
    final uid = dataMap is Map ? dataMap['uid'] : null;
    if (uid == null) {
      throw const FormatException('Huya anonymousLogin returned no uid');
    }
    return uid.toString();
  }

  /// `yyuid` from an account cookie (kept for when a cookie store exists;
  /// this port is anonymous-only and never calls it).
  static int? parseViewerUidFromCookie(String cookie) {
    final match =
        RegExp(r'(?:^|;\s*)yyuid=(\d+)(?:;|$)').firstMatch(cookie);
    final uid = int.tryParse(match?.group(1) ?? '');
    return uid != null && uid > 0 ? uid : null;
  }

  static String _createViewerGuid() {
    final random = Random.secure();
    const alphabet = '0123456789abcdef';
    return List<String>.generate(
            32, (_) => alphabet[random.nextInt(alphabet.length)])
        .join();
  }

  static int _createFallbackViewerUid() {
    final random = Random.secure();
    // Random.nextInt is limited to 2^32, so compose two supported ranges.
    final offset = random.nextInt(1000000) * 100000 + random.nextInt(100000);
    return 1400000000000 + offset;
  }

  // ------------------------------------------------------- search + lists

  @override
  Future<List<LiveRoom>> searchRooms(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final effectivePageSize = pageSize.clamp(1, 50);
    final response = await _dio.get<dynamic>(
      _searchBaseUrl,
      queryParameters: <String, dynamic>{
        'm': 'Search',
        'do': 'getSearchContent',
        'q': keyword,
        'uid': 0,
        'v': 4,
        'typ': -5,
        'livestate': 0,
        'rows': effectivePageSize,
        'start': (page - 1) * effectivePageSize,
      },
      options: Options(headers: <String, String>{'User-Agent': _browserUa}),
    );
    return parseHuyaSearchRooms(_decodeJson(response.data));
  }

  @override
  Future<List<LiveRoom>> searchAnchors(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final response = await _dio.get<dynamic>(
      _searchBaseUrl,
      queryParameters: <String, dynamic>{
        'm': 'Search',
        'do': 'getSearchContent',
        'q': keyword,
        'uid': 0,
        'v': 1,
        'typ': -5,
        'livestate': 0,
        'rows': pageSize.clamp(1, 50),
        'start': (page - 1) * pageSize.clamp(1, 50),
      },
      options: Options(headers: <String, String>{'User-Agent': _browserUa}),
    );
    return parseHuyaSearchAnchors(_decodeJson(response.data));
  }

  /// Home hot list via cache.php LiveList (no gameId).
  ///
  /// NOTE: the category endpoint was reported dead at inventory time
  /// (cache.php returning `datas: []`), so this hot list is the
  /// fallback and getCategoryRooms may come back empty — but probed live
  /// from this VM on 2026-11-16, cache.php returned 120 datas for both
  /// the hot list and `gameId=1`. There is no alternate hot/category
  /// list API in Pure Live 3.x; an empty result is returned as-is
  /// rather than faked.
  @override
  Future<List<LiveRoom>> getRecommendRooms({
    int page = 1,
    int pageSize = 30,
  }) async {
    final response = await _dio.get<dynamic>(
      'https://www.huya.com/cache.php',
      queryParameters: <String, dynamic>{
        'm': 'LiveList',
        'do': 'getLiveListByPage',
        'tagAll': 0,
        'page': page,
      },
      options: Options(headers: <String, String>{
        'User-Agent': _browserUa,
        'Origin': 'https://www.huya.com',
        'Referer': 'https://www.huya.com/',
      }),
    );
    return parseHuyaCacheList(_decodeJson(response.data));
  }

  /// Categories — port of Pure Live 3.x `getCategores` + `getSubCategores`.
  ///
  /// The four top types are fixed upstream (网游 1 / 单机 2 / 娱乐 8 /
  /// 手游 3); each one's games come from
  /// `live.cdn.huya.com/liveconfig/game/bussLive?bussType=<id>`
  /// (probed live 2026-11-16: 105/134/19/127 games). The four fetches
  /// run in parallel and one dead type never kills the other three.
  /// When every fetch fails, the verified-popular fallback below is
  /// returned so the tab never shows a blank category row — the gids
  /// are real (same live probe) and `getCategoryRooms` accepts them
  /// as `gameId`.
  @override
  Future<List<LiveArea>> getCategories({
    int page = 1,
    int pageSize = 30,
  }) async {
    final results = await Future.wait(
      _huyaCategoryTypes.map((type) async {
        try {
          final response = await _dio.get<dynamic>(
            'https://live.cdn.huya.com/liveconfig/game/bussLive',
            queryParameters: <String, dynamic>{'bussType': type},
            options: Options(
              headers: <String, String>{'User-Agent': _browserUa},
            ),
          );
          return parseHuyaCategories(_decodeJson(response.data));
        } catch (_) {
          return const <LiveArea>[];
        }
      }),
    );
    final areas = results.expand((list) => list).toList(growable: false);
    if (areas.isNotEmpty) return areas;
    return _fallbackHuyaCategories;
  }

  /// Pure Live's top-type order: 网游 / 单机 / 娱乐 / 手游.
  static const List<String> _huyaCategoryTypes = <String>['1', '2', '8', '3'];

  /// Verified-popular games per top type (live probe 2026-11-16,
  /// `bussLive` top entries by heat). Only used when all four live
  /// fetches fail; areaId is the real gid, so category rooms load.
  static const List<LiveArea> _fallbackHuyaCategories = <LiveArea>[
    // 网游
    LiveArea(areaId: '1', areaName: '英雄联盟', platform: PlatformIds.huya),
    LiveArea(areaId: '862', areaName: 'CS2', platform: PlatformIds.huya),
    LiveArea(areaId: '5937', areaName: '无畏契约', platform: PlatformIds.huya),
    LiveArea(areaId: '5485', areaName: 'lol云顶之弈', platform: PlatformIds.huya),
    LiveArea(areaId: '393', areaName: '炉石传说', platform: PlatformIds.huya),
    LiveArea(areaId: '4', areaName: '穿越火线', platform: PlatformIds.huya),
    LiveArea(areaId: '7', areaName: 'DOTA2', platform: PlatformIds.huya),
    LiveArea(areaId: '8', areaName: '魔兽世界', platform: PlatformIds.huya),
    // 单机
    LiveArea(areaId: '2793', areaName: '天天吃鸡', platform: PlatformIds.huya),
    LiveArea(areaId: '100032', areaName: '主机游戏', platform: PlatformIds.huya),
    LiveArea(areaId: '1732', areaName: '我的世界', platform: PlatformIds.huya),
    LiveArea(areaId: '70953', areaName: '失控进化-RUST', platform: PlatformIds.huya),
    LiveArea(areaId: '485', areaName: '植物大战僵尸', platform: PlatformIds.huya),
    LiveArea(areaId: '1318', areaName: '部落：上升', platform: PlatformIds.huya),
    LiveArea(areaId: '5907', areaName: '互动点播', platform: PlatformIds.huya),
    LiveArea(areaId: '4375', areaName: "精灵宝可梦Let's Go", platform: PlatformIds.huya),
    // 娱乐
    LiveArea(areaId: '2165', areaName: '户外', platform: PlatformIds.huya),
    LiveArea(areaId: '1663', areaName: '星秀', platform: PlatformIds.huya),
    LiveArea(areaId: '6861', areaName: '原创', platform: PlatformIds.huya),
    LiveArea(areaId: '2356', areaName: '体育', platform: PlatformIds.huya),
    LiveArea(areaId: '2135', areaName: '一起看', platform: PlatformIds.huya),
    LiveArea(areaId: '4079', areaName: '交友', platform: PlatformIds.huya),
    LiveArea(areaId: '2633', areaName: '二次元', platform: PlatformIds.huya),
    LiveArea(areaId: '2168', areaName: '颜值', platform: PlatformIds.huya),
    // 手游
    LiveArea(areaId: '2336', areaName: '王者荣耀', platform: PlatformIds.huya),
    LiveArea(areaId: '9449', areaName: '三角洲行动', platform: PlatformIds.huya),
    LiveArea(areaId: '3203', areaName: '和平精英', platform: PlatformIds.huya),
    LiveArea(areaId: '7185', areaName: '金铲铲之战', platform: PlatformIds.huya),
    LiveArea(areaId: '2928', areaName: 'QQ飞车手游', platform: PlatformIds.huya),
    LiveArea(areaId: '4769', areaName: 'COD手游', platform: PlatformIds.huya),
    LiveArea(areaId: '2429', areaName: '火影忍者手游', platform: PlatformIds.huya),
    LiveArea(areaId: '6909', areaName: '蛋仔派对', platform: PlatformIds.huya),
  ];

  /// Parse a `bussLive` response (`data[]` of `{gid, gameFullName}`)
  /// into flat areas. `gid` has four historical shapes (Pure Live):
  /// Map (comma-separated value, take first), double, int, String.
  static List<LiveArea> parseHuyaCategories(dynamic decoded) {
    final areas = <LiveArea>[];
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! List) return areas;
    for (final item in data) {
      if (item is! Map) continue;
      final gid = _huyaGid(item['gid']);
      if (gid.isEmpty) continue;
      final name = item['gameFullName']?.toString() ?? '';
      if (name.isEmpty) continue;
      areas.add(
        LiveArea(
          areaId: gid,
          areaName: name,
          areaPic: 'https://huyaimg.msstatic.com/cdnimage/game/$gid-MS.jpg',
          platform: PlatformIds.huya,
        ),
      );
    }
    return areas;
  }

  static String _huyaGid(dynamic rawGid) {
    if (rawGid is Map) {
      return rawGid['value']?.toString().split(',').first ?? '';
    }
    if (rawGid is double) return rawGid.toInt().toString();
    if (rawGid is int) return rawGid.toString();
    return rawGid?.toString() ?? '';
  }

  @override
  Future<List<LiveRoom>> getCategoryRooms(
    LiveArea area, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final response = await _dio.get<dynamic>(
      'https://www.huya.com/cache.php',
      queryParameters: <String, dynamic>{
        'm': 'LiveList',
        'do': 'getLiveListByPage',
        'tagAll': 0,
        'gameId': area.areaId,
        'page': page,
      },
      options: Options(headers: <String, String>{
        'User-Agent': _browserUa,
        'Origin': 'https://www.huya.com',
        'Referer': 'https://www.huya.com/',
      }),
    );
    return parseHuyaCacheList(_decodeJson(response.data));
  }

  // ------------------------------------------------------------- helpers

  /// Dio already decodes JSON bodies into Map/List; a plain-text body
  /// (or a text/plain content-type) arrives as String and is decoded here.
  static dynamic _decodeJson(dynamic data) {
    if (data is String) {
      try {
        return json.decode(data);
      } on FormatException {
        return null;
      }
    }
    return data;
  }
}

class _ResolvedLine {
  const _ResolvedLine({required this.line, required this.url});

  final HuyaLineModel line;
  final String url;
}
