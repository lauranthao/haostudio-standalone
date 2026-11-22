// Link toolbox — item 9 (build 29, I group).
//
// Paste any platform live link and jump into the room. Pure parser
// first (no network): the five platforms' canonical web URLs plus
// the short-link hosts that redirect to them. Short links
// (v.douyin.com, etc.) cannot be parsed from the text alone —
// [resolveShortLink] follows the redirect with Dio and re-parses the
// landing URL; a landing URL that still does not parse is a clean
// failure, never a guessed room.
//
// Patterns (verified against the adapters' own link builders):
// - bilibili: live.bilibili.com/{roomId} (numeric)
// - douyu: douyu.com/{roomId} (numeric)
// - huya: huya.com/{roomId} (alphanumeric)
// - douyin: live.douyin.com/{webRid} (numeric webRid — the room
//   detail call resolves it; the adapter's DouyinSite accepts a
//   webRid as roomId, see douyin_site getRoomDetail)
// - kuaishou: live.kuaishou.com/u/{userId} — the user id is NOT the
//   liveStreamId; the room page resolves the live room from it via
//   the adapter, so the parse keeps the raw id and the room entry
//   passes it through as roomId (same as a history entry would).
//   Short form: kuaishou.com short links + v.kuaishou.com redirect.
// - douyin short: v.douyin.com/{code} (redirect, needs resolve).
//
// Anything else (a video page, a user homepage, garbage) returns
// null — the sheet says so plainly instead of opening a wrong room.

import 'package:dio/dio.dart';

/// A pasted link resolved to a platform + room id.
class ParsedLiveLink {
  const ParsedLiveLink({
    required this.platform,
    required this.roomId,
    required this.sourceUrl,
  });

  /// Platform id (bilibili / douyu / huya / douyin / kuaishou).
  final String platform;

  /// Room id (or webRid / user id for Douyin / Kuaishou — the room
  /// entry resolves it through the platform adapter).
  final String roomId;

  /// The URL that was parsed (after redirect resolution when the
  /// input was a short link).
  final String sourceUrl;

  @override
  String toString() => '$platform:$roomId';
}

/// Hosts that are short links: the id in the URL is a redirect code,
/// not a room id. Only these hosts go through [resolveShortLink].
const Set<String> _shortLinkHosts = {
  'v.douyin.com',
  'v.kuaishou.com',
  'kuaishou.com',
  'douyin.com',
};

/// Parse [input] (a pasted link, with or without scheme) into a
/// platform + room id. Returns null when the text is not a live
/// link for one of the five platforms. Never throws.
ParsedLiveLink? parseLiveLink(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  // The link may be pasted with surrounding text ("看看这个 …") —
  // extract the first URL-like token.
  final urlMatch = RegExp(
    r'https?://[^\s\u4e00-\u9fff]+',
  ).firstMatch(text);
  final candidate = urlMatch?.group(0) ?? text;
  final withScheme = candidate.startsWith('http')
      ? candidate
      : 'https://$candidate';
  Uri? uri;
  try {
    uri = Uri.parse(withScheme);
  } catch (_) {
    return null;
  }
  final host = uri.host.toLowerCase().replaceFirst('www.', '');
  final path = uri.path;

  ParsedLiveLink? live(String platform, String id) {
    final clean = id.trim();
    if (clean.isEmpty) return null;
    return ParsedLiveLink(
      platform: platform,
      roomId: clean,
      sourceUrl: uri.toString(),
    );
  }

  // Bilibili live: live.bilibili.com/{roomId}
  if (host == 'live.bilibili.com') {
    final m = RegExp(r'^/(\d+)').firstMatch(path);
    if (m != null) return live('bilibili', m.group(1)!);
    return null;
  }
  // Douyu: www.douyu.com/{roomId} (numeric room pages only —
  // /directory/... and other paths are not rooms).
  if (host == 'douyu.com') {
    final m = RegExp(r'^/(\d+)(?:[/?#]|$)').firstMatch(path);
    if (m != null) return live('douyu', m.group(1)!);
    return null;
  }
  // Huya: www.huya.com/{roomId}
  if (host == 'huya.com') {
    final m = RegExp(r'^/([A-Za-z0-9_-]+)(?:[/?#]|$)').firstMatch(path);
    if (m != null) {
      final id = m.group(1)!;
      if (id != 'live' && !id.startsWith('g/')) {
        return live('huya', id);
      }
    }
    return null;
  }
  // Douyin live: live.douyin.com/{webRid}
  if (host == 'live.douyin.com') {
    final m = RegExp(r'^/(\d+)').firstMatch(path);
    if (m != null) return live('douyin', m.group(1)!);
    return null;
  }
  // Kuaishou live: live.kuaishou.com/u/{userId}
  if (host == 'live.kuaishou.com') {
    final m = RegExp(r'^/u/([A-Za-z0-9_-]+)').firstMatch(path);
    if (m != null) return live('kuaishou', m.group(1)!);
    return null;
  }
  // Short links carry no room id — the caller must resolve them.
  if (_shortLinkHosts.contains(host)) return null;
  return null;
}

/// True when [input] looks like a short link that needs redirect
/// resolution before parsing.
bool isShortLiveLink(String input) {
  final text = input.trim();
  if (text.isEmpty) return false;
  try {
    final uri = Uri.parse(
      text.startsWith('http') ? text : 'https://$text',
    );
    return _shortLinkHosts.contains(
      uri.host.toLowerCase().replaceFirst('www.', ''),
    );
  } catch (_) {
    return false;
  }
}

/// Follow one short link to its landing URL and parse that. Uses a
/// HEAD/GET with redirects enabled and a 10 s cap; any failure
/// returns null (never a guessed room). [dio] is injectable for
/// tests; production passes none.
Future<ParsedLiveLink?> resolveShortLink(
  String input, {
  Dio? dio,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = dio ?? Dio();
  final url = input.trim().startsWith('http')
      ? input.trim()
      : 'https://${input.trim()}';
  try {
    final response = await client
        .get<dynamic>(
          url,
          options: Options(
            followRedirects: true,
            maxRedirects: 5,
            validateStatus: (s) => s != null && s < 400,
          ),
        )
        .timeout(timeout);
    // Dio's finalUri is the landing URL after redirects; fall back
    // to the request path when the client does not expose it.
    final landing = response.realUri.toString();
    return parseLiveLink(landing);
  } catch (_) {
    return null;
  }
}

/// Parse, resolving short links when needed. Returns null when the
/// text is not a live link on any of the five platforms.
Future<ParsedLiveLink?> parseOrResolveLiveLink(
  String input, {
  Dio? dio,
}) async {
  final direct = parseLiveLink(input);
  if (direct != null) return direct;
  if (isShortLiveLink(input)) return resolveShortLink(input, dio: dio);
  return null;
}
