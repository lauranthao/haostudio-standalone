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
