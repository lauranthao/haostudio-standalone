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

import 'package:dio/dio.dart';

import '../../core/network/http_client.dart';
import 'music_models.dart';

/// UA for all music search/detail/lyrics/comments/plaza calls.
const String kMusicUa =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 '
    'Safari/604.1';

class MusicApi {
  MusicApi({Dio? dio}) : _dio = dio ?? sharedDio();

  final Dio _dio;

  // -- low-level helpers ---------------------------------------------------

  Future<Map<String, dynamic>?> _getJson(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final res = await _dio.get<dynamic>(
        url,
        queryParameters: query,
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
  }) async {
    try {
      final res = await _dio.get<String>(
        url,
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
  Future<List<Song>> searchWy(String q, int limit) async {
    final j = await _postFormJson(
      'https://music.163.com/api/cloudsearch/pc',
      {'s': q, 'type': '1', 'limit': '$limit', 'offset': '0'},
    );
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
  Future<List<Song>> searchTx(String q, int limit) async {
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
  Future<List<Song>> searchKg(String q, int limit) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final j = await _getJson(
        'https://songsearch.kugou.com/song_search_v2',
        headers: {'User-Agent': kMusicUa},
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
  Future<List<Song>> searchKwQuery(String q, int limit) async {
    final url =
        'https://search.kuwo.cn/r.s?all=${Uri.encodeComponent(q)}&ft=music&rformat=json&encoding=utf8&rn=$limit';
    for (var attempt = 0; attempt < 2; attempt++) {
      final txt = await _getText(
        url,
        headers: {'User-Agent': kMusicUa},
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
    return list.map((x) {
      final rid = x['MUSICRID']?.toString() ?? '';
      final picShort = x['web_albumpic_short']?.toString() ?? '';
      final picPath = x['PICPATH']?.toString() ?? '';
      return Song(
        songId: rid.replaceAll('MUSIC_', ''),
        title: x['NAME']?.toString() ?? '',
        artist: x['ARTIST']?.toString() ?? '',
        album: x['ALBUM']?.toString() ?? '',
        cover: coverHi(
          picShort.isNotEmpty
              ? 'https://img1.kuwo.cn/star/albumcover/$picShort'
              : picPath,
        ),
        platform: MusicPlatform.kw,
        dur: _asInt(x['DURATION']),
      );
    }).where((s) => s.songId.isNotEmpty && s.title.isNotEmpty).toList();
  }

  /// Single-platform dispatch (directSearchOne). Aggregated search lives
  /// in SongSearchService and calls these four in parallel.
  Future<List<Song>> searchOne(MusicPlatform pf, String q) {
    switch (pf) {
      case MusicPlatform.wy:
        return searchWy(q, 20);
      case MusicPlatform.tx:
        return searchTx(q, 20);
      case MusicPlatform.kg:
        return searchKg(q, 15);
      case MusicPlatform.kw:
        return searchKwQuery(q, 15);
      case MusicPlatform.mg:
        return Future.value([]);
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
      query: {
        's': q,
        'type': '1000',
        'limit': '30',
        'offset': '$off',
      },
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
              creator: (x['creator'] as Map<String, dynamic>?)?['nickname']
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
              cover: coverHi(x['hts_pic']?.toString() ?? x['pic']?.toString() ?? ''),
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
    final j = await _postFormJson(
      'https://music.163.com/api/cloudsearch/pc',
      {'s': q, 'type': '100', 'limit': '30', 'offset': '0'},
    );
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
    final ranked = counts.entries
        .where((e) {
          final n = normalizeName(e.key);
          return n.contains(nq) || nq.contains(n);
        })
        .toList()
      ..sort((a, b) => b.value.$1.compareTo(a.value.$1));
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
      final album = (s['album'] as Map<String, dynamic>?) ??
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
        albumYear: pt > 0
            ? DateTime.fromMillisecondsSinceEpoch(pt).year
            : 0,
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
    final albums = _asList(albJ?['data']?['list']).map((a) {
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
            DateTime.tryParse(a['pubTime']?.toString() ?? '')?.millisecondsSinceEpoch ?? 0,
        songCount:
            ((a['latest_song'] as Map<String, dynamic>?)?['song_count'] as num?)
                    ?.toInt() ??
                0,
        artist: a['singerName']?.toString() ?? q,
      );
    }).where((a) => a.id.isNotEmpty && a.name.isNotEmpty).toList();
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
            artist:
                singers.map((a) => a['name']?.toString() ?? '').join(' / '),
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
      final decoded = jsonDecode((trio[1] as String? ?? '').replaceAll("'", '"'));
      if (decoded is Map<String, dynamic>) {
        final raw = _asList(decoded['abslist']).isNotEmpty
            ? _asList(decoded['abslist'])
            : _asList(decoded['albumlist']);
        albums = raw
            .map(
              (a) => AlbumSummary(
                id: (a['ALBUMID'] ?? a['DC_TARGETID'] ?? a['albumid'] ?? a['id'])
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
              ),
            )
            .where((a) => a.id.isNotEmpty && a.name.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    var pic = '';
    try {
      final decoded = jsonDecode((trio[2] as String? ?? '').replaceAll("'", '"'));
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

  Future<ArtistDetail> artistDetail(
    MusicPlatform pf,
    String id,
    String name,
  ) {
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
      artist: (al['artist'] as Map<String, dynamic>?)?['name']?.toString() ?? '',
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
      songs: _asList(d['list']).map((s) {
        final singers = _asList(s['singer']);
        return Song(
          songId: s['songmid']?.toString() ?? '',
          title: s['songname']?.toString() ?? '',
          artist: singers.map((a) => a['name']?.toString() ?? '').join(' / '),
          cover: pic,
          platform: MusicPlatform.tx,
          dur: (s['interval'] as num?)?.toInt() ?? 0,
        );
      }).where((s) => s.songId.isNotEmpty && s.title.isNotEmpty).toList(),
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
    return AlbumDetail(
      name: q,
      pic: '',
      artist: artist,
      songs: list,
    );
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
    return _asList(j?['result']).map((x) {
      return PlaylistSummary(
        id: x['id']?.toString() ?? '',
        name: x['name']?.toString() ?? '',
        cover: coverHi(x['picUrl']?.toString() ?? ''),
        playCount: (x['playCount'] as num?)?.toInt() ?? 0,
        trackCount: (x['trackCount'] as num?)?.toInt() ?? 0,
        desc: x['copywriter']?.toString() ?? '',
        platform: MusicPlatform.wy,
      );
    }).where((p) => p.id.isNotEmpty && p.name.isNotEmpty).toList();
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
    return _asList(j?['data']?['list']).map((x) {
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
    }).where((p) => p.id.isNotEmpty && p.name.isNotEmpty).toList();
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
    return _asList(j?['data']?['info']).map((x) {
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
    }).where((p) => p.id.isNotEmpty && p.name.isNotEmpty).toList();
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

  Future<({String name, List<Song> tracks})> importWyPlaylist(
    String id,
  ) async {
    var name = '';
    var tids = <String>[];
    try {
      final j = await _getJson(
        'https://music.163.com/api/v6/playlist/detail?id=$id',
        headers: {'User-Agent': kMusicUa},
        timeout: const Duration(seconds: 15),
      );
      final pl = j?['playlist'] as Map<String, dynamic>? ?? {};
      name = pl['name']?.toString() ?? '';
      tids = _asList(pl['trackIds'])
          .map((t) => t['id']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (_) {}
    if (tids.isEmpty) {
      final j = await _getJson(
        'https://music.163.com/api/playlist/detail?id=$id',
        headers: {'User-Agent': kMusicUa},
        timeout: const Duration(seconds: 15),
      );
      final result = j?['result'] as Map<String, dynamic>? ?? {};
      final tr = _asList(result['tracks']);
      return (
        name: result['name']?.toString() ?? name,
        tracks: tr.map((t) {
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
        }).where((s) => s.songId.isNotEmpty && s.title.isNotEmpty).toList(),
      );
    }
    final out = <Song>[];
    for (var i = 0; i < tids.length; i += 100) {
      final chunk = tids.sublist(i, math.min(i + 100, tids.length));
      try {
        final j = await _getJson(
          'https://music.163.com/api/song/detail/?ids=${Uri.encodeComponent('[${chunk.join(',')}]')}',
          headers: {'User-Agent': kMusicUa},
          timeout: const Duration(seconds: 15),
        );
        final byId = <String, Map<String, dynamic>>{};
        for (final t in _asList(j?['songs'])) {
          byId[t['id']?.toString() ?? ''] = t;
        }
        for (final cid in chunk) {
          final t = byId[cid];
          if (t == null) continue;
          final ars = _asList(t['artists']).isNotEmpty
              ? _asList(t['artists'])
              : _asList(t['ar']);
          final alb = (t['album'] as Map<String, dynamic>?) ??
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
      } catch (_) {}
    }
    return (
      name: name,
      tracks: out.where((s) => s.songId.isNotEmpty && s.title.isNotEmpty).toList(),
    );
  }

  Future<({String name, List<Song> tracks})> importTxPlaylist(
    String id,
  ) async {
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
    );
    final cd = _asList(j?['cdlist']).isNotEmpty
        ? _asList(j?['cdlist']).first
        : <String, dynamic>{};
    return (
      name: decodeEntities(cd['dissname']?.toString() ?? ''),
      tracks: _asList(cd['songlist']).map((x) {
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
      }).where((s) => s.songId.isNotEmpty && s.title.isNotEmpty).toList(),
    );
  }

  Future<({String name, List<Song> tracks})> importKwPlaylist(
    String id,
  ) async {
    final out = <Song>[];
    var name = '';
    for (var pn = 0; pn < 10; pn++) {
      final j = await _getJson(
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
      );
      final list = _asList(j?['musiclist']);
      if (pn == 0) name = j?['title']?.toString() ?? '';
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
      if (list.length < 100) break;
    }
    return (
      name: name,
      tracks: out.where((s) => s.songId.isNotEmpty && s.title.isNotEmpty).toList(),
    );
  }

  Future<({String name, List<Song> tracks})> importKgPlaylist(
    String id,
  ) async {
    final out = <Song>[];
    for (var pn = 1; pn <= 10; pn++) {
      final j = await _getJson(
        toHttps(
          'http://mobilecdn.kugou.com/api/v3/special/song?specialid=$id&page=$pn&pagesize=100&showtype=1',
        ),
        headers: {'User-Agent': kMusicUa},
        timeout: const Duration(seconds: 15),
      );
      final list = _asList(j?['data']?['info']);
      if (list.isEmpty) break;
      for (final x in list) {
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
            cover: uc.isEmpty
                ? ''
                : coverHi(uc.replaceAll('{size}', '400')),
            platform: MusicPlatform.kg,
            dur: (x['duration'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      if (list.length < 100) break;
    }
    return (
      name: '',
      tracks: out.where((s) => s.songId.isNotEmpty && s.title.isNotEmpty).toList(),
    );
  }

  Future<({String name, List<Song> tracks})> importPlaylist(
    MusicPlatform pf,
    String id,
  ) {
    switch (pf) {
      case MusicPlatform.wy:
        return importWyPlaylist(id);
      case MusicPlatform.tx:
        return importTxPlaylist(id);
      case MusicPlatform.kg:
        return importKgPlaylist(id);
      case MusicPlatform.kw:
        return importKwPlaylist(id);
      case MusicPlatform.mg:
        return Future.value((name: '', tracks: <Song>[]));
    }
  }

  /// Import a playlist from a pasted public link (wy / kw / tx).
  /// Returns null when the URL is not a recognised playlist link.
  Future<({String name, List<Song> tracks, MusicPlatform pf})?>
      importFromLink(String url) async {
    final wy = RegExp(r'music\.163\.com/(#\/)?playlist\?id=(\d+)').firstMatch(url);
    if (wy != null) {
      final r = await importWyPlaylist(wy.group(2)!);
      return (name: r.name, tracks: r.tracks, pf: MusicPlatform.wy);
    }
    final kw = RegExp(r'kuwo\.cn/playlist_detail/(\d+)').firstMatch(url);
    if (kw != null) {
      final r = await importKwPlaylist(kw.group(1)!);
      return (name: r.name, tracks: r.tracks, pf: MusicPlatform.kw);
    }
    final tx = RegExp(r'y\.qq\.com/.*playlist/(\d+)').firstMatch(url);
    if (tx != null) {
      final r = await importTxPlaylist(tx.group(1)!);
      return (name: r.name, tracks: r.tracks, pf: MusicPlatform.tx);
    }
    return null;
  }

  // -- comments (app.js:850+) -----------------------------------------------
  // Per-platform fetchers return null on failure; the aggregator throws
  // only when every upstream failed. No comments UI exists in v1.0.4
  // (fix 15 removed the Comments button from the track sheet) — the
  // service is ported for future use.

  static const int commentsPageSize = 30;

  Future<({List<CommentItem> hot, List<CommentItem> list})?>
      _commentsWy(String id, int limit, int offset) async {
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

  Future<({List<CommentItem> hot, List<CommentItem> list})?>
      _commentsTx(String mid, int limit, int page) async {
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

  Future<({List<CommentItem> hot, List<CommentItem> list})?>
      _commentsKg(String hash, int limit, int page) async {
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
          likes: (c['like_count'] as num?)?.toInt() ??
              (c['praisenum'] as num?)?.toInt() ??
              0,
          time: ((c['addtime'] as num?)?.toInt() ?? 0) * 1000,
          platform: MusicPlatform.kg,
        );
      }).toList(),
    );
  }

  Future<({List<CommentItem> hot, List<CommentItem> list})?>
      _commentsKw(String rid, int limit, int page) async {
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
        final found = await Future.wait(
          others.map((p) => searchOne(p, title).catchError((_) => <Song>[])),
        ).timeout(const Duration(milliseconds: 2500), onTimeout: () => <List<Song>>[]);
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
        final k = '${c.nick}|${c.content.substring(0, c.content.length > 60 ? 60 : c.content.length)}';
        if (c.content.isEmpty || seen.contains(k)) continue;
        seen.add(k);
        hot.add(c);
      }
      for (final c in r.list) {
        final k = '${c.nick}|${c.content.substring(0, c.content.length > 60 ? 60 : c.content.length)}';
        if (c.content.isEmpty || seen.contains(k)) continue;
        seen.add(k);
        pool.add(c);
      }
    }
    if (jobs.isNotEmpty && !anyOk) {
      throw Exception('comments fail');
    }
    hot.sort((a, b) => b.likes.compareTo(a.likes));
    final extra = pool
        .where((c) => c.likes > 0)
        .toList()
      ..sort((a, b) => b.likes.compareTo(a.likes));
    final extraTop = extra.take(5).toList();
    final hotKeys = extraTop
        .map(
          (c) =>
              '${c.nick}|${c.content.substring(0, c.content.length > 60 ? 60 : c.content.length)}',
        )
        .toSet();
    hot = [...hot, ...extraTop]
      ..sort((a, b) => b.likes.compareTo(a.likes));
    hot = hot.take(15).toList();
    final ordinary = pool
        .where(
          (c) =>
              !hotKeys.contains(
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

  Future<Song?> findAltPlatform(
    String title,
    String artist,
    MusicPlatform excludePf,
    String album,
  ) async {
    final others = [MusicPlatform.tx, MusicPlatform.wy, MusicPlatform.kg, MusicPlatform.kw]
        .where((p) => p != excludePf)
        .toList();
    // 5 s cap (chen 2026-11-17: 播失败换源不能静默等太久): each leg
    // has a 10 s internal timeout, and Future.wait holds the whole
    // error path hostage until the slowest leg answers — up to 10 s
    // of silence while the player waits for an alt. On timeout the
    // in-flight legs keep running in the background (not cancelled)
    // but their results are discarded and the caller falls through
    // to the next song.
    final settled = await Future.wait(
      others.map(
        (pf) => searchOne(pf, title).catchError((_) => <Song>[]),
      ),
    ).timeout(
      const Duration(seconds: 5),
      onTimeout: () => <List<Song>>[],
    );
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
      if (RegExp(r'^(ti|ar|al|by|offset):', caseSensitive: false)
          .hasMatch(text)) {
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

  Future<List<LyricLine>> lyrics(Song song) async {
    try {
      switch (song.platform) {
        case MusicPlatform.wy:
          final j = await _getJson(
            'https://music.163.com/api/song/lyric?os=pc&id=${Uri.encodeComponent(song.songId)}&lv=-1&kv=-1&tv=-1',
            headers: {'User-Agent': kMusicUa},
          );
          final lrc = j?['lrc'] as Map<String, dynamic>?;
          return parseLrc(lrc?['lyric']?.toString() ?? '');
        case MusicPlatform.tx:
          final j = await _getJson(
            'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg',
            headers: {
              'Referer': 'https://y.qq.com/',
              'User-Agent': kMusicUa,
            },
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
