// Playlist import by pasted link — NetEase share links (chen 2026-11-20)
// + the other platforms (chen: "其他的也要支持").
//
// Bug: chen pasted his NetEase share
//   "分享LaurantHAo的歌单《LaurantHAo喜欢的音乐》https://163cn.tv/blpA29jW (@网易云音乐)"
// into the import box and got "导入失败：请粘贴歌单链接".
// Root cause: `importFromLink` only recognised
// `music.163.com/(#/)?playlist?id=<digits>` — the short link 163cn.tv
// matched nothing, and its resolved form (y.music.163.com/m/playlist?
// app_version=..&id=.. — id NOT the first query param) failed the regex
// too. `importWyPlaylist` itself was fine, only URL recognition broke.
//
// Fix: extract the URL from the pasted share text, walk short-link
// redirects MANUALLY (the id sits in an intermediate hop's Location —
// the landing page itself 404s for our UA while the id is already
// known), and read the id off any real playlist URL per platform:
//   wy: music.163.com/playlist?id=.., #/playlist?id=..,
//       y.music.163.com/m/playlist?..&id=.., 163cn.tv/<code>
//   kg: www.kugou.com/yy/special/single/<id>.html,
//       m.kugou.com/plist/list/<id>, t1.kugou.com/<code> (resolves to
//       a share/zlist.html?listid=&uid=&sign=.. page, fetched via the
//       signed m3ws zlist API), direct zlist URLs
//   tx: y.qq.com/n/ryqq[_v2]/playlist/<id>[.html] (desktop = mobile)
//   kw: [www.]kuwo.cn/playlist_detail/<id> (desktop = mobile)
// No short-link domain exists for QQ/Kuwo (checked 2026-11-20); no
// formats were invented. Kugou fetch paths follow the public
// dsh-kugou-music plugin (lib/kugou.js, MIT) and the app's existing
// importKgPlaylist (mobilecdn special/song).
//
// Tests: the mocked-Dio groups are OFFLINE (interceptor returns canned
// responses; short-link "redirects" are faked via 302 + Location
// headers, which is exactly what the manual walker reads). The `live`
// group hits the real network — verified live from this VM 2026-11-20:
// 163cn.tv/blpA29jW 302 -> y.music.163.com/m/playlist?
// app_version=9.6.30&id=18578359274 -> 302 -> music.163.com/playlist?
// app_version=9.6.30&id=18578359274, and the v6 detail API returns code
// 200 / "LaurantHAo喜欢的音乐" / 1467 tracks; m3ws zlist answers
// 签名错误 with a bad signature and 参数错误 with the correct one
// (signature algorithm proven live); www.kugou.com special page title
// for 546903 is "抖音最火的歌全在这里_精选集_乐库频道_酷狗网".
// NOT verifiable from this VM: mobilecdn.kugou.com (connection fails)
// and m.kugou.com/plist/list (301 -> region-lock page for non-mainland
// IPs) — those two Kugou paths are mock-verified only and need chen's
// phone (mainland) as the live check.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';

const _wyId = '18578359274';
const _wyName = 'LaurantHAo喜欢的音乐';
const _shortLink = 'https://163cn.tv/blpA29jW';
const _shareText = '分享LaurantHAo的歌单《LaurantHAo喜欢的音乐》$_shortLink (@网易云音乐)';
const _mobileLong =
    'https://y.music.163.com/m/playlist?app_version=9.6.30&id=$_wyId&userid=332927966';
const _desktopLong = 'https://music.163.com/playlist?id=$_wyId';
const _desktopHash = 'https://music.163.com/#/playlist?id=$_wyId';
const _kgSpecial = 'https://www.kugou.com/yy/special/single/546903.html';
const _kgSpecialName = '抖音最火的歌全在这里';
const _kgPlist = 'https://m.kugou.com/plist/list/1234567';
const _kgZlist =
    'https://m.kugou.com/share/zlist.html?listid=12345&uid=67890&sign=abcdef&_t=1700000000000&type=0';

/// Mocked Dio: canned responses for every URL importFromLink can hit.
/// `requests` counts how many real (mocked) HTTP calls were made.
({Dio dio, List<String> requests}) _mockDio() {
  final requests = <String>[];
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options.uri.toString());
        final uri = options.uri;
        // NetEase short link: fake the first 302 chen's link really does
        // (the walker reads the id off the Location URL, never fetches
        // the landing page — the real one 404s for our UA).
        if (uri.host == '163cn.tv' && uri.path == '/blpA29jW') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 302,
              headers: Headers.fromMap({
                'location': [_mobileLong],
              }),
              data: '',
            ),
          );
          return;
        }
        // Two-hop short link: first hop has no id, second hop does.
        if (uri.host == '163cn.tv' && uri.path == '/twostep') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 302,
              headers: Headers.fromMap({
                'location': [
                  'https://music.163.com/playlist?app_version=9.6.30',
                ],
              }),
              data: '',
            ),
          );
          return;
        }
        if (uri.toString() ==
            'https://music.163.com/playlist?app_version=9.6.30') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 302,
              headers: Headers.fromMap({
                'location': [
                  'https://music.163.com/playlist?app_version=9.6.30&id=$_wyId',
                ],
              }),
              data: '',
            ),
          );
          return;
        }
        // NetEase short link that never resolves.
        if (uri.host == '163cn.tv') {
          handler.resolve(
            Response(requestOptions: options, statusCode: 500, data: ''),
          );
          return;
        }
        // Kugou short link -> zlist share page.
        if (uri.host == 't1.kugou.com' && uri.path == '/kgshare') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 302,
              headers: Headers.fromMap({
                'location': [
                  'https://m.kugou.com/share/zlist.html?listid=12345&uid=67890&sign=abcdef&_t=1700000000000&type=0',
                ],
              }),
              data: '',
            ),
          );
          return;
        }
        // Kugou short link -> special page.
        if (uri.host == 't1.kugou.com' && uri.path == '/kgspec') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 302,
              headers: Headers.fromMap({
                'location': [
                  'https://www.kugou.com/yy/special/single/546903.html',
                ],
              }),
              data: '',
            ),
          );
          return;
        }
        // Kugou short link -> a SONG share page (not a playlist).
        if (uri.host == 't1.kugou.com' && uri.path == '/songlink') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 302,
              headers: Headers.fromMap({
                'location': [
                  'https://m.kugou.com/ssr/aik_ssr/shareSong?action=single&hash=ABC123',
                ],
              }),
              data: '',
            ),
          );
          return;
        }
        if (uri.host == 't1.kugou.com') {
          handler.resolve(
            Response(requestOptions: options, statusCode: 500, data: ''),
          );
          return;
        }
        // Kugou zlist share API.
        if (uri.host == 'm3ws.kugou.com') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'list': {
                  'name': '分享歌单',
                  'info': [
                    {
                      'name': '歌手B - 歌B',
                      'hash': 'bbb',
                      'timelen': 180000,
                      'album_id': '22',
                    },
                  ],
                },
              },
            ),
          );
          return;
        }
        // Kugou special songs API (app's existing importKgPlaylist).
        if (uri.host == 'mobilecdn.kugou.com') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'data': {
                  'info': [
                    {
                      'filename': '歌手C - 歌C',
                      'hash': 'ccc',
                      'duration': 210,
                      'trans_param': {
                        'union_cover': 'http://imge.kugou.com/x/{size}.jpg',
                      },
                    },
                    {
                      'filename': '歌手D - 歌D',
                      'hash': 'ddd',
                      'duration': 190,
                    },
                  ],
                },
              },
            ),
          );
          return;
        }
        // Kugou special page title (playlist name fetch).
        if (uri.host == 'www.kugou.com' &&
            uri.path == '/yy/special/single/546903.html') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data:
                  '<html><head><title>抖音最火的歌全在这里_精选集_乐库频道_酷狗网</title></head></html>',
            ),
          );
          return;
        }
        if (uri.host == 'www.kugou.com') {
          handler.resolve(
            Response(requestOptions: options, statusCode: 404, data: ''),
          );
          return;
        }
        // Kugou user playlist JSON API.
        if (uri.host == 'm.kugou.com' && uri.path.startsWith('/plist/list/')) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'list': {
                  'list': {
                    'total': 2,
                    'info': [
                      {
                        'filename': '歌手A - 歌A',
                        'hash': 'aaa',
                        'duration': 200,
                        'album_id': '11',
                      },
                      {
                        'filename': '歌手E - 歌E',
                        'hash': 'eee',
                        'duration': 220,
                        'album_id': '12',
                      },
                    ],
                  },
                },
              },
            ),
          );
          return;
        }
        // NetEase v6 playlist detail.
        if (uri.host == 'music.163.com' &&
            uri.path == '/api/v6/playlist/detail') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'code': 200,
                'playlist': {
                  'name': _wyName,
                  'trackIds': [
                    {'id': 1},
                    {'id': 2},
                  ],
                },
              },
            ),
          );
          return;
        }
        // NetEase song detail (chunked by importWyPlaylist).
        if (uri.host == 'music.163.com' && uri.path.contains('song/detail')) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'songs': [
                  {
                    'id': 1,
                    'name': '歌一',
                    'ar': [
                      {'name': '歌手一'},
                    ],
                    'al': {'name': '专辑一', 'picUrl': ''},
                    'dt': 200000,
                  },
                  {
                    'id': 2,
                    'name': '歌二',
                    'ar': [
                      {'name': '歌手二'},
                    ],
                    'al': {'name': '专辑二', 'picUrl': ''},
                    'dt': 180000,
                  },
                ],
              },
            ),
          );
          return;
        }
        // QQ playlist detail.
        if (uri.host == 'c.y.qq.com') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'cdlist': [
                  {
                    'dissname': 'QQ歌单',
                    'songlist': [
                      {
                        'mid': 'm1',
                        'name': 'QQ歌',
                        'singer': [
                          {'name': '歌手'},
                        ],
                        'album': {'mid': 'a1'},
                        'interval': 200,
                      },
                    ],
                  },
                ],
              },
            ),
          );
          return;
        }
        // Kuwo playlist detail (pn=0 carries one song, then it stops).
        if (uri.host == 'nplserver.kuwo.cn') {
          final pn = uri.queryParameters['pn'];
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: pn == '0'
                  ? {
                      'title': '酷我歌单',
                      'musiclist': [
                        {
                          'id': 'k1',
                          'name': '酷我歌',
                          'artist': '歌手',
                          'duration': 180,
                        },
                      ],
                    }
                  : {'title': '酷我歌单', 'musiclist': []},
            ),
          );
          return;
        }
        handler.reject(
          DioException(
            requestOptions: options,
            error: 'unexpected URL in import-link test: $uri',
          ),
        );
      },
    ),
  );
  return (dio: dio, requests: requests);
}

void main() {
  group('extractUrlFromText', () {
    test('full NetEase share text -> the bare short link', () {
      expect(MusicApi.extractUrlFromText(_shareText), _shortLink);
    });

    test('plain URL passes through unchanged', () {
      expect(
        MusicApi.extractUrlFromText(_desktopLong),
        _desktopLong,
      );
    });

    test('trailing share-text punctuation is stripped', () {
      expect(
        MusicApi.extractUrlFromText('歌单：$_desktopLong。'),
        _desktopLong,
      );
      expect(
        MusicApi.extractUrlFromText('(见 $_desktopLong)'),
        _desktopLong,
      );
    });

    test('text with no URL -> null', () {
      expect(MusicApi.extractUrlFromText('没有链接的文字'), isNull);
      expect(MusicApi.extractUrlFromText(''), isNull);
    });
  });

  group('wyPlaylistIdFromUrl', () {
    test('desktop long form', () {
      expect(MusicApi.wyPlaylistIdFromUrl(_desktopLong), _wyId);
    });

    test('desktop hash form', () {
      expect(MusicApi.wyPlaylistIdFromUrl(_desktopHash), _wyId);
    });

    test('mobile long form (id is not the first query param)', () {
      expect(MusicApi.wyPlaylistIdFromUrl(_mobileLong), _wyId);
    });

    test('resolved landing form (id after app_version)', () {
      expect(
        MusicApi.wyPlaylistIdFromUrl(
          'https://music.163.com/playlist?app_version=9.6.30&id=$_wyId',
        ),
        _wyId,
      );
    });

    test('not a playlist URL -> null', () {
      expect(
        MusicApi.wyPlaylistIdFromUrl('https://music.163.com/song?id=123'),
        isNull,
      );
      expect(
        MusicApi.wyPlaylistIdFromUrl('https://example.com/playlist?id=123'),
        isNull,
      );
      expect(MusicApi.wyPlaylistIdFromUrl('not a url'), isNull);
    });
  });

  group('kugou URL parsing', () {
    test('special desktop URL -> specialid', () {
      expect(MusicApi.kgSpecialIdFromUrl(_kgSpecial), '546903');
    });

    test('specialid query param -> id', () {
      expect(
        MusicApi.kgSpecialIdFromUrl(
          'https://www.kugou.com/yy/special/index/1.html?specialid=546903',
        ),
        '546903',
      );
    });

    test('non-Kugou URL -> null', () {
      expect(
        MusicApi.kgSpecialIdFromUrl('https://music.163.com/playlist?id=1'),
        isNull,
      );
      expect(MusicApi.kgPlistIdFromUrl(_kgSpecial), isNull);
    });

    test('plist mobile URL -> id (with and without /list/)', () {
      expect(MusicApi.kgPlistIdFromUrl(_kgPlist), '1234567');
      expect(
        MusicApi.kgPlistIdFromUrl('https://m.kugou.com/plist/1234567'),
        '1234567',
      );
    });

    test('zlist share URL -> share params', () {
      final s = MusicApi.kgShareParamsFromUrl(_kgZlist);
      expect(s, isNotNull);
      expect(s!.listid, '12345');
      expect(s.uid, '67890');
      expect(s.sign, 'abcdef');
      expect(s.t, '1700000000000');
      expect(s.type, '0');
    });

    test('zlist URL without listid/uid -> null; song share -> null', () {
      expect(
        MusicApi.kgShareParamsFromUrl(
          'https://m.kugou.com/share/zlist.html?type=0',
        ),
        isNull,
      );
      expect(
        MusicApi.kgShareParamsFromUrl(
          'https://m.kugou.com/ssr/aik_ssr/shareSong?action=single&hash=ABC',
        ),
        isNull,
      );
    });
  });

  group('kugouSign', () {
    test('fixed vector matches the live-verified value', () {
      // Same params as the 2026-11-20 live probe: m3ws answered
      // 参数错误 (signature accepted) instead of 签名错误.
      expect(
        MusicApi.kugouSign({
          'srcappid': '2919',
          'clientver': '20000',
          'clienttime': '1700000000000',
          'mid': '1700000000000',
          'uuid': '1700000000000',
          'dfid': '-',
          'listid': '1',
          'type': '0',
          'uid': '1',
          'sign': '',
          '_t': '',
          'pagesize': '100',
          'page': '1',
          'appid': '1014',
        }),
        'df8f9297ab02c3f1ecf546006507d798',
      );
    });
  });

  group('importFromLink (mocked Dio, offline)', () {
    test('chen\'s exact short link imports the playlist', () async {
      final mock = _mockDio();
      final r = await MusicApi(dio: mock.dio).importFromLink(_shortLink);
      expect(r, isNotNull);
      expect(r!.name, _wyName);
      expect(r.pf, MusicPlatform.wy);
      expect(r.tracks.length, 2);
      expect(r.tracks.map((s) => s.title), ['歌一', '歌二']);
    });

    test('the full share text paste imports the same playlist', () async {
      final mock = _mockDio();
      final r = await MusicApi(dio: mock.dio).importFromLink(_shareText);
      expect(r, isNotNull);
      expect(r!.name, _wyName);
      expect(r.pf, MusicPlatform.wy);
      expect(r.tracks.length, 2);
    });

    test('mobile long form imports', () async {
      final mock = _mockDio();
      final r = await MusicApi(dio: mock.dio).importFromLink(_mobileLong);
      expect(r, isNotNull);
      expect(r!.name, _wyName);
      expect(r.tracks.length, 2);
    });

    test('desktop long form and hash form still import', () async {
      final mock = _mockDio();
      final api = MusicApi(dio: mock.dio);
      final a = await api.importFromLink(_desktopLong);
      expect(a, isNotNull);
      expect(a!.name, _wyName);
      final b = await api.importFromLink(_desktopHash);
      expect(b, isNotNull);
      expect(b!.name, _wyName);
    });

    test('QQ long form still imports', () async {
      final mock = _mockDio();
      final r = await MusicApi(
        dio: mock.dio,
      ).importFromLink('https://y.qq.com/n/ryqq/playlist/7373560897');
      expect(r, isNotNull);
      expect(r!.name, 'QQ歌单');
      expect(r.pf, MusicPlatform.tx);
      expect(r.tracks.length, 1);
      expect(r.tracks.first.title, 'QQ歌');
    });

    test('Kuwo long form still imports', () async {
      final mock = _mockDio();
      final r = await MusicApi(
        dio: mock.dio,
      ).importFromLink('https://kuwo.cn/playlist_detail/12345');
      expect(r, isNotNull);
      expect(r!.name, '酷我歌单');
      expect(r.pf, MusicPlatform.kw);
      expect(r.tracks.length, 1);
      expect(r.tracks.first.title, '酷我歌');
    });

    test('unrecognised link -> null, zero HTTP requests', () async {
      final mock = _mockDio();
      final r = await MusicApi(
        dio: mock.dio,
      ).importFromLink('https://example.com/playlist/123');
      expect(r, isNull);
      expect(mock.requests, isEmpty);
    });

    test('short link that never resolves -> null, no crash', () async {
      final mock = _mockDio();
      final r = await MusicApi(
        dio: mock.dio,
      ).importFromLink('https://163cn.tv/deadcode');
      expect(r, isNull);
    });

    test('two-hop short link: id only in the second hop', () async {
      final mock = _mockDio();
      final r = await MusicApi(
        dio: mock.dio,
      ).importFromLink('https://163cn.tv/twostep');
      expect(r, isNotNull);
      expect(r!.name, _wyName);
      expect(r.tracks.length, 2);
    });

    test('Kugou special desktop link imports with the real name', () async {
      final mock = _mockDio();
      final r = await MusicApi(dio: mock.dio).importFromLink(_kgSpecial);
      expect(r, isNotNull);
      expect(r!.name, _kgSpecialName);
      expect(r.pf, MusicPlatform.kg);
      expect(r.tracks.length, 2);
      expect(r.tracks.map((s) => s.title), ['歌C', '歌D']);
      expect(r.tracks.first.songId, 'ccc');
    });

    test('Kugou special link inside share text imports too', () async {
      final mock = _mockDio();
      final r = await MusicApi(
        dio: mock.dio,
      ).importFromLink('分享酷狗歌单《$_kgSpecialName》$_kgSpecial （@酷狗音乐）');
      expect(r, isNotNull);
      expect(r!.name, _kgSpecialName);
      expect(r.tracks.length, 2);
    });

    test('Kugou user playlist (plist) imports with fallback name', () async {
      final mock = _mockDio();
      final r = await MusicApi(dio: mock.dio).importFromLink(_kgPlist);
      expect(r, isNotNull);
      expect(r!.name, '酷狗歌单 1234567');
      expect(r.pf, MusicPlatform.kg);
      expect(r.tracks.length, 2);
      expect(r.tracks.map((s) => s.title), ['歌A', '歌E']);
    });

    test('Kugou short link -> zlist share imports', () async {
      final mock = _mockDio();
      final r = await MusicApi(
        dio: mock.dio,
      ).importFromLink('https://t1.kugou.com/kgshare');
      expect(r, isNotNull);
      expect(r!.name, '分享歌单');
      expect(r.pf, MusicPlatform.kg);
      expect(r.tracks.length, 1);
      expect(r.tracks.first.title, '歌B');
      expect(r.tracks.first.songId, 'BBB');
    });

    test('direct zlist share URL imports', () async {
      final mock = _mockDio();
      final r = await MusicApi(dio: mock.dio).importFromLink(_kgZlist);
      expect(r, isNotNull);
      expect(r!.name, '分享歌单');
      expect(r.tracks.length, 1);
    });

    test('Kugou short link -> special page imports', () async {
      final mock = _mockDio();
      final r = await MusicApi(
        dio: mock.dio,
      ).importFromLink('https://t1.kugou.com/kgspec');
      expect(r, isNotNull);
      expect(r!.name, _kgSpecialName);
      expect(r.tracks.length, 2);
    });

    test('Kugou short link -> SONG share is not a playlist -> null', () async {
      final mock = _mockDio();
      final r = await MusicApi(
        dio: mock.dio,
      ).importFromLink('https://t1.kugou.com/songlink');
      expect(r, isNull);
    });

    test('QQ ryqq_v2 form and .html variant import', () async {
      final mock = _mockDio();
      final api = MusicApi(dio: mock.dio);
      final a = await api.importFromLink(
        'https://y.qq.com/n/ryqq_v2/playlist/7373560897',
      );
      expect(a, isNotNull);
      expect(a!.name, 'QQ歌单');
      final b = await api.importFromLink(
        'https://y.qq.com/n/ryqq/playlist/7373560897.html',
      );
      expect(b, isNotNull);
      expect(b!.name, 'QQ歌单');
    });

    test('Kuwo www variant and share-text paste import', () async {
      final mock = _mockDio();
      final api = MusicApi(dio: mock.dio);
      final a = await api.importFromLink(
        'https://www.kuwo.cn/playlist_detail/12345',
      );
      expect(a, isNotNull);
      expect(a!.name, '酷我歌单');
      final b = await api.importFromLink(
        '分享歌单 https://kuwo.cn/playlist_detail/12345 （@酷我音乐）',
      );
      expect(b, isNotNull);
      expect(b!.name, '酷我歌单');
      expect(b.tracks.length, 1);
    });
  });

  group('live (real network: 163cn.tv + music.163.com)', () {
    test(
      'chen\'s short link imports end to end',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final r = await MusicApi().importFromLink(_shortLink);
        expect(r, isNotNull);
        expect(r!.name, _wyName);
        expect(r.pf, MusicPlatform.wy);
        // Live playlist has 1467 tracks (2026-11-20); allow growth.
        expect(r.tracks.length, greaterThan(100));
        expect(r.tracks.first.title, isNotEmpty);
        // ignore: avoid_print
        print('live import: ${r.tracks.length} tracks, first: '
            '${r.tracks.first.title} - ${r.tracks.first.artist}');
      },
    );

    test(
      'kugouSign is accepted by the real m3ws server',
      timeout: const Timeout(Duration(minutes: 1)),
      () async {
        // Fixed params + Dart-computed signature. A correct signature
        // turns the answer from 签名错误 (20006) into 参数错误 (the
        // dummy listid does not exist) — the server checked the
        // signature first, so errcode 2 proves the Dart signer is right.
        final params = <String, String>{
          'srcappid': '2919',
          'clientver': '20000',
          'clienttime': '1700000000000',
          'mid': '1700000000000',
          'uuid': '1700000000000',
          'dfid': '-',
          'listid': '1',
          'type': '0',
          'uid': '1',
          'sign': '',
          '_t': '',
          'pagesize': '100',
          'page': '1',
          'appid': '1014',
        };
        final res = await Dio().get<dynamic>(
          'https://m3ws.kugou.com/v2/zlist/list',
          queryParameters: {
            ...params,
            'signature': MusicApi.kugouSign(params),
          },
          options: Options(
            headers: {'User-Agent': kMusicUa},
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
        final raw = res.data;
        final Map<String, dynamic>? data = raw is Map<String, dynamic>
            ? raw
            : raw is String
                ? jsonDecode(raw) as Map<String, dynamic>?
                : null;
        // ignore: avoid_print
        print('live zlist probe: $data');
        expect(data?['errcode'], 2);
        expect(data?['error'], '参数错误');
      },
    );

    test(
      'Kugou special title is fetched live (tracks need mainland)',
      timeout: const Timeout(Duration(minutes: 1)),
      () async {
        // mobilecdn.kugou.com does not connect from this VM, so the
        // track list stays empty here — only the name (from the
        // www.kugou.com title, reachable live) is asserted. Full
        // track import needs chen's phone in mainland China.
        final r = await MusicApi().importKgPlaylist('546903');
        expect(r.name, _kgSpecialName);
        // ignore: avoid_print
        print('live kg special: name=${r.name}, tracks=${r.tracks.length}');
      },
    );
  });
}
