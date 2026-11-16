// Huya room-page / list / search parsing — pure functions, no network.
//
// Port of the parsing inside Pure Live 3.x
// lib/shared/platforms/huya/huya_site.dart (_loadRoomDetail L608-755,
// parsePlayQualities L282-320, getCategoryRooms / getRecommendRooms,
// searchRooms L761-831, searchAnchors L832-874).
//
// Room detail is an HTML scrape: `GET https://www.huya.com/<roomId>`,
// then `var TT_ROOM_DATA = {...}` + `stream: {...}` (patterns in
// huya_request_params.dart). The regexes LOCATE the blobs; extraction then
// scans balanced braces so nested objects are not truncated by the regex's
// non-greedy `}` (the upstream regex alone stops at the first `}`).

import 'dart:convert';

import '../../../core/models/live_models.dart';
import 'huya_models.dart';
import 'huya_request_params.dart';

/// Parses a Huya room page into a detailed [LiveRoom].
///
/// * `gameLiveInfo.state == 'ON'` (and not a replay) ⇒ live.
/// * Offline / replay rooms still return a room (liveStatus false, empty
///   lines/bitRates) — never throws for "offline".
/// * Throws [FormatException] when the page carries no parseable
///   TT_ROOM_DATA / stream blobs at all.
LiveRoom parseHuyaRoomPage(String html, String roomId) {
  final roomJson = _extractJsonObject(html, HuyaRequestParams.roomDataRegex);
  final streamJson = _extractJsonObject(html, HuyaRequestParams.streamRegex);
  if (roomJson == null || streamJson == null) {
    throw const FormatException(
        'Huya room playback metadata is unavailable');
  }

  final roomData = roomJson;
  final streamDataList = streamJson['data'];
  if (streamDataList is! List || streamDataList.isEmpty) {
    throw const FormatException('Huya room stream data is unavailable');
  }
  final streamData = streamDataList.first;
  if (streamData is! Map) {
    throw const FormatException('Huya room stream data is unavailable');
  }
  final gameLiveInfo = streamData['gameLiveInfo'] is Map
      ? Map<String, dynamic>.from(streamData['gameLiveInfo'] as Map)
      : <String, dynamic>{};

  final state = roomData['state']?.toString() ?? '';
  final isReplay = roomData['isReplay'] == true;
  final isLiving = state == 'ON' && !isReplay;

  var topSid = 0;
  var subSid = 0;
  final lines = <HuyaLineModel>[];
  final bitRates = <HuyaBitRateModel>[];
  if (isLiving) {
    final streamInfoList = streamData['gameStreamInfoList'];
    if (streamInfoList is List && streamInfoList.isNotEmpty) {
      final first = streamInfoList.first;
      if (first is Map) {
        topSid = int.tryParse(first['lChannelId'].toString()) ?? 0;
        subSid = int.tryParse(first['lSubChannelId'].toString()) ?? 0;
      }
      const lineTypes = {
        'sFlvUrl': HuyaLineType.flv,
        'sHlsUrl': HuyaLineType.hls,
      };
      for (final item in streamInfoList) {
        if (item is! Map) continue;
        for (final entry in lineTypes.entries) {
          final url = item[entry.key]?.toString() ?? '';
          if (url.isEmpty) continue;
          lines.add(HuyaLineModel(
            line: url,
            lineType: entry.value,
            flvAntiCode: item['sFlvAntiCode']?.toString() ?? '',
            hlsAntiCode: item['sHlsAntiCode']?.toString() ?? '',
            streamName: item['sStreamName']?.toString() ?? '',
            cdnType: item['sCdnType']?.toString() ?? '',
            presenterUid:
                int.tryParse(item['presenterUid']?.toString() ?? '') ?? topSid,
          ));
        }
      }
    }
    final multi = streamJson['vMultiStreamInfo'];
    if (multi is List) {
      for (final item in multi) {
        if (item is! Map) continue;
        final name = item['sDisplayName']?.toString() ?? '';
        if (name.contains('HDR')) continue;
        bitRates.add(HuyaBitRateModel(
          bitRate: item['iBitRate'] is int
              ? item['iBitRate'] as int
              : int.tryParse(item['iBitRate']?.toString() ?? '') ?? 0,
          name: name,
        ));
      }
    }
  }

  final popularity = _roomPopularity(gameLiveInfo);
  final danmakuUid =
      int.tryParse(gameLiveInfo['uid']?.toString() ?? '') ?? 0;

  return LiveRoom(
    roomId: roomId,
    platform: PlatformIds.huya,
    title: gameLiveInfo['introduction']?.toString() ?? '',
    cover: gameLiveInfo['screenshot']?.toString() ?? '',
    nick: gameLiveInfo['nick']?.toString() ?? '',
    avatar: gameLiveInfo['avatar180']?.toString() ?? '',
    watching: int.tryParse(popularity) ?? 0,
    liveStatus: isLiving,
    link: 'https://www.huya.com/$roomId',
    data: HuyaUrlDataModel(
      bitRates: bitRates,
      lines: lines,
      url: '',
      uid: '',
      isXingxiu: gameLiveInfo['gid'] == 1663,
    ).toDataMap(),
    danmakuData: HuyaDanmakuArgs(
      uid: danmakuUid,
      topSid: topSid,
      subSid: subSid,
    ).toDataMap(),
  );
}

/// Huya's room detail returns `userCount` and `totalCount` as the same
/// multi-million popularity value — it is heat, not a concurrent head count.
String _roomPopularity(Map<String, dynamic> liveData) {
  final totalCount = liveData['totalCount']?.toString().trim() ?? '';
  final userCount = liveData['userCount']?.toString().trim() ?? '';
  return totalCount.isNotEmpty ? totalCount : userCount;
}

/// Quality menu from a room snapshot (upstream parsePlayQualities).
///
/// Only rates the server returned in vMultiStreamInfo: `4K` excluded, no
/// invented 2000 fallback, bitRate 0 = 原画. When the server returned no
/// rates at all but lines exist, a single 原画 entry is offered (upstream
/// behaviour — source quality needs no `ratio` param).
List<LivePlayQuality> parseHuyaPlayQualities(HuyaUrlDataModel data) {
  final playbackLines = List<HuyaLineModel>.unmodifiable(data.lines);
  final rates = data.bitRates.isEmpty
      ? <HuyaBitRateModel>[const HuyaBitRateModel(name: '原画', bitRate: 0)]
      : data.bitRates;
  final unique = <int, HuyaBitRateModel>{};
  for (final rate in rates) {
    if (rate.bitRate < 0 || rate.name.trim().isEmpty) continue;
    if (rate.name == '4K') continue;
    unique.putIfAbsent(rate.bitRate, () => rate);
  }
  return unique.values
      .map(
        (rate) => LivePlayQuality(
          quality: rate.name,
          id: rate.bitRate.toString(),
          sort: rate.bitRate == 0 ? 1 << 30 : rate.bitRate,
          data: <String, Object>{'urls': playbackLines, 'bitRate': rate.bitRate},
        ),
      )
      .toList(growable: false);
}

/// Parses a `cache.php` LiveList response (`data.datas[]`) — shared by
/// getRecommendRooms (hot list, no gameId) and getCategoryRooms (gameId).
///
/// NOTE: the category endpoint was reported dead at inventory time
/// (cache.php returning `datas: []`), so the hot list is the fallback
/// and category rooms may come back empty — but probed live from this VM
/// on 2026-11-16, cache.php returned 120 datas for BOTH the hot list
/// and `gameId=1`. There is no alternate hot/category list API in Pure
/// Live 3.x; an empty result is returned as-is rather than faked.
List<LiveRoom> parseHuyaCacheList(dynamic decoded) {
  final items = <LiveRoom>[];
  final datas = decoded is Map
      ? (decoded['data'] is Map ? decoded['data']['datas'] : null)
      : null;
  if (datas is! List) return items;
  for (final item in datas) {
    if (item is! Map) continue;
    var cover = item['screenshot']?.toString() ?? '';
    if (cover.isNotEmpty && !cover.contains('?')) {
      cover += '?x-oss-process=style/w338_h190&';
    }
    var title = item['introduction']?.toString() ?? '';
    if (title.isEmpty) title = item['roomName']?.toString() ?? '';
    items.add(LiveRoom(
      roomId: item['profileRoom']?.toString() ?? '',
      platform: PlatformIds.huya,
      title: title,
      cover: cover,
      nick: item['nick']?.toString() ?? '',
      avatar: item['avatar180']?.toString() ?? '',
      watching: int.tryParse(item['totalCount']?.toString() ?? '') ?? 0,
      liveStatus: true,
      link: 'https://www.huya.com/${item['profileRoom']?.toString() ?? ''}',
    ));
  }
  return items;
}

/// Parses a search.cdn.huya.com response for rooms
/// (`response["3"]["docs"]`).
List<LiveRoom> parseHuyaSearchRooms(dynamic decoded) {
  final items = <LiveRoom>[];
  final docs = decoded is Map
      ? (decoded['response'] is Map ? decoded['response']['3'] : null)
      : null;
  final list = docs is Map ? docs['docs'] : null;
  if (list is! List) return items;
  for (final item in list) {
    if (item is! Map) continue;
    var cover = item['game_screenshot']?.toString() ?? '';
    if (cover.isNotEmpty && !cover.contains('?')) {
      cover += '?x-oss-process=style/w338_h190&';
    }
    var title = item['game_introduction']?.toString() ?? '';
    if (title.isEmpty) title = item['game_roomName']?.toString() ?? '';
    items.add(LiveRoom(
      roomId: item['room_id']?.toString() ?? '',
      platform: PlatformIds.huya,
      title: title,
      cover: cover,
      nick: item['game_nick']?.toString() ?? '',
      avatar: item['game_imgUrl']?.toString() ?? '',
      watching: int.tryParse(item['game_total_count']?.toString() ?? '') ?? 0,
      liveStatus: true,
      link: 'https://www.huya.com/${item['room_id']?.toString() ?? ''}',
    ));
  }
  return items;
}

/// Parses a search.cdn.huya.com response for anchors
/// (`response["1"]["docs"]`), mapped onto LiveRoom (our searchAnchors
/// contract returns rooms, not a separate anchor type).
List<LiveRoom> parseHuyaSearchAnchors(dynamic decoded) {
  final items = <LiveRoom>[];
  final docs = decoded is Map
      ? (decoded['response'] is Map ? decoded['response']['1'] : null)
      : null;
  final list = docs is Map ? docs['docs'] : null;
  if (list is! List) return items;
  for (final item in list) {
    if (item is! Map) continue;
    final liveOn = item['gameLiveOn'];
    final isLive = liveOn is bool
        ? liveOn
        : liveOn is num
            ? liveOn != 0
            : liveOn?.toString().toLowerCase() == 'true';
    items.add(LiveRoom(
      roomId: item['room_id']?.toString() ?? '',
      platform: PlatformIds.huya,
      nick: item['game_nick']?.toString() ?? '',
      avatar: item['game_avatarUrl180']?.toString() ?? '',
      liveStatus: isLive,
      link: 'https://www.huya.com/${item['room_id']?.toString() ?? ''}',
    ));
  }
  return items;
}

/// Locates a JSON object with [pattern] and extracts it with balanced
/// brace scanning (string-aware), so nested objects survive. Falls back
/// to the regex's first capture group when the scan cannot run.
Map<String, dynamic>? _extractJsonObject(String text, String pattern) {
  final match = RegExp(pattern).firstMatch(text);
  if (match == null) return null;
  final braceAt = text.indexOf('{', match.start);
  if (braceAt < 0) return null;
  final end = _balancedBraceEnd(text, braceAt);
  final raw = end != null
      ? text.substring(braceAt, end + 1)
      : (match.groupCount >= 1 ? match.group(1) : null);
  if (raw == null) return null;
  try {
    final decoded = json.decode(raw);
    return decoded is Map<String, dynamic>
        ? decoded
        : decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : null;
  } on FormatException {
    return null;
  }
}

/// Index of the `}` closing the `{` at [openAt], or null if unbalanced.
/// String literals (with `\"` escapes) are skipped so braces inside
/// strings do not affect depth.
int? _balancedBraceEnd(String text, int openAt) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = openAt; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}
