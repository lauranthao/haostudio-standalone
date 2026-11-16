// Kuaishou adapter — port of Pure Live 3.x
// lib/shared/platforms/kuaishou/kuaishou_site.dart (672 lines).
//
// Room detail: HTML scrape — GET https://live.kuaishou.com/u/<roomId>,
// `window.__INITIAL_STATE__` -> `liveroom.playList[0]` (fallback: legacy
// `room` object) -> `liveStream` (id = liveStreamId, poster, playUrls,
// caption) + `author` (id/name/avatar/description).
//
// ROOMID RULE (fixes the old Swift/web bug): the room identifier is
// `author.id`, NEVER `liveStream.id`. The live-stream id is only the
// danmaku/feed credential (`danmakuData['liveStreamId']`) and the `link`
// value for the native kwai:// deep link.
//
// Quality+lines: parseKuaishouPlayQualities(playUrls) — same-quality URLs
// merged/deduped = one quality -> N lines (one group per quality, by
// platform design). No re-signing: the URLs arrive signed (txSecret /
// txTime). Empty parse -> room unplayable (empty list, never invented).
// Lines are identified by URL, not index.
// Search: GET https://live.kuaishou.com/live_api/search/author (POST is
// 405 — verified live 2026-11-16) — returns ANCHORS, not rooms (only a
// `living` flag); Kuaishou search = find anchor -> open room.
// Danmaku: HTTP polling (kuaishou_danmaku.dart), getDanmaku() returns it.
//
// NOT ported (needs account/session machinery this project has no
// equivalent for yet):
// * Session bootstrap (`getCookie` + log-sdk `registerDid` POST) — the
//   room page is fetched anonymously first, exactly as Pure Live's
//   refresh path does; if Kuaishou starts requiring a session for a
//   network, retry-after-bootstrap is the next step, not a silent
//   offline. Note: from this VM the room page currently answers the
//   rate-limit card ("请求过快，请稍后重试") even with cookies —
//   see the test file's live-probe notes.
// * Categories (`live_api/category/data`, gameboard/non-gameboard lists)
//   and the emoji table (`pcConfig` emoji panel) — out of this task's
//   scope; the base contract returns [] for categories.

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/models/live_models.dart';
import '../../../core/network/http_client.dart';
import '../live_site.dart';
import 'kuaishou_danmaku.dart';
import 'kuaishou_models.dart';
import 'kuaishou_room_parser.dart';

class KuaishouSite extends LiveSite {
  KuaishouSite({Dio? dio}) : _dio = dio ?? sharedDio();

  @override
  String get id => 'kuaishou';

  @override
  String get name => '快手';

  @override
  LiveDanmaku getDanmaku() => KuaishouDanmaku();

  // One shared Dio for this adapter (sharedDio(); never a second Dio).
  final Dio _dio;

  static const Map<String, String> _headers = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/107.0.0.0 Safari/537.36',
    'accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,'
        'image/webp,image/apng,*/*;q=0.8,'
        'application/signed-exchange;v=b3',
    'connection': 'keep-alive',
    'sec-ch-ua':
        'Google Chrome;v=107, Chromium;v=107, Not=A?Brand;v=24',
    'sec-ch-ua-platform': 'macOS',
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'same-origin',
    'Sec-Fetch-User': '?1',
  };

  static const String _roomBaseUrl = 'https://live.kuaishou.com/u';
  static const String _recommendUrl =
      'https://live.kuaishou.com/live_api/home/list';
  static const String _authorSearchUrl =
      'https://live.kuaishou.com/live_api/search/author';

  // ---------------------------------------------------------------- room

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async {
    try {
      return await _loadRoomDetail(room.roomId);
    } on Object {
      // UI path: a transient failure must not blank the card — return
      // the room as offline. The recovery path below does NOT swallow
      // errors.
      return room.copyWith(liveStatus: false);
    }
  }

  /// Strict room load: throws [FormatException] when the page carries no
  /// parseable playback metadata (recovery callers must see the
  /// transient error, never a disguised "offline").
  Future<LiveRoom> _loadRoomDetail(String roomId) async {
    final response = await _dio.get<String>(
      '$_roomBaseUrl/$roomId',
      options: Options(
        headers: <String, String>{
          ..._headers,
          'Accept': 'text/html,application/xhtml+xml',
        },
        responseType: ResponseType.plain,
      ),
    );
    final html = response.data ?? '';
    if (html.isEmpty) {
      throw const FormatException('Kuaishou room page is empty');
    }
    return parseKuaishouRoomPage(html, roomId);
  }

  // ------------------------------------------------------- qualities/lines

  @override
  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async {
    return parseKuaishouPlayQualities(kuaishouPlayUrlsOf(liveRoom));
  }

  @override
  Future<List<String>> getPlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final data = quality == null
        ? null
        : KuaishouQualityData.fromDataMap(quality.data);
    return data?.urls ?? const <String>[];
  }

  /// Full resolution with per-URL stream facts. Kuaishou URLs carry no
  /// wsTime-style lease, so refreshAt/invalidAt stay null (no proactive
  /// refresh); the signed URLs expire on the server's own txTime.
  /// appliedQualityData is the requested quality's selection id — the
  /// quality list itself comes from the server, so it is confirmed.
  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final data = quality == null
        ? null
        : KuaishouQualityData.fromDataMap(quality.data);
    return LivePlayUrlResolution(
      urls: data?.urls ?? const <String>[],
      appliedQualityData: quality?.selectionId,
      issuedAt: DateTime.now().toUtc(),
      streamFacts: data?.facts ?? const <LiveStreamFacts>[],
    );
  }

  /// Recovery — MUST re-fetch all identity/token/room fields; returning
  /// cached URLs is a no-op. Reloads room detail, re-lists qualities,
  /// matches the requested quality id (else first), resolves fresh URLs.
  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsForRecovery({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final roomId = liveRoom.roomId.trim();
    if (roomId.isEmpty) {
      return LivePlayUrlResolution(
        urls: const <String>[],
        appliedQualityData: quality?.selectionId,
      );
    }
    final refreshedDetail = await _loadRoomDetail(roomId);
    if (!refreshedDetail.liveStatus) {
      return LivePlayUrlResolution(
        urls: const <String>[],
        appliedQualityData: quality?.selectionId,
      );
    }
    final refreshedQualities =
        await getPlayQualities(liveRoom: refreshedDetail);
    if (refreshedQualities.isEmpty) {
      return LivePlayUrlResolution(
        urls: const <String>[],
        appliedQualityData: quality?.selectionId,
      );
    }
    final requestedId = quality?.selectionId;
    final refreshedQuality = refreshedQualities.firstWhere(
      (item) => item.selectionId == requestedId,
      orElse: () => refreshedQualities.first,
    );
    final resolution = await resolvePlayUrls(
      liveRoom: refreshedDetail,
      quality: refreshedQuality,
    );
    return LivePlayUrlResolution(
      urls: resolution.urls,
      appliedQualityData: refreshedQuality.selectionId,
      issuedAt: resolution.issuedAt,
      streamFacts: resolution.streamFacts,
    );
  }

  // ------------------------------------------------------- search + lists

  /// Home hot list via `live_api/home/list` (no pagination server-side;
  /// the page slice is taken client-side).
  @override
  Future<List<LiveRoom>> getRecommendRooms({
    int page = 1,
    int pageSize = 30,
  }) async {
    final response = await _dio.get<dynamic>(
      _recommendUrl,
      options: Options(headers: _headers),
    );
    final rooms = parseKuaishouRecommendRooms(_decodeJson(response.data));
    final effectivePageSize = pageSize.clamp(1, 100);
    final start = (page - 1) * effectivePageSize;
    if (start >= rooms.length) return const <LiveRoom>[];
    final end = (start + effectivePageSize).clamp(0, rooms.length);
    return rooms.sublist(start, end);
  }

  /// Categories — port of Pure Live 3.x `getCategores` +
  /// `getSubCategores`: eight fixed top types (热门 1 / 网游 2 / 单机 3 /
  /// 手游 4 / 棋牌 5 / 娱乐 6 / 综合 7 / 文化 8) from
  /// `live_api/category/data?type=<id>&page=&size=` (probed live
  /// 2026-11-16). All types fetch in parallel; a full first page
  /// pulls one more page, capped at two. One dead type never kills
  /// the others; when every fetch fails, the verified-popular
  /// fallback below is returned so the tab never shows a blank
  /// category row.
  @override
  Future<List<LiveArea>> getCategories({
    int page = 1,
    int pageSize = 30,
  }) async {
    final first = await Future.wait(
      _kuaishouCategoryTypes
          .map((type) => _fetchKuaishouCategoryPage(type, 1)),
    );
    final areas = first.expand((list) => list).toList();
    final fullTypes = <String>[];
    for (var i = 0; i < _kuaishouCategoryTypes.length; i++) {
      if (first[i].length >= _kuaishouCategoryPageSize) {
        fullTypes.add(_kuaishouCategoryTypes[i]);
      }
    }
    if (fullTypes.isNotEmpty) {
      final second = await Future.wait(
        fullTypes.map((type) => _fetchKuaishouCategoryPage(type, 2)),
      );
      areas.addAll(second.expand((list) => list));
    }
    if (areas.isNotEmpty) return areas;
    return _fallbackKuaishouCategories;
  }

  /// Pure Live's top-type order: 热门 / 网游 / 单机 / 手游 / 棋牌 /
  /// 娱乐 / 综合 / 文化.
  static const List<String> _kuaishouCategoryTypes = <String>[
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
  ];

  static const int _kuaishouCategoryPageSize = 50;

  Future<List<LiveArea>> _fetchKuaishouCategoryPage(
    String type,
    int page,
  ) async {
    try {
      final response = await _dio.get<dynamic>(
        'https://live.kuaishou.com/live_api/category/data',
        queryParameters: <String, dynamic>{
          'type': type,
          'page': page,
          'size': _kuaishouCategoryPageSize,
        },
        options: Options(headers: _headers),
      );
      return parseKuaishouCategories(_decodeJson(response.data));
    } catch (_) {
      return const <LiveArea>[];
    }
  }

  /// Verified-popular categories per top type (live probe 2026-11-16,
  /// `category/data` first-page entries). Only used when all live
  /// fetches fail; ids are real, so category rooms load.
  static const List<LiveArea> _fallbackKuaishouCategories = <LiveArea>[
    // 热门
    LiveArea(areaId: '22008', areaName: '和平精英', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1001', areaName: '王者荣耀', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '22484', areaName: '暗区突围', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '22744', areaName: '格斗游戏', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '2', areaName: '穿越火线', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '21', areaName: '绝地求生', platform: PlatformIds.kuaishou),
    // 网游
    LiveArea(areaId: '1', areaName: '英雄联盟', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1009', areaName: '我的世界', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '3', areaName: '地下城与勇士', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '13', areaName: '守望先锋', platform: PlatformIds.kuaishou),
    // 单机
    LiveArea(areaId: '22762', areaName: '黑神话悟空', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '22088', areaName: '经典单机', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '15', areaName: '街机游戏', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '22193', areaName: '植物大战僵尸', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '22189', areaName: '红警', platform: PlatformIds.kuaishou),
    // 手游
    LiveArea(areaId: '22181', areaName: '原神', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1054', areaName: 'QQ飞车手游', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '22337', areaName: '蛋仔派对', platform: PlatformIds.kuaishou),
    // 棋牌
    LiveArea(areaId: '1018', areaName: 'JJ斗地主', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '22185', areaName: '天天象棋', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '20', areaName: '三国杀', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '6', areaName: '斗地主', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '10', areaName: '象棋', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1017', areaName: '欢乐斗地主', platform: PlatformIds.kuaishou),
    // 娱乐
    LiveArea(areaId: '1000004', areaName: '才艺', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1000003', areaName: '音乐', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1000006', areaName: '颜值', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1000002', areaName: '舞蹈', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1000007', areaName: '情感', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1000005', areaName: '脱口秀', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1000001', areaName: '明星', platform: PlatformIds.kuaishou),
    // 综合
    LiveArea(areaId: '1000024', areaName: '其他', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1000020', areaName: '购物', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1000016', areaName: '健康', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1000021', areaName: '媒体', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1000011', areaName: '美妆', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1000008', areaName: '汽车', platform: PlatformIds.kuaishou),
    // 文化
    LiveArea(areaId: '1000023', areaName: '科普', platform: PlatformIds.kuaishou),
    LiveArea(areaId: '1000022', areaName: '教育', platform: PlatformIds.kuaishou),
  ];

  /// Category rooms — port of Pure Live 3.x: game boards
  /// (`gameboard/list`, short numeric ids) vs non-game boards
  /// (`non-gameboard/list`, long 10000xx ids), split on id length < 7.
  @override
  Future<List<LiveRoom>> getCategoryRooms(
    LiveArea area, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final api = area.areaId.length < 7
        ? 'https://live.kuaishou.com/live_api/gameboard/list'
        : 'https://live.kuaishou.com/live_api/non-gameboard/list';
    final response = await _dio.get<dynamic>(
      api,
      queryParameters: <String, dynamic>{
        'filterType': 0,
        'pageSize': 20,
        'gameId': area.areaId,
        'page': page,
      },
      options: Options(headers: _headers),
    );
    return parseKuaishouCategoryRooms(_decodeJson(response.data));
  }

  /// Author search — returns ANCHORS as rooms (no viewer count, only a
  /// `living` flag). The web search page never lists rooms, so finding
  /// the anchor and opening their room is the whole flow.
  @override
  Future<List<LiveRoom>> searchRooms(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    return _searchAuthors(keyword, page: page, pageSize: pageSize);
  }

  /// Same anchor list as [searchRooms]: in this project both searches
  /// return [LiveRoom]s, and Kuaishou has no separate room search.
  @override
  Future<List<LiveRoom>> searchAnchors(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    return _searchAuthors(keyword, page: page, pageSize: pageSize);
  }

  Future<List<LiveRoom>> _searchAuthors(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final response = await _dio.get<dynamic>(
      _authorSearchUrl,
      queryParameters: <String, dynamic>{
        'keyword': keyword,
        'page': page,
        'lssid': '',
      },
      options: Options(headers: <String, String>{
        ..._headers,
        'Referer':
            'https://live.kuaishou.com/search?keyword=${Uri.encodeQueryComponent(keyword)}',
      }),
    );
    final rooms = parseKuaishouAuthorSearch(_decodeJson(response.data));
    return rooms.take(pageSize.clamp(1, 100)).toList(growable: false);
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
