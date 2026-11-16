// Bilibili adapter tests — pure parsing rules that must never regress:
//
// - WBI signing against known vectors (mixin key table, wts + w_rid,
//   `!'()*` stripping) — verified against an independent Python
//   implementation of the same algorithm.
// - Quality = g_qn_desc ∩ accept_qn (unavailable tiers like 4K/杜比
//   never appear for an anonymous request); applied quality is the
//   server's current_qn, NOT the requested qn (10000 -> 250 downgrade).
// - Lines are ordered http_stream/flv first and identified by URL.
// - Danmaku discovery: token + host_list -> official gateway first,
//   regional hosts as failovers.
// - End-to-end room detail -> qualities -> URLs with a stubbed Dio
//   (no real network), including recovery re-fetching.
// - Live room fetch attempts against room 7734200 (skipped when the VM
//   has no route to Bilibili). Unsigned getDanmuInfo returns code -352
//   on this VM; the WBI-signed call returns code 0.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/shared/platforms/bilibili/bilibili_danmaku.dart';
import 'package:standalone/shared/platforms/bilibili/bilibili_site.dart';
import 'package:standalone/shared/platforms/bilibili/bilibili_wbi.dart';

// ------------------------------------------------------------------ canned

Map<String, dynamic> cannedNav() => <String, dynamic>{
  'code': 0,
  'data': <String, dynamic>{
    'wbi_img': <String, dynamic>{
      'img_url':
          'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
      'sub_url':
          'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
    },
  },
};

Map<String, dynamic> cannedSpi() => <String, dynamic>{
  'code': 0,
  'data': <String, dynamic>{'b_3': 'B3TEST', 'b_4': 'B4TEST'},
};

Map<String, dynamic> cannedRoomInfo() => <String, dynamic>{
  'code': 0,
  'message': 'OK',
  'data': <String, dynamic>{
    'room_info': <String, dynamic>{
      'room_id': 7734200,
      'short_id': 6,
      'title': 'Test Room',
      'cover': 'https://example.com/cover.jpg',
      'online': 12345,
      'live_status': 1,
      'description': 'desc',
      'area_name': '英雄联盟',
      'live_start_time': 1794623151,
    },
    'anchor_info': <String, dynamic>{
      'base_info': <String, dynamic>{
        'uname': 'Tester',
        'face': 'https://example.com/face.jpg',
      },
    },
  },
};

Map<String, dynamic> cannedDanmuInfo() => <String, dynamic>{
  'code': 0,
  'data': <String, dynamic>{
    'token': 'test-token-abc',
    'host_list': <Map<String, dynamic>>[
      <String, dynamic>{
        'host': 'tx-bj-live-comet-01.chat.bilibili.com',
        'port': 2243,
        'wss_port': 443,
        'ws_port': 2244,
      },
      <String, dynamic>{
        'host': 'tx-sh-live-comet-02.chat.bilibili.com',
        'port': 2243,
        'wss_port': 444,
        'ws_port': 2244,
      },
    ],
  },
};

Map<String, dynamic> cannedPlayInfo({int currentQn = 150}) =>
    <String, dynamic>{
      'code': 0,
      'message': 'OK',
      'ttl': 1,
      'data': <String, dynamic>{
        'room_id': 7734200,
        'short_id': 6,
        'live_status': 1,
        'playurl_info': <String, dynamic>{
          'playurl': <String, dynamic>{
            'cid': 7734200,
            'g_qn_desc': <Map<String, dynamic>>[
              <String, dynamic>{'qn': 30000, 'desc': '杜比'},
              <String, dynamic>{'qn': 20000, 'desc': '4K'},
              <String, dynamic>{'qn': 15000, 'desc': '2K'},
              <String, dynamic>{'qn': 10000, 'desc': '原画'},
              <String, dynamic>{'qn': 400, 'desc': '蓝光'},
              <String, dynamic>{'qn': 250, 'desc': '超清'},
              <String, dynamic>{'qn': 150, 'desc': '高清'},
              <String, dynamic>{'qn': 80, 'desc': '流畅'},
            ],
            'stream': <Map<String, dynamic>>[
              <String, dynamic>{
                'protocol_name': 'http_stream',
                'format': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'format_name': 'flv',
                    'codec': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'current_qn': currentQn,
                        'accept_qn': <int>[10000, 400, 250, 150],
                        'codec_name': 'avc',
                        'base_url': '/live-bvc/1/live_1_1_1500.flv?x=1',
                        'url_info': <Map<String, dynamic>>[
                          <String, dynamic>{
                            'host':
                                'https://d1--ov-gotcha05.bilivideo.com',
                            'extra': '&e=1',
                          },
                          <String, dynamic>{
                            'host':
                                'https://d1--ov-gotcha06.bilivideo.com',
                            'extra': '&e=1',
                          },
                        ],
                      },
                    ],
                  },
                ],
              },
              <String, dynamic>{
                'protocol_name': 'http_hls',
                'format': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'format_name': 'ts',
                    'codec': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'current_qn': currentQn,
                        'accept_qn': <int>[10000, 400, 250, 150],
                        'codec_name': 'avc',
                        'base_url': '/live-bvc/2/live_1_1_1500.m3u8?x=1',
                        'url_info': <Map<String, dynamic>>[
                          <String, dynamic>{
                            'host':
                                'https://d1--ov-gotcha105.bilivideo.com',
                            'extra': '&e=1',
                          },
                        ],
                      },
                    ],
                  },
                  <String, dynamic>{
                    'format_name': 'fmp4',
                    'codec': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'current_qn': currentQn,
                        'accept_qn': <int>[10000, 400, 250, 150],
                        'codec_name': 'avc',
                        'base_url':
                            '/live-bvc/3/live_1_1_1500/index.m3u8?x=1',
                        'url_info': <Map<String, dynamic>>[
                          <String, dynamic>{
                            'host':
                                'https://d1--ov-gotcha207.bilivideo.com',
                            'extra': '&e=1',
                          },
                        ],
                      },
                    ],
                  },
                ],
              },
            ],
          },
        },
      },
    };

Map<String, dynamic> cannedRecommendList() => <String, dynamic>{
  'code': 0,
  'data': <Map<String, dynamic>>[
    <String, dynamic>{
      'roomid': 111,
      'title': 'A',
      'uname': 'U1',
      'online': 100,
      'cover': '//i0.hdslb.com/cover1.jpg',
      'face': '//i0.hdslb.com/face1.jpg',
      'area_name': 'X',
    },
    <String, dynamic>{
      'roomid': 222,
      'title': 'B',
      'uname': 'U2',
      'online': 500,
      'cover': 'https://i0.hdslb.com/cover2.jpg',
      'face': '',
      'area_v2_name': 'Y',
    },
  ],
};

Map<String, dynamic> cannedRecommendFeed() => <String, dynamic>{
  'code': 0,
  'data': <String, dynamic>{
    'recommend_room_list': <Map<String, dynamic>>[
      <String, dynamic>{
        'roomid': 333,
        'title': 'C',
        'uname': 'U3',
        'online': 7,
        'cover': '//i0.hdslb.com/cover3.jpg',
        'face': '//i0.hdslb.com/face3.jpg',
      },
    ],
  },
};

Map<String, dynamic> cannedCategories() => <String, dynamic>{
  'code': 0,
  'data': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 2,
      'name': '网游',
      'list': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 86,
          'name': '英雄联盟',
          'pic': '//i0.hdslb.com/pic86.jpg',
        },
        <String, dynamic>{'id': 329, 'name': '无畏契约', 'pic': ''},
      ],
    },
    <String, dynamic>{
      'id': 3,
      'name': '手游',
      'list': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 100,
          'name': '王者荣耀',
          'pic': 'https://i0.hdslb.com/pic100.jpg',
        },
      ],
    },
  ],
};

Map<String, dynamic> cannedCategoryRooms() => <String, dynamic>{
  'code': 0,
  'data': <String, dynamic>{
    'list': <Map<String, dynamic>>[
      <String, dynamic>{
        'roomid': 444,
        'title': 'D',
        'uname': 'U4',
        'online': 50,
        'cover': '//i0.hdslb.com/c4.jpg',
        'face': '//i0.hdslb.com/f4.jpg',
        'area_name': '英雄联盟',
      },
      <String, dynamic>{
        'roomid': 555,
        'title': 'E',
        'uname': 'U5',
        'online': 900,
        'cover': '',
        'face': '',
        'area_name': '英雄联盟',
      },
    ],
  },
};

Map<String, dynamic> cannedSearchRooms() => <String, dynamic>{
  'code': 0,
  'data': <String, dynamic>{
    'result': <String, dynamic>{
      'live_room': <Map<String, dynamic>>[
        <String, dynamic>{
          'roomid': 666,
          'title': '<em class="keyword">英雄联盟</em> test',
          'uname': 'U6',
          'online': 42,
          'live_status': 1,
          'cate_name': '<em class="keyword">英雄联盟</em>',
          'cover': '//i0.hdslb.com/sc.jpg',
          'uface': '//i0.hdslb.com/sf.jpg',
        },
        <String, dynamic>{
          'roomid': 777,
          'title': 'offline room',
          'uname': 'U7',
          'online': 0,
          'live_status': 0,
          'cate_name': '其他',
          'cover': '',
          'uface': '',
        },
      ],
    },
  },
};

Map<String, dynamic> cannedSearchAnchors() => <String, dynamic>{
  'code': 0,
  'data': <String, dynamic>{
    'result': <Map<String, dynamic>>[
      <String, dynamic>{
        'roomid': 888,
        'uname': '<em class="keyword">主播</em>A',
        'uface': '//i0.hdslb.com/af.jpg',
        'is_live': 1,
      },
      <String, dynamic>{
        'roomid': 999,
        'uname': 'B',
        'uface': '',
        'is_live': 0,
      },
    ],
  },
};

// -------------------------------------------------------------- stub dio

/// Dio that answers each path from [handlers] (keyed by request path,
/// without query string). Unstubbed paths reject so a test fails loudly
/// instead of hitting the network. [onRequest] runs before resolution,
/// so callers can count requests.
Dio stubDio(
  Map<String, dynamic Function(RequestOptions)> handlers, {
  void Function(String path)? onRequest,
}) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        onRequest?.call(options.path);
        final fn = handlers[options.path];
        if (fn == null) {
          handler.reject(
            DioException(
              requestOptions: options,
              error: 'unstubbed path ${options.path}',
            ),
          );
          return;
        }
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: fn(options),
          ),
        );
      },
    ),
  );
  return dio;
}

Dio fullStubDio({void Function(String path)? onRequest}) {
  return stubDio(
    <String, dynamic Function(RequestOptions)>{
      'https://api.bilibili.com/x/frontend/finger/spi': (_) => cannedSpi(),
      'https://api.bilibili.com/x/web-interface/nav': (_) => cannedNav(),
      'https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom':
          (_) => cannedRoomInfo(),
      'https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo':
          (_) => cannedDanmuInfo(),
      'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo':
          (_) => cannedPlayInfo(),
      'https://api.live.bilibili.com/room/v1/Area/getListByAreaID':
          (_) => cannedRecommendList(),
      'https://api.live.bilibili.com/room/v1/Area/getList':
          (_) => cannedCategories(),
      'https://api.live.bilibili.com/xlive/web-interface/v1/second/getList':
          (_) => cannedCategoryRooms(),
      'https://api.bilibili.com/x/web-interface/search/type': (options) {
        final searchType = options.queryParameters['search_type'];
        return searchType == 'live_user'
            ? cannedSearchAnchors()
            : cannedSearchRooms();
      },
      'https://live.bilibili.com/lol':
          (_) => '<html>"access_id":"stub-access-id"</html>',
    },
    onRequest: onRequest,
  );
}

Future<bool>? _liveReachableCache;

/// Cached cheap probe: can this VM reach api.live.bilibili.com?
Future<bool> _liveReachable() {
  return _liveReachableCache ??= _checkLiveReachable();
}

Future<bool> _checkLiveReachable() async {
  try {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    final response = await dio.get<dynamic>(
      'https://api.live.bilibili.com/room/v1/Area/getListByAreaID',
      queryParameters: <String, dynamic>{
        'areaId': 0,
        'parent_area_id': 0,
        'sort': 'online',
        'pageSize': 1,
        'page': 1,
      },
    );
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// First statement of a live test: returns false (and marks the test
/// skipped) when the VM has no route to Bilibili, so the suite stays
/// green off-network. An API behaviour change still fails the test.
Future<bool> requireLive() async {
  if (await _liveReachable()) return true;
  markTestSkipped(
    'live network unavailable: no route to api.live.bilibili.com',
  );
  return false;
}

void main() {
  group('BilibiliWbiSigner (known vectors)', () {
    test('getMixinKey reorders img+sub keys through the table', () {
      expect(
        BilibiliWbiSigner.getMixinKey(
          '7cd084941338484aae1ad9425b84077c'
          '4932caff0ff746eab6f01bf08b70ac45',
        ),
        'ea1db124af3c7062474693fa704f4ff8',
      );
    });

    test('signParams produces the documented w_rid', () {
      final signed = BilibiliWbiSigner.signParams(
        <String, String>{'room_id': '7734200'},
        'ea1db124af3c7062474693fa704f4ff8',
        wtsSeconds: 1794800000,
      );
      expect(signed['wts'], '1794800000');
      expect(signed['w_rid'], 'f0c59e265e7de99585501f0c4401f1a2');
      expect(signed['room_id'], '7734200');
    });

    test('signParams strips !\'()* from values before signing', () {
      // Dart's Uri.encodeQueryComponent encodes a space as `+` (Python's
      // quote gives %20) — the vector below is the Dart form, matching
      // Pure Live's Dart implementation; verified against md5 of
      // 'id=123&note=ab+c&type=0&wts=1794800000' + mixin.
      final signed = BilibiliWbiSigner.signParams(
        <String, String>{'id': '123', 'type': '0', 'note': "a!'()*b c"},
        'ea1db124af3c7062474693fa704f4ff8',
        wtsSeconds: 1794800000,
      );
      expect(signed['w_rid'], 'd317df4a936ac9257b84e42c68efb740');
    });

    test('signParams does not mutate the input map', () {
      final input = <String, String>{'room_id': '7734200'};
      BilibiliWbiSigner.signParams(
        input,
        'ea1db124af3c7062474693fa704f4ff8',
        wtsSeconds: 1794800000,
      );
      expect(input.containsKey('wts'), isFalse);
      expect(input.containsKey('w_rid'), isFalse);
    });

    test('getWbiKeys fetches img/sub keys from nav and caches them', () async {
      var navCalls = 0;
      final dio = stubDio(<String, dynamic Function(RequestOptions)>{
        'https://api.bilibili.com/x/web-interface/nav': (_) {
          navCalls++;
          return cannedNav();
        },
      });
      final signer = BilibiliWbiSigner(dio: dio);
      final first = await signer.getWbiKeys();
      final second = await signer.getWbiKeys();
      expect(first.$1, '7cd084941338484aae1ad9425b84077c');
      expect(first.$2, '4932caff0ff746eab6f01bf08b70ac45');
      expect(second, first);
      expect(navCalls, 1);
    });

    test('getWbiKeys throws when nav carries no wbi_img', () async {
      final dio = stubDio(<String, dynamic Function(RequestOptions)>{
        'https://api.bilibili.com/x/web-interface/nav':
            (_) => <String, dynamic>{'code': 0, 'data': <String, dynamic>{}},
      });
      final signer = BilibiliWbiSigner(dio: dio);
      await expectLater(signer.getWbiKeys(), throwsFormatException);
    });
  });

  group('parsePlayQualities', () {
    test('quality = g_qn_desc ∩ accept_qn, sorted desc', () {
      final qualities = BiliBiliSite.parsePlayQualities(cannedPlayInfo());
      expect(
        qualities.map((q) => q.data).toList(),
        <int>[10000, 400, 250, 150],
      );
      expect(
        qualities.map((q) => q.quality).toList(),
        <String>['原画', '蓝光', '超清', '高清'],
      );
      expect(qualities.first.id, '10000');
      expect(qualities.first.sort, 10000);
    });

    test('unavailable tiers (4K/杜比/2K/流畅) never appear', () {
      final qualities = BiliBiliSite.parsePlayQualities(cannedPlayInfo());
      final ids = qualities.map((q) => q.data).toSet();
      expect(ids.contains(20000), isFalse);
      expect(ids.contains(30000), isFalse);
      expect(ids.contains(15000), isFalse);
      expect(ids.contains(80), isFalse);
    });

    test('current_qn alone is accepted even if not in accept_qn', () {
      final payload = cannedPlayInfo(currentQn: 80);
      final qualities = BiliBiliSite.parsePlayQualities(payload);
      expect(qualities.map((q) => q.data).toList(), contains(80));
    });

    test('non-zero code throws', () {
      expect(
        () => BiliBiliSite.parsePlayQualities(
          <String, dynamic>{'code': -352, 'message': '-352'},
        ),
        throwsStateError,
      );
    });

    test('missing playurl payload throws FormatException', () {
      expect(
        () => BiliBiliSite.parsePlayQualities(
          <String, dynamic>{
            'code': 0,
            'data': <String, dynamic>{},
          },
        ),
        throwsFormatException,
      );
    });
  });

  group('parsePlayUrlResolution', () {
    test('requested 10000 is downgraded to applied 250... (canned 150)', () {
      final resolution = BiliBiliSite.parsePlayUrlResolution(
        cannedPlayInfo(),
        requestedQualityData: 10000,
      );
      // Canned payload has current_qn 150: the server applied 150, not
      // the requested 10000 — the UI must show 150.
      expect(resolution.appliedQualityData, 150);
      expect(resolution.qualityUnconfirmed, isTrue);
      expect(resolution.urls.length, 4);
      expect(resolution.urls.first, contains('gotcha05'));
      expect(resolution.urls.first, contains('.flv'));
      // http_stream/flv lines first, then hls.
      expect(resolution.factsFor(0).format, 'flv');
      expect(resolution.factsFor(0).codec, 'avc');
      expect(resolution.factsFor(2).format, 'hls');
      expect(resolution.factsFor(3).format, 'hls');
      // Only the applied qn's URLs are returned.
      expect(resolution.urls.every((u) => u.contains('1500')), isTrue);
    });

    test('requested qn that matches is confirmed', () {
      final resolution = BiliBiliSite.parsePlayUrlResolution(
        cannedPlayInfo(),
        requestedQualityData: 150,
      );
      expect(resolution.appliedQualityData, 150);
      expect(resolution.qualityUnconfirmed, isFalse);
      expect(resolution.urls.length, 4);
    });

    test('default request (qn 0) is not flagged unconfirmed', () {
      final resolution = BiliBiliSite.parsePlayUrlResolution(
        cannedPlayInfo(),
        requestedQualityData: 0,
      );
      expect(resolution.appliedQualityData, 150);
      expect(resolution.qualityUnconfirmed, isFalse);
    });

    test('duplicate URLs are dropped, one fact per URL', () {
      final payload = cannedPlayInfo();
      final playurl =
          payload['data']['playurl_info']['playurl'] as Map<String, dynamic>;
      final streams = playurl['stream'] as List;
      final flvCodec =
          ((streams[0] as Map)['format'] as List)[0]['codec'][0]
              as Map<String, dynamic>;
      flvCodec['url_info'] = <Map<String, dynamic>>[
        <String, dynamic>{
          'host': 'https://d1--ov-gotcha05.bilivideo.com',
          'extra': '&e=1',
        },
        <String, dynamic>{
          'host': 'https://d1--ov-gotcha05.bilivideo.com',
          'extra': '&e=1',
        },
      ];
      final resolution = BiliBiliSite.parsePlayUrlResolution(
        payload,
        requestedQualityData: 150,
      );
      expect(resolution.urls.length, 3);
      expect(resolution.streamFacts.length, 3);
    });

    test('no candidates returns empty urls with requested qn', () {
      final payload = cannedPlayInfo();
      final playurl =
          payload['data']['playurl_info']['playurl'] as Map<String, dynamic>;
      playurl['stream'] = <dynamic>[];
      final resolution = BiliBiliSite.parsePlayUrlResolution(
        payload,
        requestedQualityData: 10000,
      );
      expect(resolution.urls, isEmpty);
      expect(resolution.appliedQualityData, 10000);
      expect(resolution.qualityUnconfirmed, isTrue);
    });
  });

  group('carousel', () {
    test('isCarouselResponse: live_status 2 without playurl_info', () {
      expect(
        BiliBiliSite.isCarouselResponse(<String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{'live_status': 2},
        }),
        isTrue,
      );
      expect(
        BiliBiliSite.isCarouselResponse(<String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{
            'live_status': 1,
            'playurl_info': <String, dynamic>{},
          },
        }),
        isFalse,
      );
      expect(
        BiliBiliSite.isCarouselResponse(<String, dynamic>{
          'code': -352,
          'data': <String, dynamic>{'live_status': 2},
        }),
        isFalse,
      );
    });

    test('carouselQuality is the only quality for a carousel room', () async {
      final dio = stubDio(<String, dynamic Function(RequestOptions)>{
        'https://api.bilibili.com/x/frontend/finger/spi': (_) => cannedSpi(),
        'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo':
            (_) => <String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{'live_status': 2},
            },
      });
      final site = BiliBiliSite(dio: dio);
      final qualities = await site.getPlayQualities(
        liveRoom: const LiveRoom(roomId: '1', platform: 'bilibili'),
      );
      expect(qualities.length, 1);
      expect(qualities.first.id, BiliBiliSite.carouselQualityId);
      expect(qualities.first.quality, '轮播');
    });

    test('parseRoundPlayVideo + parseVideoPlayUrls', () {
      final video = BiliBiliSite.parseRoundPlayVideo(<String, dynamic>{
        'code': 0,
        'data': <String, dynamic>{'bvid': 'BV1xx411c7mD', 'cid': 123456},
      });
      expect(video.bvid, 'BV1xx411c7mD');
      expect(video.cid, 123456);
      expect(
        () => BiliBiliSite.parseRoundPlayVideo(<String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{'bvid': 'bad', 'cid': 0},
        }),
        throwsFormatException,
      );
      final urls = BiliBiliSite.parseVideoPlayUrls(<String, dynamic>{
        'code': 0,
        'data': <String, dynamic>{
          'durl': <Map<String, dynamic>>[
            <String, dynamic>{
              'url': 'https://example.com/v1.mp4',
              'backup_url': <String>['https://example.com/v1b.mp4'],
            },
            <String, dynamic>{
              'url': 'https://example.com/v1.mp4',
              'backup_url': <String>[],
            },
          ],
        },
      });
      expect(urls, <String>[
        'https://example.com/v1.mp4',
        'https://example.com/v1b.mp4',
      ]);
    });
  });

  group('room info + danmaku discovery parsing', () {
    test('parseRoomInfoResponse returns data; -352 throws', () {
      final data = BiliBiliSite.parseRoomInfoResponse(cannedRoomInfo());
      expect(data['room_info']['room_id'], 7734200);
      expect(
        () => BiliBiliSite.parseRoomInfoResponse(<String, dynamic>{
          'code': -352,
          'message': '-352',
        }),
        throwsStateError,
      );
      expect(
        () => BiliBiliSite.parseRoomInfoResponse(<String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{},
        }),
        throwsFormatException,
      );
    });

    test('parseDanmakuArgs: official gateway first, regional failovers', () {
      final args = BiliBiliSite.parseDanmakuArgs(
        cannedDanmuInfo()['data'] as Map<String, dynamic>,
        realRoomId: 7734200,
        buvid: 'B3TEST',
        cookie: 'buvid3=B3TEST;',
      );
      expect(args.roomId, 7734200);
      expect(args.token, 'test-token-abc');
      expect(args.uid, 0);
      expect(args.buvid, 'B3TEST');
      expect(args.serverUrls, <String>[
        'wss://broadcastlv.chat.bilibili.com/sub',
        'wss://tx-bj-live-comet-01.chat.bilibili.com/sub',
        'wss://tx-sh-live-comet-02.chat.bilibili.com:444/sub',
      ]);
    });

    test('parseDanmakuArgs tolerates an empty host_list', () {
      final args = BiliBiliSite.parseDanmakuArgs(
        <String, dynamic>{'token': 't'},
        realRoomId: 1,
      );
      expect(args.serverUrls, <String>[
        'wss://broadcastlv.chat.bilibili.com/sub',
      ]);
    });

    test('danmakuData map round-trips through BiliBiliDanmakuArgs', () {
      final args = BiliBiliSite.parseDanmakuArgs(
        cannedDanmuInfo()['data'] as Map<String, dynamic>,
        realRoomId: 7734200,
        buvid: 'B3TEST',
        cookie: 'buvid3=B3TEST;',
      );
      final map = <String, dynamic>{
        'roomId': args.roomId,
        'token': args.token,
        'serverUrls': args.serverUrls,
        'buvid': args.buvid,
        'uid': args.uid,
        'cookie': args.cookie,
      };
      final restored = BiliBiliDanmakuArgs.fromMap(map);
      expect(restored.token, 'test-token-abc');
      expect(restored.serverUrls.length, 3);
      expect(restored.serverUrls.first, 'wss://broadcastlv.chat.bilibili.com/sub');
    });
  });

  group('lists parsing', () {
    test('parseRecommendRooms handles the ranked list shape, sorted', () {
      final rooms = BiliBiliSite.parseRecommendRooms(cannedRecommendList());
      expect(rooms.map((r) => r.roomId).toList(), <String>['222', '111']);
      expect(rooms.first.watching, 500);
      expect(rooms.first.cover, 'https://i0.hdslb.com/cover2.jpg@400w.jpg');
      expect(rooms.last.cover, 'https://i0.hdslb.com/cover1.jpg@400w.jpg');
      expect(rooms.first.liveStatus, isTrue);
    });

    test('parseRecommendRooms handles the feed shape', () {
      final rooms = BiliBiliSite.parseRecommendRooms(cannedRecommendFeed());
      expect(rooms.length, 1);
      expect(rooms.first.roomId, '333');
    });

    test('parseCategories flattens subs and records parents', () {
      final parents = <String, String>{};
      final areas = BiliBiliSite.parseCategories(
        cannedCategories(),
        parentIds: parents,
      );
      expect(areas.map((a) => a.areaId).toList(), <String>['86', '329', '100']);
      expect(areas.first.areaName, '英雄联盟');
      expect(
        areas.first.areaPic,
        'https://i0.hdslb.com/pic86.jpg@100w.png',
      );
      expect(areas[1].areaPic, '');
      expect(parents, <String, String>{'86': '2', '329': '2', '100': '3'});
    });

    test('parseCategoryRooms sorts by watching desc', () {
      final rooms = BiliBiliSite.parseCategoryRooms(cannedCategoryRooms());
      expect(rooms.map((r) => r.roomId).toList(), <String>['555', '444']);
      expect(rooms.first.watching, 900);
    });

    test('parseSearchRooms strips em tags and maps live status', () {
      final rooms = BiliBiliSite.parseSearchRooms(cannedSearchRooms());
      expect(rooms.length, 2);
      expect(rooms.first.title, '英雄联盟 test');
      expect(rooms.first.liveStatus, isTrue);
      expect(rooms.first.watching, 42);
      expect(
        rooms.first.cover,
        'https://i0.hdslb.com/sc.jpg@400w.jpg',
      );
      expect(rooms.last.liveStatus, isFalse);
      expect(rooms.last.cover, '');
    });

    test('parseSearchAnchors strips em tags and maps is_live', () {
      final anchors = BiliBiliSite.parseSearchAnchors(cannedSearchAnchors());
      expect(anchors.length, 2);
      expect(anchors.first.nick, '主播A');
      expect(anchors.first.liveStatus, isTrue);
      expect(anchors.last.liveStatus, isFalse);
    });

    test('normalizeNetworkImageUrl', () {
      expect(
        BiliBiliSite.normalizeNetworkImageUrl('//i0.hdslb.com/x.jpg'),
        'https://i0.hdslb.com/x.jpg',
      );
      expect(
        BiliBiliSite.normalizeNetworkImageUrl('https://i0.hdslb.com/x.jpg'),
        'https://i0.hdslb.com/x.jpg',
      );
      expect(
        BiliBiliSite.normalizeNetworkImageUrl('i0.hdslb.com/x.jpg'),
        'https://i0.hdslb.com/x.jpg',
      );
      expect(BiliBiliSite.normalizeNetworkImageUrl('null'), '');
      expect(BiliBiliSite.normalizeNetworkImageUrl(''), '');
      expect(BiliBiliSite.normalizeNetworkImageUrl('not a url'), '');
    });

    test('sortRoomsByPopularity is deterministic on ties', () {
      final rooms = BiliBiliSite.sortRoomsByPopularity(<LiveRoom>[
        const LiveRoom(roomId: 'b', platform: 'bilibili', watching: 10),
        const LiveRoom(roomId: 'a', platform: 'bilibili', watching: 10),
        const LiveRoom(roomId: 'c', platform: 'bilibili', watching: 20),
      ]);
      expect(
        rooms.map((r) => r.roomId).toList(),
        <String>['c', 'a', 'b'],
      );
    });
  });

  group('stubbed end-to-end (no network)', () {
    test('getRoomDetail fills metadata + danmakuData', () async {
      final site = BiliBiliSite(dio: fullStubDio());
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: '6', platform: 'bilibili'),
      );
      expect(room.title, 'Test Room');
      expect(room.nick, 'Tester');
      expect(room.liveStatus, isTrue);
      expect(room.watching, 12345);
      expect(room.link, 'https://live.bilibili.com/6');
      expect(room.data?['realRoomId'], '7734200');
      final danmakuData = room.danmakuData;
      expect(danmakuData, isNotNull);
      expect(danmakuData!['token'], 'test-token-abc');
      expect(danmakuData['roomId'], 7734200);
      expect(danmakuData['buvid'], 'B3TEST');
      expect(
        (danmakuData['serverUrls'] as List).first,
        'wss://broadcastlv.chat.bilibili.com/sub',
      );
    });

    test('getRoomDetail returns the room offline on -352', () async {
      final dio = stubDio(<String, dynamic Function(RequestOptions)>{
        'https://api.bilibili.com/x/frontend/finger/spi': (_) => cannedSpi(),
        'https://api.bilibili.com/x/web-interface/nav': (_) => cannedNav(),
        'https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom':
            (_) => <String, dynamic>{'code': -352, 'message': '-352'},
      });
      final site = BiliBiliSite(dio: dio);
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: '6', platform: 'bilibili', title: 'kept'),
      );
      expect(room.liveStatus, isFalse);
      expect(room.title, 'kept');
    });

    test('qualities + resolve via stub, recovery re-fetches', () async {
      var playInfoCalls = 0;
      final dio = fullStubDio(
        onRequest: (path) {
          if (path.contains('getRoomPlayInfo')) playInfoCalls++;
        },
      );
      final site = BiliBiliSite(dio: dio);
      const room = LiveRoom(roomId: '7734200', platform: 'bilibili');

      final qualities = await site.getPlayQualities(liveRoom: room);
      expect(qualities.map((q) => q.data).toList(), <int>[
        10000,
        400,
        250,
        150,
      ]);

      final resolution = await site.resolvePlayUrls(
        liveRoom: room,
        quality: qualities.first,
      );
      expect(resolution.appliedQualityData, 150);
      expect(resolution.qualityUnconfirmed, isTrue);
      expect(resolution.urls.length, 4);
      expect(await site.getPlayUrls(liveRoom: room, quality: qualities.first),
          resolution.urls);

      final before = playInfoCalls;
      final recovered = await site.resolvePlayUrlsForRecovery(
        liveRoom: room,
        quality: qualities.first,
      );
      expect(recovered.urls, resolution.urls);
      expect(playInfoCalls, greaterThan(before));
    });

    test('getRecommendRooms + searchRooms via stub', () async {
      final site = BiliBiliSite(dio: fullStubDio());
      final rooms = await site.getRecommendRooms();
      expect(rooms.map((r) => r.roomId).toList(), <String>['222', '111']);

      final found = await site.searchRooms('英雄联盟');
      expect(found.length, 2);
      expect(found.first.title, '英雄联盟 test');

      final anchors = await site.searchAnchors('主播');
      expect(anchors.first.nick, '主播A');
    });

    test('getCategoryRooms resolves the parent via getCategories', () async {
      final site = BiliBiliSite(dio: fullStubDio());
      final areas = await site.getCategories();
      expect(areas.length, 3);
      final lol = areas.firstWhere((a) => a.areaId == '86');
      final rooms = await site.getCategoryRooms(lol);
      expect(rooms.map((r) => r.roomId).toList(), <String>['555', '444']);
    });

    test('getCategoryRooms returns empty for an unknown area', () async {
      final site = BiliBiliSite(dio: fullStubDio());
      final rooms = await site.getCategoryRooms(
        const LiveArea(areaId: '424242', areaName: 'nope'),
      );
      expect(rooms, isEmpty);
    });
  });

  group('live room 7734200 (real network)', () {
    const liveRoom = LiveRoom(roomId: '7734200', platform: 'bilibili');

    test('unsigned getDanmuInfo returns -352 (documents WBI need)',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      if (!await requireLive()) return;
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          headers: <String, String>{
            'User-Agent': BiliBiliSite.kDefaultUserAgent,
            'Referer': 'https://live.bilibili.com/7734200',
          },
        ),
      );
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo',
        queryParameters: <String, dynamic>{'id': 7734200, 'type': 0},
      );
      expect(response.data?['code'], -352);
    });

    test('getRoomDetail discovers WBI-signed danmaku credentials',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      if (!await requireLive()) return;
      final site = BiliBiliSite();
      final room = await site.getRoomDetail(liveRoom);
      expect(room.liveStatus, isTrue);
      expect(room.title, isNotEmpty);
      expect(room.nick, isNotEmpty);
      final danmakuData = room.danmakuData;
      expect(danmakuData, isNotNull);
      expect(danmakuData!['token']?.toString().isNotEmpty, isTrue);
      expect(
        (danmakuData['serverUrls'] as List).first,
        'wss://broadcastlv.chat.bilibili.com/sub',
      );
      expect(danmakuData['roomId'], 7734200);
    });

    test('qualities list only server-confirmed tiers',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      if (!await requireLive()) return;
      final site = BiliBiliSite();
      final qualities = await site.getPlayQualities(liveRoom: liveRoom);
      expect(qualities, isNotEmpty);
      final ids = qualities.map((q) => q.data).toSet();
      // Anonymous accept_qn on this room: 10000/400/250/150.
      expect(ids, contains(10000));
      expect(ids, contains(150));
      expect(ids.contains(20000), isFalse);
      expect(ids.contains(30000), isFalse);
    });

    test('resolvePlayUrls reports the APPLIED quality on downgrade',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      if (!await requireLive()) return;
      final site = BiliBiliSite();
      final qualities = await site.getPlayQualities(liveRoom: liveRoom);
      final top = qualities.firstWhere(
        (q) => q.data == 10000,
        orElse: () => qualities.first,
      );
      final resolution = await site.resolvePlayUrls(
        liveRoom: liveRoom,
        quality: top,
      );
      expect(resolution.urls, isNotEmpty);
      expect(resolution.urls.every((u) => u.startsWith('http')), isTrue);
      // Anonymous request for 10000 is downgraded by the server.
      expect(resolution.appliedQualityData, isNot(10000));
      expect(resolution.qualityUnconfirmed, isTrue);
      expect(resolution.streamFacts.length, resolution.urls.length);
      expect(
        resolution.streamFacts.map((f) => f.format).toSet(),
        isNot(contains('other')),
      );
    });

    test('getRecommendRooms returns a ranked list',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      if (!await requireLive()) return;
      final site = BiliBiliSite();
      final rooms = await site.getRecommendRooms(pageSize: 10);
      expect(rooms, isNotEmpty);
      expect(rooms.first.roomId.isNotEmpty, isTrue);
      for (var i = 1; i < rooms.length; i++) {
        expect(rooms[i].watching, lessThanOrEqualTo(rooms[i - 1].watching));
      }
    });

    test('searchRooms finds live rooms',
        timeout: const Timeout(Duration(seconds: 60)), () async {
      if (!await requireLive()) return;
      final site = BiliBiliSite();
      final rooms = await site.searchRooms('英雄联盟', pageSize: 5);
      expect(rooms, isNotEmpty);
      expect(rooms.first.roomId.isNotEmpty, isTrue);
      expect(rooms.first.title.contains('<'), isFalse);
    });

    test('getCategories + getCategoryRooms (英雄联盟)',
        timeout: const Timeout(Duration(seconds: 90)), () async {
      if (!await requireLive()) return;
      final site = BiliBiliSite();
      final areas = await site.getCategories();
      expect(areas, isNotEmpty);
      final lol = areas.firstWhere(
        (a) => a.areaId == '86',
        orElse: () => areas.first,
      );
      expect(lol.areaName, '英雄联盟');
      final rooms = await site.getCategoryRooms(lol);
      expect(rooms, isNotEmpty);
    });
  });
}
