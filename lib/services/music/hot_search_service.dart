// Hot search words — real platform data only, never fabricated.
//
// Beans `SearchView.loadHotWords` (SearchView.swift:774-784) loads per
// platform: QQ `hotKeys()`, Kugou `hotWords()`, NetEase `hotSearch()`.
// `hotSearch(platform)` keeps that per-platform shape so the stage-2
// platform-switch capsule can plug straight in.
//
// Live verification from this VM (2026-11-18, curl):
// - NetEase (wy): GET https://music.163.com/api/search/hot?type=1111
//   -> HTTP 200, {"code":200,"result":{"hots":[{"first":...}]}} —
//   WORKS (unsigned GET; the earlier 404 finding was the weapi-
//   encrypted POST path Beans uses, not this GET).
// - QQ (tx): GET https://c.y.qq.com/splcloud/fcgi-bin/gethotkey.fcg
//   ?g_tk=5381&format=json&inCharset=utf8&outCharset=utf-8&notice=0
//   &platform=yqq.json&needNewCode=0 -> HTTP 200, {"code":0,
//   "data":{"hotkey":[{"k":...,"n":...}]}} — WORKS. Keys carry
//   trailing spaces and are trimmed here. (The returned list looks
//   stale upstream — 2019-era entries — but it is what QQ returns;
//   it is real data, not ours to edit.)
// - Kugou (kg): mobilecdn.kugou.com/api/v3/search/hot -> timeout
//   (HTTP 000); gateway.kugou.com/v1/search/hot -> 502. NO working
//   endpoint found, so Kugou returns [] — and Beans' own
//   `KugouMusicAPI.hotWords()` is a hardcoded 10-word list, which is
//   fabricated data by our rule, so it is NOT copied.
// - Kuwo (kw) / Migu (mg): no hot endpoint verified -> [].
// A platform with no working endpoint returns an empty list and the
// UI hides the section; nothing is ever made up to fill it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'music_models.dart';

class HotSearchService {
  HotSearchService({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
    final response = await request.close();
    if (response.statusCode != 200) return null;
    final body = await response.transform(utf8.decoder).join();
    final data = jsonDecode(body);
    return data is Map<String, dynamic> ? data : null;
  }

  /// NetEase hot payload -> words (`result.hots[].first`).
  /// Extracted for tests: the network half is `_getJson`, the parse
  /// half is pure and runs on canned JSON.
  @visibleForTesting
  static List<String> parseNetEase(Map<String, dynamic> data, int limit) {
    final result = data['result'];
    if (result is! Map) return [];
    final hots = result['hots'];
    if (hots is! List) return [];
    return hots
        .map((e) => e is Map ? (e['first']?.toString() ?? '') : '')
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty)
        .take(limit)
        .toList();
  }

  /// QQ hot payload -> words (`data.hotkey[].k`, trailing spaces trimmed).
  @visibleForTesting
  static List<String> parseQQ(Map<String, dynamic> data, int limit) {
    final inner = data['data'];
    if (inner is! Map) return [];
    final hotkey = inner['hotkey'];
    if (hotkey is! List) return [];
    return hotkey
        .map((e) => e is Map ? (e['k']?.toString() ?? '') : '')
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty)
        .take(limit)
        .toList();
  }

  /// Real hot words for [platform], up to [limit]. Empty when the
  /// platform has no working hot endpoint (never fabricated).
  Future<List<String>> hotSearch(
    MusicPlatform platform, {
    int limit = 10,
  }) async {
    try {
      switch (platform) {
        case MusicPlatform.wy:
          final data = await _getJson(
            Uri.https('music.163.com', '/api/search/hot', {'type': '1111'}),
          );
          if (data == null) return [];
          return parseNetEase(data, limit);
        case MusicPlatform.tx:
          final data = await _getJson(
            Uri.https('c.y.qq.com', '/splcloud/fcgi-bin/gethotkey.fcg', {
              'g_tk': '5381',
              'format': 'json',
              'inCharset': 'utf8',
              'outCharset': 'utf-8',
              'notice': '0',
              'platform': 'yqq.json',
              'needNewCode': '0',
            }),
          );
          if (data == null) return [];
          return parseQQ(data, limit);
        case MusicPlatform.kg:
        case MusicPlatform.kw:
        case MusicPlatform.mg:
          return [];
      }
    } catch (_) {
      return [];
    }
  }
}
