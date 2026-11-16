// Bilibili adapter — port of Pure Live 3.x
// lib/shared/platforms/bilibili/bilibili_site.dart (1039 lines).
//
// Room detail: GET api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom
//   (WBI-signed — unsigned calls return code -352; see bilibili_wbi.dart).
// Quality+lines: GET .../xlive/web-room/v2/index/getRoomPlayInfo
//   (quality = g_qn_desc ∩ accept_qn; NEVER invent a quality the server
//   didn't confirm; current_qn kept as appliedQualityData — anonymous
//   requests get silently downgraded, e.g. 10000 -> 250, verified live
//   2026-11-16 on room 7734200; the UI must reflect the APPLIED quality).
//   Lines = url_info[] hosts for the applied qn, ordered http_stream/flv
//   first; lines are identified by URL, never by index.
// Danmaku: WBI-signed getDanmuInfo -> token + host_list into
//   LiveRoom.danmakuData (token/serverUrls/buvid/uid/cookie), consumed by
//   bilibili_danmaku.dart on connect/reconnect. Room entry does one quick
//   discovery; a failure leaves danmakuData null and playback proceeds.
//   (The danmaku transport's own unsigned fallback discovery still exists
//   in bilibili_danmaku.dart and will hit -352 — see known gap in the
//   file header of the report; the adapter path is the signed one.)
// Carousel rooms (live_status 2): getRoundPlayVideo + x/player/playurl.
//   Our LivePlayUrlResolution has no start offset, so the round-play
//   video starts at 0.
// Categories: room/v1/Area/getList (unsigned) flattens sub-areas; the
//   parent_area_id each sub-area needs for second/getList is remembered
//   in _categoryParentIds (the endpoint returns -400 without it).
//   second/getList is WBI-signed AND needs w_webid (access_id scraped
//   from live.bilibili.com/lol; an empty w_webid returns -352).
// Recommend: getListByAreaID sort=online (ranked) with the getMoreRecList
//   feed as a bounded fallback. Search: x/web-interface/search/type
//   (live / live_user), needs the buvid cookie (HTTP 412 without it).
//
// Anonymous-only: no account cookie, no DedeUserID — danmaku uid is 0.
// No Master quality tier is implemented.

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/models/live_models.dart';
import '../../../core/network/http_client.dart';
import '../live_site.dart';
import 'bilibili_danmaku.dart';
import 'bilibili_wbi.dart';

class BiliBiliSite extends LiveSite {
  BiliBiliSite({Dio? dio}) : _dio = dio ?? sharedDio();

  @override
  String get id => 'bilibili';

  @override
  String get name => '哔哩哔哩';

  @override
  LiveDanmaku getDanmaku() => BiliBiliDanmaku();

  // One shared Dio for this adapter (sharedDio(); never a second Dio).
  final Dio _dio;

  late final BilibiliWbiSigner _wbi = BilibiliWbiSigner(dio: _dio);

  static const String kDefaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36';
  static const String kDefaultReferer = 'https://live.bilibili.com/';

  String _buvid3 = '';
  String _buvid4 = '';
  Future<(String, String)>? _buvidRequest;
  String _accessId = '';
  Future<String>? _accessIdRequest;

  /// sub-area id -> parent area id, filled by getCategories. second/getList
  /// returns -400 without parent_area_id, so a category room list is only
  /// attempted when the parent is known.
  final Map<String, String> _categoryParentIds = <String, String>{};

  // ------------------------------------------------------------ headers

  Future<Map<String, String>> getHeader() async {
    final (b3, b4) = await _resolveBuvid();
    return <String, String>{
      'user-agent': kDefaultUserAgent,
      'referer': kDefaultReferer,
      'cookie': 'buvid3=$b3;buvid4=$b4;',
    };
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

  Future<(String, String)> _fetchBuvid() async {
    try {
      final response = await _dio.get<dynamic>(
        'https://api.bilibili.com/x/frontend/finger/spi',
        options: Options(headers: <String, String>{
          'user-agent': kDefaultUserAgent,
          'referer': kDefaultReferer,
        }),
      );
      final body = _decodeJson(response.data);
      final data = body is Map ? body['data'] : null;
      final b3 = data is Map ? data['b_3']?.toString() ?? '' : '';
      final b4 = data is Map ? data['b_4']?.toString() ?? '' : '';
      _buvid3 = b3;
      _buvid4 = b4;
      return (b3, b4);
    } catch (_) {
      // Anonymous requests still work without buvid on most endpoints
      // (search is the exception — it 412s); never fail the room on it.
      return ('', '');
    }
  }

  /// w_webid for second/getList, scraped from the live home page.
  Future<String> getAccessId() async {
    if (_accessId.isNotEmpty) return _accessId;
    final pending = _accessIdRequest;
    if (pending != null) return pending;

    late final Future<String> operation;
    operation = _fetchAccessId().whenComplete(() {
      if (identical(_accessIdRequest, operation)) _accessIdRequest = null;
    });
    _accessIdRequest = operation;
    return operation;
  }

  Future<String> _fetchAccessId() async {
    try {
      final response = await _dio.get<String>(
        'https://live.bilibili.com/lol',
        options: Options(
          headers: await getHeader(),
          responseType: ResponseType.plain,
        ),
      );
      final id = RegExp(
        r'"access_id":"(.*?)"',
      ).firstMatch(response.data ?? '')?.group(1)?.replaceAll('\\', '');
      _accessId = id ?? '';
      return _accessId;
    } catch (_) {
      return '';
    }
  }

  /// WBI-signed GET returning decoded JSON. [url] carries the query
  /// params; the signed map is passed as Dio queryParameters against the
  /// bare base URL so Dio encodes it exactly once.
  Future<dynamic> _getWbiJson(String url, {bool forceRefresh = false}) async {
    final headers = await getHeader();
    final signed = await _wbi.signUrl(
      url,
      forceRefresh: forceRefresh,
      headers: headers,
    );
    final base = url.split('?').first;
    final response = await _dio.get<dynamic>(
      base,
      queryParameters: signed,
      options: Options(headers: headers),
    );
    return _decodeJson(response.data);
  }

  // ------------------------------------------------------------- room

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async {
    final roomId = room.roomId.trim();
    if (roomId.isEmpty) return room;
    try {
      final roomInfo = await getRoomInfo(roomId: roomId);
      final info = roomInfo['room_info'];
      final realRoomId =
          info is Map
              ? info['room_id']?.toString() ?? roomId
              : roomId;
      Map<String, dynamic>? danmakuData;
      try {
        // Room entry must not wait through the whole chat retry chain. A
        // single quick discovery gives playback priority; the websocket
        // layer refreshes credentials when it needs them.
        final args = await _discoverDanmaku(
          int.tryParse(realRoomId) ?? 0,
          maxAttempts: 1,
        );
        danmakuData = <String, dynamic>{
          'roomId': args.roomId,
          'token': args.token,
          'serverUrls': args.serverUrls,
          'buvid': args.buvid,
          'uid': args.uid,
          'cookie': args.cookie,
        };
      } catch (_) {
        // Chat credentials are best-effort here; the danmaku transport
        // re-discovers them on connect.
        danmakuData = null;
      }
      return _buildRoom(
        roomInfo,
        roomId: roomId,
        realRoomId: realRoomId,
        danmakuData: danmakuData,
      );
    } on Object {
      // UI path: a transient failure must not blank the card — return
      // the room as offline.
      return room.copyWith(liveStatus: false);
    }
  }

  Future<Map<String, dynamic>> getRoomInfo({required String roomId}) async {
    const baseUrl =
        'https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom';
    final url = '$baseUrl?room_id=$roomId';
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final result = await _getWbiJson(url, forceRefresh: attempt > 0);
        return parseRoomInfoResponse(result);
      } catch (error) {
        lastError = error;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
        }
      }
    }
    throw StateError('Bilibili room info failed after WBI refresh: $lastError');
  }

  static Map<String, dynamic> parseRoomInfoResponse(dynamic response) {
    if (response is! Map) {
      throw const FormatException('Bilibili room response is not an object');
    }
    final code = int.tryParse(response['code']?.toString() ?? '');
    if (code != 0) {
      throw StateError('Bilibili room request rejected: code=$code');
    }
    final data = response['data'];
    if (data is! Map || data['room_info'] is! Map || data['anchor_info'] is! Map) {
      throw const FormatException('Bilibili room metadata is incomplete');
    }
    return Map<String, dynamic>.from(data);
  }

  /// Danmaku credential discovery (getDanmuInfo, WBI-signed). Retries
  /// with a forced WBI key refresh on attempts 2 and 4, as in Pure Live.
  Future<BiliBiliDanmakuArgs> _discoverDanmaku(
    int realRoomId, {
    int maxAttempts = 4,
  }) async {
    const baseUrl =
        'https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo';
    final headers = await getHeader();
    Map<String, dynamic>? data;
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final signed = await _wbi.signUrl(
          '$baseUrl?id=$realRoomId&type=0',
          forceRefresh: attempt == 1 || attempt == 3,
          headers: headers,
        );
        final response = await _dio.get<dynamic>(
          baseUrl,
          queryParameters: signed,
          options: Options(headers: headers),
        );
        final body = _decodeJson(response.data);
        final candidate = body is Map ? body['data'] : null;
        if (body is Map &&
            body['code'] == 0 &&
            candidate is Map &&
            (candidate['token']?.toString().isNotEmpty ?? false)) {
          data = Map<String, dynamic>.from(candidate);
          break;
        }
        lastError = StateError(
          'getDanmuInfo code=${body is Map ? body['code'] : 'n/a'}',
        );
      } catch (error) {
        lastError = error;
      }
      if (attempt + 1 < maxAttempts) {
        await Future<void>.delayed(
          Duration(milliseconds: 180 * (attempt + 1)),
        );
      }
    }
    if (data == null) {
      throw StateError('Bilibili danmaku discovery failed: $lastError');
    }
    return parseDanmakuArgs(
      data,
      realRoomId: realRoomId,
      buvid: _buvid3,
      cookie: headers['cookie'] ?? '',
    );
  }

  /// token + host_list -> transport args. The generic gateway has stable
  /// public DNS while some resolvers intermittently omit the regional
  /// comet records, so it is tried first and the regional nodes stay as
  /// failovers.
  static BiliBiliDanmakuArgs parseDanmakuArgs(
    Map<String, dynamic> data, {
    required int realRoomId,
    String buvid = '',
    String cookie = '',
  }) {
    const officialFallback = 'wss://broadcastlv.chat.bilibili.com/sub';
    final serverUrls = <String>[officialFallback];
    for (final item in (data['host_list'] as List?) ?? const []) {
      if (item is! Map) continue;
      final host = item['host']?.toString().trim() ?? '';
      if (host.isEmpty) continue;
      final port = int.tryParse(item['wss_port']?.toString() ?? '') ?? 443;
      final endpoint = 'wss://$host${port == 443 ? '' : ':$port'}/sub';
      if (!serverUrls.contains(endpoint)) serverUrls.add(endpoint);
    }
    return BiliBiliDanmakuArgs(
      roomId: realRoomId,
      // Anonymous-only: no account cookie, no DedeUserID — uid 0.
      uid: 0,
      token: data['token']?.toString() ?? '',
      serverUrls: serverUrls,
      buvid: buvid,
      cookie: cookie,
    );
  }

  LiveRoom _buildRoom(
    Map<String, dynamic> roomInfo, {
    required String roomId,
    required String realRoomId,
    Map<String, dynamic>? danmakuData,
  }) {
    final info = roomInfo['room_info'];
    final anchor = roomInfo['anchor_info'];
    final baseInfo = anchor is Map ? anchor['base_info'] : null;
    final infoMap = info is Map ? info : const <String, dynamic>{};
    final baseMap = baseInfo is Map ? baseInfo : const <String, dynamic>{};
    final live = _liveStatus(infoMap['live_status']) == 1;
    final face = baseMap['face']?.toString() ?? '';
    return LiveRoom(
      roomId: roomId,
      platform: PlatformIds.bilibili,
      title: infoMap['title']?.toString() ?? '',
      cover: infoMap['cover']?.toString() ?? '',
      nick: baseMap['uname']?.toString() ?? '',
      avatar: face.isEmpty ? '' : '$face@100w.jpg',
      watching: int.tryParse(infoMap['online']?.toString() ?? '') ?? 0,
      liveStatus: live,
      link: 'https://live.bilibili.com/$roomId',
      // Real (long) room id: play-info and danmaku calls resolve from it.
      data: <String, dynamic>{'realRoomId': realRoomId},
      danmakuData: danmakuData,
    );
  }

  /// 1 = live, 2 = carousel, anything else = offline.
  static int _liveStatus(Object? value) =>
      int.tryParse(value?.toString() ?? '') ?? 0;

  /// Play-info / danmaku resolve from the real room id when detail
  /// supplied it; the short id also works, so fall back to roomId.
  static String _effectiveRoomId(LiveRoom room) {
    final data = room.data;
    final real = data?['realRoomId']?.toString().trim() ?? '';
    return real.isNotEmpty ? real : room.roomId;
  }

  // ------------------------------------------------------- qualities/lines

  @override
  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async {
    final result = await _requestPlayInfo(
      roomId: _effectiveRoomId(liveRoom),
      qualityData: 0,
    );
    if (isCarouselResponse(result)) return <LivePlayQuality>[carouselQuality];
    return parsePlayQualities(result);
  }

  @override
  Future<List<String>> getPlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    return (await resolvePlayUrls(liveRoom: liveRoom, quality: quality)).urls;
  }

  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final requestedQn = _requestedQn(quality);
    final result = await _requestPlayInfo(
      roomId: _effectiveRoomId(liveRoom),
      qualityData: requestedQn,
    );
    if (isCarouselResponse(result)) return _resolveCarouselVideo(liveRoom);
    return parsePlayUrlResolution(
      result,
      requestedQualityData: requestedQn,
    );
  }

  /// Recovery — MUST re-fetch, never return cached URLs. This adapter
  /// keeps no URL cache and resolvePlayUrls issues a fresh
  /// getRoomPlayInfo on every call, so recovery is a re-resolve.
  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsForRecovery({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    return resolvePlayUrls(liveRoom: liveRoom, quality: quality);
  }

  static int _requestedQn(LivePlayQuality? quality) {
    final data = quality?.data;
    if (data is int) return data;
    return int.tryParse(data?.toString() ?? '') ??
        int.tryParse(quality?.id ?? '') ??
        0;
  }

  Future<dynamic> _requestPlayInfo({
    required String roomId,
    required Object? qualityData,
  }) async {
    final response = await _dio.get<dynamic>(
      'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo',
      queryParameters: <String, dynamic>{
        'room_id': roomId,
        'protocol': '0,1',
        'format': '0,1,2',
        'codec': '0',
        'qn': qualityData ?? 0,
        'platform': 'web',
        'ptype': '8',
        'dolby': '5',
        'panorama': '1',
        'mask': '0',
        'no_playurl': '0',
      },
      options: Options(headers: await getHeader()),
    );
    return _decodeJson(response.data);
  }

  /// Extracts only qualities accepted by at least one returned codec. The
  /// global descriptor list also contains unavailable tiers and previously
  /// produced buttons which could never resolve to a stream.
  static List<LivePlayQuality> parsePlayQualities(dynamic response) {
    final playUrl = _playUrlPayload(response);
    final descriptions = <int, String>{};
    for (final raw in (playUrl['g_qn_desc'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final qn = int.tryParse(raw['qn']?.toString() ?? '');
      if (qn == null || qn <= 0) continue;
      final description = raw['desc']?.toString().trim() ?? '';
      descriptions[qn] = description.isEmpty ? '未知清晰度' : description;
    }

    final accepted = <int>{};
    for (final payload in _codecPayloads(playUrl)) {
      for (final rawQn in (payload.codec['accept_qn'] as List?) ?? const []) {
        final qn = int.tryParse(rawQn.toString());
        if (qn != null && qn > 0) accepted.add(qn);
      }
      final current =
          int.tryParse(payload.codec['current_qn']?.toString() ?? '');
      if (current != null && current > 0) accepted.add(current);
    }

    final ordered = accepted.toList()..sort((a, b) => b.compareTo(a));
    return ordered
        .map(
          (qn) => LivePlayQuality(
            quality: descriptions[qn] ?? '未知清晰度',
            id: '$qn',
            data: qn,
            sort: qn,
          ),
        )
        .toList(growable: false);
  }

  /// Keeps the server-acknowledged `current_qn` with the URLs. Bilibili
  /// can advertise 10000/400 to a guest and still return qn=250 for every
  /// request; the caller must then keep the UI on 250 instead of
  /// pretending the tap was applied. A requested qn that comes back
  /// different is flagged qualityUnconfirmed.
  static LivePlayUrlResolution parsePlayUrlResolution(
    dynamic response, {
    required Object? requestedQualityData,
  }) {
    final playUrl = _playUrlPayload(response);
    final requestedQn = int.tryParse(requestedQualityData?.toString() ?? '');
    final candidates = <_BilibiliStreamCandidate>[];

    for (final payload in _codecPayloads(playUrl)) {
      final codec = payload.codec;
      final currentQn = int.tryParse(codec['current_qn']?.toString() ?? '');
      final baseUrl = codec['base_url']?.toString() ?? '';
      if (currentQn == null || currentQn <= 0 || baseUrl.isEmpty) continue;
      for (final rawUrl in (codec['url_info'] as List?) ?? const []) {
        if (rawUrl is! Map) continue;
        final url =
            '${rawUrl['host'] ?? ''}$baseUrl${rawUrl['extra'] ?? ''}'.trim();
        if (!url.startsWith('http')) continue;
        candidates.add(
          _BilibiliStreamCandidate(
            url: url,
            currentQn: currentQn,
            protocol: payload.protocol,
            format: payload.format,
            codec: codec['codec_name']?.toString() ?? '',
          ),
        );
      }
    }

    candidates.sort((a, b) {
      final requestedOrder =
          (b.currentQn == requestedQn ? 1 : 0)
              .compareTo(a.currentQn == requestedQn ? 1 : 0);
      if (requestedOrder != 0) return requestedOrder;
      final protocolOrder =
          _protocolRank(a.protocol).compareTo(_protocolRank(b.protocol));
      if (protocolOrder != 0) return protocolOrder;
      final formatOrder =
          _formatRank(a.format).compareTo(_formatRank(b.format));
      if (formatOrder != 0) return formatOrder;
      final codecOrder = _codecRank(a.codec).compareTo(_codecRank(b.codec));
      if (codecOrder != 0) return codecOrder;
      final cdnOrder =
          (a.url.contains('mcdn') ? 1 : 0).compareTo(
            b.url.contains('mcdn') ? 1 : 0,
          );
      if (cdnOrder != 0) return cdnOrder;
      return a.url.compareTo(b.url);
    });

    final downgraded =
        requestedQn != null && requestedQn > 0;
    if (candidates.isEmpty) {
      return LivePlayUrlResolution(
        urls: const [],
        appliedQualityData: requestedQualityData,
        qualityUnconfirmed: downgraded,
      );
    }
    final appliedQn = candidates.first.currentQn;
    final seen = <String>{};
    final urls = <String>[];
    final facts = <LiveStreamFacts>[];
    for (final candidate in candidates) {
      if (candidate.currentQn != appliedQn || !seen.add(candidate.url)) {
        continue;
      }
      urls.add(candidate.url);
      final codec = candidate.codec.toLowerCase();
      facts.add(
        LiveStreamFacts(
          format: _streamFormatOf(candidate.format, candidate.url),
          codec: codec.isEmpty ? null : codec,
        ),
      );
    }
    return LivePlayUrlResolution(
      urls: List.unmodifiable(urls),
      appliedQualityData: appliedQn,
      qualityUnconfirmed:
          downgraded && requestedQn != appliedQn,
      issuedAt: DateTime.now().toUtc(),
      streamFacts: facts,
    );
  }

  static String _streamFormatOf(String format, String url) {
    final normalized = format.toLowerCase();
    if (normalized == 'flv') return 'flv';
    if (normalized == 'hls' || url.toLowerCase().contains('.m3u8')) {
      return 'hls';
    }
    return 'other';
  }

  static Map<dynamic, dynamic> _playUrlPayload(dynamic response) {
    if (response is! Map) {
      throw const FormatException('Bilibili play response is not an object');
    }
    if (response['code'] != 0) {
      throw StateError(
        'Bilibili play API code=${response['code']}: ${response['message']}',
      );
    }
    final data = response['data'];
    final playUrlInfo = data is Map ? data['playurl_info'] : null;
    final playUrl = playUrlInfo is Map ? playUrlInfo['playurl'] : null;
    if (playUrl is! Map) {
      throw const FormatException('Bilibili playurl payload is missing');
    }
    return playUrl;
  }

  static Iterable<
    ({Map<dynamic, dynamic> codec, String format, String protocol})
  >
  _codecPayloads(Map<dynamic, dynamic> playUrl) sync* {
    for (final rawStream in (playUrl['stream'] as List?) ?? const []) {
      if (rawStream is! Map) continue;
      final protocol = rawStream['protocol_name']?.toString() ?? '';
      for (final rawFormat in (rawStream['format'] as List?) ?? const []) {
        if (rawFormat is! Map) continue;
        final format = rawFormat['format_name']?.toString() ?? '';
        for (final rawCodec in (rawFormat['codec'] as List?) ?? const []) {
          if (rawCodec is Map) {
            yield (codec: rawCodec, format: format, protocol: protocol);
          }
        }
      }
    }
  }

  static int _protocolRank(String value) =>
      value == 'http_stream' ? 0 : 1;
  static int _formatRank(String value) => switch (value) {
    'flv' => 0,
    'ts' => 1,
    'fmp4' => 2,
    _ => 3,
  };
  static int _codecRank(String value) => value == 'avc' ? 0 : 1;

  // ------------------------------------------------------------ carousel

  static const String carouselQualityId = 'carousel';

  static final LivePlayQuality carouselQuality = LivePlayQuality(
    quality: '轮播',
    id: carouselQualityId,
    data: carouselQualityId,
  );

  static bool isCarouselResponse(dynamic response) {
    if (response is! Map || response['code'] != 0) return false;
    final data = response['data'];
    if (data is! Map || data['playurl_info'] != null) return false;
    return _liveStatus(data['live_status']) == 2;
  }

  Future<LivePlayUrlResolution> _resolveCarouselVideo(
    LiveRoom liveRoom,
  ) async {
    final headers = await getHeader();
    final round = await _dio.get<dynamic>(
      'https://api.live.bilibili.com/live/getRoundPlayVideo',
      queryParameters: <String, dynamic>{
        'room_id': _effectiveRoomId(liveRoom),
      },
      options: Options(headers: headers),
    );
    final video = parseRoundPlayVideo(_decodeJson(round.data));
    final play = await _dio.get<dynamic>(
      'https://api.bilibili.com/x/player/playurl',
      queryParameters: <String, dynamic>{
        'bvid': video.bvid,
        'cid': '${video.cid}',
        'qn': '80',
        'fnval': '0',
        'fnver': '0',
        'fourk': '1',
        'platform': 'html5',
        'high_quality': '1',
      },
      options: Options(headers: headers),
    );
    final urls = parseVideoPlayUrls(_decodeJson(play.data));
    if (urls.isEmpty) {
      throw const FormatException('Bilibili 轮播视频没有可播放地址');
    }
    return LivePlayUrlResolution(
      urls: urls,
      appliedQualityData: carouselQualityId,
      issuedAt: DateTime.now().toUtc(),
      streamFacts:
          urls
              .map((_) => const LiveStreamFacts(format: 'other'))
              .toList(growable: false),
    );
  }

  static ({String bvid, int cid}) parseRoundPlayVideo(dynamic response) {
    if (response is! Map) {
      throw const FormatException(
        'Bilibili round play response is not an object',
      );
    }
    if (response['code'] != 0) {
      throw StateError(
        'Bilibili getRoundPlayVideo code=${response['code']}: '
        '${response['message']}',
      );
    }
    final data = response['data'];
    final bvid = data is Map ? (data['bvid']?.toString().trim() ?? '') : '';
    final cid =
        data is Map ? (int.tryParse(data['cid']?.toString() ?? '') ?? 0) : 0;
    if (!_bvidPattern.hasMatch(bvid) || cid <= 0) {
      throw const FormatException('Bilibili getRoundPlayVideo: 没有正在轮播的视频');
    }
    return (bvid: bvid, cid: cid);
  }

  static final RegExp _bvidPattern = RegExp(r'^BV[0-9A-Za-z]{10}$');

  static List<String> parseVideoPlayUrls(dynamic response) {
    if (response is! Map) {
      throw const FormatException('Bilibili video play response is not an object');
    }
    if (response['code'] != 0) {
      throw StateError(
        'Bilibili x/player/playurl code=${response['code']}: '
        '${response['message']}',
      );
    }
    final data = response['data'];
    final urls = <String>[];
    if (data is Map) {
      for (final part in (data['durl'] as List?) ?? const []) {
        if (part is! Map) continue;
        for (final raw in [
          part['url'],
          ...(part['backup_url'] as List? ?? const []),
        ]) {
          final url = raw?.toString().trim() ?? '';
          if (!url.startsWith('http')) continue;
          if (!urls.contains(url)) urls.add(url);
        }
      }
    }
    return List.unmodifiable(urls);
  }

  // ------------------------------------------------------- recommend/list

  @override
  Future<List<LiveRoom>> getRecommendRooms({
    int page = 1,
    int pageSize = 30,
  }) async {
    const rankedUrl =
        'https://api.live.bilibili.com/room/v1/Area/getListByAreaID';
    Object? rankedError;

    // `webMain/getMoreRecList` is a recommendation feed: its `online`
    // values are deliberately not ordered. The Popular page promises a
    // heat ranking, so prefer the anonymous endpoint whose contract
    // includes sort=online.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _dio.get<dynamic>(
          rankedUrl,
          queryParameters: <String, dynamic>{
            'areaId': 0,
            'parent_area_id': 0,
            'sort': 'online',
            'pageSize': pageSize.clamp(1, 30),
            'page': page,
          },
          options: Options(headers: await getHeader()),
        );
        return parseRecommendRooms(_decodeJson(response.data));
      } catch (error) {
        rankedError = error;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
        }
      }
    }

    // Keep the recommendation feed only as a bounded availability
    // fallback. Local sorting still makes its displayed heat order
    // truthful.
    try {
      final response = await _dio.get<dynamic>(
        'https://api.live.bilibili.com/xlive/web-interface/v1/webMain/getMoreRecList',
        queryParameters: <String, dynamic>{'platform': 'web', 'page': page},
        options: Options(headers: await getHeader()),
      );
      return parseRecommendRooms(_decodeJson(response.data));
    } catch (fallbackError) {
      throw Exception(
        'Bilibili recommend failed: ranked=$rankedError; '
        'fallback=$fallbackError',
      );
    }
  }

  /// Parses both the current webMain response and the legacy anonymous
  /// fallback. Kept pure so response-shape regressions can be unit tested.
  static List<LiveRoom> parseRecommendRooms(dynamic response) {
    if (response is! Map) {
      throw const FormatException('Bilibili response is not an object');
    }
    if (response['code'] != 0) {
      throw StateError(
        'Bilibili API code=${response['code']}: ${response['message']}',
      );
    }

    final data = response['data'];
    final dynamic rawList = data is Map ? data['recommend_room_list'] : data;
    if (rawList is! List) {
      throw const FormatException('Bilibili recommendation list is missing');
    }

    final rooms =
        rawList
            .whereType<Map>()
            .map((raw) {
              final roomId =
                  (raw['roomid'] ?? raw['room_id'])?.toString() ?? '';
              final cover = normalizeNetworkImageUrl(
                (raw['cover'] ?? raw['user_cover'])?.toString(),
              );
              return LiveRoom(
                roomId: roomId,
                platform: PlatformIds.bilibili,
                title: raw['title']?.toString() ?? '',
                cover: cover.isEmpty ? '' : '$cover@400w.jpg',
                nick: raw['uname']?.toString() ?? '',
                avatar: normalizeNetworkImageUrl(raw['face']?.toString()),
                watching:
                    int.tryParse(raw['online']?.toString() ?? '') ?? 0,
                liveStatus: true,
              );
            })
            .where((room) => room.roomId.isNotEmpty)
            .toList(growable: false);
    return sortRoomsByPopularity(rooms);
  }

  /// Bilibili's list payload can be a recommendation snapshot, and even
  /// the ranked endpoint can contain small adjacent inversions while heat
  /// changes. Re-sort the values shown on the cards and use room identity
  /// for stable ties so the visible ranking is always deterministic.
  static List<LiveRoom> sortRoomsByPopularity(Iterable<LiveRoom> rooms) {
    final result = rooms.toList(growable: false);
    result.sort((left, right) {
      final byWatching = right.watching.compareTo(left.watching);
      if (byWatching != 0) return byWatching;
      return left.roomId.compareTo(right.roomId);
    });
    return result;
  }

  // ----------------------------------------------------------- categories

  @override
  Future<List<LiveArea>> getCategories({
    int page = 1,
    int pageSize = 30,
  }) async {
    final response = await _dio.get<dynamic>(
      'https://api.live.bilibili.com/room/v1/Area/getList',
      queryParameters: <String, dynamic>{
        'need_entrance': 1,
        'parent_id': 0,
      },
      options: Options(headers: await getHeader()),
    );
    return parseCategories(
      _decodeJson(response.data),
      parentIds: _categoryParentIds,
    );
  }

  /// Flattens the parent -> sub-area tree into sub-areas and records each
  /// sub-area's parent id for getCategoryRooms. Kept pure so the mapping
  /// can be unit tested.
  static List<LiveArea> parseCategories(
    dynamic response, {
    Map<String, String>? parentIds,
  }) {
    if (response is! Map) {
      throw const FormatException('Bilibili response is not an object');
    }
    if (response['code'] != 0) {
      throw StateError(
        'Bilibili API code=${response['code']}: ${response['message']}',
      );
    }
    final areas = <LiveArea>[];
    for (final item in (response['data'] as List?) ?? const []) {
      if (item is! Map) continue;
      final parentId = item['id']?.toString() ?? '';
      for (final subItem in (item['list'] as List?) ?? const []) {
        if (subItem is! Map) continue;
        final areaId = subItem['id']?.toString() ?? '';
        if (areaId.isEmpty) continue;
        parentIds?[areaId] = parentId;
        final pic = normalizeNetworkImageUrl(subItem['pic']?.toString());
        areas.add(
          LiveArea(
            areaId: areaId,
            areaName: subItem['name']?.toString() ?? '',
            areaPic: pic.isEmpty ? '' : '$pic@100w.png',
            platform: PlatformIds.bilibili,
          ),
        );
      }
    }
    return areas;
  }

  @override
  Future<List<LiveRoom>> getCategoryRooms(
    LiveArea area, {
    int page = 1,
    int pageSize = 30,
  }) async {
    if (_categoryParentIds.isEmpty) {
      try {
        await getCategories();
      } catch (_) {
        // Fall through: an unknown parent yields an empty list below
        // rather than a request the server rejects (-400).
      }
    }
    final parentId = _categoryParentIds[area.areaId];
    if (parentId == null) return const <LiveRoom>[];
    const baseUrl =
        'https://api.live.bilibili.com/xlive/web-interface/v1/second/getList';
    final url =
        '$baseUrl?platform=web&parent_area_id=$parentId'
        '&area_id=${area.areaId}&sort_type=online&page=$page'
        '&w_webid=${await getAccessId()}';
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final result = await _getWbiJson(url, forceRefresh: attempt > 0);
        return parseCategoryRooms(result);
      } catch (error) {
        lastError = error;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
        }
      }
    }
    throw StateError('Bilibili category rooms failed: $lastError');
  }

  static List<LiveRoom> parseCategoryRooms(dynamic response) {
    if (response is! Map) {
      throw const FormatException('Bilibili response is not an object');
    }
    if (response['code'] != 0) {
      throw StateError(
        'Bilibili API code=${response['code']}: ${response['message']}',
      );
    }
    final data = response['data'];
    final list = data is Map ? data['list'] : null;
    if (list is! List) {
      throw const FormatException('Bilibili category list is missing');
    }
    final rooms =
        list
            .whereType<Map>()
            .map((item) {
              final cover = normalizeNetworkImageUrl(
                item['cover']?.toString(),
              );
              return LiveRoom(
                roomId: item['roomid']?.toString() ?? '',
                platform: PlatformIds.bilibili,
                title: item['title']?.toString() ?? '',
                cover: cover.isEmpty ? '' : '$cover@400w.jpg',
                nick: item['uname']?.toString() ?? '',
                avatar: normalizeNetworkImageUrl(item['face']?.toString()),
                watching:
                    int.tryParse(item['online']?.toString() ?? '') ?? 0,
                liveStatus: true,
              );
            })
            .where((room) => room.roomId.isNotEmpty)
            .toList(growable: false);
    return sortRoomsByPopularity(rooms);
  }

  // --------------------------------------------------------------- search

  @override
  Future<List<LiveRoom>> searchRooms(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final response = await _dio.get<dynamic>(
      'https://api.bilibili.com/x/web-interface/search/type',
      queryParameters: <String, dynamic>{
        'context': '',
        'search_type': 'live',
        'cover_type': 'user_cover',
        'order': '',
        'keyword': keyword,
        'category_id': '',
        '__refresh__': '',
        '_extra': '',
        'highlight': 0,
        'single_column': 0,
        'page': page,
        'page_size': pageSize.clamp(1, 50),
      },
      options: Options(headers: await getHeader()),
    );
    return parseSearchRooms(_decodeJson(response.data));
  }

  static List<LiveRoom> parseSearchRooms(dynamic response) {
    if (response is! Map) {
      throw const FormatException('Bilibili response is not an object');
    }
    if (response['code'] != 0) {
      throw StateError(
        'Bilibili API code=${response['code']}: ${response['message']}',
      );
    }
    final data = response['data'];
    final result = data is Map ? data['result'] : null;
    final queryList = result is Map ? result['live_room'] : null;
    final rooms = <LiveRoom>[];
    for (final item in (queryList as List?) ?? const []) {
      if (item is! Map) continue;
      final liveStatus = int.tryParse(item['live_status']?.toString() ?? '');
      rooms.add(
        LiveRoom(
          roomId: item['roomid']?.toString() ?? '',
          platform: PlatformIds.bilibili,
          title: _stripEmTags(item['title']?.toString() ?? ''),
          cover: _searchCover(item['cover']),
          nick: item['uname']?.toString() ?? '',
          avatar: _searchCover(item['uface']),
          watching: int.tryParse(item['online']?.toString() ?? '') ?? 0,
          liveStatus: liveStatus == 1,
        ),
      );
    }
    return rooms.where((room) => room.roomId.isNotEmpty).toList();
  }

  @override
  Future<List<LiveRoom>> searchAnchors(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final response = await _dio.get<dynamic>(
      'https://api.bilibili.com/x/web-interface/search/type',
      queryParameters: <String, dynamic>{
        'context': '',
        'search_type': 'live_user',
        'cover_type': 'user_cover',
        'order': '',
        'keyword': keyword,
        'category_id': '',
        '__refresh__': '',
        '_extra': '',
        'highlight': 0,
        'single_column': 0,
        'page': page,
        'page_size': pageSize.clamp(1, 50),
      },
      options: Options(headers: await getHeader()),
    );
    return parseSearchAnchors(_decodeJson(response.data));
  }

  static List<LiveRoom> parseSearchAnchors(dynamic response) {
    if (response is! Map) {
      throw const FormatException('Bilibili response is not an object');
    }
    if (response['code'] != 0) {
      throw StateError(
        'Bilibili API code=${response['code']}: ${response['message']}',
      );
    }
    final data = response['data'];
    final result = data is Map ? data['result'] : null;
    final anchors = <LiveRoom>[];
    for (final item in (result as List?) ?? const []) {
      if (item is! Map) continue;
      final isLive = item['is_live'];
      final live = isLive == true || isLive == 1 || isLive == '1';
      anchors.add(
        LiveRoom(
          roomId: item['roomid']?.toString() ?? '',
          platform: PlatformIds.bilibili,
          nick: _stripEmTags(item['uname']?.toString() ?? ''),
          avatar: _searchCover(item['uface']),
          liveStatus: live,
        ),
      );
    }
    return anchors.where((room) => room.roomId.isNotEmpty).toList();
  }

  // -------------------------------------------------------------- helpers

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

  /// Port of Pure Live's normalizeNetworkImageUrl (core/network/
  /// network_image_url.dart): protocol-relative links get https:, bare
  /// hosts get https://, anything else unusable becomes ''.
  static String normalizeNetworkImageUrl(String? source) {
    var value = source?.trim() ?? '';
    if (value.isEmpty || value.toLowerCase() == 'null') return '';

    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).trim();
    }
    if (value.isEmpty) return '';
    if (value.startsWith('//')) return 'https:$value';

    final uri = Uri.tryParse(value);
    if (uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty) {
      return value;
    }
    if (!value.contains(' ') &&
        RegExp(r'^[\w.-]+\.[a-zA-Z]{2,}([/:?#]|$)').hasMatch(value)) {
      return 'https://$value';
    }
    return '';
  }

  static final RegExp _emTagPattern = RegExp(r'<.*?em.*?>');

  /// Search results highlight the keyword with <em class="keyword">…
  /// tags; strip them (Pure Live strips the title; the area name gets
  /// the same treatment because it is shown in the UI too).
  static String _stripEmTags(String value) =>
      value.replaceAll(_emTagPattern, '');

  /// Search cover/uface: protocol-relative ('//i0.hdslb.com/…') -> https.
  static String _searchCover(Object? raw) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) return '';
    final withScheme = value.startsWith('//') ? 'https:$value' : value;
    return '$withScheme@400w.jpg';
  }
}

class _BilibiliStreamCandidate {
  const _BilibiliStreamCandidate({
    required this.url,
    required this.currentQn,
    required this.protocol,
    required this.format,
    required this.codec,
  });

  final String url;
  final int currentQn;
  final String protocol;
  final String format;
  final String codec;
}
