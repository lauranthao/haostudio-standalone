// Douyu adapter — port of Pure Live 3.x
// lib/shared/platforms/douyu/douyu_site.dart (742 lines) +
// lib/core/network/douyu_utils.dart (651 lines, MD5 signing — ported as
// douyu_utils.dart in this directory).
//
// Room detail: GET https://www.douyu.com/betard/<roomId>.
// Quality+lines: POST.../lapi/live/getH5PlayV1/<roomId> with a signed
// body (DouyuUtils.sign); multirates[] -> qualities — rate is an OPAQUE
// integer id, NEVER sorted numerically (server order is kept);
// cdnsWithName[] -> CDN codes, scdn* LAST (Pure Live order — the
// first line is the default played line); each CDN may confirm a
// different rate — URLs are grouped by confirmed rate and only one
// rate's group is returned; appliedQualityData = confirmed rate.
// Danmaku: WS wss://danmuproxy.douyu.com:8506, type@= text protocol
// (douyu_danmaku.dart); getDanmaku() returns DouyuDanmaku.
// Play URLs expire fast (~5 min on ws lines): resolvePlayUrlsForRecovery
// re-fetches everything, never returns cached URLs.
//
// Deviations from Pure Live, deliberate:
// - Anonymous-only: no account cookies / session renewal (see
// douyu_utils.dart). The server may silently downgrade anonymous
// requests; the confirmed rate is reported, never the requested one.
// - CDN order: Pure Live 3.x sorts scdn* LAST (its comparator returns 1
// for scdn vs non-scdn) — copied verbatim. The first line is the
// default played line, so this decides which CDN plays by default.
// - Our LiveRoom has no area/introduction/notice/startedAt fields, so
// betard fields for those are dropped; watching is an int.
// - Our LiveArea is flat (no LiveCategory tree), so getCategories
// returns the flat cate2 list from m.douyu.com/api/cate/list.
// - No quality is ever invented: only rates the server advertised in
// multirates[] (or the single `rate` fallback) are offered. No Master
// quality, no 4K label.
// - searchAnchors returns LiveRoom entries (our LiveSite contract has
// no LiveAnchorItem type).

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/models/live_models.dart';
import '../../../core/network/http_client.dart';
import '../live_site.dart';
import 'douyu_danmaku.dart';
import 'douyu_utils.dart';

class DouyuSite extends LiveSite {
  DouyuSite({Dio? dio}) : _dio = dio ?? sharedDio() {
    _utils = DouyuUtils(dio: _dio);
  }

  @override
  String get id => 'douyu';

  @override
  String get name => '斗鱼';

  @override
  LiveDanmaku getDanmaku() => DouyuDanmaku();

  final Dio _dio;
  late final DouyuUtils _utils;

  /// Anonymous original-quality URLs carry `expire=300`: the CDN closes
  /// the stream 300 s after the URL was issued. The URL has no absolute
  /// time, so the issue time is remembered when it is resolved.
  static final Map<String, DateTime> _issuedAt = {};
  static const Duration _leaseRefreshLead = Duration(seconds: 45);

  /// `expire` seconds carried by a URL, or null when it has none.
  static int? douyuUrlExpireSeconds(String url) {
    final value = int.tryParse(
      Uri.tryParse(url)?.queryParameters['expire'] ?? '',
    );
    return value != null && value > 0 ? value : null;
  }

  /// Hard expiry for one URL, given when it was issued.
  static DateTime? douyuPlayUrlInvalidAt(String url, DateTime issuedAt) {
    final expire = douyuUrlExpireSeconds(url);
    if (expire == null) return null;
    return issuedAt.toUtc().add(Duration(seconds: expire));
  }

  /// Proactive refresh deadline for one URL, given when it was issued.
  /// Short leases keep three quarters of their lifetime.
  static DateTime? douyuPlayUrlRefreshAt(String url, DateTime issuedAt) {
    final invalidAt = douyuPlayUrlInvalidAt(url, issuedAt);
    if (invalidAt == null) return null;
    final quarter = Duration(seconds: douyuUrlExpireSeconds(url)! ~/ 4);
    return invalidAt.subtract(
      quarter < _leaseRefreshLead ? quarter : _leaseRefreshLead,
    );
  }

  static void _rememberIssued(String url, DateTime at) {
    if (douyuUrlExpireSeconds(url) == null) return;
    _issuedAt.remove(url);
    _issuedAt[url] = at;
    while (_issuedAt.length > 64) {
      _issuedAt.remove(_issuedAt.keys.first);
    }
  }

  @override
  DateTime? getPlayUrlInvalidAt(String url) {
    final expire = douyuUrlExpireSeconds(url);
    if (expire == null) return null;
    return douyuPlayUrlInvalidAt(url, _issuedAt[url] ?? DateTime.now());
  }

  @override
  DateTime? getPlayUrlRefreshAt(String url) {
    final invalidAt = getPlayUrlInvalidAt(url);
    if (invalidAt == null) return null;
    final quarter = Duration(seconds: douyuUrlExpireSeconds(url)! ~/ 4);
    return invalidAt.subtract(
      quarter < _leaseRefreshLead ? quarter : _leaseRefreshLead,
    );
  }

  // ---------------------------------------------------------------- room

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async {
    try {
      final roomInfo = await _fetchRoomInfo(room.roomId);
      final fresh = parseDouyuRoomDetail(roomInfo, room.roomId);
      // Pad whatever the profile endpoint left empty with the fields
      // the room already carries, so a partial response never blanks
      // the UI.
      if (fresh.cover.isEmpty && room.cover.isNotEmpty) {
        return fresh.copyWith(cover: room.cover);
      }
      return fresh;
    } on Object {
      // UI path: a transient failure must not blank the card — return
      // the room as offline. The recovery path does NOT swallow errors.
      return room.copyWith(liveStatus: false);
    }
  }

  Future<Map<dynamic, dynamic>> _fetchRoomInfo(String roomId) async {
    final response = await _dio.get<dynamic>(
      'https://www.douyu.com/betard/$roomId',
      options: Options(
        headers: <String, String>{
          'referer': 'https://www.douyu.com/$roomId',
          'user-agent': DouyuUtils.userAgent,
        },
      ),
    );
    final decoded = _decodeJson(response.data);
    final roomInfo = decoded is Map ? decoded['room'] : null;
    if (roomInfo is! Map) {
      throw const FormatException('Douyu betard response has no room');
    }
    return roomInfo;
  }

  /// Builds a room from a betard `room` object.
  static LiveRoom parseDouyuRoomDetail(
    Map<dynamic, dynamic> roomInfo,
    String roomId,
  ) {
    final live = isLiveRoomPayload(roomInfo);
    final bizAll = roomInfo['room_biz_all'];
    final hot = bizAll is Map ? bizAll['hot'] : null;
    final resolvedId = roomInfo['room_id']?.toString() ?? roomId;
    return LiveRoom(
      roomId: resolvedId,
      platform: PlatformIds.douyu,
      cover: roomInfo['room_pic']?.toString() ?? '',
      watching: _asInt(hot) ?? 0,
      title: roomInfo['room_name']?.toString() ?? '',
      nick: roomInfo['owner_name']?.toString() ?? '',
      avatar: roomInfo['owner_avatar']?.toString() ?? '',
      liveStatus: live,
      link: 'https://www.douyu.com/$roomId',
      danmakuData: <String, dynamic>{'roomId': resolvedId},
    );
  }

  /// show_status == 1, not a replay loop, title not starting with 【回放】.
  static bool isLiveRoomPayload(Map<dynamic, dynamic> roomInfo) {
    return _asInt(roomInfo['show_status']) == 1 &&
        _asInt(roomInfo['videoLoop']) != 1 &&
        !roomInfo['room_name'].toString().startsWith('【回放】');
  }

  // ------------------------------------------------------- qualities/lines

  @override
  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async {
    final roomId = liveRoom.roomId.trim();
    final playData = await _requestPlayData(roomId);
    final cdns = parseCdnCodes(playData);
    // Pure Live 3.x comparator, verbatim: scdn* sorts LAST.
    cdns.sort((a, b) {
      if (a.startsWith("scdn") && !b.startsWith("scdn")) {
        return 1;
      } else if (!a.startsWith("scdn") && b.startsWith("scdn")) {
        return -1;
      }
      return 0;
    });
    return parsePlayQualities(playData, cdns);
  }

  /// Keeps Douyu's advertised `multirates` order. The numeric `rate` is
  /// an opaque request code (source is commonly 0), not a bitrate;
  /// sorting it numerically would reverse source and low-quality
  /// choices.
  static List<LivePlayQuality> parsePlayQualities(
    Map<String, dynamic> playData,
    List<String> cdns,
  ) {
    final qualities = <LivePlayQuality>[];
    final rates = playData['multirates'];
    if (rates is List) {
      final rateItems = rates.whereType<Map>().toList(growable: false);
      for (var index = 0; index < rateItems.length; index++) {
        final item = rateItems[index];
        final rate = _asInt(item['rate']);
        if (rate == null) continue;
        if (qualities.any(
          (quality) => quality.selectionId == rate.toString(),
        )) {
          continue;
        }
        final name = item['name']?.toString().trim() ?? '';
        qualities.add(
          LivePlayQuality(
            quality: name.isNotEmpty ? name : '默认',
            id: rate.toString(),
            sort: rateItems.length - index,
            data: DouyuPlayData(rate, List<String>.unmodifiable(cdns)),
          ),
        );
      }
    }
    if (qualities.isEmpty) {
      final rate = _asInt(playData['rate']) ?? -1;
      qualities.add(
        LivePlayQuality(
          quality: '默认',
          id: rate.toString(),
          sort: 1,
          data: DouyuPlayData(rate, List<String>.unmodifiable(cdns)),
        ),
      );
    }
    return qualities;
  }

  @override
  Future<List<String>> getPlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final resolved = await resolvePlayUrls(
      liveRoom: liveRoom,
      quality: quality,
    );
    return resolved.urls;
  }

  /// Full resolution with the server-confirmed rate + lease times.
  /// A null quality resolves the first advertised quality.
  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final effectiveQuality = quality ?? await _firstQuality(liveRoom);
    if (effectiveQuality == null) {
      return const LivePlayUrlResolution(urls: <String>[]);
    }
    return _resolvePlayUrlsRaw(liveRoom: liveRoom, quality: effectiveQuality);
  }

  Future<LivePlayQuality?> _firstQuality(LiveRoom liveRoom) async {
    final qualities = await getPlayQualities(liveRoom: liveRoom);
    return qualities.isEmpty ? null : qualities.first;
  }

  /// Recovery — MUST re-fetch all identity/token/room fields; returning
  /// cached URLs is a no-op. Re-lists qualities, keeps the requested
  /// rate against the fresh CDN set (else the first quality), and
  /// re-signs every URL.
  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsForRecovery({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final requested = quality;
    if (requested == null) {
      return resolvePlayUrls(liveRoom: liveRoom);
    }
    // Both the signed URL and advertised CDN set can change while a live
    // connection is paused. Refresh the metadata, then ask for the
    // committed rate with those current CDNs rather than reopening the
    // old URL cohort.
    final qualities = await getPlayQualities(liveRoom: liveRoom);
    if (qualities.isEmpty) {
      return const LivePlayUrlResolution(urls: <String>[]);
    }
    final requestedId = requested.selectionId;
    LivePlayQuality? matching;
    for (final item in qualities) {
      if (item.selectionId == requestedId) {
        matching = item;
        break;
      }
    }
    if (matching != null) {
      return _resolvePlayUrlsRaw(liveRoom: liveRoom, quality: matching);
    }
    final freshData = qualities.first.data;
    final requestedData = requested.data;
    if (freshData is DouyuPlayData && requestedData is DouyuPlayData) {
      // A no-longer-advertised rate can still be accepted or downgraded
      // by the server. Preserve that acknowledgement for the
      // successful-source commit; never label a fallback using only the
      // requested rate.
      return _resolvePlayUrlsRaw(
        liveRoom: liveRoom,
        quality: LivePlayQuality(
          quality: requested.quality,
          id: requested.id,
          sort: requested.sort,
          data: DouyuPlayData(requestedData.rate, freshData.cdns),
        ),
      );
    }
    return _resolvePlayUrlsRaw(liveRoom: liveRoom, quality: qualities.first);
  }

  /// Resolves one URL per CDN in parallel (per-CDN try/catch — one bad
  /// CDN must not discard the healthy alternatives), then groups the
  /// URLs by the rate each CDN actually confirmed. A single UI quality
  /// label must not cover a mixture of source and downgraded streams:
  /// prefer an acknowledged requested rate, otherwise the first
  /// acknowledged cohort in platform order.
  Future<LivePlayUrlResolution> _resolvePlayUrlsRaw({
    required LiveRoom liveRoom,
    required LivePlayQuality quality,
  }) async {
    final rawData = quality.data;
    final roomId = liveRoom.roomId.trim();
    if (rawData is! DouyuPlayData || roomId.isEmpty) {
      return const LivePlayUrlResolution(urls: <String>[]);
    }
    final data = rawData;
    final issuedAt = DateTime.now().toUtc();
    final urlsByRate = <Object?, List<String>>{};
    Object? lastError;
    final results = await Future.wait<LivePlayUrlResolution?>(
      data.cdns.map((cdn) async {
        try {
          return await _resolvePlayUrl(roomId, data.rate, cdn);
        } catch (error) {
          lastError = error;
          return null;
        }
      }),
    );
    for (final resolution in results) {
      if (resolution == null || resolution.urls.isEmpty) continue;
      final urls = urlsByRate.putIfAbsent(
        resolution.appliedQualityData,
        () => <String>[],
      );
      for (final url in resolution.urls) {
        if (!urls.contains(url)) urls.add(url);
      }
    }
    if (urlsByRate.isEmpty) {
      if (lastError != null) throw lastError!;
      return const LivePlayUrlResolution(urls: <String>[]);
    }
    final acknowledgedRates = urlsByRate.keys.whereType<int>().toList(
      growable: false,
    );
    final appliedRate = urlsByRate.containsKey(data.rate)
        ? data.rate
        : (acknowledgedRates.isEmpty ? null : acknowledgedRates.first);
    final urls = List<String>.unmodifiable(urlsByRate[appliedRate]!);
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
      appliedQualityData: appliedRate,
      qualityUnconfirmed: appliedRate == null,
      issuedAt: issuedAt,
      refreshAt: refreshAt,
      invalidAt: invalidAt,
      streamFacts: urls.map(douyuStreamFacts).toList(growable: false),
    );
  }

  /// One signed play URL for one (rate, cdn) pair.
  Future<LivePlayUrlResolution> _resolvePlayUrl(
    String roomId,
    int rate,
    String cdn,
  ) async {
    final issuedAt = DateTime.now().toUtc();
    final playData = await _requestPlayData(roomId, rate: rate, cdn: cdn);
    final rawRate = playData['rate'];
    // Unlike a bitrate, rate is an opaque integer identifier. Do not
    // truncate malformed fractions (e.g. 0.5) into a false source-quality
    // acknowledgement.
    final appliedRate =
        rawRate is num && rawRate.isFinite && rawRate == rawRate.roundToDouble()
        ? rawRate.toInt()
        : int.tryParse(rawRate?.toString().trim() ?? '');
    var url = parsePlayUrl(playData);
    // 海外/部分匿名会话会拿到 5 分钟即失效的 ws CDN 线（expire=300&fcdn=ws）；
    // 附加 expire=0 让 CDN 按默认时长签发（simple_live 同款补丁）。
    if (url.contains('expire=300') && url.contains('fcdn=ws')) {
      url = '$url&expire=0';
    }
    _rememberIssued(url, issuedAt);
    return LivePlayUrlResolution(
      urls: <String>[url],
      appliedQualityData: appliedRate != null && appliedRate >= 0
          ? appliedRate
          : null,
      qualityUnconfirmed: appliedRate == null || appliedRate < 0,
      issuedAt: issuedAt,
    );
  }

  /// Signed POST to getH5PlayV1, retried once with a forced encryption
  /// descriptor refresh (the first attempt is also the cheapest way to
  /// learn the descriptor went stale).
  Future<Map<String, dynamic>> _requestPlayData(
    String roomId, {
    int rate = -1,
    String cdn = '',
  }) async {
    if (roomId.trim().isEmpty) {
      throw const DouyuPlayApiException('room id is empty');
    }
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final sign = await _utils.sign(
          roomId,
          rate: rate,
          cdn: cdn,
          forceRefresh: attempt > 0,
        );
        final response = await _dio.post<dynamic>(
          'https://www.douyu.com/lapi/live/getH5PlayV1/$roomId',
          data: sign,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            headers: _utils.requestHeaders(roomId),
          ),
        );
        if (response.statusCode != 200) {
          throw DouyuPlayApiException('H5 play HTTP ${response.statusCode}');
        }
        return parsePlayResponse(_decodeJson(response.data));
      } catch (error) {
        lastError = error;
      }
    }
    throw DouyuPlayApiException(
      'H5 play request failed after retry',
      cause: lastError,
    );
  }

  static Map<String, dynamic> parsePlayResponse(dynamic response) {
    if (response is! Map) {
      throw const DouyuPlayApiException('H5 play response is not an object');
    }
    final errorCode =
        _asInt(response['error']) ?? _asInt(response['code']) ?? -1;
    if (errorCode != 0) {
      final message = response['msg']?.toString().trim();
      throw DouyuPlayApiException(
        'H5 play API error $errorCode'
        '${message?.isNotEmpty == true ? ': $message' : ''}',
      );
    }
    final rawData = response['data'];
    if (rawData is! Map) {
      throw const DouyuPlayApiException('H5 play response is missing data');
    }
    return Map<String, dynamic>.from(rawData);
  }

  static List<String> parseCdnCodes(Map<String, dynamic> data) {
    final result = <String>[];
    final rawCdns = data['cdnsWithName'];
    if (rawCdns is List) {
      for (final item in rawCdns.whereType<Map>()) {
        final code = item['cdn']?.toString().trim() ?? '';
        if (code.isNotEmpty && !result.contains(code)) result.add(code);
      }
    }
    final current = data['rtmp_cdn']?.toString().trim() ?? '';
    if (current.isNotEmpty && !result.contains(current)) {
      result.insert(0, current);
    }
    if (result.isEmpty) result.add('');
    return result;
  }

  static String parsePlayUrl(Map<String, dynamic> data) {
    final live = _htmlUnescape(data['rtmp_live']?.toString().trim() ?? '');
    // Some current H5 responses return a complete signed FLV address in
    // rtmp_live. It must win over the separate CDN base fields;
    // prefixing a second absolute URL produces a syntactically valid but
    // unopenable input such as
    // `https://cdn/live/https://other/live.flv`.
    if (_isPlayableUrl(live)) return live;
    // getH5PlayV1 normally separates the CDN base (`rtmp_url`, and on
    // variants `flv_url`) from the signed media path (`rtmp_live`). A
    // base URL is syntactically valid HTTP but is not an FFmpeg input.
    // Returning it early was the direct cause of "input stream address
    // format" failures.
    for (final baseKey in const <String>['rtmp_url', 'flv_url']) {
      final base = _htmlUnescape(data[baseKey]?.toString().trim() ?? '');
      if (base.isEmpty || live.isEmpty) continue;
      final combined =
          '${base.replaceFirst(RegExp(r'/+$'), '')}/${live.replaceFirst(RegExp(r'^/+'), '')}';
      if (_isPlayableUrl(combined)) return combined;
    }

    for (final key in const <String>['player_1', 'stream_url', 'url']) {
      final value = _htmlUnescape(data[key]?.toString().trim() ?? '');
      if (_isPlayableUrl(value)) return value;
    }

    // Compatibility with payloads that expose a complete FLV address
    // without rtmp_live. Require a media-looking path so a bare CDN
    // directory is never handed to the player again.
    final flvUrl = _htmlUnescape(data['flv_url']?.toString().trim() ?? '');
    if (_isDirectMediaUrl(flvUrl)) return flvUrl;
    throw const DouyuPlayApiException('H5 play response has no playable URL');
  }

  /// Declared stream facts for one resolved URL. getH5PlayV1 serves FLV;
  /// a signed path without an extension is still FLV.
  static LiveStreamFacts douyuStreamFacts(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.endsWith('.m3u8')) return const LiveStreamFacts(format: 'hls');
    if (path.endsWith('.flv')) return const LiveStreamFacts(format: 'flv');
    return const LiveStreamFacts(format: 'flv');
  }

  static bool _isPlayableUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.host.isNotEmpty &&
        const {'http', 'https', 'rtmp'}.contains(uri.scheme);
  }

  static bool _isDirectMediaUrl(String value) {
    if (!_isPlayableUrl(value)) return false;
    final path = Uri.parse(value).path.toLowerCase();
    return path.endsWith('.flv') ||
        path.endsWith('.m3u8') ||
        path.endsWith('.mp4');
  }

  /// Minimal HTML-entity unescape for signed URL fields (rtmp_live /
  /// rtmp_url may carry `&amp;`). `&amp;` is replaced last so a
  /// double-encoded value unescapes exactly once.
  static String _htmlUnescape(String value) {
    return value
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  // ------------------------------------------------------- search + lists

  @override
  Future<List<LiveArea>> getCategories({
    int page = 1,
    int pageSize = 30,
  }) async {
    final response = await _dio.get<dynamic>(
      'https://m.douyu.com/api/cate/list',
      options: Options(headers: _utils.requestHeaders()),
    );
    return parseDouyuCategories(_decodeJson(response.data));
  }

  /// Flat cate2 list (our LiveArea has no category tree).
  static List<LiveArea> parseDouyuCategories(dynamic decoded) {
    final areas = <LiveArea>[];
    final data = decoded is Map ? decoded['data'] : null;
    final subCateList = data is Map ? data['cate2Info'] : null;
    if (subCateList is! List) return areas;
    for (final item in subCateList) {
      if (item is! Map) continue;
      var pic = '';
      for (final key in const ['icon', 'smallIcon', 'pic']) {
        final url = item[key]?.toString() ?? '';
        if (url.isNotEmpty) {
          pic = url;
          break;
        }
      }
      areas.add(
        LiveArea(
          areaId: item['cate2Id']?.toString() ?? '',
          areaName: item['cate2Name']?.toString() ?? '',
          areaPic: pic,
          platform: PlatformIds.douyu,
        ),
      );
    }
    return areas;
  }

  @override
  Future<List<LiveRoom>> getRecommendRooms({
    int page = 1,
    int pageSize = 30,
  }) async {
    final response = await _dio.get<dynamic>(
      'https://www.douyu.com/japi/weblist/apinc/allpage/6/$page',
      options: Options(headers: _utils.requestHeaders()),
    );
    return parseDouyuRoomList(_decodeJson(response.data));
  }

  @override
  Future<List<LiveRoom>> getCategoryRooms(
    LiveArea area, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final response = await _dio.get<dynamic>(
      'https://www.douyu.com/gapi/rkc/directory/mixList/2_${area.areaId}/$page',
      options: Options(headers: _utils.requestHeaders()),
    );
    return parseDouyuRoomList(_decodeJson(response.data));
  }

  /// Parses `data.rl[]` — shared by getRecommendRooms and
  /// getCategoryRooms. Only `type == 1` entries are live rooms; an
  /// empty/malformed list is returned as-is, never faked.
  static List<LiveRoom> parseDouyuRoomList(dynamic decoded) {
    final items = <LiveRoom>[];
    final rl = decoded is Map && decoded['data'] is Map
        ? decoded['data']['rl']
        : null;
    if (rl is! List) return items;
    for (final item in rl) {
      if (item is! Map) continue;
      if (_asInt(item['type']) != 1) continue;
      final roomId = item['rid']?.toString() ?? '';
      final av = item['av']?.toString() ?? '';
      items.add(
        LiveRoom(
          roomId: roomId,
          platform: PlatformIds.douyu,
          cover: item['rs16']?.toString() ?? '',
          watching: _asInt(item['ol']) ?? 0,
          title: item['rn']?.toString() ?? '',
          nick: item['nn']?.toString() ?? '',
          avatar: av.isNotEmpty
              ? 'https://apic.douyucdn.cn/upload/${av}_middle.jpg'
              : '',
          liveStatus: true,
          link: 'https://www.douyu.com/$roomId',
        ),
      );
    }
    return items;
  }

  @override
  Future<List<LiveRoom>> searchRooms(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final effectivePageSize = pageSize.clamp(1, 50);
    final headers = _utils.requestHeaders()
      ..['referer'] = 'https://www.douyu.com/search/';
    final response = await _dio.get<dynamic>(
      'https://www.douyu.com/japi/search/api/searchShow',
      queryParameters: <String, dynamic>{
        'kw': keyword,
        'page': page,
        'pageSize': effectivePageSize,
      },
      options: Options(headers: headers),
    );
    final decoded = _decodeJson(response.data);
    if (decoded is! Map) return <LiveRoom>[];
    if (_asInt(decoded['error']) != 0) {
      throw Exception(decoded['msg']?.toString() ?? 'Douyu search failed');
    }
    return parseDouyuSearchRooms(decoded);
  }

  static List<LiveRoom> parseDouyuSearchRooms(Map<dynamic, dynamic> decoded) {
    final items = <LiveRoom>[];
    final queryList = decoded['data'] is Map
        ? decoded['data']['relateShow']
        : null;
    if (queryList is! List) return items;
    for (final item in queryList) {
      if (item is! Map) continue;
      final isLive =
          _asInt(item['isLive']) == 1 && _asInt(item['roomType']) == 0;
      final roomId = item['rid']?.toString() ?? '';
      items.add(
        LiveRoom(
          roomId: roomId,
          platform: PlatformIds.douyu,
          title: item['roomName']?.toString() ?? '',
          cover: item['roomSrc']?.toString() ?? '',
          nick: item['nickName']?.toString() ?? '',
          avatar: item['avatar']?.toString() ?? '',
          watching: _asInt(item['hot']) ?? 0,
          liveStatus: isLive,
          link: 'https://www.douyu.com/$roomId',
        ),
      );
    }
    return items;
  }

  @override
  Future<List<LiveRoom>> searchAnchors(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final effectivePageSize = pageSize.clamp(1, 50);
    final headers = _utils.requestHeaders()
      ..['referer'] = 'https://www.douyu.com/search/';
    final response = await _dio.get<dynamic>(
      'https://www.douyu.com/japi/search/api/searchUser',
      queryParameters: <String, dynamic>{
        'kw': keyword,
        'page': page,
        'pageSize': effectivePageSize,
        'filterType': 1,
      },
      options: Options(headers: headers),
    );
    final decoded = _decodeJson(response.data);
    if (decoded is! Map) return <LiveRoom>[];
    return parseDouyuSearchAnchors(decoded);
  }

  static List<LiveRoom> parseDouyuSearchAnchors(Map<dynamic, dynamic> decoded) {
    final items = <LiveRoom>[];
    final queryList = decoded['data'] is Map
        ? decoded['data']['relateUser']
        : null;
    if (queryList is! List) return items;
    for (final item in queryList) {
      if (item is! Map) continue;
      final anchor = item['anchorInfo'];
      if (anchor is! Map) continue;
      final isLive =
          _asInt(anchor['isLive']) == 1 && _asInt(anchor['roomType']) == 0;
      final roomId = anchor['rid']?.toString() ?? '';
      items.add(
        LiveRoom(
          roomId: roomId,
          platform: PlatformIds.douyu,
          nick: anchor['nickName']?.toString() ?? '',
          avatar: anchor['avatar']?.toString() ?? '',
          liveStatus: isLive,
          link: 'https://www.douyu.com/$roomId',
        ),
      );
    }
    return items;
  }

  @override
  Future<List<LiveMessage>> getSuperChatMessage({
    required LiveRoom liveRoom,
  }) async => <LiveMessage>[];

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

  static int? _asInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}

/// Play descriptor carried by LivePlayQuality.data: the opaque rate id
/// to request and the CDN codes to sign one URL each against.
class DouyuPlayData {
  const DouyuPlayData(this.rate, this.cdns);

  final int rate;
  final List<String> cdns;
}

class DouyuPlayApiException implements Exception {
  const DouyuPlayApiException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'DouyuPlayApiException: $message'
      : 'DouyuPlayApiException: $message ($cause)';
}
