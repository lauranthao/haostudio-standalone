// Douyin search — port of Pure Live 3.x
// lib/shared/platforms/douyin/douyin_search.dart.
//
// Three-stage fallback, in order:
//   1. live API   https://www.douyin.com/aweme/v1/web/live/search/
//   2. general API https://www.douyin.com/aweme/v1/web/general/search/stream/
//   3. partition search https://live.douyin.com/webcast/web/partition/search/
//      (then partition room lists, first 3 partitions, two hosts tried).
// A stage that errors or returns nothing falls through to the next; all
// stages failing returns [] — never fake rooms. Anchor search is NOT here:
// Douyin does not support it (DouyinSite.searchAnchors throws).
//
// Differences from upstream: Dio instead of Pure Live's HttpClient, and
// no user-configured cookie store exists in this project yet — search
// runs anonymous-only, warming a ttwid/UIFID_TEMP cookie from
// https://live.douyin.com/ exactly as upstream's _fetchCookie does.

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/models/live_models.dart';
import '../../../core/network/http_client.dart';
import 'douyin_audience.dart';

class DouyinSearch {
  DouyinSearch({Dio? dio}) : _dio = dio ?? sharedDio();

  final Dio _dio;

  static const String host = 'https://live.douyin.com';
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const Map<String, String> defaultHeaders = <String, String>{
    'User-Agent': userAgent,
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
  };

  String _cookie = '';
  Future<String>? _cookieRequest;

  Future<String> _getCookie() async {
    if (_cookie.isNotEmpty) return _cookie;
    try {
      final cookie = await (_cookieRequest ??= _fetchCookie());
      _cookieRequest = null;
      if (cookie.isNotEmpty) _cookie = cookie;
      return _cookie;
    } catch (_) {
      _cookieRequest = null;
      return '';
    }
  }

  Future<String> _fetchCookie() async {
    try {
      final response = await _dio.get<dynamic>(
        host,
        queryParameters: const {'from_nav': '1'},
        options: Options(headers: defaultHeaders),
      );
      final setCookieValues =
          response.headers.map['set-cookie'] ?? const <String>[];
      final cookies = <String>[];
      for (final value in setCookieValues) {
        final cookie = value.split(';').first.trim();
        if (cookie.startsWith('ttwid=') || cookie.startsWith('UIFID_TEMP=')) {
          cookies.add(cookie);
        }
      }
      return cookies.join('; ');
    } catch (_) {
      return '';
    }
  }

  Future<Map<String, String>> _getHeaders(String keyword) async {
    final cookie = await _getCookie();
    return <String, String>{
      ...defaultHeaders,
      'Referer':
          'https://www.douyin.com/search/${Uri.encodeComponent(keyword)}?source=switch_tab&type=live',
      'Origin': 'https://www.douyin.com',
      'Sec-Fetch-Dest': 'empty',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Site': 'same-origin',
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
  }

  Future<List<LiveRoom>> search(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final kw = keyword.trim();
    final normalizedPage = page < 1 ? 1 : page;
    final normalizedPageSize = pageSize.clamp(1, 50);
    if (kw.isEmpty) return const <LiveRoom>[];
    try {
      final live = await _searchByLiveApi(kw, normalizedPage, normalizedPageSize);
      if (live.isNotEmpty) return live;
    } catch (_) {
      // Fall through to the general API.
    }
    try {
      final general =
          await _searchByGeneralApi(kw, normalizedPage, normalizedPageSize);
      if (general.isNotEmpty) return general;
    } catch (_) {
      // Fall through to partition search.
    }
    try {
      return await _searchByPartition(kw, normalizedPage, normalizedPageSize);
    } catch (_) {
      return const <LiveRoom>[];
    }
  }

  Future<List<LiveRoom>> _searchByLiveApi(
      String keyword, int page, int pageSize) async {
    final count = pageSize.clamp(1, 50);
    final offset = count * (page - 1);
    final headers = await _getHeaders(keyword);
    final result = await _getJson(
      'https://www.douyin.com/aweme/v1/web/live/search/',
      queryParameters: <String, dynamic>{
        'device_platform': 'webapp',
        'aid': '6383',
        'channel': 'channel_pc_web',
        'search_channel': 'aweme_live',
        'search_source': 'switch_tab',
        'query_correct_type': '1',
        'need_filter_settings': '1',
        'list_type': 'single',
        'keyword': keyword,
        'offset': offset.toString(),
        'count': count.toString(),
        'os_version': '10',
      },
      headers: headers,
    );
    if (result['status_code'] != 0) return const <LiveRoom>[];
    return parseSearchVideos(result['data']);
  }

  Future<List<LiveRoom>> _searchByGeneralApi(
      String keyword, int page, int pageSize) async {
    final count = pageSize.clamp(1, 50);
    final offset = count * (page - 1);
    final headers = await _getHeaders(keyword);
    final result = await _getJson(
      'https://www.douyin.com/aweme/v1/web/general/search/stream/',
      queryParameters: <String, dynamic>{
        'device_platform': 'webapp',
        'aid': '6383',
        'channel': 'channel_pc_web',
        'search_channel': 'aweme_live',
        'keyword': keyword,
        'offset': offset.toString(),
        'count': count.toString(),
        'os_version': '10',
      },
      headers: headers,
    );
    if (result['status_code'] != 0) return const <LiveRoom>[];
    return parseSearchVideos(result['data']);
  }

  Future<List<LiveRoom>> _searchByPartition(
      String keyword, int page, int pageSize) async {
    final headers = await _getHeaders(keyword);
    final result = await _getJson(
      'https://live.douyin.com/webcast/web/partition/search/',
      queryParameters: <String, dynamic>{'keyword': keyword, 'aid': '6383'},
      headers: headers,
    );
    final data = _asMap(result['data']);
    final partitions = data?['SearchResult'];
    if (partitions is! List || partitions.isEmpty) {
      return const <LiveRoom>[];
    }
    final merged = <LiveRoom>[];
    final seen = <String>{};
    for (var i = 0; i < partitions.length && i < 3; i++) {
      final partitionItem = _asMap(partitions[i]);
      if (partitionItem == null) continue;
      final partition = _asMap(partitionItem['partition']);
      if (partition == null) continue;
      final partitionId = partition['id_str']?.toString();
      final partitionType = partition['type'];
      if (partitionId == null ||
          partitionId.isEmpty ||
          partitionType == null) {
        continue;
      }
      try {
        final rooms = await _getPartitionRooms(
          partitionId,
          partitionType.toString(),
          page: page,
          pageSize: pageSize,
        );
        for (final room in rooms) {
          if (!seen.add(room.roomId)) continue;
          merged.add(room);
          if (merged.length >= pageSize) return merged;
        }
      } catch (_) {
        // One dead partition must not kill the other two.
      }
    }
    return merged;
  }

  Future<List<LiveRoom>> _getPartitionRooms(
    String partition,
    String partitionType, {
    required int page,
    required int pageSize,
  }) async {
    final count = pageSize.clamp(1, 50);
    final params = <String, dynamic>{
      'aid': '6383',
      'app_name': 'douyin_web',
      'live_id': '1',
      'device_platform': 'web',
      'language': 'zh-CN',
      'browser_language': 'zh-CN',
      'browser_platform': 'Win32',
      'browser_name': 'Chrome',
      'browser_version': '120.0.0.0',
      'partition': partition,
      'partition_type': partitionType,
      'count': count.toString(),
      'offset': ((page - 1) * count).toString(),
      'cookie_enabled': 'true',
      'screen_width': '1920',
      'screen_height': '1080',
    };
    final headers = await _getHeaders('');
    const urls = <String>[
      'https://live.douyin.com/webcast/web/partition/detail/room/v2/',
      'https://webcast.amemv.com/webcast/web/partition/detail/room/v2/',
    ];
    for (final url in urls) {
      try {
        final result =
            await _getJson(url, queryParameters: params, headers: headers);
        if (result['status_code'] != 0) continue;
        final data = _asMap(result['data']);
        final list = data?['data'];
        if (list is! List || list.isEmpty) continue;
        return parsePartitionRoomList(list);
      } catch (_) {
        // Try the next host.
      }
    }
    return const <LiveRoom>[];
  }

  Future<Map<String, dynamic>> _getJson(
    String url, {
    required Map<String, dynamic> queryParameters,
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
    throw const FormatException('Douyin search response is not an object');
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

  // ------------------------------------------------------------ parsing

  /// Parses a search `data` list (live/general API) into rooms.
  static List<LiveRoom> parseSearchVideos(dynamic payload) {
    if (payload is! List) return const <LiveRoom>[];
    final result = <LiveRoom>[];
    final seen = <String>{};
    for (final item in payload) {
      final raw = _parseRawLiveData(item);
      final itemMap = _asMap(item) ?? const <String, dynamic>{};
      final room = _normalizeSearchItem(
        raw,
        fallback: <String, dynamic>{
          'nickname': itemMap['nickname'],
          'title': itemMap['title'] ?? itemMap['desc'],
          'tag': itemMap['search_keyword'],
        },
      );
      if (room == null || !seen.add(room.roomId)) continue;
      result.add(room);
    }
    return result;
  }

  /// Parses a partition room list (`data.data[]` from
  /// partition/detail/room/v2) into rooms.
  static List<LiveRoom> parsePartitionRoomList(dynamic payload) {
    if (payload is! List) return const <LiveRoom>[];
    final rooms = <LiveRoom>[];
    for (final item in payload) {
      final itemMap = _asMap(item);
      if (itemMap == null) continue;
      final room = _asMap(itemMap['room']);
      if (room == null) continue;
      final owner = _asMap(room['owner']) ?? const <String, dynamic>{};
      final cover = _asMap(room['cover']) ?? const <String, dynamic>{};
      final avatar = _asMap(owner['avatar_thumb']) ?? const <String, dynamic>{};
      final coverList = cover['url_list'];
      final avatarList = avatar['url_list'];
      final coverUrl =
          coverList is List && coverList.isNotEmpty ? coverList.first.toString() : '';
      final avatarUrl = avatarList is List && avatarList.isNotEmpty
          ? avatarList.first.toString()
          : '';
      final webRid =
          _firstNonEmpty([itemMap['web_rid'], owner['web_rid']]);
      final roomId = room['id_str']?.toString() ?? '';
      if (roomId.isEmpty) continue;
      final rid = webRid.isNotEmpty ? webRid : roomId;
      rooms.add(
        LiveRoom(
          roomId: rid,
          title: room['title']?.toString() ?? '',
          cover: coverUrl,
          nick: owner['nickname']?.toString() ?? '',
          avatar: avatarUrl,
          platform: 'douyin',
          watching: douyinWatching(room),
          liveStatus: true,
          link: 'https://live.douyin.com/$rid',
        ),
      );
    }
    return rooms;
  }

  static Map<String, dynamic>? _parseRawLiveData(dynamic item) {
    final itemMap = _asMap(item);
    if (itemMap == null) return null;
    final candidates = <dynamic>[
      _mapValue(_mapValue(itemMap, 'lives'), 'rawdata'),
      _mapValue(_mapValue(itemMap, 'lives'), 'raw_data'),
      _mapValue(_mapValue(itemMap, 'live'), 'rawdata'),
      _mapValue(_mapValue(itemMap, 'live_info'), 'rawdata'),
      _mapValue(
          _mapValue(_mapValue(itemMap, 'aweme_info'), 'live_info'), 'rawdata'),
      _mapValue(_mapValue(itemMap, 'data'), 'rawdata'),
      itemMap['rawdata'],
      itemMap['lives'],
      itemMap['live'],
      itemMap['live_info'],
      _mapValue(_mapValue(itemMap, 'aweme_info'), 'live_info'),
      itemMap['aweme_info'],
      itemMap['data'],
      itemMap,
    ];
    for (final candidate in candidates) {
      if (candidate is String) {
        try {
          final decoded = jsonDecode(candidate);
          if (decoded is Map) return Map<String, dynamic>.from(decoded);
        } catch (_) {
          // Not JSON — try the next candidate.
        }
      } else {
        final map = _asMap(candidate);
        if (map != null) return map;
      }
    }
    return null;
  }

  static LiveRoom? _normalizeSearchItem(
    Map<String, dynamic>? raw, {
    Map<String, dynamic>? fallback,
  }) {
    if (raw == null) return null;
    fallback ??= const <String, dynamic>{};
    final room = _asMap(raw['room']) ?? const <String, dynamic>{};
    final owner = _asMap(raw['owner']) ?? const <String, dynamic>{};
    final roomOwner = _asMap(room['owner']) ?? const <String, dynamic>{};
    final roomId = _firstNonEmpty([
      raw['id_str'],
      raw['room_id_str'],
      room['id_str'],
      room['id'],
      raw['room_id'],
      raw['roomId'],
    ]);
    if (roomId.isEmpty) return null;
    final webRid = _firstNonEmpty(
        [owner['web_rid'], raw['web_rid'], roomOwner['web_rid']]);
    final nickname = _firstNonEmpty([
      owner['nickname'],
      raw['nickname'],
      roomOwner['nickname'],
      fallback['nickname'],
    ]);
    final title = _firstNonEmpty(
        [raw['title'], room['title'], fallback['title'], nickname]);
    final cover = _asMap(raw['cover']);
    final roomCover = _asMap(room['cover']);
    final avatarLarge = _asMap(owner['avatar_large']);
    final avatarThumb = _asMap(owner['avatar_thumb']);
    String getFirstUrl(dynamic value) {
      if (value is List && value.isNotEmpty) {
        return value.first?.toString() ?? '';
      }
      return '';
    }

    final pic = _firstNonEmpty([
      getFirstUrl(avatarLarge?['url_list']),
      getFirstUrl(cover?['url_list']),
      getFirstUrl(roomCover?['url_list']),
      raw['cover_url'],
    ]);
    final status = (raw['status'] is num
            ? (raw['status'] as num).toInt()
            : int.tryParse(raw['status']?.toString() ?? '') ?? 0) ==
        2;
    String? tagText;
    final partitionRoadMap = room['partition_road_map'];
    if (partitionRoadMap is List && partitionRoadMap.isNotEmpty) {
      final firstPartition = _asMap(partitionRoadMap.first);
      tagText = firstPartition?['title']?.toString();
    }
    tagText = _firstNonEmpty([
      raw['video_feed_tag'],
      tagText,
      _mapValue(raw['partition'], 'title'),
      fallback['tag'],
    ]);
    // Deterministic identity: the internal room id is a stable fallback
    // when web_rid is absent (never a timestamp).
    final realWebRid = webRid.isNotEmpty ? webRid : roomId;
    final avatar = _firstNonEmpty([
      getFirstUrl(avatarThumb?['url_list']),
      getFirstUrl(avatarLarge?['url_list']),
    ]);
    var watching = douyinWatching(room);
    if (watching == 0) watching = douyinWatching(raw);
    // Note: upstream uses the owner's avatar_large url as the card cover
    // when no cover url_list exists (its `pic` prefers avatarLarge first);
    // preserved here so search cards match upstream behaviour.
    return LiveRoom(
      roomId: realWebRid,
      title: title,
      cover: pic,
      nick: nickname.isNotEmpty ? nickname : '抖音直播',
      avatar: avatar,
      platform: 'douyin',
      watching: watching,
      liveStatus: status,
      link: 'https://live.douyin.com/$realWebRid',
    );
  }

  static String _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      if (value == null) continue;
      final text = value.toString();
      if (text.isNotEmpty && text != 'null') return text;
    }
    return '';
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static dynamic _mapValue(dynamic value, String key) {
    final map = _asMap(value);
    return map?[key];
  }
}
