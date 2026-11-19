// Douyin adapter — port of Pure Live 3.x
// lib/shared/platforms/douyin/douyin_site.dart (981 lines).
//
// Two ids: short web_rid (<= 16 chars) vs long numeric roomId.
// `_resolveDetail` dispatches on length: web_rid -> `webcast/room/web/enter`
// (A-Bogus-signed via DouyinUtils.buildRequestUrl), HTML fallback on
// failure; roomId -> `webcast.amemv.com/webcast/room/reflow/info/`.
// `room.status == 2` => live; `room.stream_url` is stored as
// LiveRoom.data, and the danmaku credentials (webRid, long roomId,
// anonymous user id, cookie) as LiveRoom.danmakuData.
//
// Quality+lines: `stream_url.flv_pull_url` + `hls_pull_url_map`, joined by
// quality key (ORIGIN/FULL_HD1/HD1/SD2/SD1...), never by position; sorted
// by sdk_params level / known key rank, NOT v_bit_rate; lines = the FLV +
// HLS URLs of the same quality merged; switching quality needs no
// re-signing (plain pull URLs). No quality is invented: only keys the
// server returned become menu entries, and the audio-only `ao` variant is
// excluded. LiveStreamFacts carry the declared format (flv/hls) per URL
// so the player decides from facts, never from the platform.
//
// Search: DouyinSearch (live API -> general API -> partition search).
// searchAnchors reuses searchRooms (P1-19): Douyin has no anchor-search
// API, and the old implementation threw — which breaks any
// cross-platform unified search that calls searchAnchors on all 5
// platforms. A room result already carries its anchor (owner
// nickname/avatar + roomId + liveStatus), so it doubles as an anchor
// result, the same shape Kuaishou returns from both searches.
// Recommend: `webcast/feed/` (both response generations parsed).
// Categories: homepage `categoryData` scrape; areaId "id,type".
//
// Danmaku: WS requires the ttwid cookie — the transport in
// douyin_danmaku.dart handles it via the native WS util; untouched here.
// getDanmaku() returns DouyinDanmaku.
//
// Error policy (mirrors HuyaSite): getRoomDetail never throws — a
// transient failure returns the room as offline. The strict loader
// (_loadRoomDetail) throws so recovery callers see the real error.
// List methods return [] on failure, never fake rooms.

import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../../core/models/live_models.dart';
import '../../../core/network/http_client.dart';
import '../live_site.dart';
import 'douyin_audience.dart';
import 'douyin_danmaku.dart';
import 'douyin_request_params.dart';
import 'douyin_search.dart';
import 'douyin_utils.dart';

class DouyinSite extends LiveSite {
  DouyinSite({Dio? dio}) : _dio = dio ?? sharedDio() {
    _search = DouyinSearch(dio: _dio);
  }

  @override
  String get id => 'douyin';

  @override
  String get name => '抖音';

  @override
  LiveDanmaku getDanmaku() => DouyinDanmaku();

  final Dio _dio;
  late final DouyinSearch _search;

  static const String _defaultReferer = 'https://live.douyin.com';
  static const String _defaultAuthority = 'live.douyin.com';

  Map<String, String> get _baseHeaders => <String, String>{
        'Authority': _defaultAuthority,
        'Referer': _defaultReferer,
        'User-Agent': DouyinRequestParams.kDefaultUserAgent,
      };

  String _cookie = '';
  Future<String>? _anonymousCookieRequest;

  /// Current web clients use a 19-digit anonymous visitor ID. One ID per
  /// process so switching rooms does not create a new viewer identity.
  static final String _anonymousUserUniqueId =
      generateAnonymousUserUniqueId();

  /// Mirrors the numeric visitor-ID range produced by Douyin's current web
  /// client: 7.3e18 (inclusive) through 8e18 (exclusive).
  static String generateAnonymousUserUniqueId({Random? random}) {
    final source = random ?? Random.secure();
    final value = StringBuffer('7')..write(3 + source.nextInt(7));
    for (var i = 0; i < 17; i++) {
      value.write(source.nextInt(10));
    }
    return value.toString();
  }

  Future<Map<String, String>> getRequestHeaders() async {
    try {
      if (_cookie.isNotEmpty) {
        return <String, String>{..._baseHeaders, 'Cookie': _cookie};
      }
      final anonymousCookie =
          await (_anonymousCookieRequest ??= _fetchAnonymousCookie());
      _anonymousCookieRequest = null;
      if (anonymousCookie.isNotEmpty) {
        _cookie = anonymousCookie;
        return <String, String>{..._baseHeaders, 'Cookie': _cookie};
      }
      return Map<String, String>.from(_baseHeaders);
    } catch (_) {
      _anonymousCookieRequest = null;
      return Map<String, String>.from(_baseHeaders);
    }
  }

  Future<String> _fetchAnonymousCookie() async {
    final response = await _dio.get<dynamic>(
      'https://live.douyin.com/',
      queryParameters: const {'from_nav': '1'},
      options: Options(headers: _baseHeaders),
    );
    final setCookieValues =
        response.headers.map['set-cookie'] ?? const <String>[];
    final pairs = <String>[];
    for (final value in setCookieValues) {
      final pair = value.split(';').first.trim();
      if (pair.startsWith('ttwid=') || pair.startsWith('UIFID_TEMP=')) {
        pairs.add(pair);
      }
    }
    return pairs.join('; ');
  }

  // ---------------------------------------------------------------- room

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async {
    final roomId = room.roomId.trim();
    if (roomId.isEmpty) return room.copyWith(liveStatus: false);
    try {
      final fresh = await _resolveDetail(roomId);
      // Pad whatever the detail fetch left empty with the fields the room
      // already carries, so a partial response never blanks the UI.
      var padded = fresh;
      if ((padded.cover.isEmpty) && room.cover.isNotEmpty) {
        padded = padded.copyWith(cover: room.cover);
      }
      if (padded.nick.isEmpty && room.nick.isNotEmpty) {
        padded = padded.copyWith(nick: room.nick);
      }
      if (padded.avatar.isEmpty && room.avatar.isNotEmpty) {
        padded = padded.copyWith(avatar: room.avatar);
      }
      return padded;
    } on Object {
      // UI path: a transient failure must not blank the card — return the
      // room as offline. The recovery path below does NOT swallow errors.
      return room.copyWith(liveStatus: false);
    }
  }

  /// Strict room load: throws when no parseable playback metadata is
  /// available (recovery callers must see the transient error, never a
  /// disguised "offline").
  Future<LiveRoom> _loadRoomDetail(String roomId) async {
    final trimmed = roomId.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Douyin room id is empty');
    }
    return _resolveDetail(trimmed);
  }

  Future<LiveRoom> _resolveDetail(String roomId) async {
    if (roomId.length <= 16) {
      return getRoomDetailByWebRid(roomId);
    }
    return getRoomDetailByRoomId(roomId);
  }

  Future<LiveRoom> getRoomDetailByRoomId(String roomId) async {
    final result = await _getJson(
      'https://webcast.amemv.com/webcast/room/reflow/info/',
      queryParameters: <String, dynamic>{
        'type_id': 0,
        'live_id': 1,
        'room_id': roomId,
        'sec_user_id': '',
        'version_code': '99.99.99',
        'app_id': 6383,
      },
      headers: await getRequestHeaders(),
    );
    final data = _asMap(result['data']);
    final room = _asMap(data?['room']);
    if (room == null) {
      throw const FormatException('Douyin reflow/info has no room');
    }
    final owner = _asMap(room['owner']) ?? const <String, dynamic>{};
    final webRid = _firstText([owner['web_rid']]);
    if (webRid.isEmpty) {
      throw const FormatException('Douyin reflow/info has no web_rid');
    }
    final status = int.tryParse(room['status']?.toString() ?? '') ?? 0;
    if (status == 4) {
      // Ended/replay placeholder: resolve through the web_rid path.
      return getRoomDetailByWebRid(webRid);
    }
    final roomStatus = status == 2;
    final headers = await getRequestHeaders();
    return LiveRoom(
      roomId: webRid,
      title: _firstText([room['title']]),
      cover: roomStatus ? _firstImageUrl([room['cover']]) : '',
      nick: _firstText([owner['nickname']]),
      avatar: _firstImageUrl([owner['avatar_thumb']]),
      watching: roomStatus ? douyinWatching(room) : 0,
      liveStatus: roomStatus,
      link: 'https://live.douyin.com/$webRid',
      platform: 'douyin',
      danmakuData: <String, dynamic>{
        'webRid': webRid,
        'roomId': roomId,
        'userId': _anonymousUserUniqueId,
        'cookie': headers['Cookie'] ?? '',
      },
      data: roomStatus ? _asMap(room['stream_url']) : const <String, dynamic>{},
    );
  }

  Future<LiveRoom> getRoomDetailByWebRid(String webRid) async {
    try {
      return await _getRoomDetailByWebRidApi(webRid);
    } catch (_) {
      // API path failed — fall back to the room-page HTML scrape.
    }
    return _getRoomDetailByWebRidHtml(webRid);
  }

  Future<LiveRoom> _getRoomDetailByWebRidApi(String webRid) async {
    final data = await _getRoomDataByApi(webRid);
    final list = data['data'];
    if (list is! List || list.isEmpty) {
      throw const FormatException('Douyin room enter has no room data');
    }
    final roomData = _asMap(list.first);
    if (roomData == null) {
      throw const FormatException('Douyin room enter has no room data');
    }
    final userData = _asMap(data['user']) ?? const <String, dynamic>{};
    final roomId = _firstText([roomData['id_str']]);
    if (roomId.isEmpty) {
      throw const FormatException('Douyin room enter has no room id');
    }
    final owner = _asMap(roomData['owner']) ?? const <String, dynamic>{};
    final roomStatus = _douyinIsLive(roomData, data);
    final headers = await getRequestHeaders();
    return LiveRoom(
      roomId: webRid,
      title: _firstText([roomData['title']]),
      cover: roomStatus ? _firstImageUrl([roomData['cover']]) : '',
      nick: roomStatus
          ? _firstText([owner['nickname']])
          : _firstText([userData['nickname']]),
      avatar: roomStatus
          ? _firstImageUrl([owner['avatar_thumb']])
          : _firstImageUrl([userData['avatar_thumb']]),
      watching: roomStatus ? douyinWatching(roomData) : 0,
      liveStatus: roomStatus,
      link: 'https://live.douyin.com/$webRid',
      platform: 'douyin',
      danmakuData: <String, dynamic>{
        'webRid': webRid,
        'roomId': roomId,
        'userId': _anonymousUserUniqueId,
        'cookie': headers['Cookie'] ?? '',
      },
      data: roomStatus
          ? _asMap(roomData['stream_url'])
          : const <String, dynamic>{},
    );
  }

  Future<LiveRoom> _getRoomDetailByWebRidHtml(String webRid) async {
    final detail = await _getRoomDataByHtml(webRid);
    final roomStore = _asMap(detail['roomStore']);
    final roomInfo = _asMap(roomStore?['roomInfo']);
    final room = _asMap(roomInfo?['room']);
    if (room == null) {
      throw const FormatException('Douyin room HTML has no room info');
    }
    final owner = _asMap(room['owner']) ?? const <String, dynamic>{};
    final anchor = _asMap(roomInfo?['anchor']) ?? const <String, dynamic>{};
    final realRoomId = _firstText([room['id_str']]);
    final userStore = _asMap(detail['userStore']);
    final odin = _asMap(userStore?['odin']);
    final rawUserUniqueId = odin?['user_unique_id']?.toString() ?? '';
    final userUniqueId = RegExp(r'^\d{19}$').hasMatch(rawUserUniqueId)
        ? rawUserUniqueId
        : _anonymousUserUniqueId;
    final roomStatus = int.tryParse(room['status']?.toString() ?? '') == 2;
    final headers = await getRequestHeaders();
    return LiveRoom(
      roomId: webRid,
      title: _firstText([room['title']]),
      cover: roomStatus ? _firstImageUrl([room['cover']]) : '',
      nick: roomStatus
          ? _firstText([owner['nickname']])
          : _firstText([anchor['nickname']]),
      avatar: roomStatus
          ? _firstImageUrl([owner['avatar_thumb']])
          : _firstImageUrl([anchor['avatar_thumb']]),
      watching: roomStatus ? douyinWatching(room) : 0,
      liveStatus: roomStatus,
      link: 'https://live.douyin.com/$webRid',
      platform: 'douyin',
      danmakuData: <String, dynamic>{
        'webRid': webRid,
        'roomId': realRoomId,
        'userId': userUniqueId,
        'cookie': headers['Cookie'] ?? '',
      },
      data: roomStatus
          ? _asMap(room['stream_url'])
          : const <String, dynamic>{},
    );
  }

  Future<Map<String, dynamic>> _getRoomDataByApi(String webRid) async {
    final requestHeaders = await getRequestHeaders();
    final queryParams = <String, dynamic>{
      'app_name': 'douyin_web',
      'enter_from': 'web_live',
      'live_id': '1',
      'web_rid': webRid,
      'is_need_double_stream': 'false',
    };
    final targetUrl = DouyinUtils.buildRequestUrl(
      'https://live.douyin.com/webcast/room/web/enter/',
      queryParams,
    );
    final result = await _getJson(targetUrl, headers: requestHeaders);
    final data = _asMap(result['data']);
    if (data == null) {
      throw const FormatException('Douyin room enter has no data');
    }
    return data;
  }

  Future<Map<String, dynamic>> _getRoomDataByHtml(String webRid) async {
    final dyCookie = await _getWebCookie(webRid);
    final response = await _dio.get<String>(
      'https://live.douyin.com/$webRid',
      options: Options(
        headers: <String, String>{
          'Authority': _defaultAuthority,
          'Referer': _defaultReferer,
          'Cookie': dyCookie,
          'User-Agent': DouyinRequestParams.kDefaultUserAgent,
        },
        responseType: ResponseType.plain,
      ),
    );
    final result = response.data ?? '';
    final renderData =
        RegExp(r'\{\\"state\\":\{\\"appStore.*?\]\\n').firstMatch(result)?.group(0) ??
            '';
    if (renderData.isEmpty) {
      throw const FormatException('Douyin room HTML has no render data');
    }
    final str = renderData
        .trim()
        .replaceAll('\\"', '"')
        .replaceAll(r'\\', r'\')
        .replaceAll(']\\n', '');
    final renderDataJson = _decodeJson(str);
    final state = renderDataJson is Map ? _asMap(renderDataJson['state']) : null;
    if (state == null) {
      throw const FormatException('Douyin room HTML has no state');
    }
    return state;
  }

  Future<String> _getWebCookie(String webRid) async {
    final headResp = await _dio.head<dynamic>(
      'https://live.douyin.com/$webRid',
      options: Options(headers: _baseHeaders),
    );
    var dyCookie = '';
    final setCookies = headResp.headers.map['set-cookie'];
    if (setCookies != null) {
      for (final element in setCookies) {
        final cookie = element.split(';').first;
        if (cookie.contains('ttwid')) dyCookie += '$cookie;';
        if (cookie.contains('__ac_nonce')) dyCookie += '$cookie;';
        if (cookie.contains('msToken')) dyCookie += '$cookie;';
      }
    }
    return dyCookie;
  }

  static bool _douyinIsLive(dynamic room, dynamic envelope) {
    final status = int.tryParse(
        room is Map ? (room['status']?.toString() ?? '') : '');
    if (status != null) return status == 2;
    final roomStatus = int.tryParse(envelope is Map
        ? (envelope['room_status']?.toString() ?? '')
        : '');
    return roomStatus == 0;
  }

  // ------------------------------------------------------- qualities/lines

  @override
  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async {
    return parseStreamQualities(liveRoom.data);
  }

  /// Resolves Douyin qualities by their stable `sdk_key`.
  ///
  /// The modern `stream_data.data` payload and the legacy pull-url maps
  /// are joined by key, never by position (JSON map order is not a
  /// quality contract). Sort key is the sdk_key rank / sdk_params level,
  /// NOT v_bit_rate — source can legitimately have a lower instantaneous
  /// bitrate than a transcoded tier.
  static List<LivePlayQuality> parseStreamQualities(dynamic rawStreamUrl) {
    if (rawStreamUrl is! Map) return const <LivePlayQuality>[];
    final liveCore = rawStreamUrl['live_core_sdk_data'];
    final pullData = liveCore is Map ? liveCore['pull_data'] : null;
    final options = pullData is Map ? pullData['options'] : null;
    final optionQualities = options is Map && options['qualities'] is List
        ? (options['qualities'] as List).whereType<Map>().toList(growable: false)
        : const <Map>[];

    Map<dynamic, dynamic> decodedStreams = const {};
    final streamDataText =
        pullData is Map ? pullData['stream_data']?.toString().trim() ?? '' : '';
    if (streamDataText.startsWith('{')) {
      try {
        final decoded = json.decode(streamDataText);
        if (decoded is Map && decoded['data'] is Map) {
          decodedStreams = decoded['data'] as Map;
        }
      } catch (_) {
        // A malformed stream_data blob must not drop the legacy maps.
      }
    }

    final flvMap = rawStreamUrl['flv_pull_url'] is Map
        ? rawStreamUrl['flv_pull_url'] as Map
        : const <dynamic, dynamic>{};
    final hlsMap = rawStreamUrl['hls_pull_url_map'] is Map
        ? rawStreamUrl['hls_pull_url_map'] as Map
        : const <dynamic, dynamic>{};
    final resolutionNames = rawStreamUrl['resolution_name'] is Map
        ? rawStreamUrl['resolution_name'] as Map
        : const <dynamic, dynamic>{};

    final descriptors = <String, Map<dynamic, dynamic>>{};
    for (final option in optionQualities) {
      final key = option['sdk_key']?.toString().trim() ?? '';
      if (key.isNotEmpty) {
        descriptors.putIfAbsent(key.toLowerCase(), () => option);
      }
    }
    for (final key in <dynamic>{
      ...decodedStreams.keys,
      ...flvMap.keys,
      ...hlsMap.keys,
    }) {
      final text = key?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        descriptors.putIfAbsent(
            text.toLowerCase(), () => <dynamic, dynamic>{'sdk_key': text});
      }
    }

    final qualities = <LivePlayQuality>[];
    for (final entry in descriptors.entries) {
      final key = entry.key;
      final descriptor = entry.value;
      final urls = <String>[];
      final stream = _caseInsensitiveMapValue(decodedStreams, key);
      final main = stream is Map ? stream['main'] : null;
      if (main is Map) {
        _addPlayableUrl(urls, main['flv']);
        _addPlayableUrl(urls, main['hls']);
      }
      _addPlayableUrl(urls, _caseInsensitiveMapValue(flvMap, key));
      _addPlayableUrl(urls, _caseInsensitiveMapValue(hlsMap, key));
      if (urls.isEmpty) continue;
      // Douyin may publish an `ao` entry beside its video renditions. It
      // is an audio-only pull URL (`only_audio=1`), not a selectable video
      // quality.
      if (_isAudioOnlyVariant(key, urls)) continue;

      final configuredName = descriptor['name']?.toString().trim() ?? '';
      final resolutionName = _caseInsensitiveMapValue(resolutionNames, key)
              ?.toString()
              .trim() ??
          '';
      final sdkParams =
          _decodeSdkParams(main is Map ? main['sdk_params'] : null);
      final bitRate = int.tryParse(descriptor['v_bit_rate']?.toString() ?? '') ??
          int.tryParse(sdkParams['vbitrate']?.toString() ?? '');
      final resolution = descriptor['resolution']?.toString().trim().isNotEmpty == true
          ? descriptor['resolution'].toString()
          : sdkParams['resolution']?.toString();
      final level = int.tryParse(descriptor['level']?.toString() ?? '') ?? 0;
      final knownRank = _douyinQualityRank(key);
      final sort = knownRank > 0
          ? knownRank
          : level > 0
              ? level * 1000000
              : bitRate ?? 0;
      qualities.add(
        LivePlayQuality(
          quality: _douyinQualityLabel(
            key: key,
            configuredName: configuredName,
            resolutionName: resolutionName,
            resolution: resolution,
            bitrate: bitRate,
          ),
          id: key.toLowerCase(),
          sort: sort,
          data: List<String>.unmodifiable(urls),
          declaredAspectRatio: _declaredAspectRatio(
            main: main is Map ? main : null,
            descriptor: descriptor,
            sdkParams: sdkParams,
          ),
        ),
      );
    }

    qualities.sort((left, right) {
      final rank = right.sort.compareTo(left.sort);
      return rank != 0
          ? rank
          : left.selectionId.compareTo(right.selectionId);
    });

    // Platform aliases can expose the same actual URL under both legacy
    // (`FULL_HD1`) and modern (`uhd`) keys. Presenting both would claim a
    // quality change even though the player receives an identical source.
    final seenStreams = <String>{};
    return qualities
        .where((quality) {
          final urls = (quality.data as List).map((url) => url.toString()).toList()
            ..sort();
          return seenStreams.add(urls.join('\u0000'));
        })
        .toList(growable: false);
  }

  /// Douyin SDK-key label mapping (Pure Live LiveQualityLabel._douyin):
  /// ORIGIN -> 原画, FULL_HD1/UHD -> 蓝光, HD1 -> 超清, SD2 -> 高清,
  /// SD1 -> 标清, MD -> 流畅. A CJK server name wins as-is; otherwise the
  /// resolution/bitrate falls back to a plain label, never an invented
  /// quality name.
  static String _douyinQualityLabel({
    required String key,
    required String configuredName,
    required String resolutionName,
    String? resolution,
    int? bitrate,
  }) {
    for (final candidate in [configuredName, resolutionName]) {
      if (candidate.isNotEmpty &&
          RegExp(r'[\u3400-\u9fff]').hasMatch(candidate)) {
        return candidate;
      }
    }
    final token = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final mapped = switch (token) {
      'origin' || 'origion' || 'original' || 'source' => '原画',
      'fullhd' || 'fullhd1' || 'uhd' || 'uhd1' || 'blue' || 'bluray' || 'blueray' =>
        '蓝光',
      'fhd' || 'hd' || 'hd1' => '超清',
      'sd' || 'sd2' => '高清',
      'ld' || 'sd1' => '标清',
      'md' => '流畅',
      'auto' => '自动',
      _ => null,
    };
    if (mapped != null) return mapped;
    final resolutionLabel = _resolutionLabel(resolution);
    if (resolutionLabel != null) return resolutionLabel;
    if (bitrate != null && bitrate > 0) return _bitrateLabel(bitrate);
    if (configuredName.isNotEmpty) return configuredName;
    if (resolutionName.isNotEmpty) return resolutionName;
    return key;
  }

  static String? _resolutionLabel(String? value) {
    final match = RegExp(r'(\d{3,5})\s*[x×]\s*(\d{3,5})', caseSensitive: false)
        .firstMatch(value ?? '');
    if (match == null) return null;
    final width = int.tryParse(match.group(1) ?? '') ?? 0;
    final height = int.tryParse(match.group(2) ?? '') ?? 0;
    final shortSide = width < height ? width : height;
    if (shortSide >= 2160) return '4K';
    if (shortSide >= 1440) return '2K 超清';
    if (shortSide >= 1080) return '1080P 高清';
    if (shortSide >= 720) return '720P 清晰';
    if (shortSide >= 480) return '480P 流畅';
    if (shortSide >= 360) return '360P 极速';
    return '${shortSide}P';
  }

  static String _bitrateLabel(int bitsPerSecond) {
    if (bitsPerSecond >= 1000000) {
      final mbps = bitsPerSecond / 1000000;
      final text = mbps == mbps.roundToDouble()
          ? mbps.toInt().toString()
          : mbps.toStringAsFixed(1);
      return '${text}M';
    }
    if (bitsPerSecond >= 1000) return '${bitsPerSecond ~/ 1000}K';
    return '$bitsPerSecond';
  }

  static int _douyinQualityRank(String key) => switch (key.toUpperCase()) {
        'ORIGION' || 'ORIGIN' => 6000000,
        'FULL_HD1' || 'UHD' => 5000000,
        'HD1' || 'HD' => 4000000,
        'SD2' || 'SD' => 3000000,
        'SD1' || 'LD' => 2000000,
        'MD' => 1000000,
        _ => 0,
      };

  static Map<dynamic, dynamic> _decodeSdkParams(dynamic raw) {
    if (raw is Map) return raw;
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) return const <dynamic, dynamic>{};
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? decoded : const <dynamic, dynamic>{};
    } catch (_) {
      return const <dynamic, dynamic>{};
    }
  }

  static dynamic _caseInsensitiveMapValue(
      Map<dynamic, dynamic> map, String key) {
    final direct = map[key];
    if (direct != null) return direct;
    final normalized = key.toLowerCase();
    for (final entry in map.entries) {
      if (entry.key?.toString().toLowerCase() == normalized) {
        return entry.value;
      }
    }
    return null;
  }

  static void _addPlayableUrl(List<String> urls, dynamic value) {
    final url = value?.toString().trim() ?? '';
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasScheme ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        urls.contains(url)) {
      return;
    }
    urls.add(url);
  }

  static bool _isAudioOnlyVariant(String key, List<String> urls) {
    final token = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    if (const {'ao', 'audio', 'audioonly'}.contains(token)) return true;
    if (urls.isEmpty) return false;
    return urls.every((url) {
      final uri = Uri.tryParse(url);
      final value = uri?.queryParameters['only_audio']?.toLowerCase();
      return value == '1' || value == 'true';
    });
  }

  static double? _declaredAspectRatio({
    required Map<dynamic, dynamic>? main,
    required Map<dynamic, dynamic> descriptor,
    required Map<dynamic, dynamic> sdkParams,
  }) {
    ({int width, int height})? fromResolution(Object? value) {
      final match = RegExp(r'(\d{2,5})\s*[xX×*]\s*(\d{2,5})')
          .firstMatch(value?.toString() ?? '');
      if (match == null) return null;
      return _plausibleSize(
          int.tryParse(match.group(1)!), int.tryParse(match.group(2)!));
    }

    final size = _plausibleSizeValues(main?['width'], main?['height']) ??
        _plausibleSizeValues(sdkParams['width'], sdkParams['height']) ??
        fromResolution(sdkParams['resolution']) ??
        fromResolution(descriptor['resolution']);
    return size == null ? null : size.width / size.height;
  }

  static ({int width, int height})? _plausibleSizeValues(
          Object? rawWidth, Object? rawHeight) =>
      _plausibleSize(int.tryParse(rawWidth?.toString() ?? ''),
          int.tryParse(rawHeight?.toString() ?? ''));

  static ({int width, int height})? _plausibleSize(int? width, int? height) {
    if (width == null ||
        height == null ||
        width < 120 ||
        height < 120 ||
        width > 16384 ||
        height > 16384) {
      return null;
    }
    final ratio = width / height;
    return ratio < 0.30 || ratio > 3.50 ? null : (width: width, height: height);
  }

  @override
  Future<List<String>> getPlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final data = quality?.data;
    if (data is List) {
      return data
          .map((url) => url.toString())
          .where((url) => url.isNotEmpty)
          .toList(growable: false);
    }
    if (quality == null) {
      final qualities = await getPlayQualities(liveRoom: liveRoom);
      if (qualities.isNotEmpty) {
        return getPlayUrls(liveRoom: liveRoom, quality: qualities.first);
      }
    }
    return const <String>[];
  }

  /// Full resolution with per-URL declared formats. Douyin pull URLs are
  /// plain CDN URLs (no re-signing, no lease): issuedAt is recorded but
  /// refreshAt/invalidAt stay null — there is no expiry to proactively
  /// refresh against.
  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final urls = await getPlayUrls(liveRoom: liveRoom, quality: quality);
    return LivePlayUrlResolution(
      urls: urls,
      appliedQualityData: quality?.selectionId,
      issuedAt: DateTime.now().toUtc(),
      streamFacts:
          urls.map((url) => LiveStreamFacts(format: _formatOfUrl(url))).toList(
                growable: false,
              ),
    );
  }

  /// Recovery — MUST re-fetch, never return cached URLs. Reloads the room
  /// detail, re-lists qualities, matches the requested quality id (else
  /// first) and resolves fresh URLs from the new detail.
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

  /// Declared format from the URL path (`.flv` / `.m3u8`); 'other' when
  /// the path carries neither suffix.
  static String _formatOfUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.endsWith('.flv')) return 'flv';
    if (path.endsWith('.m3u8')) return 'hls';
    return 'other';
  }

  // ------------------------------------------------------- search + lists

  @override
  Future<List<LiveRoom>> searchRooms(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    return _search.search(keyword, page: page, pageSize: pageSize);
  }

  /// Anchor search (P1-19): Douyin has no anchor-search endpoint, so
  /// this reuses [searchRooms] instead of throwing. A room result
  /// already carries its anchor (owner nickname/avatar + roomId +
  /// liveStatus), so it doubles as an anchor result — the same shape
  /// Kuaishou returns from both searches. Never throws for a missing
  /// anchor API: searchRooms returns [] when every stage fails.
  ///
  /// Caller contract across platforms — searchAnchors always returns
  /// LiveRoom entries; only Bilibili can still throw (see below), so a
  /// unified caller must try/catch per platform, never assume all five
  /// behave alike:
  /// - Douyin (here): room search reused; watching populated,
  ///   liveStatus real.
  /// - Bilibili: true anchor search, but it needs the buvid cookie —
  ///   getHeader() fetches one first, and if that fetch fails the API
  ///   answers HTTP 412 and parseSearchAnchors throws StateError.
  /// - Huya/Douyu: true anchor search; watching is 0 (not reported),
  ///   only nick/avatar/liveStatus are populated.
  /// - Kuaishou: author search; watching is 0 (unknown, never faked),
  ///   only the `living` flag says whether the anchor is live.
  @override
  Future<List<LiveRoom>> searchAnchors(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    return searchRooms(keyword, page: page, pageSize: pageSize);
  }

  @override
  Future<List<LiveRoom>> getRecommendRooms({
    int page = 1,
    int pageSize = 30,
  }) async {
    try {
      final result = await _getJson(
        'https://live.douyin.com/webcast/feed/',
        queryParameters: <String, dynamic>{
          'aid': '6383',
          'app_name': 'douyin_web',
          'need_map': '1',
          'is_draw': '1',
          'inner_from_drawer': '0',
          'enter_source': 'web_homepage_hot_web_live_card',
          'source_key': 'web_homepage_hot_web_live_card',
        },
        headers: await getRequestHeaders(),
      );
      final rooms = parseRecommendRooms(result);
      final start = (page - 1) * pageSize;
      if (start >= rooms.length) return const <LiveRoom>[];
      final end = (start + pageSize).clamp(0, rooms.length);
      return rooms.sublist(start, end);
    } catch (_) {
      // The feed endpoint has no paging of its own; a failure returns an
      // empty list rather than fake rooms.
      return const <LiveRoom>[];
    }
  }

  /// Parses both generations of Douyin's anonymous feed response: the
  /// legacy `data.data` list and (since Aug 2026) `data` as a list of feed
  /// envelopes with the room in each envelope's `data` field.
  static List<LiveRoom> parseRecommendRooms(dynamic payload) {
    final root = _asMap(payload);
    if (root == null) {
      throw const FormatException('Douyin feed response is not an object');
    }
    final statusCode = int.tryParse(root['status_code']?.toString() ?? '');
    if (statusCode != null && statusCode != 0) {
      throw StateError('Douyin feed rejected request: code=$statusCode');
    }
    dynamic rawRooms = root['data'];
    if (rawRooms is Map) rawRooms = rawRooms['data'];
    if (rawRooms is! List) {
      throw const FormatException('Douyin feed room list is missing');
    }
    final rooms = <LiveRoom>[];
    final seenRoomIds = <String>{};
    for (final rawItem in rawRooms) {
      final envelope = _asMap(rawItem);
      if (envelope == null) continue;
      final embedded = _decodeEmbeddedMap(envelope['data']);
      final nestedRoom = _asMap(envelope['room']);
      final room = <Map<String, dynamic>?>[embedded, nestedRoom, envelope]
          .firstWhere(
              (candidate) => candidate != null && _looksLikeRoom(candidate),
              orElse: () => null);
      if (room == null) continue;
      final owner = _asMap(room['owner']) ??
          _asMap(envelope['owner']) ??
          const <String, dynamic>{};
      final roomId = _firstText([
        envelope['web_rid'],
        owner['web_rid'],
        room['web_rid'],
        room['id_str'],
        room['id'],
      ]);
      if (roomId.isEmpty || !seenRoomIds.add(roomId)) continue;
      final title =
          _firstText([room['title'], envelope['title'], owner['nickname']]);
      final nick = _firstText([owner['nickname'], envelope['nickname']]);
      final cover = _firstImageUrl([room['cover'], envelope['cover']]);
      final avatar = _firstImageUrl([
        owner['avatar_thumb'],
        owner['avatar_large'],
        envelope['avatar_thumb'],
      ]);
      rooms.add(
        LiveRoom(
          roomId: roomId,
          title: title,
          cover: cover,
          nick: nick,
          platform: 'douyin',
          avatar: avatar,
          watching: douyinWatching(room),
          liveStatus: true,
          link: 'https://live.douyin.com/$roomId',
        ),
      );
    }
    return rooms;
  }

  static Map<String, dynamic>? _decodeEmbeddedMap(dynamic value) {
    final direct = _asMap(value);
    if (direct != null) return direct;
    if (value is! String || !value.trimLeft().startsWith('{')) return null;
    try {
      return _asMap(json.decode(value));
    } catch (_) {
      return null;
    }
  }

  static bool _looksLikeRoom(Map<String, dynamic> value) {
    return value['owner'] is Map ||
        value['title'] != null ||
        value['id_str'] != null ||
        value['stream_url'] is Map;
  }

  @override
  Future<List<LiveArea>> getCategories({
    int page = 1,
    int pageSize = 30,
  }) async {
    try {
      final response = await _dio.get<String>(
        'https://live.douyin.com/',
        queryParameters: const {'from_nav': '1'},
        options: Options(
          headers: await getRequestHeaders(),
          responseType: ResponseType.plain,
        ),
      );
      final areas = parseCategories(response.data ?? '');
      if (areas.isNotEmpty) return areas;
    } catch (_) {
      // Fall through to the fallback below.
    }
    // Homepage blocked (bot check) or the SSR blob moved: never leave
    // the tab without categories. areaIds are the repo's on-record
    // partition ids (canned fixture in douyin_site_test.dart).
    return _fallbackDouyinCategories;
  }

  static const List<LiveArea> _fallbackDouyinCategories = <LiveArea>[
    LiveArea(areaId: '1,1', areaName: '游戏', platform: 'douyin'),
    LiveArea(areaId: '2,1', areaName: '英雄联盟', platform: 'douyin'),
  ];

  /// Parses the homepage `categoryData` blob into areas. areaId is
  /// "id,type" — the exact shape getCategoryRooms splits on.
  /// Parses the homepage `categoryData` blob into areas. areaId is
  /// "id,type" - the exact shape getCategoryRooms splits on.
  ///
  /// The blob escaping varies by page generation (raw, singly- or
  /// doubly-escaped JSON), so extraction is retried on the HTML
  /// unescaped 0..3 times; the first attempt yielding a
  /// `categoryData` list wins. This covers the Pure Live escaped
  /// form as well as the raw form.
  static List<LiveArea> parseCategories(String html) {
    var text = html;
    for (var attempt = 0; attempt < 4; attempt++) {
      final extracted = extractCategoryDataJson(text);
      if (extracted.isNotEmpty) {
        final renderDataJson = _decodeJson(extracted);
        final data =
            renderDataJson is Map ? renderDataJson['categoryData'] : null;
        if (data is List) return _areasFromCategoryData(data);
      }
      text = _unescapeOnce(text);
    }
    return const <LiveArea>[];
  }

  /// One JSON-unescape pass: backslash-quote becomes a quote, then
  /// a doubled backslash becomes one. Built from char codes so no
  /// escape sequences appear in source.
  static String _unescapeOnce(String s) {
    final bs = String.fromCharCode(92);
    return s.replaceAll('$bs"', '"').replaceAll('$bs$bs', bs);
  }

  static List<LiveArea> _areasFromCategoryData(List<dynamic> data) {
    final areas = <LiveArea>[];
    for (final item in data) {
      final itemMap = _asMap(item);
      if (itemMap == null) continue;
      final partition = _asMap(itemMap['partition']);
      if (partition == null) continue;
      final id =
          '${partition['id_str']},${partition['type']}';
      final title = partition['title']?.toString() ?? '';
      areas.add(LiveArea(
          areaId: id, areaName: title, platform: 'douyin'));
      final subs = itemMap['sub_partition'];
      if (subs is List) {
        for (final subItem in subs) {
          final subMap = _asMap(subItem);
          final subPartition =
              subMap == null ? null : _asMap(subMap['partition']);
          if (subPartition == null) continue;
          areas.add(LiveArea(
            areaId: '${subPartition['id_str']},${subPartition['type']}',
            areaName: subPartition['title']?.toString() ?? '',
            platform: 'douyin',
          ));
        }
      }
    }
    return areas;
  }

  static String extractCategoryDataJson(String source) {
    const startPatterns = <String>[
      r'{\"pathname\":\"/\",\"categoryData\":',
      r'{"pathname":"/","categoryData":',
    ];
    for (final startPattern in startPatterns) {
      final startIndex = source.indexOf(startPattern);
      if (startIndex == -1) continue;
      var openBraces = 0;
      var foundFirstBrace = false;
      for (var i = startIndex; i < source.length; i++) {
        if (source[i] == '{') {
          openBraces++;
          foundFirstBrace = true;
        } else if (source[i] == '}') {
          openBraces--;
        }
        if (foundFirstBrace && openBraces == 0) {
          final rawData = source.substring(startIndex, i + 1);
          return rawData.replaceAll('\\"', '"').replaceAll(r'\\', r'\');
        }
      }
    }
    return '';
  }

  @override
  Future<List<LiveRoom>> getCategoryRooms(
    LiveArea area, {
    int page = 1,
    int pageSize = 30,
  }) async {
    try {
      final ids = area.areaId.split(',');
      final partitionId = ids.isNotEmpty ? ids[0] : '';
      final partitionType = ids.length > 1 ? ids[1] : '';
      if (partitionId.isEmpty) return const <LiveRoom>[];
      final queryParameters = <String, dynamic>{
        'aid': '6383',
        'app_name': 'douyin_web',
        'live_id': '1',
        'device_platform': 'web',
        'language': 'zh-CN',
        'enter_from': 'link_share',
        'cookie_enabled': 'true',
        'screen_width': '1980',
        'screen_height': '1080',
        'browser_language': 'zh-CN',
        'browser_platform': 'Win32',
        'browser_name': 'Edge',
        'browser_version': '125.0.0.0',
        'browser_online': 'true',
        'count': '15',
        'offset': ((page - 1) * 15).toString(),
        'partition': partitionId,
        'partition_type': partitionType,
        'req_from': '2',
      };
      final targetUrl = DouyinUtils.buildRequestUrl(
        'https://live.douyin.com/webcast/web/partition/detail/room/v2/',
        queryParameters,
      );
      final result =
          await _getJson(targetUrl, headers: await getRequestHeaders());
      return parseCategoryRooms(result);
    } catch (_) {
      return const <LiveRoom>[];
    }
  }

  /// Parses a partition room list (`data.data[]`) into rooms.
  static List<LiveRoom> parseCategoryRooms(dynamic payload) {
    final root = _asMap(payload);
    final data = root == null ? null : _asMap(root['data']);
    final list = data?['data'];
    if (list is! List) return const <LiveRoom>[];
    final items = <LiveRoom>[];
    for (final item in list) {
      final itemMap = _asMap(item);
      if (itemMap == null) continue;
      final room = _asMap(itemMap['room']);
      if (room == null) continue;
      final owner = _asMap(room['owner']) ?? const <String, dynamic>{};
      items.add(
        LiveRoom(
          roomId: _firstText([itemMap['web_rid'], owner['web_rid']]),
          title: _firstText([room['title']]),
          cover: _firstImageUrl([room['cover']]),
          nick: _firstText([owner['nickname']]),
          avatar: _firstImageUrl([owner['avatar_thumb']]),
          platform: 'douyin',
          watching: douyinWatching(room),
          liveStatus: true,
          link:
              'https://live.douyin.com/${_firstText([itemMap['web_rid'], owner['web_rid']])}',
        ),
      );
    }
    return items.where((room) => room.roomId.isNotEmpty).toList();
  }

  // ------------------------------------------------------------- helpers

  Future<Map<String, dynamic>> _getJson(
    String url, {
    Map<String, dynamic>? queryParameters,
    required Map<String, String> headers,
  }) async {
    final response = await _dio.get<dynamic>(
      url,
      queryParameters: queryParameters,
      options: Options(headers: headers),
    );
    final decoded = _decodeJson(response.data);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const FormatException('Douyin response is not an object');
  }

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

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static String _firstText(Iterable<dynamic> candidates) {
    for (final value in candidates) {
      if (value == null || value is Map || value is Iterable && value is! String) {
        continue;
      }
      final text = value.toString().trim();
      if (text.isNotEmpty && text != 'null') return text;
    }
    return '';
  }

  static String _firstImageUrl(Iterable<dynamic> candidates) {
    for (final value in candidates) {
      final image = _asMap(value);
      final urlList = image?['url_list'];
      if (urlList is List) {
        final url = _firstText(urlList);
        if (url.isNotEmpty) return url;
      }
      final direct = _firstText([value]);
      if (direct.startsWith('http://') || direct.startsWith('https://')) {
        return direct;
      }
    }
    return '';
  }
}
