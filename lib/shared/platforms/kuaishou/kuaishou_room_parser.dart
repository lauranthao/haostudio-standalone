// Kuaishou response parsers — pure functions, no network.
//
// Port of Pure Live 3.x `lib/shared/platforms/kuaishou/kuaishou_site.dart`:
// `parsePlayQualities` (same-quality URLs merged/deduped = one quality ->
// N lines), `_loadRoom` (room-page `window.__INITIAL_STATE__`), the
// `live_api/home/list` recommend feed, and `parseAuthorSearch`.
//
// ROOMID RULE (fixes the old Swift/web bug): the room identifier is
// `author.id`, NEVER `liveStream.id`. The live-stream id is only the
// danmaku/feed credential (`danmakuData['liveStreamId']`) and the `link`
// value for the native kwai:// deep link.

import 'dart:convert';

import '../../../core/models/live_models.dart';
import '../live_site.dart';
import 'kuaishou_models.dart';

/// Parse `window.__INITIAL_STATE__` out of a room-page HTML document.
///
/// Balanced-brace extraction (string-aware), so a `;` or `</script>`
/// inside a JSON string value cannot truncate the state the way Pure
/// Live's non-greedy `window.__INITIAL_STATE__=(.*?);` regex can. The
/// upstream regex is kept as a fallback. Throws [FormatException] when
/// no parseable state is found.
Map<String, dynamic> extractKuaishouInitialState(String html) {
  const marker = 'window.__INITIAL_STATE__';
  final markerIndex = html.indexOf(marker);
  if (markerIndex >= 0) {
    final start = html.indexOf('{', markerIndex + marker.length);
    if (start >= 0) {
      final end = _matchingBraceEnd(html, start);
      if (end != null) {
        try {
          final decoded =
              _decodeStateJson(html.substring(start, end));
          if (decoded != null) return decoded;
        } on FormatException {
          // Fall through to the regex below.
        }
      }
    }
  }
  final match = RegExp(
    r'window\.__INITIAL_STATE__\s*=\s*(.*?);\s*</script>',
    dotAll: true,
  ).firstMatch(html);
  if (match != null) {
    final decoded = _decodeStateJson(match.group(1)!);
    if (decoded != null) return decoded;
  }
  throw const FormatException('Kuaishou initial state is missing');
}

Map<String, dynamic>? _decodeStateJson(String text) {
  try {
    // The state embeds bare `undefined` values; JSON needs `null`.
    final decoded = jsonDecode(text.replaceAll('undefined', 'null'));
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  } on FormatException {
    return null;
  }
}

/// Index just past the `}` matching the `{` at [start], or null when
/// the braces never balance (or a string never terminates).
int? _matchingBraceEnd(String text, int start) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final c = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
    } else {
      if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return i + 1;
      }
    }
  }
  return null;
}

/// Parse a Kuaishou room page into a [LiveRoom].
///
/// Reads `liveroom.playList[0]` (current shape), falling back to a
/// top-level `room` object (older shape, also what the danmaku
/// transport scrapes). The room id is `author.id`; the live-stream id
/// goes to `danmakuData['liveStreamId']` and `link` only. An offline
/// room (empty `liveStream`, `isLiving: false`, or an `errorType`
/// card such as the rate-limit "请求过快，请稍后重试") parses as
/// `liveStatus: false` with whatever author info the page carried —
/// never throws for a reachable page. Throws [FormatException] when
/// the page carries no room metadata at all.
LiveRoom parseKuaishouRoomPage(String html, String roomId) {
  final state = extractKuaishouInitialState(html);
  Map<String, dynamic>? room;
  final liveRoom = state['liveroom'];
  if (liveRoom is Map) {
    final playList = liveRoom['playList'];
    if (playList is List && playList.isNotEmpty) {
      final first = playList.first;
      if (first is Map<String, dynamic>) {
        room = first;
      } else if (first is Map) {
        room = Map<String, dynamic>.from(first);
      }
    }
  }
  room ??= state['room'] is Map
      ? Map<String, dynamic>.from(state['room'] as Map)
      : null;
  if (room == null) {
    throw const FormatException('Kuaishou room metadata is missing');
  }

  final liveStream = _asMap(room['liveStream']);
  final author = _asMap(room['author']);
  final gameInfo = _asMap(room['gameInfo']);
  final rawLiveState = room['isLiving'];
  final live = rawLiveState == true ||
      rawLiveState == 1 ||
      rawLiveState?.toString().toLowerCase() == 'true';
  final description = author['description']?.toString() ?? '';
  final liveStreamId = liveStream['id']?.toString() ?? '';
  final poster = liveStream['poster']?.toString() ?? '';
  final playUrls = liveStream['playUrls'];
  return LiveRoom(
    roomId: author['id']?.toString() ?? roomId,
    platform: PlatformIds.kuaishou,
    title: description.replaceAll('\n', ' '),
    cover: _posterUrl(poster),
    nick: author['name']?.toString() ?? '',
    avatar: author['avatar']?.toString() ?? '',
    watching: live ? _asInt(gameInfo['watchingCount']) ?? 0 : 0,
    liveStatus: live,
    link: liveStreamId,
    data: playUrls == null
        ? null
        : <String, dynamic>{'playUrls': playUrls},
    danmakuData: liveStreamId.isEmpty
        ? null
        : <String, dynamic>{'liveStreamId': liveStreamId},
  );
}

/// Parse Kuaishou `playUrls` descriptors into qualities.
///
/// Both current room-page and recommendation payloads are handled:
/// room pages expose `{h264: ..., hevc: ...}` while list/replay entries
/// are usually a direct adaptation-set descriptor. Multiple descriptors
/// can represent CDN lines, so URLs of the same quality are merged and
/// deduped into one quality -> N lines (one group per quality, by
/// platform design). No re-signing: the URLs arrive signed. An empty
/// result means the room is unplayable — callers return it as-is,
/// never invent a quality.
List<LivePlayQuality> parseKuaishouPlayQualities(dynamic raw) {
  final descriptors = raw is List ? raw : <dynamic>[raw];
  final merged = <String, _MergedQuality>{};

  for (final rawDescriptor in descriptors) {
    if (rawDescriptor is! Map) continue;
    final sets = <_CodecSet>[];
    for (final codec in const ['h264', 'avc']) {
      final candidate = rawDescriptor[codec];
      if (_representationsOf(candidate).isNotEmpty) {
        sets.add(
          _CodecSet(
            suffix: '',
            codecRank: 0,
            codec: 'avc',
            descriptor: candidate,
          ),
        );
        break;
      }
    }
    for (final codec in const ['hevc', 'h265']) {
      final candidate = rawDescriptor[codec];
      if (_representationsOf(candidate).isNotEmpty) {
        sets.add(
          _CodecSet(
            suffix: ' · H.265',
            codecRank: 1,
            codec: 'hevc',
            descriptor: candidate,
          ),
        );
        break;
      }
    }
    if (sets.isEmpty) {
      sets.add(
        _CodecSet(
          suffix: '',
          codecRank: 0,
          codec: null,
          descriptor: rawDescriptor,
        ),
      );
    }

    for (final set in sets) {
      for (final item in _representationsOf(set.descriptor)) {
        if (item is! Map) continue;
        final url = item['url']?.toString().trim() ?? '';
        final uri = Uri.tryParse(url);
        if (uri?.isAbsolute != true ||
            (!url.startsWith('http://') &&
                !url.startsWith('https://'))) {
          continue;
        }
        final sort =
            _asInt(item['level']) ?? _asInt(item['bitrate']) ?? 0;
        final rawName = item['name']?.toString().trim().isNotEmpty == true
            ? item['name'].toString().trim()
            : item['shortName']?.toString().trim().isNotEmpty == true
                ? item['shortName'].toString().trim()
                : item['qualityType']?.toString().trim().isNotEmpty == true
                    ? item['qualityType'].toString().trim()
                    : '清晰度 $sort';
        final name =
            set.suffix.isEmpty ? rawName : '$rawName${set.suffix}';
        final key = '$name\u0000$sort';
        final existing = merged[key];
        if (existing == null) {
          merged[key] = _MergedQuality(
            name: name,
            sort: sort,
            codecRank: set.codecRank,
            urls: <String>[url],
            facts: <LiveStreamFacts>[
              LiveStreamFacts(
                format: kuaishouStreamFormat(url),
                codec: set.codec,
              ),
            ],
          );
        } else if (!existing.urls.contains(url)) {
          existing.urls.add(url);
          existing.facts.add(
            LiveStreamFacts(
              format: kuaishouStreamFormat(url),
              codec: set.codec,
            ),
          );
        }
      }
    }
  }

  final entries = merged.values.toList(growable: false)
    ..sort((a, b) {
      if (a.codecRank != b.codecRank) {
        return a.codecRank.compareTo(b.codecRank);
      }
      return b.sort.compareTo(a.sort);
    });
  return entries
      .map(
        (entry) => LivePlayQuality(
          quality: normalizeKuaishouQualityLabel(entry.name),
          id: '${entry.name}\u0000${entry.sort}',
          sort: entry.sort,
          data: KuaishouQualityData(
            urls: List<String>.unmodifiable(entry.urls),
            facts: List<LiveStreamFacts>.unmodifiable(entry.facts),
          ).toDataMap(),
        ),
      )
      .toList(growable: false);
}

/// Normalise a Kuaishou quality label for display, without changing the
/// opaque id used to request that stream. CJK labels (what Kuaishou
/// actually serves: 高清 / 超清 / 蓝光 4M / 蓝光 质臻) pass through
/// untouched; bare SDK tokens map onto the same vocabulary (port of
/// Pure Live's `LiveQualityLabel` generic branch).
String normalizeKuaishouQualityLabel(String rawLabel) {
  final raw = rawLabel.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (RegExp(r'[\u3400-\u9fff]').hasMatch(raw)) return raw;
  final token =
      raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  return switch (token) {
    'original' || 'origin' || 'origion' || 'source' => '原画',
    'blue' || 'bluray' || 'blueray' => '蓝光',
    'uhd' || 'super' || 'superhd' || 'fullhd' || 'fhd' => '超清',
    'hd' || 'high' => '高清',
    'sd' || 'standard' || 'medium' => '标清',
    'low' || 'ld' || 'smooth' || 'fluent' => '流畅',
    'auto' => '自动',
    'default' => '默认',
    _ => raw.isNotEmpty ? raw : '默认',
  };
}

/// Parse the `live_api/home/list` recommend feed into rooms.
///
/// Shape: `data.list[].gameLiveInfo[].liveInfo[]`, each with `author`,
/// `gameInfo`, `id` (= liveStreamId), `watchingCount`, `playUrls`.
/// The room id is `author.id`. The cover is the stream screenshot
/// (`poster`), falling back to the game poster. A card whose `living`
/// flag is explicitly false is a replay card — reported offline, its
/// signed replay URLs still carried in `data` (same as Pure Live's
/// record-room handling).
List<LiveRoom> parseKuaishouRecommendRooms(dynamic json) {
  final data = json is Map ? json['data'] : null;
  final list = data is Map ? data['list'] : null;
  if (list is! List) return const [];
  final rooms = <LiveRoom>[];
  for (final section in list) {
    if (section is! Map) continue;
    final gameLiveInfo = section['gameLiveInfo'];
    if (gameLiveInfo is! List) continue;
    for (final group in gameLiveInfo) {
      if (group is! Map) continue;
      final liveInfo = group['liveInfo'];
      if (liveInfo is! List) continue;
      for (final item in liveInfo) {
        if (item is! Map) continue;
        final author = _asMap(item['author']);
        final gameInfo = _asMap(item['gameInfo']);
        final authorId = author['id']?.toString() ?? '';
        if (authorId.isEmpty) continue;
        final liveStreamId = item['id']?.toString() ?? '';
        final description = author['description']?.toString() ?? '';
        final streamPoster = item['poster']?.toString() ?? '';
        final gamePoster = gameInfo['poster']?.toString() ?? '';
        final cover = streamPoster.isNotEmpty ? streamPoster : gamePoster;
        final living = item['living'];
        final live = living is bool ? living : true;
        final playUrls = item['playUrls'];
        rooms.add(
          LiveRoom(
            roomId: authorId,
            platform: PlatformIds.kuaishou,
            title: description.replaceAll('\n', ' '),
            cover: _posterUrl(cover),
            nick: author['name']?.toString() ?? '',
            avatar: author['avatar']?.toString() ?? '',
            watching: _asInt(item['watchingCount']) ?? 0,
            liveStatus: live,
            link: liveStreamId,
            data: playUrls == null
                ? null
                : <String, dynamic>{'playUrls': playUrls},
            danmakuData: liveStreamId.isEmpty
                ? null
                : <String, dynamic>{'liveStreamId': liveStreamId},
          ),
        );
      }
    }
  }
  return rooms;
}

/// Parse the `live_api/search/author` response into anchor rooms.
///
/// The endpoint returns ANCHORS, not rooms: no viewer count, only a
/// `living` flag (and `bannedStatus`). A Kuaishou search therefore
/// finds the anchor; opening the anchor's room fetches the live
/// detail. `watching` is 0 (unknown, never a fabricated count) and
/// banned anchors report offline. The room id is the anchor id.
List<LiveRoom> parseKuaishouAuthorSearch(dynamic json) {
  final data = json is Map ? json['data'] : null;
  final list = data is Map ? data['list'] : null;
  if (list is! List) return const [];
  final rooms = <LiveRoom>[];
  for (final author in list) {
    if (author is! Map) continue;
    final id = author['id']?.toString().trim() ?? '';
    if (id.isEmpty) continue;
    final name = author['name']?.toString() ?? '';
    final avatar = author['avatar']?.toString() ?? '';
    final banned = author['bannedStatus'];
    final isBanned =
        banned is Map && banned['banned'] == true;
    final live = !isBanned && author['living'] == true;
    rooms.add(
      LiveRoom(
        roomId: id,
        platform: PlatformIds.kuaishou,
        title: name,
        cover: avatar,
        nick: name,
        avatar: avatar,
        watching: 0,
        liveStatus: live,
        link: 'https://live.kuaishou.com/u/$id',
      ),
    );
  }
  return rooms;
}

// ------------------------------------------------------------ helpers

List<dynamic> _representationsOf(dynamic descriptor) {
  if (descriptor is! Map) return const [];
  final adaptationSet = descriptor['adaptationSet'];
  final representations = adaptationSet is Map
      ? adaptationSet['representation']
      : descriptor['representation'];
  if (representations is List) return representations;
  return const [];
}

int? _asInt(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return const <String, dynamic>{};
}

/// Pure Live appends `.jpg` when a poster URL carries no image
/// extension; an empty poster stays empty (never `null.jpg`).
String _posterUrl(String poster) {
  if (poster.isEmpty) return '';
  return _isImage(poster) ? poster : '$poster.jpg';
}

bool _isImage(String url) {
  const imageExtensions = <String>{
    'svgz', 'pjp', 'png', 'ico', 'avif', 'tiff', 'tif', 'jfif', 'svg',
    'xbm', 'pjpeg', 'webp', 'jpg', 'jpeg', 'bmp', 'gif',
  };
  if (url.isEmpty) return false;
  final ext = url.split('.').last.toLowerCase().split('?').first;
  return imageExtensions.contains(ext);
}

class _CodecSet {
  const _CodecSet({
    required this.suffix,
    required this.codecRank,
    required this.codec,
    required this.descriptor,
  });

  final String suffix;
  final int codecRank;
  final String? codec;
  final dynamic descriptor;
}

class _MergedQuality {
  _MergedQuality({
    required this.name,
    required this.sort,
    required this.codecRank,
    required this.urls,
    required this.facts,
  });

  final String name;
  final int sort;
  final int codecRank;
  final List<String> urls;
  final List<LiveStreamFacts> facts;
}
