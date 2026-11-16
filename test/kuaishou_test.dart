// Kuaishou adapter unit tests — pure-Dart rules that must never regress:
//
// - Quality parsing from canned `playUrls` descriptors (same-quality URLs
//   merged/deduped = one quality -> N lines; h264/hevc split; no invented
//   quality on empty input).
// - Room-page parsing from canned `window.__INITIAL_STATE__` HTML:
//   room id is author.id, NEVER liveStream.id; offline/rate-limit cards
//   parse as offline without throwing.
// - Recommend + author-search parsing from canned API payloads.
// - End-to-end room detail -> qualities -> URLs -> recovery with a
//   stubbed Dio (no real network).
//
// Live-probe notes (VM, 2026-11-16, curl):
// - GET https://live.kuaishou.com/live_api/home/list -> 200, real rooms
//   with signed .flv playUrls (txSecret/txTime). Fixture URLs below are
//   verbatim from that fetch (expired signatures — parse fixtures only).
// - GET .../live_api/search/author?keyword=... -> 200, `result: 1`;
//   "王者荣耀" returns real anchors. POST to the same endpoint -> 405
//   Method Not Allowed, so the adapter uses GET (the task text said
//   POST; the port source and the live server say GET).
// - GET https://live.kuaishou.com/u/<authorId> -> 200 but the page
//   carries the rate-limit card (`errorType.type 2`,
//   "请求过快，请稍后重试") with an empty liveStream — even with cookies
//   from a prior homepage visit. The VM's egress IP is throttled, so a
//   live room-page parse cannot be verified from here; the parser is
//   verified against canned pages in the exact shape Pure Live reads
//   (`liveroom.playList[0]`), and the rate-limit card is a fixture too.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/shared/platforms/kuaishou/kuaishou_models.dart';
import 'package:standalone/shared/platforms/kuaishou/kuaishou_room_parser.dart';
import 'package:standalone/shared/platforms/kuaishou/kuaishou_site.dart';

/// Real representation entries from the 2026-11-16 home/list fetch
/// (room IhCcVB9K7wg, author CF小蛇). Signed URLs, expired — parse
/// fixtures only, never played.
List<Map<String, dynamic>> cannedPlayUrls() => <Map<String, dynamic>>[
      <String, dynamic>{
        'hideAuto': false,
        'autoDefaultSelect': true,
        'version': '2.0',
        'type': 'dynamic',
        'adaptationSet': <String, dynamic>{
          'gopDuration': 2000,
          'representation': <Map<String, dynamic>>[
            <String, dynamic>{
              'bitrate': 1000,
              'qualityType': 'STANDARD',
              'level': 30,
              'url':
                  'https://tx-origin.pull.yximgs.com/gifshow/IhCcVB9K7wg_GameAvcSdL0.flv?txSecret=dc5b5a422f311a4a15ef6ade38cea97f&txTime=6afbef50&tsc=origin',
              'name': '高清',
              'shortName': '高清',
            },
            <String, dynamic>{
              'bitrate': 2000,
              'qualityType': 'HIGH',
              'level': 50,
              'defaultSelect': true,
              'url':
                  'https://tx-origin.pull.yximgs.com/gifshow/IhCcVB9K7wg_GameAvcHdL0.flv?txSecret=07177d93368a7d73aeab30e84ef46a60&txTime=6afbef50&tsc=origin',
              'name': '超清',
              'shortName': '超清',
            },
            <String, dynamic>{
              'bitrate': 4000,
              'qualityType': 'SUPER',
              'level': 70,
              'url':
                  'https://tx-origin.pull.yximgs.com/gifshow/IhCcVB9K7wg_GameAvcFhdL0.flv?txSecret=379e4b3a41e93bf8f520077cb0ca09cc&txTime=6afbef50&tsc=origin',
              'name': '蓝光 4M',
              'shortName': '蓝光 4M',
            },
            <String, dynamic>{
              'bitrate': 8000,
              'qualityType': 'SUPER',
              'level': 130,
              'url':
                  'https://tx-origin.pull.yximgs.com/gifshow/IhCcVB9K7wg_GameAvcFhdL3.flv?txSecret=ecfd0f44be0ff858055c0afd46817dbf&txTime=6afbef50&tsc=origin',
              'name': '蓝光 质臻',
              'shortName': '蓝光 质臻',
            },
          ],
        },
      },
    ];

/// Canned live room page: `liveroom.playList[0]` shape. The description
/// contains a `;` and a `</script>`-adjacent `;` trap — the state must
/// still parse whole (brace matching, not the naive regex).
String cannedRoomPage({bool live = true}) {
  final state = <String, dynamic>{
    'liveroom': <String, dynamic>{
      'playList': <Map<String, dynamic>>[
        <String, dynamic>{
          'author': <String, dynamic>{
            'id': 'xmjx151556',
            'name': 'CF小蛇',
            'avatar': 'https://example.com/avatar.jpg',
            'description': '小蛇竟然开播了;今晚冲分',
          },
          'gameInfo': <String, dynamic>{
            'id': 2,
            'name': '穿越火线',
            'watchingCount': '9',
          },
          'isLiving': live,
          'liveStream': live
              ? <String, dynamic>{
                  'id': 'IhCcVB9K7wg',
                  'poster':
                      'https://live1.static.yximgs.com/live/game/screenshot/IhCcVB9K7wg~1794809224670~1',
                  'playUrls': cannedPlayUrls(),
                }
              : <String, dynamic>{},
        },
      ],
    },
  };
  return '<html><head></head><body><script>'
      'window.__INITIAL_STATE__=${jsonEncode(state)};'
      '</script></body></html>';
}

/// The exact rate-limit card this VM gets from the room page today.
String cannedRateLimitPage() {
  const state =
      '{"liveroom":{"playList":[{"liveStream":{},"author":{},'
      '"gameInfo":{},"isLiving":false,"errorType":{"type":2,'
      '"title":"请求过快，请稍后重试","content":"浏览其他内容","url":"/"}}]}}';
  return '<html><body><script>window.__INITIAL_STATE__=$state;'
      '</script></body></html>';
}

void main() {
  group('parseKuaishouPlayQualities (real playUrls shape)', () {
    test('four qualities, sorted by level desc, all FLV', () {
      final qualities = parseKuaishouPlayQualities(cannedPlayUrls());
      expect(
        qualities.map((q) => q.quality),
        ['蓝光 质臻', '蓝光 4M', '超清', '高清'],
      );
      expect(qualities.map((q) => q.sort), [130, 70, 50, 30]);
      for (final quality in qualities) {
        final data = KuaishouQualityData.fromDataMap(quality.data)!;
        expect(data.urls.length, 1);
        expect(data.urls.first, contains('.flv?'));
        expect(data.facts.first.format, 'flv');
        expect(data.facts.first.codec, isNull);
      }
      // No Master quality is ever invented.
      expect(
        qualities.map((q) => q.quality),
        isNot(contains('Master')),
      );
    });

    test('same-quality URLs across descriptors merge and dedupe', () {
      final first = cannedPlayUrls();
      final second = jsonDecode(jsonEncode(first)) as List;
      final secondDescriptor = second[0] as Map<String, dynamic>;
      final secondAdaptation =
          secondDescriptor['adaptationSet'] as Map<String, dynamic>;
      // Second descriptor carries only 超清: one new line plus an exact
      // duplicate of the first descriptor's 超清 URL (must dedupe).
      final secondReps = ((secondAdaptation['representation'] as List)
              .where((r) => r['name'] == '超清'))
          .toList();
      secondReps.add(<String, dynamic>{
        'bitrate': 2000,
        'qualityType': 'HIGH',
        'level': 50,
        'url':
            'https://ks3-origin.pull.yximgs.com/gifshow/IhCcVB9K7wg_GameAvcHdL0.flv?txSecret=zzz&txTime=6afbef50',
        'name': '超清',
        'shortName': '超清',
      });
      secondReps.add(
        Map<String, dynamic>.from(
          (first[0]['adaptationSet']['representation'] as List)[1]
              as Map<String, dynamic>,
        ),
      );
      secondAdaptation['representation'] = secondReps;
      final qualities = parseKuaishouPlayQualities([first[0], second[0]]);
      expect(qualities.length, 4);
      final hd = qualities.firstWhere((q) => q.quality == '超清');
      final data = KuaishouQualityData.fromDataMap(hd.data)!;
      expect(data.urls.length, 2);
      expect(
        data.urls.where((u) => u.contains('tx-origin')).length,
        1,
      );
      expect(
        data.urls.where((u) => u.contains('ks3-origin')).length,
        1,
      );
    });

    test('h264 + hevc sets become separate qualities', () {
      final descriptor = <String, dynamic>{
        'h264': <String, dynamic>{
          'adaptationSet': <String, dynamic>{
            'representation': <Map<String, dynamic>>[
              <String, dynamic>{
                'bitrate': 2000,
                'level': 50,
                'url': 'https://example.com/a.flv',
                'name': '超清',
              },
            ],
          },
        },
        'hevc': <String, dynamic>{
          'adaptationSet': <String, dynamic>{
            'representation': <Map<String, dynamic>>[
              <String, dynamic>{
                'bitrate': 2000,
                'level': 50,
                'url': 'https://example.com/a-hevc.flv',
                'name': '超清',
              },
            ],
          },
        },
      };
      final qualities = parseKuaishouPlayQualities([descriptor]);
      expect(
        qualities.map((q) => q.quality),
        ['超清', '超清 · H.265'],
      );
      expect(
        KuaishouQualityData.fromDataMap(qualities[0].data)!
            .facts
            .first
            .codec,
        'avc',
      );
      expect(
        KuaishouQualityData.fromDataMap(qualities[1].data)!
            .facts
            .first
            .codec,
        'hevc',
      );
    });

    test('HLS URLs report hls facts', () {
      final qualities = parseKuaishouPlayQualities([
        <String, dynamic>{
          'adaptationSet': <String, dynamic>{
            'representation': <Map<String, dynamic>>[
              <String, dynamic>{
                'bitrate': 1000,
                'level': 30,
                'url': 'https://example.com/s.m3u8?token=x',
                'name': '高清',
              },
            ],
          },
        },
      ]);
      expect(qualities.length, 1);
      expect(
        KuaishouQualityData.fromDataMap(qualities.first.data)!
            .facts
            .first
            .format,
        'hls',
      );
    });

    test('empty / invalid input yields no qualities, never fake ones', () {
      expect(parseKuaishouPlayQualities(null), isEmpty);
      expect(parseKuaishouPlayQualities([]), isEmpty);
      expect(parseKuaishouPlayQualities([<String, dynamic>{}]), isEmpty);
      expect(
        parseKuaishouPlayQualities([
          <String, dynamic>{
            'adaptationSet': <String, dynamic>{
              'representation': <Map<String, dynamic>>[
                <String, dynamic>{
                  'level': 30,
                  'url': 'not-a-url',
                  'name': '高清',
                },
                <String, dynamic>{'level': 30, 'name': '高清'},
              ],
            },
          },
        ]),
        isEmpty,
      );
    });

    test('quality label normalisation', () {
      expect(normalizeKuaishouQualityLabel('蓝光 4M'), '蓝光 4M');
      expect(normalizeKuaishouQualityLabel('STANDARD'), '标清');
      expect(normalizeKuaishouQualityLabel('original'), '原画');
      expect(normalizeKuaishouQualityLabel('  超清  '), '超清');
      expect(normalizeKuaishouQualityLabel(''), '默认');
    });
  });

  group('parseKuaishouRoomPage', () {
    test('live room: roomId is author.id, not liveStream.id', () {
      final room = parseKuaishouRoomPage(cannedRoomPage(), 'xmjx151556');
      expect(room.roomId, 'xmjx151556');
      expect(room.roomId, isNot('IhCcVB9K7wg'));
      expect(room.liveStatus, isTrue);
      expect(room.nick, 'CF小蛇');
      expect(room.title, '小蛇竟然开播了;今晚冲分');
      expect(room.watching, 9);
      expect(room.cover, contains('screenshot/IhCcVB9K7wg'));
      expect(room.avatar, 'https://example.com/avatar.jpg');
      // liveStreamId is danmaku credential + link only.
      expect(room.danmakuData?['liveStreamId'], 'IhCcVB9K7wg');
      expect(room.link, 'IhCcVB9K7wg');
      final qualities =
          parseKuaishouPlayQualities(kuaishouPlayUrlsOf(room));
      expect(qualities.length, 4);
    });

    test('requested id is used when the page carries no author id', () {
      final state = jsonDecode(
        cannedRoomPage().split('window.__INITIAL_STATE__=')[1].split(
              ';</script>',
            )[0],
      ) as Map<String, dynamic>;
      ((state['liveroom'] as Map)['playList'] as List)[0]
          .remove('author');
      final html =
          '<script>window.__INITIAL_STATE__=${jsonEncode(state)};</script>';
      final room = parseKuaishouRoomPage(html, 'fallback-id');
      expect(room.roomId, 'fallback-id');
    });

    test('offline room parses without throwing', () {
      final room = parseKuaishouRoomPage(
        cannedRoomPage(live: false),
        'xmjx151556',
      );
      expect(room.liveStatus, isFalse);
      expect(room.watching, 0);
      expect(room.roomId, 'xmjx151556');
      expect(room.danmakuData, isNull);
      expect(parseKuaishouPlayQualities(kuaishouPlayUrlsOf(room)), isEmpty);
    });

    test('rate-limit card parses as offline, not an error', () {
      final room = parseKuaishouRoomPage(cannedRateLimitPage(), 'any-id');
      expect(room.liveStatus, isFalse);
      expect(room.roomId, 'any-id');
    });

    test('legacy top-level room shape still parses', () {
      final html =
          '<script>window.__INITIAL_STATE__={"room":{"author":{"id":"abc123","name":"A","avatar":"https://example.com/a.jpg","description":"hi"},"gameInfo":{"name":"Game","watchingCount":5},"isLiving":true,"liveStream":{"id":"LS1","poster":"https://example.com/p.jpg","playUrls":${jsonEncode(cannedPlayUrls())}}}};</script>';
      final room = parseKuaishouRoomPage(html, 'abc123');
      expect(room.roomId, 'abc123');
      expect(room.liveStatus, isTrue);
      expect(room.danmakuData?['liveStreamId'], 'LS1');
    });

    test('page without state throws FormatException', () {
      expect(
        () => parseKuaishouRoomPage('<html></html>', 'x'),
        throwsFormatException,
      );
    });

    test('poster without image extension gets .jpg, empty stays empty', () {
      final room = parseKuaishouRoomPage(cannedRoomPage(), 'xmjx151556');
      // Screenshot URL has no extension in the real payload.
      expect(room.cover, endsWith('.jpg'));
      final offline = parseKuaishouRoomPage(
        cannedRoomPage(live: false),
        'xmjx151556',
      );
      expect(offline.cover, isEmpty);
    });
  });

  group('parseKuaishouRecommendRooms', () {
    test('home/list maps sections to rooms with author ids', () {
      final payload = <String, dynamic>{
        'data': <String, dynamic>{
          'list': <Map<String, dynamic>>[
            <String, dynamic>{
              'labelName': '热推直播',
              'gameLiveInfo': <Map<String, dynamic>>[
                <String, dynamic>{
                  'liveInfo': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'IhCcVB9K7wg',
                      'poster':
                          'https://live1.static.yximgs.com/live/game/screenshot/IhCcVB9K7wg~1',
                      'caption': '小蛇竟然开播了......',
                      'living': true,
                      'watchingCount': 9,
                      'author': <String, dynamic>{
                        'id': 'xmjx151556',
                        'name': 'CF小蛇',
                        'avatar': 'https://example.com/a.jpg',
                        'description': 'CF主播',
                      },
                      'gameInfo': <String, dynamic>{
                        'id': 2,
                        'name': '穿越火线',
                        'poster': 'https://example.com/game.jpg',
                      },
                      'playUrls': cannedPlayUrls(),
                    },
                    // Replay card: living false, still carries URLs.
                    <String, dynamic>{
                      'id': 'Replay1',
                      'poster': '',
                      'living': false,
                      'watchingCount': 0,
                      'author': <String, dynamic>{
                        'id': 'replay-author',
                        'name': 'Replay',
                        'avatar': '',
                        'description': '',
                      },
                      'gameInfo': <String, dynamic>{
                        'name': 'Game',
                        'poster': 'https://example.com/game.jpg',
                      },
                      'playUrls': cannedPlayUrls(),
                    },
                  ],
                },
              ],
            },
          ],
        },
      };
      final rooms = parseKuaishouRecommendRooms(payload);
      expect(rooms.length, 2);
      expect(rooms[0].roomId, 'xmjx151556');
      expect(rooms[0].liveStatus, isTrue);
      expect(rooms[0].cover, contains('screenshot/IhCcVB9K7wg'));
      expect(rooms[0].watching, 9);
      expect(rooms[0].danmakuData?['liveStreamId'], 'IhCcVB9K7wg');
      expect(
        parseKuaishouPlayQualities(kuaishouPlayUrlsOf(rooms[0])).length,
        4,
      );
      expect(rooms[1].roomId, 'replay-author');
      expect(rooms[1].liveStatus, isFalse);
      expect(rooms[1].cover, 'https://example.com/game.jpg');
    });

    test('empty / malformed feed returns empty, never fake rooms', () {
      expect(parseKuaishouRecommendRooms({'data': {'list': []}}), isEmpty);
      expect(parseKuaishouRecommendRooms({'data': {}}), isEmpty);
      expect(parseKuaishouRecommendRooms(null), isEmpty);
    });
  });

  group('parseKuaishouAuthorSearch', () {
    test('real anchor shape: id, living flag, banned -> offline', () {
      final payload = <String, dynamic>{
        'data': <String, dynamic>{
          'type': 'authors',
          'result': 1,
          'list': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'Kslala666',
              'name': '王者荣耀辣辣🌸（舜家）',
              'description': '直播时间 每晚8点',
              'avatar': 'https://example.com/u.jpg',
              'sex': 'F',
              'living': false,
              'bannedStatus': <String, dynamic>{'banned': false},
              'counts': <String, dynamic>{'fan': '1941w'},
            },
            <String, dynamic>{
              'id': 'live-anchor',
              'name': 'Live One',
              'avatar': 'https://example.com/l.jpg',
              'living': true,
              'bannedStatus': <String, dynamic>{'banned': false},
            },
            <String, dynamic>{
              'id': 'banned-anchor',
              'name': 'Banned One',
              'avatar': '',
              'living': true,
              'bannedStatus': <String, dynamic>{'banned': true},
            },
            <String, dynamic>{'name': 'No Id Anchor'},
          ],
        },
      };
      final rooms = parseKuaishouAuthorSearch(payload);
      expect(rooms.length, 3);
      expect(rooms[0].roomId, 'Kslala666');
      expect(rooms[0].nick, '王者荣耀辣辣🌸（舜家）');
      expect(rooms[0].liveStatus, isFalse);
      expect(rooms[0].watching, 0);
      expect(rooms[0].link, 'https://live.kuaishou.com/u/Kslala666');
      expect(rooms[1].liveStatus, isTrue);
      // A banned anchor reports offline even with living: true.
      expect(rooms[2].liveStatus, isFalse);
    });

    test('empty / malformed search returns empty', () {
      expect(
        parseKuaishouAuthorSearch({
          'data': {'type': 'authors', 'list': [], 'result': 1},
        }),
        isEmpty,
      );
      expect(parseKuaishouAuthorSearch({'data': {}}), isEmpty);
      expect(parseKuaishouAuthorSearch(null), isEmpty);
    });
  });

  group('KuaishouSite end-to-end with stubbed Dio', () {
    late Dio stubDio;
    var roomPageFetches = 0;

    setUp(() {
      roomPageFetches = 0;
      stubDio = Dio();
      stubDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.contains('/u/xmjx151556')) {
              roomPageFetches++;
              return handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: cannedRoomPage(),
                ),
              );
            }
            if (options.path.contains('live_api/home/list')) {
              return handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'data': <String, dynamic>{
                      'list': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'gameLiveInfo': <Map<String, dynamic>>[
                            <String, dynamic>{
                              'liveInfo': <Map<String, dynamic>>[
                                <String, dynamic>{
                                  'id': 'IhCcVB9K7wg',
                                  'poster': 'https://example.com/shot',
                                  'living': true,
                                  'watchingCount': 9,
                                  'author': <String, dynamic>{
                                    'id': 'xmjx151556',
                                    'name': 'CF小蛇',
                                    'avatar': 'https://example.com/a.jpg',
                                    'description': '',
                                  },
                                  'gameInfo': <String, dynamic>{
                                    'name': '穿越火线',
                                  },
                                  'playUrls': cannedPlayUrls(),
                                },
                              ],
                            },
                          ],
                        },
                      ],
                    },
                  },
                ),
              );
            }
            if (options.path.contains('live_api/search/author')) {
              return handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'data': <String, dynamic>{
                      'type': 'authors',
                      'result': 1,
                      'list': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'id': 'Kslala666',
                          'name': '王者荣耀辣辣🌸（舜家）',
                          'avatar': 'https://example.com/u.jpg',
                          'living': false,
                          'bannedStatus': <String, dynamic>{
                            'banned': false,
                          },
                        },
                      ],
                    },
                  },
                ),
              );
            }
            return handler.next(options);
          },
        ),
      );
    });

    test('room detail -> qualities -> URLs -> facts -> recovery', () async {
      final site = KuaishouSite(dio: stubDio);
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: 'xmjx151556', platform: 'kuaishou'),
      );
      expect(room.liveStatus, isTrue);
      expect(room.roomId, 'xmjx151556');

      final qualities = await site.getPlayQualities(liveRoom: room);
      expect(
        qualities.map((q) => q.quality),
        ['蓝光 质臻', '蓝光 4M', '超清', '高清'],
      );

      final top = qualities.first;
      final urls = await site.getPlayUrls(liveRoom: room, quality: top);
      expect(urls.length, 1);
      expect(urls.first, startsWith('https://tx-origin.pull.yximgs.com/'));
      expect(urls.first, contains('.flv?'));

      final resolution =
          await site.resolvePlayUrls(liveRoom: room, quality: top);
      expect(resolution.urls, urls);
      expect(resolution.appliedQualityData, top.selectionId);
      expect(resolution.issuedAt, isNotNull);
      expect(resolution.streamFacts.map((f) => f.format), ['flv']);
      // Kuaishou URLs carry no wsTime-style lease: no refresh deadline.
      expect(resolution.refreshAt, isNull);
      expect(resolution.invalidAt, isNull);

      // Recovery re-fetches the room page (fresh scrape, never cached).
      final fetchesBefore = roomPageFetches;
      final recovered = await site.resolvePlayUrlsForRecovery(
        liveRoom: room,
        quality: top,
      );
      expect(roomPageFetches, fetchesBefore + 1);
      expect(recovered.urls, urls);
      expect(recovered.appliedQualityData, top.selectionId);
    });

    test('recovery falls back to first quality when id is gone', () async {
      final site = KuaishouSite(dio: stubDio);
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: 'xmjx151556', platform: 'kuaishou'),
      );
      const stale = LivePlayQuality(
        quality: '蓝光 8M',
        id: '蓝光 8M\u0000999',
        sort: 999,
      );
      final recovered = await site.resolvePlayUrlsForRecovery(
        liveRoom: room,
        quality: stale,
      );
      expect(recovered.urls.length, 1);
      expect(recovered.appliedQualityData, contains('蓝光 质臻'));
    });

    test('failed room page degrades to offline, never throws', () async {
      final failing = Dio();
      failing.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: '<html></html>',
            ),
          ),
        ),
      );
      final site = KuaishouSite(dio: failing);
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: 'xmjx151556', platform: 'kuaishou'),
      );
      expect(room.liveStatus, isFalse);
      expect(await site.getPlayQualities(liveRoom: room), isEmpty);
      expect(
        await site.getPlayUrls(liveRoom: room, quality: null),
        isEmpty,
      );
    });

    test('recommend + search go through the site', () async {
      final site = KuaishouSite(dio: stubDio);
      final rooms = await site.getRecommendRooms();
      expect(rooms.length, 1);
      expect(rooms.first.roomId, 'xmjx151556');
      expect(
        (await site.getPlayQualities(liveRoom: rooms.first)).length,
        4,
      );

      final anchors = await site.searchRooms('王者荣耀');
      expect(anchors.length, 1);
      expect(anchors.first.roomId, 'Kslala666');
      expect(anchors.first.liveStatus, isFalse);
      final anchors2 = await site.searchAnchors('王者荣耀');
      expect(anchors2.length, 1);
      expect(anchors2.first.roomId, 'Kslala666');
    });

    test('site identity + danmaku transport', () {
      final site = KuaishouSite();
      expect(site.id, 'kuaishou');
      expect(site.name, '快手');
      expect(site.getDanmaku().runtimeType.toString(), 'KuaishouDanmaku');
    });
  });
}
