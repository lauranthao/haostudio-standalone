// Music direct API — Dart port of app.js §1 (search, artist/album,
// plaza, comments, lyrics, alt-platform lookup).
//
// Transport: Dart Dio directly (the old nativeFetch bridge disappears in
// Flutter). Every call uses sharedDio() with per-call timeouts matching
// the JS values. Upstream failures return empty / null, never throw out
// of the per-platform search functions — the aggregator (fix 12) needs
// one platform failing to not kill the others.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../core/network/http_client.dart';
import 'music_models.dart';
import 'music_store.dart';

/// UA for all music search/detail/lyrics/comments/plaza calls.
const String kMusicUa =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 '
    'Safari/604.1';

/// Kugou 分享歌单参数 — from a share/zlist.html landing URL
/// (listid/uid/sign/_t/type/global_collection_id/chain).
typedef KgShare = ({
  String listid,
  String uid,
  String sign,
  String t,
  String type,
  String collection,
  String chain,
});

class MusicApi {
  MusicApi({Dio? dio}) : _dio = dio ?? sharedDio();

  final Dio _dio;

  // -- low-level helpers ---------------------------------------------------

  Future<Map<String, dynamic>?> _getJson(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Duration timeout = const Duration(seconds: 10),
    CancelToken? cancelToken,
  }) async {
    try {
      final res = await _dio.get<dynamic>(
        url,
        queryParameters: query,
        cancelToken: cancelToken,
        options: Options(
          headers: headers,
          receiveTimeout: timeout,
          responseType: ResponseType.json,
        ),
      );
      if (res.statusCode != 200) return null;
      final data = res.data;
      if (data is Map<String, dynamic>) return data;
      if (data is String) {
        try {
          final decoded = jsonDecode(data);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {}
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _postFormJson(
    String url,
    Map<String, String> fields, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    CancelToken? cancelToken,
  }) async {
    try {
      final body = fields.entries
          .map(
            (e) =>
                '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
          )
          .join('&');
      final res = await _dio.post<dynamic>(
        url,
        data: body,
        cancelToken: cancelToken,
        options: Options(
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            ...?headers,
          },
          receiveTimeout: timeout,
          responseType: ResponseType.json,
        ),
      );
      if (res.statusCode != 200) return null;
      final data = res.data;
      if (data is Map<String, dynamic>) return data;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _getText(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    CancelToken? cancelToken,
  }) async {
    try {
      final res = await _dio.get<String>(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: headers,
          receiveTimeout: timeout,
          responseType: ResponseType.plain,
        ),
      );
      if (res.statusCode != 200) return null;
      return res.data;
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, dynamic>> _asList(dynamic v) {
    if (v is List) return v.whereType<Map<String, dynamic>>().toList();
    return [];
  }

  /// Kuwo's single-quoted JSON yields string numbers after the quote
  /// swap — accept both num and String.
  static int _asInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  // -- song search (app.js:482-518) ----------------------------------------

  /// NetEase: POST music.163.com/api/cloudsearch/pc, type=1.
  Future<List<Song>> searchWy(
    String q,
    int limit, {
    CancelToken? cancelToken,
  }) async {
    final j = await _postFormJson('https://music.163.com/api/cloudsearch/pc', {
      's': q,
      'type': '1',
      'limit': '$limit',
      'offset': '0',
    }, cancelToken: cancelToken);
    final songs = _asList(j?['result']?['songs']);
    return songs.map((x) {
      final durMs = (x['duration'] as num?) ?? (x['dt'] as num?) ?? 0;
      final ar = _asList(x['ar']);
      final al = x['al'] as Map<String, dynamic>?;
      return Song(
        songId: x['id']?.toString() ?? '',
        title: x['name']?.toString() ?? '',
        artist: ar.map((a) => a['name']?.toString() ?? '').join('/'),
        album: al?['name']?.toString() ?? '',
        cover: coverHi(al?['picUrl']?.toString() ?? ''),
        platform: MusicPlatform.wy,
        dur: (durMs / 1000).round(),
      );
    }).toList();
  }

  /// QQ: GET c.y.qq.com search_for_qq_cp. songId is the songmid.
  Future<List<Song>> searchTx(
    String q,
    int limit, {
    CancelToken? cancelToken,
  }) async {
    final j = await _getJson(
      'https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp',
      headers: {'Referer': 'https://y.qq.com/', 'User-Agent': kMusicUa},
      cancelToken: cancelToken,
      query: {
        'g_tk': '5381',
        'uin': '0',
        'format': 'json',
        'inCharset': 'utf-8',
        'outCharset': 'utf-8',
        'notice': '0',
        'platform': 'h5',
        'needNewCode': '1',
        'w': q,
        'zhidaqu': '1',
        'catZhida': '1',
        't': '0',
        'flag': '1',
        'ie': 'utf-8',
        'sem': '1',
        'aggr': '0',
        'perpage': '$limit',
        'n': '$limit',
        'p': '1',
        'remoteplace': 'txt.mqq.all',
      },
    );
    final list = _asList(j?['data']?['song']?['list']);
    return list.map((x) {
      final singers = _asList(x['singer']);
      final albummid = x['albummid']?.toString() ?? '';
      return Song(
        songId: x['songmid']?.toString() ?? '',
        title: x['songname']?.toString() ?? '',
        artist: singers.map((a) => a['name']?.toString() ?? '').join('/'),
        album: x['albumname']?.toString() ?? '',
        cover: albummid.isEmpty
            ? ''
            : coverHi(
                'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albummid.jpg',
              ),
        platform: MusicPlatform.tx,
        dur: (x['interval'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  /// Kugou: GET songsearch.kugou.com. Retry once after 800 ms if the
  /// API answered 200 but with an empty list (its known flakiness —
  /// measured 2026-11-17: same query returned 15 results, then 0,
  /// then 0 within minutes). A null fetch (network/timeout) is NOT
  /// retried: burning another 10 s timeout for a dead leg only holds
  /// the whole aggregated search hostage.
  Future<List<Song>> searchKg(
    String q,
    int limit, {
    CancelToken? cancelToken,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final j = await _getJson(
        'https://songsearch.kugou.com/song_search_v2',
        headers: {'User-Agent': kMusicUa},
        cancelToken: cancelToken,
        query: {
          'keyword': q,
          'page': '1',
          'pagesize': '$limit',
          'format': 'json',
        },
      );
      if (j == null) return [];
      final out = _asList(j['data']?['lists'])
          .map(
            (x) => Song(
              songId: x['FileHash']?.toString() ?? '',
              title: x['SongName']?.toString() ?? '',
              artist: x['SingerName']?.toString() ?? '',
              album: x['AlbumName']?.toString() ?? '',
              platform: MusicPlatform.kg,
              dur: (x['Duration'] as num?)?.toInt() ?? 0,
            ),
          )
          .where((s) => s.songId.isNotEmpty)
          .toList();
      if (out.isNotEmpty || attempt == 1) return out;
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    return [];
  }

  /// Kuwo: single-quoted pseudo-JSON via r.s — try JSON.parse after
  /// quote-swap, then the regex fallback (load-bearing, app.js:505).
  /// Retry once after 800 ms if empty.
  Future<List<Song>> searchKw(String q, int limit) => searchKwQuery(q, limit);

  /// Kuwo search with the query string built into the URL.
  Future<List<Song>> searchKwQuery(
    String q,
    int limit, {
    CancelToken? cancelToken,
  }) async {
    final url =
        'https://search.kuwo.cn/r.s?all=${Uri.encodeComponent(q)}&ft=music&rformat=json&encoding=utf8&rn=$limit';
    for (var attempt = 0; attempt < 2; attempt++) {
      final txt = await _getText(
        url,
        headers: {'User-Agent': kMusicUa},
        cancelToken: cancelToken,
      );
      // Null = network/timeout: do not retry (see searchKg).
      if (txt == null) return [];
      final out = _parseKwSongs(txt);
      if (out.isNotEmpty || attempt == 1) return out;
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    return [];
  }

  /// Parse a Kuwo r.s response (single-quoted JSON or raw text).
  static List<Song> parseKwSongs(String txt) => _parseKwSongs(txt);

  static List<Song> _parseKwSongs(String txt) {
    List<Map<String, dynamic>> list = [];
    try {
      final decoded = jsonDecode(txt.replaceAll("'", '"'));
      if (decoded is Map<String, dynamic>) {
        list = _asList(decoded['abslist']);
      }
    } catch (_) {
      final ids = RegExp(r"'MUSICRID':'(MUSIC_\d+)'")
          .allMatches(txt)
          .map((m) => m.group(1) ?? '')
          .toList();
      final names = RegExp(r"'NAME':'((?:[^'\\]|\\.)*)'")
          .allMatches(txt)
          .map((m) => m.group(1) ?? '')
          .toList();
      final arts = RegExp(r"'ARTIST':'((?:[^'\\]|\\.)*)'")
          .allMatches(txt)
          .map((m) => m.group(1) ?? '')
          .toList();
      final pics = RegExp(r"'web_albumpic_short':'((?:[^'\\]|\\.)*)'")
          .allMatches(txt)
          .map((m) => m.group(1) ?? '')
          .toList();
      list = [
        for (var i = 0; i < ids.length; i++)
          {
            'MUSICRID': ids[i],
            'NAME': i < names.length ? names[i] : '',
            'ARTIST': i < arts.length ? arts[i] : '',
            'web_albumpic_short': i < pics.length ? pics[i] : '',
          },
      ];
    }
    return list
        .map((x) {
          final rid = x['MUSICRID']?.toString() ?? '';
          final picShort = x['web_albumpic_short']?.toString() ?? '';
          final picPath = x['PICPATH']?.toString() ?? '';
          return Song(
            songId: rid.replaceAll('MUSIC_', ''),
            // Kuwo names arrive with raw escapes (double-escaped \uXXXX
            // + HTML entities, e.g. '明天会更好-1985&nbsp;TVB...',
            // '梅艳芳\\u0026张学友...') — decode here so the row shows
            // clean text AND backfillCovers' title keys match the other
            // platforms. Both the JSON path and the regex fallback above
            // flow through this construction.
            title: decodeEntities(x['NAME']?.toString() ?? ''),
            artist: decodeEntities(x['ARTIST']?.toString() ?? ''),
            album: decodeEntities(x['ALBUM']?.toString() ?? ''),
            cover: coverHi(
              picShort.isNotEmpty
                  ? 'https://img1.kuwo.cn/star/albumcover/$picShort'
                  : picPath,
            ),
            platform: MusicPlatform.kw,
            dur: _asInt(x['DURATION']),
          );
        })
        .where((s) => s.songId.isNotEmpty && s.title.isNotEmpty)
        .toList();
  }

  /// Single-platform dispatch (directSearchOne). Aggregated search lives
  /// in SongSearchService and calls these four in parallel.
  ///
  /// [cancelToken] (P1-P5): when the caller gives up on the leg
  /// (timeout / new search), cancelling the token aborts the Dio
  /// request itself instead of letting it run in the background. A
  /// cancelled request surfaces as null here (the helpers swallow
  /// every error) — it is NOT recorded as a platform failure or
  /// cooldown, because cancellation is the caller's decision, not a
  /// platform outage.
  Future<List<Song>> searchOne(
    MusicPlatform pf,
    String q, {
    CancelToken? cancelToken,
  }) {
    switch (pf) {
      case MusicPlatform.wy:
        return searchWy(q, 20, cancelToken: cancelToken);
      case MusicPlatform.tx:
        return searchTx(q, 20, cancelToken: cancelToken);
      case MusicPlatform.kg:
        return searchKg(q, 15, cancelToken: cancelToken);
      case MusicPlatform.kw:
        return searchKwQuery(q, 15, cancelToken: cancelToken);
      case MusicPlatform.mg:
        return Future.value([]);
    }
  }

  // -- album search (stage 2, Beans `SearchView` albumResults) --------
  // Beans searches albums per provider (`NetEaseAPI.searchAlbums`,
  // `QQMusicAPI.searchAlbums`, `KugouMusicAPI.searchAlbums`); Kuwo has
  // no Beans album search, but our own `artistDetailKw` already uses
  // the Kuwo r.s ft=album endpoint, so the same endpoint serves
  // album search here. No fake data: a platform with no results
  // returns an empty list. Order follows song search (wy + tx first)
  // — with the stage-2 capsule only one platform is queried at a time,
  // so the sort is a no-op in practice; the dispatch keeps the same
  // wy/tx-first thinking for any future multi-platform caller.

  /// Album search for one platform (stage-2 capsule dispatch).
  Future<List<AlbumSummary>> searchAlbums(MusicPlatform pf, String q) {
    switch (pf) {
      case MusicPlatform.wy:
        return searchWyAlbums(q);
      case MusicPlatform.tx:
        return searchTxAlbums(q);
      case MusicPlatform.kg:
        return searchKgAlbums(q);
      case MusicPlatform.kw:
        return searchKwAlbums(q);
      case MusicPlatform.mg:
        return Future.value([]);
    }
  }

  /// NetEase album search (Beans `NetEaseAPI.searchAlbums`,
  /// NetEaseAPI.swift:365: POST /api/cloudsearch/pc, type=10,
  /// result.albums[]: id / name / artist.name / picUrl /
  /// publishTime (ms) / size).
  Future<List<AlbumSummary>> searchWyAlbums(String q) async {
    final j = await _getJson(
      'https://music.163.com/api/cloudsearch/pc',
      headers: {'User-Agent': kMusicUa},
      query: {'s': q, 'type': '10', 'limit': '30', 'offset': '0'},
    );
    return parseWyAlbums(j?['result'] as Map<String, dynamic>? ?? {});
  }

  /// NetEase album payload -> [AlbumSummary] (`result.albums`).
  /// Extracted for tests: the network half is `_getJson`, the parse
  /// half is pure and runs on canned JSON.
  static List<AlbumSummary> parseWyAlbums(Map<String, dynamic> result) {
    return _asList(result['albums'])
        .map(
          (x) => AlbumSummary(
            id: x['id']?.toString() ?? '',
            name: x['name']?.toString() ?? '',
            cover: coverHi(x['picUrl']?.toString() ?? ''),
            artist:
                (x['artist'] as Map<String, dynamic>?)?['name']
                    ?.toString() ??
                '',
            publishTime: (x['publishTime'] as num?)?.toInt() ?? 0,
            songCount: (x['size'] as num?)?.toInt() ?? 0,
            platform: MusicPlatform.wy,
          ),
        )
        .where((a) => a.id.isNotEmpty && a.name.isNotEmpty)
        .toList();
  }

  /// QQ album search (Beans `QQMusicAPI.searchAlbums`,
  /// QQMusicAPI.swift:304: client_search_cp t=8, data.album.list;
  /// musicu search_type=2 is the fallback there — we have no musicu
  /// helper in this codebase, so there is no second leg here: an
  /// empty first leg returns [] instead of a fabricated fallback).
  Future<List<AlbumSummary>> searchTxAlbums(String q) async {
    final j = await _getJson(
      'https://c.y.qq.com/soso/fcgi-bin/client_search_cp',
      headers: {'Referer': 'https://y.qq.com/', 'User-Agent': kMusicUa},
      query: {
        'g_tk': '5381',
        'uin': '0',
        'format': 'json',
        'inCharset': 'utf-8',
        'outCharset': 'utf-8',
        'notice': '0',
        'platform': 'h5',
        'needNewCode': '1',
        'w': q,
        'zhidaqu': '1',
        'catZhida': '1',
        't': '8',
        'flag': '1',
        'ie': 'utf-8',
        'sem': '1',
        'aggr': '0',
        'perpage': '30',
        'n': '30',
        'p': '1',
        'remoteplace': 'txt.mqq.all',
      },
    );
    return parseTxAlbums(j?['data'] as Map<String, dynamic>? ?? {});
  }

  /// QQ album payload -> [AlbumSummary] (`data.album.list`).
  /// Beans `parseAlbumItems` (QQMusicAPI.swift:323): name from
  /// name/albumname/albumName, mid from mid/albummid/albumMID, artist
  /// from singer[].name (fallback singerName), cover from the
  /// T002R300x300M000{mid} photo URL, trackCount from total.
  /// An item with no mid gets the opaque id `qq-album-{id}-{name}`
  /// (Beans does the same) — AlbumDetailPage treats that id as
  /// "no real id" and falls back to a name search.
  static List<AlbumSummary> parseTxAlbums(Map<String, dynamic> data) {
    final album = data['album'];
    final list = album is Map<String, dynamic>
        ? _asList(album['list'])
        : <Map<String, dynamic>>[];
    return list
        .map((x) {
          final name =
              x['name']?.toString() ??
              x['albumname']?.toString() ??
              x['albumName']?.toString() ??
              '';
          final mid =
              x['mid']?.toString() ??
              x['albummid']?.toString() ??
              x['albumMID']?.toString() ??
              '';
          final singers = _asList(x['singer']);
          var artist = singers
              .map((s) => s['name']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .join(' / ');
          if (artist.isEmpty) artist = x['singerName']?.toString() ?? '';
          final numericId = (x['id'] as num?)?.toInt() ?? 0;
          return AlbumSummary(
            id: mid.isNotEmpty ? mid : 'qq-album-$numericId-$name',
            name: name,
            cover: mid.isEmpty
                ? ''
                : coverHi(
                    'https://y.gtimg.cn/music/photo_new/T002R300x300M000$mid.jpg',
                  ),
            artist: artist,
            songCount: (x['total'] as num?)?.toInt() ?? 0,
            platform: MusicPlatform.tx,
          );
        })
        .where((a) => a.name.isNotEmpty)
        .toList();
  }

  /// Kugou album search (Beans `KugouMusicAPI.searchAlbums`,
  /// KugouMusicAPI.swift:614: NO dedicated album endpoint — it
  /// aggregates the official song-search results by album, keeping
  /// the official album name / artist / cover). The id is the opaque
  /// `album|artist` key (Beans does the same) — AlbumDetailPage
  /// treats it as "no real id" and falls back to a name search.
  /// Kugou songs carry no cover in our search, so cover is ''.
  Future<List<AlbumSummary>> searchKgAlbums(String q) async {
    final songs = await searchKg(q, 40).catchError((_) => <Song>[]);
    return parseKgAlbums(songs);
  }

  /// Kugou song results -> deduped [AlbumSummary] list.
  static List<AlbumSummary> parseKgAlbums(List<Song> songs) {
    final seen = <String>{};
    final out = <AlbumSummary>[];
    for (final s in songs) {
      if (s.album.isEmpty) continue;
      final key = '${s.album}|${s.artist}';
      if (!seen.add(key)) continue;
      out.add(
        AlbumSummary(
          id: key,
          name: s.album,
          artist: s.artist,
          platform: MusicPlatform.kg,
        ),
      );
    }
    return out;
  }

  /// Kuwo album search (r.s ft=album — the same endpoint our own
  /// `artistDetailKw` already uses for an artist's albums).
  Future<List<AlbumSummary>> searchKwAlbums(String q) async {
    final txt = await _getText(
      'https://search.kuwo.cn/r.s?all=${Uri.encodeComponent(q)}&ft=album&rformat=json&encoding=utf8&rn=30&pn=0',
      headers: {'User-Agent': kMusicUa},
    );
    if (txt == null) return [];
    return parseKwAlbums(txt);
  }

  /// Kuwo r.s ft=album payload -> [AlbumSummary]. Same field mapping
  /// as `artistDetailKw`'s album parse: id from
  /// ALBUMID/DC_TARGETID/albumid/id, name from ALBUM/name, artist
  /// from ARTIST/artist, cover from hts_PICPATH/PICPATH, track count
  /// from SONGNUM.
  static List<AlbumSummary> parseKwAlbums(String txt) {
    try {
      final decoded = jsonDecode(txt.replaceAll("'", '"'));
      if (decoded is! Map<String, dynamic>) return [];
      final raw = _asList(decoded['abslist']).isNotEmpty
          ? _asList(decoded['abslist'])
          : _asList(decoded['albumlist']);
      return raw
          .map(
            (a) => AlbumSummary(
              id:
                  (a['ALBUMID'] ??
                          a['DC_TARGETID'] ??
                          a['albumid'] ??
                          a['id'])
                      ?.toString() ??
                  '',
              name: decodeEntities(
                a['ALBUM']?.toString() ?? a['name']?.toString() ?? '',
              ),
              cover: coverHi(
                a['hts_PICPATH']?.toString() ??
                    a['PICPATH']?.toString() ??
                    '',
              ),
              songCount: (a['SONGNUM'] as num?)?.toInt() ?? 0,
              artist: decodeEntities(
                a['ARTIST']?.toString() ?? a['artist']?.toString() ?? '',
              ),
              platform: MusicPlatform.kw,
            ),
          )
          .where((a) => a.id.isNotEmpty && a.name.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // -- playlist search (app.js:539-571) ------------------------------------
  // QQ playlist search is rejected by its API — only wy + kw exist.

  Future<({List<PlaylistSummary> items, int total})> searchWyPlaylists(
    String q,
    int page,
  ) async {
    final off = (page - 1) * 30;
    final j = await _getJson(
      'https://music.163.com/api/cloudsearch/pc',
      headers: {'User-Agent': kMusicUa},
      query: {'s': q, 'type': '1000', 'limit': '30', 'offset': '$off'},
    );
    final res = j?['result'] as Map<String, dynamic>? ?? {};
    final list = _asList(res['playlists']);
    return (
      items: list
          .map(
            (x) => PlaylistSummary(
              id: x['id']?.toString() ?? '',
              name: x['name']?.toString() ?? '',
              cover: coverHi(x['coverImgUrl']?.toString() ?? ''),
              creator:
                  (x['creator'] as Map<String, dynamic>?)?['nickname']
                      ?.toString() ??
                  '',
              playCount: (x['playCount'] as num?)?.toInt() ?? 0,
              trackCount: (x['trackCount'] as num?)?.toInt() ?? 0,
              desc: x['description']?.toString() ?? '',
              platform: MusicPlatform.wy,
            ),
          )
          .where((p) => p.id.isNotEmpty && p.name.isNotEmpty)
          .toList(),
      total: (res['playlistCount'] as num?)?.toInt() ?? 0,
    );
  }

  Future<({List<PlaylistSummary> items, int total})> searchKwPlaylists(
    String q,
    int page,
  ) async {
    final url =
        'https://search.kuwo.cn/r.s?all=${Uri.encodeComponent(q)}&ft=playlist&rformat=json&encoding=utf8&rn=30&pn=${page - 1}';
    final txt = await _getText(url, headers: {'User-Agent': kMusicUa});
    var list = <Map<String, dynamic>>[];
    var total = 0;
    final text = txt ?? '';
    try {
      final decoded = jsonDecode(text.replaceAll("'", '"'));
      if (decoded is Map<String, dynamic>) {
        list = _asList(decoded['abslist']);
        total = (decoded['TOTAL'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {
      final ids = RegExp(r"'DC_TARGETID':'(\d+)'")
          .allMatches(text)
          .map((m) => m.group(1) ?? '')
          .toList();
      final names = RegExp(r"'name':'((?:[^'\\]|\\.)*)'")
          .allMatches(text)
          .map((m) => m.group(1) ?? '')
          .toList();
      final pics = RegExp(r"'hts_pic':'((?:[^'\\]|\\.)*)'")
          .allMatches(text)
          .map((m) => m.group(1) ?? '')
          .toList();
      final pcs = RegExp(r"'playcnt':'(\d+)'")
          .allMatches(text)
          .map((m) => m.group(1) ?? '')
          .toList();
      final sns = RegExp(r"'songnum':'(\d+)'")
          .allMatches(text)
          .map((m) => m.group(1) ?? '')
          .toList();
      final nicks = RegExp(r"'nickname':'((?:[^'\\]|\\.)*)'")
          .allMatches(text)
          .map((m) => m.group(1) ?? '')
          .toList();
      final intros = RegExp(r"'intro':'((?:[^'\\]|\\.)*)'")
          .allMatches(text)
          .map((m) => m.group(1) ?? '')
          .toList();
      list = [
        for (var i = 0; i < ids.length; i++)
          {
            'DC_TARGETID': ids[i],
            'name': i < names.length ? names[i] : '',
            'hts_pic': i < pics.length ? pics[i] : '',
            'playcnt': i < pcs.length ? pcs[i] : '0',
            'songnum': i < sns.length ? sns[i] : '0',
            'nickname': i < nicks.length ? nicks[i] : '',
            'intro': i < intros.length ? intros[i] : '',
          },
      ];
    }
    return (
      items: list
          .map(
            (x) => PlaylistSummary(
              id: (x['DC_TARGETID'] ?? x['playlistid'])?.toString() ?? '',
              name: decodeEntities(x['name']?.toString() ?? ''),
              cover: coverHi(
                x['hts_pic']?.toString() ?? x['pic']?.toString() ?? '',
              ),
              creator: x['nickname']?.toString() ?? '',
              playCount: int.tryParse(x['playcnt']?.toString() ?? '0') ?? 0,
              trackCount: int.tryParse(x['songnum']?.toString() ?? '0') ?? 0,
              desc: x['intro']?.toString() ?? '',
              platform: MusicPlatform.kw,
            ),
          )
          .where((p) => p.id.isNotEmpty && p.name.isNotEmpty)
          .toList(),
      total: total,
    );
  }

  // -- artist search (app.js:573+) -----------------------------------------

  Future<List<ArtistSummary>> searchWyArtists(String q) async {
    final j = await _postFormJson('https://music.163.com/api/cloudsearch/pc', {
      's': q,
      'type': '100',
      'limit': '30',
      'offset': '0',
    });
    final list = _asList(j?['result']?['artists']);
    return list.map((x) {
      final alias = _asList(x['alias']);
      return ArtistSummary(
        id: x['id']?.toString() ?? '',
        name: x['name']?.toString() ?? '',
        cover: coverHi(
          x['picUrl']?.toString() ?? x['img1v1Url']?.toString() ?? '',
        ),
        musicSize: (x['musicSize'] as num?)?.toInt() ?? 0,
        albumSize: (x['albumSize'] as num?)?.toInt() ?? 0,
        platform: MusicPlatform.wy,
        alias: alias.isNotEmpty ? alias.first.toString() : '',
      );
    }).toList();
  }

  /// QQ artists are DERIVED from search results (app.js:585): zhida when
  /// type===2, otherwise singer-occurrence ranking.
  Future<List<ArtistSummary>> searchTxArtists(String q, int page) async {
    final j = await _getJson(
      'https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp',
      headers: {'Referer': 'https://y.qq.com/', 'User-Agent': kMusicUa},
      query: {
        'g_tk': '5381',
        'uin': '0',
        'format': 'json',
        'inCharset': 'utf-8',
        'outCharset': 'utf-8',
        'notice': '0',
        'platform': 'h5',
        'needNewCode': '1',
        'w': q,
        'zhidaqu': '1',
        'catZhida': '1',
        't': '0',
        'flag': '1',
        'ie': 'utf-8',
        'sem': '1',
        'aggr': '0',
        'perpage': '30',
        'n': '30',
        'p': '$page',
        'remoteplace': 'txt.mqq.all',
      },
    );
    final data = j?['data'] as Map<String, dynamic>? ?? {};
    final out = <ArtistSummary>[];
    final zhida = data['zhida'] as Map<String, dynamic>?;
    if (zhida != null && zhida['type'] == 2) {
      final mid = zhida['singermid']?.toString() ?? '';
      out.add(
        ArtistSummary(
          id: mid,
          name: zhida['singername']?.toString() ?? '',
          cover: mid.isEmpty
              ? ''
              : coverHi(
                  'https://y.gtimg.cn/music/photo_new/T001R300x300M000$mid.jpg',
                ),
          musicSize: (zhida['songnum'] as num?)?.toInt() ?? 0,
          albumSize: (zhida['albumnum'] as num?)?.toInt() ?? 0,
          platform: MusicPlatform.tx,
        ),
      );
    }
    final counts = <String, (int count, String mid)>{};
    for (final s in _asList(data['song']?['list'])) {
      for (final singer in _asList(s['singer'])) {
        final name = singer['name']?.toString() ?? '';
        if (name.contains(';') || name.contains('、')) continue;
        final prev = counts[name];
        counts[name] = (
          (prev?.$1 ?? 0) + 1,
          singer['mid']?.toString() ?? prev?.$2 ?? '',
        );
      }
    }
    final nq = normalizeName(q);
    final ranked = counts.entries.where((e) {
      final n = normalizeName(e.key);
      return n.contains(nq) || nq.contains(n);
    }).toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    for (final e in ranked) {
      if (out.any((a) => a.id == e.value.$2 && e.value.$2.isNotEmpty)) {
        continue;
      }
      out.add(
        ArtistSummary(
          id: e.value.$2,
          name: e.key,
          cover: e.value.$2.isEmpty
              ? ''
              : coverHi(
                  'https://y.gtimg.cn/music/photo_new/T001R300x300M000${e.value.$2}.jpg',
                ),
          musicSize: e.value.$1,
          albumSize: 0,
          platform: MusicPlatform.tx,
        ),
      );
    }
    return out;
  }

  Future<List<ArtistSummary>> searchKwArtists(String q) async {
    final url =
        'https://search.kuwo.cn/r.s?all=${Uri.encodeComponent(q)}&ft=artist&rformat=json&encoding=utf8&rn=30&pn=0';
    final txt = await _getText(url, headers: {'User-Agent': kMusicUa});
    try {
      final decoded = jsonDecode((txt ?? '').replaceAll("'", '"'));
      if (decoded is Map<String, dynamic>) {
        return _asList(decoded['abslist']).map((x) {
          return ArtistSummary(
            id: x['ARTISTID']?.toString() ?? '',
            name: x['ARTIST']?.toString() ?? '',
            cover: coverHi(x['hts_PICPATH']?.toString() ?? ''),
            musicSize: (x['SONGNUM'] as num?)?.toInt() ?? 0,
            albumSize: (x['ALBUMNUM'] as num?)?.toInt() ?? 0,
            platform: MusicPlatform.kw,
          );
        }).toList();
      }
    } catch (_) {}
    return [];
  }

  // -- artist detail (app.js:624-688) ---------------------------------------

  Future<ArtistDetail> artistDetailWy(String id) async {
    const headers = {'User-Agent': kMusicUa};
    final timeout = const Duration(seconds: 15);
    final pair = await Future.wait([
      _getJson(
        'https://music.163.com/api/artist/albums/$id?limit=30&offset=0',
        headers: headers,
        timeout: timeout,
      ),
      _getJson(
        'https://music.163.com/api/v1/artist/songs?id=$id&limit=100&offset=0',
        headers: headers,
        timeout: timeout,
      ),
    ]);
    final ar = pair[0] ?? {};
    var first = pair[1] ?? {};
    var allSongs = _asList(first['songs']);
    final total = (first['total'] as num?)?.toInt() ?? 0;
    final pages = ((total / 100).ceil()).clamp(0, 10);
    if (pages > 1) {
      final rest = await Future.wait([
        for (var k = 1; k < pages; k++)
          _getJson(
            'https://music.163.com/api/v1/artist/songs?id=$id&limit=100&offset=${k * 100}',
            headers: headers,
            timeout: timeout,
          ),
      ]);
      for (final r in rest) {
        allSongs = [...allSongs, ..._asList(r?['songs'])];
      }
    }
    if (allSongs.isEmpty) {
      final sr = await _getJson(
        'https://music.163.com/api/artist/top/song?id=$id&limit=100',
        headers: headers,
        timeout: timeout,
      );
      allSongs = _asList(sr?['songs']);
    }
    Song mapSong(Map<String, dynamic> s) {
      final artists = _asList(s['artists']).isNotEmpty
          ? _asList(s['artists'])
          : _asList(s['ar']);
      final album =
          (s['album'] as Map<String, dynamic>?) ??
          (s['al'] as Map<String, dynamic>?) ??
          {};
      final durMs = (s['duration'] as num?) ?? (s['dt'] as num?) ?? 0;
      final pt = (album['publishTime'] as num?)?.toInt() ?? 0;
      return Song(
        songId: s['id']?.toString() ?? '',
        title: s['name']?.toString() ?? '',
        artist: artists.map((a) => a['name']?.toString() ?? '').join(' / '),
        album: album['name']?.toString() ?? '',
        cover: coverHi(album['picUrl']?.toString() ?? ''),
        platform: MusicPlatform.wy,
        dur: (durMs / 1000).round(),
        albumYear: pt > 0 ? DateTime.fromMillisecondsSinceEpoch(pt).year : 0,
      );
    }

    final albums = _asList(ar['hotAlbums']).map((a) {
      final artist = a['artist'] as Map<String, dynamic>?;
      return AlbumSummary(
        id: a['id']?.toString() ?? '',
        name: a['name']?.toString() ?? '',
        cover: coverHi(a['picUrl']?.toString() ?? ''),
        publishTime: (a['publishTime'] as num?)?.toInt() ?? 0,
        songCount: (a['size'] as num?)?.toInt() ?? 0,
        artist: artist?['name']?.toString() ?? '',
      );
    }).toList();
    final artist = ar['artist'] as Map<String, dynamic>? ?? {};
    return ArtistDetail(
      name: artist['name']?.toString() ?? '',
      pic: coverHi(artist['picUrl']?.toString() ?? ''),
      musicSize: (artist['musicSize'] as num?)?.toInt() ?? 0,
      albumSize: (artist['albumSize'] as num?)?.toInt() ?? 0,
      songs: allSongs.map(mapSong).toList(),
      albums: albums,
    );
  }

  Future<ArtistDetail> artistDetailTx(String mid, String name) async {
    final q = (name.isEmpty ? mid : name).trim();
    if (q.isEmpty) {
      return ArtistDetail(name: '');
    }
    const headers = {'Referer': 'https://y.qq.com/', 'User-Agent': kMusicUa};
    const timeout = Duration(seconds: 15);
    final jobs = [
      for (var p = 1; p <= 3; p++)
        _getJson(
          'https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp',
          headers: headers,
          query: {
            'g_tk': '5381',
            'uin': '0',
            'format': 'json',
            'inCharset': 'utf-8',
            'outCharset': 'utf-8',
            'notice': '0',
            'platform': 'h5',
            'needNewCode': '1',
            'w': q,
            'zhidaqu': '1',
            'catZhida': '1',
            't': '0',
            'flag': '1',
            'ie': 'utf-8',
            'sem': '1',
            'aggr': '0',
            'perpage': '30',
            'n': '30',
            'p': '$p',
            'remoteplace': 'txt.mqq.all',
          },
          timeout: timeout,
        ),
    ];
    final albP = mid.isEmpty
        ? Future<Map<String, dynamic>?>.value({})
        : _getJson(
            'https://c.y.qq.com/v8/fcg-bin/fcg_v8_singer_album.fcg',
            headers: headers,
            query: {
              'singermid': mid,
              'order': 'time',
              'begin': '0',
              'num': '30',
              'g_tk': '5381',
              'loginUin': '0',
              'hostUin': '0',
              'format': 'json',
              'inCharset': 'utf8',
              'outCharset': 'utf-8',
              'notice': '0',
              'platform': 'yqq.json',
              'needNewCode': '0',
            },
            timeout: timeout,
          );
    final results = await Future.wait(jobs);
    final albJ = await albP;
    final albums = _asList(albJ?['data']?['list'])
        .map((a) {
          final albumMid = a['albumMID']?.toString() ?? '';
          return AlbumSummary(
            id: albumMid,
            name: a['albumName']?.toString() ?? '',
            cover: albumMid.isEmpty
                ? ''
                : coverHi(
                    'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg',
                  ),
            publishTime:
                DateTime.tryParse(a['pubTime']?.toString() ?? '')
                    ?.millisecondsSinceEpoch ??
                0,
            songCount:
                ((a['latest_song'] as Map<String, dynamic>?)?['song_count']
                        as num?)
                    ?.toInt() ??
                0,
            artist: a['singerName']?.toString() ?? q,
            platform: MusicPlatform.tx,
          );
        })
        .where((a) => a.id.isNotEmpty && a.name.isNotEmpty)
        .toList();
    final seen = <String>{};
    final songs = <Song>[];
    var songnum = 0;
    var albumnum = 0;
    for (final j in results) {
      final d = j?['data'] as Map<String, dynamic>? ?? {};
      final z = d['zhida'] as Map<String, dynamic>?;
      if (z != null &&
          z['type'] == 2 &&
          (mid.isEmpty || z['singermid'] == mid)) {
        songnum = (z['songnum'] as num?)?.toInt() ?? songnum;
        albumnum = (z['albumnum'] as num?)?.toInt() ?? albumnum;
      }
      for (final s in _asList(d['song']?['list'])) {
        final songmid = s['songmid']?.toString() ?? '';
        if (songmid.isEmpty || seen.contains(songmid)) continue;
        final singers = _asList(s['singer']);
        final mine = mid.isNotEmpty
            ? singers.any((x) => x['mid'] == mid)
            : singers.any((x) => x['name'] == q);
        if (!mine) continue;
        seen.add(songmid);
        final albummid = s['albummid']?.toString() ?? '';
        songs.add(
          Song(
            songId: songmid,
            title: s['songname']?.toString() ?? '',
            artist: singers.map((a) => a['name']?.toString() ?? '').join(' / '),
            album: s['albumname']?.toString() ?? '',
            cover: albummid.isEmpty
                ? ''
                : coverHi(
                    'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albummid.jpg',
                  ),
            platform: MusicPlatform.tx,
            dur: (s['interval'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    }
    return ArtistDetail(
      name: q,
      pic: mid.isEmpty
          ? ''
          : coverHi(
              'https://y.gtimg.cn/music/photo_new/T001R300x300M000$mid.jpg',
            ),
      musicSize: songnum > 0 ? songnum : songs.length,
      albumSize: albums.isNotEmpty ? albums.length : albumnum,
      songs: songs,
      albums: albums,
    );
  }

  Future<ArtistDetail> artistDetailKw(String name) async {
    final trio = await Future.wait([
      searchKwQuery(name, 100).catchError((_) => <Song>[]),
      _getText(
        'https://search.kuwo.cn/r.s?all=${Uri.encodeComponent(name)}&ft=album&rformat=json&encoding=utf8&rn=30&pn=0',
        headers: {'User-Agent': kMusicUa},
      ),
      _getText(
        'https://search.kuwo.cn/r.s?all=${Uri.encodeComponent(name)}&ft=artist&rformat=json&encoding=utf8&rn=3&pn=0',
        headers: {'User-Agent': kMusicUa},
      ),
    ]);
    final songs = (trio[0] as List<Song>? ?? []).map((s) {
      return Song(
        songId: s.songId,
        title: s.title,
        artist: s.artist,
        platform: MusicPlatform.kw,
        dur: s.dur,
        cover: coverHi(s.cover),
      );
    }).toList();
    var albums = <AlbumSummary>[];
    try {
      final decoded = jsonDecode(
        (trio[1] as String? ?? '').replaceAll("'", '"'),
      );
      if (decoded is Map<String, dynamic>) {
        final raw = _asList(decoded['abslist']).isNotEmpty
            ? _asList(decoded['abslist'])
            : _asList(decoded['albumlist']);
        albums = raw
            .map(
              (a) => AlbumSummary(
                id:
                    (a['ALBUMID'] ??
                            a['DC_TARGETID'] ??
                            a['albumid'] ??
                            a['id'])
                        ?.toString() ??
                    '',
                name: decodeEntities(
                  a['ALBUM']?.toString() ?? a['name']?.toString() ?? '',
                ),
                cover: coverHi(
                  a['hts_PICPATH']?.toString() ??
                      a['PICPATH']?.toString() ??
                      '',
                ),
                songCount: (a['SONGNUM'] as num?)?.toInt() ?? 0,
                artist: decodeEntities(
                  a['ARTIST']?.toString() ?? a['artist']?.toString() ?? '',
                ),
                platform: MusicPlatform.kw,
              ),
            )
            .where((a) => a.id.isNotEmpty && a.name.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    var pic = '';
    try {
      final decoded = jsonDecode(
        (trio[2] as String? ?? '').replaceAll("'", '"'),
      );
      if (decoded is Map<String, dynamic>) {
        final list = _asList(decoded['abslist']);
        String norm(String s) => s.replaceAll(RegExp(r'\s+'), '');
        final hit = list.firstWhere(
          (a) => norm(a['ARTIST']?.toString() ?? '') == norm(name),
          orElse: () => list.isNotEmpty ? list.first : <String, dynamic>{},
        );
        if (hit.isNotEmpty) {
          final base = decoded['BASEPICPATH']?.toString() ?? '';
          pic = coverHi(
            hit['ARTISTPIC']?.toString() ??
                (base + (hit['PICPATH']?.toString() ?? '')),
          );
        }
      }
    } catch (_) {}
    return ArtistDetail(
      name: name,
      pic: pic,
      musicSize: songs.length,
      albumSize: albums.length,
      songs: songs,
      albums: albums,
    );
  }

  Future<ArtistDetail> artistDetail(MusicPlatform pf, String id, String name) {
    switch (pf) {
      case MusicPlatform.kw:
        return artistDetailKw(name.isEmpty ? id : name);
      case MusicPlatform.tx:
        return artistDetailTx(id, name);
      default:
        return artistDetailWy(id);
    }
  }

  // -- album songs (app.js:690-717) -----------------------------------------

  Future<AlbumDetail> albumSongsWy(String id) async {
    final j = await _getJson(
      'https://music.163.com/api/v1/album/$id',
      headers: {'User-Agent': kMusicUa},
    );
    final songs = _asList(j?['songs']);
    final al = songs.isNotEmpty
        ? (songs.first['al'] as Map<String, dynamic>? ?? {})
        : <String, dynamic>{};
    return AlbumDetail(
      name: al['name']?.toString() ?? '',
      pic: coverHi(al['picUrl']?.toString() ?? ''),
      artist:
          (al['artist'] as Map<String, dynamic>?)?['name']?.toString() ?? '',
      songs: songs.map((s) {
        final ar = _asList(s['ar']);
        final sal = s['al'] as Map<String, dynamic>?;
        final durMs = (s['duration'] as num?) ?? (s['dt'] as num?) ?? 0;
        return Song(
          songId: s['id']?.toString() ?? '',
          title: s['name']?.toString() ?? '',
          artist: ar.map((a) => a['name']?.toString() ?? '').join(' / '),
          album: sal?['name']?.toString() ?? '',
          cover: coverHi(sal?['picUrl']?.toString() ?? ''),
          platform: MusicPlatform.wy,
          dur: (durMs / 1000).round(),
        );
      }).toList(),
    );
  }

  Future<AlbumDetail> albumSongsTx(String albummid) async {
    final j = await _getJson(
      'https://c.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg',
      headers: {'Referer': 'https://y.qq.com/', 'User-Agent': kMusicUa},
      query: {
        'albummid': albummid,
        'g_tk': '5381',
        'loginUin': '0',
        'hostUin': '0',
        'format': 'json',
        'inCharset': 'utf8',
        'outCharset': 'utf-8',
        'notice': '0',
        'platform': 'yqq.json',
        'needNewCode': '0',
      },
    );
    final d = j?['data'] as Map<String, dynamic>? ?? {};
    final pic = albummid.isEmpty
        ? ''
        : coverHi(
            'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albummid.jpg',
          );
    return AlbumDetail(
      name: d['name']?.toString() ?? '',
      pic: pic,
      artist: d['singername']?.toString() ?? '',
      songs: _asList(d['list'])
          .map((s) {
            final singers = _asList(s['singer']);
            return Song(
              songId: s['songmid']?.toString() ?? '',
              title: s['songname']?.toString() ?? '',
              artist: singers
                  .map((a) => a['name']?.toString() ?? '')
                  .join(' / '),
              cover: pic,
              platform: MusicPlatform.tx,
              dur: (s['interval'] as num?)?.toInt() ?? 0,
            );
          })
          .where((s) => s.songId.isNotEmpty && s.title.isNotEmpty)
          .toList(),
    );
  }

  /// KW has no public album-track endpoint — search the album name and
  /// filter to the artist (intentional workaround, app.js:703).
  Future<AlbumDetail> albumSongsKw(
    String id,
    String name,
    String artist,
  ) async {
    final q = name.trim();
    if (q.isEmpty) {
      return AlbumDetail(name: '', artist: artist);
    }
    var list = await searchKwQuery(q, 100).catchError((_) => <Song>[]);
    final an = normalizeName(artist);
    if (an.isNotEmpty) {
      final mine = list.where((s) {
        final first = normalizeName(firstArtist(s.artist));
        return first == an || normalizeName(s.artist).contains(an);
      }).toList();
      if (mine.isNotEmpty) list = mine;
    }
    return AlbumDetail(name: q, pic: '', artist: artist, songs: list);
  }

  Future<AlbumDetail> albumSongs(
    String id,
    MusicPlatform pf,
    String name,
    String artist,
  ) {
    switch (pf) {
      case MusicPlatform.tx:
        return albumSongsTx(id);
      case MusicPlatform.kw:
        return albumSongsKw(id, name, artist);
      default:
        return albumSongsWy(id);
    }
  }

  // -- plaza (app.js:720-830) ------------------------------------------------

  Future<List<PlaylistSummary>> plazaWy() async {
    final j = await _getJson(
      'https://music.163.com/api/personalized/playlist?limit=30',
      headers: {'User-Agent': kMusicUa},
    );
    return _asList(j?['result'])
        .map((x) {
          return PlaylistSummary(
            id: x['id']?.toString() ?? '',
            name: x['name']?.toString() ?? '',
            cover: coverHi(x['picUrl']?.toString() ?? ''),
            playCount: (x['playCount'] as num?)?.toInt() ?? 0,
            trackCount: (x['trackCount'] as num?)?.toInt() ?? 0,
            desc: x['copywriter']?.toString() ?? '',
            platform: MusicPlatform.wy,
          );
        })
        .where((p) => p.id.isNotEmpty && p.name.isNotEmpty)
        .toList();
  }

  Future<List<PlaylistSummary>> plazaTx() async {
    final rnd = (DateTime.now().millisecondsSinceEpoch % 1000000000);
    final j = await _getJson(
      'https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg',
      headers: {'Referer': 'https://y.qq.com/', 'User-Agent': kMusicUa},
      query: {
        'picmid': '1',
        'rnd': '$rnd',
        'g_tk': '5381',
        'loginUin': '0',
        'hostUin': '0',
        'format': 'json',
        'inCharset': 'utf8',
        'outCharset': 'utf-8',
        'notice': '0',
        'platform': 'yqq.json',
        'needNewCode': '0',
        'categoryId': '10000000',
        'sortId': '5',
        'sin': '0',
        'ein': '29',
      },
    );
    return _asList(j?['data']?['list'])
        .map((x) {
          final creator = x['creator'] as Map<String, dynamic>?;
          return PlaylistSummary(
            id: x['dissid']?.toString() ?? '',
            name: decodeEntities(x['dissname']?.toString() ?? ''),
            cover: coverHi(x['imgurl']?.toString() ?? ''),
            creator: creator?['name']?.toString() ?? '',
            playCount: (x['listennum'] as num?)?.toInt() ?? 0,
            trackCount: 0,
            desc: x['introduction']?.toString() ?? '',
            platform: MusicPlatform.tx,
          );
        })
        .where((p) => p.id.isNotEmpty && p.name.isNotEmpty)
        .toList();
  }

  Future<List<PlaylistSummary>> plazaKw() async {
    final r = await searchKwPlaylists('热门', 1);
    return r.items;
  }

  Future<List<PlaylistSummary>> plazaKg() async {
    final j = await _getJson(
      toHttps(
        'http://mobilecdn.kugou.com/api/v3/search/special?format=json&keyword=%E7%83%AD%E9%97%A8&page=1&pagesize=30&showtype=1',
      ),
      headers: {'User-Agent': kMusicUa},
    );
    return _asList(j?['data']?['info'])
        .map((x) {
          return PlaylistSummary(
            id: x['specialid']?.toString() ?? '',
            name: x['specialname']?.toString() ?? '',
            cover: coverHi(
              (x['imgurl']?.toString() ?? '').replaceAll('{size}', '400'),
            ),
            creator: x['nickname']?.toString() ?? '',
            playCount: (x['playcount'] as num?)?.toInt() ?? 0,
            trackCount: (x['songcount'] as num?)?.toInt() ?? 0,
            desc: x['intro']?.toString() ?? '',
            time: x['publishtime']?.toString() ?? '',
            platform: MusicPlatform.kg,
          );
        })
        .where((p) => p.id.isNotEmpty && p.name.isNotEmpty)
        .toList();
  }

  /// Fetch ONLY the given platform (fix 9: never silently fall back).
  Future<List<PlaylistSummary>> plaza(MusicPlatform pf) {
    switch (pf) {
      case MusicPlatform.wy:
        return plazaWy();
      case MusicPlatform.tx:
        return plazaTx();
      case MusicPlatform.kg:
        return plazaKg();
      case MusicPlatform.kw:
        return plazaKw();
      case MusicPlatform.mg:
        return Future.value([]);
    }
  }

  // -- plaza import (app.js:762-830) -----------------------------------------

  /// NetEase playlist import. [missing] counts songs known to be
  /// missing (a chunk that failed twice, or ids the detail endpoint
  /// never returned); [note] is '' when the import is complete, else
  /// a user-facing reason. [onProgress] reports (imported, total);
  /// [cancelToken] stops between chunks (in-flight requests abort).
  Future<({String name, List<Song> tracks, int missing, String note})>
      importWyPlaylist(
    String id, {
    void Function(int done, int? total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    var name = '';
    var tids = <String>[];
    // One v6 detail fetch. Returns true when the call answered at
    // all (even with an error body); false on network/timeout/throw.
    Future<bool> fetchV6() async {
      try {
        final j = await _getJson(
          'https://music.163.com/api/v6/playlist/detail?id=$id',
          headers: {'User-Agent': kMusicUa},
          timeout: const Duration(seconds: 15),
          cancelToken: cancelToken,
        );
        if (j == null) return false;
        final pl = j['playlist'] as Map<String, dynamic>? ?? {};
        name = pl['name']?.toString() ?? '';
        tids = _asList(pl['trackIds'])
            .map((t) => t['id']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
        return true;
      } catch (_) {
        return false;
      }
    }

    // v6: retry once (800 ms) whenever the first attempt leaves us
    // with no ids — answered-but-empty AND network failure alike
    // (M-P1-3). Two silent no-answers used to fall straight through
    // to the old endpoint, whose track list truncates big playlists
    // to ~10 (measured 2026-11-17: 836-song playlist -> 10 tracks,
    // no trackIds) — and nothing said so.
    var answered = await fetchV6();
    if (tids.isEmpty && cancelToken?.isCancelled != true) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      answered = await fetchV6();
    }
    if (tids.isEmpty) {
      final j = await _getJson(
        'https://music.163.com/api/playlist/detail?id=$id',
        headers: {'User-Agent': kMusicUa},
        timeout: const Duration(seconds: 15),
        cancelToken: cancelToken,
      );
      final result = j?['result'] as Map<String, dynamic>? ?? {};
      final tr = _asList(result['tracks']);
      final tracks = tr
          .map((t) {
            final ars = _asList(t['artists']);
            final alb = t['album'] as Map<String, dynamic>?;
            final durMs = (t['duration'] as num?) ?? (t['dt'] as num?) ?? 0;
            return Song(
              songId: t['id']?.toString() ?? '',
              title: t['name']?.toString() ?? '',
              artist: ars.map((a) => a['name']?.toString() ?? '').join('/'),
              album: alb?['name']?.toString() ?? '',
              cover: coverHi(alb?['picUrl']?.toString() ?? ''),
              platform: MusicPlatform.wy,
              dur: (durMs / 1000).round(),
            );
          })
          .where((s) => s.songId.isNotEmpty && s.title.isNotEmpty)
          .toList();
      return (
        name: result['name']?.toString() ?? name,
        tracks: tracks,
        missing: 0,
        // The old endpoint may have truncated a big playlist and we
        // cannot know its true size when v6 never answered: say so
        // instead of silently importing ~10 songs.
        note: !answered
            ? '网络不稳定，歌单可能未导全（仅 ${tracks.length} 首）'
            : '',
      );
    }
    final out = <Song>[];
    var missing = 0;
    final failedChunks = <String>[];
    // Cancelled mid-import: return what we have, say so.
    ({String name, List<Song> tracks, int missing, String note})
    cancelled() => (
      name: name,
      tracks: out
          .where((s) => s.songId.isNotEmpty && s.title.isNotEmpty)
          .toList(),
      missing: tids.length - out.length,
      note: '已取消导入，已导入 ${out.length} 首',
    );
    for (var i = 0; i < tids.length; i += 100) {
      if (cancelToken?.isCancelled == true) return cancelled();
      final chunk = tids.sublist(i, math.min(i + 100, tids.length));
      Future<Map<String, dynamic>?> fetchChunk() async {
        try {
          return await _getJson(
            'https://music.163.com/api/song/detail/?ids=${Uri.encodeComponent('[${chunk.join(',')}]')}',
            headers: {'User-Agent': kMusicUa},
            timeout: const Duration(seconds: 15),
            cancelToken: cancelToken,
          );
        } catch (_) {
          return null;
        }
      }

      var j = await fetchChunk();
      if (j == null && cancelToken?.isCancelled != true) {
        // One retry after 800 ms (M-P1-3, same rule as search legs).
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (cancelToken?.isCancelled != true) j = await fetchChunk();
      }
      if (j == null) {
        if (cancelToken?.isCancelled == true) return cancelled();
        missing += chunk.length;
        failedChunks.add('第 ${i ~/ 100 + 1} 组');
        onProgress?.call(out.length, tids.length);
        continue;
      }
      final byId = <String, Map<String, dynamic>>{};
      for (final t in _asList(j['songs'])) {
        byId[t['id']?.toString() ?? ''] = t;
      }
      for (final cid in chunk) {
        final t = byId[cid];
        if (t == null) {
          // Detail endpoint never returned this id: count it
          // instead of silently dropping the song.
          missing++;
          continue;
        }
        final ars = _asList(t['artists']).isNotEmpty
            ? _asList(t['artists'])
            : _asList(t['ar']);
        final alb =
            (t['album'] as Map<String, dynamic>?) ??
            (t['al'] as Map<String, dynamic>?) ??
            {};
        final durMs = (t['duration'] as num?) ?? (t['dt'] as num?) ?? 0;
        out.add(
          Song(
            songId: t['id']?.toString() ?? '',
            title: t['name']?.toString() ?? '',
            artist: ars.map((a) => a['name']?.toString() ?? '').join('/'),
            album: alb['name']?.toString() ?? '',
            cover: coverHi(alb['picUrl']?.toString() ?? ''),
            platform: MusicPlatform.wy,
            dur: (durMs / 1000).round(),
          ),
        );
      }
      onProgress?.call(out.length, tids.length);
    }
    return (
      name: name,
      tracks: out
          .where((s) => s.songId.isNotEmpty && s.title.isNotEmpty)
          .toList(),
      missing: missing,
      note: missing > 0
          ? '其中 $missing 首因网络失败未导入'
                '${failedChunks.isNotEmpty ? '（${failedChunks.join('、')}）' : ''}'
          : '',
    );
  }

  Future<({String name, List<Song> tracks, int missing, String note})>
      importTxPlaylist(
    String id, {
    void Function(int done, int? total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final j = await _getJson(
      'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg',
      headers: {'Referer': 'https://y.qq.com/', 'User-Agent': kMusicUa},
      query: {
        'type': '1',
        'json': '1',
        'utf8': '1',
        'onlysong': '0',
        'new_format': '1',
        'disstid': id,
        'loginUin': '0',
        'hostUin': '0',
        'format': 'json',
        'inCharset': 'utf8',
        'outCharset': 'utf-8',
        'notice': '0',
        'platform': 'yqq.json',
        'needNewCode': '0',
      },
      timeout: const Duration(seconds: 15),
      cancelToken: cancelToken,
    );
    final cd = _asList(j?['cdlist']).isNotEmpty
        ? _asList(j?['cdlist']).first
        : <String, dynamic>{};
    final tracks = _asList(cd['songlist'])
          .map((x) {
            final singers = _asList(x['singer']);
            final album = x['album'] as Map<String, dynamic>?;
            final albumMid = album?['mid']?.toString() ?? '';
            return Song(
              songId: x['mid']?.toString() ?? '',
              title: x['name']?.toString() ?? '',
              artist: singers.map((a) => a['name']?.toString() ?? '').join('/'),
              cover: albumMid.isEmpty
                  ? ''
                  : coverHi(
                      'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg',
                    ),
              platform: MusicPlatform.tx,
              dur: (x['interval'] as num?)?.toInt() ?? 0,
            );
          })
          .where((s) => s.songId.isNotEmpty && s.title.isNotEmpty)
          .toList();
    onProgress?.call(tracks.length, tracks.length);
    return (
      name: decodeEntities(cd['dissname']?.toString() ?? ''),
      tracks: tracks,
      missing: 0,
      note: '',
    );
  }

  Future<({String name, List<Song> tracks, int missing, String note})>
      importKwPlaylist(
    String id, {
    void Function(int done, int? total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final out = <Song>[];
    var name = '';
    String? stoppedReason;
    for (var pn = 0; pn < 10; pn++) {
      if (cancelToken?.isCancelled == true) {
        stoppedReason = 'cancelled';
        break;
      }
      final j = await _importPageWithRetry(
        () => _getJson(
          'https://nplserver.kuwo.cn/pl.svc',
          headers: {'User-Agent': kMusicUa},
          query: {
            'op': 'getlistinfo',
            'pid': id,
            'pn': '$pn',
            'rn': '100',
            'encode': 'utf8',
            'keyset': 'pl2012',
            'vipver': '1',
          },
          timeout: const Duration(seconds: 15),
          cancelToken: cancelToken,
        ),
        cancelToken,
      );
      if (j == null) {
        stoppedReason = cancelToken?.isCancelled == true
            ? 'cancelled'
            : '第 ${pn + 1} 页获取失败';
        break;
      }
      final list = _asList(j['musiclist']);
      if (pn == 0) name = j['title']?.toString() ?? '';
      if (list.isEmpty) break;
      for (final x in list) {
        out.add(
          Song(
            songId: x['id']?.toString() ?? '',
            title: x['name']?.toString() ?? '',
            artist: x['artist']?.toString() ?? '',
            cover: coverHi(
              x['albumpic']?.toString() ?? x['musicPic']?.toString() ?? '',
            ),
            platform: MusicPlatform.kw,
            dur: (x['duration'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      onProgress?.call(out.length, null);
      if (list.length < 100) break;
    }
    final tracks = out
        .where((s) => s.songId.isNotEmpty && s.title.isNotEmpty)
        .toList();
    return (
      name: name,
      tracks: tracks,
      missing: 0,
      note: switch (stoppedReason) {
        null => '',
        'cancelled' => '已取消导入，已导入 ${tracks.length} 首',
        final r => '$r，仅导入 ${tracks.length} 首',
      },
    );
  }

  /// Kugou import page fetch with one retry (M-P1-7): [fetch]
  /// returns null on network failure (never throws — _getJson
  /// swallows). Returns null only when both attempts fail. A
  /// cancelled token is never retried.
  Future<Map<String, dynamic>?> _importPageWithRetry(
    Future<Map<String, dynamic>?> Function() fetch,
    CancelToken? cancelToken,
  ) async {
    var j = await fetch();
    if (j != null) return j;
    if (cancelToken?.isCancelled == true) return null;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (cancelToken?.isCancelled == true) return null;
    return fetch();
  }

  /// How many Kugou import pages fly at once (M-P1-7): the old
  /// serial loop took 40 pages x 15 s worst case. 3 at a time cuts a
  /// 400-song plist from ~80 s to ~30 s at 2 s/page (mock) with no
  /// extra load the API cannot take.
  static const _kgImportConcurrency = 3;

  /// Batched parallel page fetch for Kugou imports (M-P1-7).
  ///
  /// [fetchPage] fetches one page and returns its raw items plus
  /// whether it is the last page (empty, or short of the page size),
  /// or null when the page failed twice (after one retry). Pages are
  /// fetched [_kgImportConcurrency] at a time and appended in page
  /// order, so the result order matches the old serial loop. Stops at
  /// [maxPages], on cancel, on a failed page, or on [totalTimeout];
  /// [onPage] reports the cumulative imported count after each page.
  /// Returns the pages in order plus why the import stopped early
  /// ('' = complete, 'cancelled', 'timeout', or '第 X 页获取失败').
  Future<({List<List<Map<String, dynamic>>> pages, String stoppedReason})>
      _fetchKgPages({
    required int maxPages,
    required Future<({List<Map<String, dynamic>> items, bool last})?>
        Function(int page)
        fetchPage,
    CancelToken? cancelToken,
    Duration totalTimeout = const Duration(seconds: 180),
    void Function(int doneItems)? onPage,
  }) async {
    final pages = <List<Map<String, dynamic>>>[];
    final deadline = DateTime.now().add(totalTimeout);
    var stoppedReason = '';
    var doneItems = 0;
    var page = 1;
    while (page <= maxPages) {
      if (cancelToken?.isCancelled == true) {
        stoppedReason = 'cancelled';
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        stoppedReason = 'timeout';
        break;
      }
      final batch = <int>[
        for (var k = 0;
            k < _kgImportConcurrency && page + k <= maxPages;
            k++)
          page + k,
      ];
      final results = await Future.wait(batch.map(fetchPage));
      var done = false;
      for (var k = 0; k < batch.length; k++) {
        final r = results[k];
        if (r == null) {
          // A null page while the token is cancelled is the user's
          // cancel, not a page failure — report it honestly.
          stoppedReason = cancelToken?.isCancelled == true
              ? 'cancelled'
              : '第 ${batch[k]} 页获取失败';
          done = true;
          break;
        }
        pages.add(r.items);
        doneItems += r.items.length;
        onPage?.call(doneItems);
        if (r.items.isEmpty || r.last) {
          done = true;
          break;
        }
      }
      if (done) break;
      page += batch.length;
    }
    return (pages: pages, stoppedReason: stoppedReason);
  }

  /// Import-progress note for a Kugou import that stopped early.
  /// [done] is the imported count, [total] the known total (0 when
  /// unknown — then the missing count stays unknown too).
  static String _kgStoppedNote(String reason, int done, int total) {
    final missing = total > 0 ? total - done : 0;
    final missingPart = missing > 0 ? '，缺 $missing 首' : '';
    return switch (reason) {
      'cancelled' => '已取消导入，已导入 $done 首$missingPart',
      'timeout' => '导入超时，已导入 $done 首$missingPart',
      '' => '',
      final r => '$r，仅导入 $done 首$missingPart',
    };
  }

  Future<({String name, List<Song> tracks, int missing, String note})>
      importKgPlaylist(
    String id, {
    void Function(int done, int? total)? onProgress,
    CancelToken? cancelToken,
    Duration totalTimeout = const Duration(seconds: 180),
  }) async {
    Future<({List<Map<String, dynamic>> items, bool last})?> fetchPage(
      int pn,
    ) async {
      final j = await _importPageWithRetry(
        () => _getJson(
          toHttps(
            'http://mobilecdn.kugou.com/api/v3/special/song?specialid=$id&page=$pn&pagesize=100&showtype=1',
          ),
          headers: {'User-Agent': kMusicUa},
          timeout: const Duration(seconds: 15),
          cancelToken: cancelToken,
        ),
        cancelToken,
      );
      if (j == null) return null;
      final list = _asList(j['data']?['info']);
      return (
        items: [for (final x in list) Map<String, dynamic>.from(x as Map)],
        last: list.isEmpty || list.length < 100,
      );
    }

    final r = await _fetchKgPages(
      maxPages: 10,
      fetchPage: fetchPage,
      cancelToken: cancelToken,
      totalTimeout: totalTimeout,
      onPage: (done) => onProgress?.call(done, null),
    );
    final out = <Song>[];
    for (final page in r.pages) {
      for (final x in page) {
        final fn = x['filename']?.toString() ?? '';
        final sep = fn.indexOf(' - ');
        final artist = sep >= 0 ? fn.substring(0, sep) : '';
        final title = sep >= 0 ? fn.substring(sep + 3) : fn;
        final trans = x['trans_param'] as Map<String, dynamic>?;
        final uc = trans?['union_cover']?.toString() ?? '';
        out.add(
          Song(
            songId: x['hash']?.toString() ?? '',
            title: title,
            artist: artist,
            cover: uc.isEmpty ? '' : coverHi(uc.replaceAll('{size}', '400')),
            platform: MusicPlatform.kg,
            dur: (x['duration'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    }
    final name = await _kgSpecialTitle(id, cancelToken: cancelToken);
    final tracks = out
        .where((s) => s.songId.isNotEmpty && s.title.isNotEmpty)
        .toList();
    return (
      name: name.isEmpty ? '酷狗歌单 $id' : name,
      tracks: tracks,
      missing: 0,
      note: _kgStoppedNote(r.stoppedReason, tracks.length, 0),
    );
  }

  /// Kugou 用户歌单 (`m.kugou.com/plist/list/<id>?json=true`, 10/page).
  /// Public playlists need no login (dsh-kugou-music lib/kugou.js
  /// fetchPlaylist). Name comes from the special-page title when it
  /// exists, else `酷狗歌单 <id>` - the plist JSON carries no name.
  Future<({String name, List<Song> tracks, int missing, String note})>
      importKgPlist(
    String id, {
    void Function(int done, int? total)? onProgress,
    CancelToken? cancelToken,
    Duration totalTimeout = const Duration(seconds: 180),
  }) async {
    var total = 0;
    Future<({List<Map<String, dynamic>> items, bool last})?> fetchPage(
      int p,
    ) async {
      final j = await _importPageWithRetry(
        () => _getJson(
          'https://m.kugou.com/plist/list/$id',
          headers: {
            'User-Agent': kMusicUa,
            'Referer': 'https://www.kugou.com/',
          },
          query: {'json': 'true', 'page': '$p', 'pagesize': '10'},
          timeout: const Duration(seconds: 15),
          cancelToken: cancelToken,
        ),
        cancelToken,
      );
      if (j == null) return null;
      final list = j['list']?['list'] as Map<String, dynamic>?;
      final info = _asList(list?['info']);
      if (p == 1) total = (list?['total'] as num?)?.toInt() ?? info.length;
      return (
        items: [for (final x in info) Map<String, dynamic>.from(x as Map)],
        last: info.isEmpty || info.length < 10,
      );
    }

    final r = await _fetchKgPages(
      maxPages: 40,
      fetchPage: fetchPage,
      cancelToken: cancelToken,
      totalTimeout: totalTimeout,
      onPage: (done) => onProgress?.call(done, total == 0 ? null : total),
    );
    final out = <Song>[];
    for (final page in r.pages) {
      for (final x in page) {
        final fn = x['filename']?.toString() ?? '';
        final sep = fn.indexOf(' - ');
        out.add(
          Song(
            songId: (x['hash']?.toString() ?? '').toUpperCase(),
            title: sep >= 0 ? fn.substring(sep + 3) : fn,
            artist: sep >= 0 ? fn.substring(0, sep) : '',
            cover: '',
            platform: MusicPlatform.kg,
            dur: (x['duration'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    }
    final name = await _kgSpecialTitle(id, cancelToken: cancelToken);
    final tracks = out
        .where((s) => s.songId.isNotEmpty && s.title.isNotEmpty)
        .toList();
    return (
      name: name.isEmpty ? '酷狗歌单 $id' : name,
      tracks: tracks,
      // Only a stopped-early import has a known missing count; a
      // complete import drops nothing it fetched.
      missing: r.stoppedReason.isEmpty
          ? 0
          : (total > 0 ? math.max(0, total - tracks.length) : 0),
      note: _kgStoppedNote(r.stoppedReason, tracks.length, total),
    );
  }

  /// Kugou 新版分享歌单 (t1.kugou.com short link -> share/zlist.html).
  /// m3ws.kugou.com/v2/zlist/list, signed with [kugouSign]; params come
  /// from the share landing URL. No login. Up to 500 songs (100/page).
  Future<({String name, List<Song> tracks, int missing, String note})>
      importKgShared(
    KgShare share, {
    void Function(int done, int? total)? onProgress,
    CancelToken? cancelToken,
    Duration totalTimeout = const Duration(seconds: 180),
  }) async {
    var name = '';
    final now = DateTime.now().millisecondsSinceEpoch.toString();
    var fetched = 0;
    Future<({List<Map<String, dynamic>> items, bool last})?> fetchPage(
      int page,
    ) async {
      final params = <String, String>{
        'srcappid': '2919',
        'clientver': '20000',
        'clienttime': now,
        'mid': now,
        'uuid': now,
        'dfid': '-',
        'listid': share.listid,
        'type': share.type,
        'uid': share.uid,
        'sign': share.sign,
        '_t': share.t,
        'pagesize': '100',
        'page': '$page',
        'appid': '1014',
        if (share.chain.isNotEmpty) 'chain': share.chain,
        if (share.collection.isNotEmpty)
          'global_collection_id': share.collection,
      };
      final j = await _importPageWithRetry(
        () => _getJson(
          'https://m3ws.kugou.com/v2/zlist/list',
          headers: {
            'User-Agent': kMusicUa,
            'Referer': 'https://www.kugou.com/',
          },
          query: {...params, 'signature': kugouSign(params)},
          timeout: const Duration(seconds: 15),
          cancelToken: cancelToken,
        ),
        cancelToken,
      );
      if (j == null) return null;
      final info = j['list'] as Map<String, dynamic>?;
      if (name.isEmpty) name = info?['name']?.toString() ?? '';
      final arr = _asList(info?['info']);
      fetched += arr.length;
      return (
        items: [for (final s in arr) Map<String, dynamic>.from(s as Map)],
        last: arr.isEmpty || arr.length < 100 || fetched >= 500,
      );
    }

    final r = await _fetchKgPages(
      maxPages: 10,
      fetchPage: fetchPage,
      cancelToken: cancelToken,
      totalTimeout: totalTimeout,
      onPage: (done) => onProgress?.call(done, null),
    );
    final out = <Song>[];
    for (final page in r.pages) {
      for (final s in page) {
        final full = s['name']?.toString() ?? '';
        final sep = full.indexOf(' - ');
        out.add(
          Song(
            songId: (s['hash']?.toString() ?? '').toUpperCase(),
            title: sep >= 0 ? full.substring(sep + 3) : full,
            artist: sep >= 0 ? full.substring(0, sep) : '',
            cover: '',
            platform: MusicPlatform.kg,
            dur: ((s['timelen'] as num?) ?? 0) ~/ 1000,
          ),
        );
      }
    }
    final tracks = out
        .where((s) => s.songId.isNotEmpty && s.title.isNotEmpty)
        .take(500)
        .toList();
    return (
      name: name,
      tracks: tracks,
      missing: 0,
      note: _kgStoppedNote(r.stoppedReason, tracks.length, 0),
    );
  }

  /// [missing]/[note] ride along from the platform import (M-P1-3 /
  /// M-P1-7): a partial import is reported, not silently short.
  Future<({String name, List<Song> tracks, int missing, String note})>
      importPlaylist(
    MusicPlatform pf,
    String id, {
    void Function(int done, int? total)? onProgress,
    CancelToken? cancelToken,
  }) {
    switch (pf) {
      case MusicPlatform.wy:
        return importWyPlaylist(
          id,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
      case MusicPlatform.tx:
        return importTxPlaylist(
          id,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
      case MusicPlatform.kg:
        return importKgPlaylist(
          id,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
      case MusicPlatform.kw:
        return importKwPlaylist(
          id,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
      case MusicPlatform.mg:
        return Future.value((name: '', tracks: <Song>[], missing: 0, note: ''));
    }
  }

  /// NetEase charts (Beans Discover charts: 飙升/新歌/原创/热歌 + the rest).
  /// `GET https://music.163.com/api/toplist` returns 65 charts; the four
  /// canonical ones are pinned first in that order, the rest keep API
  /// order. A chart IS a playlist id — tap opens [PlazaDetailPage].
  static List<PlaylistSummary> parseNeteaseCharts(Map<String, dynamic> j) {
    const pinned = ['飙升榜', '新歌榜', '原创榜', '热歌榜'];
    final all = _asList(j['list'])
        .whereType<Map<String, dynamic>>()
        .map(
          (c) => PlaylistSummary(
            id: c['id']?.toString() ?? '',
            name: c['name']?.toString() ?? '',
            cover: c['coverImgUrl']?.toString() ?? '',
            trackCount: (c['trackCount'] as num?)?.toInt() ?? 0,
            desc: c['updateFrequency']?.toString() ?? '',
            platform: MusicPlatform.wy,
          ),
        )
        .where((p) => p.id.isNotEmpty && p.name.isNotEmpty)
        .toList();
    final head = <PlaylistSummary>[];
    for (final name in pinned) {
      final i = all.indexWhere((p) => p.name == name);
      if (i >= 0) head.add(all.removeAt(i));
    }
    return [...head, ...all];
  }

  Future<List<PlaylistSummary>> neteaseCharts() async {
    final j = await _getJson(
      'https://music.163.com/api/toplist',
      headers: {'User-Agent': kMusicUa},
      timeout: const Duration(seconds: 15),
    );
    if (j == null) return const [];
    return parseNeteaseCharts(j);
  }

  /// First http(s) URL inside pasted text (a share paste carries the
  /// link between Chinese text, e.g. "分享…歌单《…》https://163cn.tv/xxx
  /// (@网易云音乐)"). Trailing punctuation from the share text is
  /// stripped. Null when the text holds no URL at all.
  static String? extractUrlFromText(String input) {
    final m = RegExp(r'https?://[^\s]+').firstMatch(input);
    if (m == null) return null;
    return m.group(0)!.replaceAll(RegExp(r'[)）\]》。，,;!！]+$'), '');
  }

  /// NetEase playlist id from any real long-form URL:
  /// music.163.com/playlist?id=.., music.163.com/#/playlist?id=..,
  /// y.music.163.com/m/playlist?..&id=.. (id anywhere in the query).
  /// Null when it is not a NetEase playlist URL.
  static String? wyPlaylistIdFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (!uri.host.endsWith('music.163.com')) return null;
    var path = uri.path;
    var query = uri.queryParameters;
    // Desktop hash form: music.163.com/#/playlist?id=123
    if (uri.fragment.startsWith('/playlist')) {
      final frag = Uri.tryParse(uri.fragment);
      if (frag == null) return null;
      path = frag.path;
      query = frag.queryParameters;
    }
    if (!path.contains('playlist')) return null;
    final id = query['id'];
    if (id == null || int.tryParse(id) == null) return null;
    return id;
  }

  /// Follow HTTP redirects MANUALLY (up to 5 hops) and return every URL
  /// visited, start URL first. Manual because the id often sits in an
  /// INTERMEDIATE Location (163cn.tv -> y.music.163.com/m/playlist?
  /// id=..), and the landing page itself may 404 for our UA while the
  /// id is already known. Fail-soft: on any error return the hops
  /// collected so far (at least the start URL). Never throws.
  Future<List<String>> _followRedirects(String url) async {
    final hops = <String>[url];
    var current = url;
    for (var i = 0; i < 5; i++) {
      String? next;
      try {
        final res = await _dio.get<dynamic>(
          current,
          options: Options(
            headers: {'User-Agent': kMusicUa},
            followRedirects: false,
            receiveTimeout: const Duration(seconds: 8),
            responseType: ResponseType.plain,
          ),
        );
        final loc = res.headers.value('location');
        if (loc == null || loc.isEmpty) break;
        next = Uri.parse(current).resolve(loc).toString();
      } catch (_) {
        break;
      }
      if (next == current) break;
      hops.add(next);
      current = next;
    }
    return hops;
  }

  /// Kugou 精选集 id from a desktop special URL:
  /// `www.kugou.com/yy/special/single/<id>.html` (also matches a
  /// specialid/global_collection_id/collection_id query param).
  static String? kgSpecialIdFromUrl(String url) {
    final m = RegExp(
      r'kugou\.com/yy/special/single/(\d{4,})',
      caseSensitive: false,
    ).firstMatch(url);
    if (m != null) return m.group(1);
    final q = Uri.tryParse(url)?.queryParameters ?? const {};
    for (final key in ['specialid', 'global_collection_id', 'collection_id']) {
      final id = q[key];
      if (id != null && int.tryParse(id) != null) return id;
    }
    return null;
  }

  /// Kugou 用户歌单 id from the mobile playlist page URL:
  /// `m.kugou.com/plist/list/<id>` (or `plist/<id>`).
  static String? kgPlistIdFromUrl(String url) {
    final m = RegExp(
      r'kugou\.com/plist/(?:list/)?(\d{4,})',
      caseSensitive: false,
    ).firstMatch(url);
    return m?.group(1);
  }

  /// Kugou 分享歌单参数 from a share/zlist.html landing URL
  /// (t1.kugou.com short links resolve to one). Null when the URL is
  /// not a zlist share page.
  static KgShare? kgShareParamsFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (!uri.path.contains('zlist')) return null;
    final q = uri.queryParameters;
    final listid = q['listid'] ?? '';
    final uid = q['uid'] ?? '';
    if (listid.isEmpty || uid.isEmpty) return null;
    return (
      listid: listid,
      uid: uid,
      sign: q['sign'] ?? '',
      t: q['_t'] ?? '',
      type: q['type'] ?? '0',
      collection: q['global_collection_id'] ?? '',
      chain: q['chain'] ?? '',
    );
  }

  /// Kugou web-API signature (infSign rule, as documented in the public
  /// dsh-kugou-music plugin, lib/kugou.js): md5(secret + sorted k=v
  /// concat + secret). Verified live 2026-11-20: with a correct
  /// signature m3ws answers 参数错误 (bad params) instead of 签名错误.
  static String kugouSign(Map<String, String> params) {
    const secret = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
    final keys = params.keys.toList()..sort();
    final raw = keys.map((k) => '$k=${params[k]}').join();
    return md5.convert(utf8.encode(secret + raw + secret)).toString();
  }

  /// Playlist name from the Kugou special page <title> (the JSON
  /// playlist APIs do not return a name). Fail-soft: '' on any failure.
  Future<String> _kgSpecialTitle(
    String id, {
    CancelToken? cancelToken,
  }) async {
    final html = await _getText(
      'https://www.kugou.com/yy/special/single/$id.html',
      cancelToken: cancelToken,
    );
    if (html == null) return '';
    final m = RegExp(
      r'<title>([^<]*)</title>',
      caseSensitive: false,
    ).firstMatch(html);
    if (m == null) return '';
    return m
        .group(1)!
        .replaceAll(RegExp(r'_[^_]*_乐库频道_酷狗网$'), '')
        .replaceAll(RegExp(r'_酷狗网$'), '')
        .trim();
  }

  /// Import a playlist from a pasted public link (wy / kg / kw / tx).
  /// Returns null when the URL is not a recognised playlist link.
  /// [missing]/[note] ride along from the platform import (M-P1-3 /
  /// M-P1-7): a partial import is reported, not silently short.
  Future<
    ({
      String name,
      List<Song> tracks,
      MusicPlatform pf,
      int missing,
      String note,
    })?
  >
  importFromLink(
    String input, {
    void Function(int done, int? total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final url = extractUrlFromText(input);
    if (url == null) return null;
    final host = Uri.tryParse(url)?.host ?? '';

    // NetEase short link (163cn.tv/<code>): walk the redirects — the
    // playlist id sits in an intermediate hop's URL.
    if (host == '163cn.tv' || host.endsWith('.163cn.tv')) {
      for (final hop in await _followRedirects(url)) {
        final id = wyPlaylistIdFromUrl(hop);
        if (id != null) {
          final r = await importWyPlaylist(
            id,
            onProgress: onProgress,
            cancelToken: cancelToken,
          );
          return (
            name: r.name,
            tracks: r.tracks,
            pf: MusicPlatform.wy,
            missing: r.missing,
            note: r.note,
          );
        }
      }
      return null;
    }
    // Kugou short link (t1.kugou.com/<code>): walk the redirects — the
    // landing may be a zlist share page, a special page, or a plist page.
    if (host == 't1.kugou.com' || host.endsWith('.t1.kugou.com')) {
      for (final hop in await _followRedirects(url)) {
        final share = kgShareParamsFromUrl(hop);
        if (share != null) {
          final r = await importKgShared(
            share,
            onProgress: onProgress,
            cancelToken: cancelToken,
          );
          return (
            name: r.name,
            tracks: r.tracks,
            pf: MusicPlatform.kg,
            missing: r.missing,
            note: r.note,
          );
        }
        final special = kgSpecialIdFromUrl(hop);
        if (special != null) {
          final r = await importKgPlaylist(
            special,
            onProgress: onProgress,
            cancelToken: cancelToken,
          );
          return (
            name: r.name,
            tracks: r.tracks,
            pf: MusicPlatform.kg,
            missing: r.missing,
            note: r.note,
          );
        }
        final plist = kgPlistIdFromUrl(hop);
        if (plist != null) {
          final r = await importKgPlist(
            plist,
            onProgress: onProgress,
            cancelToken: cancelToken,
          );
          return (
            name: r.name,
            tracks: r.tracks,
            pf: MusicPlatform.kg,
            missing: r.missing,
            note: r.note,
          );
        }
      }
      return null;
    }

    // Direct long forms (no redirect needed).
    final wyId = wyPlaylistIdFromUrl(url);
    if (wyId != null) {
      final r = await importWyPlaylist(
        wyId,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      return (
        name: r.name,
        tracks: r.tracks,
        pf: MusicPlatform.wy,
        missing: r.missing,
        note: r.note,
      );
    }
    final kgShare = kgShareParamsFromUrl(url);
    if (kgShare != null) {
      final r = await importKgShared(
        kgShare,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      return (
        name: r.name,
        tracks: r.tracks,
        pf: MusicPlatform.kg,
        missing: r.missing,
        note: r.note,
      );
    }
    final kgSpecial = kgSpecialIdFromUrl(url);
    if (kgSpecial != null) {
      final r = await importKgPlaylist(
        kgSpecial,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      return (
        name: r.name,
        tracks: r.tracks,
        pf: MusicPlatform.kg,
        missing: r.missing,
        note: r.note,
      );
    }
    final kgPlist = kgPlistIdFromUrl(url);
    if (kgPlist != null) {
      final r = await importKgPlist(
        kgPlist,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      return (
        name: r.name,
        tracks: r.tracks,
        pf: MusicPlatform.kg,
        missing: r.missing,
        note: r.note,
      );
    }
    final kw = RegExp(r'kuwo\.cn/playlist_detail/(\d+)').firstMatch(url);
    if (kw != null) {
      final r = await importKwPlaylist(
        kw.group(1)!,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      return (
        name: r.name,
        tracks: r.tracks,
        pf: MusicPlatform.kw,
        missing: r.missing,
        note: r.note,
      );
    }
    final tx = RegExp(r'y\.qq\.com/.*playlist/(\d+)').firstMatch(url);
    if (tx != null) {
      final r = await importTxPlaylist(
        tx.group(1)!,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      return (
        name: r.name,
        tracks: r.tracks,
        pf: MusicPlatform.tx,
        missing: r.missing,
        note: r.note,
      );
    }
    return null;
  }

  // -- comments (app.js:850+) -----------------------------------------------
  // Per-platform fetchers return null on failure; the aggregator throws
  // only when every upstream failed. No comments UI exists in v1.0.4
  // (fix 15 removed the Comments button from the track sheet) — the
  // service is ported for future use.

  static const int commentsPageSize = 30;

  Future<({List<CommentItem> hot, List<CommentItem> list})?> _commentsWy(
    String id,
    int limit,
    int offset,
  ) async {
    final j = await _getJson(
      'https://music.163.com/api/v1/resource/comments/R_SO_4_$id?limit=$limit&offset=$offset',
      headers: {'User-Agent': kMusicUa},
      timeout: const Duration(seconds: 8),
    );
    if (j == null) return null;
    CommentItem map(Map<String, dynamic> c) {
      final user = c['user'] as Map<String, dynamic>? ?? {};
      return CommentItem(
        nick: user['nickname']?.toString() ?? '',
        avatar: toHttps(user['avatarUrl']?.toString() ?? ''),
        content: c['content']?.toString() ?? '',
        likes: (c['likedCount'] as num?)?.toInt() ?? 0,
        time: (c['time'] as num?)?.toInt() ?? 0,
        platform: MusicPlatform.wy,
      );
    }

    return (
      hot: _asList(j['hotComments']).map(map).toList(),
      list: _asList(j['comments']).map(map).toList(),
    );
  }

  Future<({List<CommentItem> hot, List<CommentItem> list})?> _commentsTx(
    String mid,
    int limit,
    int page,
  ) async {
    final j = await _getJson(
      'https://c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg',
      headers: {'Referer': 'https://y.qq.com/', 'User-Agent': kMusicUa},
      query: {
        'biztype': '1',
        'topid': mid,
        'cmd': '8',
        'needmusiccrit': '0',
        'pagenum': '$page',
        'pagesize': '$limit',
      },
      timeout: const Duration(seconds: 8),
    );
    if (j == null) return null;
    final comment = j['comment'] as Map<String, dynamic>? ?? {};
    return (
      hot: <CommentItem>[],
      list: _asList(comment['commentlist']).map((c) {
        return CommentItem(
          nick: c['nick']?.toString() ?? '',
          avatar: c['avatarurl']?.toString() ?? '',
          content: c['rootcommentcontent']?.toString() ?? '',
          likes: (c['praisenum'] as num?)?.toInt() ?? 0,
          time: ((c['time'] as num?)?.toInt() ?? 0) * 1000,
          platform: MusicPlatform.tx,
        );
      }).toList(),
    );
  }

  Future<({List<CommentItem> hot, List<CommentItem> list})?> _commentsKg(
    String hash,
    int limit,
    int page,
  ) async {
    final j = await _getJson(
      'https://www.kugou.com/yy/index.php?r=comment/commentData&hash=$hash&page=$page&pagesize=$limit',
      headers: {'User-Agent': kMusicUa},
      timeout: const Duration(seconds: 8),
    );
    if (j == null) return null;
    final data = j['data'] as Map<String, dynamic>? ?? {};
    final list = _asList(data['comment_list']).isNotEmpty
        ? _asList(data['comment_list'])
        : _asList(data['list']);
    return (
      hot: <CommentItem>[],
      list: list.map((c) {
        return CommentItem(
          nick: c['user_name']?.toString() ?? c['nickname']?.toString() ?? '',
          avatar: c['user_pic']?.toString() ?? c['avatar']?.toString() ?? '',
          content: c['content']?.toString() ?? '',
          likes:
              (c['like_count'] as num?)?.toInt() ??
              (c['praisenum'] as num?)?.toInt() ??
              0,
          time: ((c['addtime'] as num?)?.toInt() ?? 0) * 1000,
          platform: MusicPlatform.kg,
        );
      }).toList(),
    );
  }

  Future<({List<CommentItem> hot, List<CommentItem> list})?> _commentsKw(
    String rid,
    int limit,
    int page,
  ) async {
    final j = await _getJson(
      'https://comment.kuwo.cn/com.s?digest=0&sid=$rid&page=$page&rows=$limit',
      headers: {'User-Agent': kMusicUa},
      timeout: const Duration(seconds: 8),
    );
    if (j == null) return null;
    return (
      hot: <CommentItem>[],
      list: _asList(j['rows']).map((c) {
        return CommentItem(
          nick: c['u_name']?.toString() ?? '',
          avatar: c['u_pic']?.toString() ?? '',
          content: c['msg']?.toString() ?? '',
          likes: (c['like'] as num?)?.toInt() ?? 0,
          time: ((c['time'] as num?)?.toInt() ?? 0) * 1000,
          platform: MusicPlatform.kw,
        );
      }).toList(),
    );
  }

  Future<({List<CommentItem> hot, List<CommentItem> latest, bool hasMore})>
  comments(
    String songId,
    MusicPlatform platform,
    String title,
    String artist,
    int offset,
  ) async {
    Future<({List<CommentItem> hot, List<CommentItem> list})?> fetchFor(
      MusicPlatform p,
      String id,
    ) {
      switch (p) {
        case MusicPlatform.wy:
          return _commentsWy(id, (60 + offset).clamp(0, 100), 0);
        case MusicPlatform.tx:
          return _commentsTx(id, (40 + offset).clamp(0, 100), 0);
        case MusicPlatform.kg:
          return _commentsKg(id, (40 + offset).clamp(0, 100), 1);
        case MusicPlatform.kw:
          return _commentsKw(id, (40 + offset).clamp(0, 100), 1);
        case MusicPlatform.mg:
          return Future.value(null);
      }
    }

    final jobs = <Future<({List<CommentItem> hot, List<CommentItem> list})?>>[];
    final first = fetchFor(platform, songId);
    jobs.add(first);
    if (title.isNotEmpty) {
      try {
        final others = kSearchPlatforms.where((p) => p != platform).toList();
        final found =
            await Future.wait(
              others.map(
                (p) => searchOne(p, title).catchError((_) => <Song>[]),
              ),
            ).timeout(
              const Duration(milliseconds: 2500),
              onTimeout: () => <List<Song>>[],
            );
        final ta = normalizeName(title);
        final aa = normalizeName(firstArtist(artist));
        final alts = <({MusicPlatform pf, String id})>[];
        for (final list in found) {
          for (final x in list) {
            if (x.platform == platform) continue;
            if (normalizeName(x.title) != ta) continue;
            if (aa.isNotEmpty && normalizeName(firstArtist(x.artist)) != aa) {
              continue;
            }
            alts.add((pf: x.platform, id: x.songId));
            if (alts.length >= 3) break;
          }
          if (alts.length >= 3) break;
        }
        for (final a in alts) {
          jobs.add(fetchFor(a.pf, a.id));
        }
      } catch (_) {}
    }
    final settled = await Future.wait(
      jobs.map((j) => j.then((v) => v).catchError((_) => null)),
    );
    final seen = <String>{};
    var hot = <CommentItem>[];
    final pool = <CommentItem>[];
    var anyOk = false;
    for (final r in settled) {
      if (r == null) continue;
      anyOk = true;
      for (final c in r.hot) {
        final k =
            '${c.nick}|${c.content.substring(0, c.content.length > 60 ? 60 : c.content.length)}';
        if (c.content.isEmpty || seen.contains(k)) continue;
        seen.add(k);
        hot.add(c);
      }
      for (final c in r.list) {
        final k =
            '${c.nick}|${c.content.substring(0, c.content.length > 60 ? 60 : c.content.length)}';
        if (c.content.isEmpty || seen.contains(k)) continue;
        seen.add(k);
        pool.add(c);
      }
    }
    if (jobs.isNotEmpty && !anyOk) {
      throw Exception('comments fail');
    }
    hot.sort((a, b) => b.likes.compareTo(a.likes));
    final extra = pool.where((c) => c.likes > 0).toList()
      ..sort((a, b) => b.likes.compareTo(a.likes));
    final extraTop = extra.take(5).toList();
    final hotKeys = extraTop
        .map(
          (c) =>
              '${c.nick}|${c.content.substring(0, c.content.length > 60 ? 60 : c.content.length)}',
        )
        .toSet();
    hot = [...hot, ...extraTop]..sort((a, b) => b.likes.compareTo(a.likes));
    hot = hot.take(15).toList();
    final ordinary =
        pool
            .where(
              (c) => !hotKeys.contains(
                '${c.nick}|${c.content.substring(0, c.content.length > 60 ? 60 : c.content.length)}',
              ),
            )
            .toList()
          ..sort((a, b) => b.time.compareTo(a.time));
    final latest = ordinary.skip(offset).take(commentsPageSize).toList();
    return (
      hot: offset == 0 ? hot : <CommentItem>[],
      latest: latest,
      hasMore: ordinary.length > offset + commentsPageSize,
    );
  }

  // -- alt-platform lookup (app.js: directFindAltPlatform) -------------------
  // Preference order tx > wy > kg > kw; exact normalised title + first
  // artist (+ album) match. Used when the current platform cannot play.

  /// [timeout] (M-P1-4): whole-lookup cap. 5 s by default; the
  /// auto-advance failure path passes 2 s so a dead song fails over
  /// to the next track instead of silencing the app.
  Future<Song?> findAltPlatform(
    String title,
    String artist,
    MusicPlatform excludePf,
    String album, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final others = [
      MusicPlatform.tx,
      MusicPlatform.wy,
      MusicPlatform.kg,
      MusicPlatform.kw,
    ].where((p) => p != excludePf).toList();
    // 5 s cap (chen 2026-11-17: 播失败换源不能静默等太久): each leg
    // has a 10 s internal timeout, and Future.wait holds the whole
    // error path hostage until the slowest leg answers — up to 10 s
    // of silence while the player waits for an alt. On timeout the
    // in-flight legs are CANCELLED (P1-P5): their Dio requests abort
    // instead of running on in the background, and a cancelled leg
    // contributes nothing — it is not recorded as a failure.
    final tokens = <CancelToken>[for (var i = 0; i < others.length; i++) CancelToken()];
    final settled = await Future.wait(
      others.indexed.map(
        (e) => searchOne(
          e.$2,
          title,
          cancelToken: tokens[e.$1],
        ).catchError((_) => <Song>[]),
      ),
    ).timeout(timeout, onTimeout: () {
      for (final t in tokens) {
        t.cancel();
      }
      return <List<Song>>[];
    });
    final all = settled.expand((l) => l).toList();
    final order = {
      MusicPlatform.tx: 0,
      MusicPlatform.wy: 1,
      MusicPlatform.kg: 2,
      MusicPlatform.kw: 3,
    };
    all.sort(
      (a, b) => (order[a.platform] ?? 9).compareTo(order[b.platform] ?? 9),
    );
    final ta = normalizeName(title);
    final aa = normalizeName(firstArtist(artist));
    final al = normalizeName(album);
    for (final x in all) {
      if (x.platform == excludePf) continue;
      if (normalizeName(x.title) != ta) continue;
      if (aa.isNotEmpty && normalizeName(firstArtist(x.artist)) != aa) {
        continue;
      }
      if (al.isNotEmpty && x.album.isNotEmpty && normalizeName(x.album) != al) {
        continue;
      }
      return x;
    }
    return null;
  }

  // -- lyrics (app.js:925+) ---------------------------------------------------

  static List<LyricLine> parseLrc(String txt) {
    final out = <LyricLine>[];
    for (final line in txt.split('\n')) {
      final m = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]').firstMatch(line);
      if (m == null) continue;
      final text = line.replaceAll(RegExp(r'\[.*?\]'), '').trim();
      if (text.isEmpty) continue;
      if (RegExp(
        r'^(ti|ar|al|by|offset):',
        caseSensitive: false,
      ).hasMatch(text)) {
        continue;
      }
      if (text.startsWith('暂无歌词') || text.startsWith('纯音乐')) continue;
      out.add(
        LyricLine(
          t: (int.parse(m.group(1)!) * 60) + double.parse(m.group(2)!),
          text: text,
        ),
      );
    }
    out.sort((a, b) => a.t.compareTo(b.t));
    return out;
  }

  /// Parse LRC with an optional translation track (NetEase `tlyric`):
  /// translations are matched to main lines by timestamp (centisecond
  /// key, nearest within 0.5 s as fallback — translated lines usually
  /// share the main line's timestamp exactly). Lines without a match
  /// keep `translation == null`.
  static List<LyricLine> parseLrcWithTranslation(String txt, String? tTxt) {
    final main = parseLrc(txt);
    if (tTxt == null || tTxt.isEmpty || main.isEmpty) return main;
    final trans = parseLrc(tTxt);
    if (trans.isEmpty) return main;
    final byTime = <int, String>{};
    for (final l in trans) {
      byTime[(l.t * 100).round()] = l.text;
    }
    String? nearest(double t) {
      String? best;
      var bestDiff = 0.5;
      for (final l in trans) {
        final d = (l.t - t).abs();
        if (d < bestDiff) {
          bestDiff = d;
          best = l.text;
        }
      }
      return best;
    }

    return main.map((l) {
      final tr = byTime[(l.t * 100).round()] ?? nearest(l.t);
      if (tr == null || tr.isEmpty) return l;
      return LyricLine(t: l.t, text: l.text, translation: tr);
    }).toList();
  }

  /// Lyrics for a song, cached (P1-P7): memory + Hive, keyed by
  /// identityKey. A song played again reuses its lyrics instead of
  /// re-fetching on every load. Empty results are NOT cached.
  Future<List<LyricLine>> lyrics(Song song) async {
    final cached = MusicStore.getLyrics(song.identityKey);
    if (cached != null) return cached;
    final lines = await _fetchLyrics(song);
    if (lines.isNotEmpty) {
      unawaited(MusicStore.putLyrics(song.identityKey, lines));
    }
    return lines;
  }

  Future<List<LyricLine>> _fetchLyrics(Song song) async {
    try {
      switch (song.platform) {
        case MusicPlatform.wy:
          final j = await _getJson(
            'https://music.163.com/api/song/lyric?os=pc&id=${Uri.encodeComponent(song.songId)}&lv=-1&kv=-1&tv=-1',
            headers: {'User-Agent': kMusicUa},
          );
          final lrc = j?['lrc'] as Map<String, dynamic>?;
          final tlyric = j?['tlyric'] as Map<String, dynamic>?;
          return parseLrcWithTranslation(
            lrc?['lyric']?.toString() ?? '',
            tlyric?['lyric']?.toString(),
          );
        case MusicPlatform.tx:
          final j = await _getJson(
            'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg',
            headers: {'Referer': 'https://y.qq.com/', 'User-Agent': kMusicUa},
            query: {
              'songmid': song.songId,
              'format': 'json',
              'nobase64': '1',
              'g_tk': '5381',
            },
          );
          return parseLrc(j?['lyric']?.toString() ?? '');
        case MusicPlatform.kw:
          final j = await _getJson(
            'https://m.kuwo.cn/newh5/singles/songinfoandlrc',
            headers: {'User-Agent': kMusicUa},
            query: {'musicId': song.songId},
            timeout: const Duration(seconds: 15),
          );
          final data = j?['data'] as Map<String, dynamic>? ?? {};
          return _asList(data['lrclist'])
              .map(
                (x) => LyricLine(
                  t: (x['time'] as num?)?.toDouble() ?? 0,
                  text: (x['lineLyric']?.toString() ?? '').trim(),
                ),
              )
              .where((l) => l.text.isNotEmpty)
              .toList();
        default:
          return [];
      }
    } catch (_) {
      return [];
    }
  }
}
